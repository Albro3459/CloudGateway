package wgconfig

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/netip"
	"slices"
	"strings"
)

var meshAllowedIPs = []netip.Prefix{
	netip.MustParsePrefix("10.0.0.0/16"),
	netip.MustParsePrefix("fd42:42:42::/48"),
}

// Mesh returns a copy routed like CloudGatewayRoutingMode.mesh: no VPN DNS or
// search domains, and only the fleet mesh ranges. Full mode uses the canonical config
func (c *Config) Mesh() *Config {
	mesh := c.clone()
	mesh.DNS = nil
	mesh.DNSSearch = nil
	mesh.Peer.AllowedIPs = slices.Clone(meshAllowedIPs)
	return mesh
}

func (c *Config) clone() *Config {
	clone := *c
	clone.Addresses = slices.Clone(c.Addresses)
	clone.DNS = slices.Clone(c.DNS)
	clone.DNSSearch = slices.Clone(c.DNSSearch)
	clone.Peer.AllowedIPs = slices.Clone(c.Peer.AllowedIPs)
	if c.Peer.PresharedKey != nil {
		key := *c.Peer.PresharedKey
		clone.Peer.PresharedKey = &key
	}
	return &clone
}

// Canonical renders the parsed fields in a fixed order and spacing. It contains the private key
func (c *Config) Canonical() []byte {
	var b bytes.Buffer
	b.WriteString("[Interface]\n")
	fmt.Fprintf(&b, "PrivateKey = %s\n", c.PrivateKey.base64())
	if c.ListenPort != 0 {
		fmt.Fprintf(&b, "ListenPort = %d\n", c.ListenPort)
	}
	fmt.Fprintf(&b, "Address = %s\n", joinPrefixes(c.Addresses))
	if len(c.DNS) > 0 || len(c.DNSSearch) > 0 {
		values := make([]string, 0, len(c.DNS)+len(c.DNSSearch))
		for _, addr := range c.DNS {
			values = append(values, addr.String())
		}
		values = append(values, c.DNSSearch...)
		fmt.Fprintf(&b, "DNS = %s\n", strings.Join(values, ", "))
	}
	if c.MTU != 0 {
		fmt.Fprintf(&b, "MTU = %d\n", c.MTU)
	}
	b.WriteString("\n")
	c.writePeer(&b, c.Peer.Endpoint.String())
	return b.Bytes()
}

// Hash is the lowercase hex SHA-256 of Canonical, so equivalent texts share a hash
func (c *Config) Hash() string {
	sum := sha256.Sum256(c.Canonical())
	return hex.EncodeToString(sum[:])
}

// SetConf renders wg setconf input with the endpoint already resolved. It holds
// keys, so pass it to wg through a pipe. Addresses, DNS, and MTU are applied elsewhere
func (c *Config) SetConf(endpoint netip.AddrPort, fwmark uint32) ([]byte, error) {
	if !endpoint.IsValid() || endpoint.Port() == 0 || endpoint.Addr().Zone() != "" {
		return nil, errors.New("wgconfig: invalid resolved endpoint")
	}
	var b bytes.Buffer
	b.WriteString("[Interface]\n")
	fmt.Fprintf(&b, "PrivateKey = %s\n", c.PrivateKey.base64())
	if c.ListenPort != 0 {
		fmt.Fprintf(&b, "ListenPort = %d\n", c.ListenPort)
	}
	if fwmark != 0 {
		fmt.Fprintf(&b, "FwMark = 0x%x\n", fwmark)
	}
	b.WriteString("\n")
	c.writePeer(&b, endpoint.String())
	return b.Bytes(), nil
}

func (c *Config) writePeer(b *bytes.Buffer, endpoint string) {
	b.WriteString("[Peer]\n")
	fmt.Fprintf(b, "PublicKey = %s\n", c.Peer.PublicKey.base64())
	if c.Peer.PresharedKey != nil {
		fmt.Fprintf(b, "PresharedKey = %s\n", c.Peer.PresharedKey.base64())
	}
	fmt.Fprintf(b, "AllowedIPs = %s\n", joinPrefixes(c.Peer.AllowedIPs))
	fmt.Fprintf(b, "Endpoint = %s\n", endpoint)
	if c.Peer.PersistentKeepalive != 0 {
		fmt.Fprintf(b, "PersistentKeepalive = %d\n", c.Peer.PersistentKeepalive)
	}
}

func joinPrefixes(prefixes []netip.Prefix) string {
	values := make([]string, len(prefixes))
	for i, prefix := range prefixes {
		values[i] = prefix.String()
	}
	return strings.Join(values, ", ")
}
