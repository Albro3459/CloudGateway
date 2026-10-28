package store

import (
	"encoding/json"
	"fmt"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

type IntentPhase string

const (
	PhaseStopped  IntentPhase = "stopped"
	PhaseStarting IntentPhase = "starting"
	PhaseRunning  IntentPhase = "running"
	PhaseStopping IntentPhase = "stopping"
	PhaseFailed   IntentPhase = "failed"
)

// Suppression keeps the daemon from starting or reconnecting on its own
type Suppression string

const (
	SuppressDown            Suppression = "down"
	SuppressLogout          Suppression = "logout"
	SuppressResolverFailure Suppression = "resolverFailure"
)

// Intent is the one durable network intent record. Persist it before every
// kernel change. A newer revision wins over older queued work
type Intent struct {
	Revision          uint64 `json:"revision"`
	AccountID         string `json:"accountId,omitempty"`
	SessionGeneration uint64 `json:"sessionGeneration,omitempty"`
	// ProfileID is the compound config ID signedInUID/regionId/clientId
	ProfileID       string             `json:"profileId,omitempty"`
	SecretReference string             `json:"secretReference,omitempty"`
	ConfigHash      string             `json:"configHash,omitempty"`
	Mode            ipc.Mode           `json:"mode,omitempty"`
	Phase           IntentPhase        `json:"phase"`
	Suppression     Suppression        `json:"suppression,omitempty"`
	FailureCode     ipc.CommandFailure `json:"failureCode,omitempty"`
	// Journal belongs to the network package, which records owned changes here
	Journal json.RawMessage `json:"journal,omitempty"`
}

func (i Intent) valid() bool {
	switch i.Phase {
	case PhaseStopped, PhaseStarting, PhaseRunning, PhaseStopping, PhaseFailed:
	default:
		return false
	}
	switch i.Suppression {
	case "", SuppressDown, SuppressLogout, SuppressResolverFailure:
	default:
		return false
	}
	return i.Mode == "" || i.Mode == ipc.ModeFull || i.Mode == ipc.ModeMesh
}

// LoadIntent returns ErrMissing when no intent was ever saved. ErrUnreadable
// means owned resources exist in an unknown state and must be removed by
// their fixed identities
func (s *Store) LoadIntent() (Intent, error) {
	var intent Intent
	if err := readJSON(s.path(intentFile), &intent, maxRecordBytes); err != nil {
		return Intent{}, err
	}
	if !intent.valid() {
		return Intent{}, fmt.Errorf("%w: invalid intent", ErrUnreadable)
	}
	return intent, nil
}

// SaveIntent requires a revision above the saved one. An unreadable saved
// intent does not block recovery from writing a new one
func (s *Store) SaveIntent(intent Intent) error {
	if !intent.valid() {
		return fmt.Errorf("store: invalid intent")
	}
	if current, err := s.LoadIntent(); err == nil && intent.Revision <= current.Revision {
		return ErrStale
	}
	return s.save(s.path(intentFile), intent)
}
