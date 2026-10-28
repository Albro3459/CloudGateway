// Package networktest simulates the kernel, nftables, WireGuard, and
// systemd-resolved state behind network.Executor, so tests can drive the real
// network package on any OS. It answers only the invocations that package makes,
// in iproute2 6.x and busctl --json=short shapes. Production code must not import it
package networktest

import (
	"context"
	"fmt"
	"io/fs"
	"net/netip"
	"slices"
	"strings"
	"sync"
	"time"
)

type Link struct {
	Index    int
	Name     string
	Kind     string
	Alias    string
	MTU      int
	Up       bool
	Loopback bool
	Addrs    []Addr
	// WireGuard is set once wg setconf configures a wireguard link
	WireGuard *WireGuard
}

type Addr struct {
	Prefix netip.Prefix
	// Scope is global, link, or host
	Scope string
}

type Route struct {
	Dst      netip.Prefix
	Table    int
	Dev      string
	Gateway  netip.Addr
	Protocol int
	// Type is empty for unicast
	Type string
	MTU  int
}

type Rule struct {
	Family   int
	Priority int
	// Src and Dst are the zero prefix for all
	Src    netip.Prefix
	Dst    netip.Prefix
	Not    bool
	FwMark uint32
	FwMask uint32
	Table  int
	// Suppress means suppress_prefixlength SuppressLength
	Suppress       bool
	SuppressLength int
	Protocol       int
	// Selector adds one printed key, such as "oif" or "uid_start", with SelectorValue.
	// RouteVia treats any selector but iif lo as not matching host traffic
	Selector      string
	SelectorValue any
}

type WireGuard struct {
	FwMark     uint32
	PeerKey    string
	Endpoint   netip.AddrPort
	AllowedIPs []netip.Prefix
	Handshake  time.Time
}

// Call is one recorded invocation
type Call struct {
	Tool  string
	Args  []string
	Stdin []byte
}

// Has reports whether args appear in order and next to each other
func (c Call) Has(args ...string) bool {
	for i := 0; i+len(args) <= len(c.Args); i++ {
		if slices.Equal(c.Args[i:i+len(args)], args) {
			return true
		}
	}
	return false
}

func (c Call) String() string { return c.Tool + " " + strings.Join(c.Args, " ") }

// Match selects calls to tool whose arguments contain args in order
func Match(tool string, args ...string) func(Call) bool {
	return func(c Call) bool { return c.Tool == tool && c.Has(args...) }
}

// ExitError is a simulated nonzero exit. Like the real executor, it never carries output
type ExitError struct {
	Call   Call
	Reason string
}

func (e *ExitError) Error() string { return fmt.Sprintf("networktest: %s: %s", e.Call, e.Reason) }

type resolvedLink struct {
	dns          []netip.Addr
	domains      []string
	defaultRoute *bool
}

type hook struct {
	match func(Call) bool
	fn    func()
}

// Host is safe for concurrent use. Hooks run after the call returns its lock,
// so they may call back into the network package
type Host struct {
	mu            sync.Mutex
	links         []*Link
	routes        []Route
	rules         []Rule
	nft           map[string]string
	resolved      bool
	resolvedLinks map[int]*resolvedLink
	globalDNS     []netip.Addr
	globalDomains []string
	files         map[string]string
	missing       map[string]bool
	calls         []Call
	failures      []func(Call) bool
	hooks         []hook
	nextIndex     int
}

const resolvConfStub = "# This is /run/systemd/resolve/stub-resolv.conf managed by man:systemd-resolved(8).\nnameserver 127.0.0.53\noptions edns0 trust-ad\nsearch .\n"

// New returns a host with only loopback, the kernel's default rules, the
// WireGuard module, IPv6 enabled, and systemd-resolved behind its stub
func New() *Host {
	h := &Host{
		nft:           map[string]string{},
		resolved:      true,
		resolvedLinks: map[int]*resolvedLink{},
		files: map[string]string{
			"/proc/sys/net/ipv6/conf/all/disable_ipv6":     "0\n",
			"/proc/sys/net/ipv6/conf/default/disable_ipv6": "0\n",
			"/proc/sys/net/ipv4/conf/all/src_valid_mark":   "0\n",
			"/proc/sys/kernel/osrelease":                   "6.8.0-45-generic\n",
			"/sys/module/wireguard/version":                "1.0.0\n",
			"/etc/resolv.conf":                             resolvConfStub,
		},
		missing:   map[string]bool{},
		nextIndex: 1,
	}
	h.AddLink(Link{Name: "lo", MTU: 65536, Up: true, Loopback: true})
	h.AddAddress("lo", netip.MustParsePrefix("127.0.0.1/8"), "host")
	h.AddAddress("lo", netip.MustParsePrefix("::1/128"), "host")
	for _, family := range []int{4, 6} {
		h.rules = append(h.rules, Rule{Family: family, Priority: 0, Table: 255}, Rule{Family: family, Priority: 32766, Table: 254})
	}
	h.rules = append(h.rules, Rule{Family: 4, Priority: 32767, Table: 253})
	return h
}

// NewUbuntu returns a dual-stack Ubuntu Server VM: enp0s1 with DHCP IPv4 and
// SLAAC IPv6, resolved using the DHCP server for DNS, and the iptables-nft
// filter tables UFW creates
func NewUbuntu() *Host {
	h := New()
	h.AddLink(Link{Name: "enp0s1", MTU: 1500, Up: true})
	h.AddAddress("enp0s1", netip.MustParsePrefix("192.168.64.5/24"), "global")
	h.AddAddress("enp0s1", netip.MustParsePrefix("2001:db8:1::5/64"), "global")
	h.AddAddress("enp0s1", netip.MustParsePrefix("fe80::5054:ff:fe12:3456/64"), "link")
	h.AddRoute(Route{Dst: netip.MustParsePrefix("0.0.0.0/0"), Table: 254, Dev: "enp0s1", Gateway: netip.MustParseAddr("192.168.64.1"), Protocol: 16})
	h.AddRoute(Route{Dst: netip.MustParsePrefix("192.168.64.1/32"), Table: 254, Dev: "enp0s1", Protocol: 16})
	h.AddRoute(Route{Dst: netip.MustParsePrefix("::/0"), Table: 254, Dev: "enp0s1", Gateway: netip.MustParseAddr("fe80::1"), Protocol: 9})
	h.SetLinkDNS("enp0s1", netip.MustParseAddr("192.168.64.1"))
	h.AddNftTable("ip", "filter")
	h.AddNftTable("ip6", "filter")
	return h
}

// AddLink returns the new ifindex
func (h *Host) AddLink(l Link) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.addLink(l)
}

func (h *Host) addLink(l Link) int {
	l.Index = h.nextIndex
	h.nextIndex++
	h.links = append(h.links, &l)
	return l.Index
}

// SetLinkMTU follows the kernel, which removes IPv6 from a link below 1280
func (h *Host) SetLinkMTU(name string, mtu int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.setMTU(h.link(name), mtu)
}

// SetLinkDown sets the link administratively down. Like the kernel, it drops the
// link's routes and IPv6 addresses
func (h *Host) SetLinkDown(name string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	l := h.link(name)
	l.Up = false
	l.Addrs = slices.DeleteFunc(l.Addrs, func(a Addr) bool { return a.Prefix.Addr().Is6() })
	h.routes = slices.DeleteFunc(h.routes, func(r Route) bool { return r.Dev == name })
}

func (h *Host) RemoveLink(name string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.deleteLink(name)
}

// AddAddress also adds the kernel's local and prefix routes
func (h *Host) AddAddress(link string, prefix netip.Prefix, scope string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if err := h.addAddress(link, prefix, scope); err != nil {
		panic(err)
	}
}

// RemoveAddress models a DHCP lease change and drops the kernel routes with it
func (h *Host) RemoveAddress(link string, prefix netip.Prefix) {
	h.mu.Lock()
	defer h.mu.Unlock()
	l := h.link(link)
	if l == nil {
		return
	}
	l.Addrs = slices.DeleteFunc(l.Addrs, func(a Addr) bool { return a.Prefix == prefix })
	h.routes = slices.DeleteFunc(h.routes, func(r Route) bool {
		return r.Dev == link && r.Protocol == 2 && (r.Dst == netip.PrefixFrom(prefix.Addr(), prefix.Addr().BitLen()) || r.Dst == prefix.Masked())
	})
}

func (h *Host) AddRoute(r Route) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.routes = append(h.routes, r)
}

// RemoveRoutes returns how many matched, as when networkd drops foreign routes
func (h *Host) RemoveRoutes(match func(Route) bool) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	before := len(h.routes)
	h.routes = slices.DeleteFunc(h.routes, match)
	return before - len(h.routes)
}

func (h *Host) AddRule(r Rule) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.rules = append(h.rules, r)
}

// RemoveRules returns how many matched, as when networkd drops foreign rules on netplan apply
func (h *Host) RemoveRules(match func(Rule) bool) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	before := len(h.rules)
	h.rules = slices.DeleteFunc(h.rules, match)
	return before - len(h.rules)
}

func (h *Host) AddNftTable(family, name string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.nft[family+" "+name] = ""
}

// FlushNftRuleset removes every table, as a restart of nftables.service does
func (h *Host) FlushNftRuleset() {
	h.mu.Lock()
	defer h.mu.Unlock()
	clear(h.nft)
}

// FlushNftTable empties every chain in "family name" and keeps the chains
func (h *Host) FlushNftTable(name string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	var kept []string
	chain := false
	for line := range strings.Lines(h.nft[name]) {
		trimmed := strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(trimmed, "chain "):
			chain = true
		case trimmed == "}":
			chain = false
		case chain && !strings.HasPrefix(trimmed, "type "):
			continue
		}
		kept = append(kept, strings.TrimSuffix(line, "\n"))
	}
	h.nft[name] = strings.Join(kept, "\n")
}

// SetResolverActive stops or starts systemd-resolved. Stopping it keeps link settings
func (h *Host) SetResolverActive(active bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.resolved = active
}

func (h *Host) SetLinkDNS(link string, addrs ...netip.Addr) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.resolvedLink(h.link(link).Index).dns = addrs
}

// SetLinkDomains takes resolvectl domain syntax, where ~ marks a routing-only domain
func (h *Host) SetLinkDomains(link string, domains ...string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.resolvedLink(h.link(link).Index).domains = domains
}

func (h *Host) SetGlobalDNS(addrs ...netip.Addr) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.globalDNS = addrs
}

func (h *Host) SetGlobalDomains(domains ...string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.globalDomains = domains
}

// RevertLink drops resolved's settings for the link, as a competing manager can
func (h *Host) RevertLink(link string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if l := h.link(link); l != nil {
		delete(h.resolvedLinks, l.Index)
	}
}

func (h *Host) SetFile(name, content string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.files[name] = content
}

func (h *Host) RemoveFile(name string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.files, name)
}

func (h *Host) RemoveTool(tool string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.missing[tool] = true
}

// SetHandshake sets the latest handshake of a configured WireGuard link
func (h *Host) SetHandshake(link string, at time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.link(link).WireGuard.Handshake = at
}

// FailWhen makes matching calls exit nonzero without changing state
func (h *Host) FailWhen(match func(Call) bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.failures = append(h.failures, match)
}

// ClearFailures removes every FailWhen
func (h *Host) ClearFailures() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.failures = nil
}

// RouteVia returns the link a locally generated packet from src to dst takes,
// or "" when no rule finds a route. An invalid src is an unbound socket. It
// walks rules like the kernel: by priority, with not inverting the whole
// selector set, then the longest matching route in the rule's table, which a
// suppress length at least as long as its prefix skips
func (h *Host) RouteVia(src, dst netip.Addr, mark uint32) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	family := addrFamily(dst)
	rules := slices.Clone(h.rules)
	slices.SortStableFunc(rules, func(a, b Rule) int { return a.Priority - b.Priority })
	for _, r := range rules {
		if r.Family != family || r.Table == 255 {
			continue
		}
		match := (!r.Src.IsValid() || src.IsValid() && r.Src.Contains(src)) && (!r.Dst.IsValid() || r.Dst.Contains(dst)) && (r.FwMark == 0 || r.FwMark == mark) &&
			(r.Selector == "" || r.Selector == "iif" && r.SelectorValue == "lo")
		if match == r.Not {
			continue
		}
		var best *Route
		for i, route := range h.routes {
			if route.Table == r.Table && route.Type == "" && route.Dst.Contains(dst) && (best == nil || route.Dst.Bits() > best.Dst.Bits()) {
				best = &h.routes[i]
			}
		}
		if best == nil || r.Suppress && best.Dst.Bits() <= r.SuppressLength {
			continue
		}
		return best.Dev
	}
	return ""
}

// After runs fn once a matching call succeeds
func (h *Host) After(match func(Call) bool, fn func()) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.hooks = append(h.hooks, hook{match: match, fn: fn})
}

func (h *Host) Calls() []Call {
	h.mu.Lock()
	defer h.mu.Unlock()
	return slices.Clone(h.calls)
}

func (h *Host) ResetCalls() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.calls = nil
}

// Link returns a copy
func (h *Host) Link(name string) (Link, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	l := h.link(name)
	if l == nil {
		return Link{}, false
	}
	copied := *l
	copied.Addrs = slices.Clone(l.Addrs)
	if l.WireGuard != nil {
		wg := *l.WireGuard
		copied.WireGuard = &wg
	}
	return copied, true
}

func (h *Host) Routes() []Route {
	h.mu.Lock()
	defer h.mu.Unlock()
	return slices.Clone(h.routes)
}

func (h *Host) Rules() []Rule {
	h.mu.Lock()
	defer h.mu.Unlock()
	return slices.Clone(h.rules)
}

// NftTables lists tables as "family name", sorted
func (h *Host) NftTables() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	var names []string
	for name := range h.nft {
		names = append(names, name)
	}
	slices.Sort(names)
	return names
}

// NftTable returns the body last loaded for "family name"
func (h *Host) NftTable(name string) (string, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	body, ok := h.nft[name]
	return body, ok
}

// Resolver returns resolved's DNS servers, domains, and DefaultRoute for a link
func (h *Host) Resolver(link string) (dns []netip.Addr, domains []string, defaultRoute bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	l := h.link(link)
	if l == nil {
		return nil, nil, false
	}
	r := h.resolvedLinks[l.Index]
	if r == nil {
		return nil, nil, h.defaultRoute(l.Index)
	}
	return slices.Clone(r.dns), slices.Clone(r.domains), h.defaultRoute(l.Index)
}

func (h *Host) File(name string) (string, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	content, ok := h.files[name]
	return content, ok
}

// Run implements network.Executor
func (h *Host) Run(_ context.Context, tool string, args []string, stdin []byte) ([]byte, error) {
	call := Call{Tool: tool, Args: slices.Clone(args), Stdin: slices.Clone(stdin)}
	h.mu.Lock()
	h.calls = append(h.calls, call)
	if h.missing[tool] {
		h.mu.Unlock()
		return nil, &ExitError{Call: call, Reason: "not installed"}
	}
	for _, fail := range h.failures {
		if fail(call) {
			h.mu.Unlock()
			return nil, &ExitError{Call: call, Reason: "injected failure"}
		}
	}
	out, err := h.dispatch(call)
	var after []func()
	if err == nil {
		for _, hk := range h.hooks {
			if hk.match(call) {
				after = append(after, hk.fn)
			}
		}
	}
	h.mu.Unlock()
	if err != nil {
		return nil, &ExitError{Call: call, Reason: err.Error()}
	}
	for _, fn := range after {
		fn()
	}
	return out, nil
}

func (h *Host) Available(tool string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return !h.missing[tool]
}

func (h *Host) ReadFile(name string) ([]byte, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	content, ok := h.files[name]
	if !ok {
		return nil, &fs.PathError{Op: "open", Path: name, Err: fs.ErrNotExist}
	}
	return []byte(content), nil
}

// WriteFile only replaces existing files, like writes under /proc/sys
func (h *Host) WriteFile(name string, data []byte) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.files[name]; !ok {
		return &fs.PathError{Op: "open", Path: name, Err: fs.ErrNotExist}
	}
	h.files[name] = string(data)
	return nil
}

func (h *Host) dispatch(c Call) ([]byte, error) {
	switch c.Tool {
	case "ip":
		return h.ip(c.Args)
	case "wg":
		return h.wg(c.Args, c.Stdin)
	case "nft":
		return h.nftRun(c.Args, c.Stdin)
	case "resolvectl":
		return nil, h.resolvectl(c.Args)
	case "busctl":
		return h.busctl(c.Args)
	}
	return nil, fmt.Errorf("unknown tool")
}

func (h *Host) link(name string) *Link {
	for _, l := range h.links {
		if l.Name == name {
			return l
		}
	}
	return nil
}

func (h *Host) deleteLink(name string) {
	l := h.link(name)
	if l == nil {
		return
	}
	h.links = slices.DeleteFunc(h.links, func(other *Link) bool { return other == l })
	h.routes = slices.DeleteFunc(h.routes, func(r Route) bool { return r.Dev == name })
	delete(h.resolvedLinks, l.Index)
}

func (h *Host) addAddress(link string, prefix netip.Prefix, scope string) error {
	l := h.link(link)
	if l == nil {
		return fmt.Errorf("Cannot find device %q", link)
	}
	for _, a := range l.Addrs {
		if a.Prefix.Addr() == prefix.Addr() {
			return fmt.Errorf("RTNETLINK answers: File exists")
		}
	}
	if prefix.Addr().Is6() && l.MTU < 1280 {
		return fmt.Errorf("RTNETLINK answers: Permission denied")
	}
	l.Addrs = append(l.Addrs, Addr{Prefix: prefix, Scope: scope})
	h.addKernelRoutes(l)
	return nil
}

// addKernelRoutes adds the local and prefix routes the kernel keeps for a link's addresses
func (h *Host) addKernelRoutes(l *Link) {
	for _, a := range l.Addrs {
		routes := []Route{{Dst: netip.PrefixFrom(a.Prefix.Addr(), a.Prefix.Addr().BitLen()), Table: 255, Dev: l.Name, Protocol: 2, Type: "local"}}
		if !l.Loopback && (a.Prefix.Addr().Is6() || a.Prefix.Bits() < 32) {
			routes = append(routes, Route{Dst: a.Prefix.Masked(), Table: 254, Dev: l.Name, Protocol: 2})
		}
		for _, r := range routes {
			if !slices.Contains(h.routes, r) {
				h.routes = append(h.routes, r)
			}
		}
	}
}

func (h *Host) setMTU(l *Link, mtu int) {
	l.MTU = mtu
	if mtu < 1280 {
		l.Addrs = slices.DeleteFunc(l.Addrs, func(a Addr) bool { return a.Prefix.Addr().Is6() })
		h.routes = slices.DeleteFunc(h.routes, func(r Route) bool { return r.Dev == l.Name && r.Dst.Addr().Is6() })
	}
}

func (h *Host) resolvedLink(index int) *resolvedLink {
	r := h.resolvedLinks[index]
	if r == nil {
		r = &resolvedLink{}
		h.resolvedLinks[index] = r
	}
	return r
}

// defaultRoute follows resolved: explicit when set, else true unless the link has a routing-only domain
func (h *Host) defaultRoute(index int) bool {
	r := h.resolvedLinks[index]
	if r == nil {
		return true
	}
	if r.defaultRoute != nil {
		return *r.defaultRoute
	}
	return !slices.ContainsFunc(r.domains, func(d string) bool { return strings.HasPrefix(d, "~") })
}
