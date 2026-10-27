// Package network owns the cloudgateway WireGuard interface and the routes,
// policy rules, nftables table, and resolver settings around it. It runs trusted
// system tools with fixed argument arrays and has no HTTP, Firebase, or cloud imports
package network

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"slices"
	"strings"
	"time"
)

// Fixed identities of owned resources, so they can be found and removed without the journal
const (
	InterfaceName = "cloudgateway"
	// InterfaceAlias marks the link as ours. A link with the name but not the alias is foreign
	InterfaceAlias = "cloudgatewayd"
	// PendingInterfaceName is where a new link gets its alias before taking
	// InterfaceName, so an unaliased link named cloudgateway is never ours
	PendingInterfaceName = "cloudgw-pending"
	RouteTable           = 52820
	// FwMark is distinct from wg-quick's 51820
	FwMark = 0xce54
	// RouteProtocol tags owned rules and routes. Linux and FRR use 0-18, 42, 99,
	// and 186-198, and the stock rt_protos names nothing above 192
	RouteProtocol = 206
	// Full's rule priorities sit below main at 32766 and clear of Tailscale's 5210-5270
	PrioritySource   = 30200
	PriorityMesh     = 30203
	PriorityLocal    = 30205
	PrioritySuppress = 30210
	PriorityTunnel   = 30220
	// NftTable is in the inet family. Regional servers own inet cloudgateway
	NftTable = "cloudgateway_client"
)

const (
	mainTable        = 254
	mainRulePriority = 32766
	mtuCeiling       = 1500
	// WireGuard over IPv6 adds 80 bytes
	mtuOverhead = 80
)

// systemTables are unspec, default, main, and local
var systemTables = []int{0, 253, mainTable, 255}

var meshPrefixes = []netip.Prefix{
	netip.MustParsePrefix("10.0.0.0/16"),
	netip.MustParsePrefix("fd42:42:42::/48"),
}

// localPrefixes stay on the physical path in Full. Full carries traffic bound for
// the public internet, so cloud metadata, time sync, VPC peers, and LANs keep
// working even when main has no specific route to them. Mesh ranges and VPN DNS
// inside these go back to the tunnel first
var localPrefixes = []netip.Prefix{
	netip.MustParsePrefix("10.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("169.254.0.0/16"),
	netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.168.0.0/16"),
	netip.MustParsePrefix("fc00::/7"),
	netip.MustParsePrefix("fe80::/10"),
}

// Resources is the fixed resource set. The journal records it so a later release
// can still remove what this one installed
type Resources struct {
	Interface        string `json:"interface"`
	PendingInterface string `json:"pendingInterface"`
	Alias            string `json:"alias"`
	Table            int    `json:"table"`
	FwMark           uint32 `json:"fwmark"`
	Protocol         int    `json:"protocol"`
	SourcePriority   int    `json:"sourcePriority"`
	MeshPriority     int    `json:"meshPriority"`
	LocalPriority    int    `json:"localPriority"`
	SuppressPriority int    `json:"suppressPriority"`
	TunnelPriority   int    `json:"tunnelPriority"`
	NftTable         string `json:"nftTable"`
}

var fixed = Resources{
	Interface:        InterfaceName,
	PendingInterface: PendingInterfaceName,
	Alias:            InterfaceAlias,
	Table:            RouteTable,
	FwMark:           FwMark,
	Protocol:         RouteProtocol,
	SourcePriority:   PrioritySource,
	MeshPriority:     PriorityMesh,
	LocalPriority:    PriorityLocal,
	SuppressPriority: PrioritySuppress,
	TunnelPriority:   PriorityTunnel,
	NftTable:         NftTable,
}

// knownResources lists every resource set a release has installed. A journal
// naming any other set is rejected, so a damaged one can never point teardown
// at kernel defaults
var knownResources = []Resources{fixed}

// valid keeps ownership matching away from kernel defaults even if an unknown
// set slips through: protocol 0 is a wildcard on rule delete, and 0 and 2 tag
// the kernel's own rules and routes
func (r Resources) valid() bool {
	return r.Interface != "" && r.PendingInterface != "" && r.Alias != "" && r.NftTable != "" &&
		r.Protocol > 2 && r.Protocol < 256 && r.FwMark != 0 &&
		!slices.Contains(systemTables, r.Table) &&
		r.SourcePriority > 0 && r.MeshPriority > 0 && r.LocalPriority > 0 && r.SuppressPriority > 0 && r.TunnelPriority > 0
}

type Mode string

const (
	ModeFull Mode = "full"
	ModeMesh Mode = "mesh"
)

// Profile is one mode-transformed config ready to install. It carries no key
// material. SetConf renders the wg setconf input, and wgconfig.Config.SetConf fits
type Profile struct {
	// ID is opaque, such as signedInUID/regionId/clientId
	ID         string
	ConfigHash string
	// Mode is the mode the user chose. AllowedIPs must fit it
	Mode      Mode
	Addresses []netip.Prefix
	// DNS holds the regional DNS addresses from the canonical config, even in Mesh
	// where the mode transform clears them. Full sets them on the VPN link. Both
	// modes probe the first and keep them out of overlaps
	DNS []netip.Addr
	// SearchDomains come from the canonical config too. Only Full applies them
	SearchDomains []string
	// MTU zero means min(route MTU toward the endpoint, 1500) - 80
	MTU int
	// PeerPublicKey is base64, as wg show prints it
	PeerPublicKey string
	AllowedIPs    []netip.Prefix
	EndpointHost  string
	EndpointPort  uint16
	// SetConf renders wg setconf input for the resolved endpoint and fwmark, zero in Mesh
	SetConf func(endpoint netip.AddrPort, fwmark uint32) ([]byte, error)
}

func (p Profile) validate() error {
	invalid := func(what string) error { return fmt.Errorf("%w: %s", ErrInvalidProfile, what) }
	switch {
	case p.ID == "":
		return invalid("missing ID")
	case p.SetConf == nil:
		return invalid("missing setconf renderer")
	case len(p.Addresses) == 0:
		return invalid("no addresses")
	case len(p.AllowedIPs) == 0:
		return invalid("no allowed IPs")
	case !validKey(p.PeerPublicKey):
		return invalid("peer public key")
	case p.EndpointPort == 0 || !validHost(p.EndpointHost):
		return invalid("endpoint")
	case p.MTU != 0 && (p.MTU < 1280 || p.MTU > 65535):
		return invalid("MTU")
	}
	switch p.Mode {
	case ModeMesh:
		// Anything wider would route ordinary traffic, and the endpoint, into a tunnel with no Full rules
		for _, prefix := range p.AllowedIPs {
			if !slices.ContainsFunc(meshPrefixes, func(mesh netip.Prefix) bool { return covers(mesh, prefix) }) {
				return invalid("mesh mode allowed IP outside the mesh ranges")
			}
		}
	case ModeFull:
		// Full carries both families, so a missing address or default for either would blackhole it
		hasIPv4 := slices.ContainsFunc(p.Addresses, func(prefix netip.Prefix) bool { return prefix.Addr().Is4() })
		hasIPv6 := slices.ContainsFunc(p.Addresses, func(prefix netip.Prefix) bool { return prefix.Addr().Is6() })
		switch {
		case len(p.DNS) == 0:
			return invalid("full mode without DNS")
		case !hasIPv4 || !hasIPv6:
			return invalid("full mode without both IPv4 and IPv6 addresses")
		case !slices.Contains(p.AllowedIPs, netip.MustParsePrefix("0.0.0.0/0")) || !slices.Contains(p.AllowedIPs, netip.MustParsePrefix("::/0")):
			return invalid("full mode without both default routes")
		}
	default:
		return invalid("mode")
	}
	for _, prefix := range p.Addresses {
		if !prefix.IsValid() || prefix.Addr().Zone() != "" {
			return invalid("address")
		}
	}
	for _, prefix := range p.AllowedIPs {
		if !prefix.IsValid() || prefix != prefix.Masked() {
			return invalid("allowed IP")
		}
	}
	for _, addr := range p.DNS {
		if !addr.IsValid() || addr.Zone() != "" {
			return invalid("DNS address")
		}
	}
	for _, domain := range p.SearchDomains {
		if !validDomain(domain) {
			return invalid("search domain")
		}
	}
	return nil
}

// covers reports whether outer contains all of inner
func covers(outer, inner netip.Prefix) bool {
	return outer.Bits() <= inner.Bits() && outer.Contains(inner.Addr())
}

// checkEndpoint refuses an endpoint the tunnel would carry, since its own
// encrypted packets would loop. Default routes are fine, because the fwmark
// skips Full's tunnel rule, but no rule skips a main route or Full's mesh rule
func checkEndpoint(endpoint netip.Addr, mode Mode, allowed []netip.Prefix, dns []netip.Addr) error {
	inside := slices.ContainsFunc(allowed, func(prefix netip.Prefix) bool { return prefix.Bits() > 0 && prefix.Contains(endpoint) })
	if mode == ModeFull {
		inside = inside || slices.ContainsFunc(tunnelPrefixes(dns), func(prefix netip.Prefix) bool { return prefix.Contains(endpoint) })
	}
	if inside {
		return fmt.Errorf("%w: endpoint %s is inside the tunnel's own routes", ErrInvalidProfile, endpoint)
	}
	return nil
}

func validKey(key string) bool {
	decoded, err := base64.StdEncoding.DecodeString(key)
	return len(key) == 44 && err == nil && len(decoded) == 32
}

func validHost(host string) bool {
	if addr, err := netip.ParseAddr(host); err == nil {
		return addr.Zone() == ""
	}
	return validDomain(host)
}

// validDomain also keeps argv safe, since no label can start with a dash
func validDomain(domain string) bool {
	domain = strings.TrimSuffix(domain, ".")
	if domain == "" || len(domain) > 253 {
		return false
	}
	for label := range strings.SplitSeq(domain, ".") {
		if label == "" || len(label) > 63 || label[0] == '-' {
			return false
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
				return false
			}
		}
	}
	return true
}

const JournalVersion = 1

type Phase string

const (
	PhaseApplying Phase = "applying"
	PhaseApplied  Phase = "applied"
	PhaseRemoving Phase = "removing"
)

// Journal records the owned resource set and the profile installed in it. The
// daemon persists every update before the kernel changes. It never holds key material
type Journal struct {
	Version    int            `json:"version"`
	Phase      Phase          `json:"phase"`
	ProfileID  string         `json:"profileId"`
	ConfigHash string         `json:"configHash"`
	Mode       Mode           `json:"mode"`
	Host       string         `json:"host"`
	Endpoint   netip.AddrPort `json:"endpoint"`
	PeerKey    string         `json:"peerKey"`
	Addresses  []netip.Prefix `json:"addresses"`
	AllowedIPs []netip.Prefix `json:"allowedIPs"`
	DNS        []netip.Addr   `json:"dns"`
	Search     []string       `json:"search"`
	MTU        int            `json:"mtu"`
	Resources  Resources      `json:"resources"`
}

// ParseJournal rejects unknown versions and phases. Treat a rejected journal as
// missing, so Down removes owned resources by fixed identity
func ParseJournal(data []byte) (*Journal, error) {
	var j Journal
	if err := json.Unmarshal(data, &j); err != nil {
		return nil, fmt.Errorf("network: journal: %w", err)
	}
	if j.Version != JournalVersion {
		return nil, fmt.Errorf("network: journal version %d is not supported", j.Version)
	}
	switch j.Phase {
	case PhaseApplying, PhaseApplied, PhaseRemoving:
	default:
		return nil, fmt.Errorf("network: journal phase %q is not supported", j.Phase)
	}
	if !slices.Contains(knownResources, j.Resources) {
		return nil, errors.New("network: journal resource set is not known")
	}
	return &j, nil
}

// State values match the public tunnel states
type State string

const (
	StateDisconnected  State = "disconnected"
	StateConnecting    State = "connecting"
	StateConnected     State = "connected"
	StateDisconnecting State = "disconnecting"
	StateUnknown       State = "unknown"
)

type Freshness string

const (
	FreshnessCurrent     Freshness = "current"
	FreshnessStale       Freshness = "stale"
	FreshnessUnavailable Freshness = "unavailable"
)

type Observation struct {
	State      State
	Freshness  Freshness
	ObservedAt time.Time
	// ActiveMode and ProfileID are set only when connected
	ActiveMode Mode
	ProfileID  string
	// Endpoint is the kernel's current peer endpoint. Roaming does not count as drift
	Endpoint        netip.AddrPort
	LatestHandshake time.Time
	// Drift names owned resources that do not match the journal
	Drift []string
}

var (
	ErrInvalidProfile     = errors.New("network: invalid profile")
	ErrToolMissing        = errors.New("network: required tool missing")
	ErrNotApplied         = errors.New("network: no applied tunnel")
	ErrEndpointUnresolved = errors.New("network: endpoint did not resolve")
	ErrTeardownIncomplete = errors.New("network: owned resources remain")
	// ErrResolverPolicy means Full DNS no longer goes only to the VPN link. Tear
	// down, suppress restart, and report vpn_failed
	ErrResolverPolicy = errors.New("network: full mode resolver policy lost")
)

type ConflictKind string

const (
	ConflictMissingTools     ConflictKind = "missing_tools"
	ConflictNoWireGuard      ConflictKind = "no_wireguard"
	ConflictIPv6Disabled     ConflictKind = "ipv6_disabled"
	ConflictForeignInterface ConflictKind = "foreign_interface"
	ConflictForeignRule      ConflictKind = "foreign_rule"
	ConflictForeignRoute     ConflictKind = "foreign_route"
	ConflictForeignMark      ConflictKind = "foreign_mark"
	ConflictOverlap          ConflictKind = "overlap"
	// ConflictForeignVPN is another rule sending traffic to a table with a default route
	ConflictForeignVPN       ConflictKind = "foreign_vpn"
	ConflictResolverInactive ConflictKind = "resolver_inactive"
	ConflictResolverStub     ConflictKind = "resolver_stub"
	ConflictResolverDomains  ConflictKind = "resolver_domains"
)

type Conflict struct {
	Kind ConflictKind
	// Prefixes lists overlapping local addresses and routes
	Prefixes []netip.Prefix
	// Names lists tools, links, rule priorities, or resolver domains
	Names []string
}

// PreflightError lists every conflict found before any change
type PreflightError struct {
	Conflicts []Conflict
}

func (e *PreflightError) Error() string {
	parts := make([]string, len(e.Conflicts))
	for i, c := range e.Conflicts {
		details := c.Names
		for _, prefix := range c.Prefixes {
			details = append(details, prefix.String())
		}
		parts[i] = string(c.Kind)
		if len(details) > 0 {
			parts[i] += " (" + strings.Join(details, ", ") + ")"
		}
	}
	return "network: preflight failed: " + strings.Join(parts, "; ")
}

func (e *PreflightError) Has(kind ConflictKind) bool {
	for _, c := range e.Conflicts {
		if c.Kind == kind {
			return true
		}
	}
	return false
}

// ApplyError reports a failure after Apply changed the kernel: a failed
// teardown of the previous profile, or a failed install after rollback.
// Restored is true when the previous profile is running again
type ApplyError struct {
	Err      error
	Restored bool
}

func (e *ApplyError) Error() string {
	if e.Restored {
		return "network: apply failed, previous profile restored: " + e.Err.Error()
	}
	return "network: apply failed: " + e.Err.Error()
}

func (e *ApplyError) Unwrap() error { return e.Err }
