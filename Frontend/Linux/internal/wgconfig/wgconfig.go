// Package wgconfig parses the backend's WireGuard config through an allowlist
// and renders canonical text, hashes, and wg setconf input. Keys never appear
// in formatted output or errors
package wgconfig

import (
	"encoding/base64"
	"fmt"
	"io"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
)

const MaxConfigBytes = 16 << 10

// Key is a WireGuard key. Formatting it never prints the value
type Key [32]byte

func (Key) Format(f fmt.State, _ rune) { _, _ = io.WriteString(f, "[redacted]") }

func (k Key) base64() string { return base64.StdEncoding.EncodeToString(k[:]) }

type Endpoint struct {
	// Host is a lowercase hostname or a canonical IP literal without brackets
	Host string
	Port uint16
}

func (e Endpoint) String() string {
	if addr, err := netip.ParseAddr(e.Host); err == nil && addr.Is6() {
		return "[" + e.Host + "]:" + strconv.Itoa(int(e.Port))
	}
	return e.Host + ":" + strconv.Itoa(int(e.Port))
}

type Peer struct {
	PublicKey    Key
	PresharedKey *Key
	AllowedIPs   []netip.Prefix
	Endpoint     Endpoint
	// PersistentKeepalive is in seconds. Zero is off
	PersistentKeepalive uint16
}

type Config struct {
	PrivateKey Key
	// ListenPort is zero when unset. The Swift parser accepts it, so this one does too
	ListenPort uint16
	Addresses  []netip.Prefix
	DNS        []netip.Addr
	DNSSearch  []string
	// MTU is zero when unset
	MTU  uint16
	Peer Peer
}

func (c Config) Format(f fmt.State, _ rune) {
	_, _ = fmt.Fprintf(f, "wgconfig.Config{Addresses:%v DNS:%v Endpoint:%v}", c.Addresses, c.DNS, c.Peer.Endpoint)
}

// ParseError names the line and problem without echoing any part of the line
type ParseError struct {
	Line   int
	Reason string
}

func (e *ParseError) Error() string {
	if e.Line == 0 {
		return "wgconfig: " + e.Reason
	}
	return fmt.Sprintf("wgconfig: line %d: %s", e.Line, e.Reason)
}

var (
	labelPattern   = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$`)
	numericPattern = regexp.MustCompile(`^[0-9]+$`)
	interfaceKeys  = map[string]bool{"privatekey": true, "listenport": true, "address": true, "dns": true, "mtu": true}
	peerKeys       = map[string]bool{"publickey": true, "presharedkey": true, "allowedips": true, "endpoint": true, "persistentkeepalive": true}
	listKeys       = map[string]bool{"address": true, "dns": true, "allowedips": true}
)

type section struct {
	line   int
	values map[string]string
	lines  map[string]int
}

// Parse accepts one [Interface] and exactly one [Peer]. Hooks, SaveConfig, Table,
// FwMark, unknown keys, and unknown sections are rejected
func Parse(text string) (*Config, error) {
	if len(text) > MaxConfigBytes {
		return nil, &ParseError{Reason: "config too large"}
	}
	var iface *section
	var peers []*section
	var current *section
	text = strings.NewReplacer("\r\n", "\n", "\r", "\n").Replace(text)
	for i, line := range strings.Split(text, "\n") {
		number := i + 1
		line, _, _ = strings.Cut(line, "#")
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		switch strings.ToLower(line) {
		case "[interface]":
			if iface != nil {
				return nil, &ParseError{number, "multiple [Interface] sections"}
			}
			iface = &section{line: number, values: map[string]string{}, lines: map[string]int{}}
			current = iface
			continue
		case "[peer]":
			current = &section{line: number, values: map[string]string{}, lines: map[string]int{}}
			peers = append(peers, current)
			continue
		}
		rawKey, value, ok := strings.Cut(line, "=")
		if !ok {
			return nil, &ParseError{number, "expected a section header or key = value"}
		}
		if current == nil {
			return nil, &ParseError{number, "key outside a section"}
		}
		key := strings.ToLower(strings.TrimSpace(rawKey))
		allowed := interfaceKeys
		if current != iface {
			allowed = peerKeys
		}
		if !allowed[key] {
			return nil, &ParseError{number, "unsupported key"}
		}
		value = strings.TrimSpace(value)
		if existing, ok := current.values[key]; ok {
			if !listKeys[key] {
				return nil, &ParseError{number, "duplicate " + key}
			}
			value = existing + "," + value
		} else {
			current.lines[key] = number
		}
		current.values[key] = value
	}
	if iface == nil {
		return nil, &ParseError{Reason: "missing [Interface]"}
	}
	if len(peers) != 1 {
		return nil, &ParseError{Reason: "expected exactly one [Peer]"}
	}
	config := &Config{}
	if err := parseInterface(iface, config); err != nil {
		return nil, err
	}
	if err := parsePeer(peers[0], &config.Peer); err != nil {
		return nil, err
	}
	return config, nil
}

func parseInterface(s *section, c *Config) error {
	var err error
	if c.PrivateKey, err = requiredKey(s, "privatekey"); err != nil {
		return err
	}
	if value, ok := s.values["listenport"]; ok {
		if c.ListenPort, err = parseUint16(value, 1); err != nil {
			return &ParseError{s.lines["listenport"], "invalid ListenPort"}
		}
	}
	addresses, ok := s.values["address"]
	if !ok {
		return &ParseError{s.line, "missing Address"}
	}
	for _, value := range listValues(addresses) {
		prefix, err := parsePrefix(value)
		if err != nil || prefix.Bits() != prefix.Addr().BitLen() {
			return &ParseError{s.lines["address"], "Address must be an IPv4 /32 or IPv6 /128"}
		}
		c.Addresses = append(c.Addresses, prefix)
	}
	if len(c.Addresses) == 0 {
		return &ParseError{s.lines["address"], "missing Address"}
	}
	for _, value := range listValues(s.values["dns"]) {
		if addr, err := netip.ParseAddr(value); err == nil && addr.Zone() == "" {
			c.DNS = append(c.DNS, addr)
		} else if validHostname(value) {
			c.DNSSearch = append(c.DNSSearch, strings.ToLower(value))
		} else {
			return &ParseError{s.lines["dns"], "invalid DNS"}
		}
	}
	if value, ok := s.values["mtu"]; ok {
		// Linux drops IPv6 from links below 1280, and every backend config carries IPv6
		if c.MTU, err = parseUint16(value, 1280); err != nil {
			return &ParseError{s.lines["mtu"], "invalid MTU"}
		}
	}
	return nil
}

func parsePeer(s *section, p *Peer) error {
	var err error
	if p.PublicKey, err = requiredKey(s, "publickey"); err != nil {
		return err
	}
	if _, ok := s.values["presharedkey"]; ok {
		key, err := requiredKey(s, "presharedkey")
		if err != nil {
			return err
		}
		p.PresharedKey = &key
	}
	for _, value := range listValues(s.values["allowedips"]) {
		prefix, err := parsePrefix(value)
		if err != nil {
			return &ParseError{s.lines["allowedips"], "invalid AllowedIPs"}
		}
		p.AllowedIPs = append(p.AllowedIPs, prefix.Masked())
	}
	if len(p.AllowedIPs) == 0 {
		return &ParseError{s.line, "missing AllowedIPs"}
	}
	value, ok := s.values["endpoint"]
	if !ok {
		return &ParseError{s.line, "missing Endpoint"}
	}
	if p.Endpoint, err = parseEndpoint(value); err != nil {
		return &ParseError{s.lines["endpoint"], "invalid Endpoint"}
	}
	if value, ok := s.values["persistentkeepalive"]; ok {
		if p.PersistentKeepalive, err = parseUint16(value, 0); err != nil {
			return &ParseError{s.lines["persistentkeepalive"], "invalid PersistentKeepalive"}
		}
	}
	return nil
}

func requiredKey(s *section, name string) (Key, error) {
	value, ok := s.values[name]
	if !ok {
		return Key{}, &ParseError{s.line, "missing " + name}
	}
	var key Key
	decoded, err := base64.StdEncoding.Strict().DecodeString(value)
	if err != nil || len(decoded) != len(key) {
		return Key{}, &ParseError{s.lines[name], "invalid " + name}
	}
	copy(key[:], decoded)
	return key, nil
}

func listValues(value string) []string {
	var values []string
	for item := range strings.SplitSeq(value, ",") {
		if item = strings.TrimSpace(item); item != "" {
			values = append(values, item)
		}
	}
	return values
}

func parseUint16(value string, minimum uint64) (uint16, error) {
	n, err := strconv.ParseUint(value, 10, 16)
	if err != nil || n < minimum {
		return 0, strconv.ErrRange
	}
	return uint16(n), nil
}

// parsePrefix accepts a CIDR or a bare address, which means a single host
func parsePrefix(value string) (netip.Prefix, error) {
	if !strings.Contains(value, "/") {
		addr, err := netip.ParseAddr(value)
		if err != nil || addr.Zone() != "" {
			return netip.Prefix{}, strconv.ErrSyntax
		}
		return netip.PrefixFrom(addr, addr.BitLen()), nil
	}
	prefix, err := netip.ParsePrefix(value)
	if err != nil {
		return netip.Prefix{}, err
	}
	return prefix, nil
}

// validHostname accepts dotted LDH labels of 1 to 63 bytes, at most 253 bytes in
// total. It is stricter than internal/network's validDomain, so anything accepted
// here also passes there. An all-numeric last label would look like an IP address
func validHostname(name string) bool {
	if len(name) > 253 {
		return false
	}
	labels := strings.Split(name, ".")
	for _, label := range labels {
		if !labelPattern.MatchString(label) {
			return false
		}
	}
	return !numericPattern.MatchString(labels[len(labels)-1])
}

func parseEndpoint(value string) (Endpoint, error) {
	var host, port string
	if rest, ok := strings.CutPrefix(value, "["); ok {
		var found bool
		host, port, found = strings.Cut(rest, "]:")
		addr, err := netip.ParseAddr(host)
		if !found || err != nil || !addr.Is6() || addr.Zone() != "" {
			return Endpoint{}, strconv.ErrSyntax
		}
		host = addr.String()
	} else {
		separator := strings.LastIndex(value, ":")
		if separator < 0 {
			return Endpoint{}, strconv.ErrSyntax
		}
		host, port = value[:separator], value[separator+1:]
		if addr, err := netip.ParseAddr(host); err == nil && addr.Is4() {
			host = addr.String()
		} else if !validHostname(host) {
			return Endpoint{}, strconv.ErrSyntax
		} else {
			host = strings.ToLower(host)
		}
	}
	n, err := parseUint16(port, 1)
	if err != nil {
		return Endpoint{}, err
	}
	return Endpoint{Host: host, Port: n}, nil
}
