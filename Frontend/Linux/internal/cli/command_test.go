package cli

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

const (
	east = "uid1/us-east-1/mac"
	west = "uid1/us-west-2/laptop"
)

func onlineState(edits ...func(*ipc.State)) ipc.State {
	return testState(append([]func(*ipc.State){withClients(
		testClient(west, "US West", 2, "Laptop", func(c *ipc.Client) { c.Installed = false; c.Status = "" }),
		testClient(east, "US East", 1, "Mac", func(c *ipc.Client) { c.Status = ipc.ClientTunnelConnected }),
		testClient("uid1/us-east-1/old", "US East", 1, "Old", func(c *ipc.Client) {
			c.InternalIP, c.Installed, c.Eligibility, c.CloudState, c.Status = nil, false, "inactive", "removed", ""
		}),
	), withSelected(east), func(s *ipc.State) {
		s.Tunnel.Phase, s.Tunnel.ConfigID = ipc.TunnelConnected, ptr(east)
	}}, edits...)...)
}

func stale(s *ipc.State) { s.Tunnel.Observation = ipc.ObservationStale }

func TestSignedOutStatusHidesAccountDetails(t *testing.T) {
	h := newHarness(t, testState(signedOut, func(s *ipc.State) {
		s.Inventory = ipc.InventoryUnavailable
		s.Tunnel.Phase = ipc.TunnelConnected
	}))
	expectExit(t, h.run("auth", "status"), 0)
	expectEqual(t, "auth", h.out.String(), "Auth:         Signed out\nAccount:      none\nAccess:       unverified\nCredentials:  unknown\n")
	h.reset()
	expectExit(t, h.run("status", "--json"), 0)
	expectEqual(t, "tunnel state", field(h.last(), "data", "tunnel", "state"), any("connected"))
	expectEqual(t, "config", field(h.last(), "data", "tunnel", "configId"), nil)
	expectExit(t, h.run("list"), 3)
	expectEqual(t, "diagnostics", h.diag.String(), "Error: Sign-in required\nRun: cloudgateway auth login\n")
}

func TestWaitsForStartupRestorationWithinTheDeadline(t *testing.T) {
	restoring := testState(signedOut, func(s *ipc.State) {
		s.IsRestoring, s.HasRetainedSession, s.Access, s.Inventory = true, true, ipc.AccessChecking, ipc.InventoryUnavailable
	})
	h := newHarness(t, restoring, restoring, onlineState())
	expectExit(t, h.run("auth", "status", "--json"), 0)
	expectEqual(t, "state", field(h.last(), "data", "state"), any("online"))
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionSnapshot, ipc.ActionSnapshot, ipc.ActionSnapshot)
	expectEqual(t, "elapsed", h.clock.elapsed(), time.Second)

	// Read commands default to a 30 second deadline when --timeout is absent
	defaulted := newHarness(t, restoring)
	expectExit(t, defaulted.run("list"), 8)
	expectEqual(t, "elapsed", defaulted.clock.elapsed(), 29500*time.Millisecond)

	stuck := newHarness(t, restoring)
	expectExit(t, stuck.run("auth", "status", "--timeout", "2", "--json"), 0)
	expectEqual(t, "state", field(stuck.last(), "data", "state"), any("restoring"))
	if stuck.clock.elapsed() >= 2*time.Second {
		t.Fatalf("elapsed %v", stuck.clock.elapsed())
	}
	stuck.reset()
	expectExit(t, stuck.run("list", "--timeout", "2", "--json"), 8)
	expectEqual(t, "message", field(stuck.last(), "error", "message"), any("CloudGateway is still restoring this session"))
}

func TestListsAuthorizedOnlineInventoryByRegion(t *testing.T) {
	h := newHarness(t, onlineState())
	expectExit(t, h.run("list"), 0)
	expectEqual(t, "list", h.out.String(), `US East (us-east-1)
  1  Mac  mac  connected, selected
  2  Old  old  removed, inactive

US West (us-west-2)
  1  Laptop  laptop

Tunnel observation: current at 2027-01-15T08:00:00Z
Inventory: current
`)
	h.reset()
	expectExit(t, h.run("list", "--region", "us-west-2", "--json"), 0)
	expectEqual(t, "json", h.out.String(), `{"command":"list","data":{"accountId":"uid1","freshness":"current","profileObservation":"current","profilesObservedAt":"2027-01-15T08:00:00Z","regionId":"us-west-2","regions":[{"configs":[{"clientId":"laptop","cloudState":"active","configId":"uid1/us-west-2/laptop","connectionUrl":null,"eligibility":"eligible","index":1,"installed":false,"internalIp":"10.0.0.2","name":"Laptop","owner":null,"readAt":"1970-01-01T00:00:00Z","selected":false,"source":"cloud","tunnel":null,"updatedAt":null}],"name":"US West","regionId":"us-west-2"}],"scope":"authorized"},"error":null,"operationId":null,"schemaVersion":1,"type":"result"}`+"\n")
	h.reset()
	expectExit(t, h.run("list", "--region", "eu-west-1"), 2)
	expectEqual(t, "diagnostics", h.diag.String(), "Error: Region 'eu-west-1' is unavailable in this account's current inventory\n"+
		"Available regions: us-east-1 (US East), us-west-2 (US West)\n")
}

func TestListLabelsRetainedTunnelStateAfterAProfileReadFails(t *testing.T) {
	h := newHarness(t, onlineState(stale))
	expectExit(t, h.run("list"), 0)
	expectContains(t, h.out.String(), "connected (stale), selected")
	if !strings.HasSuffix(h.out.String(), "Tunnel observation: stale, last observed at 2027-01-15T08:00:00Z\nInventory: current\n") {
		t.Fatalf("list:\n%s", h.out.String())
	}
	h.reset()
	expectExit(t, h.run("list", "--json"), 0)
	expectEqual(t, "observation", field(h.last(), "data", "profileObservation"), any("stale"))
	expectEqual(t, "tunnel", field(field(h.last(), "data", "regions").([]any)[0], "configs").([]any)[0].(map[string]any)["tunnel"], any("connected"))

	missing := newHarness(t, onlineState(func(s *ipc.State) { s.Tunnel.Observation, s.Tunnel.ObservedAt = ipc.ObservationUnavailable, nil }))
	expectExit(t, missing.run("list", "--json"), 0)
	expectEqual(t, "observed at", field(missing.last(), "data", "profilesObservedAt"), nil)
	expectEqual(t, "tunnel", field(field(missing.last(), "data", "regions").([]any)[0], "configs").([]any)[0].(map[string]any)["tunnel"], nil)
	missing.reset()
	expectExit(t, missing.run("list"), 0)
	expectMissing(t, missing.out.String(), "connected")
	if !strings.HasSuffix(missing.out.String(), "Tunnel observation: unavailable\nInventory: current\n") {
		t.Fatalf("list:\n%s", missing.out.String())
	}
}

func TestOfflineListShowsReducedCachedScope(t *testing.T) {
	h := newHarness(t, onlineState(func(s *ipc.State) { s.Access, s.Inventory = ipc.AccessOffline, ipc.InventoryCached }))
	expectExit(t, h.run("auth", "status", "--json"), 0)
	expectEqual(t, "state", field(h.last(), "data", "state"), any("offline"))
	h.reset()
	expectExit(t, h.run("list", "--json"), 0)
	expectEqual(t, "scope", field(h.last(), "data", "scope"), any("installed"))
	expectEqual(t, "freshness", field(h.last(), "data", "freshness"), any("cached"))
	h.reset()
	expectExit(t, h.run("list"), 0)
	if !strings.HasSuffix(h.out.String(), "\nOffline: showing this account's saved configs from cached authorization\n") {
		t.Fatalf("list:\n%s", h.out.String())
	}
}

func TestDeniedAndUnavailableInventoryFailWithStableCodes(t *testing.T) {
	denied := newHarness(t, testState(signedOut, func(s *ipc.State) { s.Access, s.Inventory = ipc.AccessDenied, ipc.InventoryUnavailable }))
	expectExit(t, denied.run("auth", "status", "--json"), 0)
	expectEqual(t, "state", field(denied.last(), "data", "state"), any("denied"))
	expectExit(t, denied.run("list"), 3)
	expectEqual(t, "diagnostics", denied.diag.String(), "Error: Account access was denied\nSign in again after access is restored\n")

	unreachable := newHarness(t, testState(signedOut, func(s *ipc.State) {
		s.HasRetainedSession, s.Access, s.Inventory = true, ipc.AccessUnreachable, ipc.InventoryUnavailable
	}))
	expectExit(t, unreachable.run("auth", "status", "--json"), 0)
	expectEqual(t, "state", field(unreachable.last(), "data", "state"), any("retained"))
	unreachable.reset()
	expectExit(t, unreachable.run("list", "--json"), 6)
	expectEqual(t, "message", field(unreachable.last(), "error", "message"), any("Unable to reach CloudGateway to restore this account"))

	for _, alias := range []string{"list", "ls"} {
		for _, filter := range [][]string{nil, {"--region", "chicago"}} {
			h := newHarness(t, testState(func(s *ipc.State) { s.Inventory = ipc.InventoryUnavailable }))
			expectExit(t, h.run(append([]string{alias}, filter...)...), 6)
			expectEqual(t, "output", h.out.String(), "")
			expectEqual(t, "diagnostics", h.diag.String(), "Waiting for network… Try again soon.\n")
			h.reset()
			expectExit(t, h.run(append([]string{alias, "--json"}, filter...)...), 6)
			expectEqual(t, "code", field(h.last(), "error", "code"), any("network_unavailable"))
			expectEqual(t, "data", field(h.last(), "data"), nil)
		}
	}

	refreshing := newHarness(t, testState(func(s *ipc.State) { s.Inventory = ipc.InventoryRefreshing }))
	expectExit(t, refreshing.run("list", "--timeout", "1"), 8)
	expectEqual(t, "diagnostics", refreshing.diag.String(), "Error: CloudGateway is still loading inventory\nTry again with a longer --timeout\n")

	for _, freshness := range []ipc.InventoryFreshness{ipc.InventoryCurrent, ipc.InventoryCached} {
		h := newHarness(t, testState(func(s *ipc.State) { s.Inventory = freshness }))
		expectExit(t, h.run("ls", "--region", "chicago", "--json"), 2)
		expectEqual(t, "suggestion", field(h.last(), "error", "suggestion"), any("Available regions: none"))
	}
	empty := newHarness(t, testState())
	expectExit(t, empty.run("ls"), 0)
	expectEqual(t, "empty", empty.out.String(), "No configs\n\nTunnel observation: current at 2027-01-15T08:00:00Z\nInventory: current\n")
}

func TestStatusReportsObservationOperationModeAndAuth(t *testing.T) {
	h := newHarness(t, onlineState(stale))
	expectExit(t, h.run("status"), 0)
	expectEqual(t, "status", h.out.String(), `VPN:          connected
Observation:  stale, last observed at 2027-01-15T08:00:00Z
Config:       uid1/us-east-1/mac
Operation:    none retained
Selected mode:     unavailable
Active mode:       unknown
Mode observation:  stale, last observed at 2027-01-15T08:00:00Z
Auth:         Signed in (online)
Account:      uid1
Access:       online
Credentials:  available
`)
	if h.clock.elapsed() > observationWait {
		t.Fatalf("waited %v", h.clock.elapsed())
	}

	missing := newHarness(t, testState(func(s *ipc.State) { s.Tunnel.Observation, s.Tunnel.ObservedAt = ipc.ObservationUnavailable, nil }))
	expectExit(t, missing.run("status", "--json"), 0)
	expectEqual(t, "state", field(missing.last(), "data", "tunnel", "state"), any("unknown"))
	expectEqual(t, "observation", field(missing.last(), "data", "tunnel", "observation"), any("unavailable"))

	id := "6f9619ff-8b86-d011-b42d-00c04fc964ff"
	latest := newHarness(t, onlineState())
	latest.daemon.operation = &ipc.Operation{ID: id, State: ipc.OperationCompleted}
	latest.daemon.outcome = &ipc.Outcome{Kind: ipc.OutcomeStartRequested, Identifier: east, Warning: ipc.WarningSelectionNotSaved}
	expectExit(t, latest.run("status"), 0)
	expectContains(t, latest.out.String(), "Operation:    "+id+" completed, start requested for "+east+" (selection not saved)\n")
	latest.reset()
	expectExit(t, latest.run("status", "--json"), 0)
	expectEqual(t, "envelope operation", field(latest.last(), "operationId"), nil)
	expectEqual(t, "data operation", field(latest.last(), "data", "operation", "id"), any(id))
}

func TestHumanStatusAsksWhetherTheServerResponds(t *testing.T) {
	h := newHarness(t, onlineState(func(s *ipc.State) { s.ServerResponding = ptr(false) }))
	expectExit(t, h.run("status"), 0)
	if !strings.HasPrefix(h.out.String(), "VPN:          connected\nObservation:  current at 2027-01-15T08:00:00Z\n"+
		"Config:       uid1/us-east-1/mac\nServer:       not responding. Run: cloudgateway refresh\nOperation:") {
		t.Fatalf("status:\n%s", h.out.String())
	}
	expectEqual(t, "check server", h.daemon.requestsFor(ipc.ActionSnapshot)[0].CheckServer, true)
	h.reset()
	expectExit(t, h.run("status", "--json"), 0)
	expectEqual(t, "json check server", h.daemon.requestsFor(ipc.ActionSnapshot)[0].CheckServer, false)
	expectMissing(t, h.out.String(), "refresh")
	for _, arguments := range [][]string{{"mode", "status"}, {"status", "--operation", "6f9619ff-8b86-d011-b42d-00c04fc964ff"}} {
		h.reset()
		h.run(arguments...)
		for _, request := range h.daemon.requestsFor(ipc.ActionSnapshot) {
			expectEqual(t, strings.Join(arguments, " "), request.CheckServer, false)
		}
	}
	responding := newHarness(t, onlineState(func(s *ipc.State) { s.ServerResponding = ptr(true) }))
	expectExit(t, responding.run("status"), 0)
	expectMissing(t, responding.out.String(), "Server:")
}

func TestOtherDaemonVersionsUseCompatibleStatusOnly(t *testing.T) {
	h := newHarness(t, onlineState())
	h.daemon.version = ipc.Version + 1
	h.daemon.handshakeTunnel = ipc.Tunnel{Phase: ipc.TunnelConnected, Observation: ipc.ObservationCurrent, ObservedAt: &observedAt, ConfigID: ptr(east)}
	expectExit(t, h.run("auth", "status", "--json"), 4)
	expectEqual(t, "code", field(h.last(), "error", "code"), any("incompatible_version"))
	h.reset()
	expectExit(t, h.run("status", "--json"), 0)
	expectEqual(t, "status", h.out.String(), `{"command":"status","data":{"auth":null,"mode":null,"operation":null,"tunnel":{"configId":null,"observation":"current","observedAt":null,"state":"connected"}},"error":null,"operationId":null,"schemaVersion":1,"type":"result"}`+"\n")
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionHandshake)
	h.reset()
	expectExit(t, h.run("status"), 0)
	expectEqual(t, "human", h.out.String(), "VPN:          connected\nObservation:  current\nOperation:    none retained\nMode:  unavailable\nAuth:  unavailable\n")
	h.reset()
	expectExit(t, h.run("mode", "status", "--json"), 4)
	expectEqual(t, "suggestion", field(h.last(), "error", "suggestion"), any("Wait for the daemon restart to finish, or run: sudo systemctl restart cloudgatewayd"))

	draining := newHarness(t, onlineState())
	draining.daemon.lifecycle = ipc.LifecycleDraining
	expectExit(t, draining.run("list", "--json"), 4)
	expectEqual(t, "code", field(draining.last(), "error", "code"), any("incompatible_version"))

	invalid := newHarness(t, onlineState())
	invalid.daemon.lifecycle = ipc.LifecycleInvalidInstallation
	expectExit(t, invalid.run("list", "--json"), 4)
	expectEqual(t, "code", field(invalid.last(), "error", "code"), any("installation_required"))
}

func TestDaemonConnectionFailuresMapToStableCodes(t *testing.T) {
	missing := newHarness(t)
	missing.daemon.stop()
	expectExit(t, missing.run("status", "--json"), 4)
	expectEqual(t, "code", field(missing.last(), "error", "code"), any("controller_unavailable"))
	expectEqual(t, "suggestion", field(missing.last(), "error", "suggestion"), any("Check it with: systemctl status cloudgatewayd"))

	uninstalled := newHarness(t)
	uninstalled.daemon.stop()
	uninstalled.currentLink = filepath.Join(t.TempDir(), "current")
	expectExit(t, uninstalled.run("list"), 4)
	expectEqual(t, "diagnostics", uninstalled.diag.String(),
		"Error: CloudGateway is not installed\nInstall CloudGateway with the installer, then try again\n")

	if os.Geteuid() != 0 {
		denied := newHarness(t, testState())
		if err := os.Chmod(denied.daemon.path, 0); err != nil {
			t.Fatal(err)
		}
		expectExit(t, denied.run("auth", "status"), 4)
		expectEqual(t, "diagnostics", denied.diag.String(), "Error: The CloudGateway daemon rejected this request\n"+
			"Run the command as root or as the operator account enrolled during installation\n")
	}

	rejected := newHarness(t, testState())
	rejected.daemon.onRequest = func(ipc.Request) *ipc.Reply { return &ipc.Reply{Error: ipc.FailureRejected} }
	expectExit(t, rejected.run("list", "--json"), 4)
	expectEqual(t, "code", field(rejected.last(), "error", "code"), any("controller_rejected"))

	dropped := newHarness(t, testState())
	dropped.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionSnapshot {
			return dropReply
		}
		return nil
	}
	expectExit(t, dropped.run("list"), 4)
	expectEqual(t, "diagnostics", dropped.diag.String(), "Error: Unable to reach the CloudGateway daemon\nCheck it with: systemctl status cloudgatewayd\n")

	hung := newHarness(t, testState())
	hung.daemon.hung[ipc.ActionSnapshot] = true
	expectExit(t, hung.run("list", "--json", "--timeout", "0.2"), 8)
	expectEqual(t, "code", field(hung.last(), "error", "code"), any("timeout"))
}

func TestOperationLookupMapsTheRetainedOutcome(t *testing.T) {
	id := "6f9619ff-8b86-d011-b42d-00c04fc964ff"
	h := newHarness(t)
	h.daemon.operation = &ipc.Operation{ID: id, State: ipc.OperationCompleted}
	h.daemon.outcome = &ipc.Outcome{Kind: ipc.OutcomeStartRequested, Identifier: east}
	expectExit(t, h.run("status", "--operation", strings.ToUpper(id), "--json"), 0)
	expectEqual(t, "operation id", field(h.last(), "operationId"), any(id))
	expectActions(t, h.daemon, ipc.ActionHandshake, ipc.ActionUserActivity, ipc.ActionOperation)
	expectEqual(t, "context", h.daemon.requestsFor(ipc.ActionOperation)[0].ContextID, id)

	h.daemon.operation = &ipc.Operation{ID: id, State: ipc.OperationFailed, Failure: ipc.FailureCommandFailed}
	h.daemon.outcome = &ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandVPNFailed}
	expectExit(t, h.run("status", "--operation", id), 9)
	if !strings.HasSuffix(h.diag.String(), "Error: The VPN operation failed\nRun: cloudgateway status\n") {
		t.Fatalf("diagnostics:\n%s", h.diag.String())
	}

	h.daemon.operation = &ipc.Operation{ID: id, State: ipc.OperationUnknown}
	h.daemon.outcome = &ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandStopTimedOut}
	expectExit(t, h.run("status", "--operation", id), 8)

	// Another session's connect result keeps only its coarse state
	h.daemon.operation, h.daemon.outcome = &ipc.Operation{ID: id, State: ipc.OperationCompleted}, nil
	h.reset()
	expectExit(t, h.run("status", "--operation", id, "--json"), 0)
	expectEqual(t, "result", field(h.last(), "data", "operation", "result"), nil)
	expectEqual(t, "config", field(h.last(), "data", "operation", "configId"), nil)

	failed := newHarness(t)
	failed.daemon.handshakeTunnel = ipc.Tunnel{Phase: ipc.TunnelConnected, Observation: ipc.ObservationCurrent}
	failed.daemon.operation = &ipc.Operation{ID: id, State: ipc.OperationFailed}
	failed.daemon.outcome = &ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandNetworkUnavailable}
	expectExit(t, failed.run("status", "--operation", id), 6)
	expectContains(t, failed.out.String(), "VPN:          connected\n")
	expectContains(t, failed.out.String(), "Operation:    "+id+" failed, failed\n")
	expectEqual(t, "diagnostics", failed.diag.String(), "Waiting for network… Try again soon.\n")

	wrong := newHarness(t)
	wrong.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionOperation {
			return &ipc.Reply{Operation: &ipc.Operation{ID: "4830b738-2823-4888-bf37-2918ae356ad5", State: ipc.OperationCompleted}}
		}
		return nil
	}
	expectExit(t, wrong.run("status", "--operation", id, "--json"), 1)
	expectEqual(t, "code", field(wrong.last(), "error", "code"), any("invalid_response"))
}

func TestUnknownOperationReportsObservedState(t *testing.T) {
	h := newHarness(t)
	h.daemon.handshakeTunnel = ipc.Tunnel{Phase: ipc.TunnelConnected, Observation: ipc.ObservationCurrent, ObservedAt: &observedAt}
	expectExit(t, h.run("status", "--operation", "6F9619FF-8B86-D011-B42D-00C04FC964FF", "--json"), 10)
	expectEqual(t, "output", h.out.String(), `{"command":"status","data":{"auth":null,"mode":null,"operation":{"configId":null,"error":{"code":"operation_unknown","message":"The operation result is unknown or no longer retained","suggestion":"Run cloudgateway status before trying again"},"id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","result":null,"state":"unknown","warning":null},"tunnel":{"configId":null,"observation":"current","observedAt":null,"state":"connected"}},"error":{"code":"operation_unknown","message":"The operation result is unknown or no longer retained","suggestion":"Run cloudgateway status before trying again"},"operationId":"6f9619ff-8b86-d011-b42d-00c04fc964ff","schemaVersion":1,"type":"error"}`+"\n")
	expectEqual(t, "diagnostics", h.diag.String(), "")
}

func TestOperationLookupUsesTheSnapshotDetailsAndRedaction(t *testing.T) {
	id := "6f9619ff-8b86-d011-b42d-00c04fc964ff"
	for _, account := range []*string{nil, ptr("uid2")} {
		state := testState(func(s *ipc.State) {
			s.AccountID, s.Tunnel.Phase = account, ipc.TunnelConnected
		})
		h := newHarness(t)
		h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
			if request.Action == ipc.ActionOperation {
				return &ipc.Reply{State: &state, Operation: &ipc.Operation{ID: id, State: ipc.OperationCompleted}}
			}
			return nil
		}
		expectExit(t, h.run("status", "--operation", id, "--json"), 0)
		expectEqual(t, "tunnel", field(h.last(), "data", "tunnel", "state"), any("connected"))
		expectEqual(t, "observed", field(h.last(), "data", "tunnel", "observedAt"), any("2027-01-15T08:00:00Z"))
		expectEqual(t, "config", field(h.last(), "data", "operation", "configId"), nil)
		expectEqual(t, "auth", field(h.last(), "data", "auth", "state") != nil, true)
		expectMissing(t, h.out.String(), "uid1/")
	}
}

func TestStaleSocketWithoutAnInstalledReleaseNeedsInstallation(t *testing.T) {
	for _, installed := range []bool{false, true} {
		h := newHarness(t)
		h.daemon.stop()
		listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: h.daemon.path, Net: "unix"})
		if err != nil {
			t.Fatal(err)
		}
		// Leave the socket file behind so connecting is refused
		listener.SetUnlinkOnClose(false)
		_ = listener.Close()
		want := "controller_unavailable"
		if !installed {
			h.currentLink = filepath.Join(t.TempDir(), "current")
			want = "installation_required"
		}
		expectExit(t, h.run("status", "--json"), 4)
		expectEqual(t, "code", field(h.last(), "error", "code"), any(want))
	}
}
