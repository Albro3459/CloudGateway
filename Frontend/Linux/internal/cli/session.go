package cli

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"strings"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

const (
	pollInterval    = 500 * time.Millisecond
	observationWait = 5 * time.Second
)

type clock struct {
	now   func() time.Time
	sleep func(ctx context.Context, d time.Duration) error
}

var realClock = clock{now: time.Now, sleep: func(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}}

func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	s := hex.EncodeToString(b[:])
	return s[0:8] + "-" + s[8:12] + "-" + s[12:16] + "-" + s[16:20] + "-" + s[20:]
}

// session is one invocation's view of the daemon. Every call shares the caller deadline
type session struct {
	cli       *CLI
	ctx       context.Context
	deadline  time.Time
	conn      *ipc.Conn
	lifecycle ipc.Lifecycle
	current   bool
	reported  bool
}

func (s *session) remaining() time.Duration { return s.deadline.Sub(s.cli.clock.now()) }

func (s *session) close() {
	if s.conn != nil {
		_ = s.conn.Close()
		s.conn = nil
	}
}

// open dials the daemon socket unless a connection is already open
func (s *session) open() error {
	if s.conn != nil {
		return nil
	}
	remaining := s.remaining()
	if remaining <= 0 {
		return errorCode(codeTimeout)
	}
	ctx, cancel := context.WithTimeout(s.ctx, remaining)
	defer cancel()
	conn, err := ipc.Dial(ctx, s.cli.socketPath)
	switch {
	case err == nil:
		s.conn = conn
		return nil
	case s.ctx.Err() != nil:
		return errorCode(codeInterrupted)
	case ctx.Err() != nil:
		return errorCode(codeTimeout)
	case errors.Is(err, fs.ErrPermission):
		return errorCode(codeControllerRejected)
	}
	// A missing, refused, or stale socket without an installed release means CloudGateway isn't installed
	if _, statErr := os.Stat(s.cli.currentLink); errors.Is(statErr, fs.ErrNotExist) {
		return errorCode(codeInstallationRequired)
	}
	return controllerFailure(ipc.FailureUnavailable)
}

// call sends one request on the open connection, bounded by the caller deadline
func (s *session) call(request ipc.Request) (ipc.Reply, error) {
	remaining := s.remaining()
	if remaining <= 0 {
		return ipc.Reply{}, errorCode(codeTimeout)
	}
	if s.ctx.Err() != nil {
		return ipc.Reply{}, errorCode(codeInterrupted)
	}
	if s.conn == nil {
		return ipc.Reply{}, controllerFailure(ipc.FailureUnavailable)
	}
	if request.ID == "" {
		request.ID = newUUID()
	}
	ctx, cancel := context.WithTimeout(s.ctx, remaining)
	defer cancel()
	reply, err := s.conn.Call(ctx, request)
	if err != nil {
		// A failed exchange can leave a partial frame behind, so this connection is done
		s.close()
		var syntax *json.SyntaxError
		var mismatch *json.UnmarshalTypeError
		switch {
		case s.ctx.Err() != nil:
			return ipc.Reply{}, errorCode(codeInterrupted)
		case errors.Is(err, context.DeadlineExceeded):
			return ipc.Reply{}, errorCode(codeTimeout)
		case errors.As(err, &syntax), errors.As(err, &mismatch), errors.Is(err, ipc.ErrMessageTooLarge):
			return ipc.Reply{}, controllerFailure(ipc.FailureInvalidRequest)
		}
		return ipc.Reply{}, controllerFailure(ipc.FailureUnavailable)
	}
	if reply.Error != "" {
		return reply, controllerFailure(reply.Error)
	}
	return reply, nil
}

// sleep waits one poll interval within the caller deadline
func (s *session) sleep() error { return s.sleepFor(pollInterval) }

func (s *session) sleepFor(d time.Duration) error {
	remaining := s.remaining()
	if remaining <= 0 {
		return errorCode(codeTimeout)
	}
	ctx, cancel := context.WithTimeout(s.ctx, remaining)
	defer cancel()
	if err := s.cli.clock.sleep(ctx, d); err != nil {
		if s.ctx.Err() != nil {
			return errorCode(codeInterrupted)
		}
		return errorCode(codeTimeout)
	}
	return nil
}

// handshake records whether this CLI matches the running daemon's IPC version and lifecycle
func (s *session) handshake() error {
	reply, err := s.call(ipc.Request{Action: ipc.ActionHandshake})
	if err != nil {
		return err
	}
	if reply.Lifecycle == nil {
		return controllerFailure(ipc.FailureInvalidRequest)
	}
	s.lifecycle = *reply.Lifecycle
	s.current = reply.Version == ipc.Version && reply.Lifecycle.State == ipc.LifecycleCurrent
	return nil
}

// connect repeats the handshake and reports user activity once when this CLI matches the daemon
func (s *session) connect() error {
	if err := s.handshake(); err != nil {
		return err
	}
	if s.current && !s.reported {
		if _, err := s.call(ipc.Request{Action: ipc.ActionUserActivity}); err != nil {
			return err
		}
		s.reported = true
	}
	return nil
}

func (s *session) versionError() error {
	if s.lifecycle.State == ipc.LifecycleInvalidInstallation {
		return errorCode(codeInstallationRequired)
	}
	return errorCode(codeIncompatibleVersion)
}

func (s *session) requireCurrent() error {
	if err := s.connect(); err != nil {
		return err
	}
	if !s.current {
		return s.versionError()
	}
	return nil
}

func (s *session) poll(request ipc.Request, limit time.Time, pending func(ipc.Reply) (bool, error)) (ipc.Reply, bool, error) {
	for {
		reply, err := s.call(request)
		if err != nil {
			return reply, false, err
		}
		isPending, err := pending(reply)
		if err != nil {
			return reply, false, err
		}
		if !isPending {
			return reply, true, nil
		}
		if !s.cli.clock.now().Add(pollInterval).Before(limit) {
			return reply, false, nil
		}
		if err := s.cli.clock.sleep(s.ctx, pollInterval); err != nil {
			return reply, false, errorCode(codeInterrupted)
		}
	}
}

func stateOf(reply ipc.Reply) (ipc.State, error) {
	if reply.State == nil {
		return ipc.State{}, controllerFailure(ipc.FailureInvalidRequest)
	}
	return *reply.State, nil
}

// pollSettled waits for restoration, verification, and inventory refresh to finish
func (s *session) pollSettled(pending func(ipc.State) bool) (ipc.State, bool, error) {
	reply, settled, err := s.poll(ipc.Request{Action: ipc.ActionSnapshot}, s.deadline, func(reply ipc.Reply) (bool, error) {
		state, err := stateOf(reply)
		return err == nil && (isPendingRestoration(state) || isAwaitingVerification(state) || pending(state)), err
	})
	if err != nil {
		return ipc.State{}, false, err
	}
	state, err := stateOf(reply)
	return state, settled, err
}

func accountError(state ipc.State, message string) error {
	if state.Access == ipc.AccessDenied {
		return errorCode(codeAccessDenied)
	}
	if state.HasRetainedSession && state.Access == ipc.AccessUnreachable {
		return newError(codeNetworkUnavailable, message, "")
	}
	return errorCode(codeSignInRequired)
}

func (s *session) observationLimit() time.Time {
	return minTime(s.deadline, s.cli.clock.now().Add(observationWait))
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}

func (s *session) authStatus() (data, error) {
	if err := s.requireCurrent(); err != nil {
		return nil, err
	}
	reply, _, err := s.poll(ipc.Request{Action: ipc.ActionSnapshot}, s.deadline, func(reply ipc.Reply) (bool, error) {
		state, err := stateOf(reply)
		return err == nil && isPendingRestoration(state), err
	})
	if err != nil {
		return nil, err
	}
	state, err := stateOf(reply)
	if err != nil {
		return nil, err
	}
	return newAuthStatus(state), nil
}

func (s *session) modeStatus() (data, error) {
	if err := s.requireCurrent(); err != nil {
		return nil, err
	}
	reply, _, err := s.poll(ipc.Request{Action: ipc.ActionSnapshot}, s.observationLimit(), func(reply ipc.Reply) (bool, error) {
		state, err := stateOf(reply)
		return err == nil && state.Tunnel.Observation != ipc.ObservationCurrent, err
	})
	if err != nil {
		return nil, err
	}
	state, err := stateOf(reply)
	if err != nil {
		return nil, err
	}
	return newModeStatus(state), nil
}

func (s *session) inventory(regionID string, isLong bool) (data, error) {
	if err := s.requireCurrent(); err != nil {
		return nil, err
	}
	state, settled, err := s.pollSettled(func(state ipc.State) bool { return state.Inventory == ipc.InventoryRefreshing })
	if err != nil {
		return nil, err
	}
	if !settled {
		if isPendingRestoration(state) {
			return nil, newError(codeTimeout, "CloudGateway is still restoring this session", "")
		}
		return nil, newError(codeTimeout, "CloudGateway is still loading inventory", "")
	}
	if state.AccountID == nil {
		return nil, accountError(state, "Unable to reach CloudGateway to restore this account")
	}
	if state.Inventory == ipc.InventoryUnavailable {
		return nil, newError(codeNetworkUnavailable, "Inventory is unavailable for this account", "")
	}
	if regionID != "" {
		if regionID, err = resolveInventoryRegion(regionID, state, *state.AccountID); err != nil {
			return nil, err
		}
	}
	return newInventory(state, *state.AccountID, regionID, false, false, isLong), nil
}

// status can read another daemon version's tunnel, without account details. Human status asks the
// daemon whether a connected server still responds
func (s *session) status(checkServer bool) (data, error) {
	if err := s.connect(); err != nil {
		return nil, err
	}
	limit := s.observationLimit()
	if s.current {
		request := ipc.Request{Action: ipc.ActionSnapshot, CheckServer: checkServer}
		reply, _, err := s.poll(request, limit, func(reply ipc.Reply) (bool, error) {
			state, err := stateOf(reply)
			return err == nil && state.Tunnel.Observation != ipc.ObservationCurrent, err
		})
		if err != nil {
			return nil, err
		}
		state, err := stateOf(reply)
		if err != nil {
			return nil, err
		}
		mode, auth := newModeStatus(state), newAuthStatus(state)
		return status{tunnel: publicTunnel(state.Tunnel), operation: s.operationOf(reply), update: s.updateOf(reply),
			mode: &mode, auth: &auth, serverResponding: state.ServerResponding}, nil
	}
	reply, _, err := s.poll(ipc.Request{Action: ipc.ActionHandshake}, limit, func(reply ipc.Reply) (bool, error) {
		if reply.Lifecycle == nil {
			return false, controllerFailure(ipc.FailureInvalidRequest)
		}
		return reply.Lifecycle.Tunnel.Observation != ipc.ObservationCurrent, nil
	})
	if err != nil {
		return nil, err
	}
	return status{tunnel: coarseTunnel(reply.Lifecycle.Tunnel), operation: s.operationOf(reply)}, nil
}

// operationOf trusts the daemon to have already hidden account-bound outcomes from this session
func (s *session) operationOf(reply ipc.Reply) *operation {
	if reply.Operation == nil {
		return nil
	}
	op := newOperation(*reply.Operation, reply.Outcome)
	return &op
}

// updateOf reads a managed update only from a daemon this CLI matches
func (s *session) updateOf(reply ipc.Reply) *update {
	if !s.current {
		return nil
	}
	return replyUpdate(reply)
}

func replyUpdate(reply ipc.Reply) *update {
	if reply.Update == nil {
		return nil
	}
	u := newUpdate(*reply.Update)
	return &u
}

// tunnelOf prefers the detailed tunnel, falling back to the coarse view another daemon version can share
func (s *session) tunnelOf(reply ipc.Reply) tunnel {
	switch {
	case s.current && reply.State != nil:
		return publicTunnel(reply.State.Tunnel)
	case reply.State != nil:
		return coarseTunnel(reply.State.Tunnel)
	case reply.Lifecycle != nil:
		return coarseTunnel(reply.Lifecycle.Tunnel)
	}
	return coarseTunnel(s.lifecycle.Tunnel)
}

func sameID(a, b string) bool { return strings.EqualFold(a, b) }

// operation is a single lookup that also reports the current observed state. If the connection is
// lost, as when an update restarts the daemon, it repeats the lookup on the restarted daemon
func (s *session) operation(id string) (data, error) {
	if err := s.open(); err != nil {
		return nil, err
	}
	if err := s.connect(); err != nil {
		return nil, err
	}
	lookup := ipc.Request{Action: ipc.ActionOperation, ContextID: id}
	reply, err := s.call(lookup)
	for isControllerFailure(err, ipc.FailureUnavailable) {
		if err = s.reconnect(); err == nil {
			reply, err = s.call(lookup)
		}
	}
	if err != nil {
		return nil, err
	}
	if reply.Operation == nil || !sameID(reply.Operation.ID, id) {
		return nil, errorCode(codeInvalidResponse)
	}
	op := s.operationOf(reply)
	u := s.updateOf(reply)
	if u != nil && !sameID(u.id, id) {
		return nil, errorCode(codeInvalidResponse)
	}
	result := status{tunnel: s.tunnelOf(reply), operation: op, update: u}
	if s.current && reply.State != nil {
		mode, auth := newModeStatus(*reply.State), newAuthStatus(*reply.State)
		result.mode, result.auth = &mode, &auth
	}
	failure := updateFailure(u)
	if failure == nil {
		failure = op.failure
	}
	if failure == nil {
		return result, nil
	}
	if u != nil {
		failure = updateObservationFailure(failure, id)
	}
	failure = copyError(failure)
	failure.data = result
	return nil, failure
}

// reconnect waits out a daemon restart, then repeats the handshake on a new connection until the
// daemon has finished starting
func (s *session) reconnect() error {
	for {
		s.close()
		if err := s.sleep(); err != nil {
			return err
		}
		err := s.open()
		if err == nil {
			err = s.connect()
		}
		if err == nil && s.lifecycle.State != ipc.LifecycleDraining {
			return nil
		}
		if err != nil && !isControllerFailure(err, ipc.FailureUnavailable) {
			return err
		}
	}
}

// copyError keeps shared code defaults and operation records from picking up data
func copyError(e *cliError) *cliError {
	copied := *e
	return &copied
}
