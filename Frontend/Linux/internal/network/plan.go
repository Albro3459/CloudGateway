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
}

func (r rule) key() ruleKey {
	k := ruleKey{Family: r.Family, Priority: r.Priority}
	if r.Src.IsValid() {
		k.Src = r.Src.Addr()
	}
	return k
}

func (k ruleKey) String() string {
	if k.Src.IsValid() {
		return fmt.Sprintf("rule %d from %s", k.Priority, k.Src)
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

// linkLocal stays on the physical path in Full even when main has no specific
// route, which keeps cloud metadata at 169.254.169.254 and time sync reachable
func linkLocal(family int) netip.Prefix {
	if family == 4 {
		return netip.MustParsePrefix("169.254.0.0/16")
	}
	return netip.MustParsePrefix("fe80::/10")
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
	for _, priority := range []int{res.LinkLocalPriority, res.SuppressPriority, res.TunnelPriority} {
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
	case res.LinkLocalPriority:
		args = append(args, "to", linkLocal(r.Family).String(), "lookup", "main")
	case res.SuppressPriority:
		args = append(args, "lookup", "main", "suppress_prefixlength", "0")
	case res.TunnelPriority:
		args = append(args, "not", "fwmark", fmt.Sprintf("%#x", res.FwMark), "lookup", strconv.Itoa(res.Table))
	}
	return ipCommand(append(args, "protocol", strconv.Itoa(res.Protocol))...)
}

// ruleDelCommand selects by protocol too, so the kernel never matches a foreign rule
func ruleDelCommand(res Resources, r ruleKey) command {
	args := []string{familyFlag(r.Family), "rule", "del", "priority", strconv.Itoa(r.Priority)}
	if r.Src.IsValid() {
		args = append(args, "from", r.Src.String())
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
