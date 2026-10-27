package daemon

import (
	"cmp"
	"context"
	"math"
	"net/netip"
	"slices"
	"strings"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/cloud"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/wgconfig"
)

const (
	offlineRegionOrder = 1000
	eligible           = "eligible"
)

// schedule ports CloudGatewayMacInventorySchedule
type schedule struct {
	lastActivity   time.Time
	lastSuccess    time.Time
	lastCompletion time.Time
	retryAfter     time.Time
	failures       int
}

func newSchedule(now time.Time) schedule { return schedule{lastActivity: now} }

func (s *schedule) activity(now time.Time) { s.lastActivity = now }

func (s *schedule) stale(now time.Time) bool {
	return s.lastSuccess.IsZero() || now.Sub(s.lastSuccess) >= 60*time.Second
}

func (s *schedule) idle(now time.Time) bool { return now.Sub(s.lastActivity) >= 900*time.Second }

func (s *schedule) due(now time.Time) bool {
	if s.idle(now) {
		return false
	}
	if !s.retryAfter.IsZero() {
		return !now.Before(s.retryAfter)
	}
	interval := 60 * time.Second
	if now.Sub(s.lastActivity) >= 120*time.Second {
		interval = 300 * time.Second
	}
	return s.lastCompletion.IsZero() || now.Sub(s.lastCompletion) >= interval
}

func (s *schedule) complete(now time.Time, succeeded bool, jitter float64) {
	s.lastCompletion = now
	if succeeded {
		s.lastSuccess, s.failures, s.retryAfter = now, 0, time.Time{}
		return
	}
	s.failures = min(s.failures+1, 5)
	seconds := min(900, 60*math.Pow(2, float64(s.failures-1))*(0.8+0.4*min(1, max(0, jitter))))
	s.retryAfter = now.Add(time.Duration(seconds * float64(time.Second)))
}

func (s *schedule) reset() {
	s.lastSuccess, s.lastCompletion, s.retryAfter, s.failures = time.Time{}, time.Time{}, time.Time{}, 0
}

// row is one cloud client. Its downloaded config is parsed and dropped, so
// only the canonical config stays, in memory only
type row struct {
	option     cloud.Option
	identifier string
	usable     bool
	config     *wgconfig.Config
	hash       string
}

// eligibility ports CloudGatewayMacController.eligibility. A config the
// allowlisted parser rejects counts as missing on Linux
func (r row) eligibility() string {
	switch {
	case r.option.Client.Status != cloud.StatusActive:
		return "inactive"
	case !r.usable || r.config == nil:
		return "config_missing"
	case !r.option.RegionEnabled():
		return "region_unavailable"
	}
	return eligible
}

func buildRows(account string, inventory cloud.Inventory) []row {
	rows := make([]row, 0, len(inventory.Options))
	for _, option := range inventory.Options {
		// IDs reach terminals and config identifiers, so control characters or slashes never pass
		if !store.ValidComponent(option.Client.RegionID) || !store.ValidComponent(option.Client.ClientID) {
			continue
		}
		r := row{option: option, identifier: account + "/" + option.Client.RegionID + "/" + option.Client.ClientID,
			usable: option.Client.HasUsableConfig()}
		if r.usable {
			if config, err := wgconfig.Parse(string(option.Client.WireGuardConfig)); err == nil {
				r.config, r.hash = config, config.Hash()
			}
		}
		r.option.Client.WireGuardConfig = ""
		rows = append(rows, r)
	}
	return rows
}

func (c *Controller) rowLocked(identifier string) *row {
	for i := range c.rows {
		if c.rows[i].identifier == identifier {
			return &c.rows[i]
		}
	}
	return nil
}

func (c *Controller) installedLocked(identifier, account string) *store.InstalledConfig {
	for i := range c.installed {
		if c.installed[i].AccountID == account && c.installed[i].Identifier == identifier {
			return &c.installed[i]
		}
	}
	return nil
}

func (c *Controller) applySavedLocked(saved store.InventorySnapshot) {
	c.installed, c.selected, c.selectedMode = saved.Configs, saved.SelectedIdentifier, saved.SelectedMode
}

// hasConnectableLocked ports hasConnectableConfig
func (c *Controller) hasConnectableLocked(identifier, account string) bool {
	if !c.isOffline && len(c.rows) > 0 {
		r := c.rowLocked(identifier)
		return r != nil && r.eligibility() == eligible
	}
	config := c.installedLocked(identifier, account)
	return config != nil && config.Snapshot.Status == string(cloud.StatusActive)
}

// canMutateInventoryLocked ports canStartInventoryMutation
func (c *Controller) canMutateInventoryLocked() bool {
	return c.stops == 0 && c.canSubmitCreationLocked()
}

func (c *Controller) recordActivity(refreshIfStale bool) {
	command, creation := c.registry.Busy()
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closing {
		return
	}
	now := c.now()
	c.schedule.activity(now)
	if !refreshIfStale {
		return
	}
	if c.user != "" {
		if c.schedule.stale(now) || c.refresh != nil {
			c.refreshInventoryLocked(false, !command && !creation)
		}
	} else if c.creds != nil {
		c.restoreSessionLocked()
	}
}

// tick runs scheduled inventory work like refreshInventoryIfDue
func (c *Controller) tick() {
	command, creation := c.registry.Busy()
	c.mu.Lock()
	defer c.mu.Unlock()
	if !command && !creation {
		c.resumeDeferredLocked(true)
	}
	if command || creation || c.closing || c.draining || c.refresh != nil || c.restore != nil || c.commands > 0 || c.stops > 0 ||
		c.preparing || c.login != nil || c.deferred || !c.schedule.due(c.now()) {
		return
	}
	if c.user != "" {
		c.refreshInventoryLocked(true, true)
	} else if c.creds != nil {
		c.restoreSessionLocked()
	}
}

// refreshInventoryLocked ports refreshInventory. Work running a command
// defers it, and so does an automatic refresh while reservations are open
func (c *Controller) refreshInventoryLocked(force, allowAutomatic bool) {
	if c.user == "" || c.creds == nil || c.refresh != nil || c.closing {
		return
	}
	if !force && !c.schedule.stale(c.now()) {
		return
	}
	if c.commands > 0 || c.stops > 0 || !force && !allowAutomatic {
		if c.deferred {
			c.deferredAutomatic = c.deferredAutomatic && !force
		} else {
			c.deferredAutomatic = !force
		}
		c.deferred = true
		c.notifyLocked()
		return
	}
	c.deferred, c.deferredAutomatic = false, false
	c.inventoryEpoch++
	ctx, cancel := context.WithCancel(c.accountCtx)
	j := &job{done: make(chan struct{}), cancel: cancel, epoch: c.inventoryEpoch}
	c.refresh = j
	c.notifyLocked()
	go c.runRefresh(ctx, j, c.user, c.creds.Generation, c.epoch, c.fence)
}

func (c *Controller) resumeDeferredLocked(allowAutomatic bool) {
	if !c.deferred {
		return
	}
	now := c.now()
	if c.deferredAutomatic && (!c.schedule.stale(now) || c.schedule.idle(now)) {
		c.deferred, c.deferredAutomatic = false, false
		c.notifyLocked()
		return
	}
	c.refreshInventoryLocked(!c.deferredAutomatic, allowAutomatic)
}

// cancelRefreshLocked supersedes an in-flight refresh, as a start does on macOS
func (c *Controller) cancelRefreshLocked() {
	if c.refresh != nil {
		c.refresh.cancel()
		c.refresh = nil
	}
	c.inventoryEpoch++
}

func (c *Controller) runRefresh(ctx context.Context, j *job, account string, generation, epoch, fence uint64) {
	defer close(j.done)
	defer j.cancel()
	c.refreshInventory(ctx, j, account, generation, epoch, fence)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.refresh == j {
		c.refresh = nil
		if c.epoch == epoch && c.refreshResult.epoch == j.epoch {
			c.schedule.complete(c.now(), c.refreshResult.result == ipc.RefreshRefreshed, c.jitter())
		}
	}
	c.notifyLocked()
}

func (c *Controller) refreshInventory(ctx context.Context, j *job, account string, generation, epoch, fence uint64) {
	current := func() bool {
		return c.epoch == epoch && c.fence == fence && c.user == account && c.refresh == j && !c.closing
	}
	tokens := c.tokenSource(generation)
	c.mu.Lock()
	if !current() {
		c.mu.Unlock()
		return
	}
	if len(c.rows) == 0 {
		if saved, err := c.cache.Load(account); err == nil {
			c.applySavedLocked(saved)
		} else {
			c.installed, c.selected, c.selectedMode, c.hasInventory = nil, "", nil, false
		}
		c.notifyLocked()
	}
	c.mu.Unlock()
	access, err := c.cloud.CheckAccess(ctx, account, tokens)
	if err == nil {
		c.mu.Lock()
		if !current() {
			c.mu.Unlock()
			return
		}
		err = c.observeRoleLocked(access.Role, account)
		ok := current()
		c.mu.Unlock()
		if err != nil || !ok {
			return
		}
	}
	var inventory cloud.Inventory
	if err == nil {
		inventory, err = c.cloud.FetchInventory(ctx, account, access.Role, tokens)
	}
	var rows []row
	if err == nil {
		rows = buildRows(account, inventory)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if classify(err) == failSignIn {
		c.refreshResult = refreshOutcome{epoch: j.epoch, result: ipc.RefreshSignInRequired}
		return
	}
	if !current() {
		return
	}
	if err == nil {
		if err = c.publishLocked(rows, access.Role, account); err == nil {
			c.refreshResult = refreshOutcome{epoch: j.epoch, result: ipc.RefreshRefreshed}
			return
		}
	}
	c.inventoryFailedLocked(err, account, j.epoch)
}

// inventoryFailedLocked ports the refresh failure paths. Only a transport
// failure with prior authorization falls back to the cache
func (c *Controller) inventoryFailedLocked(err error, account string, epoch uint64) {
	result := ipc.RefreshUnavailable
	switch classify(err) {
	case failCancelled:
		return
	case failOffline:
		c.inventoryFailure = "offline"
		c.rows = nil
		if saved, loadErr := c.cache.Load(account); loadErr == nil && saved.AccessAllowed {
			c.applySavedLocked(saved)
			c.hasInventory = true
		} else {
			c.installed, c.selected, c.hasInventory = nil, "", false
		}
		c.isOffline = true
	case failDenied:
		result = ipc.RefreshDenied
		c.inventoryFailure = "denied"
		c.denyLocked(account)
	default:
		c.inventoryFailure = "unavailable"
		c.rows, c.installed, c.hasInventory = nil, nil, false
	}
	c.refreshResult = refreshOutcome{epoch: epoch, result: result}
	c.notifyLocked()
}

// publishLocked replaces the authorized cache from a complete refresh, then
// shows the saved metadata. Removed clients stay hidden until the account changes
func (c *Controller) publishLocked(rows []row, role cloud.Role, account string) error {
	rows = slices.DeleteFunc(rows, func(r row) bool { return c.removed[r.identifier] })
	options := make([]store.AuthorizedOption, 0, len(rows))
	for _, r := range rows {
		client := r.option.Client
		options = append(options, store.AuthorizedOption{
			ClientID: client.ClientID, RegionID: client.RegionID, ClientName: client.ClientName,
			RegionDisplayName: r.option.RegionDisplayName(), Status: string(client.Status), UpdatedAt: client.UpdatedAt,
			AssignedTunnelIPv4: client.AssignedTunnelIPv4, ServerEndpointIPv4: client.ServerEndpointIPv4,
			ServerEndpointHostname: client.ServerEndpointHostname, OwnerUID: client.OwnerUID,
			Usable: r.eligibility() == eligible, ConfigHash: r.hash,
		})
	}
	if err := c.cache.Authorize(account, store.Role(role), options); err != nil {
		c.clearInventoryPresentationLocked(account)
		return err
	}
	saved, err := c.cache.Load(account)
	if err == nil && !saved.AccessAllowed {
		err = store.ErrAccessDenied
	}
	if err != nil {
		c.clearInventoryPresentationLocked(account)
		return err
	}
	c.rows, c.readAt = rows, c.now()
	c.applySavedLocked(saved)
	c.isOffline, c.hasInventory, c.inventoryFailure = false, true, ""
	c.notifyLocked()
	return nil
}

// awaitRefresh ports the macOS awaited refresh. On Linux, a connected server
// that stopped responding first gets its endpoint re-resolved outside the tunnel
func (c *Controller) awaitRefresh(parent context.Context) ipc.Reply {
	if _, creation := c.registry.Busy(); creation {
		return ipc.Reply{Error: ipc.FailureBusy}
	}
	ctx, cancel := context.WithTimeout(parent, refreshTimeout)
	defer cancel()
	c.recoverEndpoint(ctx)
	result := c.awaitInventory(ctx)
	state := c.state(parent, false)
	return ipc.Reply{Refresh: result, State: &state}
}

func (c *Controller) awaitInventory(ctx context.Context) ipc.RefreshResult {
	c.mu.Lock()
	if c.closing {
		c.mu.Unlock()
		return ipc.RefreshSkipped
	}
	if c.user == "" {
		if c.creds == nil {
			c.mu.Unlock()
			return ipc.RefreshSignInRequired
		}
		c.restoreSessionLocked()
		restore := c.restore
		c.mu.Unlock()
		if restore == nil {
			return ipc.RefreshSkipped
		}
		if !waitJob(ctx, restore) {
			return ipc.RefreshTimedOut
		}
		c.mu.Lock()
		switch {
		case c.user != "" && c.isOffline:
			c.mu.Unlock()
			return ipc.RefreshUnavailable
		case c.user != "":
		case c.accessResult == ipc.AccessDenied:
			c.mu.Unlock()
			return ipc.RefreshDenied
		case c.creds == nil:
			c.mu.Unlock()
			return ipc.RefreshSignInRequired
		default:
			c.mu.Unlock()
			return ipc.RefreshUnavailable
		}
	} else {
		c.refreshInventoryLocked(true, true)
	}
	if c.deferred {
		session := c.sessionLocked()
		c.mu.Unlock()
		if !c.waitFor(ctx, func() bool { return c.commands == 0 && c.stops == 0 || c.closing }) {
			return ipc.RefreshTimedOut
		}
		c.mu.Lock()
		if session != c.sessionLocked() || c.closing {
			c.mu.Unlock()
			return ipc.RefreshSuperseded
		}
		c.resumeDeferredLocked(true)
	}
	epoch, j := c.inventoryEpoch, c.refresh
	c.mu.Unlock()
	if j != nil && !waitJob(ctx, j) {
		return ipc.RefreshTimedOut
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.refreshResult.epoch == epoch && c.refreshResult.result != "" {
		return c.refreshResult.result
	}
	return ipc.RefreshSuperseded
}

// recoverEndpoint moves the peer to a changed server address when the
// connected server stopped answering
func (c *Controller) recoverEndpoint(ctx context.Context) {
	if c.observe(ctx).State != network.StateConnected {
		return
	}
	checkCtx, cancel := context.WithTimeout(ctx, serverCheckTimeout)
	responding, err := c.net.ServerResponding(checkCtx)
	cancel()
	if err != nil || responding {
		return
	}
	c.netMu.Lock()
	defer c.netMu.Unlock()
	if c.currentIntent().Phase != store.PhaseRunning {
		return
	}
	if _, changed, err := c.net.UpdateEndpoint(ctx); err != nil {
		c.logf("server endpoint could not be re-resolved: %s", failure(err))
	} else if changed {
		c.logf("server endpoint changed. Updated the peer in place")
		c.cloud.CloseIdleConnections()
	}
	c.observe(ctx)
}

// clientsLocked ports clientMetadata, filtered to the signed-in account
func (c *Controller) clientsLocked(obs network.Observation, phase ipc.TunnelPhase) []ipc.Client {
	clients := []ipc.Client{}
	account := c.user
	if account == "" {
		return clients
	}
	active := c.activeProfileLocked(obs)
	status := func(identifier string, installed bool) ipc.ClientTunnel {
		switch {
		case identifier == active:
			return rowStatus(phase)
		case installed:
			return ipc.ClientTunnelDisconnected
		}
		return ""
	}
	if c.isOffline || len(c.rows) == 0 {
		names := offlineRegionNames(c.installed)
		for _, config := range c.installed {
			if config.AccountID != account || !belongs(config.Identifier, account) {
				continue
			}
			snapshot := config.Snapshot
			eligibility := "inactive"
			if snapshot.Status == string(cloud.StatusActive) {
				eligibility = eligible
			}
			client := ipc.Client{
				Identifier: config.Identifier, ClientID: snapshot.ClientID, RegionID: snapshot.RegionID,
				RegionName: names[snapshot.RegionID], RegionOrder: offlineRegionOrder,
				ClientName: cmp.Or(strings.TrimSpace(snapshot.ClientName), snapshot.ClientID),
				InternalIP: tunnelIPv4(snapshot.AssignedTunnelIPv4), ConnectionURL: connectionURL(snapshot.ServerEndpointHostname, snapshot.ServerEndpointIPv4),
				CloudState: snapshot.Status, Eligibility: eligibility, Installed: true, Source: "cache",
				ReadAt: snapshot.ReadAt.UTC(), UpdatedAt: optionalTime(snapshot.UpdatedAt), Status: status(config.Identifier, true),
			}
			clients = append(clients, client)
		}
		return clients
	}
	for _, r := range c.rows {
		client := r.option.Client
		installed := c.installedLocked(r.identifier, account) != nil
		item := ipc.Client{
			Identifier: r.identifier, ClientID: client.ClientID, RegionID: client.RegionID,
			RegionName: r.option.RegionDisplayName(), RegionOrder: r.option.DisplayOrder(), ClientName: client.DisplayName(),
			InternalIP: tunnelIPv4(client.AssignedTunnelIPv4), ConnectionURL: connectionURL(client.ServerEndpointHostname, client.ServerEndpointIPv4),
			CloudState: string(client.Status), Eligibility: r.eligibility(), Installed: installed, Source: "cloud",
			ReadAt: c.readAt.UTC(), UpdatedAt: optionalTime(client.UpdatedAt), Status: status(r.identifier, installed),
		}
		if client.OwnerEmail != "" {
			owner := client.OwnerEmail
			item.OwnerLabel = &owner
		}
		clients = append(clients, item)
	}
	return clients
}

func rowStatus(phase ipc.TunnelPhase) ipc.ClientTunnel {
	switch phase {
	case ipc.TunnelConnected:
		return ipc.ClientTunnelConnected
	case ipc.TunnelConnecting:
		return ipc.ClientTunnelConnecting
	case ipc.TunnelDisconnecting:
		return ipc.ClientTunnelDisconnecting
	case ipc.TunnelDisconnected:
		return ipc.ClientTunnelDisconnected
	}
	return ipc.ClientTunnelInvalid
}

// offlineRegionNames ports offlineRegions: the most recently read snapshot names each region
func offlineRegionNames(configs []store.InstalledConfig) map[string]string {
	names := map[string]string{}
	latest := map[string]time.Time{}
	for _, config := range configs {
		snapshot := config.Snapshot
		if read, ok := latest[snapshot.RegionID]; ok && !snapshot.ReadAt.After(read) {
			continue
		}
		latest[snapshot.RegionID] = snapshot.ReadAt
		names[snapshot.RegionID] = cmp.Or(strings.TrimSpace(snapshot.RegionDisplayName), snapshot.RegionID)
	}
	return names
}

func connectionURL(hostname, ipv4 string) *string {
	for _, value := range []string{hostname, ipv4} {
		if value = strings.TrimSpace(value); value != "" {
			return &value
		}
	}
	return nil
}

// tunnelIPv4 accepts an IPv4 address with an optional prefix length
func tunnelIPv4(value string) *string {
	address, _, _ := strings.Cut(value, "/")
	if prefix := strings.TrimPrefix(value, address); prefix != "" {
		if _, err := netip.ParsePrefix(value); err != nil {
			return nil
		}
	}
	addr, err := netip.ParseAddr(address)
	if err != nil || !addr.Is4() {
		return nil
	}
	text := addr.String()
	return &text
}

func optionalTime(value time.Time) *time.Time {
	if value.IsZero() {
		return nil
	}
	utc := value.UTC()
	return &utc
}

func belongs(identifier, account string) bool {
	return account != "" && store.ValidIdentifier(identifier) && strings.HasPrefix(identifier, account+"/")
}
