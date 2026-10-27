package network

import (
	"context"
	"fmt"
	"net/netip"
	"slices"
	"strings"
)

const observeAttempts = 3

// Observe reads owned state and maps it onto the public tunnel states. A failed
// read keeps the last state as stale, or reports unknown and unavailable when no
// read ever succeeded
func (m *Manager) Observe(ctx context.Context) (Observation, error) {
	m.stateMu.Lock()
	m.observeSeq++
	seq := m.observeSeq
	m.stateMu.Unlock()
	for attempt := 1; ; attempt++ {
		j, _, generation := m.statusGeneration()
		res, adoptPending := ownership(j)
		withResolver := j != nil && j.Phase == PhaseApplied && j.Mode == ModeFull
		s, err := m.read(ctx, res, adoptPending, withResolver)
		j, t, after := m.statusGeneration()
		// A change landed during the read, so the snapshot may mix both sides of it
		if after != generation && attempt < observeAttempts {
			continue
		}
		if err != nil {
			return m.stale(), err
		}
		res, _ = ownership(j)
		obs := evaluate(s, j, t, res)
		obs.ObservedAt = m.now()
		m.stateMu.Lock()
		if seq > m.lastSeq {
			m.last, m.lastSeq = &obs, seq
		}
		m.stateMu.Unlock()
		return obs, nil
	}
}

func (m *Manager) statusGeneration() (*Journal, transition, uint64) {
	m.stateMu.Lock()
	defer m.stateMu.Unlock()
	return m.journal, m.transition, m.generation
}

func (m *Manager) stale() Observation {
	m.stateMu.Lock()
	defer m.stateMu.Unlock()
	if m.last == nil {
		return Observation{State: StateUnknown, Freshness: FreshnessUnavailable}
	}
	return Observation{State: m.last.State, Freshness: FreshnessStale, ObservedAt: m.last.ObservedAt}
}

func evaluate(s *snapshot, j *Journal, t transition, res Resources) Observation {
	obs := Observation{Freshness: FreshnessCurrent}
	for _, p := range s.peers {
		if j == nil || p.Key == j.PeerKey {
			obs.Endpoint, obs.LatestHandshake = p.Endpoint, p.Handshake
			break
		}
	}
	switch {
	case t == transitionApplying:
		obs.State = StateConnecting
	case t == transitionRemoving && s.anyOwned(res):
		obs.State = StateDisconnecting
	case !s.anyOwned(res):
		obs.State = StateDisconnected
	case j == nil || j.Phase != PhaseApplied:
		obs.State = StateUnknown
	default:
		if core := coreMismatch(s, j); len(core) > 0 {
			obs.State = StateUnknown
			obs.Drift = core
			break
		}
		obs.Drift = drift(s, j)
		if len(obs.Drift) > 0 {
			// Reconcile repairs these, so the tunnel is reconnecting rather than lost
			obs.State = StateConnecting
			break
		}
		obs.State = StateConnected
		obs.ActiveMode = j.Mode
		obs.ProfileID = j.ProfileID
	}
	return obs
}

// coreMismatch covers what Reconcile never repairs: a missing link, addresses
// someone else added, and the peer
func coreMismatch(s *snapshot, j *Journal) []string {
	if s.own == nil {
		return []string{"interface"}
	}
	var mismatch []string
	for _, a := range s.own.Addrs {
		if a.Global && !slices.Contains(j.Addresses, a.Prefix) {
			mismatch = append(mismatch, "extra address "+a.Prefix.String())
		}
	}
	if len(s.peers) != 1 || s.peers[0].Key != j.PeerKey || !sameSet(s.peers[0].AllowedIPs, j.AllowedIPs) {
		mismatch = append(mismatch, "peer")
	}
	var mark uint32
	if j.Mode == ModeFull {
		mark = j.Resources.FwMark
	}
	if s.wgMark != mark {
		mismatch = append(mismatch, "fwmark")
	}
	return mismatch
}

func missingAddresses(s *snapshot, j *Journal) []netip.Prefix {
	var missing []netip.Prefix
	for _, prefix := range j.Addresses {
		if !slices.ContainsFunc(s.own.Addrs, func(a address) bool { return a.Prefix == prefix }) {
			missing = append(missing, prefix)
		}
	}
	return missing
}

// drift needs the owned link, so call it only without a core mismatch
func drift(s *snapshot, j *Journal) []string {
	var names []string
	if !s.own.Up {
		names = append(names, "interface down")
	}
	if s.own.MTU != j.MTU {
		names = append(names, fmt.Sprintf("mtu %d", s.own.MTU))
	}
	for _, prefix := range missingAddresses(s, j) {
		names = append(names, "missing address "+prefix.String())
	}
	if !s.tableMatches(j) {
		names = append(names, "nftables")
	}
	missingRoutes, extraRoutes := diffRoutes(s, j)
	for _, r := range missingRoutes {
		names = append(names, fmt.Sprintf("missing route %s table %d", r.Dst, r.Table))
	}
	for _, r := range extraRoutes {
		names = append(names, fmt.Sprintf("extra route %s table %d", r.Dst, r.Table))
	}
	missingRules, extraRules := diffRules(s, j)
	for _, r := range missingRules {
		names = append(names, "missing "+r.String())
	}
	for _, r := range extraRules {
		names = append(names, "extra "+r.String())
	}
	if j.Mode == ModeFull {
		switch {
		case s.resolver == nil:
			names = append(names, "resolver unavailable")
		default:
			if conflicts := s.resolver.conflicts(s.own.Index); len(conflicts) > 0 {
				names = append(names, "resolver domains "+strings.Join(conflicts, " "))
			}
			if !s.resolver.matches(s.own.Index, j.DNS, j.Search) {
				names = append(names, "resolver link")
			}
		}
	}
	return names
}
