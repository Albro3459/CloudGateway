package daemon

import (
	"context"
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/cloud"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network/networktest"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
)

func TestRestartAdoptsRunningTunnelWithoutChanges(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	h.host.ResetCalls()

	h.restart()
	state := h.settled()

	expect(t, "mutations", strings.Join(h.mutations(), "\n"), "")
	expect(t, "tunnel", state.Tunnel.Phase, ipc.TunnelConnected)
	expect(t, "config", deref(state.Tunnel.ConfigID), any(configA))
	expect(t, "active", deref(state.ActiveMode), any(ipc.ModeFull))
	expect(t, "owned", h.owned(), fullOwned)
	// Adoption keeps the journal, so down still finds every owned resource
	expect(t, "down", h.run(ipc.Request{Action: ipc.ActionTurnOff}).outcome.Kind, ipc.OutcomeCompleted)
	expect(t, "owned after down", h.owned(), "")
}

func TestRebootResumesLastClientAndMode(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeMesh})
	h.up(configA)
	h.close(h.c)
	h.host = networktest.NewUbuntu()
	h.mu.Lock()
	h.lookupFailing = 2
	h.mu.Unlock()

	h.open()
	h.eventually("resume", func() bool {
		return h.snapshot().Tunnel.Phase == ipc.TunnelConnected && h.intent().Phase == store.PhaseRunning
	})

	state := h.settled()
	expect(t, "config", deref(state.Tunnel.ConfigID), any(configA))
	expect(t, "mode", deref(state.ActiveMode), any(ipc.ModeMesh))
	expect(t, "owned", h.owned(), meshOwned)
	// Two lookups failed while the network came up, so resume backed off twice
	expect(t, "backoff", h.clock.Now().Sub(testStart), 15*time.Second)
	expect(t, "intent", h.intent().Phase, store.PhaseRunning)
}

func TestRebootResumesAfterAFailedFirstObservation(t *testing.T) {
	h := newHarness(t)
	h.leaveRunning()
	var reads atomic.Int32
	address := networktest.Match("ip", "-j", "-d", "-N", "address", "show")
	h.host.FailWhen(func(c networktest.Call) bool { return address(c) && reads.Add(1) == 1 })

	h.open()
	h.eventually("resume", func() bool { return h.snapshot().Tunnel.Phase == ipc.TunnelConnected && !h.resuming() })

	expect(t, "owned", h.owned(), fullOwned)
}

func TestResumeReportsConnectingWhileWaitingForAuthorization(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	h.close(h.c)
	h.host = networktest.NewUbuntu()
	h.cloud.set(func(f *fakeCloud) { f.accessErr = cloudError(cloud.KindUnavailable, 500, false) })

	h.open()
	state := h.settled()
	expect(t, "waiting", state.Tunnel.Phase, ipc.TunnelConnecting)
	expect(t, "access", state.Access, ipc.AccessUnreachable)

	h.cloud.set(func(f *fakeCloud) { f.accessErr = nil })
	h.eventually("resume", func() bool { return h.snapshot().Tunnel.Phase == ipc.TunnelConnected })
	expect(t, "owned", h.owned(), fullOwned)
}

func TestDownBeforeRebootStaysOff(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	h.run(ipc.Request{Action: ipc.ActionTurnOff})
	h.close(h.c)
	h.host = networktest.NewUbuntu()

	h.open()
	state := h.settled()

	expect(t, "tunnel", state.Tunnel.Phase, ipc.TunnelDisconnected)
	expect(t, "resume", !h.resuming(), true)
	expect(t, "mutations", len(h.mutations()), 0)
}

func TestDownWhoseFirstSavesFailTurnsOffAndStaysOff(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	// A directory where the intent file belongs fails the stopping and removing
	// saves. The teardown's first change clears it, so the later saves work
	path := filepath.Join(h.dir, "intent.json")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	var once sync.Once
	h.host.After(networktest.Match("resolvectl", "revert"), func() { once.Do(func() { _ = os.Remove(path) }) })

	out := h.run(ipc.Request{Action: ipc.ActionTurnOff})

	expect(t, "down", out.outcome.Kind, ipc.OutcomeCompleted)
	expect(t, "owned", h.owned(), "")
	intent := h.intent()
	expect(t, "intent", string(intent.Phase)+" "+string(intent.Suppression), "stopped down")
	h.close(h.c)
	h.host = networktest.NewUbuntu()
	h.open()
	h.settled()
	expect(t, "resume", !h.resuming(), true)
}

func TestUnreadableIntentRemovesOwnedResources(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	h.close(h.c)
	if err := os.WriteFile(filepath.Join(h.dir, "intent.json"), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}

	h.open()
	state := h.settled()

	expect(t, "tunnel", state.Tunnel.Phase, ipc.TunnelDisconnected)
	expect(t, "owned", h.owned(), "")
	intent := h.intent()
	expect(t, "intent", string(intent.Phase)+" "+string(intent.Suppression), "stopped down")
}

func TestInterruptedStopFinishesAtStartup(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	h.close(h.c)
	st := h.st()
	intent, _ := st.LoadIntent()
	intent.Revision++
	intent.Phase, intent.Suppression = store.PhaseStopping, store.SuppressDown
	if err := st.SaveIntent(intent); err != nil {
		t.Fatal(err)
	}

	h.open()

	expect(t, "owned", h.owned(), "")
	expect(t, "phase", h.intent().Phase, store.PhaseStopped)
}

func TestNetworkdRuleRemovalIsReconciled(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	h.host.RemoveRules(func(r networktest.Rule) bool { return r.Protocol == network.RouteProtocol })
	expect(t, "drifted", h.snapshot().Tunnel.Phase, ipc.TunnelConnecting)

	h.c.reconcile(context.Background())

	expect(t, "tunnel", h.snapshot().Tunnel.Phase, ipc.TunnelConnected)
	expect(t, "owned", h.owned(), fullOwned)
}

func TestResolverPolicyFailureTearsDownAndRequiresPreflight(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	h.host.SetLinkDomains("enp0s1", "lan")

	h.c.reconcile(context.Background())

	state := h.snapshot()
	expect(t, "tunnel", state.Tunnel.Phase, ipc.TunnelDisconnected)
	expect(t, "active", deref(state.ActiveMode), nil)
	expect(t, "selected", deref(state.SelectedMode), any(ipc.ModeFull))
	expect(t, "owned", h.owned(), "")
	intent := h.intent()
	expect(t, "intent", string(intent.Phase)+" "+string(intent.Suppression)+" "+string(intent.FailureCode),
		"failed resolverFailure vpn_failed")
	dns := h.do(ipc.Request{Action: ipc.ActionDiagnostics, Probe: "dns_policy"}).Check
	expect(t, "doctor", string(dns.Status)+" "+*dns.FailureCode, "fail vpn_failed")

	// After a reboot the failure stays down
	h.close(h.c)
	h.host = networktest.NewUbuntu()
	h.host.SetLinkDomains("enp0s1", "lan")
	h.open()
	h.settled()
	expect(t, "no resume", !h.resuming(), true)
	// The next up must pass preflight again
	expect(t, "up", h.up(configA).outcome.Failure, ipc.CommandSetupRequired)
	h.host.SetLinkDomains("enp0s1")
	expect(t, "up after fix", h.up(configA).outcome.Kind, ipc.OutcomeStartRequested)
	dns = h.do(ipc.Request{Action: ipc.ActionDiagnostics, Probe: "dns_policy"}).Check
	expect(t, "doctor after fix", dns.Status, ipc.DoctorPass)
}

func TestRefreshRecoversChangedServerAddress(t *testing.T) {
	for _, mode := range []ipc.Mode{ipc.ModeFull, ipc.ModeMesh} {
		t.Run(string(mode), func(t *testing.T) {
			h := newHarness(t)
			h.signedIn(userA)
			h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: mode})
			h.up(configA)
			human := h.do(ipc.Request{Action: ipc.ActionSnapshot, CheckServer: true}).State
			expect(t, "responding", deref(human.ServerResponding), any(true))
			expect(t, "json status", h.snapshot().ServerResponding == nil, true)
			h.setServer(movedIP, true)
			expect(t, "hint", deref(h.do(ipc.Request{Action: ipc.ActionSnapshot, CheckServer: true}).State.ServerResponding), any(false))
			h.host.ResetCalls()

			reply := h.do(ipc.Request{Action: ipc.ActionAwaitRefresh})

			expect(t, "refresh", reply.Refresh, ipc.RefreshRefreshed)
			link, _ := h.host.Link(network.InterfaceName)
			expect(t, "endpoint", link.WireGuard.Endpoint, netip.AddrPortFrom(movedIP, 51820))
			expect(t, "mutations", strings.Join(h.mutations(), "\n"),
				"wg set cloudgateway peer "+testPublicKey+" endpoint 203.0.113.20:51820")
			expect(t, "tunnel", reply.State.Tunnel.Phase, ipc.TunnelConnected)
		})
	}
}

func TestUpdateNoOpAndRestartOntoInstalledRelease(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)

	noop := h.do(ipc.Request{Action: ipc.ActionUpdate, AllowDisconnect: true})
	expect(t, "no-op", noop.Update.Phase, ipc.UpdateCompleted)
	expect(t, "no-op operation", noop.Operation.State, ipc.OperationCompleted)

	h.releases.set(identityV1, identityV2, nil)
	id := newID()
	prepared := h.do(ipc.Request{Action: ipc.ActionUpdate, ID: id})
	expect(t, "prepared", prepared.Update.Phase, ipc.UpdatePrepared)
	expect(t, "accepted", prepared.Operation.State, ipc.OperationAccepted)
	expect(t, "busy meanwhile", h.do(ipc.Request{Action: ipc.ActionConnect, ID: newID(), Identifier: configB}).Error, ipc.FailureBusy)
	confirmed := h.do(ipc.Request{Action: ipc.ActionConfirm, ContextID: id})
	expect(t, "activating", confirmed.Update.Phase, ipc.UpdateActivating)
	select {
	case <-h.c.Exit():
	default:
		t.Fatal("confirmed update did not ask to exit")
	}
	expect(t, "draining", h.do(ipc.Request{Action: ipc.ActionHandshake}).Lifecycle.State, ipc.LifecycleDraining)

	// systemd restarts the daemon on the installed release, and the tunnel stays up
	h.close(h.c)
	h.releases.set(identityV2, identityV2, nil)
	h.host.ResetCalls()
	h.open()
	reply := h.do(ipc.Request{Action: ipc.ActionOperation, ContextID: id})

	expect(t, "completed", reply.Update.Phase, ipc.UpdateCompleted)
	expect(t, "target", reply.Update.Target, identityV2)
	expect(t, "operation", reply.Operation.State, ipc.OperationCompleted)
	expect(t, "tunnel", reply.State.Tunnel.Phase, ipc.TunnelConnected)
	expect(t, "mutations", len(h.mutations()), 0)
	h.clock.Advance(601 * time.Second)
	expect(t, "expired", h.do(ipc.Request{Action: ipc.ActionOperation, ContextID: id}).Operation.State, ipc.OperationUnknown)
}

func TestUpdateReadinessFailureAndSupersede(t *testing.T) {
	for _, test := range []struct {
		name      string
		installed ipc.BuildIdentity
		phase     ipc.UpdatePhase
		code      string
	}{
		{name: "old binary restarted", installed: identityV2, phase: ipc.UpdateFailed, code: "readiness_failed"},
		{name: "installed changed again", installed: ipc.BuildIdentity{Version: "1.0.2", Build: "1.0.2", CodeHash: strings.Repeat("c", 64)},
			phase: ipc.UpdateSuperseded, code: "update_superseded"},
	} {
		t.Run(test.name, func(t *testing.T) {
			h := newHarness(t)
			h.open()
			h.releases.set(identityV1, identityV2, nil)
			id := newID()
			h.do(ipc.Request{Action: ipc.ActionUpdate, ID: id})
			h.do(ipc.Request{Action: ipc.ActionConfirm, ContextID: id})
			h.close(h.c)
			h.releases.set(identityV1, test.installed, nil)

			h.open()
			reply := h.do(ipc.Request{Action: ipc.ActionOperation, ContextID: id})

			expect(t, "phase", reply.Update.Phase+" "+ipc.UpdatePhase(reply.Update.Error), test.phase+" "+ipc.UpdatePhase(test.code))
		})
	}
}

func TestCleanupRemovesOwnedResourcesByJournal(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	h.close(h.c)
	st := h.st()
	options := network.Options{Executor: h.host, Now: h.clock.Now}

	if err := Cleanup(context.Background(), st, options); err != nil {
		t.Fatal(err)
	}

	expect(t, "owned", h.owned(), "")
	intent := h.intent()
	expect(t, "intent", string(intent.Phase)+" "+string(intent.Suppression), "stopped down")
	expect(t, "journal", len(intent.Journal), 0)
	if err := Cleanup(context.Background(), st, options); err != nil {
		t.Fatalf("rerun: %v", err)
	}
	h.host.FailWhen(networktest.Match("ip", "link", "del"))
	h.host.AddLink(networktest.Link{Name: network.InterfaceName, Kind: "wireguard", Alias: network.InterfaceAlias, MTU: 1420})
	if err := Cleanup(context.Background(), st, options); err == nil {
		t.Fatal("cleanup succeeded with an owned link left")
	}
}

func TestCleanupRemovesResourcesFromNewerUnwritableState(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	h.close(h.c)
	if err := os.WriteFile(filepath.Join(h.dir, "storage.json"), []byte(`{"storageVersion":2}`), 0o600); err != nil {
		t.Fatal(err)
	}
	st, err := store.OpenForCleanup(h.dir)
	if err != nil {
		t.Fatal(err)
	}
	before := h.intent()

	if err := Cleanup(context.Background(), st, network.Options{Executor: h.host, Now: h.clock.Now}); err != nil {
		t.Fatal(err)
	}

	expect(t, "read only", st.ReadOnly(), true)
	expect(t, "owned", h.owned(), "")
	expect(t, "intent untouched", h.intent().Revision, before.Revision)
}

func TestControllerOverServerSocket(t *testing.T) {
	h := newHarness(t)
	h.seedSession(userA, 1)
	h.open()
	ts := startServer(t, h.c, uint32(os.Getuid()), nil)
	conn := dial(t, ts.path)

	handshake, err := call(conn, ipc.Request{Action: ipc.ActionHandshake})
	if err != nil {
		t.Fatal(err)
	}
	expect(t, "lifecycle", handshake.Lifecycle.State, ipc.LifecycleCurrent)
	expect(t, "running", handshake.Lifecycle.Running, identityV1)
	h.settled()
	refreshed, err := call(conn, ipc.Request{Action: ipc.ActionAwaitRefresh})
	if err != nil {
		t.Fatal(err)
	}
	expect(t, "refresh", refreshed.Refresh, ipc.RefreshRefreshed)
	expect(t, "instance", refreshed.InstanceID, ts.InstanceID())
	id := newID()
	reserved, err := call(conn, ipc.Request{Action: ipc.ActionConnect, ID: id, Identifier: configA})
	if err != nil || reserved.Operation.State != ipc.OperationAccepted {
		t.Fatalf("reserve = %+v, %v", reserved, err)
	}
	confirmed, err := call(conn, ipc.Request{Action: ipc.ActionConfirm, ContextID: id})
	if err != nil {
		t.Fatal(err)
	}
	out := h.finish(id, confirmed)
	expect(t, "outcome", out.outcome.Kind, ipc.OutcomeStartRequested)

	h.releases.set(identityV1, identityV1, os.ErrNotExist)
	invalid, _ := call(conn, ipc.Request{Action: ipc.ActionHandshake})
	expect(t, "invalid installation", invalid.Lifecycle.State, ipc.LifecycleInvalidInstallation)
	expect(t, "tunnel", invalid.Lifecycle.Tunnel.Phase, ipc.TunnelConnected)
	expect(t, "coarse", invalid.Lifecycle.Tunnel.ConfigID == nil, true)
}

// leaveRunning saves configA's running intent, then swaps in a fresh host as a reboot would
func (h *harness) leaveRunning() {
	h.t.Helper()
	h.signedIn(userA)
	h.up(configA)
	h.close(h.c)
	h.host = networktest.NewUbuntu()
}

// openWith opens a controller whose host runs hook once, on the first matching call after open
func (h *harness) openWith(match func(networktest.Call) bool, hook func()) {
	h.t.Helper()
	opened := make(chan struct{})
	var once sync.Once
	h.host.After(match, func() {
		once.Do(func() {
			<-opened
			hook()
		})
	})
	h.open()
	close(opened)
}

func (h *harness) waitSuppression(suppression store.Suppression) {
	h.eventually("suppression "+string(suppression), func() bool { return h.c.currentIntent().Suppression == suppression })
}

func TestLogoutDuringResumeApplyRollsTheStartBack(t *testing.T) {
	h := newHarness(t)
	loggedOut := make(chan result, 1)
	h.leaveRunning()
	h.openWith(networktest.Match("ip", "link", "add"), func() {
		go func() { loggedOut <- h.run(ipc.Request{Action: ipc.ActionSignOut}) }()
		h.waitSuppression(store.SuppressLogout)
	})

	out := <-loggedOut

	expect(t, "logout", out.outcome.Kind, ipc.OutcomeCompleted)
	expect(t, "owned", h.owned(), "")
	intent := h.intent()
	expect(t, "intent", string(intent.Phase)+" "+string(intent.Suppression), "stopped logout")
	expect(t, "tunnel", h.snapshot().Tunnel.Phase, ipc.TunnelDisconnected)
}

func TestDownDuringResumePreflightWins(t *testing.T) {
	h := newHarness(t)
	downed := make(chan result, 1)
	// Only preflight reads resolved's unit state, before the starting intent
	h.leaveRunning()
	h.openWith(networktest.Match("busctl", "ActiveState"), func() {
		go func() { downed <- h.run(ipc.Request{Action: ipc.ActionTurnOff}) }()
		h.waitSuppression(store.SuppressDown)
	})

	out := <-downed

	expect(t, "down", out.outcome.Kind, ipc.OutcomeCompleted)
	for _, call := range h.host.Calls() {
		if call.Has("link", "add") {
			t.Fatalf("a superseded resume changed the kernel: %s", call)
		}
	}
	intent := h.intent()
	expect(t, "intent", string(intent.Phase)+" "+string(intent.Suppression), "stopped down")
}

func TestDownRaceThenRebootStaysOff(t *testing.T) {
	h := newHarness(t)
	downed := make(chan result, 1)
	h.leaveRunning()
	h.openWith(networktest.Match("busctl", "ActiveState"), func() {
		go func() { downed <- h.run(ipc.Request{Action: ipc.ActionTurnOff}) }()
		h.waitSuppression(store.SuppressDown)
		h.host.FailWhen(networktest.Match("ip", "link", "del"))
	})
	<-downed
	h.close(h.c)
	h.host = networktest.NewUbuntu()

	h.open()
	state := h.settled()

	expect(t, "tunnel", state.Tunnel.Phase, ipc.TunnelDisconnected)
	expect(t, "resume", !h.resuming(), true)
	expect(t, "owned", h.owned(), "")
}

func TestResumeAbandonedWhileWaitingForAuthorization(t *testing.T) {
	for _, action := range []ipc.Action{ipc.ActionTurnOff, ipc.ActionSignOut} {
		t.Run(string(action), func(t *testing.T) {
			h := newHarness(t)
			h.leaveRunning()
			gate := make(chan struct{})
			h.cloud.set(func(f *fakeCloud) { f.accessGate = gate })
			h.open()
			h.eventually("resume waiting", func() bool {
				state := h.snapshot()
				return state.Tunnel.Phase == ipc.TunnelConnecting && state.IsRestoring
			})

			out := h.run(ipc.Request{Action: action})
			if out.outcome == nil {
				t.Fatalf("%s = %+v", action, out.operation)
			}
			expect(t, string(action), out.outcome.Kind, ipc.OutcomeCompleted)
			close(gate)
			h.do(ipc.Request{Action: ipc.ActionAwaitRefresh})
			h.settled()

			expect(t, "resume", !h.resuming(), true)
			expect(t, "tunnel", h.snapshot().Tunnel.Phase, ipc.TunnelDisconnected)
			expect(t, "owned", h.owned(), "")
		})
	}
}

func TestUserUpSupersedesWaitingResume(t *testing.T) {
	h := newHarness(t)
	h.leaveRunning()
	gate := make(chan struct{})
	h.cloud.set(func(f *fakeCloud) { f.inventoryGate = gate })
	h.open()
	h.eventually("restored account", func() bool { return h.snapshot().AccountID != nil })
	expect(t, "waiting", h.snapshot().Tunnel.Phase, ipc.TunnelConnecting)

	out := h.up(configA)
	close(gate)

	expect(t, "up", *out.outcome, ipc.Outcome{Kind: ipc.OutcomeStartRequested, Identifier: configA})
	// The user's starting intent superseded the resume
	h.eventually("resume abandoned", func() bool { return !h.resuming() })
	adds := 0
	for _, call := range h.host.Calls() {
		if call.Has("link", "add") {
			adds++
		}
	}
	expect(t, "starts", adds, 1)
}

func TestReadFailureBeforeAnyChangeKeepsWorkingTunnel(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	var failing atomic.Bool
	var count atomic.Int32
	address := networktest.Match("ip", "-j", "-d", "-N", "address", "show")
	// The observation and preflight reads pass, and the read inside Apply fails
	h.host.FailWhen(func(c networktest.Call) bool { return failing.Load() && address(c) && count.Add(1) >= 3 })
	h.c.mu.Lock()
	epoch := h.c.epoch
	h.c.mu.Unlock()
	plan, err := h.c.prepareStart(context.Background(), configB, userA, epoch, ipc.ModeFull)
	if err != nil {
		t.Fatal(err)
	}
	failing.Store(true)

	_, err = h.c.startTunnel(context.Background(), plan, 0)
	failing.Store(false)

	var applyErr *network.ApplyError
	if err == nil || errors.As(err, &applyErr) {
		t.Fatalf("err = %v, want a failure before any change", err)
	}
	intent := h.intent()
	expect(t, "intent", string(intent.Phase)+" "+intent.ProfileID, "running "+configA)
	h.restart()
	expect(t, "owned after restart", h.owned(), fullOwned)
}

func TestUnparseableJournalRemovesOwnedResources(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	h.close(h.c)
	st := h.st()
	intent, _ := st.LoadIntent()
	intent.Revision++
	intent.Journal = []byte(`{"version":999}`)
	if err := st.SaveIntent(intent); err != nil {
		t.Fatal(err)
	}

	h.open()
	state := h.settled()

	expect(t, "tunnel", state.Tunnel.Phase, ipc.TunnelDisconnected)
	expect(t, "owned", h.owned(), "")
	after := h.intent()
	expect(t, "intent", string(after.Phase)+" "+string(after.Suppression), "stopped down")
}

func TestUpdatePreparedExpiresAfter30Seconds(t *testing.T) {
	h := newHarness(t)
	h.open()
	h.releases.set(identityV1, identityV2, nil)
	id := newID()
	expect(t, "prepared", h.do(ipc.Request{Action: ipc.ActionUpdate, ID: id}).Update.Phase, ipc.UpdatePrepared)

	h.clock.Advance(31 * time.Second)
	reply := h.do(ipc.Request{Action: ipc.ActionOperation, ContextID: id})

	expect(t, "phase", reply.Update.Phase+" "+ipc.UpdatePhase(reply.Update.Error), ipc.UpdatePhase("failed operation_expired"))
	expect(t, "operation", reply.Operation.State, ipc.OperationFailed)
	confirmed := h.do(ipc.Request{Action: ipc.ActionConfirm, ContextID: id})
	expect(t, "late confirm", confirmed.Update.Phase, ipc.UpdateFailed)
	select {
	case <-h.c.Exit():
		t.Fatal("an expired update restarted the daemon")
	default:
	}
}

func TestDrainRefusesNewWork(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)

	h.c.Drain()

	expect(t, "up", h.do(ipc.Request{Action: ipc.ActionConnect, Identifier: configA}).Error, ipc.FailureBusy)
	expect(t, "down", h.do(ipc.Request{Action: ipc.ActionTurnOff}).Error, ipc.FailureBusy)
	expect(t, "login", h.do(ipc.Request{Action: ipc.ActionBeginLogin}).Login.Result, ipc.LoginAuthorized)
	expect(t, "refresh", h.do(ipc.Request{Action: ipc.ActionAwaitRefresh}).Refresh, ipc.RefreshSkipped)
	expect(t, "snapshot", deref(h.snapshot().AccountID), any(userA))
}

// leaveResumeRetrying reboots with a resume stuck retrying its endpoint lookup while authorized
func (h *harness) leaveResumeRetrying() {
	h.t.Helper()
	h.leaveRunning()
	h.mu.Lock()
	h.lookupFailing = 1 << 30
	h.mu.Unlock()
	h.clock.holdSleeps()
	h.open()
	h.eventually("resume retrying", func() bool { return h.clock.sleepers() == 1 })
	state := h.settled()
	expect(h.t, "retrying", state.Tunnel.Phase, ipc.TunnelConnecting)
	expect(h.t, "authorized", deref(state.AccountID), any(userA))
}

// recoverNetwork lets the retrying resume look the endpoint up again
func (h *harness) recoverNetwork() {
	h.t.Helper()
	h.mu.Lock()
	h.lookupFailing = 0
	h.mu.Unlock()
	h.clock.releaseSleeps()
	h.eventually("resume", func() bool { return h.snapshot().Tunnel.Phase == ipc.TunnelConnected && !h.resuming() })
}

func TestModeChangeDuringResumeIsBusy(t *testing.T) {
	h := newHarness(t)
	h.leaveResumeRetrying()

	mode := h.do(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeMesh})

	expect(t, "mode", mode.Error, ipc.FailureBusy)
	h.recoverNetwork()
	expect(t, "owned", h.owned(), fullOwned)
}

func TestFailedUpDuringResumeKeepsReconnect(t *testing.T) {
	h := newHarness(t)
	h.leaveResumeRetrying()
	conflict := netip.MustParsePrefix("10.0.0.50/24")
	h.host.AddAddress("enp0s1", conflict, "global")

	out := h.up(configB)

	expect(t, "up", *out.outcome, failedOutcome(ipc.CommandVPNFailed))
	expect(t, "resume kept", h.resuming(), true)
	h.host.RemoveAddress("enp0s1", conflict)
	h.recoverNetwork()
	expect(t, "config", deref(h.snapshot().Tunnel.ConfigID), any(configA))
}

func TestUpFailingAfterItsStartingIntentKeepsReconnect(t *testing.T) {
	h := newHarness(t)
	h.leaveResumeRetrying()

	// Preflight passes and the starting intent is saved, then the endpoint lookup fails
	out := h.up(configB)

	expect(t, "up", *out.outcome, failedOutcome(ipc.CommandNetworkUnavailable))
	expect(t, "resume kept", h.resuming(), true)
	h.recoverNetwork()
	expect(t, "config", deref(h.snapshot().Tunnel.ConfigID), any(configA))
}

func TestFailedLogoutKeepsResume(t *testing.T) {
	h := newHarness(t)
	h.leaveResumeRetrying()
	// A directory where the session record belongs makes the logout's first write fail
	session := filepath.Join(h.dir, "session.json")
	if err := os.Remove(session); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(session, 0o700); err != nil {
		t.Fatal(err)
	}

	out := h.run(ipc.Request{Action: ipc.ActionSignOut})

	expect(t, "logout", out.operation.Failure, ipc.FailureAuthCleanupFailed)
	expect(t, "resume kept", h.resuming(), true)
	h.recoverNetwork()
}

func TestDrainCancelsPreparation(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	gate := make(chan struct{})
	defer close(gate)
	h.cloud.set(func(f *fakeCloud) { f.regionsGate = gate })
	prepared := make(chan ipc.Reply, 1)
	go func() {
		prepared <- h.c.Handle(context.Background(), Peer{}, ipc.Request{Version: ipc.Version, ID: newID(), Action: ipc.ActionPrepareClient})
	}()
	h.eventually("preparing", func() bool {
		h.c.mu.Lock()
		defer h.c.mu.Unlock()
		return h.c.preparing
	})

	h.c.Drain()

	expect(t, "prepare", (<-prepared).Error, ipc.FailurePreparationExpired)
}

func TestDrainRefusesUpdateConfirm(t *testing.T) {
	h := newHarness(t)
	h.open()
	h.releases.set(identityV1, identityV2, nil)
	id := newID()
	expect(t, "prepared", h.do(ipc.Request{Action: ipc.ActionUpdate, ID: id}).Update.Phase, ipc.UpdatePrepared)

	h.c.Drain()
	confirmed := h.do(ipc.Request{Action: ipc.ActionConfirm, ContextID: id})

	expect(t, "update", confirmed.Update.Phase+" "+ipc.UpdatePhase(confirmed.Update.Error), ipc.UpdatePhase("failed busy"))
	select {
	case <-h.c.Exit():
		t.Fatal("a draining daemon started an update restart")
	default:
	}
}

// leaveRunningUnsaved models a start whose apply succeeded but whose running
// save failed, so memory says running while saves fail. The returned func
// lets saves work again by removing the intent file
func (h *harness) leaveRunningUnsaved() func() {
	h.t.Helper()
	h.signedIn(userA)
	h.up(configA)
	if _, err := h.c.writeIntent(func(i *store.Intent) { i.Phase = store.PhaseStarting }, false); err != nil {
		h.t.Fatal(err)
	}
	// A directory where the intent file belongs makes every save fail
	path := filepath.Join(h.dir, "intent.json")
	if err := os.Remove(path); err != nil {
		h.t.Fatal(err)
	}
	if err := os.Mkdir(path, 0o700); err != nil {
		h.t.Fatal(err)
	}
	if err := h.c.setRunning(0); err == nil {
		h.t.Fatal("running save succeeded")
	}
	expect(h.t, "memory", h.c.currentIntent().Phase, store.PhaseRunning)
	return func() {
		if err := os.Remove(path); err != nil {
			h.t.Fatal(err)
		}
	}
}

func TestUnsavedRunningIntentKeepsTunnelThroughLogout(t *testing.T) {
	h := newHarness(t)
	h.leaveRunningUnsaved()()

	out := h.run(ipc.Request{Action: ipc.ActionSignOut})

	expect(t, "logout", out.outcome.Kind, ipc.OutcomeCompleted)
	expect(t, "owned", h.owned(), fullOwned)
	intent := h.intent()
	expect(t, "intent", string(intent.Phase)+" "+string(intent.Suppression), "running logout")
}

func TestReconcileSavesUnsavedRunningIntent(t *testing.T) {
	h := newHarness(t)
	h.leaveRunningUnsaved()()

	h.c.reconcile(context.Background())

	expect(t, "intent", h.intent().Phase, store.PhaseRunning)
	h.host.SetLinkDomains("enp0s1", "lan")
	h.c.reconcile(context.Background())
	// Running is established, so a lost DNS policy fails the tunnel
	expect(t, "owned", h.owned(), "")
	expect(t, "failure", h.intent().FailureCode, ipc.CommandVPNFailed)
}

func TestDownWaitingOnResolverFailureEndsAsDown(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	h.host.SetLinkDomains("enp0s1", "lan")
	downed := make(chan result, 1)

	// Hold netMu like a running reconcile while down persists its intent
	h.c.netMu.Lock()
	go func() { downed <- h.run(ipc.Request{Action: ipc.ActionTurnOff}) }()
	h.waitSuppression(store.SuppressDown)
	h.c.failResolverPolicy(context.Background())
	h.c.netMu.Unlock()
	out := <-downed

	expect(t, "down", out.outcome.Kind, ipc.OutcomeCompleted)
	expect(t, "owned", h.owned(), "")
	intent := h.intent()
	expect(t, "intent", string(intent.Phase)+" "+string(intent.Suppression)+" "+string(intent.FailureCode), "stopped down ")
	h.host.SetLinkDomains("enp0s1")
	dns := h.do(ipc.Request{Action: ipc.ActionDiagnostics, Probe: "dns_policy"}).Check
	expect(t, "doctor", dns.Status, ipc.DoctorPass)
}

func TestResumeRetriesHostSetupDuringBoot(t *testing.T) {
	h := newHarness(t)
	h.leaveRunning()
	// resolved comes up after the daemon, so the first two preflights fail
	h.host.SetResolverActive(false)
	checks := 0
	h.host.After(networktest.Match("busctl", "ActiveState"), func() {
		if checks++; checks == 2 {
			h.host.SetResolverActive(true)
		}
	})

	h.open()
	h.eventually("resume", func() bool { return h.snapshot().Tunnel.Phase == ipc.TunnelConnected && !h.resuming() })

	expect(t, "owned", h.owned(), fullOwned)
	expect(t, "backoff", h.clock.Now().Sub(testStart), 15*time.Second)
}

func TestResumeStopsAfterSetupWindow(t *testing.T) {
	h := newHarness(t)
	h.leaveRunning()
	h.host.SetResolverActive(false)

	h.open()
	h.eventually("resume stopped", func() bool { return !h.resuming() })

	expect(t, "owned", h.owned(), "")
	expect(t, "gave up after the window", h.clock.Now().Sub(testStart) >= resumeSetupWindow, true)
}

func TestModeChangeReplacesDriftedTunnel(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	// networkd removed a rule that cannot be added back
	h.host.RemoveRules(func(r networktest.Rule) bool { return r.Priority == network.PrioritySuppress })
	h.host.FailWhen(networktest.Match("ip", "rule", "add"))
	h.c.reconcile(context.Background())
	expect(t, "drifted", h.snapshot().Tunnel.Phase, ipc.TunnelConnecting)

	out := h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeMesh})

	expect(t, "mode", out.outcome.Kind, ipc.OutcomeStartRequested)
	h.eventually("mesh", func() bool { return h.owned() == meshOwned })
}

func TestResumeStopsOnKernelFailure(t *testing.T) {
	h := newHarness(t)
	h.leaveRunning()
	h.host.FailWhen(networktest.Match("ip", "link", "add"))

	h.open()
	h.eventually("resume stopped", func() bool { return !h.resuming() })

	expect(t, "owned", h.owned(), "")
	expect(t, "no retry", h.clock.Now(), testStart)
	expect(t, "tried", slices.ContainsFunc(h.host.Calls(), func(c networktest.Call) bool { return c.Has("link", "add") }), true)
}

func TestResumeRetriesRouteLookupBeforeDHCP(t *testing.T) {
	h := newHarness(t)
	h.leaveRunning()
	// No route to the endpoint yet, so the MTU lookup fails before anything changes
	lookups := 0
	h.host.FailWhen(func(c networktest.Call) bool {
		if c.Has("route", "get") {
			lookups++
			return lookups <= 2
		}
		return false
	})

	h.open()
	h.eventually("resume", func() bool { return h.snapshot().Tunnel.Phase == ipc.TunnelConnected && !h.resuming() })

	expect(t, "owned", h.owned(), fullOwned)
	expect(t, "backoff", h.clock.Now().Sub(testStart), 15*time.Second)
}

func TestDownOverwritesResolverFailureThatLandedFirst(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	downed := make(chan result, 1)

	h.c.netMu.Lock()
	go func() { downed <- h.run(ipc.Request{Action: ipc.ActionTurnOff}) }()
	h.waitSuppression(store.SuppressDown)
	// A resolver failure that checked the intent just before the down's write
	if _, err := h.c.writeIntent(func(i *store.Intent) {
		i.Phase, i.Suppression, i.FailureCode = store.PhaseStopping, store.SuppressResolverFailure, ipc.CommandVPNFailed
	}, true); err != nil {
		t.Fatal(err)
	}
	h.c.netMu.Unlock()
	out := <-downed

	expect(t, "down", out.outcome.Kind, ipc.OutcomeCompleted)
	intent := h.intent()
	expect(t, "intent", string(intent.Phase)+" "+string(intent.Suppression)+" "+string(intent.FailureCode), "stopped down ")
}

func TestUnsavedRunningIntentIsNotSavedAfterTheTunnelIsGone(t *testing.T) {
	h := newHarness(t)
	h.leaveRunningUnsaved()()
	// Someone deleted the interface behind the daemon
	h.host.RemoveLink(network.InterfaceName)

	h.c.reconcile(context.Background())

	if _, err := h.st().LoadIntent(); !errors.Is(err, store.ErrMissing) {
		t.Fatalf("intent saved: %v", err)
	}
}

func TestReplacedTunnelReleasesItsRevokedSecret(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	running := h.intent().SecretReference
	// The server rotates client A's config, so a refresh revokes the running record
	h.cloud.set(func(f *fakeCloud) {
		for i := range f.clients {
			if f.clients[i].ClientID == clientA {
				f.clients[i].WireGuardConfig = cloud.Secret(strings.Replace(string(f.clients[i].WireGuardConfig), "PersistentKeepalive = 25", "PersistentKeepalive = 26", 1))
			}
		}
	})
	expect(t, "refresh", h.do(ipc.Request{Action: ipc.ActionAwaitRefresh}).Refresh, ipc.RefreshRefreshed)
	if _, err := h.st().GetSecret(running); err != nil {
		t.Fatalf("running record deleted: %v", err)
	}

	expect(t, "up", h.up(configA).outcome.Kind, ipc.OutcomeStartRequested)

	expect(t, "new record", h.intent().SecretReference != running, true)
	if _, err := h.st().GetSecret(running); err == nil {
		t.Fatal("replaced record kept")
	}
}
