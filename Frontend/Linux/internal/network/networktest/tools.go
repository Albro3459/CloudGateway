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

func (h *Host) wgLink(name string) (*Link, error) {
	l := h.link(name)
	if l == nil || l.Kind != "wireguard" {
		return nil, fmt.Errorf("Unable to access interface: No such device")
	}
	return l, nil
}

func (h *Host) wg(args []string, stdin []byte) ([]byte, error) {
	switch {
	case len(args) == 3 && args[0] == "setconf" && args[2] == "/dev/stdin":
		l, err := h.wgLink(args[1])
		if err != nil {
			return nil, err
		}
		config, err := parseSetConf(stdin)
		if err != nil {
			return nil, err
		}
		l.WireGuard = config
		return nil, nil
	case len(args) == 6 && args[0] == "set" && args[2] == "peer" && args[4] == "endpoint":
		l, err := h.wgLink(args[1])
		if err != nil {
			return nil, err
		}
		endpoint, err := netip.ParseAddrPort(args[5])
		if err != nil || l.WireGuard == nil || l.WireGuard.PeerKey != args[3] {
			return nil, errUsage
		}
		l.WireGuard.Endpoint = endpoint
		return nil, nil
	case len(args) == 3 && args[0] == "show" && args[1] == "all" && args[2] == "fwmark":
		var b strings.Builder
		for _, l := range h.links {
			if l.Kind == "wireguard" {
				fmt.Fprintf(&b, "%s\t%s\n", l.Name, formatMark(l.WireGuard))
			}
		}
		return []byte(b.String()), nil
	case len(args) == 3 && args[0] == "show":
		l, err := h.wgLink(args[1])
		if err != nil {
			return nil, err
		}
		wg := l.WireGuard
		if args[2] == "fwmark" {
			return []byte(formatMark(wg) + "\n"), nil
		}
		if wg == nil || wg.PeerKey == "" {
			return nil, nil
		}
		var value string
		switch args[2] {
		case "endpoints":
			value = "(none)"
			if wg.Endpoint.IsValid() {
				value = wg.Endpoint.String()
			}
		case "allowed-ips":
			values := make([]string, len(wg.AllowedIPs))
			for i, prefix := range wg.AllowedIPs {
				values[i] = prefix.String()
			}
			value = strings.Join(values, " ")
		case "latest-handshakes":
			value = "0"
			if !wg.Handshake.IsZero() {
				value = strconv.FormatInt(wg.Handshake.Unix(), 10)
			}
		default:
			return nil, errUsage
		}
		return []byte(wg.PeerKey + "\t" + value + "\n"), nil
	}
	return nil, errUsage
}

func formatMark(wg *WireGuard) string {
	if wg == nil || wg.FwMark == 0 {
		return "off"
	}
	return fmt.Sprintf("0x%x", wg.FwMark)
}

// parseSetConf reads the fields the simulation tracks. Keys are checked for
// presence and never stored
func parseSetConf(stdin []byte) (*WireGuard, error) {
	wg := &WireGuard{}
	hasPrivateKey := false
	for line := range strings.Lines(string(stdin)) {
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key, value = strings.TrimSpace(key), strings.TrimSpace(value)
		var err error
		switch key {
		case "PrivateKey":
			hasPrivateKey = value != ""
		case "FwMark":
			var mark uint64
			mark, err = strconv.ParseUint(value, 0, 32)
			wg.FwMark = uint32(mark)
		case "PublicKey":
			wg.PeerKey = value
		case "Endpoint":
			wg.Endpoint, err = netip.ParseAddrPort(value)
		case "AllowedIPs":
			for item := range strings.SplitSeq(value, ",") {
				prefix, parseErr := netip.ParsePrefix(strings.TrimSpace(item))
				if parseErr != nil {
					err = parseErr
					break
				}
				wg.AllowedIPs = append(wg.AllowedIPs, prefix)
			}
		}
		if err != nil {
			return nil, errors.New("Line unrecognized")
		}
	}
	if !hasPrivateKey {
		return nil, errors.New("Key is not the correct length or format")
	}
	return wg, nil
}

// nftRun applies a script as one transaction
func (h *Host) nftRun(args []string, stdin []byte) ([]byte, error) {
	if slices.Equal(args, []string{"-j", "list", "tables"}) {
		var names []string
		for name := range h.nft {
			names = append(names, name)
		}
		slices.Sort(names)
		entries := []any{map[string]any{"metainfo": map[string]any{"version": "1.0.9", "release_name": "Old Doc Yak #3", "json_schema_version": 1}}}
		for i, name := range names {
			family, table, _ := strings.Cut(name, " ")
			entries = append(entries, map[string]any{"table": map[string]any{"family": family, "name": table, "handle": i + 1}})
		}
		return json.Marshal(map[string]any{"nftables": entries})
	}
	if len(args) == 5 && slices.Equal(args[:3], []string{"-j", "list", "table"}) {
		return h.listNftTable(args[3] + " " + args[4])
	}
	if !slices.Equal(args, []string{"-f", "-"}) {
		return nil, errUsage
	}
	tables := map[string]string{}
	for name, body := range h.nft {
		tables[name] = body
	}
	lines := strings.Split(string(stdin), "\n")
	for i := 0; i < len(lines); i++ {
		line := strings.TrimSpace(lines[i])
		switch {
		case line == "":
		case strings.HasPrefix(line, "delete table "):
			name := strings.TrimPrefix(line, "delete table ")
			if _, ok := tables[name]; !ok {
				return nil, fmt.Errorf("Error: No such file or directory")
			}
			delete(tables, name)
		case strings.HasPrefix(line, "table ") && strings.HasSuffix(line, "{"):
			name := strings.TrimSpace(strings.TrimSuffix(strings.TrimPrefix(line, "table "), "{"))
			depth := 1
			var body []string
			for i++; i < len(lines) && depth > 0; i++ {
				depth += strings.Count(lines[i], "{") - strings.Count(lines[i], "}")
				if depth > 0 {
					body = append(body, lines[i])
				}
			}
			i--
			if depth != 0 {
				return nil, fmt.Errorf("Error: syntax error, unexpected end of file")
			}
			tables[name] = strings.Join(body, "\n")
		case strings.HasPrefix(line, "table "):
			name := strings.TrimPrefix(line, "table ")
			if _, ok := tables[name]; !ok {
				tables[name] = ""
			}
		default:
			return nil, fmt.Errorf("Error: syntax error")
		}
	}
	h.nft = tables
	return nil, nil
}

// listNftTable lists one table's chains, each followed by its rules, from the
// loaded body. Rule expressions are left out
func (h *Host) listNftTable(name string) ([]byte, error) {
	body, ok := h.nft[name]
	if !ok {
		return nil, fmt.Errorf("Error: No such file or directory")
	}
	family, table, _ := strings.Cut(name, " ")
	entries := []any{
		map[string]any{"metainfo": map[string]any{"version": "1.0.9", "release_name": "Old Doc Yak #3", "json_schema_version": 1}},
		map[string]any{"table": map[string]any{"family": family, "name": table, "handle": 1}},
	}
	chain := ""
	for line := range strings.Lines(body) {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "chain ") && strings.HasSuffix(line, "{"):
			chain = strings.TrimSpace(strings.TrimSuffix(strings.TrimPrefix(line, "chain "), "{"))
			entries = append(entries, map[string]any{"chain": map[string]any{"family": family, "table": table, "name": chain}})
		case line == "}":
			chain = ""
		case chain != "" && line != "" && !strings.HasPrefix(line, "type "):
			entries = append(entries, map[string]any{"rule": map[string]any{"family": family, "table": table, "chain": chain, "expr": []any{}}})
		}
	}
	return json.Marshal(map[string]any{"nftables": entries})
}

func (h *Host) resolvectl(args []string) error {
	if !h.resolved {
		return errors.New("Failed to connect to bus")
	}
	if len(args) < 2 {
		return errUsage
	}
	l := h.link(args[1])
	if l == nil {
		return fmt.Errorf("Unknown interface %q", args[1])
	}
	switch args[0] {
	case "dns":
		var addrs []netip.Addr
		for _, value := range args[2:] {
			addr, err := netip.ParseAddr(value)
			if err != nil {
				return errUsage
			}
			addrs = append(addrs, addr)
		}
		h.resolvedLink(l.Index).dns = addrs
	case "domain":
		h.resolvedLink(l.Index).domains = slices.Clone(args[2:])
	case "default-route":
		if len(args) != 3 {
			return errUsage
		}
		value := args[2] == "yes"
		h.resolvedLink(l.Index).defaultRoute = &value
	case "revert":
		delete(h.resolvedLinks, l.Index)
	default:
		return errUsage
	}
	return nil
}

func (h *Host) busctl(args []string) ([]byte, error) {
	if len(args) != 6 || args[0] != "--json=short" || args[1] != "get-property" {
		return nil, errUsage
	}
	service, path, iface, property := args[2], args[3], args[4], args[5]
	reply := func(signature string, data any) ([]byte, error) {
		return json.Marshal(map[string]any{"type": signature, "data": data})
	}
	if service == "org.freedesktop.systemd1" {
		if path != "/org/freedesktop/systemd1/unit/systemd_2dresolved_2eservice" || iface != "org.freedesktop.systemd1.Unit" || property != "ActiveState" {
			return nil, errUsage
		}
		state := "inactive"
		if h.resolved {
			state = "active"
		}
		return reply("s", state)
	}
	if service != "org.freedesktop.resolve1" {
		return nil, errUsage
	}
	if !h.resolved {
		return nil, errors.New("Unit dbus-org.freedesktop.resolve1.service not found")
	}
	if path == "/org/freedesktop/resolve1" && iface == "org.freedesktop.resolve1.Manager" {
		indexes := []int{0}
		for index := range h.resolvedLinks {
			indexes = append(indexes, index)
		}
		slices.Sort(indexes)
		data := []any{}
		for _, index := range indexes {
			dns, domains := h.globalDNS, h.globalDomains
			if r := h.resolvedLinks[index]; index != 0 {
				dns, domains = r.dns, r.domains
			}
			switch property {
			case "DNS":
				for _, addr := range dns {
					family := 2
					if addr.Is6() {
						family = 10
					}
					raw := []int{}
					for _, b := range addr.AsSlice() {
						raw = append(raw, int(b))
					}
					data = append(data, []any{index, family, raw})
				}
			case "Domains":
				for _, domain := range domains {
					name, routeOnly := strings.CutPrefix(domain, "~")
					data = append(data, []any{index, name, routeOnly})
				}
			default:
				return nil, errUsage
			}
		}
		if property == "DNS" {
			return reply("a(iiay)", data)
		}
		return reply("a(isb)", data)
	}
	label, ok := strings.CutPrefix(path, "/org/freedesktop/resolve1/link/_3")
	index, err := strconv.Atoi(label)
	if !ok || err != nil || iface != "org.freedesktop.resolve1.Link" || property != "DefaultRoute" {
		return nil, errUsage
	}
	if !slices.ContainsFunc(h.links, func(l *Link) bool { return l.Index == index }) {
		return nil, errors.New("Call failed: Link " + label + " not known")
	}
	return reply("b", h.defaultRoute(index))
}
