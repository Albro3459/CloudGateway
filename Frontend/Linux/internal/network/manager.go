package network

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"slices"
	"sync"
	"time"
)

type transition int

const (
	transitionNone transition = iota
	transitionApplying
	transitionRemoving
)

type Options struct {
	// Executor defaults to SystemExecutor
	Executor Executor
	// Journal is the last persisted record. Pass nil when there is none or
	// ParseJournal rejects it. A journal with an unknown resource set is ignored
	Journal *Journal
	// Persist durably stores the journal before kernel changes. Nil means nothing
	// is owned anymore. It must not keep or modify the value
	Persist func(*Journal) error
	Now     func() time.Time
	// LookupHost resolves with normal host DNS. Defaults to net.DefaultResolver
	LookupHost func(ctx context.Context, host string) ([]netip.Addr, error)
	// Exchange sends one DNS query over UDP, with SO_MARK when mark is nonzero
	Exchange func(ctx context.Context, server netip.AddrPort, mark uint32, query []byte) ([]byte, error)
}

// Manager serializes changes to the owned resources. Observe runs alongside a
// change and reports it as connecting or disconnecting
type Manager struct {
	exec     Executor
	persist  func(*Journal) error
	now      func() time.Time
	lookup   func(context.Context, string) ([]netip.Addr, error)
	exchange func(context.Context, netip.AddrPort, uint32, []byte) ([]byte, error)

	mu sync.Mutex
	// resolverLost is when Reconcile first found resolved not answering, guarded by mu
	resolverLost time.Time

	stateMu    sync.Mutex
	journal    *Journal
	transition transition
	// generation changes with every journal or transition update
	generation uint64
	// observeSeq orders observations, so a slow one never replaces a newer last
	observeSeq uint64
	last       *Observation
	lastSeq    uint64
}

func New(opts Options) *Manager {
	m := &Manager{
		exec:     opts.Executor,
		persist:  opts.Persist,
		now:      opts.Now,
		lookup:   opts.LookupHost,
		exchange: opts.Exchange,
		journal:  opts.Journal,
	}
	if m.journal != nil && !slices.Contains(knownResources, m.journal.Resources) {
		m.journal = nil
	}
	if m.exec == nil {
		m.exec = SystemExecutor{}
	}
	if m.persist == nil {
		m.persist = func(*Journal) error { return nil }
	}
	if m.now == nil {
		m.now = time.Now
	}
	if m.lookup == nil {
		m.lookup = func(ctx context.Context, host string) ([]netip.Addr, error) {
			return net.DefaultResolver.LookupNetIP(ctx, "ip", host)
		}
	}
	if m.exchange == nil {
		m.exchange = exchangeUDP
	}
	return m
}

func (m *Manager) status() (*Journal, transition) {
	m.stateMu.Lock()
	defer m.stateMu.Unlock()
	return m.journal, m.transition
}

func (m *Manager) setTransition(t transition) {
	m.stateMu.Lock()
	m.transition = t
	m.generation++
	m.stateMu.Unlock()
}

// commit persists j and only then makes it current
func (m *Manager) commit(j *Journal) error {
	var stored *Journal
	if j != nil {
		copied := *j
		stored = &copied
	}
	if err := m.persist(stored); err != nil {
		return fmt.Errorf("network: persisting journal: %w", err)
	}
	m.stateMu.Lock()
	m.journal = j
	m.generation++
	m.stateMu.Unlock()
	return nil
}
