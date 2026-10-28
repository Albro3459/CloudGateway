package network

import (
	"fmt"
	"net/netip"
	"slices"
	"strconv"
	"strings"
)

type routeKey struct {
	Dst   netip.Prefix
	Table int
}

func (r route) key() routeKey { return routeKey{Dst: r.Dst, Table: r.Table} }

// ruleKey is a whole owned rule, so one with the right selectors and a stale
// action, as an older release installed, counts as drift
type ruleKey struct {
	Family   int
	Priority int
	// Src is set only for source rules
	Src netip.Addr
	// Dst is set only for mesh and local rules
	Dst    netip.Prefix
	Not    bool
	FwMark uint32
	Table  int
	// Suppress is -1 without suppress_prefixlength
	Suppress int
}

func (r rule) key() ruleKey {
	k := ruleKey{Family: r.Family, Priority: r.Priority, Dst: r.Dst, Not: r.Not, FwMark: r.FwMark, Table: r.Table, Suppress: r.SuppressLength}
	if r.Src.IsValid() {
		k.Src = r.Src.Addr()
	}
	return k
}

func (k ruleKey) String() string {
	switch {
	case k.Src.IsValid():
		return fmt.Sprintf("rule %d from %s", k.Priority, k.Src)
	case k.Dst.IsValid():
		return fmt.Sprintf("rule %d to %s", k.Priority, k.Dst)
	}
	return fmt.Sprintf("rule %d ipv%d", k.Priority, k.Family)
}

func addrFamily(addr netip.Addr) int {
	if addr.Is4() {
		return 4
	}
	return 6
}

func familyFlag(family int) string { return "-" + strconv.Itoa(family) }

// desiredRoutes covers every non-default allowed IP in main, plus Full's
// default routes in the owned table for both families
func desiredRoutes(j *Journal) []routeKey {
	var routes []routeKey
	for _, prefix := range j.AllowedIPs {
		if prefix.Bits() > 0 {
			routes = append(routes, routeKey{Dst: prefix, Table: mainTable})
		}
	}
	if j.Mode == ModeFull {
		routes = append(routes,
			routeKey{Dst: netip.MustParsePrefix("0.0.0.0/0"), Table: j.Resources.Table},
			routeKey{Dst: netip.MustParsePrefix("::/0"), Table: j.Resources.Table})
	}
	return routes
}

// tunnelPrefixes are the mesh ranges plus every VPN DNS address outside them,
// which a local rule or a specific main route would otherwise send outside the tunnel
func tunnelPrefixes(dns []netip.Addr) []netip.Prefix {
	prefixes := slices.Clone(meshPrefixes)
	for _, addr := range dns {
		host := netip.PrefixFrom(addr, addr.BitLen())
		if !slices.ContainsFunc(prefixes, func(prefix netip.Prefix) bool { return covers(prefix, host) }) {
			prefixes = append(prefixes, host)
		}
	}
	return prefixes
}

// desiredRules lists Full's rules in install order, so the rules keeping
// traffic outside the tunnel exist before the tunnel rule captures it
func desiredRules(j *Journal, physical []netip.Addr) []ruleKey {
	if j.Mode != ModeFull {
		return nil
	}
	res := j.Resources
	main := func(family, priority int) ruleKey {
		return ruleKey{Family: family, Priority: priority, Table: mainTable, Suppress: -1}
	}
	var rules []ruleKey
	for _, addr := range physical {
		r := main(addrFamily(addr), res.SourcePriority)
		r.Src = addr
		rules = append(rules, r)
	}
	for _, family := range []int{4, 6} {
		// WireGuard's packets and the outside endpoint lookup skip every tunnel rule.
		// not would invert the whole selector set, so this matches the mark directly
		r := main(family, res.MarkPriority)
		r.FwMark = res.FwMark
		rules = append(rules, r)
	}
	for _, prefix := range meshPrefixes {
		// A local subnet more specific than the mesh range keeps its main route, as before Full started
		r := main(addrFamily(prefix.Addr()), res.MeshLocalPriority)
		r.Dst, r.Suppress = prefix, prefix.Bits()
		rules = append(rules, r)
	}
	for _, prefix := range tunnelPrefixes(j.DNS) {
		rules = append(rules, ruleKey{Family: addrFamily(prefix.Addr()), Priority: res.MeshPriority, Dst: prefix, Table: res.Table, Suppress: -1})
	}
	for _, prefix := range localPrefixes {
		r := main(addrFamily(prefix.Addr()), res.LocalPriority)
		r.Dst = prefix
		rules = append(rules, r)
	}
	for _, family := range []int{4, 6} {
		r := main(family, res.SuppressPriority)
		r.Suppress = 0
		rules = append(rules, r)
	}
	for _, family := range []int{4, 6} {
		rules = append(rules, ruleKey{Family: family, Priority: res.TunnelPriority, Not: true, FwMark: res.FwMark, Table: res.Table, Suppress: -1})
	}
	return rules
}

func diffRoutes(s *snapshot, j *Journal) (missing, extra []routeKey) {
	want := desiredRoutes(j)
	have := map[routeKey]bool{}
	for _, r := range s.ownedRoutes(j.Resources) {
		have[r.key()] = true
		if !slices.Contains(want, r.key()) {
			extra = append(extra, r.key())
		}
	}
	for _, r := range want {
		if !have[r] {
			missing = append(missing, r)
		}
	}
	return missing, extra
}

// diffRules returns extra rules from the highest priority down, so the tunnel
// rule goes before the rules that keep traffic out of it
func diffRules(s *snapshot, j *Journal) (missing, extra []ruleKey) {
	want := desiredRules(j, s.physicalAddrs(j.Resources))
	have := map[ruleKey]bool{}
	for _, r := range s.ownedRules(j.Resources) {
		have[r.key()] = true
		if !slices.Contains(want, r.key()) {
			extra = append(extra, r.key())
		}
	}
	for _, r := range want {
		if !have[r] {
			missing = append(missing, r)
		}
	}
	slices.SortStableFunc(extra, func(a, b ruleKey) int { return b.Priority - a.Priority })
	return missing, extra
}

func routeCommand(res Resources, verb string, r routeKey) command {
	return ipCommand(familyFlag(addrFamily(r.Dst.Addr())), "route", verb, r.Dst.String(), "dev", res.Interface,
		"table", strconv.Itoa(r.Table), "proto", strconv.Itoa(res.Protocol))
}

func ruleAddCommand(res Resources, r ruleKey) command {
	return ipCommand(append(ruleArgs("add", r), "protocol", strconv.Itoa(res.Protocol))...)
}

// ruleDelCommand selects by protocol too, so the kernel never matches a foreign
// rule, and by the whole rule, since several share one priority
func ruleDelCommand(res Resources, r ruleKey) command {
	return ipCommand(append(ruleArgs("del", r), "protocol", strconv.Itoa(res.Protocol))...)
}

func ruleArgs(verb string, r ruleKey) []string {
	args := []string{familyFlag(r.Family), "rule", verb, "priority", strconv.Itoa(r.Priority)}
	if r.Not {
		args = append(args, "not")
	}
	if r.Src.IsValid() {
		args = append(args, "from", r.Src.String())
	}
	if r.Dst.IsValid() {
		args = append(args, "to", r.Dst.String())
	}
	if r.FwMark != 0 {
		args = append(args, "fwmark", fmt.Sprintf("%#x", r.FwMark))
	}
	table := strconv.Itoa(r.Table)
	if r.Table == mainTable {
		table = "main"
	}
	args = append(args, "lookup", table)
	if r.Suppress >= 0 {
		args = append(args, "suppress_prefixlength", strconv.Itoa(r.Suppress))
	}
	return args
}

func resolverCommands(res Resources, dns []netip.Addr, search []string) []command {
	dnsArgs := []string{"dns", res.Interface}
	for _, addr := range dns {
		dnsArgs = append(dnsArgs, addr.String())
	}
	return []command{
		{tool: ToolResolvectl, args: dnsArgs},
		{tool: ToolResolvectl, args: append([]string{"domain", res.Interface, "~."}, search...)},
		{tool: ToolResolvectl, args: []string{"default-route", res.Interface, "yes"}},
	}
}

// nftScript recreates the owned table in one transaction. The leading add makes
// the delete valid when the table is absent. Drift checks compare only chain
// names and rule counts, so rename a chain when a release changes its rules,
// and a tunnel an older release left running gets the new rules on reconcile
func nftScript(res Resources, addrs []netip.Prefix, full bool) command {
	var b strings.Builder
	fmt.Fprintf(&b, "table inet %[1]s\ndelete table inet %[1]s\ntable inet %[1]s {\n", res.NftTable)
	b.WriteString("\tchain preraw {\n\t\ttype filter hook prerouting priority -300; policy accept;\n")
	for _, prefix := range addrs {
		family := "ip"
		if prefix.Addr().Is6() {
			family = "ip6"
		}
		fmt.Fprintf(&b, "\t\tiifname != %q %s daddr %s fib saddr type != local drop\n", res.Interface, family, prefix.Addr())
	}
	b.WriteString("\t}\n")
	if full {
		b.WriteString("\tchain premangle {\n\t\ttype filter hook prerouting priority -150; policy accept;\n")
		// Only WireGuard's own mark is restored, so marks other tools set stay
		fmt.Fprintf(&b, "\t\tmeta l4proto udp ct mark %#[1]x meta mark set %#[1]x\n\t}\n", res.FwMark)
		b.WriteString("\tchain postmangle {\n\t\ttype filter hook postrouting priority -150; policy accept;\n")
		fmt.Fprintf(&b, "\t\tmeta l4proto udp meta mark %#x ct mark set meta mark\n\t}\n", res.FwMark)
	}
	b.WriteString("}\n")
	return command{tool: ToolNft, args: []string{"-f", "-"}, stdin: []byte(b.String())}
}

func nftDeleteScript(res Resources) command {
	script := fmt.Sprintf("table inet %[1]s\ndelete table inet %[1]s\n", res.NftTable)
	return command{tool: ToolNft, args: []string{"-f", "-"}, stdin: []byte(script)}
}
