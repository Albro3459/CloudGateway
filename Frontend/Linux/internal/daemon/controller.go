package daemon

import (
	"context"
	"errors"
	"io"
	"log"
	"math/rand/v2"
	"net"
	"net/http"
	"net/netip"
	"sync"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/cloud"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
)

// Cloud is the part of *cloud.Client the controller uses
type Cloud interface {
	RequestDeviceCode(ctx context.Context, secret *cloud.DeviceSecret) (cloud.DeviceCode, error)
	PollDeviceToken(ctx context.Context, requestID string, secret *cloud.DeviceSecret) (cloud.DevicePoll, error)
	SignInWithCustomToken(ctx context.Context, customToken cloud.Secret) (cloud.Session, error)
	RefreshSession(ctx context.Context, refreshToken cloud.Secret) (cloud.Session, error)
	CheckAccess(ctx context.Context, uid string, tokens cloud.TokenSource) (cloud.Access, error)
	FetchInventory(ctx context.Context, uid string, role cloud.Role, tokens cloud.TokenSource) (cloud.Inventory, error)
	ListRegions(ctx context.Context) ([]cloud.Region, error)
	FetchCapacity(ctx context.Context, regionID string, tokens cloud.TokenSource) (cloud.Capacity, error)
	CreateClient(ctx context.Context, regionID, clientName string, idToken cloud.Secret) (cloud.CreatedClient, error)
	DeleteClient(ctx context.Context, regionID, clientID, ownerUID string, idToken cloud.Secret) error
	CloseIdleConnections()
}

// Releases reports the running release and the one installed under the current link
type Releases interface {
	Running() ipc.BuildIdentity
	Installed() (ipc.BuildIdentity, error)
}

type Options struct {
	Store    *store.Store
	Cloud    Cloud
	Releases Releases
	// Network configures the network manager. The controller supplies Journal, Persist, and Now
	Network network.Options
	Now     func() time.Time
	// Sleep waits between login polls and boot resume retries
	Sleep  func(ctx context.Context, d time.Duration) error
	Jitter func() float64
	// HTTPGet reads one URL for doctor without following redirects
	HTTPGet func(ctx context.Context, url string) (int, []byte, error)
	Logf    func(format string, args ...any)
}

const (
	refreshTimeout     = 25 * time.Second
	prepareTimeout     = 22 * time.Second
	capacityTimeout    = 20 * time.Second
	creationLifetime   = 300 * time.Second
	serverCheckTimeout = 2500 * time.Millisecond
	observeTimeout     = 3 * time.Second
	watchInterval      = 30 * time.Second
	tickInterval       = 15 * time.Second
)

// job is one background read the controller can join or cancel
type job struct {
	done   chan struct{}
	cancel context.CancelFunc
	epoch  uint64
}

type refreshOutcome struct {
	epoch  uint64
	result ipc.RefreshResult
}

type creationContext struct {
	id      string
	regions []ipc.CreationRegion
	expires time.Time
	session SessionToken
}

// Controller ports CloudGatewayMacController and its orchestrator onto one
// root daemon. mu guards account, inventory, and command state. netMu
// serializes every network effect, and intentMu guards the durable intent.
// Lock order is netMu, then mu, then intentMu. The registry may call back
// into the controller, so the controller never calls the registry while
// holding mu
type Controller struct {
	store    *store.Store
	cache    *store.AccountCache
	cloud    Cloud
	releases Releases
	net      *network.Manager
	exec     network.Executor
	lookup   func(context.Context, string) ([]netip.Addr, error)
	httpGet  func(context.Context, string) (int, []byte, error)
	registry *Registry
	now      func() time.Time
	sleep    func(context.Context, time.Duration) error
	jitter   func() float64
	logf     func(string, ...any)

	ctx    context.Context
	cancel context.CancelFunc
	// work tracks commands, which Close waits for before cancelling ctx
	work  sync.WaitGroup
	loops sync.WaitGroup
	// stopLoops ends background loops on Close
	loopCtx   context.Context
	stopLoops context.CancelFunc
	exit      chan struct{}
	exitOnce  sync.Once

	netMu sync.Mutex

	intentMu sync.Mutex
	intent   store.Intent
	// desired is the revision of the latest intent change. Journal writes do not move it
	desired uint64
	// unsaved means intent holds a running or stopped phase its save failed to persist
	unsaved bool

	tokenMu sync.Mutex

	mu      sync.Mutex
	changed chan struct{}
	closing bool
	// draining means a confirmed update is restarting the daemon
	draining bool

	creds          *store.Credentials
	idToken        cloud.Secret
	idTokenExpires time.Time
	user           string
	accessResult   ipc.AccessState
	// epoch is macOS's sessionEpoch. fence is its session fence epoch
	epoch         uint64
	fence         uint64
	accountCtx    context.Context
	accountCancel context.CancelFunc
	restore       *job
	login         *loginAttempt
	lastLogin     *ipc.LoginStatus
	retained      *retainedLogin

	rows              []row
	removed           map[string]bool
	installed         []store.InstalledConfig
	selected          string
	selectedMode      *ipc.Mode
	isOffline         bool
	hasInventory      bool
	readAt            time.Time
	refresh           *job
	inventoryEpoch    uint64
	refreshResult     refreshOutcome
	deferred          bool
	deferredAutomatic bool
	schedule          schedule
	inventoryFailure  string
	// signingOut keeps a login from committing while logout runs
	signingOut bool

	// commands counts running commands and creation. stops counts running stops
	commands      int
	stops         int
	preparing     bool
	prepareCancel context.CancelFunc
	creation      *creationContext

	obs    network.Observation
	resume *resumeState

	update *store.UpdateRecord
}

// NewController loads durable state and reconciles owned network resources.
// Call Start to begin background work
func NewController(opts Options) (*Controller, error) {
	if opts.Store == nil || opts.Cloud == nil || opts.Releases == nil {
		return nil, errors.New("daemon: controller needs a store, cloud client, and release identity")
	}
	ctx, cancel := context.WithCancel(context.Background())
	loopCtx, stopLoops := context.WithCancel(ctx)
	c := &Controller{
		store: opts.Store, cache: opts.Store.Accounts(), cloud: opts.Cloud, releases: opts.Releases,
		exec: opts.Network.Executor, lookup: opts.Network.LookupHost, httpGet: opts.HTTPGet,
		now: opts.Now, sleep: opts.Sleep, jitter: opts.Jitter, logf: opts.Logf,
		ctx: ctx, cancel: cancel, loopCtx: loopCtx, stopLoops: stopLoops, exit: make(chan struct{}),
		changed: make(chan struct{}), removed: map[string]bool{},
		obs: network.Observation{State: network.StateUnknown, Freshness: network.FreshnessUnavailable},
	}
	if c.exec == nil {
		c.exec = network.SystemExecutor{}
	}
	if c.lookup == nil {
		c.lookup = func(ctx context.Context, host string) ([]netip.Addr, error) {
			return net.DefaultResolver.LookupNetIP(ctx, "ip", host)
		}
	}
	if c.httpGet == nil {
		c.httpGet = httpGet
	}
	if c.now == nil {
		c.now = time.Now
	}
	if c.sleep == nil {
		c.sleep = sleep
	}
	if c.jitter == nil {
		c.jitter = rand.Float64
	}
	if c.logf == nil {
		c.logf = log.Printf
	}
	c.accountCtx, c.accountCancel = context.WithCancel(ctx)
	c.schedule = newSchedule(c.now())

	data, err := c.store.LoadReceipts()
	if err != nil && !errors.Is(err, store.ErrMissing) {
		c.logf("operation receipts unreadable, starting without them")
	}
	if c.registry, err = NewRegistry(data, c.now, c.store.SaveReceipts); err != nil {
		c.logf("operation receipts malformed, starting without them")
		if c.registry, err = NewRegistry(nil, c.now, c.store.SaveReceipts); err != nil {
			cancel()
			return nil, err
		}
	}
	c.loadUpdate()
	journal, unreadable := c.loadIntent()
	netOpts := opts.Network
	netOpts.Executor, netOpts.LookupHost, netOpts.Now = c.exec, c.lookup, c.now
	netOpts.Journal, netOpts.Persist = journal, c.persistJournal
	c.net = network.New(netOpts)
	c.loadSession()
	c.adopt(unreadable)
	return c, nil
}

// Start restores a retained session and begins inventory scheduling,
// network watching, and any boot resume
func (c *Controller) Start() {
	c.mu.Lock()
	c.restoreSessionLocked()
	resume := c.resume
	c.mu.Unlock()
	c.loops.Go(func() { c.watchNetwork(c.loopCtx) })
	c.loops.Go(func() {
		ticker := time.NewTicker(tickInterval)
		defer ticker.Stop()
		for {
			select {
			case <-c.loopCtx.Done():
				return
			case <-ticker.C:
				c.tick()
			}
		}
	})
	if resume != nil {
		c.loops.Go(func() { c.runResume(c.loopCtx, resume) })
	}
}

// Exit closes once a confirmed update needs the daemon to restart onto the installed release
func (c *Controller) Exit() <-chan struct{} { return c.exit }

// Drain refuses new work, stops background loops, and cancels inventory,
// restore, login, and creation preparation reads. Running commands keep
// going. It is safe to call twice
func (c *Controller) Drain() {
	c.mu.Lock()
	c.closing = true
	if c.refresh != nil {
		c.refresh.cancel()
		c.refresh = nil
	}
	if c.restore != nil {
		c.restore.cancel()
		c.restore = nil
	}
	if c.login != nil {
		c.finishLoginLocked(c.login.id, ipc.LoginCancelled)
	}
	if c.retained != nil {
		c.retained.cancel()
	}
	if c.prepareCancel != nil {
		c.prepareCancel()
	}
	c.deferred, c.resume = false, nil
	c.notifyLocked()
	c.mu.Unlock()
	c.stopLoops()
}

// Close drains, then waits for running commands until ctx ends and cancels
// remaining cloud requests. It never touches the tunnel, and a network change
// still running at the bound finishes or dies with the process, leaving its
// journal for the next start
func (c *Controller) Close(ctx context.Context) {
	c.Drain()
	done := make(chan struct{})
	go func() {
		c.work.Wait()
		c.loops.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-ctx.Done():
	}
	c.cancel()
}

func (c *Controller) Handle(ctx context.Context, _ Peer, request ipc.Request) ipc.Reply {
	switch request.Action {
	case ipc.ActionHandshake:
		// Any CLI version can read the latest operation's coarse state. Outcomes stay with status
		reply := ipc.Reply{Lifecycle: c.lifecycle(ctx), Operation: c.registry.Latest()}
		if reply.Operation == nil {
			c.mu.Lock()
			if status := c.updateStatusLocked(); status != nil {
				operation := status.Operation()
				reply.Operation = &operation
			}
			c.mu.Unlock()
		}
		return reply
	case ipc.ActionDiagnostics:
		return ipc.Reply{Check: c.diagnose(ctx, request.Probe)}
	}
	switch request.Action {
	case ipc.ActionUserActivity, ipc.ActionConnect, ipc.ActionTurnOff, ipc.ActionDisconnectClient, ipc.ActionSignOut,
		ipc.ActionAwaitRefresh, ipc.ActionPrepareClient, ipc.ActionCreateClient, ipc.ActionRemoveClient,
		ipc.ActionBeginLogin, ipc.ActionCancelLogin, ipc.ActionUpdate, ipc.ActionSetMode:
		c.recordActivity(request.Action == ipc.ActionUserActivity)
	}
	switch request.Action {
	case ipc.ActionSnapshot:
		return c.reply(ctx, request.CheckServer)
	case ipc.ActionUserActivity:
		return ipc.Reply{}
	case ipc.ActionOperation:
		return c.operationReply(ctx, request.ContextID)
	case ipc.ActionConfirm:
		return c.confirm(ctx, request.ContextID)
	case ipc.ActionAwaitRefresh:
		return c.awaitRefresh(ctx)
	case ipc.ActionBeginLogin:
		return ipc.Reply{Login: c.beginLogin(request.ID)}
	case ipc.ActionLoginStatus:
		return ipc.Reply{Login: c.loginStatus(request.ContextID)}
	case ipc.ActionCancelLogin:
		return ipc.Reply{Login: c.cancelLogin(request.ContextID)}
	case ipc.ActionPrepareClient:
		return c.prepareClient(ctx)
	case ipc.ActionUpdate:
		return c.reserveUpdate(ctx, request)
	}
	if request.Action.RequiresConfirmation() {
		return c.reserve(ctx, request)
	}
	return ipc.Reply{Error: ipc.FailureInvalidRequest}
}

func (c *Controller) lifecycle(ctx context.Context) *ipc.Lifecycle {
	lifecycle := &ipc.Lifecycle{Running: c.releases.Running(), State: ipc.LifecycleCurrent}
	if installed, err := c.releases.Installed(); err == nil {
		lifecycle.Installed = &installed
	} else {
		lifecycle.State = ipc.LifecycleInvalidInstallation
	}
	obs := c.observe(ctx)
	c.mu.Lock()
	if c.draining {
		lifecycle.State = ipc.LifecycleDraining
	}
	tunnel := c.tunnelLocked(obs)
	c.mu.Unlock()
	lifecycle.Tunnel = ipc.Tunnel{Phase: tunnel.Phase, Observation: tunnel.Observation}
	return lifecycle
}

// reply is the snapshot reply: state, the latest operation, and any retained update
func (c *Controller) reply(ctx context.Context, checkServer bool) ipc.Reply {
	c.resumeDeferredIfIdle()
	state := c.state(ctx, checkServer)
	reply := ipc.Reply{State: &state}
	session := c.session()
	if operation := c.registry.Latest(); operation != nil {
		reply.Operation = operation
		reply.Outcome = c.registry.Outcome(operation.ID, session)
	}
	c.mu.Lock()
	status := c.updateStatusLocked()
	c.mu.Unlock()
	if status != nil {
		reply.Update = status
		if reply.Operation == nil {
			operation := status.Operation()
			reply.Operation = &operation
		}
	}
	return reply
}

func (c *Controller) operationReply(ctx context.Context, id string) ipc.Reply {
	state := c.state(ctx, false)
	reply := ipc.Reply{State: &state}
	c.mu.Lock()
	status := c.updateStatusLocked()
	c.mu.Unlock()
	if status != nil && status.ID == id {
		operation := status.Operation()
		reply.Operation, reply.Update = &operation, status
		return reply
	}
	operation := c.registry.Operation(id)
	reply.Operation = &operation
	reply.Outcome = c.registry.Outcome(id, c.session())
	return reply
}

// observe refreshes the cached observation
func (c *Controller) observe(parent context.Context) network.Observation {
	ctx, cancel := context.WithTimeout(parent, observeTimeout)
	defer cancel()
	obs, _ := c.net.Observe(ctx)
	// A caller that hung up cut the read short, so its stale result doesn't replace the last one
	if parent.Err() == nil {
		c.setObservation(obs)
	}
	return obs
}

func (c *Controller) setObservation(obs network.Observation) {
	c.mu.Lock()
	c.obs = obs
	c.notifyLocked()
	c.mu.Unlock()
}

// state composes the account-filtered view like CloudGatewayMacControllerState
func (c *Controller) state(ctx context.Context, checkServer bool) ipc.State {
	obs := c.observe(ctx)
	var responding *bool
	if checkServer && obs.State == network.StateConnected {
		checkCtx, cancel := context.WithTimeout(ctx, serverCheckTimeout)
		if ok, err := c.net.ServerResponding(checkCtx); err == nil {
			responding = &ok
		}
		cancel()
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	state := ipc.State{
		HasRetainedSession: c.creds != nil,
		IsRestoring:        c.restore != nil,
		AccessAuthorized:   c.user != "",
		Access:             c.accessLocked(),
		Credentials:        "unknown",
		LoginPending:       c.login != nil,
		Inventory:          c.freshnessLocked(),
		Tunnel:             c.tunnelLocked(obs),
		CreationAllowed:    c.canMutateInventoryLocked(),
		ServerResponding:   responding,
	}
	state.Clients = c.clientsLocked(obs, state.Tunnel.Phase)
	if c.creds != nil {
		state.Credentials = "available"
	}
	if c.user != "" {
		user := c.user
		state.AccountID = &user
		if belongs(c.selected, c.user) {
			selected := c.selected
			state.SelectedIdentifier = &selected
		}
		if c.selectedMode != nil {
			mode := *c.selectedMode
			state.SelectedMode = &mode
		}
	}
	if obs.State == network.StateConnected && obs.Freshness == network.FreshnessCurrent && obs.ActiveMode != "" {
		mode := ipc.Mode(obs.ActiveMode)
		state.ActiveMode = &mode
	}
	return state
}

func (c *Controller) accessLocked() ipc.AccessState {
	switch {
	case c.user != "" && c.isOffline:
		return ipc.AccessOffline
	case c.user != "":
		return ipc.AccessOnline
	case c.restore != nil:
		return ipc.AccessChecking
	case c.accessResult != "":
		return c.accessResult
	}
	return ipc.AccessUnverified
}

func (c *Controller) freshnessLocked() ipc.InventoryFreshness {
	switch {
	case c.refresh != nil || c.deferred:
		return ipc.InventoryRefreshing
	case !c.hasInventory:
		return ipc.InventoryUnavailable
	case c.isOffline:
		return ipc.InventoryCached
	}
	return ipc.InventoryCurrent
}

// activeProfileLocked is the profile the tunnel state describes, from the
// observation when connected and from the intent while it changes
func (c *Controller) activeProfileLocked(obs network.Observation) string {
	if obs.ProfileID != "" {
		return obs.ProfileID
	}
	if c.resume != nil && obs.State == network.StateDisconnected {
		return c.resume.identifier
	}
	intent := c.currentIntent()
	if obs.State == network.StateDisconnected || intent.Phase == store.PhaseStopped {
		return ""
	}
	return intent.ProfileID
}

// tunnelLocked maps the observation onto the research table. Boot resume
// reports connecting while it waits, and another account's profile is redacted
func (c *Controller) tunnelLocked(obs network.Observation) ipc.Tunnel {
	tunnel := ipc.Tunnel{Phase: ipc.TunnelPhase(obs.State), Observation: ipc.Observation(obs.Freshness)}
	if c.resume != nil && obs.State == network.StateDisconnected {
		tunnel.Phase = ipc.TunnelConnecting
	}
	if !obs.ObservedAt.IsZero() {
		observed := obs.ObservedAt.UTC()
		tunnel.ObservedAt = &observed
	}
	if profile := c.activeProfileLocked(obs); belongs(profile, c.user) {
		tunnel.ConfigID = &profile
	}
	return tunnel
}

func (c *Controller) session() SessionToken {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.sessionLocked()
}

func (c *Controller) sessionLocked() SessionToken {
	if c.user == "" {
		return SessionToken{}
	}
	return SessionToken{AccountID: c.user, Generation: c.fence}
}

func (c *Controller) notifyLocked() {
	close(c.changed)
	c.changed = make(chan struct{})
}

// waitFor blocks until done, checked under mu, reports true or ctx ends
func (c *Controller) waitFor(ctx context.Context, done func() bool) bool {
	for {
		c.mu.Lock()
		if done() {
			c.mu.Unlock()
			return true
		}
		changed := c.changed
		c.mu.Unlock()
		select {
		case <-changed:
		case <-ctx.Done():
			return false
		}
	}
}

func waitJob(ctx context.Context, j *job) bool {
	select {
	case <-j.done:
		return true
	case <-ctx.Done():
		return false
	}
}

func sleep(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// httpGet reads at most 64 KiB and never follows redirects
func httpGet(ctx context.Context, url string) (int, []byte, error) {
	client := &http.Client{
		Timeout:       4 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	defer client.CloseIdleConnections()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	return resp.StatusCode, body, err
}
