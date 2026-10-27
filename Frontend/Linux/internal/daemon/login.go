package daemon

import (
	"context"
	"errors"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/cloud"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
)

const (
	loginStartupLimit  = 30 * time.Second
	retainedLoginLimit = 30 * time.Second
	maxRetryAfter      = 86_400 * time.Second
)

// loginAttempt ports CloudGatewayMacBrowserAuthCoordinator. The daemon owns
// it, so the CLI disappearing leaves it bounded only by its expiry
type loginAttempt struct {
	id        string
	phase     ipc.LoginPhase
	challenge *ipc.LoginChallenge
	deadline  time.Time
	ctx       context.Context
	cancel    context.CancelFunc
	// rearm moves the attempt watchdog to a new deadline
	rearm func(time.Time)
}

// retainedLogin answers beginLogin while a retained session is verified
type retainedLogin struct {
	status   ipc.LoginStatus
	deadline time.Time
	cancel   context.CancelFunc
}

func finished(id string, result ipc.LoginResult) *ipc.LoginStatus {
	return &ipc.LoginStatus{AttemptID: id, Phase: ipc.LoginFinished, Result: result}
}

func (c *Controller) attemptStatusLocked() *ipc.LoginStatus {
	a := c.login
	if a == nil {
		return c.lastLogin
	}
	status := &ipc.LoginStatus{AttemptID: a.id, Phase: a.phase}
	if a.challenge != nil {
		challenge := *a.challenge
		challenge.RemainingSeconds = max(0, int(a.deadline.Sub(c.now())/time.Second))
		status.Challenge = &challenge
	}
	return status
}

func (c *Controller) currentLoginLocked() *ipc.LoginStatus {
	if c.retained != nil {
		status := c.retained.status
		return &status
	}
	return c.attemptStatusLocked()
}

func (c *Controller) beginLogin(id string) *ipc.LoginStatus {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.user != "" {
		return finished(id, ipc.LoginAuthorized)
	}
	if current := c.currentLoginLocked(); current != nil && current.AttemptID == id {
		return current
	}
	if c.login != nil || c.retained != nil && c.retained.status.Phase != ipc.LoginFinished {
		return finished(id, ipc.LoginBusy)
	}
	if c.closing || c.draining {
		return finished(id, ipc.LoginUnavailable)
	}
	if c.creds != nil {
		c.restoreSessionLocked()
		ctx, cancel := context.WithCancel(c.ctx)
		c.retained = &retainedLogin{
			status:   ipc.LoginStatus{AttemptID: id, Phase: ipc.LoginRestoring},
			deadline: c.now().Add(retainedLoginLimit), cancel: cancel,
		}
		restore := c.restore
		go c.watchRetainedLogin(ctx, id, restore)
		status := c.retained.status
		return &status
	}
	c.retained = nil
	c.startLoginLocked(id)
	return c.attemptStatusLocked()
}

// watchRetainedLogin finishes a retained login when its restoration ends or
// its 30 second limit passes
func (c *Controller) watchRetainedLogin(ctx context.Context, id string, restore *job) {
	limit, cancel := context.WithTimeout(ctx, retainedLoginLimit)
	defer cancel()
	if restore != nil && !waitJob(limit, restore) && ctx.Err() != nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.retained == nil || c.retained.status.AttemptID != id || c.retained.status.Phase == ipc.LoginFinished {
		return
	}
	switch {
	case limit.Err() != nil || !c.now().Before(c.retained.deadline):
		c.clearAccountPresentationLocked()
		c.finishRetainedLocked(id, ipc.LoginExpired)
	case c.user != "":
		c.finishRetainedLocked(id, ipc.LoginAuthorized)
	case c.accessResult == ipc.AccessDenied:
		c.finishRetainedLocked(id, ipc.LoginDenied)
	default:
		c.finishRetainedLocked(id, ipc.LoginOffline)
	}
}

func (c *Controller) retainedExpiredLocked() bool {
	return c.retained != nil && c.retained.status.Phase == ipc.LoginRestoring && !c.now().Before(c.retained.deadline)
}

func (c *Controller) completeRetainedLocked() {
	if c.retained != nil && c.retained.status.Phase == ipc.LoginRestoring {
		c.finishRetainedLocked(c.retained.status.AttemptID, ipc.LoginAuthorized)
	}
}

func (c *Controller) finishRetainedLocked(id string, result ipc.LoginResult) {
	if c.retained == nil || c.retained.status.AttemptID != id {
		return
	}
	c.retained.cancel()
	c.retained.status = *finished(id, result)
	c.notifyLocked()
}

func (c *Controller) loginStatus(id string) *ipc.LoginStatus {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.loginStatusLocked(id)
}

func (c *Controller) loginStatusLocked(id string) *ipc.LoginStatus {
	if current := c.currentLoginLocked(); current != nil && current.AttemptID == id {
		return current
	}
	switch {
	case c.user != "":
		return finished(id, ipc.LoginAuthorized)
	case c.restore != nil:
		return &ipc.LoginStatus{AttemptID: id, Phase: ipc.LoginRestoring}
	case c.accessResult == ipc.AccessDenied:
		return finished(id, ipc.LoginDenied)
	}
	return finished(id, ipc.LoginUnavailable)
}

// cancelLogin targets only the named attempt
func (c *Controller) cancelLogin(id string) *ipc.LoginStatus {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.retained != nil && c.retained.status.AttemptID == id && c.retained.status.Phase != ipc.LoginFinished {
		c.clearAccountPresentationLocked()
		c.finishRetainedLocked(id, ipc.LoginCancelled)
	} else {
		c.finishLoginLocked(id, ipc.LoginCancelled)
	}
	return c.loginStatusLocked(id)
}

func (c *Controller) startLoginLocked(id string) {
	ctx, cancel := context.WithCancel(c.ctx)
	a := &loginAttempt{id: id, phase: ipc.LoginRequestingCode, deadline: c.now().Add(loginStartupLimit), ctx: ctx, cancel: cancel}
	// The watchdog runs on wall time so a stalled request still ends at the deadline
	var watchdog context.CancelFunc
	a.rearm = func(deadline time.Time) {
		if watchdog != nil {
			watchdog()
		}
		var limit context.Context
		limit, watchdog = context.WithTimeout(ctx, deadline.Sub(c.now()))
		go func() {
			<-limit.Done()
			if ctx.Err() == nil && limit.Err() == context.DeadlineExceeded {
				c.expireLogin(id, deadline)
			}
		}()
	}
	a.rearm(a.deadline)
	c.login = a
	c.lastLogin = nil
	c.notifyLocked()
	go c.runLogin(a)
}

func (c *Controller) expireLogin(id string, deadline time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.login != nil && c.login.id == id && c.login.deadline.Equal(deadline) {
		c.finishLoginLocked(id, ipc.LoginExpired)
	}
}

func (c *Controller) finishLoginLocked(id string, result ipc.LoginResult) {
	if c.login == nil || c.login.id != id {
		return
	}
	c.login.cancel()
	c.login = nil
	c.lastLogin = finished(id, result)
	c.notifyLocked()
}

// loginCurrent reports whether attempt a is still running and unexpired
func (c *Controller) loginCurrent(a *loginAttempt) (bool, ipc.LoginResult) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.login != a || a.ctx.Err() != nil {
		return false, ipc.LoginCancelled
	}
	if !c.now().Before(a.deadline) {
		return false, ipc.LoginExpired
	}
	return true, ""
}

func (c *Controller) runLogin(a *loginAttempt) {
	result := c.deviceLogin(a)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.login == a && result != "" {
		c.finishLoginLocked(a.id, result)
	}
}

// deviceLogin runs one attempt and returns its result, or "" once the attempt finished elsewhere
func (c *Controller) deviceLogin(a *loginAttempt) ipc.LoginResult {
	ctx := a.ctx
	ensure := func() ipc.LoginResult {
		if ok, result := c.loginCurrent(a); !ok {
			return result
		}
		return ""
	}
	secret, err := cloud.NewDeviceSecret()
	if err != nil {
		return ipc.LoginUnavailable
	}
	var code cloud.DeviceCode
	var requestStarted time.Time
	for {
		if result := ensure(); result != "" {
			return result
		}
		requestStarted = c.now()
		code, err = c.cloud.RequestDeviceCode(ctx, secret)
		if err == nil {
			break
		}
		retry, result := c.throttle(a, err)
		if result != "" {
			return result
		}
		if err := c.sleep(ctx, min(retry, max(c.deadline(a).Sub(c.now()), 0))); err != nil {
			return ipc.LoginCancelled
		}
	}
	if result := ensure(); result != "" {
		return result
	}
	c.mu.Lock()
	a.deadline = requestStarted.Add(code.ExpiresIn)
	a.rearm(a.deadline)
	a.phase = ipc.LoginWaitingForApproval
	a.challenge = &ipc.LoginChallenge{VerificationURL: code.VerificationURL, UserCode: code.UserCode}
	c.notifyLocked()
	c.mu.Unlock()
	interval := code.Interval
	for {
		remaining := c.deadline(a).Sub(c.now())
		if remaining <= 0 {
			return ipc.LoginExpired
		}
		if err := c.sleep(ctx, min(interval, remaining)); err != nil {
			return ipc.LoginCancelled
		}
		if result := ensure(); result != "" {
			return result
		}
		poll, err := c.cloud.PollDeviceToken(ctx, code.RequestID, secret)
		if err != nil {
			retry, result := c.throttle(a, err)
			if result != "" {
				return result
			}
			interval = max(interval, retry)
			continue
		}
		if result := ensure(); result != "" {
			return result
		}
		if poll.Pending {
			interval = max(interval, poll.Interval)
			continue
		}
		return c.exchange(a, poll.CustomToken)
	}
}

func (c *Controller) deadline(a *loginAttempt) time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return a.deadline
}

// throttle returns how long to wait after a 429, or the attempt's result for any other failure
func (c *Controller) throttle(a *loginAttempt, err error) (time.Duration, ipc.LoginResult) {
	if e, ok := errors.AsType[*cloud.Error](err); ok && e.Kind == cloud.KindThrottled {
		if e.RetryAfter <= 0 || e.RetryAfter > maxRetryAfter {
			return 0, ipc.LoginInvalidResponse
		}
		return e.RetryAfter, ""
	}
	if a.ctx.Err() != nil {
		return 0, ipc.LoginCancelled
	}
	switch cloud.KindOf(err) {
	case cloud.KindDeviceExpired:
		return 0, ipc.LoginExpired
	case cloud.KindDeviceDenied:
		return 0, ipc.LoginDenied
	case cloud.KindInvalidResponse, cloud.KindDeviceInvalid, cloud.KindDeviceConsumed:
		return 0, ipc.LoginInvalidResponse
	case cloud.KindOffline:
		return 0, ipc.LoginOffline
	case cloud.KindCanceled:
		return 0, ipc.LoginCancelled
	}
	return 0, ipc.LoginUnavailable
}

// exchange signs in with the custom token, checks access and role, then
// commits credentials behind this attempt and a new session generation
func (c *Controller) exchange(a *loginAttempt, customToken cloud.Secret) ipc.LoginResult {
	ctx := a.ctx
	c.mu.Lock()
	a.phase = ipc.LoginExchangingToken
	c.notifyLocked()
	c.mu.Unlock()
	session, err := c.cloud.SignInWithCustomToken(ctx, customToken)
	if err != nil {
		if ctx.Err() != nil {
			return ipc.LoginCancelled
		}
		return ipc.LoginUnavailable
	}
	if ok, result := c.loginCurrent(a); !ok {
		return result
	}
	tokens := pendingTokens(c, session)
	access, err := c.cloud.CheckAccess(ctx, session.UserID, tokens.source)
	if ok, result := c.loginCurrent(a); !ok {
		return result
	}
	// Token refreshes lock tokenMu before mu, so read the latest session first
	latest := tokens.latest()
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.login != a {
		return ""
	}
	switch classify(err) {
	case failDenied:
		if err := c.cache.Deny(session.UserID); err != nil {
			c.logf("persisting an access denial failed")
		}
		c.accessResult = ipc.AccessDenied
		return ipc.LoginDenied
	case failOffline:
		return ipc.LoginOffline
	}
	if err != nil {
		return ipc.LoginUnavailable
	}
	if _, err := c.cache.ObserveRole(session.UserID, store.Role(access.Role)); err != nil {
		return ipc.LoginUnavailable
	}
	current, err := c.store.RecoverSession()
	if err != nil {
		return ipc.LoginUnavailable
	}
	session = latest
	generation := current.Generation + 1
	if err := c.store.SaveSession(store.Session{Generation: generation, AccountID: session.UserID, RevokedThrough: current.RevokedThrough}); err != nil {
		return ipc.LoginUnavailable
	}
	creds := store.Credentials{AccountID: session.UserID, ProjectID: session.ProjectID, Generation: generation,
		RefreshToken: store.Secret(session.RefreshToken)}
	if err := c.store.SaveCredentials(creds); err != nil {
		return ipc.LoginUnavailable
	}
	if c.user != "" && c.user != session.UserID {
		c.clearAccountPresentationLocked()
	}
	c.creds = &creds
	c.idToken, c.idTokenExpires = session.IDToken, session.ExpiresAt
	c.finishLoginLocked(a.id, ipc.LoginAuthorized)
	c.authorizeAccountLocked(session.UserID)
	c.refreshInventoryLocked(true, true)
	return ""
}

// sessionTokens serves an uncommitted login session for its access check
type sessionTokens struct {
	c       *Controller
	current cloud.Session
}

func pendingTokens(c *Controller, session cloud.Session) *sessionTokens {
	return &sessionTokens{c: c, current: session}
}

func (t *sessionTokens) source(ctx context.Context, force bool) (cloud.Secret, error) {
	t.c.tokenMu.Lock()
	defer t.c.tokenMu.Unlock()
	if !force && t.c.now().Before(t.current.ExpiresAt.Add(-tokenMargin)) {
		return t.current.IDToken, nil
	}
	session, err := t.c.cloud.RefreshSession(ctx, t.current.RefreshToken)
	if err != nil {
		return "", err
	}
	if session.UserID != t.current.UserID || session.ProjectID != t.current.ProjectID {
		return "", &cloud.Error{Op: "token refresh", Kind: cloud.KindSignInRequired}
	}
	t.current = session
	return session.IDToken, nil
}

func (t *sessionTokens) latest() cloud.Session {
	t.c.tokenMu.Lock()
	defer t.c.tokenMu.Unlock()
	return t.current
}
