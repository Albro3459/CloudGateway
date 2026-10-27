package network

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"net/netip"
	"slices"
	"strconv"
	"strings"
	"time"
)

type link struct {
	Index    int
	Name     string
	Alias    string
	Kind     string
	MTU      int
	Up       bool
	Loopback bool
	Addrs    []address
}

type address struct {
	Prefix netip.Prefix
	Global bool
}

type route struct {
	Dst      netip.Prefix
	Table    int
	Dev      string
	Protocol int
	MTU      int
	// Type is empty for unicast
	Type string
}

type rule struct {
	Family   int
	Priority int
	// Src and Dst are invalid for all
	Src    netip.Prefix
	Dst    netip.Prefix
	Not    bool
	FwMark uint32
	Table  int
	// SuppressLength is -1 without suppress_prefixlength
	SuppressLength int
	Protocol       int
	// Limited is set for a selector that host traffic does not generally match,
	// such as iif other than lo, oif, uidrange, ipproto, ports, tos, or l3mdev,
	// before any not inversion
	Limited bool
}

type peer struct {
	Key        string
	Endpoint   netip.AddrPort
	AllowedIPs []netip.Prefix
	Handshake  time.Time
}

type linkDNS struct {
	Index int
	Addr  netip.Addr
}

type linkDomain struct {
	Index     int
	Name      string
	RouteOnly bool
}

type resolverState struct {
	dns     []linkDNS
	domains []linkDomain
	// defaultRoute is the owned link's DefaultRoute
	defaultRoute bool
}

// snapshot is one read of kernel and resolver state
type snapshot struct {
	ipv6      bool
	links     []link
	routes    []route
	rules     []rule
	nftTables []string
	// nftRules counts rules per chain in the owned table, nil when it is absent
	// or could not be listed
	nftRules map[string]int
	// own is the owned link, nil when absent
	own *link
	// pending is an owned link still under its temporary name
	pending *link
	wgMark  uint32
	peers   []peer
	// resolver is nil when it was not asked for or resolved did not answer
	resolver *resolverState
}

const ipv6DisablePath = "/proc/sys/net/ipv6/conf/all/disable_ipv6"

// ownership picks the resource set to look for, falling back to fixed identity
// for a missing, unknown, or invalid journal set. An unfinished journal also
// adopts an unaliased WireGuard link under the pending name, since a crash can
// land between creating it and setting its alias, and the name is ours alone
func ownership(j *Journal) (Resources, bool) {
	if j == nil || !slices.Contains(knownResources, j.Resources) || !j.Resources.valid() {
		return fixed, false
	}
	return j.Resources, j.Phase != PhaseApplied
}

func (m *Manager) read(ctx context.Context, res Resources, adoptPending, withResolver bool) (*snapshot, error) {
	s := &snapshot{}
	_, err := m.exec.ReadFile(ipv6DisablePath)
	s.ipv6 = err == nil
	out, err := m.run(ctx, ipCommand("-j", "-d", "-N", "address", "show"))
	if err != nil {
		return nil, err
	}
	if s.links, err = parseLinks(out); err != nil {
		return nil, err
	}
	families := []int{4}
	if s.ipv6 {
		families = append(families, 6)
	}
	for _, family := range families {
		flag := "-" + strconv.Itoa(family)
		if out, err = m.run(ctx, ipCommand("-j", "-N", flag, "route", "show", "table", "all")); err != nil {
			return nil, err
		}
		routes, err := parseRoutes(out, family)
		if err != nil {
			return nil, err
		}
		s.routes = append(s.routes, routes...)
		if out, err = m.run(ctx, ipCommand("-j", "-N", flag, "rule", "show")); err != nil {
			return nil, err
		}
		rules, err := parseRules(out, family)
		if err != nil {
			return nil, err
		}
		s.rules = append(s.rules, rules...)
	}
	if out, err = m.exec.Run(ctx, ToolNft, []string{"-j", "list", "tables"}, nil); err != nil {
		return nil, err
	}
	if s.nftTables, err = parseNftTables(out); err != nil {
		return nil, err
	}
	if s.hasTable(res) {
		// Only drift checks use the rule counts, so a failed listing leaves them unknown
		if out, err := m.exec.Run(ctx, ToolNft, []string{"-j", "list", "table", "inet", res.NftTable}, nil); err == nil {
			s.nftRules, _ = parseNftRules(out)
		}
	}
	s.own, s.pending = s.ownedLinks(res, adoptPending)
	if s.own == nil {
		return s, nil
	}
	if s.wgMark, s.peers, err = m.readPeers(ctx, res.Interface); err != nil {
		return nil, err
	}
	if withResolver {
		// An unanswered resolver is drift, which Reconcile bounds in time
		s.resolver, _ = m.readResolver(ctx, s.own.Index)
	}
	return s, nil
}

// ownedLinks finds the owned link, which always carries the alias, and an
// owned link still under the pending name
func (s *snapshot) ownedLinks(res Resources, adoptPending bool) (own, pending *link) {
	if !res.valid() {
		return nil, nil
	}
	for i, l := range s.links {
		if l.Kind != "wireguard" {
			continue
		}
		switch {
		case l.Name == res.Interface && l.Alias == res.Alias:
			own = &s.links[i]
		case l.Name == res.PendingInterface && (l.Alias == res.Alias || adoptPending && l.Alias == ""):
			pending = &s.links[i]
		}
	}
	return own, pending
}

func (s *snapshot) link(name string) *link {
	for i, l := range s.links {
		if l.Name == name {
			return &s.links[i]
		}
	}
	return nil
}

func (res Resources) priorities() []int {
	return []int{res.SourcePriority, res.MarkPriority, res.MeshLocalPriority, res.MeshPriority, res.LocalPriority, res.SuppressPriority, res.TunnelPriority}
}

func (s *snapshot) ownedRules(res Resources) []rule {
	if !res.valid() {
		return nil
	}
	var owned []rule
	for _, r := range s.rules {
		if r.Protocol == res.Protocol && slices.Contains(res.priorities(), r.Priority) {
			owned = append(owned, r)
		}
	}
	return owned
}

func (s *snapshot) ownedRoutes(res Resources) []route {
	if !res.valid() {
		return nil
	}
	var owned []route
	for _, r := range s.routes {
		if r.Protocol == res.Protocol && r.Dev == res.Interface {
			owned = append(owned, r)
		}
	}
	return owned
}

// catchesHostTrafficTo reports whether the rule sees host traffic toward target,
// or toward most destinations when target is invalid. Host traffic is unbound
// and unmarked, so a source, fwmark, or limiting selector keeps a rule off it,
// such as a secondary NIC's from rule, and a destination limits it to its
// prefix. not inverts the whole selector set, as the kernel does
func (r rule) catchesHostTrafficTo(target netip.Prefix) bool {
	limited := r.Src.IsValid() || r.Limited || r.FwMark != 0
	if r.Not {
		return limited || r.Dst.IsValid() && !(target.IsValid() && covers(r.Dst, target))
	}
	return !limited && (!r.Dst.IsValid() || !target.IsValid() || r.Dst.Overlaps(target))
}

// catchesHostTraffic reports whether the rule sees most host traffic
func (r rule) catchesHostTraffic() bool {
	return r.catchesHostTrafficTo(netip.Prefix{}) && (r.Not || !r.Dst.IsValid())
}

func (s *snapshot) hasDefaultRoute(table, family int) bool {
	return slices.ContainsFunc(s.routes, func(r route) bool {
		return r.Table == table && r.Dst.Bits() == 0 && addrFamily(r.Dst.Addr()) == family
	})
}

func (s *snapshot) hasTable(res Resources) bool {
	return res.valid() && slices.Contains(s.nftTables, "inet "+res.NftTable)
}

// tableMatches reports whether the owned table has the chains and rule counts
// nftScript installs for j, so a flushed table or deleted chain is drift. Rule
// contents are not compared. Unknown counts match
func (s *snapshot) tableMatches(j *Journal) bool {
	if !s.hasTable(j.Resources) {
		return false
	}
	if s.nftRules == nil {
		return true
	}
	want := map[string]int{"preraw": len(j.Addresses)}
	if j.Mode == ModeFull {
		want["premangle"], want["postmangle"] = 1, 1
	}
	return maps.Equal(s.nftRules, want)
}

func (s *snapshot) anyOwned(res Resources) bool {
	return s.own != nil || s.pending != nil || len(s.ownedRules(res)) > 0 || len(s.ownedRoutes(res)) > 0 || s.hasTable(res)
}

// fullInstalled means the tunnel rule steers unmarked traffic into the tunnel
func (s *snapshot) fullInstalled(res Resources) bool {
	for _, r := range s.ownedRules(res) {
		if r.Priority == res.TunnelPriority {
			return true
		}
	}
	return false
}

// physicalAddrs are global addresses outside the owned interface. Addresses on
// loopback and down links, such as anycast VIPs or kube-ipvs0 service IPs,
// count only outside the local ranges. Replies to private clients already take
// the local rules, so a Kubernetes node adds no rule per ClusterIP, while a
// public load balancer IP still answers outside the tunnel. Local routes that
// no address created, like the GCE guest agent's load balancer IPs, count too
func (s *snapshot) physicalAddrs(res Resources) []netip.Addr {
	local := func(addr netip.Addr) bool {
		return slices.ContainsFunc(localPrefixes, func(p netip.Prefix) bool { return p.Contains(addr) })
	}
	var addrs []netip.Addr
	for _, l := range s.links {
		if l.Name == res.Interface || l.Name == res.PendingInterface {
			continue
		}
		for _, a := range l.Addrs {
			addr := a.Prefix.Addr()
			if a.Global && (l.Up && !l.Loopback || !local(addr)) {
				addrs = append(addrs, addr)
			}
		}
	}
	for _, r := range s.routes {
		addr := r.Dst.Addr()
		if r.Type == "local" && r.Table == 255 && r.Protocol != 2 && r.Dst.IsSingleIP() && r.Dev != res.Interface &&
			r.Dev != res.PendingInterface && addr.IsGlobalUnicast() && !local(addr) {
			addrs = append(addrs, addr)
		}
	}
	slices.SortFunc(addrs, func(a, b netip.Addr) int { return a.Compare(b) })
	return slices.Compact(addrs)
}

func decodeList(data []byte, value any) error {
	if len(bytes.TrimSpace(data)) == 0 {
		return nil
	}
	return json.Unmarshal(data, value)
}

// ipValue accepts a JSON string or number, since iproute2 prints names and
// numbers as strings in some fields and plain numbers in others
type ipValue string

func (v *ipValue) UnmarshalJSON(data []byte) error {
	if len(data) > 0 && data[0] == '"' {
		var s string
		if err := json.Unmarshal(data, &s); err != nil {
			return err
		}
		*v = ipValue(s)
		return nil
	}
	*v = ipValue(data)
	return nil
}

// tableID reads numeric output from ip -N, falling back to the reserved names
func tableID(v ipValue) int {
	switch v {
	case "", "main":
		return mainTable
	case "local":
		return 255
	case "default":
		return 253
	}
	id, err := strconv.Atoi(string(v))
	if err != nil {
		return -1
	}
	return id
}

func protocolID(v ipValue) int {
	id, err := strconv.Atoi(string(v))
	if err != nil {
		return -1
	}
	return id
}

func parseLinks(data []byte) ([]link, error) {
	var raw []struct {
		Index    int      `json:"ifindex"`
		Name     string   `json:"ifname"`
		Flags    []string `json:"flags"`
		MTU      int      `json:"mtu"`
		Alias    string   `json:"ifalias"`
		LinkInfo struct {
			Kind string `json:"info_kind"`
		} `json:"linkinfo"`
		AddrInfo []struct {
			Local     string  `json:"local"`
			PrefixLen int     `json:"prefixlen"`
			Scope     ipValue `json:"scope"`
		} `json:"addr_info"`
	}
	if err := decodeList(data, &raw); err != nil {
		return nil, fmt.Errorf("network: parsing ip address output: %w", err)
	}
	links := make([]link, 0, len(raw))
	for _, r := range raw {
		l := link{Index: r.Index, Name: r.Name, Alias: r.Alias, Kind: r.LinkInfo.Kind, MTU: r.MTU,
			Up: slices.Contains(r.Flags, "UP"), Loopback: slices.Contains(r.Flags, "LOOPBACK")}
		for _, a := range r.AddrInfo {
			addr, err := netip.ParseAddr(a.Local)
			if err != nil {
				continue
			}
			prefix := netip.PrefixFrom(addr, a.PrefixLen)
			if !prefix.IsValid() {
				return nil, fmt.Errorf("network: parsing ip address output: prefix length %d", a.PrefixLen)
			}
			l.Addrs = append(l.Addrs, address{Prefix: prefix, Global: a.Scope == "global" || a.Scope == "0"})
		}
		links = append(links, l)
	}
	return links, nil
}

func parseDestination(dst string, family int) (netip.Prefix, error) {
	if dst == "default" {
		if family == 6 {
			return netip.MustParsePrefix("::/0"), nil
		}
		return netip.MustParsePrefix("0.0.0.0/0"), nil
	}
	if strings.Contains(dst, "/") {
		return netip.ParsePrefix(dst)
	}
	addr, err := netip.ParseAddr(dst)
	if err != nil {
		return netip.Prefix{}, err
	}
	return netip.PrefixFrom(addr, addr.BitLen()), nil
}

func parseRoutes(data []byte, family int) ([]route, error) {
	var raw []struct {
		Dst      string  `json:"dst"`
		Dev      string  `json:"dev"`
		Type     string  `json:"type"`
		Table    ipValue `json:"table"`
		Protocol ipValue `json:"protocol"`
		Metrics  []struct {
			MTU int `json:"mtu"`
		} `json:"metrics"`
	}
	if err := decodeList(data, &raw); err != nil {
		return nil, fmt.Errorf("network: parsing ip route output: %w", err)
	}
	routes := make([]route, 0, len(raw))
	for _, r := range raw {
		dst, err := parseDestination(r.Dst, family)
		if err != nil {
			return nil, fmt.Errorf("network: parsing ip route output: %w", err)
		}
		// iproute2 omits the protocol for boot routes
		protocol := 3
		if r.Protocol != "" {
			protocol = protocolID(r.Protocol)
		}
		parsed := route{Dst: dst, Table: tableID(r.Table), Dev: r.Dev, Protocol: protocol, Type: r.Type}
		for _, metric := range r.Metrics {
			parsed.MTU = max(parsed.MTU, metric.MTU)
		}
		routes = append(routes, parsed)
	}
	return routes, nil
}

func parseRules(data []byte, family int) ([]rule, error) {
	var raw []struct {
		Priority int             `json:"priority"`
		Src      string          `json:"src"`
		SrcLen   *int            `json:"srclen"`
		Dst      string          `json:"dst"`
		DstLen   *int            `json:"dstlen"`
		Not      json.RawMessage `json:"not"`
		FwMark   ipValue         `json:"fwmark"`
		Table    ipValue         `json:"table"`
		Suppress *int            `json:"suppress_prefixlen"`
		Protocol ipValue         `json:"protocol"`
		IIf      string          `json:"iif"`
	}
	if err := decodeList(data, &raw); err != nil {
		return nil, fmt.Errorf("network: parsing ip rule output: %w", err)
	}
	var keys []map[string]json.RawMessage
	if err := decodeList(data, &keys); err != nil {
		return nil, fmt.Errorf("network: parsing ip rule output: %w", err)
	}
	rules := make([]rule, 0, len(raw))
	for i, r := range raw {
		parsed := rule{Family: family, Priority: r.Priority, Not: r.Not != nil, SuppressLength: -1,
			Limited: r.IIf != "" && r.IIf != "lo" || slices.ContainsFunc(limitingSelectors, func(key string) bool { return keys[i][key] != nil })}
		var err error
		if parsed.Src, err = rulePrefix(r.Src, r.SrcLen); err != nil {
			return nil, err
		}
		if parsed.Dst, err = rulePrefix(r.Dst, r.DstLen); err != nil {
			return nil, err
		}
		if r.FwMark != "" {
			mark, err := strconv.ParseUint(string(r.FwMark), 0, 32)
			if err != nil {
				return nil, fmt.Errorf("network: parsing ip rule output: %w", err)
			}
			parsed.FwMark = uint32(mark)
		}
		if r.Table != "" {
			parsed.Table = tableID(r.Table)
		}
		if r.Protocol != "" {
			parsed.Protocol = protocolID(r.Protocol)
		}
		if r.Suppress != nil {
			parsed.SuppressLength = *r.Suppress
		}
		rules = append(rules, parsed)
	}
	return rules, nil
}

// limitingSelectors are iproute2's JSON keys for selectors that narrow a rule
// below all host traffic. iif is handled apart, since iif lo matches every
// locally generated packet
var limitingSelectors = []string{"oif", "uid_start", "ipproto", "sport", "sport_start", "dport", "dport_start", "tos", "dscp", "flowlabel", "l3mdev"}

// rulePrefix reads a rule's from or to, where iproute2 prints the length apart
// and only when it is not a host length
func rulePrefix(value string, length *int) (netip.Prefix, error) {
	if value == "" || value == "all" {
		return netip.Prefix{}, nil
	}
	addr, err := netip.ParseAddr(value)
	if err != nil {
		return netip.Prefix{}, fmt.Errorf("network: parsing ip rule output: %w", err)
	}
	bits := addr.BitLen()
	if length != nil {
		bits = *length
	}
	prefix := netip.PrefixFrom(addr, bits)
	if !prefix.IsValid() {
		return netip.Prefix{}, fmt.Errorf("network: parsing ip rule output: prefix length %d", bits)
	}
	return prefix, nil
}

func parseNftTables(data []byte) ([]string, error) {
	var raw struct {
		Nftables []struct {
			Table *struct {
				Family string `json:"family"`
				Name   string `json:"name"`
			} `json:"table"`
		} `json:"nftables"`
	}
	if err := decodeList(data, &raw); err != nil {
		return nil, fmt.Errorf("network: parsing nft output: %w", err)
	}
	var tables []string
	for _, entry := range raw.Nftables {
		if entry.Table != nil {
			tables = append(tables, entry.Table.Family+" "+entry.Table.Name)
		}
	}
	return tables, nil
}

// parseNftRules counts the rules in each chain of one listed table
func parseNftRules(data []byte) (map[string]int, error) {
	var raw struct {
		Nftables []struct {
			Chain *struct {
				Name string `json:"name"`
			} `json:"chain"`
			Rule *struct {
				Chain string `json:"chain"`
			} `json:"rule"`
		} `json:"nftables"`
	}
	if err := decodeList(data, &raw); err != nil {
		return nil, fmt.Errorf("network: parsing nft output: %w", err)
	}
	chains := map[string]int{}
	for _, entry := range raw.Nftables {
		switch {
		case entry.Chain != nil:
			// A flushed chain still shows up, with zero rules
			if _, ok := chains[entry.Chain.Name]; !ok {
				chains[entry.Chain.Name] = 0
			}
		case entry.Rule != nil:
			chains[entry.Rule.Chain]++
		}
	}
	return chains, nil
}

// wgFields splits wg show <if> <field> output into key and value per line
func wgFields(data []byte) [][2]string {
	var fields [][2]string
	for line := range strings.Lines(string(data)) {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "\t")
		if ok {
			fields = append(fields, [2]string{key, value})
		}
	}
	return fields
}

func parseFwMark(data []byte) (uint32, error) {
	value := strings.TrimSpace(string(data))
	if value == "off" || value == "" {
		return 0, nil
	}
	mark, err := strconv.ParseUint(value, 0, 32)
	return uint32(mark), err
}

func (m *Manager) readPeers(ctx context.Context, iface string) (uint32, []peer, error) {
	field := func(name string) ([]byte, error) {
		return m.exec.Run(ctx, ToolWG, []string{"show", iface, name}, nil)
	}
	out, err := field("fwmark")
	if err != nil {
		return 0, nil, err
	}
	mark, err := parseFwMark(out)
	if err != nil {
		return 0, nil, fmt.Errorf("network: parsing wg fwmark: %w", err)
	}
	if out, err = field("endpoints"); err != nil {
		return 0, nil, err
	}
	var peers []peer
	index := map[string]int{}
	for _, f := range wgFields(out) {
		p := peer{Key: f[0]}
		if f[1] != "(none)" {
			if p.Endpoint, err = netip.ParseAddrPort(f[1]); err != nil {
				return 0, nil, fmt.Errorf("network: parsing wg endpoints: %w", err)
			}
		}
		index[p.Key] = len(peers)
		peers = append(peers, p)
	}
	if out, err = field("allowed-ips"); err != nil {
		return 0, nil, err
	}
	for _, f := range wgFields(out) {
		i, ok := index[f[0]]
		if !ok || f[1] == "(none)" {
			continue
		}
		for value := range strings.FieldsSeq(f[1]) {
			prefix, err := netip.ParsePrefix(value)
			if err != nil {
				return 0, nil, fmt.Errorf("network: parsing wg allowed-ips: %w", err)
			}
			peers[i].AllowedIPs = append(peers[i].AllowedIPs, prefix)
		}
	}
	if out, err = field("latest-handshakes"); err != nil {
		return 0, nil, err
	}
	for _, f := range wgFields(out) {
		i, ok := index[f[0]]
		seconds, err := strconv.ParseInt(f[1], 10, 64)
		if !ok || err != nil || seconds == 0 {
			continue
		}
		peers[i].Handshake = time.Unix(seconds, 0)
	}
	return mark, peers, nil
}

const (
	resolveService = "org.freedesktop.resolve1"
	resolvePath    = "/org/freedesktop/resolve1"
)

func (m *Manager) busProperty(ctx context.Context, service, path, iface, name string, value any) error {
	out, err := m.exec.Run(ctx, ToolBusctl, []string{"--json=short", "get-property", service, path, iface, name}, nil)
	if err != nil {
		return err
	}
	var reply struct {
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(out, &reply); err != nil {
		return fmt.Errorf("network: parsing busctl %s: %w", name, err)
	}
	if err := json.Unmarshal(reply.Data, value); err != nil {
		return fmt.Errorf("network: parsing busctl %s: %w", name, err)
	}
	return nil
}

// linkObjectPath escapes the ifindex like sd_bus_path_encode, where a leading digit becomes _3X
func linkObjectPath(index int) string {
	return resolvePath + "/link/_3" + strconv.Itoa(index)
}

// readResolver reads every link's DNS servers and domains, plus DefaultRoute for
// ownIndex when it is set
func (m *Manager) readResolver(ctx context.Context, ownIndex int) (*resolverState, error) {
	r := &resolverState{}
	var servers [][3]json.RawMessage
	if err := m.busProperty(ctx, resolveService, resolvePath, resolveService+".Manager", "DNS", &servers); err != nil {
		return nil, err
	}
	for _, entry := range servers {
		var index int
		var raw []byte
		if err := json.Unmarshal(entry[0], &index); err != nil {
			return nil, fmt.Errorf("network: parsing resolver DNS: %w", err)
		}
		if err := json.Unmarshal(entry[2], &raw); err != nil {
			return nil, fmt.Errorf("network: parsing resolver DNS: %w", err)
		}
		addr, ok := netip.AddrFromSlice(raw)
		if !ok {
			return nil, fmt.Errorf("network: parsing resolver DNS: address of %d bytes", len(raw))
		}
		r.dns = append(r.dns, linkDNS{Index: index, Addr: addr})
	}
	var domains [][3]json.RawMessage
	if err := m.busProperty(ctx, resolveService, resolvePath, resolveService+".Manager", "Domains", &domains); err != nil {
		return nil, err
	}
	for _, entry := range domains {
		var d linkDomain
		if json.Unmarshal(entry[0], &d.Index) != nil || json.Unmarshal(entry[1], &d.Name) != nil || json.Unmarshal(entry[2], &d.RouteOnly) != nil {
			return nil, errors.New("network: parsing resolver domains")
		}
		r.domains = append(r.domains, d)
	}
	if ownIndex > 0 {
		if err := m.busProperty(ctx, resolveService, linkObjectPath(ownIndex), resolveService+".Link", "DefaultRoute", &r.defaultRoute); err != nil {
			return nil, err
		}
	}
	return r, nil
}

func normalizeDomain(name string) string {
	name = strings.ToLower(strings.TrimSuffix(name, "."))
	if name == "" {
		return "."
	}
	return name
}

// matches reports whether the owned link has exactly the Full DNS settings
func (r *resolverState) matches(index int, dns []netip.Addr, search []string) bool {
	var got []netip.Addr
	for _, server := range r.dns {
		if server.Index == index {
			got = append(got, server.Addr)
		}
	}
	want := []linkDomain{{Index: index, Name: ".", RouteOnly: true}}
	for _, domain := range search {
		want = append(want, linkDomain{Index: index, Name: normalizeDomain(domain)})
	}
	var gotDomains []linkDomain
	for _, d := range r.domains {
		if d.Index == index {
			d.Name = normalizeDomain(d.Name)
			gotDomains = append(gotDomains, d)
		}
	}
	return r.defaultRoute && sameSet(got, dns) && sameSet(gotDomains, want)
}

// conflicts lists domains outside the owned link on scopes that have DNS
// servers. Any of them takes matching queries away from the VPN link, and
// another ~. splits all queries. Index 0 is the global scope
func (r *resolverState) conflicts(index int) []string {
	withServers := map[int]bool{}
	for _, server := range r.dns {
		withServers[server.Index] = true
	}
	var names []string
	for _, d := range r.domains {
		if d.Index == index || !withServers[d.Index] {
			continue
		}
		name := normalizeDomain(d.Name)
		if d.RouteOnly {
			name = "~" + name
		}
		names = append(names, name)
	}
	slices.Sort(names)
	return slices.Compact(names)
}

func sameSet[T comparable](a, b []T) bool {
	set := map[T]bool{}
	for _, v := range a {
		set[v] = true
	}
	other := map[T]bool{}
	for _, v := range b {
		if !set[v] {
			return false
		}
		other[v] = true
	}
	return len(set) == len(other)
}
