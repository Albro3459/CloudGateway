// Package daemon holds cloudgatewayd's local IPC server, request validation,
// operation registry, and daemon configuration
package daemon

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/buildinfo"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

const (
	maxConnections = 32
	// idleTimeout bounds the wait for each complete request frame
	idleTimeout  = 60 * time.Second
	writeTimeout = 10 * time.Second
)

// Peer is the connecting process from SO_PEERCRED
type Peer struct {
	UID uint32
	PID int32
}

func (p Peer) IsRoot() bool { return p.UID == 0 }

// Handler answers one validated request. The server stamps the reply envelope
type Handler interface {
	Handle(ctx context.Context, peer Peer, request ipc.Request) ipc.Reply
}

// Server accepts root and the enrolled operator on the daemon socket. Each
// connection handles requests one at a time, so in-flight requests never
// exceed the connection limit
type Server struct {
	handler     Handler
	operatorUID uint32
	instanceID  string
	// peer reads the caller's credentials. Tests replace it off Linux
	peer           func(*net.UnixConn) (Peer, error)
	idleTimeout    time.Duration
	writeTimeout   time.Duration
	maxConnections int

	ctx    context.Context
	cancel context.CancelFunc

	mu       sync.Mutex
	closed   bool
	listener *net.UnixListener
	conns    map[*net.UnixConn]struct{}
	wg       sync.WaitGroup
}

func NewServer(handler Handler, operatorUID uint32) *Server {
	ctx, cancel := context.WithCancel(context.Background())
	return &Server{
		handler: handler, operatorUID: operatorUID, instanceID: newUUID(),
		peer: peerCredentials, idleTimeout: idleTimeout, writeTimeout: writeTimeout, maxConnections: maxConnections,
		ctx: ctx, cancel: cancel, conns: map[*net.UnixConn]struct{}{},
	}
}

// InstanceID changes each time the daemon process starts
func (s *Server) InstanceID() string { return s.instanceID }

// Listen creates the daemon socket at path. Its directory must be a real
// directory owned by root and writable only by root, and is set to 0711. A
// stale socket is replaced. The socket is 0600 and owned by the operator, so
// root and the operator can connect. SO_PEERCRED still decides every
// connection, since the operator owns the file and could change its mode
func Listen(path string, operatorUID uint32) (*net.UnixListener, error) {
	return listen(path, operatorUID, 0)
}

func listen(path string, operatorUID, dirOwner uint32) (*net.UnixListener, error) {
	dir := filepath.Dir(path)
	if err := os.Mkdir(dir, 0o711); err != nil && !errors.Is(err, fs.ErrExist) {
		return nil, err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return nil, err
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !info.IsDir() || !ok || stat.Uid != dirOwner || info.Mode().Perm()&0o022 != 0 {
		return nil, fmt.Errorf("%s must be a directory owned by uid %d and writable only by it", dir, dirOwner)
	}
	if err := os.Chmod(dir, 0o711); err != nil {
		return nil, err
	}
	if info, err := os.Lstat(path); err == nil && info.Mode().Type() != fs.ModeSocket {
		return nil, fmt.Errorf("%s exists and is not a socket", path)
	} else if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	// The socket is ready under a temporary name, then renamed over a stale one,
	// so a CLI never finds the path missing or root-owned while the daemon starts.
	// The daemon's 077 umask keeps it private until chmod and chown finish, and
	// only the directory owner can swap names in between
	next := path + ".new"
	if err := os.Remove(next); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: next, Net: "unix"})
	if err != nil {
		return nil, err
	}
	fail := func(err error) (*net.UnixListener, error) {
		listener.Close()
		return nil, err
	}
	if info, err := os.Lstat(next); err != nil || info.Mode().Type() != fs.ModeSocket {
		return fail(fmt.Errorf("%s changed while listening", next))
	}
	if err := os.Chmod(next, 0o600); err != nil {
		return fail(err)
	}
	if err := os.Lchown(next, int(operatorUID), -1); err != nil {
		return fail(err)
	}
	// The socket file outlives an update restart, so a CLI sees a refused
	// connection and waits instead of reporting the daemon gone. The next
	// listen replaces it, and systemctl stop removes the directory
	listener.SetUnlinkOnClose(false)
	if err := os.Rename(next, path); err != nil {
		_ = os.Remove(next)
		return fail(err)
	}
	return listener, nil
}

// Serve accepts connections until Shutdown. It returns nil after Shutdown.
// The last connection slot is kept for root, so the operator cannot lock out
// recovery
func (s *Server) Serve(listener *net.UnixListener) error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		listener.Close()
		return nil
	}
	s.listener = listener
	s.mu.Unlock()
	var delay time.Duration
	for {
		conn, err := listener.AcceptUnix()
		if err != nil {
			s.mu.Lock()
			closed := s.closed
			s.mu.Unlock()
			if closed {
				return nil
			}
			if errors.Is(err, syscall.EMFILE) || errors.Is(err, syscall.ENFILE) || errors.Is(err, syscall.ECONNABORTED) {
				delay = min(max(2*delay, 5*time.Millisecond), time.Second)
				time.Sleep(delay)
				continue
			}
			return err
		}
		delay = 0
		peer, peerErr := s.peer(conn)
		limit := s.maxConnections - 1
		if peerErr == nil && peer.IsRoot() {
			limit = s.maxConnections
		}
		s.mu.Lock()
		if s.closed || len(s.conns) >= limit {
			s.mu.Unlock()
			conn.Close()
			continue
		}
		s.conns[conn] = struct{}{}
		s.wg.Add(1)
		s.mu.Unlock()
		go s.serveConn(conn, peer, peerErr)
	}
}

func (s *Server) serveConn(conn *net.UnixConn, peer Peer, peerErr error) {
	defer func() {
		conn.Close()
		s.mu.Lock()
		delete(s.conns, conn)
		s.mu.Unlock()
		s.wg.Done()
	}()
	if peerErr != nil || peer.UID != 0 && peer.UID != s.operatorUID {
		_ = conn.SetReadDeadline(time.Now().Add(s.writeTimeout))
		var request ipc.Request
		_ = ipc.ReadMessage(conn, &request, ipc.MaxRequestBytes)
		_ = s.write(conn, ipc.Reply{Error: ipc.FailureRejected})
		return
	}
	for s.awaitRequest(conn) {
		var request ipc.Request
		if err := ipc.ReadMessage(conn, &request, ipc.MaxRequestBytes); err != nil {
			var syntax *json.SyntaxError
			var mismatch *json.UnmarshalTypeError
			if errors.Is(err, ipc.ErrMessageTooLarge) || errors.As(err, &syntax) || errors.As(err, &mismatch) {
				_ = s.write(conn, ipc.Reply{Error: ipc.FailureInvalidRequest})
			}
			return
		}
		reply := ipc.Reply{Error: Validate(request)}
		if reply.Error == "" {
			reply = s.handler.Handle(s.ctx, peer, request)
		}
		if s.write(conn, reply) != nil {
			return
		}
	}
}

// awaitRequest arms the idle deadline unless Shutdown already started
func (s *Server) awaitRequest(conn *net.UnixConn) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return !s.closed && conn.SetReadDeadline(time.Now().Add(s.idleTimeout)) == nil
}

func (s *Server) write(conn *net.UnixConn, reply ipc.Reply) error {
	if err := conn.SetWriteDeadline(time.Now().Add(s.writeTimeout)); err != nil {
		return err
	}
	err := ipc.WriteMessage(conn, s.stamp(reply), ipc.MaxReplyBytes)
	// The handler may already have acted, so the caller must not treat this as a bad request
	if errors.Is(err, ipc.ErrMessageTooLarge) {
		err = ipc.WriteMessage(conn, s.stamp(ipc.Reply{Error: ipc.FailureUnavailable}), ipc.MaxReplyBytes)
	}
	return err
}

func (s *Server) stamp(reply ipc.Reply) ipc.Reply {
	reply.Version = ipc.Version
	reply.Release = buildinfo.Version
	reply.InstanceID = s.instanceID
	return reply
}

// Shutdown stops accepting, closes idle connections, and waits for in-flight
// requests until ctx ends. Then it cancels handler contexts and closes the rest
func (s *Server) Shutdown(ctx context.Context) error {
	s.mu.Lock()
	s.closed = true
	if s.listener != nil {
		s.listener.Close()
	}
	// Idle reads end now. Busy connections exit after writing their reply
	for conn := range s.conns {
		_ = conn.SetReadDeadline(time.Now())
	}
	s.mu.Unlock()
	done := make(chan struct{})
	go func() {
		s.wg.Wait()
		close(done)
	}()
	select {
	case <-done:
		s.cancel()
		return nil
	case <-ctx.Done():
		s.cancel()
		s.mu.Lock()
		for conn := range s.conns {
			conn.Close()
		}
		s.mu.Unlock()
		return ctx.Err()
	}
}

func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
