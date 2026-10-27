package network

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The testdata samples are hand-written from the documented output formats,
// not captured from a host: iproute2 6.x ip -j (pretty-printed here, as -p
// would), with -N numeric tables, protocols, and scopes, nft -j list tables from
// nftables 1.0.9, busctl --json=short get-property replies for the
// org.freedesktop.resolve1(5) Manager DNS and Domains and Link DefaultRoute
// properties, and wg show <if> <field> lines from wg(8). They describe Ubuntu
// 24.04 with a Full tunnel up
type sampleExecutor map[string]string

func (s sampleExecutor) Run(_ context.Context, tool string, args []string, _ []byte) ([]byte, error) {
	name, ok := s[tool+" "+strings.Join(args, " ")]
	if !ok {
		return nil, fmt.Errorf("no sample for %s %v", tool, args)
	}
	return os.ReadFile(filepath.Join("testdata", name))
}

func (sampleExecutor) Available(string) bool { return true }

func (sampleExecutor) ReadFile(name string) ([]byte, error) {
	if name == ipv6DisablePath {
		return []byte("0\n"), nil
	}
	return nil, fs.ErrNotExist
}

func (sampleExecutor) WriteFile(string, []byte) error { return errors.New("read only") }

var samples = sampleExecutor{
	"ip -j -d -N address show":               "ip-address-show.json",
	"ip -j -N -4 route show table all":       "ip-route-show-4.json",
	"ip -j -N -6 route show table all":       "ip-route-show-6.json",
	"ip -j -N -4 rule show":                  "ip-rule-show-4.json",
	"ip -j -N -6 rule show":                  "ip-rule-show-6.json",
	"nft -j list tables":                     "nft-list-tables.json",
	"wg show cloudgateway fwmark":            "wg-show-fwmark.txt",
	"wg show cloudgateway endpoints":         "wg-show-endpoints.txt",
	"wg show cloudgateway allowed-ips":       "wg-show-allowed-ips.txt",
	"wg show cloudgateway latest-handshakes": "wg-show-latest-handshakes.txt",
	"busctl --json=short get-property org.freedesktop.resolve1 /org/freedesktop/resolve1 org.freedesktop.resolve1.Manager DNS":                "busctl-dns.json",
	"busctl --json=short get-property org.freedesktop.resolve1 /org/freedesktop/resolve1 org.freedesktop.resolve1.Manager Domains":            "busctl-domains.json",
	"busctl --json=short get-property org.freedesktop.resolve1 /org/freedesktop/resolve1/link/_33 org.freedesktop.resolve1.Link DefaultRoute": "busctl-default-route.json",
}

func TestSamplesParse(t *testing.T) {
	m := New(Options{Executor: samples})

	s, err := m.read(ctx, fixed, false, true)

	if err != nil {
		t.Fatal(err)
	}
	expect(t, "links", len(s.links), 3)
	expect(t, "owned index", s.own.Index, 3)
	expect(t, "owned mtu", s.own.MTU, 1420)
	expect(t, "physical", fmt.Sprint(s.physicalAddrs(fixed)), "[192.168.64.5 2001:db8:1::5]")
	expect(t, "routes", len(s.routes), 20)
	expect(t, "owned routes", fmt.Sprint(s.ownedRoutes(fixed)), "[{0.0.0.0/0 52820 cloudgateway 206 0} {::/0 52820 cloudgateway 206 0}]")
	expect(t, "rules", len(s.rules), 20)
	expect(t, "owned rules", len(s.ownedRules(fixed)), 15)
	expect(t, "mesh rule", fmt.Sprintf("%+v", s.rules[2]), "{Family:4 Priority:30203 Src:invalid Prefix Dst:10.0.0.0/16 Not:false FwMark:0 Table:52820 Suppress:false Protocol:206 Limited:false}")
	expect(t, "link-local rule", fmt.Sprintf("%+v", s.rules[5]), "{Family:4 Priority:30205 Src:invalid Prefix Dst:169.254.0.0/16 Not:false FwMark:0 Table:254 Suppress:false Protocol:206 Limited:false}")
	expect(t, "tunnel rule", fmt.Sprintf("%+v", s.rules[9]), "{Family:4 Priority:30220 Src:invalid Prefix Dst:invalid Prefix Not:true FwMark:52820 Table:52820 Suppress:false Protocol:206 Limited:false}")
	expect(t, "main default protocol", s.routes[1].Protocol, 16)
	expect(t, "nft", fmt.Sprint(s.nftTables), "[ip filter ip6 filter inet cloudgateway_client]")
	expect(t, "fwmark", s.wgMark, uint32(FwMark))
	expect(t, "peer", fmt.Sprint(s.peers), "[{xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg= 203.0.113.10:51820 [0.0.0.0/0 ::/0] "+time.Unix(1793016000, 0).String()+"}]")
	expect(t, "resolver dns", fmt.Sprint(s.resolver.dns), "[{2 192.168.64.1} {3 10.0.0.1} {3 fd42:42:42::1}]")
	expect(t, "resolver domains", fmt.Sprint(s.resolver.domains), "[{3 . true} {3 corp.example false}]")
	expect(t, "default route", s.resolver.defaultRoute, true)
}

func TestSamplesMapToConnectedFull(t *testing.T) {
	journal := &Journal{
		Version: JournalVersion, Phase: PhaseApplied, ProfileID: "uid/us-sanjose-1/client-5", Mode: ModeFull,
		Host: "us-sanjose-1.vpn.example.com", Endpoint: netip.MustParseAddrPort("203.0.113.10:51820"), PeerKey: testPeerKey,
		Addresses:  testProfile(ModeFull, 5).Addresses,
		AllowedIPs: fullIPs,
		DNS:        testProfile(ModeFull, 5).DNS,
		Search:     []string{"corp.example"},
		MTU:        1420,
		Resources:  fixed,
	}
	m := New(Options{Executor: samples, Journal: journal})

	obs, err := m.Observe(ctx)

	if err != nil {
		t.Fatal(err)
	}
	expect(t, "state", obs.State, StateConnected)
	expect(t, "mode", obs.ActiveMode, ModeFull)
	expect(t, "handshake", obs.LatestHandshake.Unix(), int64(1793016000))
}

func TestParseRulesWithNamesAndForeignMarks(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "ip-rule-show-tailscale.json"))
	if err != nil {
		t.Fatal(err)
	}

	rules, err := parseRules(data, 4)

	if err != nil {
		t.Fatal(err)
	}
	expect(t, "count", len(rules), 7)
	expect(t, "bypass", fmt.Sprintf("%+v", rules[1]), "{Family:4 Priority:5210 Src:invalid Prefix Dst:invalid Prefix Not:false FwMark:524288 Table:254 Suppress:false Protocol:0 Limited:false}")
	expect(t, "unreachable has no table", rules[3].Table, 0)
	expect(t, "named table", rules[4].Table, 52)
	s := &snapshot{rules: rules}
	expect(t, "owned", len(s.ownedRules(fixed)), 0)
}

func TestParseRouteGet(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "ip-route-get.json"))
	if err != nil {
		t.Fatal(err)
	}
	routes, err := parseRoutes(data, 4)
	if err != nil {
		t.Fatal(err)
	}
	expect(t, "route", fmt.Sprint(routes), "[{203.0.113.10/32 254 enp0s1 3 0}]")

	routes, err = parseRoutes([]byte(`[{"dst":"203.0.113.10","gateway":"192.168.64.1","dev":"enp0s1","prefsrc":"192.168.64.5","mark":"0xce54","metrics":[{"mtu":1400}],"flags":[],"uid":0,"cache":[]}]`), 4)
	if err != nil {
		t.Fatal(err)
	}
	expect(t, "route MTU", routes[0].MTU, 1400)
}

func TestParseEmptyOutput(t *testing.T) {
	rules, err := parseRules([]byte("\n"), 6)
	if err != nil || len(rules) != 0 {
		t.Fatalf("rules = %v, err = %v", rules, err)
	}
	if _, err := parseLinks([]byte("[{")); err == nil {
		t.Fatal("parsed truncated JSON")
	}
}
