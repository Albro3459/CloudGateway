package daemon

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"slices"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/wgconfig"
)

const (
	resumeBackoff    = 5 * time.Second
	resumeMaxBackoff = 60 * time.Second
	// resumeSetupWindow bounds boot resume retries after failures that changed
	// nothing, such as resolved starting after the daemon or no route yet
	resumeSetupWindow = 5 * time.Minute
)

var (
	errSuperseded      = errors.New("daemon: a newer network intent superseded this work")
	errIntentNotSaved  = errors.New("daemon: the tunnel started but its intent was not saved")
	errStopUnconfirmed = errors.New("daemon: no fresh observation confirmed the stop")
)

// startPlan is one authorized config ready to start in a mode
type startPlan struct {
	identifier string
	account    string
	generation uint64
	mode       ipc.Mode
	config     *wgconfig.Config
	hash       string
	secretRef  string
}

// resumeState is a boot resume waiting for account authorization
type resumeState struct {
	identifier string
	account    string
	generation uint64
	mode       ipc.Mode
	revision   uint64
}

func (c *Controller) currentIntent() store.Intent {
	c.intentMu.Lock()
	defer c.intentMu.Unlock()
	return c.intent
}

func (c *Controller) desiredRevision() uint64 {
	c.intentMu.Lock()
	defer c.intentMu.Unlock()
	return c.desired
}

// writeIntent persists the next intent revision. A desired change supersedes
// older queued network work. Callers may hold mu but never intentMu
func (c *Controller) writeIntent(update func(*store.Intent), desired bool) (store.Intent, error) {
	intent, _, err := c.writeIntentIf(0, update, desired)
	return intent, err
}

// writeIntentIf is writeIntent as a compare and swap: a nonzero expect fails
// with errSuperseded once the desired revision moved past it. It returns the
// desired revision after the write
func (c *Controller) writeIntentIf(expect uint64, update func(*store.Intent), desired bool) (store.Intent, uint64, error) {
	c.intentMu.Lock()
	defer c.intentMu.Unlock()
	if expect != 0 && c.desired != expect {
		return c.intent, c.desired, errSuperseded
	}
	next := c.intent
	update(&next)
	next.Revision = c.intent.Revision + 1
	if err := c.store.SaveIntent(next); err != nil {
		return c.intent, c.desired, err
	}
	c.intent, c.unsaved = next, false
	if desired {
		c.desired = next.Revision
	}
	return next, c.desired, nil
}

// setRunning records an applied tunnel. A failed save still moves the
// in-memory phase to running, so logout and reconcile treat the tunnel as
// established. reconcile retries the save, and a restart adopts the
// matching tunnel from the saved starting phase
func (c *Controller) setRunning(expect uint64) error {
	c.intentMu.Lock()
	defer c.intentMu.Unlock()
	if expect != 0 && c.desired != expect {
		return errSuperseded
	}
	next := c.intent
	next.Phase = store.PhaseRunning
	next.Revision = c.intent.Revision + 1
	err := c.store.SaveIntent(next)
	c.intent, c.unsaved = next, err != nil
	return err
}

// saveUnsaved retries persisting a running phase whose first save failed
func (c *Controller) saveUnsaved() {
	c.intentMu.Lock()
	defer c.intentMu.Unlock()
	if !c.unsaved {
		return
	}
	next := c.intent
	next.Revision++
	if err := c.store.SaveIntent(next); err != nil {
		return
	}
	c.intent, c.unsaved = next, false
}

// persistJournal stores the network journal inside the intent before every kernel change
func (c *Controller) persistJournal(j *network.Journal) error {
	var raw json.RawMessage
	if j != nil {
		var err error
		if raw, err = json.Marshal(j); err != nil {
			return err
		}
	}
	_, err := c.writeIntent(func(i *store.Intent) { i.Journal = raw }, false)
	return err
}

func (c *Controller) wake() {
	c.mu.Lock()
	c.notifyLocked()
	c.mu.Unlock()
}

// loadIntent reads the durable intent and returns its journal. An unreadable
// intent or journal reports unreadable, so adopt removes owned resources by
// fixed identity
func (c *Controller) loadIntent() (*network.Journal, bool) {
	intent, err := c.store.LoadIntent()
	switch {
	case errors.Is(err, store.ErrMissing):
		c.intent = store.Intent{Phase: store.PhaseStopped}
		return nil, false
	case err != nil:
		c.logf("network intent unreadable. Removing owned resources by fixed identity")
		c.intent = store.Intent{Phase: store.PhaseStopped}
		return nil, true
	}
	c.intent, c.desired = intent, intent.Revision
	if len(intent.Journal) == 0 {
		return nil, false
	}
	journal, err := network.ParseJournal(intent.Journal)
	if err != nil {
		c.logf("network journal unreadable. Removing owned resources by fixed identity")
		return nil, true
	}
	return journal, false
}

// adopt reconciles owned resources at startup. It replays an interrupted stop
// or logout first, adopts a tunnel that matches the journal without touching
// it, and schedules a boot resume when the saved intent was running
func (c *Controller) adopt(unreadable bool) {
	ctx := context.Background()
	intent := c.currentIntent()
	down := func(reason string, update func(*store.Intent)) bool {
		if _, err := c.stopTunnel(ctx); err != nil {
			c.logf("%s: owned network resources remain: %s", reason, failure(err))
			return false
		}
		if _, err := c.writeIntent(update, true); err != nil {
			c.logf("%s: persisting the stopped intent failed: %v", reason, err)
		}
		return true
	}
	switch {
	case unreadable:
		down("unreadable intent", func(i *store.Intent) {
			*i = store.Intent{Phase: store.PhaseStopped, Suppression: store.SuppressDown}
		})
		return
	case intent.Phase == store.PhaseStopping:
		down("interrupted stop", func(i *store.Intent) { i.Phase = store.PhaseStopped })
		return
	case intent.Phase == store.PhaseStopped || intent.Phase == store.PhaseFailed:
		if obs := c.observe(ctx); obs.State != network.StateDisconnected && intent.Phase == store.PhaseFailed {
			down("interrupted failure cleanup", func(*store.Intent) {})
		}
		return
	case intent.Suppression == store.SuppressLogout && intent.Phase == store.PhaseStarting:
		down("logout during a start", func(i *store.Intent) { i.Phase = store.PhaseStopped })
		return
	}
	obs := c.observe(ctx)
	switch {
	case obs.State == network.StateConnected && obs.ProfileID == intent.ProfileID && ipc.Mode(obs.ActiveMode) == intent.Mode:
		if intent.Phase == store.PhaseStarting {
			if err := c.setRunning(0); err != nil {
				c.logf("persisting the adopted tunnel failed: %v", err)
			}
		}
		c.logf("adopted the running tunnel")
		return
	case obs.State == network.StateConnecting && intent.Phase == store.PhaseRunning:
		c.logf("adopted the running tunnel. Repairing owned routes and rules")
		c.reconcile(ctx)
		return
	case intent.Phase == store.PhaseStarting && obs.State != network.StateDisconnected:
		if !down("interrupted start", func(*store.Intent) {}) {
			return
		}
	case obs.State != network.StateDisconnected && obs.Freshness == network.FreshnessCurrent:
		c.logf("owned network resources do not match the saved intent")
		return
	}
	// A failed read proves nothing either way, so the resume's start reads again
	creds := c.creds
	if intent.Suppression != "" || creds == nil || creds.AccountID != intent.AccountID ||
		creds.Generation != intent.SessionGeneration || !belongs(intent.ProfileID, intent.AccountID) {
		return
	}
	c.resume = &resumeState{identifier: intent.ProfileID, account: intent.AccountID, generation: intent.SessionGeneration,
		mode: intent.Mode, revision: c.desiredRevision()}
	c.logf("resuming the last connected client once its account is authorized")
}

// runResume restarts the saved client after a reboot. It waits for the same
// authorization a bare up needs and retries endpoint resolution with backoff
func (c *Controller) runResume(ctx context.Context, r *resumeState) {
	defer func() {
		c.mu.Lock()
		if c.resume == r {
			c.resume = nil
		}
		c.notifyLocked()
		c.mu.Unlock()
	}()
	backoff := resumeBackoff
	var setupDeadline time.Time
	retry := func() bool {
		if c.sleep(ctx, backoff) != nil {
			return false
		}
		backoff = min(backoff*2, resumeMaxBackoff)
		return true
	}
	for {
		var epoch uint64
		var abandoned, authorized bool
		ready := c.waitFor(ctx, func() bool {
			abandoned = c.resumeAbandonedLocked(r)
			authorized = c.user == r.account && c.hasInventory && c.restore == nil && c.refresh == nil
			epoch = c.epoch
			return abandoned || authorized || c.user == "" && c.restore == nil
		})
		if !ready || abandoned {
			return
		}
		if !authorized {
			if !retry() {
				return
			}
			c.mu.Lock()
			c.restoreSessionLocked()
			c.mu.Unlock()
			continue
		}
		plan, err := c.prepareStart(ctx, r.identifier, r.account, epoch, r.mode)
		if err == nil {
			_, err = c.startTunnel(context.Background(), plan, r.revision)
		}
		switch {
		case err == nil, errors.Is(err, errIntentNotSaved):
			c.logf("resumed the last connected client")
			return
		case errors.Is(err, errSuperseded), errors.Is(err, errCancelled):
			return
		case errors.Is(err, network.ErrEndpointUnresolved):
			if !retry() {
				return
			}
		case !errors.As(err, new(*network.ApplyError)) && (failure(err) == ipc.CommandSetupRequired || failure(err) == ipc.CommandVPNFailed):
			// Only an ApplyError changed the kernel, so retrying the rest never cycles the tunnel
			if setupDeadline.IsZero() {
				setupDeadline = c.now().Add(resumeSetupWindow)
			}
			if c.now().After(setupDeadline) {
				c.logf("boot resume stopped: %s", failure(err))
				return
			}
			c.logf("boot resume will retry: %s", failure(err))
			if !retry() {
				return
			}
		default:
			c.logf("boot resume stopped: %s", failure(err))
			return
		}
	}
}

// cancelResume abandons a boot resume that has not started its network change
func (c *Controller) cancelResume() {
	c.mu.Lock()
	c.resume = nil
	c.notifyLocked()
	c.mu.Unlock()
}

func (c *Controller) resumeAbandonedLocked(r *resumeState) bool {
	return c.closing || c.resume != r || c.desiredRevision() != r.revision || c.creds == nil || c.creds.AccountID != r.account ||
		c.creds.Generation != r.generation || c.accessResult == ipc.AccessDenied
}

func profileFor(identifier string, config *wgconfig.Config, mode ipc.Mode) network.Profile {
	applied := config
	if mode == ipc.ModeMesh {
		applied = config.Mesh()
	}
	profile := network.Profile{
		ID: identifier, ConfigHash: config.Hash(), Mode: network.Mode(mode), Addresses: config.Addresses, DNS: config.DNS, MTU: int(config.MTU),
		PeerPublicKey: base64.StdEncoding.EncodeToString(config.Peer.PublicKey[:]), AllowedIPs: applied.Peer.AllowedIPs,
		EndpointHost: config.Peer.Endpoint.Host, EndpointPort: config.Peer.Endpoint.Port, SetConf: applied.SetConf,
	}
	if mode == ipc.ModeFull {
		profile.SearchDomains = config.DNSSearch
	}
	return profile
}

// loadSecret reads a retained config and proves it is the authorized one
func (c *Controller) loadSecret(reference, identifier, hash string) (*wgconfig.Config, error) {
	record, err := c.store.GetSecret(reference)
	if err != nil {
		return nil, err
	}
	config, err := wgconfig.Parse(string(record.Config))
	if err != nil || record.ConfigID != identifier || record.ConfigHash != hash || config.Hash() != hash {
		return nil, errConfigUnavailable
	}
	return config, nil
}

// previousProfile rebuilds the running profile so a failed replacement can restore it
func (c *Controller) previousProfile(intent store.Intent) *network.Profile {
	if intent.Phase != store.PhaseRunning || intent.SecretReference == "" {
		return nil
	}
	config, err := c.loadSecret(intent.SecretReference, intent.ProfileID, intent.ConfigHash)
	if err != nil {
		return nil
	}
	profile := profileFor(intent.ProfileID, config, intent.Mode)
	return &profile
}

// startTunnel installs plan unless the same profile, hash, and mode already
// run. It preflights, persists a starting intent, applies, then persists
// running. A nonzero expect is a background start, which skips work a newer
// intent superseded and never supersedes anything itself. Every intent write
// is a compare and swap, so a down or logout accepted while the start was
// uncommitted rolls it back and keeps its own suppression
func (c *Controller) startTunnel(ctx context.Context, plan startPlan, expect uint64) (bool, error) {
	c.netMu.Lock()
	defer c.netMu.Unlock()
	desired := expect == 0
	if desired {
		expect = c.desiredRevision()
	} else if c.desiredRevision() != expect {
		return false, errSuperseded
	}
	current := c.currentIntent()
	obs := c.observe(ctx)
	if current.Phase == store.PhaseRunning && current.ProfileID == plan.identifier && current.Mode == plan.mode &&
		current.ConfigHash == plan.hash && (obs.State == network.StateConnected || obs.State == network.StateConnecting) {
		if current.Suppression != "" || current.AccountID != plan.account || current.SessionGeneration != plan.generation ||
			current.SecretReference != plan.secretRef {
			_, _, err := c.writeIntentIf(expect, func(i *store.Intent) {
				i.Suppression, i.AccountID, i.SessionGeneration, i.SecretReference = "", plan.account, plan.generation, plan.secretRef
			}, desired)
			if errors.Is(err, errSuperseded) {
				return false, err
			}
			if err != nil {
				return false, errIntentNotSaved
			}
			c.releaseSecret(current, plan.secretRef)
		}
		return false, nil
	}
	profile := profileFor(plan.identifier, plan.config, plan.mode)
	if err := c.net.Preflight(ctx, profile); err != nil {
		return false, err
	}
	_, base, err := c.writeIntentIf(expect, func(i *store.Intent) {
		*i = store.Intent{AccountID: plan.account, SessionGeneration: plan.generation, ProfileID: plan.identifier,
			SecretReference: plan.secretRef, ConfigHash: plan.hash, Mode: plan.mode, Phase: store.PhaseStarting, Journal: i.Journal}
	}, desired)
	if err != nil {
		return false, err
	}
	obs, err = c.net.Apply(ctx, profile, c.previousProfile(current))
	c.setObservation(obs)
	c.cloud.CloseIdleConnections()
	if err == nil {
		werr := c.setRunning(base)
		switch {
		case errors.Is(werr, errSuperseded):
			c.rollbackSupersededStart(ctx)
			return false, werr
		case werr != nil:
			c.logf("persisting the running intent failed: %v", werr)
			return true, errIntentNotSaved
		}
		c.releaseSecret(current, plan.secretRef)
		return true, nil
	}
	// Only an *ApplyError changed the kernel. Anything else left the previous state as it was
	var applyErr *network.ApplyError
	changed := errors.As(err, &applyErr) && !applyErr.Restored
	code := failure(err)
	_, _, werr := c.writeIntentIf(base, func(i *store.Intent) {
		switch {
		case !changed:
			journal := i.Journal
			*i = current
			i.Journal = journal
		case obs.State == network.StateDisconnected:
			i.Phase, i.FailureCode = store.PhaseStopped, code
		default:
			i.Phase, i.FailureCode = store.PhaseFailed, code
		}
	}, false)
	switch {
	case werr == nil && !changed && desired:
		// The start left everything as it was, so work it superseded, like a boot resume, may run again
		c.restoreDesired(base, expect)
	case werr != nil && !errors.Is(werr, errSuperseded):
		c.logf("persisting the failed start failed: %v", werr)
	}
	return false, err
}

// restoreDesired moves the desired revision back to previous unless a newer
// desired write already replaced current
func (c *Controller) restoreDesired(current, previous uint64) {
	c.intentMu.Lock()
	defer c.intentMu.Unlock()
	if c.desired == current {
		c.desired = previous
	}
}

// releaseSecret deletes the record a replaced intent used once the new intent
// is saved, unless an installed config still uses it. The cache keeps it out of
// a refresh's cleanup while the tunnel runs, so nothing else would delete it
func (c *Controller) releaseSecret(replaced store.Intent, next string) {
	old := replaced.SecretReference
	if old == "" || old == next || c.cache.References(replaced.AccountID, old) {
		return
	}
	if err := c.store.DeleteSecret(old); err != nil {
		c.logf("deleting a replaced secret record failed")
	}
}

// rollbackSupersededStart removes a start that finished after a newer intent
// was saved. The newer intent keeps its own phase and suppression
func (c *Controller) rollbackSupersededStart(ctx context.Context) {
	if _, err := c.stopTunnel(ctx); err != nil {
		c.logf("rolling back a superseded start failed: %s", failure(err))
		return
	}
	if _, err := c.writeIntent(func(i *store.Intent) {
		if i.Phase == store.PhaseStarting {
			i.Phase = store.PhaseStopped
		}
	}, false); err != nil {
		c.logf("persisting the rolled back start failed: %v", err)
	}
}

// stopTunnel removes every owned resource. It succeeds only when a fresh
// observation proves nothing owned remains
func (c *Controller) stopTunnel(ctx context.Context) (network.Observation, error) {
	obs, err := c.net.Down(ctx)
	c.setObservation(obs)
	c.cloud.CloseIdleConnections()
	if err == nil && (obs.State != network.StateDisconnected || obs.Freshness != network.FreshnessCurrent) {
		err = errStopUnconfirmed
	}
	return obs, err
}

// stop persists a down intent with start suppression before removing
// owned resources, so no older start can run afterward. It needs no account
func (c *Controller) stop() ipc.Outcome {
	c.cancelResume()
	_, persistErr := c.writeIntent(func(i *store.Intent) {
		i.Phase, i.Suppression, i.FailureCode = store.PhaseStopping, store.SuppressDown, ""
	}, true)
	c.wake()
	c.netMu.Lock()
	_, err := c.stopTunnel(context.Background())
	if err == nil && persistErr == nil {
		// A resolver failure that ran while this waited for netMu leaves its own
		// suppression. This down is the later request, so it wins
		_, persistErr = c.writeIntent(func(i *store.Intent) {
			i.Phase, i.Suppression, i.FailureCode = store.PhaseStopped, store.SuppressDown, ""
		}, false)
	}
	c.netMu.Unlock()
	switch {
	case err != nil:
		c.logf("stop failed: %s", failure(err))
		return failedOutcome(failure(err))
	case persistErr != nil:
		c.logf("stop could not persist its intent: %v", persistErr)
		return failedOutcome(ipc.CommandVPNFailed)
	}
	return ipc.Outcome{Kind: ipc.OutcomeCompleted}
}

// rollbackPartialStart removes a start that never reached running
func (c *Controller) rollbackPartialStart() {
	c.netMu.Lock()
	defer c.netMu.Unlock()
	if c.currentIntent().Phase != store.PhaseStarting {
		return
	}
	if _, err := c.stopTunnel(context.Background()); err != nil {
		c.logf("rolling back a partial start failed: %s", failure(err))
		return
	}
	if _, err := c.writeIntent(func(i *store.Intent) { i.Phase = store.PhaseStopped }, true); err != nil {
		c.logf("persisting the rolled back start failed: %v", err)
	}
}

func (c *Controller) watchNetwork(ctx context.Context) {
	signals, err := network.Watch(ctx, watchInterval)
	if err != nil {
		c.logf("network change events unavailable. Checking every %s", watchInterval)
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-signals:
			c.reconcile(ctx)
		}
	}
}

// reconcile repairs drift in a running tunnel. Losing exclusive Full DNS
// tears the tunnel down as an explicit failure
func (c *Controller) reconcile(ctx context.Context) {
	c.netMu.Lock()
	defer c.netMu.Unlock()
	intent := c.currentIntent()
	if intent.Phase != store.PhaseRunning {
		c.observe(ctx)
		return
	}
	c.mu.Lock()
	drifted := len(c.obs.Drift) > 0 || c.obs.State != network.StateConnected
	c.mu.Unlock()
	obs, err := c.net.Reconcile(ctx)
	c.setObservation(obs)
	// Only a tunnel whose link a fresh read still finds may persist its running
	// phase. Unknown without drift never checked the link
	linked := obs.State == network.StateConnected || obs.State == network.StateConnecting ||
		obs.State == network.StateUnknown && len(obs.Drift) > 0 && !slices.Contains(obs.Drift, network.DriftInterface)
	if obs.Freshness == network.FreshnessCurrent && linked {
		c.saveUnsaved()
	}
	if drifted && obs.State == network.StateConnected {
		c.cloud.CloseIdleConnections()
	}
	if errors.Is(err, network.ErrResolverPolicy) {
		c.failResolverPolicy(ctx)
	}
}

// failResolverPolicy suppresses restart and tears down a Full tunnel whose
// DNS no longer goes only to the VPN link. The selected mode stays Full, and
// the next up must pass preflight again
func (c *Controller) failResolverPolicy(ctx context.Context) {
	if i := c.currentIntent(); i.Phase == store.PhaseStopping && i.Suppression == store.SuppressDown {
		// A down waiting for netMu owns this teardown
		return
	}
	c.logf("Full mode DNS policy could not be restored. Tearing down the tunnel")
	if _, err := c.writeIntent(func(i *store.Intent) {
		i.Phase, i.Suppression, i.FailureCode = store.PhaseStopping, store.SuppressResolverFailure, ipc.CommandVPNFailed
	}, true); err != nil {
		c.logf("persisting the resolver failure failed: %v", err)
	}
	c.wake()
	if _, err := c.stopTunnel(context.WithoutCancel(ctx)); err != nil {
		c.logf("resolver failure teardown is incomplete: %s", failure(err))
		return
	}
	if _, err := c.writeIntent(func(i *store.Intent) { i.Phase = store.PhaseFailed }, false); err != nil {
		c.logf("persisting the resolver failure failed: %v", err)
	}
}

// Cleanup removes owned networking for uninstall while the daemon is stopped.
// It persists a stopping intent with down suppression first when it can, uses
// the journal when readable and fixed identities otherwise, and succeeds only
// when a fresh observation proves nothing owned remains. A store it cannot
// write, such as one from a newer release, still gets the teardown. It is
// safe to rerun
func Cleanup(ctx context.Context, st *store.Store, opts network.Options) error {
	intent, err := st.LoadIntent()
	var journal *network.Journal
	if err != nil {
		intent = store.Intent{}
	} else if len(intent.Journal) > 0 {
		journal, _ = network.ParseJournal(intent.Journal)
	}
	writable := true
	save := func(update func(*store.Intent)) error {
		if !writable {
			return nil
		}
		next := intent
		update(&next)
		next.Revision++
		if err := st.SaveIntent(next); err != nil {
			return err
		}
		intent = next
		return nil
	}
	if save(func(i *store.Intent) { i.Phase, i.Suppression = store.PhaseStopping, store.SuppressDown }) != nil {
		writable = false
	}
	opts.Journal = journal
	opts.Persist = func(j *network.Journal) error {
		var raw json.RawMessage
		if j != nil {
			var err error
			if raw, err = json.Marshal(j); err != nil {
				return err
			}
		}
		return save(func(i *store.Intent) { i.Journal = raw })
	}
	m := network.New(opts)
	if _, err := m.Down(ctx); err != nil {
		return err
	}
	obs, err := m.Observe(ctx)
	if err != nil {
		return err
	}
	if obs.State != network.StateDisconnected || obs.Freshness != network.FreshnessCurrent {
		return network.ErrTeardownIncomplete
	}
	return save(func(i *store.Intent) { i.Phase = store.PhaseStopped })
}
