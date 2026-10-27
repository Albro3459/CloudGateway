package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/daemon"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

var (
	observedAt = time.Unix(1_800_000_000, 0).UTC()
	testBuild  = ipc.BuildIdentity{Version: "1.2.0", Build: "1.2.0", CodeHash: strings.Repeat("c", 64)}
	// Sentinel hook replies: drop closes the connection, hang never answers
	dropReply = &ipc.Reply{}
	hangReply = &ipc.Reply{}
)

func testState(edits ...func(*ipc.State)) ipc.State {
	s := ipc.State{AccountID: ptr("uid1"), HasRetainedSession: true, AccessAuthorized: true, Access: ipc.AccessOnline,
		Credentials: "available", Inventory: ipc.InventoryCurrent, Clients: []ipc.Client{},
		Tunnel: ipc.Tunnel{Phase: ipc.TunnelDisconnected, Observation: ipc.ObservationCurrent, ObservedAt: &observedAt}}
	for _, edit := range edits {
		edit(&s)
	}
	return s
}

func signedOut(s *ipc.State) {
	s.AccountID, s.HasRetainedSession, s.AccessAuthorized, s.Credentials, s.Access = nil, false, false, "unknown", ipc.AccessUnverified
}

func withClients(clients ...ipc.Client) func(*ipc.State) {
	return func(s *ipc.State) { s.Clients = clients }
}

func withSelected(identifier string) func(*ipc.State) {
	return func(s *ipc.State) { s.SelectedIdentifier = &identifier }
}

func testClient(identifier, regionName string, order int, name string, edits ...func(*ipc.Client)) ipc.Client {
	parts := strings.Split(identifier, "/")
	c := ipc.Client{Identifier: identifier, ClientID: parts[2], RegionID: parts[1], RegionName: regionName, RegionOrder: order,
		ClientName: name, InternalIP: ptr("10.0.0.2"), CloudState: "active", Eligibility: "eligible", Installed: true,
		Source: "cloud", ReadAt: time.Unix(0, 0).UTC(), Status: ipc.ClientTunnelDisconnected}
	for _, edit := range edits {
		edit(&c)
	}
	return c
}

type fakeClock struct {
	mu    sync.Mutex
	start time.Time
	now   time.Time
}

func newFakeClock() *fakeClock {
	start := time.Unix(2_000_000_000, 0)
	return &fakeClock{start: start, now: start}
}

func (f *fakeClock) clock() clock {
	return clock{now: func() time.Time {
		f.mu.Lock()
		defer f.mu.Unlock()
		return f.now
	}, sleep: func(ctx context.Context, d time.Duration) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		f.mu.Lock()
		f.now = f.now.Add(d)
		f.mu.Unlock()
		return nil
	}}
}

func (f *fakeClock) elapsed() time.Duration {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now.Sub(f.start)
}

// fakeDaemon answers the IPC contract over a real Unix socket and records every request
type fakeDaemon struct {
	t         *testing.T
	path      string
	mu        sync.Mutex
	listener  net.Listener
	conns     []net.Conn
	accepts   int
	requests  []ipc.Request
	version   int
	lifecycle ipc.LifecycleState
	// handshakeTunnel is the version-stable tunnel another IPC version can still read
	handshakeTunnel ipc.Tunnel
	states          []ipc.State
	operation       *ipc.Operation
	outcome         *ipc.Outcome
	update          *ipc.UpdateStatus
	hung            map[ipc.Action]bool
	// onRequest runs with mu held. A nil reply falls back to the defaults
	onRequest func(ipc.Request) *ipc.Reply
}

func newFakeDaemon(t *testing.T, states ...ipc.State) *fakeDaemon {
	dir, err := os.MkdirTemp("", "cg")
	if err != nil {
		t.Fatal(err)
	}
	d := &fakeDaemon{t: t, path: filepath.Join(dir, "d.sock"), version: ipc.Version, lifecycle: ipc.LifecycleCurrent,
		handshakeTunnel: ipc.Tunnel{Phase: ipc.TunnelDisconnected, Observation: ipc.ObservationCurrent},
		states:          states, hung: map[ipc.Action]bool{}}
	d.listen()
	t.Cleanup(func() {
		d.stop()
		_ = os.RemoveAll(dir)
	})
	return d
}

func (d *fakeDaemon) listen() {
	listener, err := net.Listen("unix", d.path)
	if err != nil {
		d.t.Fatal(err)
	}
	d.mu.Lock()
	d.listener = listener
	d.mu.Unlock()
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			d.mu.Lock()
			d.accepts++
			d.conns = append(d.conns, conn)
			d.mu.Unlock()
			go d.serve(conn)
		}
	}()
}

// stop closes the listener, which removes the socket, and every open connection
func (d *fakeDaemon) stop() {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.listener != nil {
		_ = d.listener.Close()
		d.listener = nil
	}
	for _, conn := range d.conns {
		_ = conn.Close()
	}
	d.conns = nil
}

func (d *fakeDaemon) serve(conn net.Conn) {
	defer conn.Close()
	for {
		var request ipc.Request
		if err := ipc.ReadMessage(conn, &request, ipc.MaxRequestBytes); err != nil {
			return
		}
		d.mu.Lock()
		d.requests = append(d.requests, request)
		var reply *ipc.Reply
		// Reply like the real server: other IPC versions only get a handshake, then the request rules apply
		if request.Action != ipc.ActionHandshake && request.Version != d.version {
			reply = &ipc.Reply{Error: ipc.FailureIncompatibleVersion}
		} else if failure := daemon.Validate(request); failure != "" {
			d.t.Errorf("daemon rejected %+v: %s", request, failure)
			reply = &ipc.Reply{Error: failure}
		}
		if reply == nil && d.onRequest != nil {
			reply = d.onRequest(request)
		}
		if reply == nil && d.hung[request.Action] {
			reply = hangReply
		}
		if reply == nil {
			reply = d.defaultReply(request)
		}
		version := d.version
		d.mu.Unlock()
		switch reply {
		case dropReply:
			return
		case hangReply:
			_, _ = io.Copy(io.Discard, conn)
			return
		}
		answer := *reply
		answer.Version, answer.Release, answer.InstanceID = version, "1.2.0", "instance"
		if err := ipc.WriteMessage(conn, answer, ipc.MaxReplyBytes); err != nil {
			return
		}
	}
}

func (d *fakeDaemon) defaultReply(request ipc.Request) *ipc.Reply {
	switch request.Action {
	case ipc.ActionHandshake:
		return &ipc.Reply{Lifecycle: &ipc.Lifecycle{Running: testBuild, Installed: &testBuild, State: d.lifecycle, Tunnel: d.handshakeTunnel}}
	case ipc.ActionUserActivity:
		return &ipc.Reply{}
	case ipc.ActionSnapshot:
		if len(d.states) == 0 {
			d.t.Errorf("snapshot without a state")
			return &ipc.Reply{Error: ipc.FailureInvalidRequest}
		}
		state := d.states[0]
		if len(d.states) > 1 {
			d.states = d.states[1:]
		}
		return &ipc.Reply{State: &state, Operation: d.operation, Outcome: d.outcome, Update: d.update}
	case ipc.ActionOperation:
		if d.operation != nil && d.operation.ID == request.ContextID {
			return &ipc.Reply{Operation: d.operation, Outcome: d.outcome, Update: d.update}
		}
		return &ipc.Reply{Operation: &ipc.Operation{ID: request.ContextID, State: ipc.OperationUnknown}}
	}
	d.t.Errorf("unexpected daemon request %s", request.Action)
	return &ipc.Reply{Error: ipc.FailureInvalidRequest}
}

func (d *fakeDaemon) actions() []ipc.Action {
	d.mu.Lock()
	defer d.mu.Unlock()
	var actions []ipc.Action
	for _, request := range d.requests {
		actions = append(actions, request.Action)
	}
	return actions
}

func (d *fakeDaemon) requestsFor(action ipc.Action) []ipc.Request {
	d.mu.Lock()
	defer d.mu.Unlock()
	var result []ipc.Request
	for _, request := range d.requests {
		if request.Action == action {
			result = append(result, request)
		}
	}
	return result
}

func (d *fakeDaemon) acceptCount() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.accepts
}

func (d *fakeDaemon) reset() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.requests = nil
}

func (d *fakeDaemon) setStates(states ...ipc.State) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.states = states
}

type fakeInput struct {
	shortcuts bool
	keys      []byte
	columns   int
	starts    []bool
	reads     int
	closes    int
}

func (f *fakeInput) start(shortcuts bool) bool {
	f.starts = append(f.starts, shortcuts)
	return shortcuts && f.shortcuts
}

func (f *fakeInput) readKeys() []byte {
	f.reads++
	keys := f.keys
	f.keys = nil
	return keys
}

func (f *fakeInput) width() int { return f.columns }
func (f *fakeInput) close()     { f.closes++ }

type harness struct {
	t           *testing.T
	daemon      *fakeDaemon
	clock       *fakeClock
	realClock   bool
	mu          sync.Mutex
	out         bytes.Buffer
	diag        bytes.Buffer
	failsOutput bool
	onOutput    func()
	terminal    bool
	env         map[string]string
	currentLink string
	version     [2]string
	input       *fakeInput
	effects     loginEffects
	signals     chan<- os.Signal
	probes      []probe
}

func newHarness(t *testing.T, states ...ipc.State) *harness {
	return &harness{t: t, daemon: newFakeDaemon(t, states...), clock: newFakeClock(), env: map[string]string{},
		currentLink: t.TempDir(), version: [2]string{"1.2.0", "7"}, input: &fakeInput{columns: 100},
		effects: loginEffects{qrMatrix: encodeQR, copy: func(string) bool { return false }, open: func(string) bool { return false }}}
}

type harnessOutput struct{ h *harness }

func (o harnessOutput) Write(p []byte) (int, error) {
	if o.h.onOutput != nil {
		o.h.onOutput()
	}
	if o.h.failsOutput {
		return 0, syscall.EPIPE
	}
	return o.h.out.Write(p)
}

func (h *harness) cli() *CLI {
	c := &CLI{stdout: harnessOutput{h}, stderr: &h.diag, isOutputTerminal: h.terminal,
		lookupEnv: func(name string) (string, bool) {
			value, ok := h.env[name]
			return value, ok
		}, socketPath: h.daemon.path, currentLink: h.currentLink, version: h.version[0], build: h.version[1],
		clock: h.clock.clock(), input: h.input, effects: h.effects, probes: h.probes,
		notify: func(ch chan<- os.Signal, signals ...os.Signal) func() {
			if slices.Contains(signals, os.Signal(syscall.SIGINT)) {
				h.mu.Lock()
				h.signals = ch
				h.mu.Unlock()
			}
			return func() {}
		}}
	if h.realClock {
		c.clock = realClock
	}
	return c
}

func (h *harness) run(arguments ...string) int { return h.cli().Run(arguments) }

func (h *harness) signal(sig os.Signal) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.signals <- sig
}

func (h *harness) reset() {
	h.out.Reset()
	h.diag.Reset()
	h.daemon.reset()
}

// records decodes every NDJSON line of stdout
func (h *harness) records() []map[string]any {
	h.t.Helper()
	var result []map[string]any
	for _, line := range strings.Split(strings.TrimSuffix(h.out.String(), "\n"), "\n") {
		var value map[string]any
		if err := json.Unmarshal([]byte(line), &value); err != nil {
			h.t.Fatalf("invalid JSON line %q: %v", line, err)
		}
		result = append(result, value)
	}
	return result
}

func (h *harness) last() map[string]any {
	records := h.records()
	return records[len(records)-1]
}

// field walks decoded JSON by object keys
func field(value any, path ...string) any {
	for _, key := range path {
		object, ok := value.(map[string]any)
		if !ok {
			return errors.New("missing " + key)
		}
		if value, ok = object[key]; !ok {
			return errors.New("missing " + key)
		}
	}
	return value
}

func expectActions(t *testing.T, d *fakeDaemon, want ...ipc.Action) {
	t.Helper()
	if got := d.actions(); !slices.Equal(got, want) {
		t.Fatalf("actions = %v, want %v", got, want)
	}
}

func expectExit(t *testing.T, got, want int) {
	t.Helper()
	if got != want {
		t.Fatalf("exit = %d, want %d", got, want)
	}
}

func expectEqual[T comparable](t *testing.T, name string, got, want T) {
	t.Helper()
	if got != want {
		t.Fatalf("%s = %#v, want %#v", name, got, want)
	}
}

func expectContains(t *testing.T, text, part string) {
	t.Helper()
	if !strings.Contains(text, part) {
		t.Fatalf("missing %q in:\n%s", part, text)
	}
}

func expectMissing(t *testing.T, text, part string) {
	t.Helper()
	if strings.Contains(text, part) {
		t.Fatalf("unexpected %q in:\n%s", part, text)
	}
}

// accept answers a reservation, then completes or fails its confirmation with outcome
func acceptAndConfirm(d *fakeDaemon, action ipc.Action, state ipc.OperationState, outcome *ipc.Outcome, reply func() *ipc.Reply) func(ipc.Request) *ipc.Reply {
	var id string
	return func(request ipc.Request) *ipc.Reply {
		switch request.Action {
		case action:
			id = request.ID
			return &ipc.Reply{Operation: &ipc.Operation{ID: request.ID, State: ipc.OperationAccepted}}
		case ipc.ActionConfirm:
			if request.ContextID != id {
				d.t.Errorf("confirm %s, want %s", request.ContextID, id)
			}
			result := &ipc.Reply{}
			if reply != nil {
				result = reply()
			}
			result.Operation, result.Outcome = &ipc.Operation{ID: id, State: state}, outcome
			return result
		}
		return nil
	}
}
