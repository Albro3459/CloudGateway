package network

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"
)

// resolverGrace bounds how long Full keeps running while resolved does not answer
const resolverGrace = 30 * time.Second

// Reconcile repairs drift in an applied tunnel: link state, MTU, and addresses,
// owned routes and rules, source rules after address changes, the nftables
// table, src_valid_mark, and Full's resolver settings with one reapply. It never
// recreates the link or peer, so ErrTunnelLost means one changed while other
// owned resources remain. ErrResolverPolicy means exclusive Full DNS could not
// be restored, or resolved stopped answering for longer than resolverGrace
func (m *Manager) Reconcile(ctx context.Context) (Observation, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, _ := m.status()
	if j == nil || j.Phase != PhaseApplied {
		return m.Observe(ctx)
	}
	res := j.Resources
	s, err := m.read(ctx, res, false, j.Mode == ModeFull)
	if err != nil {
		return m.stale(), err
	}
	if core := coreMismatch(s, j); len(core) > 0 {
		// Nothing owned left, as after a reboot, observes as disconnected instead.
		// Only an added address leaves the tunnel working, so that stays unknown
		lost := slices.ContainsFunc(core, func(m string) bool { return !strings.HasPrefix(m, extraAddressDrift) })
		obs, err := m.Observe(ctx)
		if err == nil && lost && obs.State == StateUnknown {
			err = ErrTunnelLost
		}
		return obs, err
	}
	var commands []command
	if s.own.MTU != j.MTU {
		commands = append(commands, ipCommand("link", "set", "dev", res.Interface, "mtu", strconv.Itoa(j.MTU)))
	}
	if !s.own.Up {
		commands = append(commands, ipCommand("link", "set", "dev", res.Interface, "up"))
	}
	for _, prefix := range missingAddresses(s, j) {
		commands = append(commands, ipCommand(familyFlag(addrFamily(prefix.Addr())), "address", "add", prefix.String(), "dev", res.Interface))
	}
	if !s.tableMatches(j) {
		commands = append(commands, nftScript(res, j.Addresses, j.Mode == ModeFull))
	}
	missingRoutes, extraRoutes := diffRoutes(s, j)
	for _, r := range missingRoutes {
		commands = append(commands, routeCommand(res, "add", r))
	}
	for _, r := range extraRoutes {
		commands = append(commands, routeCommand(res, "del", r))
	}
	missingRules, extraRules := diffRules(s, j)
	var errs []error
	for _, c := range commands {
		if _, err := m.run(ctx, c); err != nil {
			errs = append(errs, err)
		}
	}
	// Adds go first, so no rule is missing while a stale one is replaced. The
	// kernel refuses an add that differs from an existing rule only by not or
	// protocol, so a refused add runs again once the stale rule is gone
	var refused []ruleKey
	for _, r := range missingRules {
		if _, err := m.run(ctx, ruleAddCommand(res, r)); err != nil {
			refused = append(refused, r)
		}
	}
	for _, r := range extraRules {
		if _, err := m.run(ctx, ruleDelCommand(res, r)); err != nil {
			errs = append(errs, err)
		}
	}
	for _, r := range refused {
		if _, err := m.run(ctx, ruleAddCommand(res, r)); err != nil {
			errs = append(errs, err)
		}
	}
	if j.Mode == ModeFull {
		if data, err := m.exec.ReadFile(srcValidMarkPath); err != nil || strings.TrimSpace(string(data)) != "1" {
			if err := m.exec.WriteFile(srcValidMarkPath, []byte("1\n")); err != nil {
				errs = append(errs, fmt.Errorf("network: setting src_valid_mark: %w", err))
			}
		}
		if err := m.repairResolver(ctx, s, j); err != nil {
			return m.observeWith(ctx, err)
		}
	}
	obs, err := m.Observe(ctx)
	return obs, errors.Join(append(errs, err)...)
}

func (m *Manager) repairResolver(ctx context.Context, s *snapshot, j *Journal) error {
	r := s.resolver
	if r == nil {
		return m.resolverUnavailable()
	}
	index := s.own.Index
	for attempt := 0; ; attempt++ {
		if conflicts := r.conflicts(index); len(conflicts) > 0 {
			return fmt.Errorf("%w: other resolver domains %s", ErrResolverPolicy, strings.Join(conflicts, " "))
		}
		// Only a matching link ends an outage, so a reapply that keeps failing still runs out the bound
		if r.matches(index, j.DNS, j.Search) {
			m.resolverLost = time.Time{}
			return nil
		}
		if attempt > 0 {
			return fmt.Errorf("%w: VPN link settings did not hold", ErrResolverPolicy)
		}
		// A failed reapply or read here usually means resolved is restarting
		if err := m.runAll(ctx, resolverCommands(j.Resources, j.DNS, j.Search)); err != nil {
			return m.resolverUnavailable()
		}
		var err error
		if r, err = m.readResolver(ctx, index); err != nil {
			return m.resolverUnavailable()
		}
	}
}

// resolverUnavailable starts or checks the bound on a resolved outage. Within
// it the tunnel reports connecting. Past it Full can no longer promise VPN DNS
func (m *Manager) resolverUnavailable() error {
	now := m.now()
	if m.resolverLost.IsZero() {
		m.resolverLost = now
	}
	if now.Sub(m.resolverLost) >= resolverGrace {
		return fmt.Errorf("%w: systemd-resolved has not answered for %s", ErrResolverPolicy, resolverGrace)
	}
	return nil
}
