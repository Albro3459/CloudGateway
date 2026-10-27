package network

import (
	"encoding/json"
	"errors"
	"net/netip"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network/networktest"
)

const fullOwnedState = `link cloudgateway kind=wireguard alias=cloudgatewayd mtu=1420 up=true addrs=10.0.0.5/32,fd42:42:42::5/128
nft inet cloudgateway_client
resolver dns=[10.0.0.1 fd42:42:42::1] domains=[~. corp.example] default-route=true
route 0.0.0.0/0 table 52820
route ::/0 table 52820
rule v4 30200 from=192.168.64.5/32 to=all not=false fwmark=0x0 table=254 suppress=false
rule v4 30205 from=all to=169.254.0.0/16 not=false fwmark=0x0 table=254 suppress=false
rule v4 30210 from=all to=all not=false fwmark=0x0 table=254 suppress=true
rule v4 30220 from=all to=all not=true fwmark=0xce54 table=52820 suppress=false
rule v6 30200 from=2001:db8:1::5/128 to=all not=false fwmark=0x0 table=254 suppress=false
rule v6 30205 from=all to=fe80::/10 not=false fwmark=0x0 table=254 suppress=false
rule v6 30210 from=all to=all not=false fwmark=0x0 table=254 suppress=true
rule v6 30220 from=all to=all not=true fwmark=0xce54 table=52820 suppress=false
wg fwmark=0xce54 peer=xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg= endpoint=203.0.113.10:51820 allowed=[0.0.0.0/0 ::/0]`

func TestApplyFullInstallsExactOwnedSet(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	foreign := foreignState(host)

	obs := h.apply(testProfile(ModeFull, 5))

	expect(t, "state", obs.State, StateConnected)
	expect(t, "freshness", obs.Freshness, FreshnessCurrent)
	expect(t, "mode", obs.ActiveMode, ModeFull)
	expect(t, "profile", obs.ProfileID, "uid/us-sanjose-1/client-5")
	expect(t, "observed at", obs.ObservedAt, h.now)
	expectText(t, "owned state", ownedState(host), fullOwnedState)
	expectText(t, "foreign state", foreignState(host), foreign)
	expectText(t, "commands", strings.Join(mutations(host.Calls()), "\n"), `nft -f -
ip link add dev cloudgw-pending type wireguard
ip link set dev cloudgw-pending alias cloudgatewayd
ip link set dev cloudgw-pending name cloudgateway
wg setconf cloudgateway /dev/stdin
ip -4 address add 10.0.0.5/32 dev cloudgateway
ip -6 address add fd42:42:42::5/128 dev cloudgateway
ip link set dev cloudgateway mtu 1420
ip link set dev cloudgateway up
ip -4 route add 0.0.0.0/0 dev cloudgateway table 52820 proto 206
ip -6 route add ::/0 dev cloudgateway table 52820 proto 206
ip -4 rule add priority 30200 from 192.168.64.5 lookup main protocol 206
ip -6 rule add priority 30200 from 2001:db8:1::5 lookup main protocol 206
ip -4 rule add priority 30205 to 169.254.0.0/16 lookup main protocol 206
ip -6 rule add priority 30205 to fe80::/10 lookup main protocol 206
ip -4 rule add priority 30210 lookup main suppress_prefixlength 0 protocol 206
ip -6 rule add priority 30210 lookup main suppress_prefixlength 0 protocol 206
ip -4 rule add priority 30220 not fwmark 0xce54 lookup 52820 protocol 206
ip -6 rule add priority 30220 not fwmark 0xce54 lookup 52820 protocol 206
resolvectl dns cloudgateway 10.0.0.1 fd42:42:42::1
resolvectl domain cloudgateway ~. corp.example
resolvectl default-route cloudgateway yes`)
	body, _ := host.NftTable("inet " + NftTable)
	expectText(t, "nft table", body, `	chain preraw {
		type filter hook prerouting priority -300; policy accept;
		iifname != "cloudgateway" ip daddr 10.0.0.5 fib saddr type != local drop
		iifname != "cloudgateway" ip6 daddr fd42:42:42::5 fib saddr type != local drop
	}
	chain premangle {
		type filter hook prerouting priority -150; policy accept;
		meta l4proto udp meta mark set ct mark
	}
	chain postmangle {
		type filter hook postrouting priority -150; policy accept;
		meta l4proto udp meta mark 0xce54 ct mark set meta mark
	}`)
	mark, _ := host.File(srcValidMarkPath)
	expect(t, "src_valid_mark", mark, "1\n")
	expectText(t, "journal phases", strings.Join(h.phases(), "\n"), "applying uid/us-sanjose-1/client-5\napplied uid/us-sanjose-1/client-5")
	expect(t, "lookups", strings.Join(h.lookups, ","), "us-sanjose-1.vpn.example.com")
	expect(t, "exchanges", len(h.exchanges), 0)
}

func TestApplyMeshInstallsExactOwnedSet(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	foreign := foreignState(host)

	obs := h.apply(testProfile(ModeMesh, 5))

	expect(t, "state", obs.State, StateConnected)
	expect(t, "mode", obs.ActiveMode, ModeMesh)
	expectText(t, "owned state", ownedState(host), `link cloudgateway kind=wireguard alias=cloudgatewayd mtu=1420 up=true addrs=10.0.0.5/32,fd42:42:42::5/128
nft inet cloudgateway_client
route 10.0.0.0/16 table 254
route fd42:42:42::/48 table 254
wg fwmark=0x0 peer=xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg= endpoint=203.0.113.10:51820 allowed=[10.0.0.0/16 fd42:42:42::/48]`)
	expectText(t, "foreign state", foreignState(host), foreign)
	expectText(t, "commands", strings.Join(mutations(host.Calls()), "\n"), `nft -f -
ip link add dev cloudgw-pending type wireguard
ip link set dev cloudgw-pending alias cloudgatewayd
ip link set dev cloudgw-pending name cloudgateway
wg setconf cloudgateway /dev/stdin
ip -4 address add 10.0.0.5/32 dev cloudgateway
ip -6 address add fd42:42:42::5/128 dev cloudgateway
ip link set dev cloudgateway mtu 1420
ip link set dev cloudgateway up
ip -4 route add 10.0.0.0/16 dev cloudgateway table 254 proto 206
ip -6 route add fd42:42:42::/48 dev cloudgateway table 254 proto 206`)
	body, _ := host.NftTable("inet " + NftTable)
	expectText(t, "nft table", body, `	chain preraw {
		type filter hook prerouting priority -300; policy accept;
		iifname != "cloudgateway" ip daddr 10.0.0.5 fib saddr type != local drop
		iifname != "cloudgateway" ip6 daddr fd42:42:42::5 fib saddr type != local drop
	}`)
	mark, _ := host.File(srcValidMarkPath)
	expect(t, "src_valid_mark", mark, "0\n")
	for _, c := range host.Calls() {
		if c.Tool == "resolvectl" || c.Tool == "busctl" {
			t.Fatalf("mesh touched the resolver: %s", c)
		}
	}
}

func TestMTU(t *testing.T) {
	tests := []struct {
		name      string
		setup     func(*networktest.Host)
		configMTU int
		want      int
	}{
		{name: "ordinary link", want: 1420},
		{name: "jumbo cloud NIC", setup: func(host *networktest.Host) { host.SetLinkMTU("enp0s1", 9000) }, want: 1420},
		{name: "route MTU", setup: func(host *networktest.Host) {
			host.AddRoute(networktest.Route{Dst: netip.MustParsePrefix("203.0.113.0/24"), Table: 254, Dev: "enp0s1", Gateway: netip.MustParseAddr("192.168.64.1"), Protocol: 4, MTU: 1400})
		}, want: 1320},
		{name: "route below the IPv6 minimum", setup: func(host *networktest.Host) {
			host.AddRoute(networktest.Route{Dst: netip.MustParsePrefix("203.0.113.0/24"), Table: 254, Dev: "enp0s1", Gateway: netip.MustParseAddr("192.168.64.1"), Protocol: 4, MTU: 1300})
		}, want: 1280},
		{name: "config wins", setup: func(host *networktest.Host) { host.SetLinkMTU("enp0s1", 9000) }, configMTU: 1380, want: 1380},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			host := networktest.NewUbuntu()
			if test.setup != nil {
				test.setup(host)
			}
			h := newHarness(t, host)
			p := testProfile(ModeFull, 5)
			p.MTU = test.configMTU
			obs := h.apply(p)
			expect(t, "state", obs.State, StateConnected)
			l, _ := host.Link(InterfaceName)
			expect(t, "mtu", l.MTU, test.want)
			expect(t, "journal mtu", h.lastJournal().MTU, test.want)
			asked := slices.ContainsFunc(host.Calls(), networktest.Match("ip", "-j", "-4", "route", "get", "203.0.113.10", "mark", "0xce54"))
			expect(t, "route lookup", asked, test.configMTU == 0)
		})
	}
}

func TestRollbackRemovesOnlyOwnedChanges(t *testing.T) {
	for _, failing := range []func(networktest.Call) bool{
		networktest.Match("ip", "link", "set", "dev", PendingInterfaceName, "alias"),
		networktest.Match("ip", "link", "set", "dev", PendingInterfaceName, "name"),
		networktest.Match("ip", "-6", "rule", "add", "priority", "30220"),
		networktest.Match("resolvectl", "domain"),
	} {
		host := networktest.NewUbuntu()
		h := newHarness(t, host)
		foreign := foreignState(host)
		host.FailWhen(failing)

		obs, err := h.m.Apply(ctx, testProfile(ModeFull, 5), nil)

		var applyErr *ApplyError
		if !errors.As(err, &applyErr) || applyErr.Restored {
			t.Fatalf("err = %v", err)
		}
		expect(t, "state", obs.State, StateDisconnected)
		expect(t, "mode", obs.ActiveMode, "")
		expectText(t, "owned state", ownedState(host), "")
		expectText(t, "foreign state", foreignState(host), foreign)
		if h.lastJournal() != nil {
			t.Fatalf("journal = %+v, want cleared", h.lastJournal())
		}
	}
}

func TestReplacementRestoresPreviousProfile(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	previous := testProfile(ModeFull, 5)
	h.apply(previous)
	host.FailWhen(networktest.Match("ip", "-4", "address", "add", "10.0.0.9/32"))
	h.persisted = nil

	obs, err := h.m.Apply(ctx, testProfile(ModeFull, 9), &previous)

	var applyErr *ApplyError
	if !errors.As(err, &applyErr) || !applyErr.Restored {
		t.Fatalf("err = %v", err)
	}
	expect(t, "state", obs.State, StateConnected)
	expect(t, "profile", obs.ProfileID, previous.ID)
	expectText(t, "owned state", ownedState(host), fullOwnedState)
	expectText(t, "journal phases", strings.Join(h.phases(), "\n"), `removing uid/us-sanjose-1/client-5
cleared
applying uid/us-sanjose-1/client-9
removing uid/us-sanjose-1/client-9
cleared
applying uid/us-sanjose-1/client-5
applied uid/us-sanjose-1/client-5`)
}

func TestReplacementReportsDisconnectedWhenRestoreFails(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	previous := testProfile(ModeFull, 5)
	h.apply(previous)
	host.FailWhen(networktest.Match("ip", "link", "set", "dev", InterfaceName, "up"))

	obs, err := h.m.Apply(ctx, testProfile(ModeMesh, 5), &previous)

	var applyErr *ApplyError
	if !errors.As(err, &applyErr) || applyErr.Restored {
		t.Fatalf("err = %v", err)
	}
	expect(t, "state", obs.State, StateDisconnected)
	expectText(t, "owned state", ownedState(host), "")
	expect(t, "restore error reported", strings.Contains(err.Error(), "restoring previous profile"), true)
	if h.lastJournal() != nil {
		t.Fatalf("journal = %+v, want cleared", h.lastJournal())
	}
}

func TestReplacementOnlyRestoresTheReplacedProfile(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))
	host.FailWhen(networktest.Match("ip", "-4", "address", "add", "10.0.0.9/32"))
	stale := testProfile(ModeFull, 5)
	stale.ConfigHash = "hash-rotated"

	obs, err := h.m.Apply(ctx, testProfile(ModeFull, 9), &stale)

	var applyErr *ApplyError
	if !errors.As(err, &applyErr) || applyErr.Restored || !strings.Contains(err.Error(), "does not match") {
		t.Fatalf("err = %v", err)
	}
	expect(t, "state", obs.State, StateDisconnected)
	expectText(t, "owned state", ownedState(host), "")
}

func TestPreflightFailureKeepsCurrentTunnel(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))
	host.SetLinkDomains("enp0s1", "lan")
	host.ResetCalls()

	obs, err := h.m.Apply(ctx, testProfile(ModeFull, 9), nil)

	var preflight *PreflightError
	if !errors.As(err, &preflight) || !preflight.Has(ConflictResolverDomains) {
		t.Fatalf("err = %v", err)
	}
	expect(t, "mutations", len(mutations(host.Calls())), 0)
	expect(t, "profile", h.lastJournal().ProfileID, "uid/us-sanjose-1/client-5")
	expectText(t, "owned state", ownedState(host), fullOwnedState)
	// The new conflict also takes the running tunnel out of exclusive DNS
	expect(t, "state", obs.State, StateConnecting)
}

func TestReplacingFullResolvesEndpointOutsideTunnel(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))
	h.lookups = nil
	host.ResetCalls()

	obs := h.apply(testProfile(ModeFull, 9))

	expect(t, "profile", obs.ProfileID, "uid/us-sanjose-1/client-9")
	expect(t, "host lookups", len(h.lookups), 0)
	expect(t, "exchanges", len(h.exchanges), 1)
	expect(t, "server", h.exchanges[0].server, netip.MustParseAddrPort("192.168.64.1:53"))
	expect(t, "mark", h.exchanges[0].mark, uint32(FwMark))
	expect(t, "route lookup", slices.ContainsFunc(host.Calls(), networktest.Match("ip", "-j", "-4", "route", "get", "203.0.113.10", "mark", "0xce54")), true)
}

func TestDownFromJournalAfterRestart(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	foreign := foreignState(host)
	h.apply(testProfile(ModeFull, 5))
	h.restart(h.lastJournal())

	obs, err := h.m.Down(ctx)

	if err != nil {
		t.Fatal(err)
	}
	expect(t, "state", obs.State, StateDisconnected)
	expectText(t, "owned state", ownedState(host), "")
	expectText(t, "foreign state", foreignState(host), foreign)
	expect(t, "reverted", slices.ContainsFunc(host.Calls(), networktest.Match("resolvectl", "revert", InterfaceName)), true)
	if h.lastJournal() != nil {
		t.Fatalf("journal = %+v, want cleared", h.lastJournal())
	}
	mark, _ := host.File(srcValidMarkPath)
	expect(t, "src_valid_mark kept", mark, "1\n")
}

func TestDownByFixedIdentityWithoutJournal(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	foreign := foreignState(host)
	h.apply(testProfile(ModeFull, 5))
	h.restart(nil)

	obs, _ := h.m.Observe(ctx)
	expect(t, "state before down", obs.State, StateUnknown)
	obs, err := h.m.Down(ctx)

	if err != nil {
		t.Fatal(err)
	}
	expect(t, "state", obs.State, StateDisconnected)
	expectText(t, "owned state", ownedState(host), "")
	expectText(t, "foreign state", foreignState(host), foreign)
}

func TestDownNeverAdoptsForeignLink(t *testing.T) {
	host := networktest.NewUbuntu()
	host.AddLink(networktest.Link{Name: InterfaceName, Kind: "wireguard", MTU: 1420, Up: true})
	host.AddRule(networktest.Rule{Family: 4, Priority: PriorityTunnel, Not: true, FwMark: FwMark, Table: RouteTable, Protocol: RouteProtocol})
	host.AddNftTable("inet", NftTable)
	h := newHarness(t, host)

	obs, err := h.m.Down(ctx)

	if err != nil {
		t.Fatal(err)
	}
	expect(t, "state", obs.State, StateDisconnected)
	l, ok := host.Link(InterfaceName)
	expect(t, "foreign link kept", ok && l.Alias == "", true)
	expect(t, "owned rules", slices.ContainsFunc(host.Rules(), isOwnedRule), false)
	expect(t, "owned table", slices.Contains(host.NftTables(), "inet "+NftTable), false)
}

func TestDownAdoptsPendingLinkFromInterruptedChange(t *testing.T) {
	for _, phase := range []Phase{PhaseApplying, PhaseRemoving} {
		host := networktest.NewUbuntu()
		host.AddLink(networktest.Link{Name: PendingInterfaceName, Kind: "wireguard", MTU: 1420})
		host.AddNftTable("inet", NftTable)
		h := newHarness(t, host)
		h.restart(&Journal{Version: JournalVersion, Phase: phase, ProfileID: "uid/us-sanjose-1/client-5", Mode: ModeFull, Resources: fixed})

		obs, _ := h.m.Observe(ctx)
		expect(t, "state before down", obs.State, StateUnknown)
		obs, err := h.m.Down(ctx)

		if err != nil {
			t.Fatal(err)
		}
		expect(t, "state", obs.State, StateDisconnected)
		_, pending := host.Link(PendingInterfaceName)
		expect(t, "pending link removed", pending, false)
		expectText(t, "owned state", ownedState(host), "")
	}
}

func TestUnaliasedPendingLinkWithoutJournalIsForeign(t *testing.T) {
	host := networktest.NewUbuntu()
	host.AddLink(networktest.Link{Name: PendingInterfaceName, Kind: "wireguard", MTU: 1420})
	h := newHarness(t, host)

	if _, err := h.m.Down(ctx); err != nil {
		t.Fatal(err)
	}

	_, kept := host.Link(PendingInterfaceName)
	expect(t, "pending link kept", kept, true)
}

func TestKnownResourcesAreValid(t *testing.T) {
	for _, res := range knownResources {
		if !res.valid() {
			t.Fatalf("invalid known resource set %+v", res)
		}
	}
	invalid := fixed
	invalid.Protocol = 0
	knownResources = append(knownResources, invalid)
	t.Cleanup(func() { knownResources = knownResources[:len(knownResources)-1] })

	res, _ := ownership(&Journal{Phase: PhaseApplied, Resources: invalid})

	expect(t, "fallback", res, fixed)
}

func TestUnaliasedInterfaceNameIsNeverAdopted(t *testing.T) {
	for _, phase := range []Phase{PhaseApplying, PhaseRemoving} {
		host := networktest.NewUbuntu()
		host.AddLink(networktest.Link{Name: InterfaceName, Kind: "wireguard", MTU: 1420})
		h := newHarness(t, host)
		h.restart(&Journal{Version: JournalVersion, Phase: phase, ProfileID: "uid/us-sanjose-1/client-5", Mode: ModeFull, Resources: fixed})

		obs, err := h.m.Down(ctx)

		if err != nil {
			t.Fatal(err)
		}
		expect(t, "state", obs.State, StateDisconnected)
		_, kept := host.Link(InterfaceName)
		expect(t, "foreign link kept", kept, true)
		var preflight *PreflightError
		if err := h.m.Preflight(ctx, testProfile(ModeMesh, 5)); !errors.As(err, &preflight) || !preflight.Has(ConflictForeignInterface) {
			t.Fatalf("preflight err = %v", err)
		}
	}
}

func TestIncompleteDownStaysVisible(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeMesh, 5))
	host.FailWhen(networktest.Match("ip", "link", "del"))

	obs, err := h.m.Down(ctx)

	if !errors.Is(err, ErrTeardownIncomplete) {
		t.Fatalf("err = %v", err)
	}
	expect(t, "state", obs.State, StateUnknown)
	expect(t, "journal phase", h.lastJournal().Phase, PhaseRemoving)
}

func TestNoSecretsOutsideSetconfStdin(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))
	h.server = netip.MustParseAddr("203.0.113.20")
	if _, _, err := h.m.UpdateEndpoint(ctx); err != nil {
		t.Fatal(err)
	}
	host.FailWhen(networktest.Match("wg", "setconf"))
	_, applyErr := h.m.Apply(ctx, testProfile(ModeFull, 9), nil)
	if applyErr == nil {
		t.Fatal("apply succeeded")
	}
	host.ClearFailures()
	h.apply(testProfile(ModeMesh, 5))
	if _, err := h.m.Down(ctx); err != nil {
		t.Fatal(err)
	}

	secrets := []string{testPrivateKey, testPresharedKey}
	journals, _ := json.Marshal(h.persisted)
	setconfs := 0
	for _, c := range host.Calls() {
		for _, secret := range secrets {
			if strings.Contains(strings.Join(c.Args, " "), secret) {
				t.Fatalf("secret in argv: %s", c)
			}
			if strings.Contains(string(c.Stdin), secret) && !c.Has("setconf", InterfaceName, "/dev/stdin") {
				t.Fatalf("secret in stdin of %s", c)
			}
		}
		if c.Has("setconf") && strings.Contains(string(c.Stdin), testPrivateKey) {
			setconfs++
		}
	}
	for _, secret := range secrets {
		for _, text := range []string{applyErr.Error(), string(journals)} {
			if strings.Contains(text, secret) {
				t.Fatalf("secret leaked into %q", text)
			}
		}
	}
	expect(t, "setconf calls with key", setconfs, 3)
}

func TestJournalRoundTrip(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))
	data, err := json.Marshal(h.lastJournal())
	if err != nil {
		t.Fatal(err)
	}

	parsed, err := ParseJournal(data)

	if err != nil {
		t.Fatal(err)
	}
	again, _ := json.Marshal(parsed)
	expectText(t, "journal", string(again), string(data))
	expect(t, "endpoint", parsed.Endpoint, netip.MustParseAddrPort("203.0.113.10:51820"))
	for _, bad := range []string{`{"version":2,"phase":"applied","resources":{"interface":"cloudgateway","nftTable":"x"}}`, `{"version":1,"phase":"done"}`, `{"version":1,"phase":"applied"}`, sparseJournal, `not json`} {
		if _, err := ParseJournal([]byte(bad)); err == nil {
			t.Fatalf("ParseJournal(%s) succeeded", bad)
		}
	}
}

func TestInvalidProfileChangesNothing(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	for _, mutate := range []func(*Profile){
		func(p *Profile) { p.PeerPublicKey = "not a key" },
		func(p *Profile) { p.SearchDomains = []string{"--set-dns"} },
		func(p *Profile) { p.EndpointHost = "host name" },
		func(p *Profile) { p.AllowedIPs = []netip.Prefix{netip.MustParsePrefix("10.0.0.5/16")} },
		func(p *Profile) { p.DNS = nil },
		func(p *Profile) { p.SetConf = nil },
		func(p *Profile) { p.Addresses = p.Addresses[:1] },
		func(p *Profile) { p.Addresses = p.Addresses[1:] },
		func(p *Profile) { p.AllowedIPs = p.AllowedIPs[:1] },
	} {
		p := testProfile(ModeFull, 5)
		mutate(&p)
		if _, err := h.m.Apply(ctx, p, nil); !errors.Is(err, ErrInvalidProfile) {
			t.Fatalf("err = %v", err)
		}
	}
	expect(t, "mutations", len(mutations(host.Calls())), 0)
}

func TestObservationWhileApplyingAndRemoving(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	var during []Observation
	record := func() {
		obs, err := h.m.Observe(ctx)
		if err != nil {
			t.Error(err)
		}
		during = append(during, obs)
	}
	host.After(networktest.Match("wg", "setconf"), record)
	host.After(networktest.Match("ip", "link", "del"), record)

	h.apply(testProfile(ModeFull, 5))
	if _, err := h.m.Down(ctx); err != nil {
		t.Fatal(err)
	}

	expect(t, "observations", len(during), 2)
	expect(t, "while applying", during[0].State, StateConnecting)
	expect(t, "mode while applying", during[0].ActiveMode, "")
	// Rules and the link are gone, the nftables table is not yet
	expect(t, "while removing", during[1].State, StateDisconnecting)
	expect(t, "mode while removing", during[1].ActiveMode, "")
}

func TestHandshakeAndRoamingDoNotEraseConnectedState(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))
	obs, _ := h.m.Observe(ctx)
	expect(t, "no handshake yet", obs.State, StateConnected)
	expect(t, "handshake", obs.LatestHandshake.IsZero(), true)

	handshake := h.now.Add(-10 * time.Minute)
	host.SetHandshake(InterfaceName, handshake)
	if _, err := host.Run(ctx, ToolWG, []string{"set", InterfaceName, "peer", testPeerKey, "endpoint", "198.51.100.7:51820"}, nil); err != nil {
		t.Fatal(err)
	}
	obs, _ = h.m.Observe(ctx)

	expect(t, "state", obs.State, StateConnected)
	expect(t, "mode", obs.ActiveMode, ModeFull)
	expect(t, "handshake", obs.LatestHandshake.Equal(handshake), true)
	expect(t, "endpoint", obs.Endpoint, netip.MustParseAddrPort("198.51.100.7:51820"))
}

// addTailscaleRules adds the policy rules tailscaled installs for both families
func addTailscaleRules(host *networktest.Host) {
	for _, family := range []int{4, 6} {
		for _, r := range []networktest.Rule{
			{Priority: 5210, FwMark: 0x80000, FwMask: 0xff0000, Table: 254},
			{Priority: 5230, FwMark: 0x80000, FwMask: 0xff0000, Table: 253},
			{Priority: 5250, FwMark: 0x80000, FwMask: 0xff0000},
			{Priority: 5270, Table: 52},
		} {
			r.Family = family
			host.AddRule(r)
		}
	}
}

func TestFullCoexistsWithTailscaleRules(t *testing.T) {
	host := networktest.NewUbuntu()
	addTailscaleRules(host)
	h := newHarness(t, host)
	foreign := foreignState(host)

	h.apply(testProfile(ModeFull, 5))
	host.RemoveRules(isOwnedRule)
	if _, err := h.m.Reconcile(ctx); err != nil {
		t.Fatal(err)
	}
	expectText(t, "owned state", ownedState(host), fullOwnedState)
	if _, err := h.m.Down(ctx); err != nil {
		t.Fatal(err)
	}

	expectText(t, "owned state after down", ownedState(host), "")
	expectText(t, "foreign state", foreignState(host), foreign)
}

func TestDownKeepsForeignRuleAtOwnedPriority(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))
	// Reconcile puts our rule after the foreign one, so a delete that ignored the
	// protocol would hit the foreign rule first
	foreign := networktest.Rule{Family: 4, Priority: PrioritySuppress, Table: 100}
	host.RemoveRules(isOwnedRule)
	host.AddRule(foreign)
	if _, err := h.m.Reconcile(ctx); err != nil {
		t.Fatal(err)
	}

	if _, err := h.m.Down(ctx); err != nil {
		t.Fatal(err)
	}

	expectText(t, "owned state", ownedState(host), "")
	expect(t, "foreign rule kept", slices.Contains(host.Rules(), foreign), true)
}

// sparseJournal leaves the protocol and priorities zero, which would match the
// kernel's default rules if ownership trusted it
const sparseJournal = `{"version":1,"phase":"applied","profileId":"uid/us-sanjose-1/client-5","mode":"full","resources":{"interface":"cloudgateway","alias":"cloudgatewayd","table":52820,"nftTable":"cloudgateway_client"}}`

func TestSparseJournalNeverTouchesKernelDefaults(t *testing.T) {
	if _, err := ParseJournal([]byte(sparseJournal)); err == nil {
		t.Fatal("ParseJournal accepted a sparse resource set")
	}
	var sparse Journal
	if err := json.Unmarshal([]byte(sparseJournal), &sparse); err != nil {
		t.Fatal(err)
	}
	isDefault := func(r networktest.Rule) bool { return r.Priority == 0 || r.Priority >= 32766 }

	for _, viaTeardown := range []bool{false, true} {
		host := networktest.NewUbuntu()
		h := newHarness(t, host)
		h.apply(testProfile(ModeFull, 5))
		defaults := slices.DeleteFunc(host.Rules(), func(r networktest.Rule) bool { return !isDefault(r) })
		expect(t, "default rules", len(defaults), 5)

		var err error
		if viaTeardown {
			// Even past New, ownership falls back to fixed identity
			err = h.m.teardown(ctx, &sparse)
		} else {
			h.restart(&sparse)
			_, err = h.m.Down(ctx)
		}

		if err != nil {
			t.Fatal(err)
		}
		expectText(t, "owned state", ownedState(host), "")
		expect(t, "default rules kept", slices.Equal(slices.DeleteFunc(host.Rules(), func(r networktest.Rule) bool { return !isDefault(r) }), defaults), true)
	}
}

func TestObserveRetriesAcrossConcurrentChange(t *testing.T) {
	host := networktest.NewUbuntu()
	h := newHarness(t, host)
	h.apply(testProfile(ModeFull, 5))
	start := h.now
	fired := false
	var inner Observation
	host.After(networktest.Match("nft", "-j", "list", "tables"), func() {
		if fired {
			return
		}
		fired = true
		if _, err := h.m.Down(ctx); err != nil {
			t.Error(err)
		}
		h.now = start.Add(time.Second)
		inner, _ = h.m.Observe(ctx)
		h.now = start.Add(2 * time.Second)
	})

	outer, err := h.m.Observe(ctx)

	if err != nil {
		t.Fatal(err)
	}
	expect(t, "outer state", outer.State, StateDisconnected)
	expect(t, "inner state", inner.State, StateDisconnected)
	host.FailWhen(networktest.Match("ip", "-j", "-d", "-N", "address", "show"))
	stale, _ := h.m.Observe(ctx)
	// The outer observation started first, so it must not replace the inner one
	expect(t, "last observed", stale.ObservedAt, start.Add(time.Second))
}
