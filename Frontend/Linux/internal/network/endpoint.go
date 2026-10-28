package network

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"net/netip"
	"strconv"
	"time"
)

const (
	queryTimeout    = 2 * time.Second
	recentHandshake = 60 * time.Second
	// The kernel removes IPv6 from links below 1280
	minimumMTU = 1280
)

// resolveEndpoint uses host DNS unless outside is set. Outside sends the query
// past an installed Full tunnel, so a dead tunnel cannot block the new address
func (m *Manager) resolveEndpoint(ctx context.Context, host string, port uint16, outside bool, ownIndex int, mark uint32) (netip.AddrPort, error) {
	if addr, err := netip.ParseAddr(host); err == nil {
		return netip.AddrPortFrom(addr.Unmap(), port), nil
	}
	var addrs []netip.Addr
	var err error
	if outside {
		addrs, err = m.lookupOutside(ctx, host, ownIndex, mark)
	} else {
		addrs, err = m.lookup(ctx, host)
	}
	if err != nil {
		return netip.AddrPort{}, fmt.Errorf("%w: %s: %w", ErrEndpointUnresolved, host, err)
	}
	if len(addrs) == 0 {
		return netip.AddrPort{}, fmt.Errorf("%w: %s", ErrEndpointUnresolved, host)
	}
	// IPv4 first, since an IPv4-only underlay is supported
	pick := addrs[0].Unmap()
	for _, addr := range addrs {
		if addr.Unmap().Is4() {
			pick = addr.Unmap()
			break
		}
	}
	return netip.AddrPortFrom(pick, port), nil
}

// lookupOutside asks the physical links' resolvers about only this host, from a
// socket carrying the WireGuard fwmark. Global servers are the fallback
func (m *Manager) lookupOutside(ctx context.Context, host string, ownIndex int, mark uint32) ([]netip.Addr, error) {
	r, err := m.readResolver(ctx, 0)
	if err != nil {
		return nil, err
	}
	var linkServers, globalServers []netip.AddrPort
	for _, server := range r.dns {
		addr := server.Addr
		if addr.Is6() && addr.IsLinkLocalUnicast() {
			addr = addr.WithZone(strconv.Itoa(server.Index))
		}
		switch server.Index {
		case 0:
			globalServers = append(globalServers, netip.AddrPortFrom(addr, 53))
		case ownIndex:
		default:
			linkServers = append(linkServers, netip.AddrPortFrom(addr, 53))
		}
	}
	servers := append(linkServers, globalServers...)
	if len(servers) == 0 {
		return nil, errors.New("no underlay DNS servers")
	}
	var lastErr error
	for _, server := range servers {
		for _, qtype := range []uint16{typeA, typeAAAA} {
			addrs, err := m.query(ctx, server, mark, host, qtype)
			if err != nil {
				lastErr = err
				break
			}
			if len(addrs) > 0 {
				return addrs, nil
			}
		}
	}
	return nil, lastErr
}

func (m *Manager) query(ctx context.Context, server netip.AddrPort, mark uint32, name string, qtype uint16) ([]netip.Addr, error) {
	var idBytes [2]byte
	_, _ = rand.Read(idBytes[:])
	id := binary.BigEndian.Uint16(idBytes[:])
	query, err := buildQuery(id, name, qtype)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, queryTimeout)
	defer cancel()
	reply, err := m.exchange(ctx, server, mark, query)
	if err != nil {
		return nil, err
	}
	return parseReply(reply, id, qtype)
}

// endpointMTU reads the route the encrypted packets will take, so the lookup
// carries the fwmark to skip an installed Full tunnel
func (m *Manager) endpointMTU(ctx context.Context, addr netip.Addr, s *snapshot, mark uint32) (int, error) {
	family := addrFamily(addr)
	out, err := m.run(ctx, ipCommand("-j", familyFlag(family), "route", "get", addr.String(), "mark", fmt.Sprintf("%#x", mark)))
	if err != nil {
		return 0, err
	}
	routes, err := parseRoutes(out, family)
	if err != nil {
		return 0, err
	}
	if len(routes) == 0 {
		return 0, errors.New("network: no route toward the endpoint")
	}
	mtu := routes[0].MTU
	if mtu == 0 {
		l := s.link(routes[0].Dev)
		if l == nil {
			return 0, fmt.Errorf("network: endpoint route uses unknown link %q", routes[0].Dev)
		}
		mtu = l.MTU
	}
	return max(min(mtu, mtuCeiling)-mtuOverhead, minimumMTU), nil
}

// ServerResponding answers the human hint only. A handshake under 60 seconds old
// counts with no traffic. Otherwise one DNS query goes through the tunnel to the
// first regional DNS address, and any reply within 2 seconds counts
func (m *Manager) ServerResponding(ctx context.Context) (bool, error) {
	j, _ := m.status()
	if j == nil || j.Phase != PhaseApplied {
		return false, ErrNotApplied
	}
	out, err := m.exec.Run(ctx, ToolWG, []string{"show", j.Resources.Interface, "latest-handshakes"}, nil)
	if err != nil {
		return false, err
	}
	for _, f := range wgFields(out) {
		seconds, err := strconv.ParseInt(f[1], 10, 64)
		if f[0] == j.PeerKey && err == nil && seconds > 0 && m.now().Sub(time.Unix(seconds, 0)) < recentHandshake {
			return true, nil
		}
	}
	if len(j.DNS) == 0 {
		return false, nil
	}
	query, err := buildQuery(0, ".", typeNS)
	if err != nil {
		return false, err
	}
	ctx, cancel := context.WithTimeout(ctx, queryTimeout)
	defer cancel()
	_, err = m.exchange(ctx, netip.AddrPortFrom(j.DNS[0], 53), 0, query)
	return err == nil, nil
}

// UpdateEndpoint re-resolves the endpoint host, outside the tunnel in Full, and
// moves the peer in place with wg set when the kernel's endpoint differs, so a
// failed wg set is retried next time. Routes, rules, and DNS stay as they are.
// It returns the peer's endpoint after the call
func (m *Manager) UpdateEndpoint(ctx context.Context) (netip.AddrPort, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, _ := m.status()
	if j == nil || j.Phase != PhaseApplied {
		return netip.AddrPort{}, false, ErrNotApplied
	}
	res := j.Resources
	s, err := m.read(ctx, res, false, false)
	if err != nil {
		return j.Endpoint, false, err
	}
	if s.own == nil {
		return j.Endpoint, false, ErrNotApplied
	}
	var current netip.AddrPort
	for _, p := range s.peers {
		if p.Key == j.PeerKey {
			current = p.Endpoint
		}
	}
	endpoint, err := m.resolveEndpoint(ctx, j.Host, j.Endpoint.Port(), s.fullInstalled(res), s.own.Index, res.FwMark)
	if err != nil {
		return current, false, err
	}
	if err := checkEndpoint(endpoint.Addr(), j.Mode, j.AllowedIPs, j.DNS); err != nil {
		return current, false, err
	}
	if endpoint != j.Endpoint {
		next := *j
		next.Endpoint = endpoint
		if err := m.commit(&next); err != nil {
			return current, false, err
		}
	}
	if endpoint == current {
		return current, false, nil
	}
	if _, err := m.exec.Run(ctx, ToolWG, []string{"set", res.Interface, "peer", j.PeerKey, "endpoint", endpoint.String()}, nil); err != nil {
		return current, false, err
	}
	return endpoint, true, nil
}
