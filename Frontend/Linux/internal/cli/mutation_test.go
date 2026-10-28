package cli

import (
	"slices"
	"strings"
	"testing"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

const (
	firstUUID    = "78ab8633-ae25-4287-885f-57bbbf6e7f63"
	secondUUID   = "4830b738-2823-4888-bf37-2918ae356ad5"
	thirdUUID    = "d1482e58-5202-4771-82ae-bb34a313c537"
	firstConfig  = "uid1/us-sanjose-1/" + firstUUID
	secondConfig = "uid1/us-sanjose-1/" + secondUUID
	thirdConfig  = "uid1/us-chicago-1/" + thirdUUID
	mutationConf = "uid1/us-east-1/" + firstUUID
)

func mutationState(edits ...func(*ipc.State)) ipc.State {
	return testState(append([]func(*ipc.State){withClients(testClient(mutationConf, "East", 0, "Mac")), withSelected(mutationConf)}, edits...)...)
}

func selectorState() ipc.State {
	return testState(withClients(
		testClient(thirdConfig, "Chicago", 2, "Mac", func(c *ipc.Client) { c.OwnerLabel = ptr("owner@example.com") }),
		testClient(secondConfig, "California", 1, "Laptop", func(c *ipc.Client) {
			c.OwnerLabel, c.InternalIP, c.ConnectionURL = ptr("b@example.com"), ptr("10.0.0.3"), ptr("192.0.2.10")
		}),
		testClient(firstConfig, "California", 1, "Desktop", func(c *ipc.Client) {
			c.OwnerLabel, c.ConnectionURL, c.Eligibility = ptr("a@example.com"), ptr("wg.us-sanjose-1.example.com"), "inactive"
		}),
	), withSelected(secondConfig))
}

func TestStartFlushesAcceptanceBeforeConfirmAndReportsSubmissionSeparately(t *testing.T) {
	h := newHarness(t, mutationState())
	h.daemon.onRequest = acceptAndConfirm(h.daemon, ipc.ActionConnect, ipc.OperationCompleted,
		&ipc.Outcome{Kind: ipc.OutcomeStartRequested, Identifier: mutationConf}, func() *ipc.Reply {
			if !strings.Contains(h.out.String(), `"type":"accepted"`) {
				t.Error("confirmed before the accepted record printed")
			}
			return &ipc.Reply{}
		})
	expectExit(t, h.run("up", firstUUID, "--json"), 0)
	records := h.records()
	expectEqual(t, "records", len(records), 2)
	id := h.daemon.requestsFor(ipc.ActionConnect)[0].ID
	expectEqual(t, "accepted", h.out.String()[:strings.Index(h.out.String(), "\n")+1],
		`{"command":"up","data":null,"error":null,"operationId":"`+id+`","schemaVersion":1,"type":"accepted"}`+"\n")
	expectEqual(t, "result id", field(records[1], "operationId"), any(id))
	expectEqual(t, "result", field(records[1], "data", "operation", "result"), any("start_requested"))
	expectEqual(t, "config", field(records[1], "data", "operation", "configId"), any(mutationConf))
	expectEqual(t, "tunnel", field(records[1], "data", "tunnel", "state"), any("disconnected"))
	expectEqual(t, "identifier", h.daemon.requestsFor(ipc.ActionConnect)[0].Identifier, mutationConf)
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot, ipc.ActionConnect, ipc.ActionConfirm)
}

func TestFailedAcceptanceOutputNeverConfirmsOrRunsReservedWork(t *testing.T) {
	h := newHarness(t, mutationState())
	h.daemon.onRequest = acceptAndConfirm(h.daemon, ipc.ActionTurnOff, ipc.OperationCompleted, &ipc.Outcome{Kind: ipc.OutcomeCompleted}, nil)
	h.failsOutput = true
	expectExit(t, h.run("down", "--json"), 1)
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionTurnOff)
}

func TestUncertainConfirmationPreservesOperationIDAndNeverRetriesDown(t *testing.T) {
	h := newHarness(t)
	h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		switch request.Action {
		case ipc.ActionTurnOff:
			return &ipc.Reply{Operation: &ipc.Operation{ID: request.ID, State: ipc.OperationAccepted}}
		case ipc.ActionConfirm:
			return dropReply
		}
		return nil
	}
	expectExit(t, h.run("down", "--json"), 10)
	id := h.daemon.requestsFor(ipc.ActionTurnOff)[0].ID
	expectEqual(t, "operation", field(h.last(), "operationId"), any(id))
	expectEqual(t, "suggestion", field(h.last(), "error", "suggestion"), any("Check this operation before retrying: cloudgateway status --operation "+id))
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionTurnOff, ipc.ActionConfirm)
}

func TestDownOnAnotherIPCVersionReportsTheMismatch(t *testing.T) {
	h := newHarness(t)
	h.daemon.version = ipc.Version + 1
	expectExit(t, h.run("down", "--json"), 4)
	expectEqual(t, "code", field(h.last(), "error", "code"), any("incompatible_version"))
	expectEqual(t, "suggestion", field(h.last(), "error", "suggestion"),
		any("Wait for the daemon restart to finish, or run: sudo systemctl restart cloudgatewayd"))
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionTurnOff)
}

func TestDownWorksSignedOutAndOnADrainingDaemon(t *testing.T) {
	h := newHarness(t, testState(signedOut))
	h.daemon.lifecycle = ipc.LifecycleDraining
	h.daemon.onRequest = acceptAndConfirm(h.daemon, ipc.ActionTurnOff, ipc.OperationCompleted, &ipc.Outcome{Kind: ipc.OutcomeCompleted}, nil)
	expectExit(t, h.run("down"), 0)
	id := h.daemon.requestsFor(ipc.ActionTurnOff)[0].ID
	expectEqual(t, "output", h.out.String(), "Accepted operation "+id+"\nVPN stopped\nVPN:          disconnected\n"+
		"Observation:  current\nOperation:    "+id+" completed, completed\n")
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionTurnOff, ipc.ActionConfirm)
}

func TestLogoutReportsCleanupFailureAndNeverChangesVPN(t *testing.T) {
	success := newHarness(t, mutationState())
	success.daemon.onRequest = acceptAndConfirm(success.daemon, ipc.ActionSignOut, ipc.OperationCompleted, &ipc.Outcome{Kind: ipc.OutcomeCompleted}, nil)
	expectExit(t, success.run("auth", "logout"), 0)
	expectContains(t, success.out.String(), "Signed out (VPN retained)\n")
	expectActions(t, success.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSignOut, ipc.ActionConfirm)

	failed := newHarness(t)
	failed.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		switch request.Action {
		case ipc.ActionSignOut:
			return &ipc.Reply{Operation: &ipc.Operation{ID: request.ID, State: ipc.OperationAccepted}}
		case ipc.ActionConfirm:
			return &ipc.Reply{Operation: &ipc.Operation{ID: request.ContextID, State: ipc.OperationFailed, Failure: ipc.FailureAuthCleanupFailed}}
		}
		return nil
	}
	expectExit(t, failed.run("auth", "logout"), 4)
	expectContains(t, failed.diag.String(), "Error: Sign-out cleanup did not finish\nRun: cloudgateway doctor\n")
	if slices.Contains(failed.daemon.actions(), ipc.ActionTurnOff) {
		t.Fatal("logout stopped the VPN")
	}
}

func TestStartPreservesTypedPolicyFailures(t *testing.T) {
	cases := []struct {
		outcome ipc.Outcome
		exit    int
	}{
		{ipc.Outcome{Kind: ipc.OutcomeStartRequested, Identifier: mutationConf}, 0},
		{ipc.Outcome{Kind: ipc.OutcomeAlreadyActive, Identifier: mutationConf}, 0},
		{ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandConfigUnavailable}, 5},
		{ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandCredentialsUnavailable}, 4},
		{ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandNetworkUnavailable}, 6},
		{ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandStopTimedOut}, 8},
	}
	for _, tc := range cases {
		state := ipc.OperationCompleted
		if tc.outcome.Kind == ipc.OutcomeFailed {
			state = ipc.OperationFailed
		}
		h := newHarness(t, mutationState())
		h.daemon.onRequest = acceptAndConfirm(h.daemon, ipc.ActionConnect, state, &tc.outcome, nil)
		expectExit(t, h.run("up", firstUUID), tc.exit)
		if tc.outcome.Failure == ipc.CommandNetworkUnavailable {
			id := h.daemon.requestsFor(ipc.ActionConnect)[0].ID
			expectEqual(t, "output", h.out.String(), "Accepted operation "+id+"\n")
			expectEqual(t, "diagnostics", h.diag.String(), "Waiting for network… Try again soon.\n")
		}
	}
	already := newHarness(t, testState(signedOut), mutationState())
	already.daemon.states[0].HasRetainedSession = true
	already.daemon.onRequest = acceptAndConfirm(already.daemon, ipc.ActionConnect, ipc.OperationCompleted,
		&ipc.Outcome{Kind: ipc.OutcomeAlreadyActive, Identifier: mutationConf}, nil)
	expectExit(t, already.run("up"), 0)
	expectContains(t, already.out.String(), "VPN already active\n")
	expectActions(t, already.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot, ipc.ActionSnapshot,
		ipc.ActionConnect, ipc.ActionConfirm)
}

func TestCompoundIdentifiersAreRejectedBeforeDialing(t *testing.T) {
	h := newHarness(t, mutationState())
	expectExit(t, h.run("up", "other/us-east-1/mac"), 2)
	expectEqual(t, "dials", h.daemon.acceptCount(), 0)
}

func TestMissingSelectionShowsOnlyCurrentAuthorizedEligibleChoices(t *testing.T) {
	eligible := testClient(mutationConf, "East", 0, "Mac")
	inactive := testClient("uid1/us-east-1/old", "East", 0, "Old", func(c *ipc.Client) { c.Eligibility = "inactive" })
	h := newHarness(t, testState(withClients(eligible, inactive)))
	h.daemon.onRequest = acceptAndConfirm(h.daemon, ipc.ActionConnect, ipc.OperationFailed,
		&ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandSelectionUnavailable}, nil)
	expectExit(t, h.run("up", "--json"), 5)
	configs := field(field(h.last(), "data", "choices", "regions").([]any)[0], "configs").([]any)
	expectEqual(t, "choices", len(configs), 1)
	expectEqual(t, "config", field(configs[0], "configId"), any(mutationConf))
	expectEqual(t, "snapshots", len(h.daemon.requestsFor(ipc.ActionSnapshot)), 2)
	h.reset()
	h.daemon.onRequest = acceptAndConfirm(h.daemon, ipc.ActionConnect, ipc.OperationFailed,
		&ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandSelectionUnavailable}, nil)
	expectExit(t, h.run("up"), 5)
	expectContains(t, h.out.String(), "\nAvailable configs:\nEast (us-east-1)\n  1  Mac  "+firstUUID+"\n")
	expectContains(t, h.diag.String(), "Error: No usable config is selected\nRun cloudgateway ls, then cloudgateway up <client-uuid>\n")
}

func TestCallerDeadlineCoversEveryMutationPhase(t *testing.T) {
	for _, action := range []ipc.Action{ipc.ActionTurnOff, ipc.ActionConfirm, ipc.ActionOperation} {
		h := newHarness(t)
		h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
			switch {
			case request.Action == action:
				return hangReply
			case request.Action == ipc.ActionTurnOff:
				return &ipc.Reply{Operation: &ipc.Operation{ID: request.ID, State: ipc.OperationAccepted}}
			case request.Action == ipc.ActionConfirm:
				return &ipc.Reply{Operation: &ipc.Operation{ID: request.ContextID, State: ipc.OperationRunning}}
			}
			return nil
		}
		expectExit(t, h.run("down", "--timeout", "0.2"), 8)
		expectEqual(t, "reservations", len(h.daemon.requestsFor(ipc.ActionTurnOff)), 1)
		if action != ipc.ActionTurnOff {
			expectContains(t, h.diag.String(), "cloudgateway status --operation")
		}
	}
}

func TestSuccessfulStopAndLogoutExposeUpdateSuppressionWarning(t *testing.T) {
	updateID := "6f9619ff-8b86-d011-b42d-00c04fc964ff"
	for _, arguments := range [][]string{{"down"}, {"auth", "logout"}} {
		for _, isJSON := range []bool{false, true} {
			h := newHarness(t, mutationState())
			action := ipc.ActionTurnOff
			if arguments[0] == "auth" {
				action = ipc.ActionSignOut
			}
			h.daemon.onRequest = acceptAndConfirm(h.daemon, action, ipc.OperationCompleted, &ipc.Outcome{Kind: ipc.OutcomeCompleted}, func() *ipc.Reply {
				return &ipc.Reply{Update: &ipc.UpdateStatus{ID: updateID, Phase: ipc.UpdateActivating, Target: testBuild,
					Identifier: mutationConf, Warning: "storage_unavailable"}}
			})
			if isJSON {
				expectExit(t, h.run(append(arguments, "--json")...), 0)
				record := h.last()
				expectEqual(t, "type", field(record, "type"), any("result"))
				expectEqual(t, "update id", field(record, "data", "update", "id"), any(updateID))
				expectEqual(t, "warning code", field(record, "data", "update", "warning", "code"), any("storage_unavailable"))
				expectEqual(t, "warning", field(record, "data", "update", "warning", "message"),
					any("CloudGateway could not persist the update safely. Reconnect suppression cannot be guaranteed after daemon restart"))
			} else {
				expectExit(t, h.run(arguments...), 0)
				expectContains(t, h.out.String(), "Update warning:  CloudGateway could not persist the update safely. Reconnect suppression")
				expectContains(t, h.out.String(), "Update:          "+updateID+" restarting the daemon onto the installed release\n")
			}
			expectEqual(t, "diagnostics", h.diag.String(), "")
		}
	}
}

func TestListsUseUUIDsAndIdenticalOrderingAcrossLayoutsAndJSON(t *testing.T) {
	short := newHarness(t, selectorState())
	expectExit(t, short.run("ls"), 0)
	expectEqual(t, "short", short.out.String(), `California (us-sanjose-1)
  1  Desktop (a@example.com)  `+firstUUID+`  inactive
  2  Laptop (b@example.com)   `+secondUUID+`  selected

Chicago (us-chicago-1)
  1  Mac (owner@example.com)  `+thirdUUID+`

Tunnel observation: current at 2027-01-15T08:00:00Z
Inventory: current
`)
	long := newHarness(t, selectorState())
	expectExit(t, long.run("list", "--long"), 0)
	expectEqual(t, "long", long.out.String(), `California (us-sanjose-1)
  1  Desktop  inactive
     VPN id:          `+firstUUID+`
     Tunnel IP:       10.0.0.2
     Connection URL:  wg.us-sanjose-1.example.com
     Owner email:     a@example.com
  2  Laptop  selected
     VPN id:          `+secondUUID+`
     Tunnel IP:       10.0.0.3
     Connection URL:  192.0.2.10
     Owner email:     b@example.com

Chicago (us-chicago-1)
  1  Mac
     VPN id:          `+thirdUUID+`
     Tunnel IP:       10.0.0.2
     Connection URL:  Unavailable
     Owner email:     owner@example.com

Tunnel observation: current at 2027-01-15T08:00:00Z
Inventory: current
`)
	var outputs []string
	for _, arguments := range [][]string{{"list", "--json"}, {"ls", "-l", "--json"}, {"list", "--long", "--json"}} {
		h := newHarness(t, selectorState())
		expectExit(t, h.run(arguments...), 0)
		outputs = append(outputs, h.out.String())
		var ids, configs []string
		var indices []float64
		for _, r := range field(h.last(), "data", "regions").([]any) {
			for _, c := range field(r, "configs").([]any) {
				ids = append(ids, field(c, "clientId").(string))
				configs = append(configs, field(c, "configId").(string))
				indices = append(indices, field(c, "index").(float64))
			}
		}
		expectEqual(t, "ids", strings.Join(ids, ","), firstUUID+","+secondUUID+","+thirdUUID)
		expectEqual(t, "configs", strings.Join(configs, ","), firstConfig+","+secondConfig+","+thirdConfig)
		if !slices.Equal(indices, []float64{1, 2, 1}) {
			t.Fatalf("indices %v", indices)
		}
	}
	if outputs[0] != outputs[1] || outputs[1] != outputs[2] {
		t.Fatal("--long changed JSON")
	}
	choices := newInventory(selectorState(), "uid1", "", false, true, false)
	expectEqual(t, "choice index", choices.regions[0].configs[0].index, 2)
	expectEqual(t, "choice index", choices.regions[1].configs[0].index, 1)
	for sel, want := range map[selector]string{
		{clientID: secondUUID}: secondConfig, {region: "sanjose", index: 2}: secondConfig, {region: "CHICAGO", index: 1}: thirdConfig,
		{region: "California", index: 1}: firstConfig,
	} {
		got, err := resolveSelector(sel, selectorState(), "uid1")
		if err != nil || got != want {
			t.Errorf("%+v: %s %v", sel, got, err)
		}
	}
}

func TestRegionFiltersRejectMissingAndAmbiguousInventory(t *testing.T) {
	for _, value := range []string{"us-sanjose-1", "California", "cALIFORNIA", "sanjose", " California "} {
		h := newHarness(t, selectorState())
		expectExit(t, h.run("ls", "--region", value, "--json"), 0)
		expectEqual(t, "region", field(h.last(), "data", "regionId"), any("us-sanjose-1"))
	}
	collision := testState(withClients(testClient(firstConfig, "Shared Name", 0, "A"),
		testClient("uid1/eu-sanjose-2/"+secondUUID, "Shared Name", 0, "B")))
	for _, alias := range []string{"sanjose", "Shared Name"} {
		h := newHarness(t, collision)
		expectExit(t, h.run("list", "--region", alias, "--json"), 2)
		expectEqual(t, "message", field(h.last(), "error", "message"), any("Region '"+alias+"' is ambiguous. Use a full region ID"))
		expectEqual(t, "suggestion", field(h.last(), "error", "suggestion"),
			any("Available regions: eu-sanjose-2 (Shared Name), us-sanjose-1 (Shared Name)"))
	}
	exact := newHarness(t, collision)
	expectExit(t, exact.run("list", "--region", "us-sanjose-1"), 0)
	cities := testState(withClients(testClient("uid1/us--san-jose--1/"+firstUUID, "X", 0, "A")))
	split := newHarness(t, cities)
	expectExit(t, split.run("list", "--region", "san-jose", "--json"), 0)
}

func TestLongOfflineDetailsShowUnavailableAndSanitizeMetadata(t *testing.T) {
	h := newHarness(t, testState(func(s *ipc.State) { s.Access, s.Inventory = ipc.AccessOffline, ipc.InventoryCached },
		withClients(testClient(firstConfig, "California", 0, "Mac", func(c *ipc.Client) { c.InternalIP, c.Source = nil, "cache" }),
			testClient(secondConfig, "California", 0, "Other", func(c *ipc.Client) {
				c.InternalIP, c.ConnectionURL, c.Source = ptr("10.0.0.3/32"), ptr("wg.example.com\x1b[31m‮"), "cache"
			}))))
	expectExit(t, h.run("ls", "-l"), 0)
	for _, part := range []string{"Tunnel IP:       Unavailable", "Connection URL:  Unavailable", "Owner email:     Unknown",
		"Connection URL:  wg.example.com [31m ", "Tunnel IP:       10.0.0.3\n"} {
		expectContains(t, h.out.String(), part)
	}
	expectMissing(t, h.out.String(), "\x1b")
	if !strings.HasSuffix(h.out.String(), "Offline: showing this account's saved configs from cached authorization\n") {
		t.Fatalf("list:\n%s", h.out.String())
	}
}

func TestSelectorsFailBeforeReservingAndNeverFallBackToBareStop(t *testing.T) {
	for _, name := range []string{"up", "down"} {
		for _, tc := range []struct {
			operands []string
			exit     int
		}{{[]string{thirdUUID}, 5}, {[]string{"missing", "1"}, 2}, {[]string{"sanjose", "3"}, 2}} {
			h := newHarness(t, testState(withClients(testClient(firstConfig, "California", 0, "Mac")), withSelected(firstConfig)))
			expectExit(t, h.run(append(append([]string{name}, tc.operands...), "--json")...), tc.exit)
			expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot)
		}
		signedOutHarness := newHarness(t, testState(signedOut))
		expectExit(t, signedOutHarness.run(name, firstUUID), 3)
		expectActions(t, signedOutHarness.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot)
		duplicate := newHarness(t, testState(withClients(testClient(firstConfig, "California", 0, "Mac"),
			testClient("uid1/us-chicago-1/"+strings.ToUpper(firstUUID), "Chicago", 0, "Other"))))
		expectExit(t, duplicate.run(name, firstUUID), 5)
		expectContains(t, duplicate.diag.String(), "ambiguous")
	}
	h := newHarness(t, testState(withClients(testClient(firstConfig, "California", 0, "Mac"))))
	expectExit(t, h.run("down", "sanjose", "3"), 2)
	expectEqual(t, "diagnostics", h.diag.String(), "Error: Index 3 is out of range for us-sanjose-1\nUse an index from 1 to 1. Run: cloudgateway ls\n")
}

func TestScopedMutationsReserveOnceAndKeepResolvedTarget(t *testing.T) {
	for _, name := range []string{"up", "down"} {
		for _, operands := range [][]string{{strings.ToUpper(secondUUID)}, {"sanjose", "2"}} {
			h := newHarness(t, selectorState())
			action := ipc.ActionConnect
			outcome := &ipc.Outcome{Kind: ipc.OutcomeStartRequested, Identifier: secondConfig}
			if name == "down" {
				action, outcome = ipc.ActionDisconnectClient, &ipc.Outcome{Kind: ipc.OutcomeCompleted}
			}
			var reserved string
			h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
				switch request.Action {
				case action:
					reserved = request.ID
					// The account's inventory changes after reservation and must not change the target
					h.daemon.states = []ipc.State{testState(withClients(testClient(firstConfig, "California", 0, "Only client")))}
					return &ipc.Reply{Operation: &ipc.Operation{ID: request.ID, State: ipc.OperationAccepted}}
				case ipc.ActionConfirm:
					return &ipc.Reply{Operation: &ipc.Operation{ID: request.ContextID, State: ipc.OperationRunning}}
				case ipc.ActionOperation:
					state := h.daemon.states[0]
					return &ipc.Reply{State: &state, Operation: &ipc.Operation{ID: request.ContextID, State: ipc.OperationCompleted}, Outcome: outcome}
				}
				return nil
			}
			expectExit(t, h.run(append(append([]string{name}, operands...), "--json")...), 0)
			expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot, action, ipc.ActionConfirm, ipc.ActionOperation)
			expectEqual(t, "identifier", h.daemon.requestsFor(action)[0].Identifier, secondConfig)
			expectEqual(t, "records", len(h.records()), 2)
			expectEqual(t, "operation", field(h.last(), "operationId"), any(reserved))
		}
	}
}

func TestAccountChangesNeverReinterpretTheReservedSelector(t *testing.T) {
	for _, name := range []string{"up", "down"} {
		h := newHarness(t, selectorState())
		action := ipc.ActionConnect
		if name == "down" {
			action = ipc.ActionDisconnectClient
		}
		other := testState(func(s *ipc.State) { s.AccountID = ptr("uid2") },
			withClients(testClient("uid2/us-sanjose-1/"+secondUUID, "California", 0, "Other account")))
		h.daemon.onRequest = acceptAndConfirm(h.daemon, action, ipc.OperationFailed,
			&ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandSignInRequired}, func() *ipc.Reply { return &ipc.Reply{State: &other} })
		expectExit(t, h.run(name, "sanjose", "2", "--json"), 3)
		expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot, action, ipc.ActionConfirm)
		expectMissing(t, h.out.String(), "uid2/")
	}
}

func TestOrderingIsDeterministicAndExactRegionIDsWinAliasCollisions(t *testing.T) {
	clients := []ipc.Client{
		testClient(thirdConfig, "us-sanjose-1", 2, "A"),
		testClient(secondConfig, "California", 1, "Same", func(c *ipc.Client) { c.OwnerLabel = ptr("a@example.com") }),
		testClient(firstConfig, "California", 1, "Same", func(c *ipc.Client) { c.OwnerLabel = ptr("a@example.com") }),
		testClient("uid1/us-sanjose-1/"+thirdUUID, "California", 1, "A", func(c *ipc.Client) { c.OwnerLabel = ptr("z@example.com") }),
	}
	want := []string{secondConfig, firstConfig, "uid1/us-sanjose-1/" + thirdUUID}
	for _, rows := range [][]ipc.Client{clients, {clients[3], clients[2], clients[1], clients[0]}, {clients[1], clients[2], clients[3], clients[0]}} {
		state := testState(withClients(rows...))
		var got []string
		for _, c := range orderedRegions(state, "uid1")[0] {
			got = append(got, c.Identifier)
		}
		if !slices.Equal(got, want) {
			t.Fatalf("order %v", got)
		}
		if id, err := resolveInventoryRegion("us-sanjose-1", state, "uid1"); err != nil || id != "us-sanjose-1" {
			t.Fatalf("exact region %s %v", id, err)
		}
	}
}

func TestModeReportsSelectedAndAppliedModes(t *testing.T) {
	for _, arguments := range [][]string{{"mode"}, {"mode", "status"}} {
		h := newHarness(t, testState(func(s *ipc.State) {
			s.Tunnel.Phase, s.Tunnel.ConfigID, s.ActiveMode, s.SelectedMode = ipc.TunnelConnected, ptr(mutationConf), ptr(ipc.ModeFull), ptr(ipc.ModeMesh)
		}))
		expectExit(t, h.run(append(arguments, "--json")...), 0)
		expectEqual(t, "output", h.out.String(), `{"command":"mode status","data":{"activeMode":"full","observation":"current","observedAt":"2027-01-15T08:00:00Z","selectedMode":"mesh","tunnelState":"connected"},"error":null,"operationId":null,"schemaVersion":1,"type":"result"}`+"\n")
		expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot)
	}
	disconnected := newHarness(t, testState(func(s *ipc.State) { s.SelectedMode = ptr(ipc.ModeMesh) }))
	expectExit(t, disconnected.run("mode"), 0)
	expectEqual(t, "human", disconnected.out.String(), "Selected mode:     mesh\nActive mode:       none\nMode observation:  current at 2027-01-15T08:00:00Z\n")
	for _, edit := range []func(*ipc.State){
		func(s *ipc.State) { s.Tunnel.Phase = ipc.TunnelConnected },
		func(s *ipc.State) { s.Tunnel.Observation = ipc.ObservationStale },
		func(s *ipc.State) { s.Tunnel.Observation, s.Tunnel.ObservedAt = ipc.ObservationUnavailable, nil },
	} {
		h := newHarness(t, testState(edit, func(s *ipc.State) { s.SelectedMode = ptr(ipc.ModeMesh) }))
		expectExit(t, h.run("mode", "status"), 0)
		expectContains(t, h.out.String(), "Active mode:       unknown\n")
		if h.clock.elapsed() > observationWait {
			t.Fatalf("waited %v", h.clock.elapsed())
		}
	}
	signedOutMode := newHarness(t, testState(signedOut, func(s *ipc.State) {
		s.ActiveMode, s.SelectedMode, s.Tunnel.Phase = ptr(ipc.ModeMesh), ptr(ipc.ModeFull), ipc.TunnelConnected
	}))
	expectExit(t, signedOutMode.run("status", "--json"), 0)
	expectEqual(t, "selected", field(signedOutMode.last(), "data", "mode", "selectedMode"), nil)
	expectEqual(t, "active", field(signedOutMode.last(), "data", "mode", "activeMode"), any("mesh"))
	expectEqual(t, "auth", field(signedOutMode.last(), "data", "auth", "state"), any("signed_out"))
}

func TestCombinedStatusMapsEveryAuthStateWithoutWaiting(t *testing.T) {
	cases := []struct {
		edit func(*ipc.State)
		want string
	}{
		{signedOut, "signed_out"},
		{func(s *ipc.State) { signedOut(s); s.HasRetainedSession = true }, "retained"},
		{func(s *ipc.State) {
			signedOut(s)
			s.HasRetainedSession, s.IsRestoring, s.Access = true, true, ipc.AccessChecking
		}, "restoring"},
		{func(*ipc.State) {}, "online"},
		{func(s *ipc.State) { s.Access, s.Inventory = ipc.AccessOffline, ipc.InventoryCached }, "offline"},
		{func(s *ipc.State) { signedOut(s); s.HasRetainedSession, s.Access = true, ipc.AccessDenied }, "denied"},
	}
	for _, tc := range cases {
		h := newHarness(t, testState(tc.edit), testState())
		expectExit(t, h.run("status", "--json"), 0)
		expectEqual(t, "auth", field(h.last(), "data", "auth", "state"), any(tc.want))
		expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot)
		expectEqual(t, "elapsed", h.clock.elapsed(), 0)
	}
}

func TestModeMutationForwardsTypedModeAndUsesConfirmationAndPolling(t *testing.T) {
	for _, mode := range []ipc.Mode{ipc.ModeFull, ipc.ModeMesh} {
		state := testState(func(s *ipc.State) { s.SelectedMode = &mode })
		h := newHarness(t, state)
		h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
			switch request.Action {
			case ipc.ActionSetMode:
				if request.Mode != mode || request.Identifier != "" {
					t.Errorf("request %+v", request)
				}
				return &ipc.Reply{Operation: &ipc.Operation{ID: request.ID, State: ipc.OperationAccepted}}
			case ipc.ActionConfirm:
				return &ipc.Reply{State: &state, Operation: &ipc.Operation{ID: request.ContextID, State: ipc.OperationRunning}}
			case ipc.ActionOperation:
				return &ipc.Reply{State: &state, Operation: &ipc.Operation{ID: request.ContextID, State: ipc.OperationCompleted},
					Outcome: &ipc.Outcome{Kind: ipc.OutcomeCompleted}}
			}
			return nil
		}
		expectExit(t, h.run("mode", string(mode), "--json"), 0)
		records := h.records()
		expectEqual(t, "records", len(records), 2)
		expectEqual(t, "command", field(records[0], "command"), any("mode "+string(mode)))
		expectEqual(t, "requested", field(records[1], "data", "requestedMode"), any(string(mode)))
		expectEqual(t, "selected", field(records[1], "data", "mode", "selectedMode"), any(string(mode)))
		expectEqual(t, "active", field(records[1], "data", "mode", "activeMode"), nil)
		expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot, ipc.ActionSetMode, ipc.ActionConfirm, ipc.ActionOperation)
		expectEqual(t, "elapsed", h.clock.elapsed(), pollInterval)
		expectEqual(t, "JSON diagnostics", h.diag.String(), "")
		h.reset()
		expectExit(t, h.run("mode", string(mode)), 0)
		expectContains(t, h.out.String(), "Routing mode selected: "+string(mode)+"\n")
		expectContains(t, h.out.String(), "Active mode:       none\n")
		if mode == ipc.ModeFull {
			expectContains(t, h.diag.String(), "DHCP-provided DNS search domains")
			expectContains(t, h.diag.String(), "cloudgateway doctor")
		} else {
			expectEqual(t, "Mesh diagnostics", h.diag.String(), "")
		}
	}
	for _, tc := range []struct {
		edit func(*ipc.State)
		exit int
		code string
	}{
		{signedOut, 3, "sign_in_required"},
		{func(s *ipc.State) { signedOut(s); s.HasRetainedSession, s.Access = true, ipc.AccessDenied }, 3, "access_denied"},
		{func(s *ipc.State) { signedOut(s); s.HasRetainedSession, s.Access = true, ipc.AccessUnreachable }, 6, "network_unavailable"},
	} {
		h := newHarness(t, testState(tc.edit))
		expectExit(t, h.run("mode", "mesh", "--json"), tc.exit)
		expectEqual(t, "code", field(h.last(), "error", "code"), any(tc.code))
		expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot)
	}
	refreshing := newHarness(t, testState(func(s *ipc.State) { s.Inventory = ipc.InventoryRefreshing }))
	expectExit(t, refreshing.run("mode", "mesh", "--timeout", "1", "--json"), 8)
	if slices.Contains(refreshing.daemon.actions(), ipc.ActionSetMode) {
		t.Fatal("reserved while inventory was refreshing")
	}
}

func TestFullModeNoticePrintsBeforeAFailedSwitch(t *testing.T) {
	h := newHarness(t, testState())
	h.daemon.onRequest = acceptAndConfirm(h.daemon, ipc.ActionSetMode, ipc.OperationFailed,
		&ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandSetupRequired}, func() *ipc.Reply {
			expectContains(t, h.diag.String(), "DHCP-provided DNS search domains")
			return &ipc.Reply{}
		})

	expectExit(t, h.run("mode", "full"), 4)
	expectContains(t, h.diag.String(), "cloudgateway doctor")
	expectContains(t, h.diag.String(), "cloudgateway mode mesh")
}

func TestModeOutputFailureLeavesReservationUnconfirmedAndTimeoutDetaches(t *testing.T) {
	for _, failsOutput := range []bool{true, false} {
		h := newHarness(t, testState())
		h.failsOutput = failsOutput
		h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
			switch request.Action {
			case ipc.ActionSetMode:
				return &ipc.Reply{Operation: &ipc.Operation{ID: request.ID, State: ipc.OperationAccepted}}
			case ipc.ActionConfirm:
				return hangReply
			}
			return nil
		}
		want := 8
		if failsOutput {
			want = 1
		}
		expectExit(t, h.run("mode", "mesh", "--timeout", "0.2", "--json"), want)
		expectEqual(t, "reservations", len(h.daemon.requestsFor(ipc.ActionSetMode)), 1)
		expectEqual(t, "confirmed", len(h.daemon.requestsFor(ipc.ActionConfirm)) == 1, !failsOutput)
		if !failsOutput {
			id := h.daemon.requestsFor(ipc.ActionSetMode)[0].ID
			expectEqual(t, "operation", field(h.last(), "operationId"), any(id))
			expectEqual(t, "suggestion", field(h.last(), "error", "suggestion"), any("Check this operation before retrying: cloudgateway status --operation "+id))
		}
	}
}
