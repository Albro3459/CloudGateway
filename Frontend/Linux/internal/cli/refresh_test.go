package cli

import (
	"slices"
	"testing"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

const refreshConfig = "uid1/us-east-1/mac"

func refreshReplies(results ...ipc.RefreshResult) func(state ipc.State) func(ipc.Request) *ipc.Reply {
	return func(state ipc.State) func(ipc.Request) *ipc.Reply {
		return func(request ipc.Request) *ipc.Reply {
			if request.Action != ipc.ActionAwaitRefresh {
				return nil
			}
			result := results[0]
			if len(results) > 1 {
				results = results[1:]
			}
			return &ipc.Reply{State: &state, Refresh: result}
		}
	}
}

func TestExplicitRefreshWaitsForItsCorrelatedResultAndNeverReconnects(t *testing.T) {
	h := newHarness(t)
	h.daemon.onRequest = refreshReplies(ipc.RefreshTimedOut, ipc.RefreshRefreshed)(testState(withClients(testClient(refreshConfig, "East", 0, "Mac"))))
	expectExit(t, h.run("refresh", "--json"), 0)
	expectEqual(t, "result", field(h.last(), "data", "result"), any("refreshed"))
	expectEqual(t, "freshness", field(h.last(), "data", "inventory", "freshness"), any("current"))
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionAwaitRefresh, ipc.ActionAwaitRefresh)
	h.reset()
	h.daemon.onRequest = refreshReplies(ipc.RefreshRefreshed)(testState(withClients(testClient(refreshConfig, "East", 0, "Mac"))))
	expectExit(t, h.run("refresh"), 0)
	expectEqual(t, "human", h.out.String(), "Inventory refresh: refreshed\n\nEast (us-east-1)\n  1  Mac  mac\n\n"+
		"Tunnel observation: current at 2027-01-15T08:00:00Z\nInventory: current\n")
}

func TestListRefreshFiltersOnlyTheCompletedFreshInventory(t *testing.T) {
	h := newHarness(t)
	h.daemon.onRequest = refreshReplies(ipc.RefreshRefreshed)(testState(withClients(testClient(refreshConfig, "East", 0, "Mac"),
		testClient("uid1/us-west-2/laptop", "West", 0, "Laptop"))))
	expectExit(t, h.run("list", "--refresh", "--region", "us-west-2", "--json"), 0)
	regions := field(h.last(), "data", "regions").([]any)
	expectEqual(t, "regions", len(regions), 1)
	expectEqual(t, "region", field(regions[0], "regionId"), any("us-west-2"))
	expectEqual(t, "freshness", field(h.last(), "data", "freshness"), any("current"))
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionAwaitRefresh)
}

func TestRefreshFailureNeverLabelsRetainedInventoryAsCurrent(t *testing.T) {
	for _, command := range [][]string{{"refresh"}, {"list", "--refresh"}} {
		h := newHarness(t)
		h.daemon.onRequest = refreshReplies(ipc.RefreshUnavailable)(testState(withClients(testClient(refreshConfig, "East", 0, "Mac"))))
		expectExit(t, h.run(append(command, "--json")...), 6)
		inventory := field(h.last(), "data")
		if command[0] == "refresh" {
			inventory = field(inventory, "inventory")
		}
		expectEqual(t, "freshness", field(inventory, "freshness"), any("stale"))
		expectEqual(t, "code", field(h.last(), "error", "code"), any("network_unavailable"))
		h.reset()
		expectExit(t, h.run(command...), 6)
		expectContains(t, h.out.String(), "Inventory: stale\n")
		expectContains(t, h.out.String(), "Mac")
		expectEqual(t, "diagnostics", h.diag.String(), "Waiting for network… Try again soon.\n")
	}
}

func TestRefreshReportsDeniedSignedOutSkippedAndSupersededExplicitly(t *testing.T) {
	cases := []struct {
		result ipc.RefreshResult
		exit   int
		code   string
	}{
		{ipc.RefreshDenied, 3, "access_denied"}, {ipc.RefreshSignInRequired, 3, "sign_in_required"},
		{ipc.RefreshSkipped, 6, "refresh_skipped"}, {ipc.RefreshSuperseded, 7, "refresh_superseded"},
	}
	for _, tc := range cases {
		h := newHarness(t)
		h.daemon.onRequest = refreshReplies(tc.result)(testState(signedOut))
		expectExit(t, h.run("refresh", "--json"), tc.exit)
		expectEqual(t, "code", field(h.last(), "error", "code"), any(tc.code))
		expectEqual(t, "inventory", field(h.last(), "data", "inventory"), nil)
		expectEqual(t, "result", field(h.last(), "data", "result"), any(string(tc.result)))
	}
}

func TestRepeatedRefreshTimeoutsStopAtTheCallerDeadline(t *testing.T) {
	h := newHarness(t)
	h.daemon.onRequest = refreshReplies(ipc.RefreshTimedOut)(testState())
	expectExit(t, h.run("refresh", "--timeout", "1", "--json"), 8)
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionAwaitRefresh, ipc.ActionAwaitRefresh)
	expectEqual(t, "result", field(h.last(), "data", "result"), any("timed_out"))
}

func TestListWaitsForTheSharedStaleRefreshAfterActivity(t *testing.T) {
	h := newHarness(t, testState())
	h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionUserActivity {
			h.daemon.states = []ipc.State{testState(func(s *ipc.State) { s.Inventory = ipc.InventoryRefreshing }),
				testState(withClients(testClient(refreshConfig, "East", 0, "Fresh Mac")))}
			return &ipc.Reply{}
		}
		return nil
	}
	expectExit(t, h.run("list", "--json"), 0)
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot, ipc.ActionSnapshot)
	expectContains(t, h.out.String(), "Fresh Mac")
}

func TestFilteredRefreshResolvesRegionsOnlyFromUsableInventory(t *testing.T) {
	for _, alias := range []string{"list", "ls"} {
		h := newHarness(t)
		h.daemon.onRequest = refreshReplies(ipc.RefreshTimedOut)(testState(func(s *ipc.State) { s.Inventory = ipc.InventoryRefreshing }))
		expectExit(t, h.run(alias, "--refresh", "--region", "chicago", "--timeout", "1", "--json"), 8)
		expectEqual(t, "result", field(h.last(), "data", "result"), any("timed_out"))
		expectEqual(t, "inventory", field(h.last(), "data", "inventory"), nil)
		expectMissing(t, h.out.String(), "unavailable in this account's current inventory")
	}
	failures := []struct {
		result ipc.RefreshResult
		exit   int
	}{
		{ipc.RefreshUnavailable, 6}, {ipc.RefreshDenied, 3}, {ipc.RefreshSignInRequired, 3}, {ipc.RefreshSkipped, 6}, {ipc.RefreshSuperseded, 7},
	}
	for _, freshness := range []ipc.InventoryFreshness{ipc.InventoryUnavailable, ipc.InventoryRefreshing} {
		for _, tc := range failures {
			h := newHarness(t)
			h.daemon.onRequest = refreshReplies(tc.result)(testState(func(s *ipc.State) { s.Inventory = freshness }))
			expectExit(t, h.run("ls", "--refresh", "--long", "--region", "chicago", "--json"), tc.exit)
			expectEqual(t, "inventory", field(h.last(), "data", "inventory"), nil)
		}
	}
	for _, result := range []ipc.RefreshResult{ipc.RefreshRefreshed, ipc.RefreshUnavailable, ipc.RefreshSkipped, ipc.RefreshSuperseded, ipc.RefreshTimedOut} {
		for _, freshness := range []ipc.InventoryFreshness{ipc.InventoryCurrent, ipc.InventoryCached} {
			h := newHarness(t)
			h.daemon.onRequest = refreshReplies(result)(testState(func(s *ipc.State) { s.Inventory = freshness },
				withClients(testClient(refreshConfig, "East", 0, "Mac"))))
			expectExit(t, h.run("ls", "--refresh", "--region", "chicago", "--timeout", "1", "--json"), 2)
			expectEqual(t, "code", field(h.last(), "error", "code"), any("usage"))
			expectContains(t, h.out.String(), "unavailable in this account's current inventory")
		}
	}
	for _, tc := range []struct {
		result ipc.RefreshResult
		code   string
	}{{ipc.RefreshDenied, "access_denied"}, {ipc.RefreshSignInRequired, "sign_in_required"}} {
		h := newHarness(t)
		h.daemon.onRequest = refreshReplies(tc.result)(testState(withClients(testClient(refreshConfig, "East", 0, "Mac"))))
		expectExit(t, h.run("ls", "--refresh", "--region", "chicago", "--json"), 3)
		expectEqual(t, "code", field(h.last(), "error", "code"), any(tc.code))
	}
	settled := newHarness(t)
	settled.daemon.onRequest = refreshReplies(ipc.RefreshTimedOut, ipc.RefreshRefreshed)(selectorState())
	expectExit(t, settled.run("ls", "--refresh", "--region", "sanjose", "-l", "--json"), 0)
	expectEqual(t, "command", field(settled.last(), "command"), any("list"))
	expectEqual(t, "region", field(settled.last(), "data", "regionId"), any("us-sanjose-1"))
	if slices.Contains(settled.daemon.actions(), ipc.ActionConnect) {
		t.Fatal("refresh reconnected")
	}
}

var addRegion = ipc.CreationRegion{RegionID: "us-sanjose-1", DisplayName: "California", Enabled: true,
	Capacity: &ipc.Capacity{Known: true, Limit: 10, Allocated: 1}}

func addHarness(t *testing.T, regions []ipc.CreationRegion, outcome ipc.Outcome) *harness {
	h := newHarness(t, testState(func(s *ipc.State) { s.CreationAllowed = true }))
	contextID := "6f9619ff-8b86-d011-b42d-00c04fc964ff"
	h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		switch request.Action {
		case ipc.ActionPrepareClient:
			return &ipc.Reply{Creation: &ipc.Creation{ID: contextID, Regions: regions}}
		case ipc.ActionCreateClient:
			if request.ContextID != contextID || request.ClientName != "Mac mini" || request.RegionID != addRegion.RegionID || request.Identifier != "" {
				t.Errorf("create request %+v", request)
			}
			return &ipc.Reply{Operation: &ipc.Operation{ID: request.ID, State: ipc.OperationAccepted}}
		case ipc.ActionConfirm:
			state := map[ipc.OutcomeKind]ipc.OperationState{ipc.OutcomeFailed: ipc.OperationFailed, ipc.OutcomeUnknown: ipc.OperationUnknown}[outcome.Kind]
			return &ipc.Reply{Operation: &ipc.Operation{ID: request.ContextID, State: cmpState(state)}, Outcome: &outcome}
		}
		return nil
	}
	return h
}

func cmpState(state ipc.OperationState) ipc.OperationState {
	if state == "" {
		return ipc.OperationCompleted
	}
	return state
}

func TestAddAcceptsCreationRegionIDDisplayNameAndCity(t *testing.T) {
	for _, region := range []string{"us-sanjose-1", "sanjose", "California", "CALIFORNIA"} {
		h := addHarness(t, []ipc.CreationRegion{addRegion}, ipc.Outcome{Kind: ipc.OutcomeCompleted})
		expectExit(t, h.run("add", region, "  Mac mini  ", "--json"), 0)
		records := h.records()
		expectEqual(t, "records", len(records), 2)
		expectEqual(t, "accepted", field(records[0], "command"), any("add"))
		expectEqual(t, "same id", field(records[0], "operationId"), field(records[1], "operationId"))
		expectEqual(t, "creation region", field(records[1], "data", "creation", "regionId"), any("us-sanjose-1"))
		expectEqual(t, "creation name", field(records[1], "data", "creation", "name"), any("Mac mini"))
		expectEqual(t, "result", field(records[1], "data", "operation", "result"), any("completed"))
		expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot, ipc.ActionPrepareClient,
			ipc.ActionCreateClient, ipc.ActionConfirm)
	}
	h := addHarness(t, []ipc.CreationRegion{addRegion}, ipc.Outcome{Kind: ipc.OutcomeCompleted, Warning: ipc.WarningInventoryNotRefreshed})
	h.daemon.states[0].Tunnel.Phase = ipc.TunnelConnected
	expectExit(t, h.run("add", "sanjose", "Mac mini"), 0)
	expectContains(t, h.out.String(), "Client created: Mac mini (us-sanjose-1)\n")
	expectContains(t, h.out.String(), "(inventory not refreshed)")
}

func TestAddRejectsUnknownAmbiguousDisabledAndFullRegionsWithoutReserving(t *testing.T) {
	second := ipc.CreationRegion{RegionID: "us-sanjose-2", DisplayName: "California", Enabled: true, Capacity: addRegion.Capacity}
	disabled := ipc.CreationRegion{RegionID: "us-disabled-1", DisplayName: "Disabled", Capacity: addRegion.Capacity}
	for _, region := range []string{"missing", "sanjose", "California", disabled.RegionID} {
		h := addHarness(t, []ipc.CreationRegion{addRegion, second, disabled}, ipc.Outcome{Kind: ipc.OutcomeCompleted})
		expectExit(t, h.run("add", region, "Mac mini", "--json"), 2)
		expectEqual(t, "created", len(h.daemon.requestsFor(ipc.ActionCreateClient)), 0)
		expectContains(t, h.out.String(), "us-sanjose-1")
		expectMissing(t, h.out.String(), "us-disabled-1 (Disabled)")
	}
	exact := addHarness(t, []ipc.CreationRegion{addRegion, second}, ipc.Outcome{Kind: ipc.OutcomeCompleted})
	expectExit(t, exact.run("add", "us-sanjose-1", "Mac mini"), 0)
	for _, tc := range []struct {
		capacity *ipc.Capacity
		exit     int
		message  string
	}{
		{&ipc.Capacity{}, 6, "Unable to check capacity for us-sanjose-1. Try again"},
		{nil, 6, "Unable to check capacity for us-sanjose-1. Try again"},
		{&ipc.Capacity{Known: true, Limit: 1, Allocated: 1}, 5, "Region us-sanjose-1 has no available client capacity"},
	} {
		region := addRegion
		region.Capacity = tc.capacity
		h := addHarness(t, []ipc.CreationRegion{region}, ipc.Outcome{Kind: ipc.OutcomeCompleted})
		expectExit(t, h.run("add", "sanjose", "Mac mini", "--json"), tc.exit)
		expectEqual(t, "message", field(h.last(), "error", "message"), any(tc.message))
		expectEqual(t, "created", len(h.daemon.requestsFor(ipc.ActionCreateClient)), 0)
	}
}

func TestAddChecksAccountAndDaemonBeforePreparing(t *testing.T) {
	for _, tc := range []struct {
		edit func(*ipc.State)
		exit int
	}{
		{signedOut, 3},
		{func(s *ipc.State) { signedOut(s); s.HasRetainedSession, s.Access = true, ipc.AccessDenied }, 3},
		{func(s *ipc.State) { signedOut(s); s.HasRetainedSession, s.Access = true, ipc.AccessUnreachable }, 6},
		{func(*ipc.State) {}, 7},
	} {
		h := newHarness(t, testState(tc.edit))
		expectExit(t, h.run("add", "sanjose", "Mac mini", "--json"), tc.exit)
		expectEqual(t, "prepared", len(h.daemon.requestsFor(ipc.ActionPrepareClient)), 0)
	}
	waits := addHarness(t, []ipc.CreationRegion{addRegion}, ipc.Outcome{Kind: ipc.OutcomeCompleted})
	waits.daemon.states = []ipc.State{testState(signedOut, func(s *ipc.State) { s.IsRestoring, s.HasRetainedSession = true, true }),
		testState(func(s *ipc.State) { s.Inventory = ipc.InventoryRefreshing }), testState(func(s *ipc.State) { s.CreationAllowed = true })}
	expectExit(t, waits.run("add", "sanjose", "Mac mini"), 0)
	expectEqual(t, "snapshots", len(waits.daemon.requestsFor(ipc.ActionSnapshot)), 3)
	stale := newHarness(t, testState())
	stale.daemon.lifecycle = ipc.LifecycleDraining
	expectExit(t, stale.run("add", "sanjose", "Mac mini", "--json"), 4)
	expectEqual(t, "prepared", len(stale.daemon.requestsFor(ipc.ActionPrepareClient)), 0)
}

func TestAddPreservesAuthFailuresObservedDuringPreparation(t *testing.T) {
	cases := []struct {
		state ipc.State
		code  string
		exit  int
	}{
		{testState(signedOut, func(s *ipc.State) { s.Access = ipc.AccessDenied }), "access_denied", 3},
		{testState(signedOut), "sign_in_required", 3},
		{testState(signedOut, func(s *ipc.State) { s.HasRetainedSession, s.Access = true, ipc.AccessUnreachable }), "network_unavailable", 6},
		{testState(func(s *ipc.State) { s.CreationAllowed = true }), "network_unavailable", 6},
	}
	for _, tc := range cases {
		h := addHarness(t, []ipc.CreationRegion{addRegion}, ipc.Outcome{Kind: ipc.OutcomeCompleted})
		h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
			if request.Action == ipc.ActionPrepareClient {
				h.daemon.states = []ipc.State{tc.state}
				return &ipc.Reply{Error: ipc.FailureUnavailable}
			}
			return nil
		}
		expectExit(t, h.run("add", "sanjose", "Mac mini", "--json"), tc.exit)
		expectEqual(t, "code", field(h.last(), "error", "code"), any(tc.code))
		expectEqual(t, "snapshots", len(h.daemon.requestsFor(ipc.ActionSnapshot)), 2)
		expectEqual(t, "created", len(h.daemon.requestsFor(ipc.ActionCreateClient)), 0)
	}
	lost := addHarness(t, []ipc.CreationRegion{addRegion}, ipc.Outcome{Kind: ipc.OutcomeCompleted})
	lost.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionPrepareClient {
			return dropReply
		}
		return nil
	}
	expectExit(t, lost.run("add", "sanjose", "Mac mini", "--json"), 6)
	expectEqual(t, "message", field(lost.last(), "error", "message"), any("Unable to load regions for client creation. Try again"))
	hung := addHarness(t, []ipc.CreationRegion{addRegion}, ipc.Outcome{Kind: ipc.OutcomeCompleted})
	hung.daemon.hung[ipc.ActionPrepareClient] = true
	hung.daemon.onRequest = nil
	expectExit(t, hung.run("add", "sanjose", "Mac mini", "--timeout", "0.2", "--json"), 8)
}

func TestAddNeverConfirmsAfterFailedAcceptanceOrRetriesUnknownOutcomes(t *testing.T) {
	h := addHarness(t, []ipc.CreationRegion{addRegion}, ipc.Outcome{Kind: ipc.OutcomeCompleted})
	h.failsOutput = true
	expectExit(t, h.run("add", "sanjose", "Mac mini", "--json"), 1)
	expectEqual(t, "created", len(h.daemon.requestsFor(ipc.ActionCreateClient)), 1)
	expectEqual(t, "confirmed", len(h.daemon.requestsFor(ipc.ActionConfirm)), 0)
	for _, tc := range []struct {
		outcome ipc.Outcome
		exit    int
	}{{ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandSignInRequired}, 3}, {ipc.Outcome{Kind: ipc.OutcomeUnknown}, 10}} {
		h := addHarness(t, []ipc.CreationRegion{addRegion}, tc.outcome)
		expectExit(t, h.run("add", "sanjose", "Mac mini", "--json"), tc.exit)
		expectEqual(t, "created", len(h.daemon.requestsFor(ipc.ActionCreateClient)), 1)
	}
	lost := addHarness(t, []ipc.CreationRegion{addRegion}, ipc.Outcome{Kind: ipc.OutcomeCompleted})
	prepare := lost.daemon.onRequest
	lost.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionConfirm {
			return dropReply
		}
		return prepare(request)
	}
	expectExit(t, lost.run("add", "sanjose", "Mac mini", "--json"), 10)
	expectEqual(t, "created", len(lost.daemon.requestsFor(ipc.ActionCreateClient)), 1)
	expectContains(t, lost.out.String(), "Check this operation before retrying")
}
