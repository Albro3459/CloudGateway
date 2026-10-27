package network

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"slices"
	"strconv"
	"time"
)

const srcValidMarkPath = "/proc/sys/net/ipv4/conf/all/src_valid_mark"

type installPlan struct {
	endpoint netip.AddrPort
	mtu      int
	payload  []byte
}

// Apply installs p, replacing any owned tunnel. Preflight, read, and lookup
// failures leave the current tunnel untouched. Every failure after the first
// kernel change is an *ApplyError: owned changes roll back and, when previous
// is set and a tunnel was applied, previous is reinstalled. The observation
// reports the resulting state either way
func (m *Manager) Apply(ctx context.Context, p Profile, previous *Profile) (Observation, error) {
	if err := p.validate(); err != nil {
		return m.observeWith(ctx, err)
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	old, _ := m.status()
	res, adopt := ownership(old)
	s, err := m.check(ctx, p, res, adopt)
	if err != nil {
		return m.observeWith(ctx, err)
	}
	plan, err := m.plan(ctx, p, s, res, s.fullInstalled(res), netip.AddrPort{})
	if err != nil {
		return m.observeWith(ctx, err)
	}
	physical := s.physicalAddrs(fixed)
	if old != nil || s.anyOwned(res) {
		if err := m.teardown(ctx, old); err != nil {
			return m.observeWith(ctx, &ApplyError{Err: err})
		}
	}
	if err := m.install(ctx, p, plan, physical); err != nil {
		failure := &ApplyError{Err: err}
		current, _ := m.status()
		if err := m.teardown(ctx, current); err != nil {
			failure.Err = errors.Join(failure.Err, err)
			return m.observeWith(ctx, failure)
		}
		if previous != nil && old != nil && old.Phase == PhaseApplied {
			if err := m.restore(ctx, *previous, old, s); err != nil {
				failure.Err = errors.Join(failure.Err, fmt.Errorf("network: restoring previous profile: %w", err))
			} else {
				failure.Restored = true
			}
		}
		return m.observeWith(ctx, failure)
	}
	return m.observeWith(ctx, nil)
}

func (m *Manager) observeWith(ctx context.Context, err error) (Observation, error) {
	obs, _ := m.Observe(ctx)
	return obs, err
}

// plan does every read an install needs before anything changes. A valid
// endpoint skips the lookup
func (m *Manager) plan(ctx context.Context, p Profile, s *snapshot, installed Resources, outside bool, endpoint netip.AddrPort) (installPlan, error) {
	var err error
	if !endpoint.IsValid() {
		ownIndex := 0
		if s.own != nil {
			ownIndex = s.own.Index
		}
		if endpoint, err = m.resolveEndpoint(ctx, p.EndpointHost, p.EndpointPort, outside, ownIndex, installed.FwMark); err != nil {
			return installPlan{}, err
		}
	}
	if err := checkEndpoint(endpoint.Addr(), p.Mode, p.AllowedIPs, p.DNS); err != nil {
		return installPlan{}, err
	}
	mtu := p.MTU
	if mtu == 0 {
		if mtu, err = m.endpointMTU(ctx, endpoint.Addr(), s, installed.FwMark); err != nil {
			return installPlan{}, err
		}
	}
	var mark uint32
	if p.Mode == ModeFull {
		mark = fixed.FwMark
	}
	payload, err := p.SetConf(endpoint, mark)
	if err != nil {
		return installPlan{}, fmt.Errorf("network: rendering setconf: %w", err)
	}
	return installPlan{endpoint: endpoint, mtu: mtu, payload: payload}, nil
}

func (m *Manager) install(ctx context.Context, p Profile, plan installPlan, physical []netip.Addr) error {
	res := fixed
	j := &Journal{
		Version:    JournalVersion,
		Phase:      PhaseApplying,
		ProfileID:  p.ID,
		ConfigHash: p.ConfigHash,
		Mode:       p.Mode,
		Host:       p.EndpointHost,
		Endpoint:   plan.endpoint,
		PeerKey:    p.PeerPublicKey,
		Addresses:  p.Addresses,
		AllowedIPs: p.AllowedIPs,
		DNS:        p.DNS,
		Search:     p.SearchDomains,
		MTU:        plan.mtu,
		Resources:  res,
	}
	m.setTransition(transitionApplying)
	defer m.setTransition(transitionNone)
	m.resolverLost = time.Time{}
	if err := m.commit(j); err != nil {
		return err
	}
	commands := []command{
		nftScript(res, p.Addresses, j.Mode == ModeFull),
		ipCommand("link", "add", "dev", res.PendingInterface, "type", "wireguard"),
		ipCommand("link", "set", "dev", res.PendingInterface, "alias", res.Alias),
		ipCommand("link", "set", "dev", res.PendingInterface, "name", res.Interface),
		{tool: ToolWG, args: []string{"setconf", res.Interface, "/dev/stdin"}, stdin: plan.payload},
	}
	for _, prefix := range p.Addresses {
		commands = append(commands, ipCommand(familyFlag(addrFamily(prefix.Addr())), "address", "add", prefix.String(), "dev", res.Interface))
	}
	commands = append(commands,
		ipCommand("link", "set", "dev", res.Interface, "mtu", strconv.Itoa(plan.mtu)),
		ipCommand("link", "set", "dev", res.Interface, "up"))
	for _, r := range desiredRoutes(j) {
		commands = append(commands, routeCommand(res, "add", r))
	}
	if err := m.runAll(ctx, commands); err != nil {
		return err
	}
	if j.Mode == ModeFull {
		// Strict rp_filter drops the server's replies without it. Like wg-quick, it stays set after down
		if err := m.exec.WriteFile(srcValidMarkPath, []byte("1\n")); err != nil {
			return fmt.Errorf("network: setting src_valid_mark: %w", err)
		}
		commands = nil
		for _, r := range desiredRules(j, physical) {
			commands = append(commands, ruleAddCommand(res, r))
		}
		commands = append(commands, resolverCommands(res, p.DNS, p.SearchDomains)...)
		if err := m.runAll(ctx, commands); err != nil {
			return err
		}
	}
	applied := *j
	applied.Phase = PhaseApplied
	return m.commit(&applied)
}

// restore reinstalls the previous profile after a failed replacement, reusing
// its resolved endpoint when the host is unchanged. It only accepts the profile
// the replaced journal describes
func (m *Manager) restore(ctx context.Context, p Profile, old *Journal, s *snapshot) error {
	if p.ID != old.ProfileID || p.ConfigHash != old.ConfigHash || p.Mode != old.Mode {
		return errors.New("network: previous profile does not match the replaced tunnel")
	}
	if err := p.validate(); err != nil {
		return err
	}
	var endpoint netip.AddrPort
	if p.EndpointHost == old.Host && p.EndpointPort == old.Endpoint.Port() {
		endpoint = old.Endpoint
	}
	if p.MTU == 0 {
		p.MTU = old.MTU
	}
	plan, err := m.plan(ctx, p, s, fixed, false, endpoint)
	if err != nil {
		return err
	}
	if err := m.install(ctx, p, plan, s.physicalAddrs(fixed)); err != nil {
		current, _ := m.status()
		return errors.Join(err, m.teardown(ctx, current))
	}
	return nil
}

// teardown removes owned resources found by the journal's resource set, or by
// fixed identity without one, and clears the journal once a fresh read shows none remain
func (m *Manager) teardown(ctx context.Context, j *Journal) error {
	res, adoptPending := ownership(j)
	m.setTransition(transitionRemoving)
	defer m.setTransition(transitionNone)
	if j != nil {
		removing := *j
		removing.Phase = PhaseRemoving
		if err := m.commit(&removing); err != nil {
			return err
		}
	}
	s, err := m.read(ctx, res, adoptPending, false)
	if err != nil {
		return err
	}
	var errs []error
	owned := s.ownedRules(res)
	slices.SortStableFunc(owned, func(a, b rule) int { return b.Priority - a.Priority })
	for _, r := range owned {
		if _, err := m.run(ctx, ruleDelCommand(res, r.key())); err != nil {
			errs = append(errs, err)
		}
	}
	if s.own != nil {
		if (j == nil || j.Mode == ModeFull) && m.exec.Available(ToolResolvectl) {
			// Deleting the link also drops resolved's state for it, so a failed revert is not fatal
			_, _ = m.run(ctx, command{tool: ToolResolvectl, args: []string{"revert", res.Interface}})
		}
		if _, err := m.run(ctx, ipCommand("link", "del", "dev", res.Interface)); err != nil {
			errs = append(errs, err)
		}
	}
	if s.pending != nil {
		if _, err := m.run(ctx, ipCommand("link", "del", "dev", res.PendingInterface)); err != nil {
			errs = append(errs, err)
		}
	}
	if s.hasTable(res) {
		if _, err := m.run(ctx, nftDeleteScript(res)); err != nil {
			errs = append(errs, err)
		}
	}
	if s, err = m.read(ctx, res, adoptPending, false); err != nil {
		return errors.Join(append(errs, err)...)
	}
	if s.anyOwned(res) {
		return errors.Join(append(errs, ErrTeardownIncomplete)...)
	}
	return m.commit(nil)
}

// Down removes every owned resource, using the journal when there is one and
// fixed identities otherwise. It succeeds only after a fresh read shows none remain
func (m *Manager) Down(ctx context.Context) (Observation, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, _ := m.status()
	return m.observeWith(ctx, m.teardown(ctx, j))
}
