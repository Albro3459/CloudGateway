package network

import (
	"context"
	"encoding/binary"
	"fmt"
	"net/netip"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network/networktest"
)

// Keys from the wg(8) examples
const (
	testPrivateKey   = "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
	testPeerKey      = "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg="
	testPresharedKey = "TrMvSoP4jYQlY6RIzBgbssQqY3vxI2Pi+y71lOWWXX0="
)

var (
	ctx        = context.Background()
	serverAddr = netip.MustParseAddr("203.0.113.10")
	meshIPs    = []netip.Prefix{netip.MustParsePrefix("10.0.0.0/16"), netip.MustParsePrefix("fd42:42:42::/48")}
	fullIPs    = []netip.Prefix{netip.MustParsePrefix("0.0.0.0/0"), netip.MustParsePrefix("::/0")}
)

// testProfile is client host in us-sanjose-1, such as 10.0.0.5 for host 5
func testProfile(mode Mode, host int) Profile {
	allowed := meshIPs
	if mode == ModeFull {
		allowed = fullIPs
	}
	p := Profile{
		ID:            fmt.Sprintf("uid/us-sanjose-1/client-%d", host),
		ConfigHash:    fmt.Sprintf("hash-%d", host),
		Mode:          mode,
		Addresses:     []netip.Prefix{netip.MustParsePrefix(fmt.Sprintf("10.0.0.%d/32", host)), netip.MustParsePrefix(fmt.Sprintf("fd42:42:42::%d/128", host))},
		DNS:           []netip.Addr{netip.MustParseAddr("10.0.0.1"), netip.MustParseAddr("fd42:42:42::1")},
		SearchDomains: []string{"corp.example"},
		PeerPublicKey: testPeerKey,
		AllowedIPs:    allowed,
		EndpointHost:  "us-sanjose-1.vpn.example.com",
		EndpointPort:  51820,
	}
	// Shaped like wgconfig.Config.SetConf
	p.SetConf = func(endpoint netip.AddrPort, fwmark uint32) ([]byte, error) {
		var b strings.Builder
		fmt.Fprintf(&b, "[Interface]\nPrivateKey = %s\n", testPrivateKey)
		if fwmark != 0 {
			fmt.Fprintf(&b, "FwMark = 0x%x\n", fwmark)
		}
		values := make([]string, len(allowed))
		for i, prefix := range allowed {
			values[i] = prefix.String()
		}
		fmt.Fprintf(&b, "\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s\nEndpoint = %s\nPersistentKeepalive = 25\n",
			testPeerKey, testPresharedKey, strings.Join(values, ", "), endpoint)
		return []byte(b.String()), nil
	}
	return p
}

type exchangeCall struct {
	server netip.AddrPort
	mark   uint32
}

type harness struct {
	t          *testing.T
	host       *networktest.Host
	m          *Manager
	now        time.Time
	server     netip.Addr
	persisted  []*Journal
	persistErr error
	lookups    []string
	exchanges  []exchangeCall
	exchangeOK bool
}

func newHarness(t *testing.T, host *networktest.Host) *harness {
	h := &harness{t: t, host: host, now: time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC), server: serverAddr, exchangeOK: true}
	h.m = New(h.options(nil))
	return h
}

// restart models a new daemon process loading journal
func (h *harness) restart(journal *Journal) {
	h.m = New(h.options(journal))
}

func (h *harness) options(journal *Journal) Options {
	return Options{
		Executor: h.host,
		Journal:  journal,
		Persist: func(j *Journal) error {
			if h.persistErr != nil {
				return h.persistErr
			}
			h.persisted = append(h.persisted, j)
			return nil
		},
		Now: func() time.Time { return h.now },
		LookupHost: func(_ context.Context, host string) ([]netip.Addr, error) {
			h.lookups = append(h.lookups, host)
			return []netip.Addr{netip.MustParseAddr("2001:db8:ffff::10"), h.server}, nil
		},
		Exchange: func(_ context.Context, server netip.AddrPort, mark uint32, query []byte) ([]byte, error) {
			h.exchanges = append(h.exchanges, exchangeCall{server: server, mark: mark})
			if !h.exchangeOK {
				return nil, context.DeadlineExceeded
			}
			return answer(query, h.server), nil
		},
	}
}

func (h *harness) lastJournal() *Journal {
	if len(h.persisted) == 0 {
		return nil
	}
	return h.persisted[len(h.persisted)-1]
}

func (h *harness) phases() []string {
	var phases []string
	for _, j := range h.persisted {
		if j == nil {
			phases = append(phases, "cleared")
		} else {
			phases = append(phases, string(j.Phase)+" "+j.ProfileID)
		}
	}
	return phases
}

func (h *harness) apply(p Profile) Observation {
	h.t.Helper()
	obs, err := h.m.Apply(ctx, p, nil)
	if err != nil {
		h.t.Fatalf("Apply: %v", err)
	}
	return obs
}

// answer builds a reply to query with one record per address of the asked type
func answer(query []byte, addrs ...netip.Addr) []byte {
	reply := slices.Clone(query)
	reply[2] |= 0x80
	qtype := binary.BigEndian.Uint16(query[len(query)-4:])
	count := 0
	for _, addr := range addrs {
		if (qtype == typeA) != addr.Is4() || qtype == typeNS {
			continue
		}
		reply = append(reply, 0xc0, 0x0c)
		reply = binary.BigEndian.AppendUint16(reply, qtype)
		reply = binary.BigEndian.AppendUint16(reply, classIN)
		reply = append(reply, 0, 0, 0x01, 0x2c)
		reply = binary.BigEndian.AppendUint16(reply, uint16(addr.BitLen()/8))
		reply = append(reply, addr.AsSlice()...)
		count++
	}
	binary.BigEndian.PutUint16(reply[6:], uint16(count))
	return reply
}

func isOwnedRule(r networktest.Rule) bool { return r.Protocol == RouteProtocol }
func isOwnedRoute(r networktest.Route) bool {
	return r.Dev == InterfaceName && r.Protocol == RouteProtocol
}

// ownedState lists every owned resource on the host, one per line
func ownedState(host *networktest.Host) string {
	var lines []string
	if l, ok := host.Link(InterfaceName); ok {
		var addrs []string
		for _, a := range l.Addrs {
			addrs = append(addrs, a.Prefix.String())
		}
		lines = append(lines, fmt.Sprintf("link %s kind=%s alias=%s mtu=%d up=%t addrs=%s", l.Name, l.Kind, l.Alias, l.MTU, l.Up, strings.Join(addrs, ",")))
		if wg := l.WireGuard; wg != nil {
			lines = append(lines, fmt.Sprintf("wg fwmark=%#x peer=%s endpoint=%s allowed=%v", wg.FwMark, wg.PeerKey, wg.Endpoint, wg.AllowedIPs))
		}
		dns, domains, defaultRoute := host.Resolver(InterfaceName)
		if len(dns) > 0 || len(domains) > 0 {
			lines = append(lines, fmt.Sprintf("resolver dns=%v domains=%v default-route=%t", dns, domains, defaultRoute))
		}
	}
	for _, r := range host.Routes() {
		if isOwnedRoute(r) {
			lines = append(lines, fmt.Sprintf("route %s table %d", r.Dst, r.Table))
		}
	}
	for _, r := range host.Rules() {
		if isOwnedRule(r) {
			src, dst := "all", "all"
			if r.Src.IsValid() {
				src = r.Src.String()
			}
			if r.Dst.IsValid() {
				dst = r.Dst.String()
			}
			suppress := "false"
			switch {
			case r.Suppress && r.SuppressLength == 0:
				suppress = "true"
			case r.Suppress:
				suppress = strconv.Itoa(r.SuppressLength)
			}
			lines = append(lines, fmt.Sprintf("rule v%d %d from=%s to=%s not=%t fwmark=%#x table=%d suppress=%s", r.Family, r.Priority, src, dst, r.Not, r.FwMark, r.Table, suppress))
		}
	}
	for _, name := range host.NftTables() {
		if name == "inet "+NftTable {
			lines = append(lines, "nft "+name)
		}
	}
	slices.Sort(lines)
	return strings.Join(lines, "\n")
}

// foreignState lists everything the package must never touch
func foreignState(host *networktest.Host) string {
	var lines []string
	for _, name := range []string{"lo", "enp0s1"} {
		l, _ := host.Link(name)
		dns, domains, defaultRoute := host.Resolver(name)
		lines = append(lines, fmt.Sprintf("%+v resolver=%v %v %t", l, dns, domains, defaultRoute))
	}
	for _, r := range host.Routes() {
		if r.Dev != InterfaceName {
			lines = append(lines, fmt.Sprintf("%+v", r))
		}
	}
	for _, r := range host.Rules() {
		if !isOwnedRule(r) {
			lines = append(lines, fmt.Sprintf("%+v", r))
		}
	}
	for _, name := range host.NftTables() {
		if name != "inet "+NftTable {
			lines = append(lines, "nft "+name)
		}
	}
	return strings.Join(lines, "\n")
}

func mutations(calls []networktest.Call) []string {
	var changed []string
	for _, c := range calls {
		switch {
		case c.Tool == "resolvectl", c.Has("-f", "-"), c.Has("setconf"), c.Has("set"), c.Has("add"), c.Has("del"):
			changed = append(changed, c.String())
		}
	}
	return changed
}

func expect[T comparable](t *testing.T, name string, got, want T) {
	t.Helper()
	if got != want {
		t.Fatalf("%s = %v, want %v", name, got, want)
	}
}

func expectText(t *testing.T, name, got, want string) {
	t.Helper()
	if got != want {
		t.Fatalf("%s:\n%s\nwant:\n%s", name, got, want)
	}
}
