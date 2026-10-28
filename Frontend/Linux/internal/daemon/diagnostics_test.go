package daemon

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/cloud"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network/networktest"
)

func (h *harness) probe(name string) string {
	h.t.Helper()
	check := h.do(ipc.Request{Action: ipc.ActionDiagnostics, Probe: name}).Check
	if check == nil || check.Name != name {
		h.t.Fatalf("probe %s = %+v", name, check)
	}
	text := string(check.Status)
	if check.FailureCode != nil {
		text += " " + *check.FailureCode
	}
	return text
}

func TestDoctorProbesReadEvidenceOnly(t *testing.T) {
	h := newHarness(t)
	h.open()
	signedOut := map[string]string{
		"network_tools": "pass", "dns_policy": "pass", "resolver": "pass", "credentials": "warning",
		"access": "warning", "inventory": "pass", "network_path": "pass", "dns": "pass", "https": "pass",
		"server": "pass", "service": "unknown",
	}
	for name, want := range signedOut {
		expect(t, name, h.probe(name), want)
	}
	expect(t, "mutations", len(h.mutations()), 0)
	h.cloud.mu.Lock()
	tokens := len(h.cloud.tokens)
	h.cloud.mu.Unlock()
	expect(t, "cloud reads", tokens, 0)
}

func TestFreshDoctorUsesMeshWithDHCPDomains(t *testing.T) {
	h := newHarness(t)
	h.host.SetLinkDomains("enp0s1", "lan")
	h.open()

	expect(t, "DNS policy", h.probe("dns_policy"), "pass")
	expect(t, "mutations", len(h.mutations()), 0)
}

func TestDoctorExplainsBlockedFullWhileMeshStaysConnected(t *testing.T) {
	h := newHarness(t)
	h.host.SetLinkDomains("enp0s1", "lan")
	h.signedIn(userA)
	h.up(configA)

	full := h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeFull})
	expect(t, "switch failure", full.outcome.Failure, ipc.CommandSetupRequired)
	expect(t, "selected", deref(full.reply.State.SelectedMode), any(ipc.ModeFull))
	expect(t, "active", deref(full.reply.State.ActiveMode), any(ipc.ModeMesh))
	expect(t, "owned", h.owned(), meshOwned)
	h.host.ResetCalls()

	check := h.do(ipc.Request{Action: ipc.ActionDiagnostics, Probe: "dns_policy"}).Check
	if check == nil {
		t.Fatal("missing DNS policy check")
	}
	expect(t, "diagnostic", check.Status, ipc.DoctorWarning)
	expect(t, "failure code", deref(check.FailureCode), any(string(ipc.CommandSetupRequired)))
	for _, text := range []string{"Mesh remains connected", "Selected Full", "DNS search or routing domains"} {
		if !strings.Contains(check.Evidence, text) {
			t.Fatalf("evidence = %q, missing %q", check.Evidence, text)
		}
	}
	expect(t, "diagnostic mutations", len(h.mutations()), 0)

	h.host.SetLinkDomains("enp0s1")
	expect(t, "Full ready", h.probe("dns_policy"), "pass")
	full = h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeFull})
	expect(t, "Full start", full.outcome.Kind, ipc.OutcomeStartRequested)
	expect(t, "Full active", deref(full.reply.State.ActiveMode), any(ipc.ModeFull))
}

func TestDoctorProbeFailures(t *testing.T) {
	tests := []struct {
		name  string
		probe string
		setup func(*harness)
		want  string
	}{
		{name: "missing tool", probe: "network_tools", setup: func(h *harness) { h.host.RemoveTool("wg") }, want: "fail setup_required"},
		{name: "no wireguard", probe: "network_tools", setup: func(h *harness) {
			h.host.RemoveFile("/sys/module/wireguard/version")
		}, want: "fail setup_required"},
		{name: "resolver stopped", probe: "dns_policy", setup: func(h *harness) {
			h.signedIn(userA)
			h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeFull})
			h.host.SetResolverActive(false)
		}, want: "fail setup_required"},
		{name: "resolver stopped in mesh", probe: "dns_policy", setup: func(h *harness) {
			h.host.SetResolverActive(false)
			h.signedIn(userA)
			h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeMesh})
		}, want: "pass"},
		{name: "stub bypassed", probe: "resolver", setup: func(h *harness) {
			h.host.SetFile("/etc/resolv.conf", "nameserver 192.168.64.1\n")
		}, want: "warning"},
		{name: "no upstream", probe: "resolver", setup: func(h *harness) { h.host.SetLinkDNS("enp0s1") }, want: "warning"},
		{name: "no default route", probe: "network_path", setup: func(h *harness) {
			h.host.RemoveRoutes(func(r networktest.Route) bool { return r.Dst.Bits() == 0 })
		}, want: "fail"},
		{name: "denied access", probe: "access", setup: func(h *harness) {
			h.seedSession(userA, 1)
			h.cloud.set(func(f *fakeCloud) { f.accessErr = cloudError(cloud.KindAccessDenied, 403, false) })
		}, want: "fail access_denied"},
		{name: "server silent", probe: "server", setup: func(h *harness) {
			h.signedIn(userA)
			h.up(configA)
			h.setServer(serverIP, true)
		}, want: "warning"},
		{name: "inventory failure", probe: "inventory", setup: func(h *harness) {
			h.signedIn(userA)
			h.cloud.set(func(f *fakeCloud) { f.inventoryErr = cloudError(cloud.KindOffline, 0, false) })
			h.do(ipc.Request{Action: ipc.ActionAwaitRefresh})
		}, want: "warning"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			h := newHarness(t)
			test.setup(h)
			if h.c == nil {
				h.open()
			}
			h.settled()

			expect(t, test.probe, h.probe(test.probe), test.want)
		})
	}
}

func TestInventorySchedule(t *testing.T) {
	s := newSchedule(testStart)
	expect(t, "first due", s.due(testStart), true)
	expect(t, "stale before success", s.stale(testStart), true)
	s.complete(testStart, true, 0.5)
	expect(t, "fresh", s.stale(testStart.Add(59*time.Second)), false)
	expect(t, "stale at 60s", s.stale(testStart.Add(60*time.Second)), true)
	expect(t, "active cadence", s.due(testStart.Add(60*time.Second)), true)
	s.activity(testStart)
	s.complete(testStart.Add(120*time.Second), true, 0.5)
	// Two minutes after the last activity the cadence slows to five minutes
	expect(t, "slow cadence early", s.due(testStart.Add(300*time.Second)), false)
	expect(t, "slow cadence", s.due(testStart.Add(420*time.Second)), true)
	expect(t, "idle", s.due(testStart.Add(900*time.Second)), false)

	s = newSchedule(testStart)
	for range 3 {
		s.complete(testStart, false, 1)
	}
	// 60s doubled twice with full jitter is 288s
	expect(t, "backoff", s.retryAfter.Sub(testStart), 288*time.Second)
	for range 5 {
		s.complete(testStart, false, 1)
	}
	expect(t, "backoff cap", s.retryAfter.Sub(testStart), 900*time.Second)
}

func TestDNSPolicyPassesInMeshAfterResolverFailure(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeFull})
	h.up(configA)
	h.host.SetLinkDomains("enp0s1", "lan")
	h.c.reconcile(context.Background())
	expect(t, "full", h.probe("dns_policy"), "fail vpn_failed")

	h.run(ipc.Request{Action: ipc.ActionSetMode, Mode: ipc.ModeMesh})

	expect(t, "mesh", h.probe("dns_policy"), "pass")
}
