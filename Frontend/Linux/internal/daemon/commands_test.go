package daemon

import (
	"encoding/json"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/cloud"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network/networktest"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
)

func secretFiles(t *testing.T, dir string) int {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(dir, "secrets"))
	if err != nil {
		t.Fatal(err)
	}
	return len(entries)
}

func TestFreshAccountStartsInMeshWithDHCPDomains(t *testing.T) {
	h := newHarness(t)
	h.host.SetLinkDomains("enp0s1", "lan")
	state := h.signedIn(userA)
	expect(t, "default mode", deref(state.SelectedMode), any(ipc.ModeMesh))

	started := h.up(configA)
	expect(t, "started", started.outcome.Kind, ipc.OutcomeStartRequested)
	expect(t, "active mode", deref(started.reply.State.ActiveMode), any(ipc.ModeMesh))
	expect(t, "owned", h.owned(), meshOwned)
	expect(t, "DNS policy", h.probe("dns_policy"), "pass")
}

func TestUpInstallsThenReportsAlreadyActive(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeFull})

	bare := h.up("")
	expect(t, "bare without selection", bare.outcome.Failure, ipc.CommandSelectionUnavailable)
	expect(t, "bare state", bare.operation.State, ipc.OperationFailed)
	expect(t, "bare failure", bare.operation.Failure, ipc.FailureRejected)

	started := h.up(configA)
	expect(t, "outcome", *started.outcome, ipc.Outcome{Kind: ipc.OutcomeStartRequested, Identifier: configA})
	expect(t, "operation", started.operation.State, ipc.OperationCompleted)
	expect(t, "owned", h.owned(), fullOwned)
	expect(t, "secret records", secretFiles(t, h.dir), 1)
	intent := h.intent()
	expect(t, "intent", intent.Phase+" "+store.IntentPhase(intent.ProfileID)+" "+store.IntentPhase(intent.Mode),
		store.IntentPhase("running "+configA+" full"))
	expect(t, "intent generation", intent.SessionGeneration, uint64(1))
	state := started.reply.State
	expect(t, "tunnel", state.Tunnel.Phase, ipc.TunnelConnected)
	expect(t, "config", deref(state.Tunnel.ConfigID), any(configA))
	expect(t, "active mode", deref(state.ActiveMode), any(ipc.ModeFull))
	expect(t, "selected", deref(state.SelectedIdentifier), any(configA))
	for _, client := range state.Clients {
		want := map[string]ipc.ClientTunnel{configA: ipc.ClientTunnelConnected, configB: ""}[client.Identifier]
		expect(t, "row "+client.Identifier, client.Status, want)
	}

	h.host.ResetCalls()
	again := h.up("")
	expect(t, "again", *again.outcome, ipc.Outcome{Kind: ipc.OutcomeAlreadyActive, Identifier: configA})
	expect(t, "mutations", len(h.mutations()), 0)
	expect(t, "secret records after repeat", secretFiles(t, h.dir), 1)
}

func TestUpSwitchesClientsAndRestoresMissingSecret(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)

	switched := h.up(configB)

	expect(t, "outcome", switched.outcome.Kind, ipc.OutcomeStartRequested)
	expect(t, "config", deref(switched.reply.State.Tunnel.ConfigID), any(configB))
	link, _ := h.host.Link("cloudgateway")
	expect(t, "address", link.Addrs[0].Prefix, netip.MustParsePrefix("10.0.0.3/32"))
	// A retained record that disappeared is reinstalled from the online inventory
	st := h.st()
	saved, _ := st.Accounts().Load(userA)
	for _, config := range saved.Configs {
		if config.Identifier == configA {
			if err := st.DeleteSecret(config.Snapshot.SecretReference); err != nil {
				t.Fatal(err)
			}
		}
	}
	back := h.up(configA)
	expect(t, "reinstalled", back.outcome.Kind, ipc.OutcomeStartRequested)
	expect(t, "records", secretFiles(t, h.dir), 2)
}

func TestUpPreflightConflictKeepsCurrentTunnel(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	h.host.AddAddress("enp0s1", netip.MustParsePrefix("10.0.0.50/24"), "global")
	intent := h.intent()
	h.host.ResetCalls()

	out := h.up(configB)

	expect(t, "outcome", *out.outcome, ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandVPNFailed})
	expect(t, "mutations", len(h.mutations()), 0)
	expect(t, "config", deref(out.reply.State.Tunnel.ConfigID), any(configA))
	after := h.intent()
	expect(t, "profile", after.ProfileID+" "+string(after.Phase), configA+" running")
	expect(t, "revision", after.Revision, intent.Revision)
}

func TestUpSetupFailureAndApplyRollback(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.host.RemoveTool("nft")

	missing := h.up(configA)
	expect(t, "missing tools", missing.outcome.Failure, ipc.CommandSetupRequired)

	h = newHarness(t)
	h.signedIn(userA)
	h.host.FailWhen(networktest.Match("ip", "link", "set", "dev", "cloudgateway", "up"))
	failed := h.up(configA)

	expect(t, "apply failure", failed.outcome.Failure, ipc.CommandVPNFailed)
	expect(t, "owned", h.owned(), "")
	expect(t, "tunnel", failed.reply.State.Tunnel.Phase, ipc.TunnelDisconnected)
	intent := h.intent()
	expect(t, "intent", string(intent.Phase)+" "+string(intent.FailureCode), "stopped vpn_failed")
}

func TestModeSwitchDisconnectedAndConnected(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)

	saved := h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeMesh})
	expect(t, "disconnected", *saved.outcome, ipc.Outcome{Kind: ipc.OutcomeCompleted})
	expect(t, "selected", deref(saved.reply.State.SelectedMode), any(ipc.ModeMesh))
	expect(t, "same mode", h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeMesh}).outcome.Kind, ipc.OutcomeCompleted)

	h.up(configA)
	expect(t, "mesh owned", h.owned(), meshOwned)
	full := h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeFull})

	expect(t, "restart", *full.outcome, ipc.Outcome{Kind: ipc.OutcomeStartRequested, Identifier: configA})
	expect(t, "active", deref(full.reply.State.ActiveMode), any(ipc.ModeFull))
	expect(t, "full owned", h.owned(), fullOwned)
	same := h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeFull})
	expect(t, "already active", *same.outcome, ipc.Outcome{Kind: ipc.OutcomeAlreadyActive, Identifier: configA})
	st := h.st()
	cached, _ := st.Accounts().Load(userA)
	expect(t, "saved mode", *cached.SelectedMode, ipc.ModeFull)
}

func TestDownWorksSignedOutAndConfirmsStop(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	h.run(ipc.Request{Action: ipc.ActionSignOut})

	h.host.FailWhen(networktest.Match("ip", "link", "del"))
	failed := h.run(ipc.Request{Action: ipc.ActionTurnOff})
	expect(t, "failed stop", failed.operation.State, ipc.OperationUnknown)
	expect(t, "failed outcome", failed.outcome.Failure, ipc.CommandStopTimedOut)

	h.host.ClearFailures()
	down := h.run(ipc.Request{Action: ipc.ActionTurnOff})
	expect(t, "down", *down.outcome, ipc.Outcome{Kind: ipc.OutcomeCompleted})
	expect(t, "owned", h.owned(), "")
	expect(t, "tunnel", down.reply.State.Tunnel.Phase, ipc.TunnelDisconnected)
	intent := h.intent()
	expect(t, "intent", string(intent.Phase)+" "+string(intent.Suppression), "stopped down")
	expect(t, "already stopped", h.run(ipc.Request{Action: ipc.ActionTurnOff}).outcome.Kind, ipc.OutcomeCompleted)
}

func TestDownRunsDuringPendingAdd(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	prepared := h.do(ipc.Request{Action: ipc.ActionPrepareClient})
	if prepared.Creation == nil {
		t.Fatalf("prepare = %+v", prepared)
	}
	addID := newID()
	add := h.do(ipc.Request{Action: ipc.ActionCreateClient, ID: addID, RegionID: region, ClientName: "Desk", ContextID: prepared.Creation.ID})
	expect(t, "add reserved", add.Operation.State, ipc.OperationAccepted)

	down := h.run(ipc.Request{Action: ipc.ActionTurnOff})

	expect(t, "down", down.outcome.Kind, ipc.OutcomeCompleted)
	expect(t, "owned", h.owned(), "")
	created := h.finish(addID, h.do(ipc.Request{Action: ipc.ActionConfirm, ContextID: addID}))
	expect(t, "add", *created.outcome, ipc.Outcome{Kind: ipc.OutcomeCompleted})
}

func TestTargetedDownStopsOnlyThatClient(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeFull})
	h.up(configA)

	other := h.run(ipc.Request{Action: ipc.ActionDisconnectClient, Identifier: configB})
	expect(t, "other", *other.outcome, ipc.Outcome{Kind: ipc.OutcomeCompleted})
	expect(t, "still up", h.owned(), fullOwned)
	unknown := h.run(ipc.Request{Action: ipc.ActionDisconnectClient, Identifier: userA + "/" + region + "/missing"})
	expect(t, "unknown target", unknown.operation.Failure, ipc.FailureRejected)

	stopped := h.run(ipc.Request{Action: ipc.ActionDisconnectClient, Identifier: configA})
	expect(t, "target", *stopped.outcome, ipc.Outcome{Kind: ipc.OutcomeCompleted})
	expect(t, "owned", h.owned(), "")

	h.run(ipc.Request{Action: ipc.ActionSignOut})
	signedOut := h.run(ipc.Request{Action: ipc.ActionDisconnectClient, Identifier: configA})
	expect(t, "signed out", signedOut.operation.Failure, ipc.FailureRejected)
}

func TestRemoveClient(t *testing.T) {
	tests := []struct {
		name    string
		setup   func(*harness)
		outcome ipc.Outcome
		state   ipc.OperationState
		deletes int
		evicted bool
		access  ipc.AccessState
	}{
		{name: "inactive", outcome: ipc.Outcome{Kind: ipc.OutcomeCompleted}, state: ipc.OperationCompleted, deletes: 1, evicted: true, access: ipc.AccessOnline},
		{name: "active", setup: func(h *harness) { h.up(configA) },
			outcome: ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandClientActive}, state: ipc.OperationFailed, access: ipc.AccessOnline},
		{name: "unobservable", setup: func(h *harness) {
			h.host.FailWhen(networktest.Match("ip", "-j", "-d", "-N", "address", "show"))
		}, outcome: ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandClientActive}, state: ipc.OperationFailed, access: ipc.AccessOnline},
		{name: "uncertain dispatch", setup: func(h *harness) {
			h.cloud.set(func(f *fakeCloud) { f.deleteErr = cloudError(cloud.KindUnavailable, 500, true) })
		}, outcome: ipc.Outcome{Kind: ipc.OutcomeUnknown}, state: ipc.OperationUnknown, deletes: 1, evicted: true, access: ipc.AccessOnline},
		{name: "forbidden", setup: func(h *harness) {
			h.cloud.set(func(f *fakeCloud) { f.deleteErr = cloudError(cloud.KindAccessDenied, 403, true) })
		}, outcome: ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandAccessDenied}, state: ipc.OperationFailed, deletes: 1, evicted: true, access: ipc.AccessDenied},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			h := newHarness(t)
			h.signedIn(userA)
			h.up(configA)
			h.up(configB)
			h.run(ipc.Request{Action: ipc.ActionTurnOff})
			h.settled()
			if test.setup != nil {
				test.setup(h)
			}
			session := h.c.session()

			out := h.run(ipc.Request{Action: ipc.ActionRemoveClient, Identifier: configA})

			// A denial signs out, which hides the outcome from everyone but its owner
			expect(t, "outcome", *h.c.registry.Outcome(out.operation.ID, session), test.outcome)
			expect(t, "state", out.operation.State, test.state)
			h.cloud.mu.Lock()
			deletes := len(h.cloud.deletes)
			h.cloud.mu.Unlock()
			expect(t, "deletes", deletes, test.deletes)
			st := h.st()
			saved, _ := st.Accounts().Load(userA)
			kept := false
			for _, config := range saved.Configs {
				kept = kept || config.Identifier == configA
			}
			expect(t, "evicted", !kept, test.evicted || test.access == ipc.AccessDenied)
			expect(t, "access", h.snapshot().Access, test.access)
			// Removal keeps retained secret records
			expect(t, "secret records", secretFiles(t, h.dir), 2)
		})
	}
}

func TestRemoveWarnsWhenInventoryDoesNotRefresh(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.cloud.set(func(f *fakeCloud) { f.deleteGate = make(chan struct{}) })
	id := newID()
	h.do(ipc.Request{Action: ipc.ActionRemoveClient, ID: id, Identifier: configA})
	reply := h.do(ipc.Request{Action: ipc.ActionConfirm, ContextID: id})
	h.eventually("delete dispatch", func() bool {
		h.c.mu.Lock()
		defer h.c.mu.Unlock()
		return h.c.installedLocked(configA, userA) == nil && h.c.rowLocked(configA) == nil
	})
	h.cloud.set(func(f *fakeCloud) {
		f.inventoryErr = cloudError(cloud.KindOffline, 0, false)
		close(f.deleteGate)
	})

	out := h.finish(id, reply)

	expect(t, "outcome", *out.outcome, ipc.Outcome{Kind: ipc.OutcomeCompleted, Warning: ipc.WarningInventoryNotRefreshed})
}

func TestAddClient(t *testing.T) {
	tests := []struct {
		name    string
		err     error
		refresh error
		outcome ipc.Outcome
		state   ipc.OperationState
	}{
		{name: "created", outcome: ipc.Outcome{Kind: ipc.OutcomeCompleted}, state: ipc.OperationCompleted},
		{name: "uncertain", err: cloudError(cloud.KindOffline, 0, true), outcome: ipc.Outcome{Kind: ipc.OutcomeUnknown}, state: ipc.OperationUnknown},
		{name: "not sent", err: cloudError(cloud.KindOffline, 0, false),
			outcome: ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandNetworkUnavailable}, state: ipc.OperationFailed},
		{name: "refresh fails", refresh: cloudError(cloud.KindOffline, 0, false),
			outcome: ipc.Outcome{Kind: ipc.OutcomeCompleted, Warning: ipc.WarningInventoryNotRefreshed}, state: ipc.OperationCompleted},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			h := newHarness(t)
			h.signedIn(userA)
			prepared := h.do(ipc.Request{Action: ipc.ActionPrepareClient}).Creation
			expect(t, "capacity", *prepared.Regions[0].Capacity, ipc.Capacity{Known: true, Limit: 10, Allocated: 2})
			h.cloud.set(func(f *fakeCloud) { f.createErr = test.err })
			if test.refresh != nil {
				h.cloud.set(func(f *fakeCloud) {
					f.inventoryErr = test.refresh
				})
			}

			out := h.run(ipc.Request{Action: ipc.ActionCreateClient, RegionID: region, ClientName: "Desk", ContextID: prepared.ID})

			expect(t, "outcome", *out.outcome, test.outcome)
			expect(t, "state", out.operation.State, test.state)
			h.cloud.mu.Lock()
			creates := len(h.cloud.creates)
			h.cloud.mu.Unlock()
			expect(t, "creates", creates, 1)
			if test.name == "created" {
				expect(t, "rows", len(out.reply.State.Clients), 3)
			}
			// The context was consumed, so a replayed add needs a new preparation
			again := h.run(ipc.Request{Action: ipc.ActionCreateClient, RegionID: region, ClientName: "Desk", ContextID: prepared.ID})
			expect(t, "reuse", again.operation.Failure, ipc.FailurePreparationExpired)
		})
	}
}

func TestAccountRedactionHidesOtherAccountsTunnelAndOutcome(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	started := h.up(configA)
	h.run(ipc.Request{Action: ipc.ActionSignOut})
	h.cloud.set(func(f *fakeCloud) { f.clients = []cloud.ClientDoc{clientDoc(userB, "client-b1", "Phone", 7)} })
	h.seedSession(userB, 3)
	h.restart()
	state := h.settled()

	expect(t, "account", deref(state.AccountID), any(userB))
	expect(t, "tunnel", state.Tunnel.Phase, ipc.TunnelConnected)
	expect(t, "config", deref(state.Tunnel.ConfigID), nil)
	expect(t, "rows", len(state.Clients), 1)
	expect(t, "row", state.Clients[0].Status, ipc.ClientTunnel(""))
	lookup := h.do(ipc.Request{Action: ipc.ActionOperation, ContextID: started.operation.ID})
	expect(t, "pre-restart result", lookup.Operation.State, ipc.OperationUnknown)
	expect(t, "outcome", lookup.Outcome == nil, true)
}

func TestNoSecretBytesInRepliesOrArguments(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeFull})
	h.up(configA)
	h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeMesh})
	h.do(ipc.Request{Action: ipc.ActionAwaitRefresh})
	for _, probe := range ipc.DoctorProbes {
		if !probe.Local {
			h.do(ipc.Request{Action: ipc.ActionDiagnostics, Probe: probe.Name})
		}
	}
	h.run(ipc.Request{Action: ipc.ActionTurnOff})

	secrets := []string{testPrivateKey, "refresh-" + userA, "id-" + userA}
	for _, reply := range h.replies {
		for _, secret := range secrets {
			if strings.Contains(reply, secret) {
				t.Fatalf("reply leaked a secret: %s", reply)
			}
		}
	}
	setconfs := 0
	for _, call := range h.host.Calls() {
		if strings.Contains(strings.Join(call.Args, " "), testPrivateKey) {
			t.Fatalf("argv leaked a key: %s", call)
		}
		if strings.Contains(string(call.Stdin), testPrivateKey) {
			if !call.Has("setconf", "cloudgateway", "/dev/stdin") {
				t.Fatalf("stdin of %s carried a key", call)
			}
			setconfs++
		}
	}
	expect(t, "setconf calls", setconfs, 2)
	intent, _ := json.Marshal(h.intent())
	for _, secret := range secrets {
		if strings.Contains(string(intent), secret) {
			t.Fatal("intent leaked a secret")
		}
	}
	h.mu.Lock()
	logs := strings.Join(h.logs, "\n")
	h.mu.Unlock()
	if strings.Contains(logs, testPrivateKey) || strings.Contains(logs, endpointHost) {
		t.Fatalf("logs leaked: %s", logs)
	}
}

func TestRemoveRefusesForeignMissingAndRemovedTargets(t *testing.T) {
	tests := []struct {
		name       string
		setup      func(*fakeCloud)
		identifier string
		outcome    ipc.Outcome
		access     ipc.AccessState
	}{
		{name: "foreign owner", setup: func(f *fakeCloud) {
			f.allOwners = true
			f.clients[0].OwnerUID = "user-c"
		}, identifier: configA, outcome: failedOutcome(ipc.CommandAccessDenied), access: ipc.AccessDenied},
		{name: "missing", identifier: userA + "/" + region + "/client-gone", outcome: failedOutcome(ipc.CommandConfigUnavailable), access: ipc.AccessOnline},
		{name: "already removed", setup: func(f *fakeCloud) { f.clients[0].Status = cloud.StatusRemoved },
			identifier: configA, outcome: failedOutcome(ipc.CommandConfigUnavailable), access: ipc.AccessOnline},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			h := newHarness(t)
			h.signedIn(userA)
			if test.setup != nil {
				h.cloud.set(test.setup)
			}
			session := h.c.session()

			out := h.run(ipc.Request{Action: ipc.ActionRemoveClient, Identifier: test.identifier})

			expect(t, "outcome", *h.c.registry.Outcome(out.operation.ID, session), test.outcome)
			h.cloud.mu.Lock()
			deletes := len(h.cloud.deletes)
			h.cloud.mu.Unlock()
			expect(t, "deletes", deletes, 0)
			expect(t, "access", h.snapshot().Access, test.access)
		})
	}
}

func TestCreateDenialSignsOut(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	prepared := h.do(ipc.Request{Action: ipc.ActionPrepareClient}).Creation
	h.cloud.set(func(f *fakeCloud) { f.createErr = cloudError(cloud.KindAccessDenied, 403, true) })
	session := h.c.session()

	out := h.run(ipc.Request{Action: ipc.ActionCreateClient, RegionID: region, ClientName: "Desk", ContextID: prepared.ID})

	expect(t, "outcome", *h.c.registry.Outcome(out.operation.ID, session), failedOutcome(ipc.CommandAccessDenied))
	state := h.snapshot()
	expect(t, "access", state.Access, ipc.AccessDenied)
	expect(t, "retained", state.HasRetainedSession, false)
}

func TestStaleObservationIsNotEvidence(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeFull})
	h.up(configA)
	h.host.FailWhen(networktest.Match("ip", "-j", "-d", "-N", "address", "show"))

	other := h.run(ipc.Request{Action: ipc.ActionDisconnectClient, Identifier: configB})
	mode := h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeMesh})

	expect(t, "targeted down", *other.outcome, failedOutcome(ipc.CommandVPNFailed))
	expect(t, "mode", *mode.outcome, failedOutcome(ipc.CommandVPNFailed))
	expect(t, "mode kept", deref(mode.reply.State.SelectedMode), any(ipc.ModeFull))
}

func TestDeferredRefreshResumesAfterReservationExpires(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.clock.Advance(61 * time.Second)
	reserved := h.do(ipc.Request{Action: ipc.ActionConnect, Identifier: configA})
	expect(t, "reserved", reserved.Operation.State, ipc.OperationAccepted)
	// Activity finds stale inventory, and the open reservation defers its automatic refresh
	h.do(ipc.Request{Action: ipc.ActionUserActivity})
	h.c.mu.Lock()
	deferred := h.c.deferred
	h.c.mu.Unlock()
	expect(t, "deferred", deferred, true)

	h.clock.Advance(31 * time.Second)
	state := h.settled()

	expect(t, "inventory", state.Inventory, ipc.InventoryCurrent)
	removed := h.run(ipc.Request{Action: ipc.ActionRemoveClient, Identifier: configB})
	expect(t, "remove", removed.outcome.Kind, ipc.OutcomeCompleted)
}

func TestCloudIDsThatCantNameConfigsAreDropped(t *testing.T) {
	h := newHarness(t)
	h.cloud.set(func(f *fakeCloud) {
		f.clients = append(f.clients, clientDoc(userA, "evil\x1b]0;owned\x07", "Evil", 7))
	})

	state := h.signedIn(userA)

	expect(t, "clients", len(state.Clients), 2)
	for _, client := range state.Clients {
		if strings.ContainsRune(client.Identifier, 0x1b) {
			t.Fatalf("client %q reached the CLI", client.Identifier)
		}
	}
}

func TestUnsafeIDsStillGetTheOwnerCheck(t *testing.T) {
	h := newHarness(t)
	// Rules let another owner's client through, under an ID the CLI never shows
	h.cloud.set(func(f *fakeCloud) {
		f.allOwners = true
		f.clients = append(f.clients, clientDoc(userB, "evil\x1b]0;owned\x07", "Evil", 7))
	})

	state := h.signedIn(userA)

	// Authorize refused the foreign owner, so nothing was published
	expect(t, "clients", len(state.Clients), 0)
}

func TestHandshakeCarriesTheUpdateAfterARestart(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.releases.set(identityV1, identityV2, nil)
	id := newID()
	h.do(ipc.Request{Action: ipc.ActionUpdate, ID: id})
	h.do(ipc.Request{Action: ipc.ActionConfirm, ContextID: id})
	h.close(h.c)
	h.releases.set(identityV2, identityV2, nil)
	h.open()

	reply := h.do(ipc.Request{Action: ipc.ActionHandshake})

	if reply.Operation == nil || reply.Operation.ID != id || reply.Operation.State != ipc.OperationCompleted {
		t.Fatalf("operation = %+v", reply.Operation)
	}
}

func TestHandshakeCarriesTheLatestOperation(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	out := h.up(configA)

	reply := h.do(ipc.Request{Action: ipc.ActionHandshake})

	if reply.Operation == nil || reply.Operation.ID != out.operation.ID || reply.Outcome != nil {
		t.Fatalf("operation = %+v, outcome %+v", reply.Operation, reply.Outcome)
	}
}
