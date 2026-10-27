package cli

import (
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

const updateConfig = "uid1/us-sanjose-1/" + firstUUID

// updateHarness reserves an update, then reports each phase in turn on confirm and operation polls
func updateHarness(t *testing.T, reconnect bool, phases ...ipc.UpdatePhase) *harness {
	if len(phases) == 0 {
		phases = []ipc.UpdatePhase{ipc.UpdateActivating, ipc.UpdateCheckingReadiness, ipc.UpdateCompleted}
	}
	h := newHarness(t, testState())
	identifier := ""
	if reconnect {
		identifier = updateConfig
	}
	var id string
	h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		state := testState()
		switch request.Action {
		case ipc.ActionUpdate:
			id = request.ID
			return &ipc.Reply{State: &state, Operation: &ipc.Operation{ID: id, State: ipc.OperationAccepted},
				Update: &ipc.UpdateStatus{ID: id, Phase: ipc.UpdatePrepared, Target: testBuild, Identifier: identifier, Reconnect: reconnect}}
		case ipc.ActionConfirm, ipc.ActionOperation:
			if request.ContextID != id || !strings.Contains(h.out.String(), id) {
				t.Errorf("%s before acceptance printed", request.Action)
			}
			phase := phases[0]
			if len(phases) > 1 {
				phases = phases[1:]
			}
			update := ipc.UpdateStatus{ID: id, Phase: phase, Target: testBuild, Identifier: identifier, Reconnect: reconnect}
			return &ipc.Reply{State: &state, Operation: ptr(update.Operation()), Update: &update}
		}
		return nil
	}
	return h
}

func TestUpdateFlushesAcceptanceAndObservesTheRecord(t *testing.T) {
	h := updateHarness(t, true)
	expectExit(t, h.run("update", "--allow-disconnect", "--json"), 0)
	records := h.records()
	expectEqual(t, "records", len(records), 2)
	expectEqual(t, "accepted", field(records[0], "type"), any("accepted"))
	expectEqual(t, "same id", field(records[0], "operationId"), field(records[1], "operationId"))
	expectEqual(t, "phase", field(records[1], "data", "update", "phase"), any("completed"))
	expectEqual(t, "config", field(records[1], "data", "update", "configId"), any(updateConfig))
	expectEqual(t, "reconnect", field(records[1], "data", "update", "reconnect"), any(true))
	expectEqual(t, "code hash", field(records[1], "data", "update", "target", "codeHash"), any(testBuild.CodeHash))
	expectEqual(t, "tunnel", field(records[1], "data", "tunnel", "state"), any("disconnected"))
	expectEqual(t, "allow disconnect", h.daemon.requestsFor(ipc.ActionUpdate)[0].AllowDisconnect, true)
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionUpdate, ipc.ActionConfirm, ipc.ActionOperation, ipc.ActionOperation)
	h.reset()
	h2 := updateHarness(t, false, ipc.UpdateCompleted)
	expectExit(t, h2.run("update"), 0)
	id := h2.daemon.requestsFor(ipc.ActionUpdate)[0].ID
	expectEqual(t, "human", h2.out.String(), "Accepted operation "+id+"\nCloudGateway update completed\nVPN:          disconnected\n"+
		"Observation:  current at 2027-01-15T08:00:00Z\nOperation:    "+id+" completed\nUpdate:       "+id+" completed\n"+
		"Target:       1.2.0 (1.2.0)\nReconnect:    disabled\n")
}

func TestUpdateLeavesPreparedWorkUnconfirmedWhenAcceptanceCannotPrint(t *testing.T) {
	h := updateHarness(t, true)
	h.failsOutput = true
	expectExit(t, h.run("update", "--json"), 1)
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionUpdate)
}

func TestUpdateMatchingReleaseNeedsNoConfirmation(t *testing.T) {
	h := newHarness(t)
	h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action != ipc.ActionUpdate {
			return nil
		}
		state := testState(func(s *ipc.State) { s.Tunnel.Phase = ipc.TunnelConnected })
		update := ipc.UpdateStatus{ID: request.ID, Phase: ipc.UpdateCompleted, Target: testBuild}
		return &ipc.Reply{State: &state, Operation: ptr(update.Operation()), Update: &update}
	}
	expectExit(t, h.run("update", "--json"), 0)
	records := h.records()
	expectEqual(t, "records", len(records), 1)
	expectEqual(t, "type", field(records[0], "type"), any("result"))
	expectEqual(t, "tunnel", field(records[0], "data", "tunnel", "state"), any("connected"))
	expectEqual(t, "config", field(records[0], "data", "update", "configId"), nil)
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionUpdate)
}

func TestUpdateRefusedReservationKeepsPreciseFailure(t *testing.T) {
	h := newHarness(t)
	h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action != ipc.ActionUpdate {
			return nil
		}
		state := testState()
		update := ipc.UpdateStatus{ID: request.ID, Phase: ipc.UpdateFailed, Target: testBuild, Error: "storage_unavailable"}
		return &ipc.Reply{State: &state, Operation: ptr(update.Operation()), Update: &update}
	}
	expectExit(t, h.run("update", "--json"), 6)
	expectEqual(t, "code", field(h.last(), "error", "code"), any("storage_unavailable"))
	expectEqual(t, "suggestion", field(h.last(), "error", "suggestion"), any("Check this machine's available storage and permissions"))
	expectEqual(t, "operation", field(h.last(), "operationId"), nil)
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionUpdate)
}

func TestUpdateWaitsForStartupBeforeReservingAgainWithTheSameID(t *testing.T) {
	h := newHarness(t, testState(func(s *ipc.State) { s.Inventory = ipc.InventoryRefreshing }), testState())
	var ids []string
	h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action != ipc.ActionUpdate {
			return nil
		}
		ids = append(ids, request.ID)
		state := testState(func(s *ipc.State) { s.Inventory = ipc.InventoryRefreshing })
		update := ipc.UpdateStatus{ID: request.ID, Phase: ipc.UpdateCompleted, Target: testBuild}
		if len(ids) == 1 {
			update = ipc.UpdateStatus{ID: request.ID, Phase: ipc.UpdateFailed, Target: testBuild, Error: "busy"}
		}
		return &ipc.Reply{State: &state, Operation: ptr(update.Operation()), Update: &update}
	}
	expectExit(t, h.run("update", "--json"), 0)
	expectEqual(t, "attempts", len(ids), 2)
	expectEqual(t, "same id", ids[0], ids[1])
}

func TestUpdateFollowsTheOperationAcrossADaemonRestart(t *testing.T) {
	h := updateHarness(t, false, ipc.UpdateActivating, ipc.UpdateCompleted)
	h.realClock = true
	answer := h.daemon.onRequest
	restarted := false
	h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionOperation && !restarted {
			// The daemon persists the record, exits, and systemd starts it on the new release
			restarted = true
			go func() {
				h.daemon.stop()
				time.Sleep(50 * time.Millisecond)
				h.daemon.listen()
			}()
			return dropReply
		}
		return answer(request)
	}
	expectExit(t, h.run("update", "--json", "--timeout", "10"), 0)
	expectEqual(t, "phase", field(h.last(), "data", "update", "phase"), any("completed"))
	expectEqual(t, "reservations", len(h.daemon.requestsFor(ipc.ActionUpdate)), 1)
	expectEqual(t, "confirmations", len(h.daemon.requestsFor(ipc.ActionConfirm)), 1)
	expectEqual(t, "activity", len(h.daemon.requestsFor(ipc.ActionUserActivity)), 1)
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionUpdate, ipc.ActionConfirm, ipc.ActionOperation,
		ipc.ActionHandshake, ipc.ActionOperation)
}

func TestUpdateReconnectReportsAVersionChangeWithRecovery(t *testing.T) {
	h := updateHarness(t, false, ipc.UpdateActivating, ipc.UpdateCompleted)
	answer := h.daemon.onRequest
	h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionOperation {
			h.daemon.version = ipc.Version + 1
			return dropReply
		}
		return answer(request)
	}
	expectExit(t, h.run("update", "--json"), 4)
	id := h.daemon.requestsFor(ipc.ActionUpdate)[0].ID
	expectEqual(t, "code", field(h.last(), "error", "code"), any("incompatible_version"))
	expectEqual(t, "suggestion", field(h.last(), "error", "suggestion"), any("Wait for the daemon restart to finish, or run: sudo systemctl restart cloudgatewayd. "+
		"Check this operation before retrying: cloudgateway status --operation "+id))
	expectEqual(t, "reservations", len(h.daemon.requestsFor(ipc.ActionUpdate)), 1)
}

func TestUpdateTimeoutUsesOneDeadlineAndDetachesWithoutCancellingWork(t *testing.T) {
	h := updateHarness(t, true, ipc.UpdateCheckingReadiness)
	expectExit(t, h.run("update", "--timeout", "1", "--json"), 8)
	expectEqual(t, "elapsed", h.clock.elapsed(), time.Second)
	id := h.daemon.requestsFor(ipc.ActionUpdate)[0].ID
	expectEqual(t, "suggestion", field(h.last(), "error", "suggestion"),
		any("Observation stopped. Confirmed update work can keep running. Check this operation before retrying: cloudgateway status --operation "+id))
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionUpdate, ipc.ActionConfirm, ipc.ActionOperation)
	defaulted := updateHarness(t, true, ipc.UpdateCheckingReadiness)
	expectExit(t, defaulted.run("update", "--json"), 8)
	expectEqual(t, "elapsed", defaulted.clock.elapsed(), 300*time.Second)
}

// The daemon may exit to restart while answering the confirmation. The lookup then shows whether it ran
func TestUpdateLostConfirmationFollowsTheOperationWithoutResending(t *testing.T) {
	h := updateHarness(t, true, ipc.UpdateCompleted)
	answer := h.daemon.onRequest
	h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionConfirm {
			return dropReply
		}
		return answer(request)
	}
	expectExit(t, h.run("update", "--json"), 0)
	expectEqual(t, "phase", field(h.last(), "data", "update", "phase"), any("completed"))
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionUpdate, ipc.ActionConfirm,
		ipc.ActionHandshake, ipc.ActionOperation)

	unknown := updateHarness(t, true)
	answer = unknown.daemon.onRequest
	unknown.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		switch request.Action {
		case ipc.ActionConfirm:
			return dropReply
		case ipc.ActionOperation:
			return &ipc.Reply{Operation: &ipc.Operation{ID: request.ContextID, State: ipc.OperationUnknown}}
		}
		return answer(request)
	}
	expectExit(t, unknown.run("update", "--json"), 10)
	id := unknown.daemon.requestsFor(ipc.ActionUpdate)[0].ID
	expectEqual(t, "suggestion", field(unknown.last(), "error", "suggestion"),
		any("Observation stopped. Confirmed update work can keep running. Check this operation before retrying: cloudgateway status --operation "+id))
	expectEqual(t, "reservations", len(unknown.daemon.requestsFor(ipc.ActionUpdate)), 1)
	expectEqual(t, "confirmations", len(unknown.daemon.requestsFor(ipc.ActionConfirm)), 1)

	rejected := updateHarness(t, true)
	answer = rejected.daemon.onRequest
	rejected.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionConfirm {
			return &ipc.Reply{Error: ipc.FailurePreparationExpired}
		}
		return answer(request)
	}
	expectExit(t, rejected.run("update", "--json"), 10)
	expectEqual(t, "code", field(rejected.last(), "error", "code"), any("operation_unknown"))
	expectActions(t, rejected.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionUpdate, ipc.ActionConfirm)
}

func TestInterruptAfterConfirmationOnlyDetaches(t *testing.T) {
	for _, sig := range []syscall.Signal{syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP} {
		h := updateHarness(t, true)
		answer := h.daemon.onRequest
		h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
			if request.Action == ipc.ActionOperation {
				h.signal(sig)
				return hangReply
			}
			return answer(request)
		}
		expectExit(t, h.run("update", "--json"), 130)
		records := h.records()
		expectEqual(t, "records", len(records), 2)
		expectEqual(t, "same id", field(records[0], "operationId"), field(records[1], "operationId"))
		expectEqual(t, "code", field(records[1], "error", "code"), any("interrupted"))
		expectContains(t, field(records[1], "error", "suggestion").(string), "Observation stopped. Confirmed update work can keep running")
		expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionUpdate, ipc.ActionConfirm, ipc.ActionOperation)
	}
	down := newHarness(t, testState())
	down.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		switch request.Action {
		case ipc.ActionTurnOff:
			return &ipc.Reply{Operation: &ipc.Operation{ID: request.ID, State: ipc.OperationAccepted}}
		case ipc.ActionConfirm:
			down.signal(syscall.SIGINT)
			return hangReply
		}
		return nil
	}
	expectExit(t, down.run("down"), 130)
	id := down.daemon.requestsFor(ipc.ActionTurnOff)[0].ID
	expectEqual(t, "output", down.out.String(), "Accepted operation "+id+"\n")
	expectEqual(t, "diagnostics", down.diag.String(), "Error: The caller was interrupted\n"+
		"Check this operation before retrying: cloudgateway status --operation "+id+"\n")
	expectActions(t, down.daemon, ipc.ActionHandshake, ipc.ActionTurnOff, ipc.ActionConfirm)

	reading := newHarness(t, testState(func(s *ipc.State) { s.Inventory = ipc.InventoryRefreshing }))
	reading.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionSnapshot {
			reading.signal(syscall.SIGQUIT)
			return hangReply
		}
		return nil
	}
	expectExit(t, reading.run("list", "--json"), 130)
	expectEqual(t, "record", reading.out.String(), `{"command":"list","data":null,"error":{"code":"interrupted","message":"The caller was interrupted","suggestion":null},"operationId":null,"schemaVersion":1,"type":"error"}`+"\n")
}

func TestStatusShowsPendingUpdateAndLooksItUpAcrossARestart(t *testing.T) {
	id := "6f9619ff-8b86-d011-b42d-00c04fc964ff"
	h := newHarness(t, testState(func(s *ipc.State) { s.Tunnel.Phase, s.Tunnel.ConfigID = ipc.TunnelConnected, ptr(updateConfig) }))
	update := ipc.UpdateStatus{ID: id, Phase: ipc.UpdateCheckingReadiness, Target: testBuild, Identifier: updateConfig, Reconnect: true}
	h.daemon.operation, h.daemon.update = ptr(update.Operation()), &update
	expectExit(t, h.run("status", "--json"), 0)
	expectEqual(t, "tunnel", field(h.last(), "data", "tunnel", "state"), any("connected"))
	expectEqual(t, "phase", field(h.last(), "data", "update", "phase"), any("checking_readiness"))
	expectEqual(t, "operation", field(h.last(), "data", "operation", "state"), any("running"))
	h.reset()
	expectExit(t, h.run("status"), 0)
	expectContains(t, h.out.String(), "Update:         "+id+" checking daemon readiness\n")
	expectContains(t, h.out.String(), "Reconnect:      captured config, subject to readiness and current authorization\n")

	// The update restarts the daemon during the lookup, which then answers on the new release
	lookup := newHarness(t, testState())
	lookup.realClock = true
	completed := ipc.UpdateStatus{ID: id, Phase: ipc.UpdateCompleted, Target: testBuild}
	lookup.daemon.operation, lookup.daemon.update = ptr(completed.Operation()), &completed
	restarted := false
	lookup.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionOperation && !restarted {
			restarted = true
			go func() {
				lookup.daemon.stop()
				time.Sleep(50 * time.Millisecond)
				lookup.daemon.listen()
			}()
			return dropReply
		}
		return nil
	}
	expectExit(t, lookup.run("status", "--operation", id, "--json", "--timeout", "10"), 0)
	expectEqual(t, "update id", field(lookup.last(), "data", "update", "id"), any(id))
	expectEqual(t, "envelope", field(lookup.last(), "operationId"), any(id))
	expectActions(t, lookup.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionOperation, ipc.ActionHandshake, ipc.ActionOperation)

	// The daemon only answers another IPC version's handshake
	other := newHarness(t, testState())
	other.daemon.version = ipc.Version + 1
	expectExit(t, other.run("status", "--operation", id, "--json"), 4)
	expectEqual(t, "code", field(other.last(), "error", "code"), any("incompatible_version"))
	expectMissing(t, other.out.String(), updateConfig)
	expectActions(t, other.daemon, ipc.ActionHandshake, ipc.ActionOperation)
}

func TestStatusOperationFailsFastWhenTheDaemonIsDown(t *testing.T) {
	h := newHarness(t)
	h.daemon.stop()
	expectExit(t, h.run("status", "--operation", "6f9619ff-8b86-d011-b42d-00c04fc964ff", "--json"), 4)
	expectEqual(t, "code", field(h.last(), "error", "code"), any("controller_unavailable"))
	expectEqual(t, "elapsed", h.clock.elapsed(), 0)
	expectEqual(t, "dials", h.daemon.acceptCount(), 0)
}

// A live daemon replying unavailable keeps its connection. Only a dropped connection follows a restart
func TestUnavailableRepliesAreNotTreatedAsDaemonRestarts(t *testing.T) {
	polling := updateHarness(t, true)
	answer := polling.daemon.onRequest
	polling.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionOperation {
			return &ipc.Reply{Error: ipc.FailureUnavailable}
		}
		return answer(request)
	}
	expectExit(t, polling.run("update", "--json"), 4)
	id := polling.daemon.requestsFor(ipc.ActionUpdate)[0].ID
	expectEqual(t, "code", field(polling.last(), "error", "code"), any("controller_unavailable"))
	expectEqual(t, "suggestion", field(polling.last(), "error", "suggestion"),
		any("Observation stopped. Confirmed update work can keep running. Check this operation before retrying: cloudgateway status --operation "+id))
	expectActions(t, polling.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionUpdate, ipc.ActionConfirm, ipc.ActionOperation)
	expectEqual(t, "connections", polling.daemon.acceptCount(), 1)

	confirming := updateHarness(t, true)
	answer = confirming.daemon.onRequest
	confirming.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionConfirm {
			return &ipc.Reply{Error: ipc.FailureUnavailable}
		}
		return answer(request)
	}
	expectExit(t, confirming.run("update", "--json"), 10)
	expectEqual(t, "code", field(confirming.last(), "error", "code"), any("operation_unknown"))
	expectActions(t, confirming.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionUpdate, ipc.ActionConfirm)

	lookup := newHarness(t)
	lookup.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionOperation {
			return &ipc.Reply{Error: ipc.FailureUnavailable}
		}
		return nil
	}
	expectExit(t, lookup.run("status", "--operation", "6f9619ff-8b86-d011-b42d-00c04fc964ff", "--json"), 4)
	expectEqual(t, "code", field(lookup.last(), "error", "code"), any("controller_unavailable"))
	expectActions(t, lookup.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionOperation)
	expectEqual(t, "elapsed", lookup.clock.elapsed(), 0)
}
