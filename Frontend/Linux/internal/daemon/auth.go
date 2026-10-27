package daemon

import (
	"context"
	"errors"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/cloud"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
)

// tokenMargin refreshes the cached ID token this long before it expires
const tokenMargin = 5 * time.Minute

var errSessionChanged = errors.New("daemon: session changed")

type failureClass int

const (
	failOther failureClass = iota
	failOffline
	failDenied
	failSignIn
	failCancelled
)

// classify ports CloudGatewayMacInventoryError. Only transport failures are
// offline. AUTH_UNAVAILABLE is an unavailable service, which keeps the session
// but never grants offline access, and neither counts as a denial
func classify(err error) failureClass {
	if errors.Is(err, errSessionChanged) {
		return failCancelled
	}
	switch cloud.KindOf(err) {
	case cloud.KindOffline:
		return failOffline
	case cloud.KindAccessDenied:
		return failDenied
	case cloud.KindSignInRequired:
		return failSignIn
	case cloud.KindCanceled:
		return failCancelled
	}
	return failOther
}

// tokenSource serves Firebase ID tokens for one credential generation.
// Refreshes are serialized, the token is cached until shortly before it
// expires, and a rotated refresh token is saved atomically
func (c *Controller) tokenSource(generation uint64) cloud.TokenSource {
	return func(ctx context.Context, rejected cloud.Secret) (cloud.Secret, error) {
		c.tokenMu.Lock()
		defer c.tokenMu.Unlock()
		c.mu.Lock()
		creds := c.creds
		if creds == nil || creds.Generation != generation {
			c.mu.Unlock()
			return "", errSessionChanged
		}
		// Callers that saw the same rejection wait here, then share one refresh
		if c.idToken != "" && c.idToken != rejected && c.now().Before(c.idTokenExpires.Add(-tokenMargin)) {
			token := c.idToken
			c.mu.Unlock()
			return token, nil
		}
		refreshToken, account, project := creds.RefreshToken, creds.AccountID, creds.ProjectID
		c.mu.Unlock()
		session, err := c.cloud.RefreshSession(ctx, cloud.Secret(refreshToken))
		if err == nil && (session.UserID != account || session.ProjectID != project) {
			err = &cloud.Error{Op: "token refresh", Kind: cloud.KindSignInRequired}
		}
		c.mu.Lock()
		defer c.mu.Unlock()
		if c.creds == nil || c.creds.Generation != generation {
			return "", errSessionChanged
		}
		if err != nil {
			if classify(err) == failSignIn {
				c.logf("saved credentials were rejected. Signing out and keeping the VPN")
				c.discardCredentialsLocked()
			}
			return "", err
		}
		if string(session.RefreshToken) != string(c.creds.RefreshToken) {
			next := *c.creds
			next.RefreshToken = store.Secret(session.RefreshToken)
			if err := c.store.SaveCredentials(next); err != nil {
				c.logf("saving a rotated refresh token failed")
			}
			c.creds = &next
		}
		c.idToken, c.idTokenExpires = session.IDToken, session.ExpiresAt
		return session.IDToken, nil
	}
}

// loadSession restores retained credentials and finishes an interrupted logout.
// A missing or unreadable session record is rebuilt, which revokes whatever
// credentials it can no longer vouch for
func (c *Controller) loadSession() {
	session, err := c.store.LoadSession()
	if errors.Is(err, store.ErrIO) {
		c.logf("session record could not be read. Starting signed out until a restart can read it")
		return
	}
	if err != nil {
		if !errors.Is(err, store.ErrMissing) {
			c.logf("session record unreadable. Rebuilding it, so saved credentials need a new sign-in")
		}
		if session, err = c.store.RecoverSession(); err != nil {
			c.logf("rebuilding the session record failed: %v", err)
			return
		}
	}
	if session.LogoutCleanup {
		c.finishLogout(session)
		return
	}
	creds, err := c.store.LoadCredentials()
	switch {
	case errors.Is(err, store.ErrMissing):
		return
	case err != nil:
		c.logf("saved credentials unreadable")
		return
	case session.Revoked(creds.Generation):
		if err := c.store.ClearCredentials(); err != nil {
			c.logf("clearing revoked credentials failed")
		}
		return
	}
	c.creds = &creds
}

// finishLogout completes a logout whose marker survived a restart
func (c *Controller) finishLogout(session store.Session) {
	if _, err := c.writeIntent(func(i *store.Intent) {
		if i.Suppression == "" {
			i.Suppression = store.SuppressLogout
		}
	}, true); err != nil {
		c.logf("persisting logout suppression failed: %v", err)
		return
	}
	if err := c.store.ClearCredentials(); err != nil {
		c.logf("clearing credentials after logout failed")
		return
	}
	session.LogoutCleanup = false
	if err := c.store.SaveSession(session); err != nil {
		c.logf("clearing the logout marker failed")
	}
}

// signOut runs logout in the order the store documents: revoke the
// generation with a cleanup marker, suppress automatic starts, clear
// credentials, then clear the marker. An established tunnel, secrets,
// caches, and selection stay
func (c *Controller) signOut() ipc.Outcome {
	failed := ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandCredentialsUnavailable}
	c.mu.Lock()
	session, err := c.store.RecoverSession()
	if err != nil {
		// An unreadable record can't block logout, which only revokes more
		known := c.currentIntent().SessionGeneration
		if c.creds != nil {
			known = max(known, c.creds.Generation)
		}
		session, err = c.store.RebuildSession(known)
	}
	if err != nil {
		c.mu.Unlock()
		c.logf("logout could not read or rebuild the session: %v", err)
		return failed
	}
	generation := session.Generation
	if c.creds != nil {
		generation = max(generation, c.creds.Generation)
	}
	marker := store.Session{Generation: generation + 1, RevokedThrough: max(generation, session.RevokedThrough), LogoutCleanup: true}
	if err := c.store.SaveSession(marker); err != nil {
		c.mu.Unlock()
		c.logf("logout could not revoke the session: %v", err)
		return failed
	}
	c.signingOut = true
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		c.signingOut = false
		c.mu.Unlock()
	}()
	if _, err := c.writeIntent(func(i *store.Intent) {
		if i.Suppression == "" {
			i.Suppression = store.SuppressLogout
		}
	}, true); err != nil {
		c.logf("logout could not persist start suppression: %v", err)
		return failed
	}
	// The suppression is durable, so a boot resume waiting for authorization ends here
	c.cancelResume()
	c.mu.Lock()
	cleared := c.store.ClearCredentials()
	c.signOutLocked()
	c.mu.Unlock()
	if cleared != nil {
		c.logf("logout could not clear credentials")
		return failed
	}
	c.rollbackPartialStart()
	marker.LogoutCleanup = false
	if err := c.store.SaveSession(marker); err != nil {
		c.logf("logout could not clear its cleanup marker")
		return failed
	}
	return ipc.Outcome{Kind: ipc.OutcomeCompleted}
}

// discardCredentialsLocked signs out after definite credential rejection,
// denial, or failed role invalidation. The VPN keeps running
func (c *Controller) discardCredentialsLocked() {
	if c.creds != nil {
		if err := c.store.ClearCredentials(); err != nil {
			c.logf("clearing rejected credentials failed")
		}
	}
	c.signOutLocked()
}

// signOutLocked ports the presentation side of macOS signOut
func (c *Controller) signOutLocked() {
	c.creds = nil
	c.idToken, c.idTokenExpires = "", time.Time{}
	c.accessResult = ""
	if c.retained != nil && c.retained.status.Phase != ipc.LoginFinished {
		c.finishRetainedLocked(c.retained.status.AttemptID, ipc.LoginCancelled)
	}
	if c.login != nil {
		c.login.cancel()
		c.login = nil
	}
	c.lastLogin = nil
	c.clearAccountPresentationLocked()
}

func (c *Controller) clearAccountPresentationLocked() {
	c.epoch++
	c.fence++
	c.accountCancel()
	c.accountCtx, c.accountCancel = context.WithCancel(c.ctx)
	if c.refresh != nil {
		c.refresh.cancel()
		c.refresh = nil
	}
	c.inventoryEpoch++
	if c.restore != nil {
		c.restore.cancel()
		c.restore = nil
	}
	c.user = ""
	c.selected, c.selectedMode = "", nil
	c.rows, c.installed = nil, nil
	c.removed = map[string]bool{}
	c.isOffline, c.hasInventory, c.inventoryFailure = false, false, ""
	c.schedule.reset()
	c.deferred, c.deferredAutomatic = false, false
	c.creation = nil
	c.notifyLocked()
}

func (c *Controller) clearInventoryPresentationLocked(account string) {
	if c.user != account {
		return
	}
	c.rows, c.installed = nil, nil
	c.hasInventory = false
	c.selected, c.selectedMode = "", nil
	c.notifyLocked()
}

// authorizeAccountLocked publishes a verified account like macOS changeAccount
func (c *Controller) authorizeAccountLocked(account string) {
	c.user = account
	c.fence++
	c.accessResult = ""
	c.completeRetainedLocked()
	c.notifyLocked()
}

// observeRoleLocked invalidates the cache after a role downgrade. A failed
// invalidation signs out so stale privileges cannot return after restart
func (c *Controller) observeRoleLocked(role cloud.Role, account string) error {
	invalidated, err := c.cache.ObserveRole(account, store.Role(role))
	if err != nil {
		c.clearInventoryPresentationLocked(account)
		c.discardCredentialsLocked()
		return err
	}
	if invalidated {
		c.clearInventoryPresentationLocked(account)
	}
	return nil
}

// denyLocked records a denial for account and signs out
func (c *Controller) denyLocked(account string) {
	c.clearInventoryPresentationLocked(account)
	if err := c.cache.Deny(account); err != nil {
		c.logf("persisting an access denial failed")
	}
	c.discardCredentialsLocked()
	c.accessResult = ipc.AccessDenied
}

func (c *Controller) sameCredsLocked(creds store.Credentials) bool {
	return c.creds != nil && c.creds.AccountID == creds.AccountID && c.creds.Generation == creds.Generation
}

// restoreSessionLocked verifies retained credentials like macOS restoreSession
func (c *Controller) restoreSessionLocked() {
	if c.login != nil || c.user != "" || c.restore != nil || c.creds == nil || c.closing {
		return
	}
	creds, epoch := *c.creds, c.epoch
	ctx, cancel := context.WithCancel(c.accountCtx)
	j := &job{done: make(chan struct{}), cancel: cancel}
	c.restore = j
	c.notifyLocked()
	go c.runRestore(ctx, j, creds, epoch)
}

func (c *Controller) runRestore(ctx context.Context, j *job, creds store.Credentials, epoch uint64) {
	defer close(j.done)
	defer j.cancel()
	access, err := c.cloud.CheckAccess(ctx, creds.AccountID, c.tokenSource(creds.Generation))
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.restore == j {
		c.restore = nil
		c.notifyLocked()
	}
	if c.epoch != epoch || !c.sameCredsLocked(creds) || c.closing || c.retainedExpiredLocked() {
		return
	}
	account := creds.AccountID
	if err == nil {
		if c.observeRoleLocked(access.Role, account) != nil {
			return
		}
		c.authorizeAccountLocked(account)
		c.refreshInventoryLocked(true, true)
		return
	}
	switch classify(err) {
	case failOffline:
		c.schedule.complete(c.now(), false, c.jitter())
		saved, loadErr := c.cache.Load(account)
		if loadErr == nil && saved.AccessAllowed {
			c.installed, c.selected, c.selectedMode = saved.Configs, saved.SelectedIdentifier, saved.SelectedMode
			c.isOffline, c.hasInventory = true, true
			c.inventoryFailure = "offline"
			c.authorizeAccountLocked(account)
		} else {
			c.accessResult = ipc.AccessUnreachable
		}
	case failDenied:
		c.denyLocked(account)
	case failSignIn, failCancelled:
	default:
		c.schedule.complete(c.now(), false, c.jitter())
		c.accessResult = ipc.AccessUnreachable
	}
	c.notifyLocked()
}
