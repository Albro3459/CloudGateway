package networktest

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"slices"
	"strconv"
	"strings"
)

var errUsage = errors.New("unsupported invocation")

var (
	tableNames    = map[int]string{253: "default", 254: "main", 255: "local"}
	protocolNames = map[int]string{2: "kernel", 3: "boot", 4: "static", 9: "ra", 16: "dhcp"}
	scopeNumbers  = map[string]string{"global": "0", "link": "253", "host": "254"}
)

func (h *Host) ip(args []string) ([]byte, error) {
	opts := map[string]bool{}
	for len(args) > 0 && strings.HasPrefix(args[0], "-") {
		opts[args[0]] = true
		args = args[1:]
	}
	if len(args) < 2 {
		return nil, errUsage
	}
	numeric := opts["-N"]
	family := 0
	if opts["-4"] {
		family = 4
	}
	if opts["-6"] {
		family = 6
	}
	rest := args[2:]
	switch args[0] + " " + args[1] {
	case "address show":
		return h.renderAddresses(numeric, opts["-d"])
	case "address add":
		if len(rest) != 3 || rest[1] != "dev" {
			return nil, errUsage
		}
		prefix, err := netip.ParsePrefix(rest[0])
		if err != nil || addrFamily(prefix.Addr()) != family {
			return nil, errUsage
		}
		return nil, h.addAddress(rest[2], prefix, "global")
	case "route show":
		if !slices.Equal(rest, []string{"table", "all"}) || family == 0 {
			return nil, errUsage
		}
		return h.renderRoutes(family, numeric)
	case "route add", "route del":
		return nil, h.changeRoute(args[1], family, rest)
	case "route get":
		return h.routeGet(family, rest)
	case "rule show":
		if family == 0 {
			return nil, errUsage
		}
		return h.renderRules(family, numeric)
	case "rule add", "rule del":
		return nil, h.changeRule(args[1], family, rest)
	case "link add":
		if len(rest) != 4 || rest[0] != "dev" || rest[2] != "type" || rest[3] != "wireguard" {
			return nil, errUsage
		}
		if h.link(rest[1]) != nil {
			return nil, errors.New("RTNETLINK answers: File exists")
		}
		h.addLink(Link{Name: rest[1], Kind: "wireguard", MTU: 1420})
		return nil, nil
	case "link set":
		return nil, h.setLink(rest)
	case "link del":
		if len(rest) != 2 || rest[0] != "dev" || h.link(rest[1]) == nil {
			return nil, errUsage
		}
		h.deleteLink(rest[1])
		return nil, nil
	}
	return nil, errUsage
}

func addrFamily(addr netip.Addr) int {
	if addr.Is4() {
		return 4
	}
	return 6
}

func (h *Host) setLink(rest []string) error {
	if len(rest) < 3 || rest[0] != "dev" {
		return errUsage
	}
	l := h.link(rest[1])
	if l == nil {
		return fmt.Errorf("Cannot find device %q", rest[1])
	}
	switch {
	case rest[2] == "up" && len(rest) == 3:
		l.Up = true
		h.addKernelRoutes(l)
	case rest[2] == "alias" && len(rest) == 4:
		l.Alias = rest[3]
	case rest[2] == "name" && len(rest) == 4:
		switch {
		case l.Up:
			return errors.New("RTNETLINK answers: Device or resource busy")
		case h.link(rest[3]) != nil:
			return errors.New("RTNETLINK answers: File exists")
		}
		for i, r := range h.routes {
			if r.Dev == l.Name {
				h.routes[i].Dev = rest[3]
			}
		}
		l.Name = rest[3]
	case rest[2] == "mtu" && len(rest) == 4:
		mtu, err := strconv.Atoi(rest[3])
		if err != nil {
			return errUsage
		}
		h.setMTU(l, mtu)
	default:
		return errUsage
	}
	return nil
}

func parseTable(value string) (int, error) {
	for id, name := range tableNames {
		if value == name {
			return id, nil
		}
	}
	return strconv.Atoi(value)
}

func (h *Host) changeRoute(verb string, family int, rest []string) error {
	if len(rest) != 7 || rest[1] != "dev" || rest[3] != "table" || rest[5] != "proto" {
		return errUsage
	}
	dst, err := netip.ParsePrefix(rest[0])
	if err != nil || addrFamily(dst.Addr()) != family {
		return errUsage
	}
	table, err := parseTable(rest[4])
	if err != nil {
		return errUsage
	}
	protocol, err := strconv.Atoi(rest[6])
	if err != nil {
		return errUsage
	}
	r := Route{Dst: dst, Table: table, Dev: rest[2], Protocol: protocol}
	index := slices.IndexFunc(h.routes, func(other Route) bool { return other.Dst == dst && other.Table == table })
	if verb == "del" {
		if index < 0 || h.routes[index].Dev != r.Dev || h.routes[index].Protocol != protocol {
			return errors.New("RTNETLINK answers: No such process")
		}
		h.routes = slices.Delete(h.routes, index, index+1)
		return nil
	}
	l := h.link(r.Dev)
	switch {
	case l == nil:
		return fmt.Errorf("Cannot find device %q", r.Dev)
	case !l.Up:
		return errors.New("Error: Device for nexthop is not up.")
	case index >= 0:
		return errors.New("RTNETLINK answers: File exists")
	}
	h.routes = append(h.routes, r)
	return nil
}

func (h *Host) changeRule(verb string, family int, rest []string) error {
	r := Rule{Family: family}
	hasProtocol := false
	for i := 0; i < len(rest); i++ {
		value := func() (string, error) {
			i++
			if i >= len(rest) {
				return "", errUsage
			}
			return rest[i], nil
		}
		key := rest[i]
		if key == "not" {
			r.Not = true
			continue
		}
		v, err := value()
		if err != nil {
			return err
		}
		switch key {
		case "priority":
			r.Priority, err = strconv.Atoi(v)
		case "from":
			var addr netip.Addr
			if addr, err = netip.ParseAddr(v); err == nil {
				r.Src = netip.PrefixFrom(addr, addr.BitLen())
			}
		case "to":
			r.Dst, err = netip.ParsePrefix(v)
		case "fwmark":
			var mark uint64
			mark, err = strconv.ParseUint(v, 0, 32)
			r.FwMark = uint32(mark)
		case "lookup":
			r.Table, err = parseTable(v)
		case "suppress_prefixlength":
			r.Suppress = v == "0"
		case "protocol":
			r.Protocol, err = strconv.Atoi(v)
			hasProtocol = true
		default:
			return errUsage
		}
		if err != nil {
			return errUsage
		}
	}
	if verb == "del" {
		// Like the kernel, protocol 0 matches any protocol
		index := slices.IndexFunc(h.rules, func(other Rule) bool {
			return other.Family == family && other.Priority == r.Priority &&
				(!r.Src.IsValid() || other.Src == r.Src) && (!r.Dst.IsValid() || other.Dst == r.Dst) &&
				(!hasProtocol || r.Protocol == 0 || other.Protocol == r.Protocol)
		})
		if index < 0 {
			return errors.New("RTNETLINK answers: No such file or directory")
		}
		h.rules = slices.Delete(h.rules, index, index+1)
		return nil
	}
	if slices.Contains(h.rules, r) {
		return errors.New("RTNETLINK answers: File exists")
	}
	h.rules = append(h.rules, r)
	return nil
}

func (h *Host) routeGet(family int, rest []string) ([]byte, error) {
	if len(rest) != 3 || rest[1] != "mark" {
		return nil, errUsage
	}
	addr, err := netip.ParseAddr(rest[0])
	if err != nil || addrFamily(addr) != family {
		return nil, errUsage
	}
	var best *Route
	for i, r := range h.routes {
		if r.Table == 254 && r.Type == "" && r.Dst.Contains(addr) && (best == nil || r.Dst.Bits() > best.Dst.Bits()) {
			best = &h.routes[i]
		}
	}
	if best == nil {
		return nil, errors.New("RTNETLINK answers: Network is unreachable")
	}
	entry := map[string]any{"dst": addr.String(), "dev": best.Dev, "mark": rest[2], "flags": []string{}, "uid": 0, "cache": []string{}}
	if best.Gateway.IsValid() {
		entry["gateway"] = best.Gateway.String()
	}
	if l := h.link(best.Dev); l != nil {
		for _, a := range l.Addrs {
			if a.Scope == "global" && addrFamily(a.Prefix.Addr()) == family {
				entry["prefsrc"] = a.Prefix.Addr().String()
				break
			}
		}
	}
	if best.MTU > 0 {
		entry["metrics"] = []map[string]int{{"mtu": best.MTU}}
	}
	return json.Marshal([]any{entry})
}

func (h *Host) renderAddresses(numeric, details bool) ([]byte, error) {
	entries := make([]map[string]any, 0, len(h.links))
	for _, l := range h.links {
		var flags []string
		linkType := "ether"
		switch {
		case l.Loopback:
			flags, linkType = []string{"LOOPBACK"}, "loopback"
		case l.Kind == "wireguard":
			flags, linkType = []string{"POINTOPOINT", "NOARP"}, "none"
		default:
			flags = []string{"BROADCAST", "MULTICAST"}
		}
		operstate := "DOWN"
		if l.Up {
			flags = append(flags, "UP", "LOWER_UP")
			operstate = "UP"
			if l.Kind == "wireguard" || l.Loopback {
				operstate = "UNKNOWN"
			}
		}
		entry := map[string]any{
			"ifindex": l.Index, "ifname": l.Name, "flags": flags, "mtu": l.MTU, "qdisc": "noqueue",
			"operstate": operstate, "group": "default", "txqlen": 1000, "link_type": linkType,
		}
		if linkType == "ether" {
			entry["address"] = fmt.Sprintf("52:54:00:12:34:%02x", l.Index)
			entry["broadcast"] = "ff:ff:ff:ff:ff:ff"
		}
		if details {
			entry["promiscuity"] = 0
			entry["allmulti"] = 0
			entry["min_mtu"] = 0
			entry["max_mtu"] = 0
			if l.Alias != "" {
				entry["ifalias"] = l.Alias
			}
			if l.Kind != "" {
				entry["linkinfo"] = map[string]string{"info_kind": l.Kind}
			}
		}
		addrs := []map[string]any{}
		for _, a := range l.Addrs {
			scope := a.Scope
			if numeric {
				scope = scopeNumbers[a.Scope]
			}
			info := map[string]any{"local": a.Prefix.Addr().String(), "prefixlen": a.Prefix.Bits(), "scope": scope,
				"valid_life_time": uint32(4294967295), "preferred_life_time": uint32(4294967295)}
			if a.Prefix.Addr().Is4() {
				info["family"] = "inet"
				info["label"] = l.Name
			} else {
				info["family"] = "inet6"
			}
			addrs = append(addrs, info)
		}
		entry["addr_info"] = addrs
		entries = append(entries, entry)
	}
	return json.Marshal(entries)
}

func named(id int, names map[int]string, numeric bool) string {
	if name, ok := names[id]; ok && !numeric {
		return name
	}
	return strconv.Itoa(id)
}

func (h *Host) renderRoutes(family int, numeric bool) ([]byte, error) {
	entries := []map[string]any{}
	for _, r := range h.routes {
		if addrFamily(r.Dst.Addr()) != family {
			continue
		}
		dst := r.Dst.String()
		switch {
		case r.Dst.Bits() == 0:
			dst = "default"
		case r.Dst.IsSingleIP():
			dst = r.Dst.Addr().String()
		}
		entry := map[string]any{"dst": dst, "dev": r.Dev, "flags": []string{}}
		if r.Type != "" {
			entry["type"] = r.Type
		}
		if r.Gateway.IsValid() {
			entry["gateway"] = r.Gateway.String()
		}
		if r.Table != 254 {
			entry["table"] = named(r.Table, tableNames, numeric)
		}
		if r.Protocol != 3 {
			entry["protocol"] = named(r.Protocol, protocolNames, numeric)
		}
		if r.MTU > 0 {
			entry["metrics"] = []map[string]int{{"mtu": r.MTU}}
		}
		entries = append(entries, entry)
	}
	return json.Marshal(entries)
}

func (h *Host) renderRules(family int, numeric bool) ([]byte, error) {
	rules := slices.Clone(h.rules)
	slices.SortStableFunc(rules, func(a, b Rule) int { return a.Priority - b.Priority })
	entries := []map[string]any{}
	for _, r := range rules {
		if r.Family != family {
			continue
		}
		entry := map[string]any{"priority": r.Priority, "src": "all"}
		if r.Src.IsValid() {
			entry["src"] = r.Src.Addr().String()
			if !r.Src.IsSingleIP() {
				entry["srclen"] = r.Src.Bits()
			}
		}
		if r.Dst.IsValid() {
			entry["dst"] = r.Dst.Addr().String()
			if !r.Dst.IsSingleIP() {
				entry["dstlen"] = r.Dst.Bits()
			}
		}
		if r.Not {
			entry["not"] = nil
		}
		if r.FwMark != 0 {
			entry["fwmark"] = fmt.Sprintf("%#x", r.FwMark)
			if r.FwMask != 0 && r.FwMask != 0xffffffff {
				entry["fwmask"] = fmt.Sprintf("%#x", r.FwMask)
			}
		}
		if r.Table != 0 {
			entry["table"] = named(r.Table, tableNames, numeric)
		}
		if r.Suppress {
			entry["suppress_prefixlen"] = 0
		}
		if r.Protocol != 0 && r.Protocol != 2 {
			entry["protocol"] = named(r.Protocol, protocolNames, numeric)
		}
		entries = append(entries, entry)
	}
	return json.Marshal(entries)
}
