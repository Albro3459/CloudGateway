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

type ruleKey struct {
	Family   int
	Priority int
	// Src is set only for source rules
	Src netip.Addr
	// Dst is set only for mesh and local rules
	Dst netip.Prefix
}

func (r rule) key() ruleKey {
	k := ruleKey{Family: r.Family, Priority: r.Priority, Dst: r.Dst}
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

// tunnelPrefixes are the mesh ranges plus any VPN DNS address the local rules
// would otherwise send outside the tunnel
func tunnelPrefixes(dns []netip.Addr) []netip.Prefix {
	prefixes := slices.Clone(meshPrefixes)
	for _, addr := range dns {
		host := netip.PrefixFrom(addr, addr.BitLen())
		local := slices.ContainsFunc(localPrefixes, func(prefix netip.Prefix) bool { return prefix.Contains(addr) })
		if local && !slices.ContainsFunc(prefixes, func(prefix netip.Prefix) bool { return covers(prefix, host) }) {
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
	var rules []ruleKey
	for _, addr := range physical {
		rules = append(rules, ruleKey{Family: addrFamily(addr), Priority: res.SourcePriority, Src: addr})
	}
	for _, prefix := range meshPrefixes {
		rules = append(rules, ruleKey{Family: addrFamily(prefix.Addr()), Priority: res.MeshLocalPriority, Dst: prefix})
	}
	for _, prefix := range tunnelPrefixes(j.DNS) {
		rules = append(rules, ruleKey{Family: addrFamily(prefix.Addr()), Priority: res.MeshPriority, Dst: prefix})
	}
	for _, prefix := range localPrefixes {
		rules = append(rules, ruleKey{Family: addrFamily(prefix.Addr()), Priority: res.LocalPriority, Dst: prefix})
	}
	for _, priority := range []int{res.SuppressPriority, res.TunnelPriority} {
		for _, family := range []int{4, 6} {
			rules = append(rules, ruleKey{Family: family, Priority: priority})
		}
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
	args := []string{familyFlag(r.Family), "rule", "add", "priority", strconv.Itoa(r.Priority)}
	switch r.Priority {
	case res.SourcePriority:
		args = append(args, "from", r.Src.String(), "lookup", "main")
	case res.MeshLocalPriority:
		// A local subnet more specific than the mesh range keeps its main route, as before Full started
		args = append(args, "to", r.Dst.String(), "lookup", "main", "suppress_prefixlength", strconv.Itoa(r.Dst.Bits()))
	case res.MeshPriority:
		// Marked packets, such as the outside endpoint lookup, skip the tunnel
		args = append(args, "to", r.Dst.String(), "not", "fwmark", fmt.Sprintf("%#x", res.FwMark), "lookup", strconv.Itoa(res.Table))
	case res.LocalPriority:
		args = append(args, "to", r.Dst.String(), "lookup", "main")
	case res.SuppressPriority:
		args = append(args, "lookup", "main", "suppress_prefixlength", "0")
	case res.TunnelPriority:
		args = append(args, "not", "fwmark", fmt.Sprintf("%#x", res.FwMark), "lookup", strconv.Itoa(res.Table))
	}
	return ipCommand(append(args, "protocol", strconv.Itoa(res.Protocol))...)
}

// ruleDelCommand selects by protocol too, so the kernel never matches a foreign
// rule, and by destination, since several local rules share one priority
func ruleDelCommand(res Resources, r ruleKey) command {
	args := []string{familyFlag(r.Family), "rule", "del", "priority", strconv.Itoa(r.Priority)}
	if r.Src.IsValid() {
		args = append(args, "from", r.Src.String())
	}
	if r.Dst.IsValid() {
		args = append(args, "to", r.Dst.String())
	}
	return ipCommand(append(args, "protocol", strconv.Itoa(res.Protocol))...)
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
// the delete valid when the table is absent
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
		b.WriteString("\t\tmeta l4proto udp meta mark set ct mark\n\t}\n")
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
