package daemon

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/buildinfo"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

// testHandler answers handshakes with a lifecycle, blocks awaitRefresh until
// released, and returns an oversized reply for prepareClient
type testHandler struct {
	mu      sync.Mutex
	peers   []Peer
	started chan struct{}
	release chan struct{}
}

func newTestHandler() *testHandler {
	return &testHandler{started: make(chan struct{}, 8), release: make(chan struct{})}
}

func (h *testHandler) Handle(ctx context.Context, peer Peer, request ipc.Request) ipc.Reply {
	h.mu.Lock()
	h.peers = append(h.peers, peer)
	h.mu.Unlock()
	switch request.Action {
	case ipc.ActionHandshake:
		return ipc.Reply{Lifecycle: &ipc.Lifecycle{State: ipc.LifecycleCurrent, Tunnel: ipc.Tunnel{Phase: ipc.TunnelDisconnected, Observation: ipc.ObservationCurrent}}}
	case ipc.ActionAwaitRefresh:
		h.started <- struct{}{}
		select {
		case <-h.release:
			return ipc.Reply{Refresh: ipc.RefreshRefreshed}
		case <-ctx.Done():
			return ipc.Reply{Error: ipc.FailureTimeout}
		}
	case ipc.ActionPrepareClient:
		return ipc.Reply{Creation: &ipc.Creation{ID: request.ID, Regions: []ipc.CreationRegion{{DisplayName: strings.Repeat("a", ipc.MaxReplyBytes)}}}}
	}
	return ipc.Reply{Operation: &ipc.Operation{ID: request.ID, State: ipc.OperationCompleted}}
}

func (h *testHandler) peer(i int) Peer {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.peers[i]
}

func (h *testHandler) calls() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.peers)
}

type testServer struct {
	*Server
	path string
	done chan error
}

// startServer serves on a short socket path, since macOS limits them to 104 bytes
func startServer(t *testing.T, handler Handler, peerUID uint32, configure func(*Server)) *testServer {
	t.Helper()
	dir, err := os.MkdirTemp("", "cgd")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	operator := uint32(os.Getuid())
	path := filepath.Join(dir, "d.sock")
	listener, err := listen(path, operator, operator)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(handler, operator)
	server.peer = func(*net.UnixConn) (Peer, error) { return Peer{UID: peerUID, PID: 42}, nil }
	if configure != nil {
		configure(server)
	}
	ts := &testServer{Server: server, path: path, done: make(chan error, 1)}
	go func() { ts.done <- server.Serve(listener) }()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
		if err := <-ts.done; err != nil {
			t.Errorf("serve: %v", err)
		}
	})
	return ts
}

func dial(t *testing.T, path string) *ipc.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	conn, err := ipc.Dial(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

func call(conn *ipc.Conn, request ipc.Request) (ipc.Reply, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if request.ID == "" {
		request.ID = newID()
	}
	return conn.Call(ctx, request)
}

// rawCall sends value without ipc.Conn, which always stamps the current version
func rawCall(t *testing.T, path string, value any) (ipc.Reply, net.Conn) {
	t.Helper()
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	if err := ipc.WriteMessage(conn, value, ipc.MaxRequestBytes); err != nil {
		t.Fatal(err)
	}
	var reply ipc.Reply
	if err := ipc.ReadMessage(conn, &reply, ipc.MaxReplyBytes); err != nil {
		t.Fatal(err)
	}
	return reply, conn
}

func expectClosed(t *testing.T, conn net.Conn) {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Read(make([]byte, 1)); !errors.Is(err, io.EOF) {
		t.Fatalf("read err = %v, want EOF", err)
	}
}

func TestServerAnswersSequentialRequestsWithStampedReplies(t *testing.T) {
	handler := newTestHandler()
	server := startServer(t, handler, uint32(os.Getuid()), nil)
	conn := dial(t, server.path)
	for range 2 {
		id := newID()
		reply, err := call(conn, ipc.Request{ID: id, Action: ipc.ActionSnapshot, CheckServer: true})
		if err != nil {
			t.Fatal(err)
		}
		if reply.Version != ipc.Version || reply.Release != buildinfo.Version || reply.InstanceID != server.InstanceID() ||
			reply.Operation == nil || reply.Operation.ID != id || reply.Error != "" {
			t.Fatalf("reply = %+v", reply)
		}
	}
	if !validUUID(server.InstanceID()) || server.InstanceID()[14] != '4' {
		t.Fatalf("instance ID = %q", server.InstanceID())
	}
	if other := NewServer(handler, 0).InstanceID(); other == server.InstanceID() {
		t.Fatal("instance IDs repeat")
	}
	if peer := handler.peer(0); peer != (Peer{UID: uint32(os.Getuid()), PID: 42}) {
		t.Fatalf("peer = %+v", peer)
	}
}

func TestServerValidatesBeforeDispatch(t *testing.T) {
	handler := newTestHandler()
	server := startServer(t, handler, 0, nil)
	conn := dial(t, server.path)
	reply, err := call(conn, ipc.Request{ID: "not-a-uuid", Action: ipc.ActionSnapshot})
	if err != nil || reply.Error != ipc.FailureInvalidRequest || reply.InstanceID != server.InstanceID() {
		t.Fatalf("reply = %+v, err = %v", reply, err)
	}
	reply, err = call(conn, ipc.Request{Action: ipc.ActionSetMode})
	if err != nil || reply.Error != ipc.FailureInvalidRequest {
		t.Fatalf("reply = %+v, err = %v", reply, err)
	}
	reply, _ = rawCall(t, server.path, ipc.Request{Version: 2, ID: newID(), Action: ipc.ActionSnapshot})
	if reply.Error != ipc.FailureIncompatibleVersion || reply.Version != ipc.Version {
		t.Fatalf("reply = %+v", reply)
	}
	if handler.calls() != 0 {
		t.Fatalf("handler ran %d times", handler.calls())
	}
	reply, _ = rawCall(t, server.path, map[string]any{"version": 7, "action": "handshake", "futureField": true})
	if reply.Error != "" || reply.Lifecycle == nil || reply.Lifecycle.State != ipc.LifecycleCurrent || reply.Version != ipc.Version {
		t.Fatalf("handshake reply = %+v", reply)
	}
	if peer := handler.peer(0); peer.UID != 0 {
		t.Fatalf("peer = %+v", peer)
	}
}

func TestServerRejectsOtherPeers(t *testing.T) {
	handler := newTestHandler()
	server := startServer(t, handler, uint32(os.Getuid())+1, nil)
	reply, conn := rawCall(t, server.path, ipc.Request{Version: ipc.Version, ID: newID(), Action: ipc.ActionHandshake})
	if reply.Error != ipc.FailureRejected || reply.InstanceID != server.InstanceID() {
		t.Fatalf("reply = %+v", reply)
	}
	expectClosed(t, conn)

	failing := startServer(t, handler, 0, func(s *Server) {
		s.peer = func(*net.UnixConn) (Peer, error) { return Peer{}, errors.New("no credentials") }
	})
	if reply, _ := rawCall(t, failing.path, ipc.Request{Version: ipc.Version, ID: newID(), Action: ipc.ActionSnapshot}); reply.Error != ipc.FailureRejected {
		t.Fatalf("reply = %+v", reply)
	}
	if handler.calls() != 0 {
		t.Fatalf("handler ran %d times", handler.calls())
	}
}

func TestServerRejectsOversizedAndMalformedFrames(t *testing.T) {
	handler := newTestHandler()
	server := startServer(t, handler, 0, nil)
	for _, frame := range [][]byte{
		binary.BigEndian.AppendUint32(nil, ipc.MaxRequestBytes+1),
		append(binary.BigEndian.AppendUint32(nil, 9), "{\"id\":7}x"...),
		append(binary.BigEndian.AppendUint32(nil, 15), `{"version":"1"}`...),
	} {
		conn, err := net.Dial("unix", server.path)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
		if _, err := conn.Write(frame); err != nil {
			t.Fatal(err)
		}
		var reply ipc.Reply
		if err := ipc.ReadMessage(conn, &reply, ipc.MaxReplyBytes); err != nil || reply.Error != ipc.FailureInvalidRequest {
			t.Fatalf("reply = %+v, err = %v", reply, err)
		}
		expectClosed(t, conn)
	}
	if handler.calls() != 0 {
		t.Fatalf("handler ran %d times", handler.calls())
	}
}

func TestServerReplacesOversizedReply(t *testing.T) {
	server := startServer(t, newTestHandler(), 0, nil)
	conn := dial(t, server.path)
	reply, err := call(conn, ipc.Request{Action: ipc.ActionPrepareClient})
	if err != nil || reply.Error != ipc.FailureUnavailable || reply.Creation != nil {
		t.Fatalf("reply = %+v, err = %v", reply, err)
	}
	if reply, err := call(conn, ipc.Request{Action: ipc.ActionSnapshot}); err != nil || reply.Operation == nil {
		t.Fatalf("follow-up reply = %+v, err = %v", reply, err)
	}
}

func TestServerCapsConcurrentConnections(t *testing.T) {
	server := startServer(t, newTestHandler(), 0, nil)
	var conns []*ipc.Conn
	for range 32 {
		conn := dial(t, server.path)
		if _, err := call(conn, ipc.Request{Action: ipc.ActionHandshake}); err != nil {
			t.Fatal(err)
		}
		conns = append(conns, conn)
	}
	if _, err := call(dial(t, server.path), ipc.Request{Action: ipc.ActionHandshake}); err == nil {
		t.Fatal("33rd connection was served")
	}
	conns[0].Close()
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, err := call(dial(t, server.path), ipc.Request{Action: ipc.ActionHandshake}); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("a freed slot was never reused")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestServerClosesIdleConnections(t *testing.T) {
	server := startServer(t, newTestHandler(), 0, func(s *Server) { s.idleTimeout = 50 * time.Millisecond })
	conn, err := net.Dial("unix", server.path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	// A partial frame does not extend the deadline
	if _, err := conn.Write([]byte{0, 0}); err != nil {
		t.Fatal(err)
	}
	expectClosed(t, conn)
}

func TestShutdownWaitsForInFlightRequests(t *testing.T) {
	handler := newTestHandler()
	server := startServer(t, handler, 0, nil)
	idle, err := net.Dial("unix", server.path)
	if err != nil {
		t.Fatal(err)
	}
	defer idle.Close()
	busy := dial(t, server.path)
	replies := make(chan ipc.Reply, 1)
	go func() {
		reply, _ := call(busy, ipc.Request{Action: ipc.ActionAwaitRefresh})
		replies <- reply
	}()
	<-handler.started
	shutdown := make(chan error, 1)
	go func() { shutdown <- server.Shutdown(context.Background()) }()
	expectClosed(t, idle)
	select {
	case err := <-shutdown:
		t.Fatalf("shutdown returned %v with a request in flight", err)
	case <-time.After(100 * time.Millisecond):
	}
	if _, err := net.Dial("unix", server.path); err == nil {
		t.Fatal("accepted a connection after shutdown began")
	}
	close(handler.release)
	if err := <-shutdown; err != nil {
		t.Fatal(err)
	}
	if reply := <-replies; reply.Refresh != ipc.RefreshRefreshed {
		t.Fatalf("in-flight reply = %+v", reply)
	}
	if err := <-server.done; err != nil {
		t.Fatal(err)
	}
	server.done <- nil
}

func TestShutdownDeadlineCancelsHandlers(t *testing.T) {
	handler := newTestHandler()
	server := startServer(t, handler, 0, nil)
	busy := dial(t, server.path)
	errs := make(chan error, 1)
	go func() {
		_, err := call(busy, ipc.Request{Action: ipc.ActionAwaitRefresh})
		errs <- err
	}()
	<-handler.started
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if err := server.Shutdown(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("shutdown err = %v", err)
	}
	if err := <-errs; err == nil {
		t.Fatal("caller got a reply from a cancelled request")
	}
}

func TestListenReplacesOnlyStaleSockets(t *testing.T) {
	dir, err := os.MkdirTemp("", "cgd")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	owner := uint32(os.Getuid())
	path := filepath.Join(dir, "run", "d.sock")
	if err := os.Mkdir(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	stale, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	stale.SetUnlinkOnClose(false)
	stale.Close()
	listener, err := listen(path, owner, owner)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(path)
	if err != nil || info.Mode().Perm() != 0o600 || info.Mode().Type() != os.ModeSocket {
		t.Fatalf("socket info = %v, err = %v", info, err)
	}
	if info, _ := os.Stat(filepath.Dir(path)); info.Mode().Perm() != 0o711 {
		t.Fatalf("dir mode = %o", info.Mode().Perm())
	}
	listener.Close()

	file := filepath.Join(dir, "run", "file")
	if err := os.WriteFile(file, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := listen(file, owner, owner); err == nil {
		t.Fatal("listened over a regular file")
	}
	if data, _ := os.ReadFile(file); string(data) != "keep" {
		t.Fatal("regular file was replaced")
	}
}

func TestListenCreatesRuntimeDirAndRefusesUnsafeOnes(t *testing.T) {
	dir, err := os.MkdirTemp("", "cgd")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	owner := uint32(os.Getuid())
	created := filepath.Join(dir, "new", "d.sock")
	listener, err := listen(created, owner, owner)
	if err != nil {
		t.Fatal(err)
	}
	listener.Close()
	if info, _ := os.Lstat(filepath.Dir(created)); !info.IsDir() || info.Mode().Perm() != 0o711 {
		t.Fatalf("created dir = %v", info)
	}

	writable := filepath.Join(dir, "writable")
	if err := os.Mkdir(writable, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(writable, 0o777); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(filepath.Join(dir, "new"), link); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		path  string
		owner uint32
	}{
		{filepath.Join(writable, "d.sock"), owner},
		{filepath.Join(link, "d.sock"), owner},
		{filepath.Join(dir, "new", "other.sock"), owner + 1},
	} {
		if listener, err := listen(test.path, owner, test.owner); err == nil {
			listener.Close()
			t.Fatalf("listened at %s", test.path)
		}
	}
	if info, _ := os.Stat(writable); info.Mode().Perm() != 0o777 {
		t.Fatal("refused dir was changed")
	}
	if _, err := os.Lstat(filepath.Join(writable, "d.sock")); !os.IsNotExist(err) {
		t.Fatal("socket created in a refused dir")
	}
}

func TestServerKeepsLastSlotForRoot(t *testing.T) {
	var uid atomic.Uint32
	uid.Store(uint32(os.Getuid()))
	server := startServer(t, newTestHandler(), 0, func(s *Server) {
		s.maxConnections = 3
		s.peer = func(*net.UnixConn) (Peer, error) { return Peer{UID: uid.Load()}, nil }
	})
	for range 2 {
		if _, err := call(dial(t, server.path), ipc.Request{Action: ipc.ActionHandshake}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := call(dial(t, server.path), ipc.Request{Action: ipc.ActionHandshake}); err == nil {
		t.Fatal("operator took the slot kept for root")
	}
	uid.Store(0)
	if _, err := call(dial(t, server.path), ipc.Request{Action: ipc.ActionHandshake}); err != nil {
		t.Fatalf("root locked out: %v", err)
	}
	if _, err := call(dial(t, server.path), ipc.Request{Action: ipc.ActionHandshake}); err == nil {
		t.Fatal("root exceeded the connection cap")
	}
}
