package daemon

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/cloud"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
)

const maxCapacityReads = 4

var (
	errClientActive      = errors.New("daemon: client active")
	errConfigUnavailable = errors.New("daemon: config unavailable")
	errCancelled         = errors.New("daemon: session changed during the command")
	errForeignOwner      = errors.New("daemon: client belongs to another owner")
)

func failedOutcome(failure ipc.CommandFailure) ipc.Outcome {
	return ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: failure}
}

// failure ports CloudGatewayMacController.failure(for:), plus the Linux
// network errors from tunnelFailure
func failure(err error) ipc.CommandFailure {
	switch {
	case errors.Is(err, errClientActive):
		return ipc.CommandClientActive
	case errors.Is(err, errStopUnconfirmed), errors.Is(err, network.ErrTeardownIncomplete):
		return ipc.CommandStopTimedOut
	case errors.Is(err, store.ErrAccessDenied), errors.Is(err, errForeignOwner):
		return ipc.CommandAccessDenied
	case errors.Is(err, errConfigUnavailable), errors.Is(err, store.ErrInvalidMetadata), errors.Is(err, store.ErrUnavailable),
		errors.Is(err, store.ErrMissing), errors.Is(err, store.ErrUnreadable):
		return ipc.CommandConfigUnavailable
	case errors.Is(err, errCancelled), errors.Is(err, errSessionChanged), errors.Is(err, errSuperseded):
		return ipc.CommandSignInRequired
	}
	return tunnelFailure(err)
}

// tunnelFailure maps network errors to public codes. Host setup gaps are
// setup_required, so doctor can explain them. Collisions with addresses,
// routes, rules, marks, or links the daemon does not own are vpn_failed.
// An endpoint that does not resolve is network_unavailable
func tunnelFailure(err error) ipc.CommandFailure {
	var preflight *network.PreflightError
	switch {
	case errors.As(err, &preflight):
		for _, conflict := range preflight.Conflicts {
			switch conflict.Kind {
			case network.ConflictMissingTools, network.ConflictNoWireGuard, network.ConflictIPv6Disabled,
				network.ConflictResolverInactive, network.ConflictResolverStub, network.ConflictResolverDomains:
				return ipc.CommandSetupRequired
			}
		}
		return ipc.CommandVPNFailed
	case errors.Is(err, network.ErrEndpointUnresolved):
		return ipc.CommandNetworkUnavailable
	case errors.Is(err, network.ErrInvalidProfile):
		return ipc.CommandConfigUnavailable
	}
	return ipc.CommandVPNFailed
}

func isStopAction(action ipc.Action) bool {
	return action == ipc.ActionTurnOff || action == ipc.ActionDisconnectClient
}

// reserve admits a confirmable request like the orchestrator's admit
func (c *Controller) reserve(ctx context.Context, request ipc.Request) ipc.Reply {
	c.resumeDeferredIfIdle()
	session := c.session()
	operation, rejected := c.registry.Reserve(request, session, func() ipc.ControllerFailure {
		return c.admission(request, session)
	})
	if rejected != "" {
		return ipc.Reply{Error: rejected}
	}
	state := c.state(ctx, false)
	return ipc.Reply{State: &state, Operation: &operation, Outcome: c.registry.Outcome(operation.ID, session)}
}

// admission runs under the registry lock after its slot rules
func (c *Controller) admission(request ipc.Request, session SessionToken) ipc.ControllerFailure {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closing || c.draining && request.Action != ipc.ActionTurnOff || c.updatePendingLocked() && !isStopAction(request.Action) {
		return ipc.FailureBusy
	}
	switch request.Action {
	case ipc.ActionSetMode:
		if !c.canAdmitModeLocked() {
			return ipc.FailureBusy
		}
		if !c.settledLocked(session) {
			return ipc.FailureRejected
		}
	case ipc.ActionRemoveClient:
		if !c.canAdmitRemovalLocked() {
			return ipc.FailureBusy
		}
		if !c.settledLocked(session) || !belongs(request.Identifier, session.AccountID) {
			return ipc.FailureRejected
		}
	case ipc.ActionDisconnectClient:
		if !c.settledLocked(session) || c.countClientsLocked(request.Identifier) != 1 {
			return ipc.FailureRejected
		}
	case ipc.ActionCreateClient:
		if !c.creationValidLocked(request) {
			return ipc.FailurePreparationExpired
		}
	}
	return ""
}

// canAdmitRemovalLocked ports canAdmitRemoval: no other work may be pending
func (c *Controller) canAdmitRemovalLocked() bool {
	return !c.closing && !c.draining && !c.preparing && c.refresh == nil && !c.deferred && c.restore == nil &&
		c.commands == 0 && c.stops == 0 && c.login == nil
}

// canAdmitModeLocked refuses a mode change while the tunnel connects, which
// includes a pending boot resume, like macOS
func (c *Controller) canAdmitModeLocked() bool {
	return c.canAdmitRemovalLocked() && c.resume == nil &&
		c.obs.State != network.StateConnecting && c.obs.State != network.StateDisconnecting
}

func (c *Controller) settledLocked(session SessionToken) bool {
	return session.AccountID != "" && session == c.sessionLocked() && c.restore == nil
}

func (c *Controller) countClientsLocked(identifier string) int {
	count := 0
	for _, client := range c.clientsLocked(c.obs, "") {
		if client.Identifier == identifier {
			count++
		}
	}
	return count
}

func (c *Controller) creationValidLocked(request ipc.Request) bool {
	creation := c.creation
	return creation != nil && creation.id == request.ContextID && c.now().Before(creation.expires) &&
		creation.session == c.sessionLocked() &&
		slices.ContainsFunc(creation.regions, func(r ipc.CreationRegion) bool { return r.RegionID == request.RegionID })
}

// confirm ports the orchestrator's confirm: checks at confirmation, then
// synchronous admission, then the command runs detached from the caller
func (c *Controller) confirm(ctx context.Context, id string) ipc.Reply {
	if c.ownsUpdate(id) {
		return c.confirmUpdate(ctx, id)
	}
	reservation, ok := c.registry.ConfirmChecked(id, c.confirmCheck)
	if !ok {
		c.resumeDeferredIfIdle()
		return c.operationReply(ctx, id)
	}
	run, rejection := c.admit(reservation)
	switch {
	case rejection != nil:
		c.registry.Finish(id, *rejection, true, "")
		c.resumeDeferredIfIdle()
	case run == nil:
		c.registry.Reject(id)
		c.resumeDeferredIfIdle()
	default:
		go func() {
			defer c.work.Done()
			outcome := run()
			// Release the controller's count first, so a caller that sees the
			// result can reserve its next command without a stale busy
			c.mu.Lock()
			if isStopAction(reservation.Request.Action) {
				c.stops--
			} else {
				c.commands--
			}
			c.notifyLocked()
			c.mu.Unlock()
			c.registry.Finish(id, outcome, false, "")
			c.resumeDeferredIfIdle()
		}()
	}
	return c.operationReply(ctx, id)
}

// resumeDeferredIfIdle restarts a deferred refresh once no command blocks it.
// A forced refresh resumes regardless of open reservations, and an automatic
// one waits for them. The registry expires reservations lazily, so reads and
// ticks call this too
func (c *Controller) resumeDeferredIfIdle() {
	command, creation := c.registry.Busy()
	c.mu.Lock()
	defer c.mu.Unlock()
	c.resumeDeferredLocked(!command && !creation)
}

// confirmCheck runs under the registry lock, so it must not call the registry
func (c *Controller) confirmCheck(pending Reservation) (ipc.ControllerFailure, *ipc.Outcome) {
	request := pending.Request
	fail := func(controller ipc.ControllerFailure, command ipc.CommandFailure) (ipc.ControllerFailure, *ipc.Outcome) {
		outcome := failedOutcome(command)
		return controller, &outcome
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	session := c.sessionLocked()
	if c.draining && request.Action != ipc.ActionTurnOff {
		return fail(ipc.FailureBusy, ipc.CommandBusy)
	}
	// Account work runs only for the session that reserved it
	if request.Action.AccountBound() && session != pending.Session {
		return fail(ipc.FailureRejected, ipc.CommandSignInRequired)
	}
	switch request.Action {
	case ipc.ActionSetMode:
		if !c.canAdmitModeLocked() {
			return fail(ipc.FailureBusy, ipc.CommandBusy)
		}
		if !c.settledLocked(session) {
			return fail(ipc.FailureRejected, ipc.CommandSignInRequired)
		}
	case ipc.ActionRemoveClient:
		if !c.canAdmitRemovalLocked() {
			return fail(ipc.FailureBusy, ipc.CommandBusy)
		}
		if !c.settledLocked(session) {
			return fail(ipc.FailureRejected, ipc.CommandSignInRequired)
		}
	case ipc.ActionDisconnectClient:
		if !c.settledLocked(session) || c.countClientsLocked(request.Identifier) != 1 {
			return fail(ipc.FailureRejected, ipc.CommandConfigUnavailable)
		}
	case ipc.ActionCreateClient:
		if !c.creationValidLocked(request) {
			return ipc.FailurePreparationExpired, nil
		}
	}
	return "", nil
}

// admit ports each controller command's synchronous rejection rules. A nil
// run without an outcome refuses work the way createClient returns false
func (c *Controller) admit(reservation Reservation) (func() ipc.Outcome, *ipc.Outcome) {
	request := reservation.Request
	c.mu.Lock()
	defer c.mu.Unlock()
	reject := func(failure ipc.CommandFailure) (func() ipc.Outcome, *ipc.Outcome) {
		outcome := failedOutcome(failure)
		return nil, &outcome
	}
	if c.closing {
		return reject(ipc.CommandBusy)
	}
	// Account work runs only for the session that reserved it
	if request.Action.AccountBound() && reservation.Session != c.sessionLocked() {
		return reject(ipc.CommandSignInRequired)
	}
	account, epoch, fence, ctx := c.user, c.epoch, c.fence, c.accountCtx
	var generation uint64
	if c.creds != nil && c.creds.AccountID == account {
		generation = c.creds.Generation
	}
	signedIn := account != "" && generation != 0
	var run func() ipc.Outcome
	switch request.Action {
	case ipc.ActionConnect:
		identifier := request.Identifier
		if identifier == "" && belongs(c.selected, account) {
			identifier = c.selected
		}
		switch {
		case !signedIn:
			return reject(ipc.CommandSignInRequired)
		case c.selectedMode == nil:
			return reject(ipc.CommandConfigUnavailable)
		case identifier == "" || !belongs(identifier, account) || !c.hasConnectableLocked(identifier, account):
			if request.Identifier == "" {
				return reject(ipc.CommandSelectionUnavailable)
			}
			return reject(ipc.CommandConfigUnavailable)
		}
		mode := *c.selectedMode
		c.cancelRefreshLocked()
		run = func() ipc.Outcome { return c.runConnect(ctx, identifier, account, epoch, mode) }
	case ipc.ActionSetMode:
		switch {
		case !signedIn:
			return reject(ipc.CommandSignInRequired)
		case !c.canMutateInventoryLocked():
			return reject(ipc.CommandBusy)
		case !c.hasInventory:
			return reject(ipc.CommandAccessDenied)
		}
		run = func() ipc.Outcome { return c.runSetMode(ctx, request.Mode, account, epoch) }
	case ipc.ActionTurnOff:
		run = c.stop
	case ipc.ActionDisconnectClient:
		switch {
		case !signedIn:
			return reject(ipc.CommandSignInRequired)
		case !c.hasInventory:
			return reject(ipc.CommandAccessDenied)
		case c.countClientsLocked(request.Identifier) != 1:
			return reject(ipc.CommandConfigUnavailable)
		}
		run = func() ipc.Outcome { return c.runDisconnect(request.Identifier, account, epoch) }
	case ipc.ActionRemoveClient:
		switch {
		case !signedIn:
			return reject(ipc.CommandSignInRequired)
		case !c.canMutateInventoryLocked():
			return reject(ipc.CommandBusy)
		case !belongs(request.Identifier, account):
			return reject(ipc.CommandConfigUnavailable)
		}
		run = func() ipc.Outcome {
			return c.runRemove(ctx, request.Identifier, account, generation, epoch, fence)
		}
	case ipc.ActionCreateClient:
		if !c.canSubmitCreationLocked() || !c.creationValidLocked(request) {
			return nil, nil
		}
		c.creation = nil
		run = func() ipc.Outcome {
			return c.runCreate(ctx, request.RegionID, request.ClientName, account, generation, epoch, fence)
		}
	case ipc.ActionSignOut:
		run = c.signOut
	default:
		return nil, nil
	}
	if isStopAction(request.Action) {
		c.stops++
	} else {
		c.commands++
	}
	c.work.Add(1)
	c.notifyLocked()
	return run, nil
}

// canSubmitCreationLocked ports canSubmitCreation, which a running stop does not block
func (c *Controller) canSubmitCreationLocked() bool {
	return !c.closing && !c.draining && c.commands == 0 && c.user != "" && c.creds != nil && c.creds.AccountID == c.user &&
		c.refresh == nil && c.restore == nil && c.login == nil
}

// prepareStart picks the config for identifier like connectConfiguration: a
// retained record the cache still authorizes, or else a fresh online install
func (c *Controller) prepareStart(ctx context.Context, identifier, account string, epoch uint64, mode ipc.Mode) (startPlan, error) {
	c.mu.Lock()
	if c.epoch != epoch || c.user != account || c.creds == nil || c.creds.AccountID != account {
		c.mu.Unlock()
		return startPlan{}, errCancelled
	}
	if !c.hasConnectableLocked(identifier, account) {
		c.mu.Unlock()
		return startPlan{}, errConfigUnavailable
	}
	plan := startPlan{identifier: identifier, account: account, generation: c.creds.Generation, mode: mode}
	offline := c.isOffline
	var option *row
	if r := c.rowLocked(identifier); r != nil && !offline {
		copied := *r
		option = &copied
	}
	var saved *store.InstalledConfig
	if config := c.installedLocked(identifier, account); config != nil {
		copied := *config
		saved = &copied
	}
	c.mu.Unlock()
	installable := !offline && option != nil && option.config != nil && option.eligibility() == eligible
	if saved != nil && (offline || option == nil || option.hash == saved.Snapshot.ConfigHash) {
		authorized, err := c.cache.Load(account)
		if err != nil {
			return startPlan{}, err
		}
		if !authorized.AccessAllowed || !slices.ContainsFunc(authorized.Configs, func(config store.InstalledConfig) bool {
			return config.Identifier == identifier && config.Snapshot.ConfigHash == saved.Snapshot.ConfigHash &&
				config.Snapshot.SecretReference == saved.Snapshot.SecretReference
		}) {
			return startPlan{}, errConfigUnavailable
		}
		config, err := c.loadSecret(saved.Snapshot.SecretReference, identifier, saved.Snapshot.ConfigHash)
		if err == nil {
			plan.config, plan.hash, plan.secretRef = config, saved.Snapshot.ConfigHash, saved.Snapshot.SecretReference
			return plan, nil
		}
		// A missing retained record is reinstalled from the online inventory
		if !installable {
			return startPlan{}, errConfigUnavailable
		}
	} else if !installable {
		return startPlan{}, errConfigUnavailable
	}
	return c.install(ctx, *option, plan, epoch)
}

// install stores the canonical config as a new secret record and its
// metadata in the cache, rolling the record back if the metadata fails.
// Retained records stay otherwise, except one this install superseded
func (c *Controller) install(ctx context.Context, option row, plan startPlan, epoch uint64) (startPlan, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if ctx.Err() != nil || c.epoch != epoch || c.user != plan.account {
		return startPlan{}, errCancelled
	}
	reference, err := c.store.PutSecret(store.SecretRecord{ConfigID: option.identifier, ConfigHash: option.hash,
		Config: store.Secret(option.config.Canonical())})
	if err != nil {
		return startPlan{}, err
	}
	client := option.option.Client
	config := store.InstalledConfig{AccountID: plan.account, Identifier: option.identifier, Snapshot: store.ConfigSnapshot{
		ClientID: client.ClientID, RegionID: client.RegionID, ClientName: client.ClientName,
		RegionDisplayName: option.option.RegionDisplayName(), Status: string(client.Status), ConfigHash: option.hash,
		SecretReference: reference, ReadAt: c.now().UTC(), UpdatedAt: client.UpdatedAt,
		AssignedTunnelIPv4: client.AssignedTunnelIPv4, ServerEndpointIPv4: client.ServerEndpointIPv4,
		ServerEndpointHostname: client.ServerEndpointHostname,
	}}
	var previous string
	if saved := c.installedLocked(option.identifier, plan.account); saved != nil {
		previous = saved.Snapshot.SecretReference
	}
	if err := c.cache.Save(config); err != nil {
		if deleteErr := c.store.DeleteSecret(reference); deleteErr != nil {
			c.logf("rolling back an unreferenced secret record failed")
		}
		return startPlan{}, err
	}
	// The reinstall superseded the old record unless the running tunnel still uses it
	if previous != "" && previous != c.currentIntent().SecretReference {
		if err := c.store.DeleteSecret(previous); err != nil {
			c.logf("deleting a superseded secret record failed")
		}
	}
	if saved, err := c.cache.Load(plan.account); err == nil {
		c.applySavedLocked(saved)
	}
	c.notifyLocked()
	plan.config, plan.hash, plan.secretRef = option.config, option.hash, reference
	return plan, nil
}

// startOutcome selects the started client like macOS. A start that ran but
// could not save its selection or intent carries selection_not_saved
func (c *Controller) startOutcome(identifier, account string, epoch uint64, started bool, saved bool) ipc.Outcome {
	outcome := ipc.Outcome{Kind: ipc.OutcomeAlreadyActive, Identifier: identifier}
	if started {
		outcome.Kind = ipc.OutcomeStartRequested
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.epoch != epoch || c.user != account {
		outcome.Warning = ipc.WarningSelectionNotSaved
		return outcome
	}
	if err := c.cache.Select(identifier, account); err != nil {
		saved = false
	} else if snapshot, err := c.cache.Load(account); err == nil {
		c.applySavedLocked(snapshot)
		c.notifyLocked()
	}
	if !saved {
		outcome.Warning = ipc.WarningSelectionNotSaved
	}
	return outcome
}

func (c *Controller) runConnect(ctx context.Context, identifier, account string, epoch uint64, mode ipc.Mode) ipc.Outcome {
	plan, err := c.prepareStart(ctx, identifier, account, epoch, mode)
	if err != nil {
		return failedOutcome(failure(err))
	}
	started, err := c.startTunnel(context.Background(), plan, 0)
	if err != nil && !errors.Is(err, errIntentNotSaved) {
		return failedOutcome(failure(err))
	}
	return c.startOutcome(identifier, account, epoch, started, err == nil)
}

// runSetMode ports setMode: disconnected saves the preference, and connected
// restarts the same client in the new mode
func (c *Controller) runSetMode(ctx context.Context, mode ipc.Mode, account string, epoch uint64) ipc.Outcome {
	obs := c.observe(context.Background())
	// Like macOS when installedProfiles throws, an unproven state is not evidence for a mode change
	if obs.Freshness != network.FreshnessCurrent {
		return failedOutcome(ipc.CommandVPNFailed)
	}
	intent := c.currentIntent()
	active := ""
	if (intent.Phase == store.PhaseRunning || intent.Phase == store.PhaseStarting) &&
		(obs.State == network.StateConnected || obs.State == network.StateConnecting || obs.State == network.StateDisconnecting) {
		active = intent.ProfileID
	}
	c.mu.Lock()
	if c.epoch != epoch || c.user != account {
		c.mu.Unlock()
		return failedOutcome(ipc.CommandSignInRequired)
	}
	sameMode := c.selectedMode != nil && *c.selectedMode == mode
	switch {
	case active != "" && (!belongs(active, account) || !c.hasConnectableLocked(active, account)):
		c.mu.Unlock()
		return failedOutcome(ipc.CommandConfigUnavailable)
	case active != "" && sameMode && intent.Mode == mode &&
		(obs.State == network.StateConnected || obs.State == network.StateConnecting):
		c.mu.Unlock()
		return ipc.Outcome{Kind: ipc.OutcomeAlreadyActive, Identifier: active}
	case active == "" && sameMode:
		c.mu.Unlock()
		return ipc.Outcome{Kind: ipc.OutcomeCompleted}
	}
	err := c.cache.SelectMode(mode, account)
	if err == nil {
		c.selectedMode = &mode
		c.notifyLocked()
	}
	c.mu.Unlock()
	if err != nil {
		return failedOutcome(failure(err))
	}
	if active == "" {
		return ipc.Outcome{Kind: ipc.OutcomeCompleted}
	}
	return c.runConnect(ctx, active, account, epoch, mode)
}

// runDisconnect stops only the named client. It never falls back to a global down
func (c *Controller) runDisconnect(identifier, account string, epoch uint64) ipc.Outcome {
	authorize := func() ipc.CommandFailure {
		c.mu.Lock()
		defer c.mu.Unlock()
		switch {
		case c.epoch != epoch || c.user != account:
			return ipc.CommandSignInRequired
		case !c.hasInventory || c.countClientsLocked(identifier) != 1:
			return ipc.CommandConfigUnavailable
		}
		return ""
	}
	if failure := authorize(); failure != "" {
		return failedOutcome(failure)
	}
	obs := c.observe(context.Background())
	// A stale or missing observation cannot prove the client already stopped
	if obs.Freshness != network.FreshnessCurrent {
		return failedOutcome(ipc.CommandVPNFailed)
	}
	intent := c.currentIntent()
	c.mu.Lock()
	resuming := c.resume != nil && c.resume.identifier == identifier
	c.mu.Unlock()
	if obs.ProfileID != identifier && !resuming &&
		(intent.ProfileID != identifier || intent.Phase == store.PhaseStopped || obs.State == network.StateDisconnected) {
		return ipc.Outcome{Kind: ipc.OutcomeCompleted}
	}
	if failure := authorize(); failure != "" {
		return failedOutcome(failure)
	}
	return c.stop()
}

// requireInactive needs a fresh current observation that shows identifier
// neither running nor changing. Anything unobservable counts as active
func (c *Controller) requireInactive(ctx context.Context, identifier string) error {
	ctx, cancel := context.WithTimeout(ctx, observeTimeout)
	defer cancel()
	obs, err := c.net.Observe(ctx)
	c.setObservation(obs)
	if err != nil || obs.Freshness != network.FreshnessCurrent || obs.ProfileID == identifier {
		return errClientActive
	}
	if intent := c.currentIntent(); intent.ProfileID == identifier && obs.State != network.StateDisconnected {
		return errClientActive
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.resume != nil && c.resume.identifier == identifier {
		return errClientActive
	}
	return nil
}

// runRemove ports removeClient: fresh authorization, one exact inactive
// target, durable eviction before dispatch, and success that cleanup or
// refresh warnings never undo. Retained secret records stay
func (c *Controller) runRemove(ctx context.Context, identifier, account string, generation, epoch, fence uint64) ipc.Outcome {
	authorize := func() error {
		c.mu.Lock()
		defer c.mu.Unlock()
		if c.epoch != epoch || c.fence != fence || c.user != account || c.closing {
			return errCancelled
		}
		return nil
	}
	tokens := c.tokenSource(generation)
	var dispatched, removed, cleanedUp bool
	err := func() error {
		if err := authorize(); err != nil {
			return err
		}
		access, err := c.cloud.CheckAccess(ctx, account, tokens)
		if err != nil {
			return err
		}
		if err := c.observeRole(access.Role, account, authorize); err != nil {
			return err
		}
		inventory, err := c.cloud.FetchInventory(ctx, account, access.Role, tokens)
		if err != nil {
			return err
		}
		if err := authorize(); err != nil {
			return err
		}
		var matches []cloud.ClientDoc
		for _, option := range inventory.Options {
			if account+"/"+option.Client.RegionID+"/"+option.Client.ClientID == identifier {
				matches = append(matches, option.Client)
			}
		}
		c.mu.Lock()
		alreadyRemoved := c.removed[identifier]
		c.mu.Unlock()
		if alreadyRemoved || len(matches) != 1 || matches[0].Status == cloud.StatusRemoved || strings.TrimSpace(matches[0].OwnerUID) == "" {
			return errConfigUnavailable
		}
		target := matches[0]
		if access.Role != cloud.RoleAdmin && target.OwnerUID != account {
			return errForeignOwner
		}
		if err := c.requireInactive(ctx, identifier); err != nil {
			return err
		}
		if err := authorize(); err != nil {
			return err
		}
		c.mu.Lock()
		saved, err := c.cache.Evict(identifier, account)
		if err == nil {
			c.applySavedLocked(saved)
			c.rows = slices.DeleteFunc(c.rows, func(r row) bool { return r.identifier == identifier })
			c.notifyLocked()
		}
		c.mu.Unlock()
		if err != nil {
			return err
		}
		idToken, err := tokens(ctx, false)
		if err != nil {
			return err
		}
		if err := authorize(); err != nil {
			return err
		}
		if err := c.requireInactive(ctx, identifier); err != nil {
			return err
		}
		if err := c.cloud.DeleteClient(ctx, target.RegionID, target.ClientID, target.OwnerUID, idToken); err != nil {
			if e, ok := errors.AsType[*cloud.Error](err); ok && e.Dispatched {
				dispatched = true
			}
			return err
		}
		dispatched, removed = true, true
		c.mu.Lock()
		if c.epoch == epoch && c.fence == fence {
			c.removed[identifier] = true
		}
		c.mu.Unlock()
		if err := authorize(); err != nil {
			return err
		}
		cleanedUp = c.requireInactive(ctx, identifier) == nil
		if err := authorize(); err != nil {
			return err
		}
		return c.refreshAfterMutation(ctx, account, tokens, authorize)
	}()
	if err == nil {
		if cleanedUp {
			return ipc.Outcome{Kind: ipc.OutcomeCompleted}
		}
		return ipc.Outcome{Kind: ipc.OutcomeCompleted, Warning: ipc.WarningLocalCleanupIncomplete}
	}
	denied := classify(err) == failDenied || errors.Is(err, errForeignOwner)
	isCurrent := authorize() == nil
	var outcome ipc.Outcome
	switch {
	case removed && cleanedUp && isCurrent:
		outcome = ipc.Outcome{Kind: ipc.OutcomeCompleted, Warning: ipc.WarningInventoryNotRefreshed}
	case removed:
		outcome = ipc.Outcome{Kind: ipc.OutcomeCompleted, Warning: ipc.WarningLocalCleanupIncomplete}
	case denied:
		outcome = failedOutcome(ipc.CommandAccessDenied)
	case dispatched:
		outcome = ipc.Outcome{Kind: ipc.OutcomeUnknown}
	default:
		outcome = failedOutcome(commandFailure(err))
	}
	if isCurrent && denied {
		if removed {
			outcome = ipc.Outcome{Kind: ipc.OutcomeCompleted, Warning: ipc.WarningLocalCleanupIncomplete}
		}
		c.mu.Lock()
		c.denyLocked(account)
		c.mu.Unlock()
	}
	return outcome
}

// commandFailure maps a failure before any cloud write: cloud errors are
// network_unavailable unless the session changed
func commandFailure(err error) ipc.CommandFailure {
	if classify(err) == failCancelled {
		return ipc.CommandSignInRequired
	}
	if _, ok := errors.AsType[*cloud.Error](err); ok {
		return ipc.CommandNetworkUnavailable
	}
	return failure(err)
}

func (c *Controller) observeRole(role cloud.Role, account string, authorize func() error) error {
	if err := authorize(); err != nil {
		return err
	}
	c.mu.Lock()
	err := c.observeRoleLocked(role, account)
	c.mu.Unlock()
	if err != nil {
		return err
	}
	return authorize()
}

// refreshAfterMutation checks access again and publishes a complete inventory
func (c *Controller) refreshAfterMutation(ctx context.Context, account string, tokens cloud.TokenSource, authorize func() error) error {
	access, err := c.cloud.CheckAccess(ctx, account, tokens)
	if err != nil {
		return err
	}
	if err := c.observeRole(access.Role, account, authorize); err != nil {
		return err
	}
	inventory, err := c.cloud.FetchInventory(ctx, account, access.Role, tokens)
	if err != nil {
		return err
	}
	rows := buildRows(account, inventory)
	if err := authorize(); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.publishLocked(rows, access.Role, account); err != nil {
		return err
	}
	c.schedule.complete(c.now(), true, c.jitter())
	return nil
}

// runCreate ports createClient. Any failure after the request may have
// reached the server is unknown, and nothing is ever resent
func (c *Controller) runCreate(ctx context.Context, regionID, name, account string, generation, epoch, fence uint64) ipc.Outcome {
	authorize := func() error {
		c.mu.Lock()
		defer c.mu.Unlock()
		if c.epoch != epoch || c.fence != fence || c.user != account || c.closing {
			return errCancelled
		}
		return nil
	}
	tokens := c.tokenSource(generation)
	var attempted, created bool
	err := func() error {
		if err := authorize(); err != nil {
			return err
		}
		access, err := c.cloud.CheckAccess(ctx, account, tokens)
		if err != nil {
			return err
		}
		if err := c.observeRole(access.Role, account, authorize); err != nil {
			return err
		}
		idToken, err := tokens(ctx, false)
		if err != nil {
			return err
		}
		if err := authorize(); err != nil {
			return err
		}
		attempted = true
		if _, err := c.cloud.CreateClient(ctx, regionID, name, idToken); err != nil {
			if e, ok := errors.AsType[*cloud.Error](err); !ok || !e.Dispatched {
				attempted = false
			}
			return err
		}
		created = true
		if err := authorize(); err != nil {
			return err
		}
		return c.refreshAfterMutation(ctx, account, tokens, authorize)
	}()
	denied := classify(err) == failDenied
	if denied && authorize() == nil {
		c.mu.Lock()
		c.denyLocked(account)
		c.mu.Unlock()
	}
	switch {
	case err == nil:
		return ipc.Outcome{Kind: ipc.OutcomeCompleted}
	case created:
		return ipc.Outcome{Kind: ipc.OutcomeCompleted, Warning: ipc.WarningInventoryNotRefreshed}
	case denied:
		return failedOutcome(ipc.CommandAccessDenied)
	case attempted:
		return ipc.Outcome{Kind: ipc.OutcomeUnknown}
	}
	if code := commandFailure(err); code != ipc.CommandVPNFailed {
		return failedOutcome(code)
	}
	return failedOutcome(ipc.CommandInternalError)
}

// prepareClient loads enabled regions and capacity within 22 seconds and
// keeps the result as a creation context for 300 seconds
func (c *Controller) prepareClient(parent context.Context) ipc.Reply {
	if command, creation := c.registry.Busy(); command || creation {
		return ipc.Reply{Error: ipc.FailureBusy}
	}
	c.mu.Lock()
	if c.preparing || c.draining || c.closing || c.updatePendingLocked() {
		c.mu.Unlock()
		return ipc.Reply{Error: ipc.FailureBusy}
	}
	if !c.canMutateInventoryLocked() {
		c.mu.Unlock()
		return ipc.Reply{Error: ipc.FailureUnavailable}
	}
	c.preparing = true
	account, generation, epoch, fence, session := c.user, c.creds.Generation, c.epoch, c.fence, c.sessionLocked()
	ctx, cancel := context.WithTimeout(c.accountCtx, prepareTimeout)
	c.prepareCancel = cancel
	c.mu.Unlock()
	defer cancel()
	stop := context.AfterFunc(parent, cancel)
	defer stop()
	regions, err := c.loadCreationRegions(ctx, c.tokenSource(generation))
	c.mu.Lock()
	defer c.mu.Unlock()
	c.preparing, c.prepareCancel = false, nil
	c.notifyLocked()
	current := c.epoch == epoch && c.fence == fence && c.user == account
	if err != nil {
		if current && classify(err) == failDenied {
			c.denyLocked(account)
		}
		if parent.Err() != nil || c.closing {
			return ipc.Reply{Error: ipc.FailurePreparationExpired}
		}
		return ipc.Reply{Error: ipc.FailureUnavailable}
	}
	if !current || c.draining || c.closing {
		return ipc.Reply{Error: ipc.FailurePreparationExpired}
	}
	c.creation = &creationContext{id: newUUID(), regions: regions, expires: c.now().Add(creationLifetime), session: session}
	return ipc.Reply{Creation: &ipc.Creation{ID: c.creation.id, Regions: slices.Clone(regions)}}
}

// loadCreationRegions ports CloudGatewayMacCapacityPreparation. Capacity
// that cannot be read stays unknown, while an access denial fails
func (c *Controller) loadCreationRegions(ctx context.Context, tokens cloud.TokenSource) ([]ipc.CreationRegion, error) {
	regions, err := c.cloud.ListRegions(ctx)
	if err != nil {
		return nil, err
	}
	result := make([]ipc.CreationRegion, len(regions))
	for i, region := range regions {
		result[i] = ipc.CreationRegion{RegionID: region.RegionID, DisplayName: region.DisplayName, Enabled: region.Enabled,
			DisplayOrder: region.DisplayOrder, Capacity: &ipc.Capacity{}}
	}
	if len(regions) == 0 {
		return result, nil
	}
	if _, err := tokens(ctx, false); err != nil {
		switch classify(err) {
		case failDenied, failSignIn:
			return nil, err
		}
		return result, nil
	}
	capacityCtx, cancel := context.WithTimeout(ctx, capacityTimeout)
	defer cancel()
	var mu sync.Mutex
	var denial error
	var wg sync.WaitGroup
	slots := make(chan struct{}, maxCapacityReads)
	for i := range regions {
		wg.Go(func() {
			slots <- struct{}{}
			defer func() { <-slots }()
			capacity, err := c.cloud.FetchCapacity(capacityCtx, regions[i].RegionID, tokens)
			mu.Lock()
			defer mu.Unlock()
			switch {
			case classify(err) == failDenied:
				denial = err
			case err == nil:
				result[i].Capacity = &ipc.Capacity{Known: capacity.Known, Limit: capacity.Limit, Allocated: capacity.Allocated}
			}
		})
	}
	wg.Wait()
	if denial != nil {
		return nil, denial
	}
	return result, nil
}
