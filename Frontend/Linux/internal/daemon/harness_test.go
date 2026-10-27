package daemon

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/cloud"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network/networktest"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
)

// Keys from the wgconfig tests. The private and preshared keys must never leave setconf stdin
const (
	testPrivateKey = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
	testPublicKey  = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI="
	testProject    = "cloudgateway-test"
	userA          = "user-a"
	userB          = "user-b"
	region         = "us-sanjose-1"
	clientA        = "client-a"
	clientB        = "client-b"
	configA        = userA + "/" + region + "/" + clientA
	configB        = userA + "/" + region + "/" + clientB
	endpointHost   = "wg.us-sanjose-1.gocloudlaunch.com"
)

var (
	testStart  = time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)
	serverIP   = netip.MustParseAddr("203.0.113.10")
	movedIP    = netip.MustParseAddr("203.0.113.20")
	tunnelDNS  = netip.MustParseAddrPort("10.0.0.1:53")
	sanJose    = cloud.Region{RegionID: region, DisplayName: "San Jose", Enabled: true, DisplayOrder: 1}
	identityV1 = ipc.BuildIdentity{Version: "1.0.0", Build: "1.0.0", CodeHash: strings.Repeat("a", 64)}
	identityV2 = ipc.BuildIdentity{Version: "1.0.1", Build: "1.0.1", CodeHash: strings.Repeat("b", 64)}
)

func wgConfig(host int) string {
	return fmt.Sprintf("[Interface]\nPrivateKey = %s\nAddress = 10.0.0.%d/32, fd42:42:42::%d/128\nDNS = 10.0.0.1, fd42:42:42::1\n\n"+
		"[Peer]\nPublicKey = %s\nEndpoint = %s:51820\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25\n",
		testPrivateKey, host, host, testPublicKey, endpointHost)
}

func clientDoc(owner, clientID, name string, host int) cloud.ClientDoc {
	return cloud.ClientDoc{
		ClientID: clientID, ClientName: name, RegionID: region, Status: cloud.StatusActive,
		WireGuardConfig: cloud.Secret(wgConfig(host)), AssignedTunnelIPv4: fmt.Sprintf("10.0.0.%d", host),
		ServerEndpointHostname: endpointHost, UpdatedAt: testStart.Add(-time.Hour), OwnerUID: owner, OwnerEmail: owner + "@example.com",
	}
}

func cloudError(kind cloud.Kind, status int, dispatched bool) error {
	return &cloud.Error{Op: "test", Kind: kind, Status: status, Dispatched: dispatched}
}

// fakeClock advances only when the controller sleeps or a test calls Advance.
// While held, sleeps wait for release, so a retrying loop stays put
type fakeClock struct {
	mu   sync.Mutex
	now  time.Time
	hold chan struct{}
	held int
}

func (f *fakeClock) holdSleeps() {
	f.mu.Lock()
	f.hold = make(chan struct{})
	f.mu.Unlock()
}

func (f *fakeClock) releaseSleeps() {
	f.mu.Lock()
	close(f.hold)
	f.hold = nil
	f.mu.Unlock()
}

func (f *fakeClock) sleepers() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.held
}

func (f *fakeClock) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}

func (f *fakeClock) Advance(d time.Duration) {
	f.mu.Lock()
	f.now = f.now.Add(d)
	f.mu.Unlock()
}

func (f *fakeClock) Sleep(ctx context.Context, d time.Duration) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	f.mu.Lock()
	hold := f.hold
	if hold != nil {
		f.held++
	}
	f.mu.Unlock()
	if hold != nil {
		select {
		case <-hold:
		case <-ctx.Done():
		}
		f.mu.Lock()
		f.held--
		f.mu.Unlock()
		if err := ctx.Err(); err != nil {
			return err
		}
	}
	f.Advance(d)
	runtime.Gosched()
	return nil
}

type pollReply struct {
	poll cloud.DevicePoll
	err  error
}

// fakeCloud is an in-memory CloudGateway backend
type fakeCloud struct {
	clock *fakeClock
	polls chan pollReply

	mu           sync.Mutex
	roles        map[string]cloud.Role
	regions      []cloud.Region
	clients      []cloud.ClientDoc
	capacity     map[string]cloud.Capacity
	code         cloud.DeviceCode
	codeErr      error
	customTokens map[string]string
	signInErr    error
	refreshErr   error
	refreshes    int
	rotate       bool
	project      string
	accessErr    error
	inventoryErr error
	createErr    error
	deleteErr    error
	deleteGate   chan struct{}
	// accessGate, inventoryGate, and regionsGate block their reads until closed
	accessGate    chan struct{}
	regionsGate   chan struct{}
	inventoryGate chan struct{}
	// allOwners returns every owner's clients, as a broken query would
	allOwners  bool
	creates    []string
	deletes    []string
	idleCloses int
	tokens     []string
}

func newFakeCloud(clock *fakeClock) *fakeCloud {
	return &fakeCloud{
		clock: clock, polls: make(chan pollReply, 16),
		roles:   map[string]cloud.Role{userA: cloud.RoleUser, userB: cloud.RoleUser},
		regions: []cloud.Region{sanJose},
		clients: []cloud.ClientDoc{clientDoc(userA, clientA, "Laptop", 2), clientDoc(userA, clientB, "Server", 3)},
		code: cloud.DeviceCode{RequestID: strings.Repeat("0", 32), UserCode: "012345", ExpiresIn: 300 * time.Second,
			Interval: 5 * time.Second, VerificationURL: "https://gocloudlaunch.com/#/auth/code?deviceRequestId=" + strings.Repeat("0", 32) + "&userCode=012345"},
		customTokens: map[string]string{"custom-" + userA: userA, "custom-" + userB: userB},
		capacity:     map[string]cloud.Capacity{region: {Known: true, Limit: 10, Allocated: 2}},
	}
}

func (f *fakeCloud) set(update func(*fakeCloud)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	update(f)
}

func (f *fakeCloud) session(uid string) cloud.Session {
	return cloud.Session{IDToken: cloud.Secret("id-" + uid), RefreshToken: cloud.Secret("refresh-" + uid),
		ExpiresAt: f.clock.Now().Add(time.Hour), UserID: uid, ProjectID: testProject}
}

func (f *fakeCloud) RequestDeviceCode(context.Context, *cloud.DeviceSecret) (cloud.DeviceCode, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.code, f.codeErr
}

func (f *fakeCloud) PollDeviceToken(ctx context.Context, _ string, _ *cloud.DeviceSecret) (cloud.DevicePoll, error) {
	select {
	case reply := <-f.polls:
		return reply.poll, reply.err
	case <-ctx.Done():
		return cloud.DevicePoll{}, cloudError(cloud.KindCanceled, 0, false)
	}
}

func (f *fakeCloud) SignInWithCustomToken(_ context.Context, token cloud.Secret) (cloud.Session, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.signInErr != nil {
		return cloud.Session{}, f.signInErr
	}
	return f.session(f.customTokens[string(token)]), nil
}

func (f *fakeCloud) RefreshSession(_ context.Context, refreshToken cloud.Secret) (cloud.Session, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.refreshErr != nil {
		return cloud.Session{}, f.refreshErr
	}
	uid, ok := strings.CutPrefix(string(refreshToken), "refresh-")
	if !ok {
		return cloud.Session{}, cloudError(cloud.KindSignInRequired, 400, false)
	}
	uid, _, _ = strings.Cut(uid, "#")
	f.refreshes++
	session := f.session(uid)
	if f.rotate {
		session.IDToken = cloud.Secret(fmt.Sprintf("id-%s#%d", uid, f.refreshes))
		session.RefreshToken = cloud.Secret(fmt.Sprintf("refresh-%s#%d", uid, f.refreshes))
	}
	if f.project != "" {
		session.ProjectID = f.project
	}
	return session, nil
}

func (f *fakeCloud) token(ctx context.Context, tokens cloud.TokenSource) error {
	token, err := tokens(ctx, "")
	if err == nil {
		f.mu.Lock()
		f.tokens = append(f.tokens, string(token))
		f.mu.Unlock()
	}
	return err
}

func (f *fakeCloud) CheckAccess(ctx context.Context, uid string, tokens cloud.TokenSource) (cloud.Access, error) {
	if err := f.token(ctx, tokens); err != nil {
		return cloud.Access{}, err
	}
	f.mu.Lock()
	gate := f.accessGate
	f.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
			return cloud.Access{}, cloudError(cloud.KindCanceled, 0, false)
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.accessErr != nil {
		return cloud.Access{}, f.accessErr
	}
	role, ok := f.roles[uid]
	if !ok {
		return cloud.Access{}, cloudError(cloud.KindAccessDenied, 403, false)
	}
	return cloud.Access{UserID: uid, Role: role}, nil
}

func (f *fakeCloud) FetchInventory(ctx context.Context, uid string, role cloud.Role, tokens cloud.TokenSource) (cloud.Inventory, error) {
	if err := f.token(ctx, tokens); err != nil {
		return cloud.Inventory{}, err
	}
	f.mu.Lock()
	gate := f.inventoryGate
	f.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
			return cloud.Inventory{}, cloudError(cloud.KindCanceled, 0, false)
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.inventoryErr != nil {
		return cloud.Inventory{}, f.inventoryErr
	}
	var clients []cloud.ClientDoc
	for _, client := range f.clients {
		if role == cloud.RoleAdmin || f.allOwners || client.OwnerUID == uid {
			clients = append(clients, client)
		}
	}
	regions := slices.Clone(f.regions)
	return cloud.Inventory{Regions: regions, Options: cloud.JoinOptions(clients, regions)}, nil
}

func (f *fakeCloud) ListRegions(ctx context.Context) ([]cloud.Region, error) {
	f.mu.Lock()
	gate := f.regionsGate
	f.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
			return nil, cloudError(cloud.KindCanceled, 0, false)
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.regions), nil
}

func (f *fakeCloud) FetchCapacity(ctx context.Context, regionID string, tokens cloud.TokenSource) (cloud.Capacity, error) {
	if err := f.token(ctx, tokens); err != nil {
		return cloud.Capacity{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.capacity[regionID], nil
}

func (f *fakeCloud) CreateClient(_ context.Context, regionID, name string, idToken cloud.Secret) (cloud.CreatedClient, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.creates = append(f.creates, regionID+" "+name+" "+string(idToken))
	if f.createErr != nil {
		return cloud.CreatedClient{}, f.createErr
	}
	owner, _, _ := strings.Cut(strings.TrimPrefix(string(idToken), "id-"), "#")
	doc := clientDoc(owner, fmt.Sprintf("client-new-%d", len(f.creates)), name, 9)
	f.clients = append(f.clients, doc)
	return cloud.CreatedClient{ClientID: doc.ClientID, RegionID: regionID, ClientName: name, Status: cloud.StatusActive,
		WireGuardConfig: doc.WireGuardConfig}, nil
}

func (f *fakeCloud) DeleteClient(ctx context.Context, regionID, clientID, ownerUID string, idToken cloud.Secret) error {
	f.mu.Lock()
	gate := f.deleteGate
	f.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
			return cloudError(cloud.KindCanceled, 0, true)
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deletes = append(f.deletes, regionID+"/"+clientID+" owner="+ownerUID+" "+string(idToken))
	if f.deleteErr != nil {
		return f.deleteErr
	}
	for i := range f.clients {
		if f.clients[i].ClientID == clientID {
			f.clients[i].Status = cloud.StatusRemoved
		}
	}
	return nil
}

func (f *fakeCloud) CloseIdleConnections() {
	f.mu.Lock()
	f.idleCloses++
	f.mu.Unlock()
}

type fakeReleases struct {
	mu        sync.Mutex
	running   ipc.BuildIdentity
	installed ipc.BuildIdentity
	err       error
}

func (r *fakeReleases) set(running, installed ipc.BuildIdentity, err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.running, r.installed, r.err = running, installed, err
}

func (r *fakeReleases) Running() ipc.BuildIdentity {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.running
}

func (r *fakeReleases) Installed() (ipc.BuildIdentity, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.installed, r.err
}

type harness struct {
	t        *testing.T
	dir      string
	clock    *fakeClock
	cloud    *fakeCloud
	host     *networktest.Host
	releases *fakeReleases
	c        *Controller

	mu            sync.Mutex
	server        netip.Addr
	lookupFailing int
	tunnelDNSDown bool
	logs          []string
	replies       []string
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	clock := &fakeClock{now: testStart}
	h := &harness{t: t, dir: t.TempDir(), clock: clock, cloud: newFakeCloud(clock), host: networktest.NewUbuntu(),
		releases: &fakeReleases{running: identityV1, installed: identityV1}, server: serverIP}
	return h
}

// open starts a controller over the harness store, like a new daemon process
func (h *harness) open() *Controller {
	h.t.Helper()
	st, err := store.Open(h.dir)
	if err != nil {
		h.t.Fatal(err)
	}
	c, err := NewController(Options{
		Store: st, Cloud: h.cloud, Releases: h.releases,
		Network: network.Options{Executor: h.host, LookupHost: h.lookupHost, Exchange: h.exchange},
		Now:     h.clock.Now, Sleep: h.clock.Sleep, Jitter: func() float64 { return 0.5 },
		HTTPGet: func(context.Context, string) (int, []byte, error) { return 200, []byte(`{"status":"ok"}`), nil },
		Logf: func(format string, args ...any) {
			h.mu.Lock()
			h.logs = append(h.logs, fmt.Sprintf(format, args...))
			h.mu.Unlock()
		},
	})
	if err != nil {
		h.t.Fatal(err)
	}
	c.Start()
	h.c = c
	h.t.Cleanup(func() { h.close(c) })
	return c
}

func (h *harness) close(c *Controller) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c.Close(ctx)
}

// restart closes the controller and opens a new one over the same store and host
func (h *harness) restart() *Controller {
	h.t.Helper()
	h.close(h.c)
	return h.open()
}

func (h *harness) lookupHost(_ context.Context, host string) ([]netip.Addr, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if host != endpointHost && host != "gocloudlaunch.com" {
		return nil, errors.New("unknown host")
	}
	if h.lookupFailing > 0 {
		h.lookupFailing--
		return nil, errors.New("temporary failure in name resolution")
	}
	return []netip.Addr{h.server}, nil
}

func (h *harness) exchange(_ context.Context, server netip.AddrPort, _ uint32, query []byte) ([]byte, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if server == tunnelDNS && h.tunnelDNSDown {
		return nil, context.DeadlineExceeded
	}
	return dnsAnswer(query, h.server), nil
}

func (h *harness) setServer(addr netip.Addr, tunnelDNSDown bool) {
	h.mu.Lock()
	h.server, h.tunnelDNSDown = addr, tunnelDNSDown
	h.mu.Unlock()
}

// dnsAnswer replies to query with an A record when it asks for one
func dnsAnswer(query []byte, addr netip.Addr) []byte {
	reply := slices.Clone(query)
	reply[2] |= 0x80
	if binary.BigEndian.Uint16(query[len(query)-4:]) != 1 {
		return reply
	}
	reply = append(reply, 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0x01, 0x2c, 0, 4)
	reply = append(reply, addr.AsSlice()...)
	binary.BigEndian.PutUint16(reply[6:], 1)
	return reply
}

// do sends one request through Handle and records the reply JSON
func (h *harness) do(request ipc.Request) ipc.Reply {
	h.t.Helper()
	request.Version = ipc.Version
	if request.ID == "" {
		request.ID = newID()
	}
	if failure := Validate(request); failure != "" {
		h.t.Fatalf("invalid request %+v: %s", request, failure)
	}
	reply := h.c.Handle(context.Background(), Peer{UID: 1000}, request)
	data, _ := json.Marshal(reply)
	h.mu.Lock()
	h.replies = append(h.replies, string(data))
	h.mu.Unlock()
	return reply
}

func (h *harness) snapshot() ipc.State {
	h.t.Helper()
	reply := h.do(ipc.Request{Action: ipc.ActionSnapshot})
	if reply.State == nil {
		h.t.Fatalf("snapshot without state: %+v", reply)
	}
	return *reply.State
}

// eventually polls cond in real time
func (h *harness) eventually(what string, cond func() bool) {
	h.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			h.t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(time.Millisecond)
	}
}

// settled waits like the CLI for restoration and inventory to finish
func (h *harness) settled() ipc.State {
	h.t.Helper()
	var state ipc.State
	h.eventually("settled state", func() bool {
		state = h.snapshot()
		h.c.mu.Lock()
		idle := h.c.commands == 0 && h.c.stops == 0
		h.c.mu.Unlock()
		return idle && !state.IsRestoring && state.Access != ipc.AccessChecking && state.Inventory != ipc.InventoryRefreshing &&
			!(state.AccountID == nil && state.HasRetainedSession && state.Access == ipc.AccessUnverified)
	})
	return state
}

type result struct {
	operation ipc.Operation
	outcome   *ipc.Outcome
	reply     ipc.Reply
}

// run reserves, confirms, and waits for a command like the CLI's submit
func (h *harness) run(request ipc.Request) result {
	h.t.Helper()
	request.ID = newID()
	reserved := h.do(request)
	if reserved.Error != "" {
		return result{operation: ipc.Operation{ID: request.ID, State: ipc.OperationFailed, Failure: reserved.Error}, reply: reserved}
	}
	if reserved.Operation == nil || reserved.Operation.State != ipc.OperationAccepted {
		h.t.Fatalf("reservation = %+v", reserved)
	}
	return h.finish(request.ID, h.do(ipc.Request{Action: ipc.ActionConfirm, ContextID: request.ID}))
}

func (h *harness) finish(id string, reply ipc.Reply) result {
	h.t.Helper()
	h.eventually("operation "+id, func() bool {
		state := reply.Operation.State
		if state != ipc.OperationAccepted && state != ipc.OperationRunning {
			return true
		}
		reply = h.do(ipc.Request{Action: ipc.ActionOperation, ContextID: id})
		return false
	})
	return result{operation: *reply.Operation, outcome: reply.Outcome, reply: reply}
}

// st is the running controller's store. Opening another one would sweep the
// controller's in-flight temp files
func (h *harness) st() *store.Store {
	h.t.Helper()
	if h.c != nil {
		return h.c.store
	}
	st, err := store.Open(h.dir)
	if err != nil {
		h.t.Fatal(err)
	}
	return st
}

// seedSession saves credentials for uid, as an earlier login would
func (h *harness) seedSession(uid string, generation uint64) {
	h.t.Helper()
	st := h.st()
	current, _ := st.LoadSession()
	if err := st.SaveSession(store.Session{Generation: generation, AccountID: uid, RevokedThrough: current.RevokedThrough}); err != nil {
		h.t.Fatal(err)
	}
	if err := st.SaveCredentials(store.Credentials{AccountID: uid, ProjectID: testProject, Generation: generation,
		RefreshToken: store.Secret("refresh-" + uid)}); err != nil {
		h.t.Fatal(err)
	}
}

// signedIn opens a controller restoring uid's saved session and waits for its inventory
func (h *harness) signedIn(uid string) ipc.State {
	h.t.Helper()
	h.seedSession(uid, 1)
	h.open()
	state := h.settled()
	if state.AccountID == nil || *state.AccountID != uid {
		h.t.Fatalf("account = %v, access %s", state.AccountID, state.Access)
	}
	return state
}

func (h *harness) resuming() bool {
	h.c.mu.Lock()
	defer h.c.mu.Unlock()
	return h.c.resume != nil
}

func (h *harness) up(identifier string) result {
	h.t.Helper()
	return h.run(ipc.Request{Action: ipc.ActionConnect, Identifier: identifier})
}

func (h *harness) intent() store.Intent {
	h.t.Helper()
	intent, err := h.st().LoadIntent()
	if err != nil {
		h.t.Fatal(err)
	}
	return intent
}

func (h *harness) owned() string {
	var lines []string
	if l, ok := h.host.Link(network.InterfaceName); ok {
		line := fmt.Sprintf("link mtu=%d", l.MTU)
		if l.WireGuard != nil {
			line += fmt.Sprintf(" endpoint=%s allowed=%v", l.WireGuard.Endpoint, l.WireGuard.AllowedIPs)
		}
		lines = append(lines, line)
	}
	for _, r := range h.host.Rules() {
		if r.Protocol == network.RouteProtocol {
			line := fmt.Sprintf("rule v%d %d", r.Family, r.Priority)
			if r.Dst.IsValid() {
				line += " to " + r.Dst.String()
			}
			lines = append(lines, line)
		}
	}
	if slices.Contains(h.host.NftTables(), "inet "+network.NftTable) {
		lines = append(lines, "nft")
	}
	return strings.Join(lines, "\n")
}

func (h *harness) mutations() []string {
	var changed []string
	for _, c := range h.host.Calls() {
		if c.Tool == "resolvectl" || c.Has("-f", "-") || c.Has("setconf") || c.Has("set") || c.Has("add") || c.Has("del") {
			changed = append(changed, c.String())
		}
	}
	return changed
}

func expect[T comparable](t *testing.T, name string, got, want T) {
	t.Helper()
	if got != want {
		t.Fatalf("%s = %v, want %v", name, got, want)
	}
}

func deref[T any](value *T) any {
	if value == nil {
		return nil
	}
	return *value
}

var fullOwned = fmt.Sprintf("link mtu=1420 endpoint=203.0.113.10:51820 allowed=[0.0.0.0/0 ::/0]\n"+
	"rule v4 %[1]d\nrule v6 %[1]d\nrule v4 %[6]d to 10.0.0.0/16\nrule v6 %[6]d to fd42:42:42::/48\n"+
	"rule v4 %[2]d to 10.0.0.0/16\nrule v6 %[2]d to fd42:42:42::/48\n"+
	"rule v4 %[3]d to 10.0.0.0/8\nrule v4 %[3]d to 100.64.0.0/10\nrule v4 %[3]d to 168.63.129.16/32\nrule v4 %[3]d to 169.254.0.0/16\n"+
	"rule v4 %[3]d to 172.16.0.0/12\nrule v4 %[3]d to 192.168.0.0/16\nrule v6 %[3]d to fc00::/7\nrule v6 %[3]d to fe80::/10\n"+
	"rule v4 %[4]d\nrule v6 %[4]d\nrule v4 %[5]d\nrule v6 %[5]d\nnft",
	network.PrioritySource, network.PriorityMesh, network.PriorityLocal, network.PrioritySuppress, network.PriorityTunnel, network.PriorityMeshLocal)

const meshOwned = "link mtu=1420 endpoint=203.0.113.10:51820 allowed=[10.0.0.0/16 fd42:42:42::/48]\nnft"
