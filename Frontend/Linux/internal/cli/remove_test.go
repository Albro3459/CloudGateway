package cli

import (
	"strings"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

const (
	removeConfig      = "uid1/us-sanjose-1/" + firstUUID
	otherRemoveConfig = "uid1/us-sanjose-1/" + secondUUID
)

func removeState() ipc.State {
	return testState(withClients(
		testClient(otherRemoveConfig, "California", 0, "Laptop", func(c *ipc.Client) { c.OwnerLabel = ptr("b@example.com") }),
		testClient(removeConfig, "California", 0, "Desktop", func(c *ipc.Client) {
			c.OwnerLabel, c.Installed, c.Eligibility, c.Status = ptr("a@example.com"), false, "config_missing", ""
		}),
		testClient("uid2/us-sanjose-1/"+firstUUID, "California", 0, "Other account"),
	), withSelected(otherRemoveConfig))
}

// removeHarness reserves removal of removeConfig and answers its confirmation with outcome
func removeHarness(t *testing.T, outcome *ipc.Outcome, state ipc.OperationState, states ...ipc.State) *harness {
	if len(states) == 0 {
		states = []ipc.State{removeState()}
	}
	h := newHarness(t, states...)
	h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		switch request.Action {
		case ipc.ActionRemoveClient:
			if request.Identifier != removeConfig || request.RegionID != "" || request.ClientName != "" || request.AllowDisconnect {
				t.Errorf("remove request %+v", request)
			}
			return &ipc.Reply{Operation: &ipc.Operation{ID: request.ID, State: ipc.OperationAccepted}}
		case ipc.ActionConfirm:
			return &ipc.Reply{Operation: &ipc.Operation{ID: request.ContextID, State: state}, Outcome: outcome}
		}
		return nil
	}
	return h
}

func expectRemovalRecovery(t *testing.T, h *harness, isJSON bool) {
	t.Helper()
	id := h.daemon.requestsFor(ipc.ActionRemoveClient)[0].ID
	suggestion := h.diag.String()
	if isJSON {
		expectEqual(t, "operation", field(h.last(), "operationId"), any(id))
		suggestion = field(h.last(), "error", "suggestion").(string)
	} else {
		expectContains(t, h.out.String(), id)
	}
	expectContains(t, suggestion, "Check this operation before retrying: cloudgateway status --operation "+id+removalRecovery)
	expectMissing(t, suggestion, removeConfig)
	expectEqual(t, "reservations", len(h.daemon.requestsFor(ipc.ActionRemoveClient)), 1)
	if len(h.daemon.requestsFor(ipc.ActionConfirm)) > 1 {
		t.Fatal("confirmation resent")
	}
}

func TestRemoveRequiresConsentAndSelectorBeforeDialing(t *testing.T) {
	for _, isJSON := range []bool{false, true} {
		for _, arguments := range [][]string{{"remove"}, {"remove", "--yes"}, {"remove", firstUUID}, {"remove", "sanjose", "1"},
			{"remove", firstUUID, "--yes=false"}, {"remove", "sanjose", "0", "--yes"}, {"remove", removeConfig, "--yes"}} {
			h := newHarness(t, removeState())
			arguments = append(arguments, "--non-interactive")
			if isJSON {
				arguments = append(arguments, "--json")
			}
			expectExit(t, h.run(arguments...), 2)
			expectEqual(t, "dials", h.daemon.acceptCount(), 0)
			expectMissing(t, h.out.String(), "Accepted operation")
		}
	}
}

func TestRemoveResolvesCanonicalIdentifierOnceFromFullAccountInventory(t *testing.T) {
	for _, sel := range [][]string{{strings.ToUpper(firstUUID)}, {"us-sanjose-1", "1"}, {"California", "01"}, {"sanjose", "1"}} {
		h := removeHarness(t, &ipc.Outcome{Kind: ipc.OutcomeCompleted}, ipc.OperationCompleted)
		expectExit(t, h.run(append(append([]string{"remove"}, sel...), "--yes", "--json", "--non-interactive")...), 0)
		records := h.records()
		expectEqual(t, "records", len(records), 2)
		expectEqual(t, "accepted", field(records[0], "type"), any("accepted"))
		expectEqual(t, "command", field(records[0], "command"), any("remove"))
		expectEqual(t, "same id", field(records[0], "operationId"), field(records[1], "operationId"))
		expectEqual(t, "error", field(records[1], "error"), nil)
		expectEqual(t, "data command", field(records[1], "data", "command"), any("remove"))
		expectEqual(t, "result", field(records[1], "data", "operation", "result"), any("completed"))
		expectEqual(t, "config", field(records[1], "data", "operation", "configId"), nil)
		expectEqual(t, "choices", field(records[1], "data", "choices"), nil)
		if _, ok := records[1]["data"].(map[string]any)["creation"]; ok {
			t.Fatal("creation serialized")
		}
		expectMissing(t, h.out.String(), "uid1/")
		expectMissing(t, h.out.String(), "uid2/")
		expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot, ipc.ActionRemoveClient, ipc.ActionConfirm)
	}
}

func TestRemoveIncludesDisabledConfiglessInactiveAndCachedRows(t *testing.T) {
	for _, eligibility := range []string{"region_unavailable", "config_missing", "inactive", "eligible"} {
		for _, cached := range []bool{false, true} {
			state := testState(withClients(testClient(removeConfig, "California", 0, "Mac", func(c *ipc.Client) {
				c.Installed, c.Eligibility, c.Status = false, eligibility, ""
				if cached {
					c.Source = "cache"
				}
			})), withSelected(otherRemoveConfig))
			if cached {
				state.Access, state.Inventory = ipc.AccessOffline, ipc.InventoryCached
			}
			h := removeHarness(t, &ipc.Outcome{Kind: ipc.OutcomeCompleted}, ipc.OperationCompleted, state)
			expectExit(t, h.run("remove", firstUUID, "--yes"), 0)
			expectContains(t, h.out.String(), "Client removed\n")
		}
	}
}

func TestRemoveWaitsForRestorationVerificationAndInventory(t *testing.T) {
	h := removeHarness(t, &ipc.Outcome{Kind: ipc.OutcomeCompleted}, ipc.OperationCompleted,
		testState(signedOut, func(s *ipc.State) { s.IsRestoring, s.HasRetainedSession, s.Access = true, true, ipc.AccessChecking }),
		testState(signedOut, func(s *ipc.State) { s.HasRetainedSession = true }),
		testState(func(s *ipc.State) { s.Inventory = ipc.InventoryRefreshing }, withClients(testClient(removeConfig, "California", 0, "Old"))),
		removeState())
	expectExit(t, h.run("remove", "sanjose", "1", "--yes"), 0)
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot, ipc.ActionSnapshot, ipc.ActionSnapshot,
		ipc.ActionSnapshot, ipc.ActionRemoveClient, ipc.ActionConfirm)
	expectEqual(t, "elapsed", h.clock.elapsed(), 3*pollInterval)
}

func TestRemoveRejectsMissingAmbiguousAndOtherAccountTargets(t *testing.T) {
	collision := testState(withClients(testClient(removeConfig, "California", 0, "A"),
		testClient("uid1/eu-sanjose-2/"+firstUUID, "California", 0, "B")))
	foreign := testState(withClients(testClient("uid2/us-sanjose-1/"+firstUUID, "California", 0, "Other")))
	cases := []struct {
		state    ipc.State
		selector []string
		exit     int
	}{
		{removeState(), []string{"chicago", "1"}, 2}, {removeState(), []string{"sanjose", "3"}, 2},
		{removeState(), []string{thirdUUID}, 5}, {foreign, []string{firstUUID}, 5},
		{collision, []string{"sanjose", "1"}, 2}, {collision, []string{"California", "1"}, 2}, {collision, []string{firstUUID}, 5},
	}
	for _, tc := range cases {
		h := newHarness(t, tc.state)
		expectExit(t, h.run(append(append([]string{"remove"}, tc.selector...), "--yes", "--json")...), tc.exit)
		expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot)
		expectMissing(t, h.out.String(), "uid2/")
	}
	exact := removeHarness(t, &ipc.Outcome{Kind: ipc.OutcomeCompleted}, ipc.OperationCompleted, collision)
	expectExit(t, exact.run("remove", "us-sanjose-1", "1", "--yes"), 0)
}

func TestRemovePreservesAccountAndInventoryGatesBeforeReservation(t *testing.T) {
	cases := []struct {
		edit func(*ipc.State)
		code string
		exit int
	}{
		{signedOut, "sign_in_required", 3},
		{func(s *ipc.State) { signedOut(s); s.Access = ipc.AccessDenied }, "access_denied", 3},
		{func(s *ipc.State) { signedOut(s); s.HasRetainedSession, s.Access = true, ipc.AccessUnreachable }, "network_unavailable", 6},
		{func(s *ipc.State) { s.Inventory = ipc.InventoryUnavailable }, "network_unavailable", 6},
	}
	for _, tc := range cases {
		h := newHarness(t, testState(tc.edit))
		expectExit(t, h.run("remove", firstUUID, "--yes", "--json"), tc.exit)
		expectEqual(t, "code", field(h.last(), "error", "code"), any(tc.code))
		expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot)
	}
	draining := newHarness(t, removeState())
	draining.daemon.lifecycle = ipc.LifecycleDraining
	expectExit(t, draining.run("remove", firstUUID, "--yes", "--json"), 4)
	expectActions(t, draining.daemon, ipc.ActionHandshake)
	stuck := newHarness(t, testState(func(s *ipc.State) { s.Inventory = ipc.InventoryRefreshing }))
	expectExit(t, stuck.run("remove", firstUUID, "--yes"), 8)
	expectEqual(t, "elapsed", stuck.clock.elapsed(), 29500*time.Millisecond)
}

func TestRemoveRetainsSuccessfulWarningsAndUnrelatedTunnelObservation(t *testing.T) {
	for _, warning := range []ipc.Warning{ipc.WarningLocalCleanupIncomplete, ipc.WarningInventoryNotRefreshed} {
		connected := removeState()
		connected.Tunnel.Phase = ipc.TunnelConnected
		for _, isJSON := range []bool{false, true} {
			h := newHarness(t, connected)
			h.daemon.onRequest = acceptAndConfirm(h.daemon, ipc.ActionRemoveClient, ipc.OperationCompleted,
				&ipc.Outcome{Kind: ipc.OutcomeCompleted, Warning: warning}, func() *ipc.Reply { return &ipc.Reply{State: &connected} })
			if isJSON {
				expectExit(t, h.run("remove", firstUUID, "--yes", "--json"), 0)
				expectEqual(t, "warning", field(h.last(), "data", "operation", "warning"), any(string(warning)))
				expectEqual(t, "tunnel", field(h.last(), "data", "tunnel", "state"), any("connected"))
			} else {
				expectExit(t, h.run("remove", firstUUID, "--yes"), 0)
				expectContains(t, h.out.String(), "Client removed\n")
				expectContains(t, h.out.String(), label(string(warning)))
				expectContains(t, h.out.String(), "VPN:          connected\n")
			}
			expectEqual(t, "diagnostics", h.diag.String(), "")
		}
	}
}

func TestRemovePreservesTypedFailuresAndActiveClientGuidance(t *testing.T) {
	cases := []struct {
		failure ipc.CommandFailure
		exit    int
	}{
		{ipc.CommandClientActive, 4}, {ipc.CommandSignInRequired, 3}, {ipc.CommandAccessDenied, 3},
		{ipc.CommandNetworkUnavailable, 6}, {ipc.CommandConfigUnavailable, 5}, {ipc.CommandSelectionUnavailable, 5},
		{ipc.CommandCredentialsUnavailable, 4}, {ipc.CommandBusy, 7}, {ipc.CommandInternalError, 1},
	}
	for _, tc := range cases {
		for _, isJSON := range []bool{false, true} {
			h := removeHarness(t, &ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: tc.failure}, ipc.OperationFailed)
			arguments := []string{"remove", firstUUID, "--yes"}
			if isJSON {
				arguments = append(arguments, "--json")
			}
			expectExit(t, h.run(arguments...), tc.exit)
			id := h.daemon.requestsFor(ipc.ActionRemoveClient)[0].ID
			if isJSON {
				expectEqual(t, "code", field(h.last(), "error", "code"), any(string(tc.failure)))
				expectEqual(t, "operation", field(h.last(), "operationId"), any(id))
				expectEqual(t, "result", field(h.last(), "data", "operation", "result"), any("failed"))
				expectEqual(t, "choices", field(h.last(), "data", "choices"), nil)
			} else if tc.failure == ipc.CommandNetworkUnavailable {
				expectEqual(t, "diagnostics", h.diag.String(), "Waiting for network… Try again soon.\n")
				expectEqual(t, "output", h.out.String(), "Accepted operation "+id+"\n")
			}
			if tc.failure == ipc.CommandClientActive {
				expectContains(t, h.out.String()+h.diag.String(), "Disconnect that client and wait for it to stop before removing it")
			}
			expectMissing(t, h.out.String(), "Client removed")
			expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot, ipc.ActionRemoveClient, ipc.ActionConfirm)
		}
	}
}

func TestRemoveSessionChangesKeepOnlyReturnedRedactedCompletion(t *testing.T) {
	for _, isJSON := range []bool{false, true} {
		h := removeHarness(t, nil, ipc.OperationCompleted)
		arguments := []string{"remove", firstUUID, "--yes"}
		if isJSON {
			arguments = append(arguments, "--json")
		}
		expectExit(t, h.run(arguments...), 0)
		if isJSON {
			for _, key := range []string{"result", "configId", "warning", "error"} {
				expectEqual(t, key, field(h.last(), "data", "operation", key), nil)
			}
		} else {
			expectContains(t, h.out.String(), "Command completed\n")
			expectMissing(t, h.out.String(), "Client removed")
		}
		for _, private := range []string{removeConfig, "Desktop", "a@example.com"} {
			expectMissing(t, h.out.String(), private)
		}
	}
}

func TestRemoveUnknownOutcomesKeepRecoveryWithoutResend(t *testing.T) {
	for _, isJSON := range []bool{false, true} {
		arguments := []string{"remove", firstUUID, "--yes"}
		if isJSON {
			arguments = append(arguments, "--json")
		}
		for _, polled := range []bool{false, true} {
			h := newHarness(t, removeState())
			h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
				switch request.Action {
				case ipc.ActionRemoveClient:
					return &ipc.Reply{Operation: &ipc.Operation{ID: request.ID, State: ipc.OperationAccepted}}
				case ipc.ActionConfirm:
					if polled {
						return &ipc.Reply{Operation: &ipc.Operation{ID: request.ContextID, State: ipc.OperationRunning}}
					}
					return &ipc.Reply{Operation: &ipc.Operation{ID: request.ContextID, State: ipc.OperationUnknown}, Outcome: &ipc.Outcome{Kind: ipc.OutcomeUnknown}}
				case ipc.ActionOperation:
					return &ipc.Reply{Operation: &ipc.Operation{ID: request.ContextID, State: ipc.OperationUnknown}, Outcome: &ipc.Outcome{Kind: ipc.OutcomeUnknown}}
				}
				return nil
			}
			expectExit(t, h.run(arguments...), 10)
			expectRemovalRecovery(t, h, isJSON)
			if isJSON {
				expectEqual(t, "result", field(h.last(), "data", "operation", "result"), any("unknown"))
			}
		}
		for _, scenario := range []string{"lost confirm", "lost lookup", "redacted", "malformed"} {
			h := newHarness(t, removeState())
			h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
				switch request.Action {
				case ipc.ActionRemoveClient:
					return &ipc.Reply{Operation: &ipc.Operation{ID: request.ID, State: ipc.OperationAccepted}}
				case ipc.ActionConfirm:
					if scenario == "lost confirm" {
						return dropReply
					}
					return &ipc.Reply{Operation: &ipc.Operation{ID: request.ContextID, State: ipc.OperationRunning}}
				case ipc.ActionOperation:
					switch scenario {
					case "lost lookup":
						return dropReply
					case "malformed":
						return &ipc.Reply{Operation: &ipc.Operation{ID: thirdUUID, State: ipc.OperationCompleted}}
					}
					state := testState(signedOut)
					return &ipc.Reply{State: &state, Operation: &ipc.Operation{ID: request.ContextID, State: ipc.OperationUnknown}}
				}
				return nil
			}
			want := map[string]int{"lost confirm": 10, "lost lookup": 4, "redacted": 10, "malformed": 1}[scenario]
			expectExit(t, h.run(arguments...), want)
			expectRemovalRecovery(t, h, isJSON)
			expectMissing(t, h.out.String(), "Desktop")
		}
	}
}

func TestRemoveOutputFailureLeavesReservationUnconfirmed(t *testing.T) {
	for _, isJSON := range []bool{false, true} {
		h := removeHarness(t, &ipc.Outcome{Kind: ipc.OutcomeCompleted}, ipc.OperationCompleted)
		h.failsOutput = true
		arguments := []string{"remove", firstUUID, "--yes"}
		if isJSON {
			arguments = append(arguments, "--json")
		}
		expectExit(t, h.run(arguments...), 1)
		expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot, ipc.ActionRemoveClient)
		expectEqual(t, "output", h.out.String(), "")
	}
}

func TestRemoveReservationFailureKeepsRecoveryGuidance(t *testing.T) {
	h := newHarness(t, removeState())
	h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionRemoveClient {
			return hangReply
		}
		return nil
	}
	expectExit(t, h.run("remove", firstUUID, "--yes", "--timeout", "0.2", "--json"), 8)
	expectRemovalRecovery(t, h, true)
	expectEqual(t, "confirmed", len(h.daemon.requestsFor(ipc.ActionConfirm)), 0)
}
