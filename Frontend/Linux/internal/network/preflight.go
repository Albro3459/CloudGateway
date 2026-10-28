package network

import (
	"bytes"
	"context"
	"fmt"
	"net/netip"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// Preflight checks p against the host without changing anything. Conflicts come
// back as *PreflightError
func (m *Manager) Preflight(ctx context.Context, p Profile) error {
	if err := p.validate(); err != nil {
		return err
	}
	j, _ := m.status()
	res, adopt := ownership(j)
	_, err := m.check(ctx, p, res, adopt)
	return err
}

func (m *Manager) check(ctx context.Context, p Profile, res Resources, adopt bool) (*snapshot, error) {
	var missing []string
	tools := []string{ToolIP, ToolWG, ToolNft}
	if p.Mode == ModeFull {
		tools = append(tools, ToolResolvectl, ToolBusctl)
	}
	for _, tool := range tools {
		if !m.exec.Available(tool) {
			missing = append(missing, tool)
		}
	}
	if len(missing) > 0 {
		return nil, &PreflightError{Conflicts: []Conflict{{Kind: ConflictMissingTools, Names: missing}}}
	}
	s, err := m.read(ctx, res, adopt, false)
	if err != nil {
		return nil, err
	}
	conflicts, err := m.conflicts(ctx, p, s, res)
	if err != nil {
		return nil, err
	}
	if len(conflicts) > 0 {
		return nil, &PreflightError{Conflicts: conflicts}
	}
	return s, nil
}

func (m *Manager) conflicts(ctx context.Context, p Profile, s *snapshot, res Resources) ([]Conflict, error) {
	var conflicts []Conflict
	add := func(kind ConflictKind, names []string, prefixes []netip.Prefix) {
		if len(names) > 0 || len(prefixes) > 0 {
			slices.Sort(names)
			conflicts = append(conflicts, Conflict{Kind: kind, Names: slices.Compact(names), Prefixes: prefixes})
		}
	}
	if !m.wireguardSupported() {
		conflicts = append(conflicts, Conflict{Kind: ConflictNoWireGuard})
	}
	if !m.ipv6Enabled() {
		conflicts = append(conflicts, Conflict{Kind: ConflictIPv6Disabled})
	}
	var links []string
	for _, name := range []string{fixed.Interface, fixed.PendingInterface} {
		if l := s.link(name); l != nil && l != s.own && l != s.pending {
			links = append(links, name)
		}
	}
	add(ConflictForeignInterface, links, nil)

	add(ConflictOverlap, nil, overlaps(p, s, res))
	// Mesh installs no rules, table routes, mark, or resolver settings
	if p.Mode != ModeFull {
		return conflicts, nil
	}

	owned := s.ownedRules(res)
	var rules, marks, vpns []string
	for _, r := range s.rules {
		if slices.Contains(owned, r) {
			continue
		}
		if slices.Contains(fixed.priorities(), r.Priority) || r.Table == fixed.Table {
			rules = append(rules, strconv.Itoa(r.Priority))
		}
		if r.FwMark == fixed.FwMark {
			marks = append(marks, "rule "+strconv.Itoa(r.Priority))
		}
		// Such as a Tailscale exit node in table 52 or a wg-quick full tunnel
		if r.catchesHostTraffic() && !slices.Contains(systemTables, r.Table) && r.Table != fixed.Table && s.hasDefaultRoute(r.Table, r.Family) {
			vpns = append(vpns, fmt.Sprintf("%d lookup %d", r.Priority, r.Table))
		}
	}
	add(ConflictForeignRule, rules, nil)
	add(ConflictForeignVPN, vpns, nil)

	var routes []netip.Prefix
	for _, r := range s.routes {
		if r.Table == fixed.Table && !(r.Protocol == res.Protocol && r.Dev == res.Interface) {
			routes = append(routes, r.Dst)
		}
	}
	add(ConflictForeignRoute, nil, routes)

	out, err := m.exec.Run(ctx, ToolWG, []string{"show", "all", "fwmark"}, nil)
	if err != nil {
		return nil, err
	}
	for _, f := range wgFields(out) {
		mark, err := parseFwMark([]byte(f[1]))
		if err == nil && mark == fixed.FwMark && (s.own == nil || f[0] != s.own.Name) {
			marks = append(marks, "interface "+f[0])
		}
	}
	add(ConflictForeignMark, marks, nil)

	var state string
	err = m.busProperty(ctx, "org.freedesktop.systemd1", "/org/freedesktop/systemd1/unit/systemd_2dresolved_2eservice",
		"org.freedesktop.systemd1.Unit", "ActiveState", &state)
	if err != nil || state != "active" {
		return append(conflicts, Conflict{Kind: ConflictResolverInactive}), nil
	}
	if !m.usesResolvedStub() {
		conflicts = append(conflicts, Conflict{Kind: ConflictResolverStub})
	}
	r, err := m.readResolver(ctx, 0)
	if err != nil {
		return nil, err
	}
	ownIndex := -1
	if s.own != nil {
		ownIndex = s.own.Index
	}
	add(ConflictResolverDomains, r.conflicts(ownIndex), nil)
	return conflicts, nil
}

// overlaps finds local networks and routes that collide with the mesh ranges,
// tunnel addresses, or regional DNS. In Mesh, a main route at least as specific
// as the tunnel's route wins. In Full, only a main route more specific than the
// mesh range wins, and VPN DNS outside the mesh always takes the tunnel. Tables
// that foreign rules reach before main win with any overlapping route
func overlaps(p Profile, s *snapshot, res Resources) []netip.Prefix {
	protected := slices.Clone(meshPrefixes)
	for _, prefix := range p.Addresses {
		protected = append(protected, netip.PrefixFrom(prefix.Addr(), prefix.Addr().BitLen()))
	}
	for _, addr := range p.DNS {
		protected = append(protected, netip.PrefixFrom(addr, addr.BitLen()))
	}
	// winsOverTunnel reports whether a main route at dst beats the tunnel for target
	winsOverTunnel := func(dst, target netip.Prefix) bool {
		if p.Mode == ModeFull {
			for _, mesh := range meshPrefixes {
				if mesh.Overlaps(target) {
					return dst.Bits() > mesh.Bits()
				}
			}
			return false
		}
		bits := 0
		for _, allowed := range p.AllowedIPs {
			if allowed.Bits() > 0 && allowed.Overlaps(target) {
				bits = max(bits, allowed.Bits())
			}
		}
		return dst.Bits() >= bits
	}
	owned := s.ownedRules(res)
	earlier := map[int][]rule{}
	for _, r := range s.rules {
		if r.Priority < mainRulePriority && !slices.Contains(owned, r) && !slices.Contains(systemTables, r.Table) && r.Table != res.Table {
			earlier[r.Table] = append(earlier[r.Table], r)
		}
	}
	reachedFirst := func(table int, target netip.Prefix) bool {
		return slices.ContainsFunc(earlier[table], func(r rule) bool { return r.catchesHostTrafficTo(target) })
	}
	ownedDev := func(dev string) bool {
		return s.own != nil && dev == s.own.Name || s.pending != nil && dev == s.pending.Name
	}
	var found []netip.Prefix
	for _, l := range s.links {
		if ownedDev(l.Name) {
			continue
		}
		for _, a := range l.Addrs {
			network := a.Prefix.Masked()
			if slices.ContainsFunc(protected, network.Overlaps) {
				found = append(found, network)
			}
		}
	}
	for _, r := range s.routes {
		if ownedDev(r.Dev) {
			continue
		}
		switch {
		case len(earlier[r.Table]) > 0:
			for _, target := range protected {
				if r.Dst.Overlaps(target) && reachedFirst(r.Table, target) {
					found = append(found, r.Dst)
					break
				}
			}
		case r.Table == mainTable && r.Dst.Bits() > 0:
			for _, target := range protected {
				if r.Dst.Overlaps(target) && winsOverTunnel(r.Dst, target) {
					found = append(found, r.Dst)
					break
				}
			}
		}
	}
	slices.SortFunc(found, func(a, b netip.Prefix) int {
		if c := a.Addr().Compare(b.Addr()); c != 0 {
			return c
		}
		return a.Bits() - b.Bits()
	})
	return slices.Compact(found)
}

// wireguardSupported finds the module loaded, built in, or installed for the
// running kernel, since ip link add loads it on demand
func (m *Manager) wireguardSupported() bool {
	if _, err := m.exec.ReadFile("/sys/module/wireguard/version"); err == nil {
		return true
	}
	release, err := m.exec.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil {
		return false
	}
	dir := filepath.Join("/lib/modules", strings.TrimSpace(string(release)))
	for _, name := range []string{"modules.builtin", "modules.dep"} {
		data, err := m.exec.ReadFile(filepath.Join(dir, name))
		if err == nil && bytes.Contains(data, []byte("/wireguard.ko")) {
			return true
		}
	}
	return false
}

// ipv6Enabled also checks default, which the new link inherits
func (m *Manager) ipv6Enabled() bool {
	for _, name := range []string{ipv6DisablePath, "/proc/sys/net/ipv6/conf/default/disable_ipv6"} {
		data, err := m.exec.ReadFile(name)
		if err != nil || strings.TrimSpace(string(data)) != "0" {
			return false
		}
	}
	return true
}

func (m *Manager) usesResolvedStub() bool {
	data, err := m.exec.ReadFile("/etc/resolv.conf")
	if err != nil {
		return false
	}
	found := false
	for line := range strings.Lines(string(data)) {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == "nameserver" {
			if fields[1] != "127.0.0.53" {
				return false
			}
			found = true
		}
	}
	return found
}
