package cli

import (
	"errors"
	"slices"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

func isPendingUpdateStartup(s ipc.State) bool {
	return isPendingRestoration(s) || isAwaitingVerification(s) || s.Inventory == ipc.InventoryRefreshing ||
		s.Tunnel.Observation != ipc.ObservationCurrent
}

func (s *session) update(allowDisconnect bool, accepted func(string) error) (data, error) {
	if err := s.requireCurrent(); err != nil {
		return nil, err
	}
	id := newUUID()
	request := ipc.Request{Action: ipc.ActionUpdate, ID: id, AllowDisconnect: allowDisconnect}
	reply, err := s.call(request)
	if err != nil {
		return nil, err
	}
	if reply.Update != nil && reply.Update.Error == string(codeBusy) && reply.State != nil && isPendingUpdateStartup(*reply.State) {
		_, settled, err := s.poll(ipc.Request{Action: ipc.ActionSnapshot}, s.deadline, func(reply ipc.Reply) (bool, error) {
			state, err := stateOf(reply)
			return err == nil && isPendingUpdateStartup(state), err
		})
		if err != nil {
			return nil, err
		}
		if !settled {
			return nil, newError(codeTimeout, "CloudGateway is still restoring update prerequisites", "")
		}
		if reply, err = s.call(request); err != nil {
			return nil, err
		}
	}
	if reply.Operation == nil || !sameID(reply.Operation.ID, id) || reply.Update == nil || !sameID(reply.Update.ID, id) {
		return nil, errorCode(codeInvalidResponse)
	}
	if reply.Operation.State != ipc.OperationAccepted {
		// A refused reservation is never retained, so there is no operation to look up
		return s.updateResult(reply, id, reply.Operation.State == ipc.OperationCompleted)
	}
	if reply.Update.Phase != ipc.UpdatePrepared {
		return nil, errorCode(codeInvalidResponse)
	}
	// Output must succeed before confirmation can authorize any effects
	if err := accepted(id); err != nil {
		return nil, err
	}
	result, err := s.observeUpdate(id)
	if err != nil {
		return nil, updateObservationFailure(asError(err), id)
	}
	return result, nil
}

// observeUpdate confirms the update, then follows it. The daemon exits so systemd restarts it on the
// installed release, so a lost connection, even during confirmation, continues with a lookup on the
// restarted daemon. The update request itself is never resent
func (s *session) observeUpdate(id string) (data, error) {
	lookup := ipc.Request{Action: ipc.ActionOperation, ContextID: id}
	reply, err := s.call(ipc.Request{Action: ipc.ActionConfirm, ContextID: id})
	if err != nil && !errors.Is(err, errNoConnection) {
		return nil, confirmFailure(err)
	}
	for {
		for errors.Is(err, errNoConnection) {
			if err = s.reconnect(); err == nil && !s.current {
				err = s.versionError()
				if op := s.handshakeOperation; s.lifecycle.State == ipc.LifecycleCurrent && op != nil && sameID(op.ID, id) &&
					op.State == ipc.OperationCompleted {
					// The restarted daemon speaks another protocol but reports this update completed
					err = newError(codeIncompatibleVersion, "CloudGateway updated to a release this CLI process doesn't match", "No restart is needed")
				}
			}
			if err == nil {
				reply, err = s.call(lookup)
			}
		}
		if err != nil {
			return nil, err
		}
		if reply.Operation == nil || !sameID(reply.Operation.ID, id) {
			return nil, errorCode(codeInvalidResponse)
		}
		if u := reply.Update; u != nil {
			if !sameID(u.ID, id) {
				return nil, errorCode(codeInvalidResponse)
			}
			if u.Phase == ipc.UpdateApprovalRequired || u.Phase == ipc.UpdateRestartRequired {
				break
			}
		}
		if reply.Operation.State != ipc.OperationAccepted && reply.Operation.State != ipc.OperationRunning {
			break
		}
		if err = s.sleep(); err == nil {
			reply, err = s.call(lookup)
		}
	}
	return s.updateResult(reply, id, true)
}

func (s *session) updateResult(reply ipc.Reply, id string, isRetained bool) (data, error) {
	if reply.Operation == nil || !sameID(reply.Operation.ID, id) {
		return nil, errorCode(codeInvalidResponse)
	}
	op := s.operationOf(reply)
	u := s.updateOf(reply)
	m := mutation{command: "update", operation: *op, tunnel: s.tunnelOf(reply), update: u}
	failure := updateFailure(u)
	if failure == nil {
		failure = op.failure
	}
	if failure != nil {
		if isRetained {
			failure = updateObservationFailure(failure, id)
		} else {
			failure = copyError(failure)
		}
		failure.data = m
		return nil, failure
	}
	if op.state != string(ipc.OperationCompleted) {
		return nil, errorCode(codeInvalidResponse)
	}
	return m, nil
}

func updateFailure(u *update) *cliError {
	switch {
	case u == nil:
		return nil
	case u.phase == string(ipc.UpdateApprovalRequired):
		return errorCode(codeApprovalRequired)
	case u.phase == string(ipc.UpdateRestartRequired):
		return errorCode(codeRestartRequired)
	case u.err != nil:
		return copyError(u.err)
	case u.phase == string(ipc.UpdateSuperseded):
		return errorCode(codeUpdateSuperseded)
	}
	return nil
}

func updateObservationFailure(original *cliError, id string) *cliError {
	if original.operationID != "" {
		return copyError(original)
	}
	guidance := "Check this operation before retrying: cloudgateway status --operation " + id
	suggestion := guidance
	switch {
	case slices.Contains([]code{codeTimeout, codeInterrupted, codeOperationUnknown, codeControllerUnavailable,
		codeControllerRejected, codeInvalidResponse}, original.code):
		suggestion = "Observation stopped. Confirmed update work can keep running. " + guidance
	case original.suggestion != nil:
		suggestion = *original.suggestion + ". " + guidance
	}
	return &cliError{code: original.code, message: original.message, suggestion: &suggestion, data: original.data, operationID: id}
}
