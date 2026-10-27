package network

import (
	"errors"
	"net/netip"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network/networktest"
)

func TestObservationMapping(t *testing.T) {
	failReads := networktest.Match("ip", "-j", "-d", "-N", "address", "show")
	tests := []struct {
		name      string
		setup     func(*harness)
		state     State
		freshness Freshness
		mode      Mode
	}{
		{name: "nothing installed", state: StateDisconnected, freshness: FreshnessCurrent},
		{name: "never observed", setup: func(h *harness) { h.host.FailWhen(failReads) }, state: StateUnknown, freshness: FreshnessUnavailable},
		{name: "connected", setup: func(h *harness) { h.apply(testProfile(ModeMesh, 5)) }, state: StateConnected, freshness: FreshnessCurrent, mode: ModeMesh},
		{name: "read fails after connected", setup: func(h *harness) {
			h.apply(testProfile(ModeFull, 5))
			h.host.FailWhen(failReads)
		}, state: StateConnected, freshness: FreshnessStale},
		{name: "owned resources without journal", setup: func(h *harness) {
			h.apply(testProfile(ModeMesh, 5))
			h.restart(nil)
		}, state: StateUnknown, freshness: FreshnessCurrent},
		{name: "journal never finished applying", setup: func(h *harness) {
			h.apply(testProfile(ModeMesh, 5))
			applying := *h.lastJournal()
			applying.Phase = PhaseApplying
			h.restart(&applying)
		}, state: StateUnknown, freshness: FreshnessCurrent},
		{name: "address removed outside the daemon", setup: func(h *harness) {
			h.apply(testProfile(ModeFull, 5))
			h.host.RemoveAddress(InterfaceName, netip.MustParsePrefix("10.0.0.5/32"))
		}, state: StateConnecting, freshness: FreshnessCurrent},
		{name: "link-local address on the tunnel", setup: func(h *harness) {
			h.apply(testProfile(ModeFull, 5))
			h.host.AddAddress(InterfaceName, netip.MustParsePrefix("fe80::1/64"), "link")
		}, state: StateConnected, freshness: FreshnessCurrent, mode: ModeFull},
		{name: "address added outside the daemon", setup: func(h *harness) {
			h.apply(testProfile(ModeFull, 5))
			h.host.AddAddress(InterfaceName, netip.MustParsePrefix("10.9.9.9/32"), "global")
		}, state: StateUnknown, freshness: FreshnessCurrent},
		{name: "resolved stopped answering", setup: func(h *harness) {
			h.apply(testProfile(ModeFull, 5))
			h.host.SetResolverActive(false)
		}, state: StateConnecting, freshness: FreshnessCurrent},
		{name: "link deleted outside the daemon", setup: func(h *harness) {
			h.apply(testProfile(ModeFull, 5))
			h.host.RemoveLink(InterfaceName)
		}, state: StateUnknown, freshness: FreshnessCurrent},
		{name: "networkd removed a rule", setup: func(h *harness) {
			h.apply(testProfile(ModeFull, 5))
			h.host.RemoveRules(func(r networktest.Rule) bool { return r.Priority == PriorityTunnel })
		}, state: StateConnecting, freshness: FreshnessCurrent},
		{name: "resolved dropped the VPN link", setup: func(h *harness) {
			h.apply(testProfile(ModeFull, 5))
			h.host.RevertLink(InterfaceName)
		}, state: StateConnecting, freshness: FreshnessCurrent},
		{name: "everything gone after reboot", setup: func(h *harness) {
			h.apply(testProfile(ModeFull, 5))
			journal := h.lastJournal()
			h.host = networktest.NewUbuntu()
			h.restart(journal)
		}, state: StateDisconnected, freshness: FreshnessCurrent},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			h := newHarness(t, networktest.NewUbuntu())
			if test.setup != nil {
				test.setup(h)
			}
			obs, _ := h.m.Observe(ctx)
			expect(t, "state", obs.State, test.state)
			expect(t, "freshness", obs.Freshness, test.freshness)
			expect(t, "mode", obs.ActiveMode, test.mode)
		})
	}
}

func TestReconcileRestoresRulesRemovedByNetworkd(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))
	removed := host.RemoveRules(isOwnedRule)
	expect(t, "removed", removed, 8)

	obs, _ := h.m.Observe(ctx)
	expect(t, "before reconcile", obs.State, StateConnecting)
	expect(t, "drift", strings.Join(obs.Drift, "; "), "missing rule 30200 from 192.168.64.5; missing rule 30200 from 2001:db8:1::5; missing rule 30205 ipv4; missing rule 30205 ipv6; missing rule 30210 ipv4; missing rule 30210 ipv6; missing rule 30220 ipv4; missing rule 30220 ipv6")
	obs, err := h.m.Reconcile(ctx)

	if err != nil {
		t.Fatal(err)
	}
	expect(t, "state", obs.State, StateConnected)
	expectText(t, "owned state", ownedState(host), fullOwnedState)
}

func TestReconcileFollowsDHCPAddressChange(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))
	host.RemoveAddress("enp0s1", netip.MustParsePrefix("192.168.64.5/24"))
	host.AddAddress("enp0s1", netip.MustParsePrefix("192.168.64.77/24"), "global")

	obs, _ := h.m.Observe(ctx)
	expect(t, "before reconcile", obs.State, StateConnecting)
	host.ResetCalls()
	obs, err := h.m.Reconcile(ctx)

	if err != nil {
		t.Fatal(err)
	}
	expect(t, "state", obs.State, StateConnected)
	expectText(t, "commands", strings.Join(mutations(host.Calls()), "\n"), `ip -4 rule add priority 30200 from 192.168.64.77 lookup main protocol 206
ip -4 rule del priority 30200 from 192.168.64.5 protocol 206`)
	expect(t, "old rule gone", strings.Contains(ownedState(host), "192.168.64.5/32"), false)
}

func TestReconcileRecreatesFlushedStateInMesh(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeMesh, 5))
	want := ownedState(host)
	host.FlushNftRuleset()
	host.RemoveRoutes(isOwnedRoute)

	obs, err := h.m.Reconcile(ctx)

	if err != nil {
		t.Fatal(err)
	}
	expect(t, "state", obs.State, StateConnected)
	expectText(t, "owned state", ownedState(host), want)
}

func TestReconcileWithoutDriftChangesNothing(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))
	host.ResetCalls()

	obs, err := h.m.Reconcile(ctx)

	if err != nil {
		t.Fatal(err)
	}
	expect(t, "state", obs.State, StateConnected)
	expect(t, "mutations", len(mutations(host.Calls())), 0)
}

func TestResolverRepairThenPolicyFailure(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))

	host.RevertLink(InterfaceName)
	obs, err := h.m.Reconcile(ctx)
	if err != nil {
		t.Fatal(err)
	}
	expect(t, "repaired", obs.State, StateConnected)
	expectText(t, "owned state", ownedState(host), fullOwnedState)

	// A competing manager clears the link again right after each reapply
	host.After(networktest.Match("resolvectl", "default-route"), func() { host.RevertLink(InterfaceName) })
	host.RevertLink(InterfaceName)
	host.ResetCalls()
	obs, err = h.m.Reconcile(ctx)
	if !errors.Is(err, ErrResolverPolicy) {
		t.Fatalf("err = %v", err)
	}
	expect(t, "state", obs.State, StateConnecting)
	expect(t, "reapplies", len(slices.DeleteFunc(host.Calls(), func(c networktest.Call) bool { return !c.Has("default-route") })), 1)
}

func TestResolverConflictOnAnotherLinkFailsWithoutReapply(t *testing.T) {
	for _, domains := range [][]string{{"~."}, {"lan"}} {
		host := networktest.NewUbuntu()
		h := newHarness(t, host)
		h.apply(testProfile(ModeFull, 5))
		host.SetLinkDomains("enp0s1", domains...)
		host.ResetCalls()

		_, err := h.m.Reconcile(ctx)

		if !errors.Is(err, ErrResolverPolicy) {
			t.Fatalf("err = %v", err)
		}
		expect(t, "mutations", len(mutations(host.Calls())), 0)
		if _, err := h.m.Down(ctx); err != nil {
			t.Fatal(err)
		}
		dns, gotDomains, _ := host.Resolver("enp0s1")
		expect(t, "other link DNS kept", slices.Equal(dns, []netip.Addr{netip.MustParseAddr("192.168.64.1")}), true)
		expect(t, "other link domains kept", slices.Equal(gotDomains, domains), true)
	}
}

func TestUpdateEndpointInPlace(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))
	h.lookups = nil
	host.ResetCalls()
	h.server = netip.MustParseAddr("203.0.113.20")

	endpoint, changed, err := h.m.UpdateEndpoint(ctx)

	if err != nil {
		t.Fatal(err)
	}
	expect(t, "changed", changed, true)
	expect(t, "endpoint", endpoint, netip.MustParseAddrPort("203.0.113.20:51820"))
	expectText(t, "commands", strings.Join(mutations(host.Calls()), "\n"),
		"wg set cloudgateway peer xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg= endpoint 203.0.113.20:51820")
	expect(t, "host lookups", len(h.lookups), 0)
	expect(t, "exchange", h.exchanges[len(h.exchanges)-1], exchangeCall{server: netip.MustParseAddrPort("192.168.64.1:53"), mark: FwMark})
	expect(t, "journal endpoint", h.lastJournal().Endpoint, endpoint)
	l, _ := host.Link(InterfaceName)
	expect(t, "kernel endpoint", l.WireGuard.Endpoint, endpoint)
	obs, _ := h.m.Observe(ctx)
	expect(t, "state", obs.State, StateConnected)

	host.ResetCalls()
	_, changed, err = h.m.UpdateEndpoint(ctx)
	if err != nil || changed {
		t.Fatalf("second update changed=%t err=%v", changed, err)
	}
	expect(t, "mutations", len(mutations(host.Calls())), 0)
}

func TestUpdateEndpointInMeshUsesHostDNS(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeMesh, 5))
	h.server = netip.MustParseAddr("203.0.113.20")

	endpoint, changed, err := h.m.UpdateEndpoint(ctx)

	if err != nil || !changed {
		t.Fatalf("changed=%t err=%v", changed, err)
	}
	expect(t, "endpoint", endpoint, netip.MustParseAddrPort("203.0.113.20:51820"))
	expect(t, "host lookups", len(h.lookups), 2)
	expect(t, "exchanges", len(h.exchanges), 0)
}

func TestUpdateEndpointFallsBackToGlobalDNS(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))
	host.SetLinkDNS("enp0s1")
	host.SetGlobalDNS(netip.MustParseAddr("192.0.2.53"))
	h.server = netip.MustParseAddr("203.0.113.20")

	if _, _, err := h.m.UpdateEndpoint(ctx); err != nil {
		t.Fatal(err)
	}
	expect(t, "server", h.exchanges[len(h.exchanges)-1].server, netip.MustParseAddrPort("192.0.2.53:53"))
}

func TestUpdateEndpointRequiresAppliedTunnel(t *testing.T) {
	h := newHarness(t, networktest.NewUbuntu())
	if _, _, err := h.m.UpdateEndpoint(ctx); !errors.Is(err, ErrNotApplied) {
		t.Fatalf("err = %v", err)
	}
}

func TestServerResponding(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	if _, err := h.m.ServerResponding(ctx); !errors.Is(err, ErrNotApplied) {
		t.Fatalf("err = %v", err)
	}
	h.apply(testProfile(ModeMesh, 5))

	host.SetHandshake(InterfaceName, h.now.Add(-30*time.Second))
	responding, err := h.m.ServerResponding(ctx)
	if err != nil {
		t.Fatal(err)
	}
	expect(t, "recent handshake", responding, true)
	expect(t, "probes", len(h.exchanges), 0)

	host.SetHandshake(InterfaceName, h.now.Add(-90*time.Second))
	responding, err = h.m.ServerResponding(ctx)
	if err != nil {
		t.Fatal(err)
	}
	expect(t, "old handshake with reply", responding, true)
	expect(t, "probe", h.exchanges[0], exchangeCall{server: netip.MustParseAddrPort("10.0.0.1:53")})

	h.exchangeOK = false
	responding, err = h.m.ServerResponding(ctx)
	if err != nil {
		t.Fatal(err)
	}
	expect(t, "no reply", responding, false)
}

func TestPreflightConflicts(t *testing.T) {
	tests := []struct {
		name     string
		mode     Mode
		setup    func(*networktest.Host)
		kind     ConflictKind
		names    []string
		prefixes []string
	}{
		{name: "VPC address overlaps mesh", mode: ModeMesh, setup: func(host *networktest.Host) {
			host.AddAddress("enp0s1", netip.MustParsePrefix("10.0.0.23/24"), "global")
		}, kind: ConflictOverlap, prefixes: []string{"10.0.0.0/24"}},
		{name: "VPC route captures regional DNS", mode: ModeFull, setup: func(host *networktest.Host) {
			host.AddRoute(networktest.Route{Dst: netip.MustParsePrefix("10.0.0.0/30"), Table: 254, Dev: "enp0s1", Gateway: netip.MustParseAddr("192.168.64.1"), Protocol: 4})
		}, kind: ConflictOverlap, prefixes: []string{"10.0.0.0/30"}},
		{name: "broad route captures mesh in Full", mode: ModeFull, setup: func(host *networktest.Host) {
			host.AddRoute(networktest.Route{Dst: netip.MustParsePrefix("10.0.0.0/8"), Table: 254, Dev: "enp0s1", Gateway: netip.MustParseAddr("192.168.64.1"), Protocol: 4})
		}, kind: ConflictOverlap, prefixes: []string{"10.0.0.0/8"}},
		{name: "foreign rule at owned priority", mode: ModeFull, setup: func(host *networktest.Host) {
			host.AddRule(networktest.Rule{Family: 4, Priority: PrioritySuppress, Table: 100})
		}, kind: ConflictForeignRule, names: []string{"30210"}},
		{name: "foreign rule looks up owned table", mode: ModeFull, setup: func(host *networktest.Host) {
			host.AddRule(networktest.Rule{Family: 6, Priority: 1000, Table: RouteTable})
		}, kind: ConflictForeignRule, names: []string{"1000"}},
		{name: "foreign route in owned table", mode: ModeFull, setup: func(host *networktest.Host) {
			host.AddRoute(networktest.Route{Dst: netip.MustParsePrefix("0.0.0.0/0"), Table: RouteTable, Dev: "enp0s1", Protocol: 4})
		}, kind: ConflictForeignRoute, prefixes: []string{"0.0.0.0/0"}},
		{name: "foreign interface uses fwmark", mode: ModeFull, setup: func(host *networktest.Host) {
			host.AddLink(networktest.Link{Name: "wg0", Kind: "wireguard", MTU: 1420, Up: true, WireGuard: &networktest.WireGuard{FwMark: FwMark}})
		}, kind: ConflictForeignMark, names: []string{"interface wg0"}},
		{name: "foreign rule uses fwmark", mode: ModeFull, setup: func(host *networktest.Host) {
			host.AddRule(networktest.Rule{Family: 6, Priority: 100, FwMark: FwMark, Table: 100})
		}, kind: ConflictForeignMark, names: []string{"rule 100"}},
		{name: "unowned link with the interface name", mode: ModeMesh, setup: func(host *networktest.Host) {
			host.AddLink(networktest.Link{Name: InterfaceName, Kind: "wireguard", MTU: 1420})
		}, kind: ConflictForeignInterface, names: []string{InterfaceName}},
		{name: "IPv6 disabled by sysctl", mode: ModeMesh, setup: func(host *networktest.Host) {
			host.SetFile("/proc/sys/net/ipv6/conf/default/disable_ipv6", "1\n")
		}, kind: ConflictIPv6Disabled},
		{name: "IPv6 disabled at boot", mode: ModeMesh, setup: func(host *networktest.Host) {
			host.RemoveFile("/proc/sys/net/ipv6/conf/all/disable_ipv6")
			host.RemoveFile("/proc/sys/net/ipv6/conf/default/disable_ipv6")
		}, kind: ConflictIPv6Disabled},
		{name: "no WireGuard module", mode: ModeMesh, setup: func(host *networktest.Host) {
			host.RemoveFile("/sys/module/wireguard/version")
		}, kind: ConflictNoWireGuard},
		{name: "busctl missing", mode: ModeFull, setup: func(host *networktest.Host) { host.RemoveTool(ToolBusctl) }, kind: ConflictMissingTools, names: []string{"busctl"}},
		{name: "resolved inactive", mode: ModeFull, setup: func(host *networktest.Host) { host.SetResolverActive(false) }, kind: ConflictResolverInactive},
		{name: "resolv.conf bypasses the stub", mode: ModeFull, setup: func(host *networktest.Host) {
			host.SetFile("/etc/resolv.conf", "nameserver 192.168.64.1\n")
		}, kind: ConflictResolverStub},
		{name: "another link routes everything", mode: ModeFull, setup: func(host *networktest.Host) { host.SetLinkDomains("enp0s1", "~.") }, kind: ConflictResolverDomains, names: []string{"~."}},
		{name: "DHCP search domain", mode: ModeFull, setup: func(host *networktest.Host) { host.SetLinkDomains("enp0s1", "Lan.") }, kind: ConflictResolverDomains, names: []string{"lan"}},
		{name: "global routing domain", mode: ModeFull, setup: func(host *networktest.Host) {
			host.SetGlobalDNS(netip.MustParseAddr("192.0.2.53"))
			host.SetGlobalDomains("~corp.example")
		}, kind: ConflictResolverDomains, names: []string{"~corp.example"}},
		{name: "Tailscale exit node", mode: ModeFull, setup: func(host *networktest.Host) {
			host.AddRule(networktest.Rule{Family: 4, Priority: 5270, Table: 52})
			host.AddRoute(networktest.Route{Dst: netip.MustParsePrefix("0.0.0.0/0"), Table: 52, Dev: "tailscale0", Protocol: 4})
		}, kind: ConflictForeignVPN, names: []string{"5270 lookup 52"}},
		{name: "wg-quick full tunnel", mode: ModeFull, setup: func(host *networktest.Host) {
			host.AddRule(networktest.Rule{Family: 6, Priority: 32765, Not: true, FwMark: 51820, Table: 51820})
			host.AddRoute(networktest.Route{Dst: netip.MustParsePrefix("::/0"), Table: 51820, Dev: "wg0", Protocol: 3})
		}, kind: ConflictForeignVPN, names: []string{"32765 lookup 51820"}},
		{name: "Tailscale subnet route covers mesh", mode: ModeMesh, setup: func(host *networktest.Host) {
			host.AddRule(networktest.Rule{Family: 4, Priority: 5270, Table: 52})
			host.AddRoute(networktest.Route{Dst: netip.MustParsePrefix("10.0.0.0/16"), Table: 52, Dev: "tailscale0", Protocol: 4})
		}, kind: ConflictOverlap, prefixes: []string{"10.0.0.0/16"}},
		{name: "Tailscale exit node captures mesh", mode: ModeMesh, setup: func(host *networktest.Host) {
			host.AddRule(networktest.Rule{Family: 4, Priority: 5270, Table: 52})
			host.AddRoute(networktest.Route{Dst: netip.MustParsePrefix("0.0.0.0/0"), Table: 52, Dev: "tailscale0", Protocol: 4})
		}, kind: ConflictOverlap, prefixes: []string{"0.0.0.0/0"}},
		{name: "rule sends mesh to another table", mode: ModeMesh, setup: func(host *networktest.Host) {
			host.AddRule(networktest.Rule{Family: 4, Priority: 100, Dst: netip.MustParsePrefix("10.0.0.0/16"), Table: 100})
			host.AddRoute(networktest.Route{Dst: netip.MustParsePrefix("0.0.0.0/0"), Table: 100, Dev: "enp0s1", Gateway: netip.MustParseAddr("192.168.64.1"), Protocol: 4})
		}, kind: ConflictOverlap, prefixes: []string{"0.0.0.0/0"}},
		{name: "unowned link with the pending name", mode: ModeMesh, setup: func(host *networktest.Host) {
			host.AddLink(networktest.Link{Name: PendingInterfaceName, Kind: "wireguard", MTU: 1420})
		}, kind: ConflictForeignInterface, names: []string{PendingInterfaceName}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			host := networktest.NewUbuntu()
			test.setup(host)
			h := newHarness(t, host)

			err := h.m.Preflight(ctx, testProfile(test.mode, 5))

			var preflight *PreflightError
			if !errors.As(err, &preflight) {
				t.Fatalf("err = %v", err)
			}
			i := slices.IndexFunc(preflight.Conflicts, func(c Conflict) bool { return c.Kind == test.kind })
			if i < 0 {
				t.Fatalf("conflicts = %v, want %s", preflight.Conflicts, test.kind)
			}
			var prefixes []string
			for _, prefix := range preflight.Conflicts[i].Prefixes {
				prefixes = append(prefixes, prefix.String())
			}
			expect(t, "names", strings.Join(preflight.Conflicts[i].Names, ","), strings.Join(test.names, ","))
			expect(t, "prefixes", strings.Join(prefixes, ","), strings.Join(test.prefixes, ","))
			expect(t, "mutations", len(mutations(host.Calls())), 0)
		})
	}
}

func TestPreflightPassesModeSpecificSetups(t *testing.T) {
	tests := []struct {
		name  string
		mode  Mode
		setup func(*networktest.Host)
	}{
		{name: "broad route is less specific than mesh routes", mode: ModeMesh, setup: func(host *networktest.Host) {
			host.AddRoute(networktest.Route{Dst: netip.MustParsePrefix("10.0.0.0/8"), Table: 254, Dev: "enp0s1", Gateway: netip.MustParseAddr("192.168.64.1"), Protocol: 4})
		}},
		{name: "mesh ignores rules, table routes, and marks", mode: ModeMesh, setup: func(host *networktest.Host) {
			host.AddRule(networktest.Rule{Family: 4, Priority: PrioritySuppress, Table: 100})
			host.AddRule(networktest.Rule{Family: 6, Priority: 100, FwMark: FwMark, Table: 100})
			host.AddRoute(networktest.Route{Dst: netip.MustParsePrefix("0.0.0.0/0"), Table: RouteTable, Dev: "enp0s1", Protocol: 4})
			host.AddLink(networktest.Link{Name: "wg0", Kind: "wireguard", MTU: 1420, Up: true, WireGuard: &networktest.WireGuard{FwMark: FwMark}})
		}},
		{name: "full coexists with Tailscale", mode: ModeFull, setup: addTailscaleRules},
		{name: "domain on a link without DNS servers", mode: ModeFull, setup: func(host *networktest.Host) {
			host.AddLink(networktest.Link{Name: "enp0s2", MTU: 1500, Up: true})
			host.SetLinkDomains("enp0s2", "lan")
		}},
		{name: "global domain without global DNS servers", mode: ModeFull, setup: func(host *networktest.Host) {
			host.SetGlobalDomains("corp.example")
		}},
		{name: "secondary NIC source routing in Full", mode: ModeFull, setup: addSecondaryNIC},
		{name: "secondary NIC source routing in Mesh", mode: ModeMesh, setup: addSecondaryNIC},
		{name: "rule after main to a table without mesh routes", mode: ModeMesh, setup: func(host *networktest.Host) {
			host.AddRule(networktest.Rule{Family: 4, Priority: 32800, Table: 100})
			host.AddRoute(networktest.Route{Dst: netip.MustParsePrefix("10.0.0.0/16"), Table: 100, Dev: "enp0s1", Protocol: 4})
		}},
		{name: "mesh ignores resolver setup", mode: ModeMesh, setup: func(host *networktest.Host) {
			host.SetResolverActive(false)
			host.SetLinkDomains("enp0s1", "lan")
			host.RemoveTool(ToolBusctl)
		}},
		{name: "module installed but not loaded", mode: ModeFull, setup: func(host *networktest.Host) {
			host.RemoveFile("/sys/module/wireguard/version")
			host.SetFile("/lib/modules/6.8.0-45-generic/modules.dep", "kernel/drivers/net/wireguard/wireguard.ko.zst: kernel/net/ipv4/udp_tunnel.ko.zst\n")
		}},
		{name: "unrelated rules and tables", mode: ModeFull, setup: func(host *networktest.Host) {
			host.AddRule(networktest.Rule{Family: 4, Priority: 5270, Table: 52})
			host.AddNftTable("inet", "cloudgateway")
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			host := networktest.NewUbuntu()
			test.setup(host)
			if err := newHarness(t, host).m.Preflight(ctx, testProfile(test.mode, 5)); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestPreflightIgnoresOwnedTunnel(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))

	for _, mode := range []Mode{ModeFull, ModeMesh} {
		if err := h.m.Preflight(ctx, testProfile(mode, 5)); err != nil {
			t.Fatalf("%s: %v", mode, err)
		}
	}
}

func TestResolverOutageIsBounded(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))

	host.SetResolverActive(false)
	obs, err := h.m.Reconcile(ctx)
	if err != nil {
		t.Fatal(err)
	}
	expect(t, "state", obs.State, StateConnecting)
	expect(t, "drift", slices.Contains(obs.Drift, "resolver unavailable"), true)
	h.now = h.now.Add(20 * time.Second)
	if _, err := h.m.Reconcile(ctx); err != nil {
		t.Fatalf("within the bound: %v", err)
	}

	host.SetResolverActive(true)
	obs, err = h.m.Reconcile(ctx)
	if err != nil {
		t.Fatal(err)
	}
	expect(t, "recovered", obs.State, StateConnected)

	host.SetResolverActive(false)
	h.now = h.now.Add(20 * time.Second)
	if _, err := h.m.Reconcile(ctx); err != nil {
		t.Fatalf("new outage: %v", err)
	}
	h.now = h.now.Add(31 * time.Second)
	if _, err := h.m.Reconcile(ctx); !errors.Is(err, ErrResolverPolicy) {
		t.Fatalf("past the bound err = %v", err)
	}
}

func TestReconcileRepairsLinkState(t *testing.T) {
	for _, damage := range []func(*networktest.Host){
		func(host *networktest.Host) { host.SetLinkDown(InterfaceName) },
		func(host *networktest.Host) { host.SetLinkMTU(InterfaceName, 1200) },
	} {
		host := networktest.NewUbuntu()
		h := newHarness(t, host)
		h.apply(testProfile(ModeFull, 5))
		damage(host)

		obs, _ := h.m.Observe(ctx)
		expect(t, "before reconcile", obs.State, StateConnecting)
		expect(t, "IPv6 address gone", slices.Contains(obs.Drift, "missing address fd42:42:42::5/128"), true)
		obs, err := h.m.Reconcile(ctx)

		if err != nil {
			t.Fatal(err)
		}
		expect(t, "state", obs.State, StateConnected)
		expectText(t, "owned state", ownedState(host), fullOwnedState)
	}
}

func TestUpdateEndpointRetriesFailedSet(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))
	h.server = netip.MustParseAddr("203.0.113.20")
	host.FailWhen(networktest.Match("wg", "set"))

	endpoint, changed, err := h.m.UpdateEndpoint(ctx)

	if err == nil || changed {
		t.Fatalf("changed=%t err=%v", changed, err)
	}
	expect(t, "kernel endpoint returned", endpoint, netip.MustParseAddrPort("203.0.113.10:51820"))
	host.ClearFailures()
	endpoint, changed, err = h.m.UpdateEndpoint(ctx)
	if err != nil || !changed {
		t.Fatalf("retry changed=%t err=%v", changed, err)
	}
	l, _ := host.Link(InterfaceName)
	expect(t, "kernel endpoint", l.WireGuard.Endpoint, endpoint)
	expect(t, "journal endpoint", h.lastJournal().Endpoint, endpoint)
}

// addSecondaryNIC adds the from and to rules cloud images set up for a second NIC
func addSecondaryNIC(host *networktest.Host) {
	host.AddLink(networktest.Link{Name: "enp0s2", MTU: 9000, Up: true})
	host.AddAddress("enp0s2", netip.MustParsePrefix("192.168.65.9/24"), "global")
	host.AddRule(networktest.Rule{Family: 4, Priority: 100, Src: netip.MustParsePrefix("192.168.65.9/32"), Table: 10001})
	host.AddRule(networktest.Rule{Family: 4, Priority: 100, Dst: netip.MustParsePrefix("192.168.65.9/32"), Table: 10001})
	host.AddRoute(networktest.Route{Dst: netip.MustParsePrefix("0.0.0.0/0"), Table: 10001, Dev: "enp0s2", Gateway: netip.MustParseAddr("192.168.65.1"), Protocol: 4})
}

func TestResolverReapplyFailureIsBounded(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))
	start := h.now
	// resolved answers reads but rejects the reapply
	host.RevertLink(InterfaceName)
	host.FailWhen(networktest.Match("resolvectl", "dns"))

	var failedAt time.Duration = -1
	for elapsed := time.Duration(0); elapsed <= 80*time.Second; elapsed += 10 * time.Second {
		h.now = start.Add(elapsed)
		if _, err := h.m.Reconcile(ctx); errors.Is(err, ErrResolverPolicy) {
			failedAt = elapsed
			break
		} else if err != nil {
			t.Fatalf("at %s: %v", elapsed, err)
		}
	}

	expect(t, "failed at", failedAt, 30*time.Second)
}
