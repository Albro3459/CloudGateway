package store

import (
	"fmt"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

// UpdateRecord is the managed update's durable recovery record. The daemon
// saves it before restarting onto the installed release, and the new daemon
// completes it
type UpdateRecord struct {
	ID         string            `json:"id"`
	Phase      ipc.UpdatePhase   `json:"phase"`
	Target     ipc.BuildIdentity `json:"target"`
	Identifier string            `json:"identifier,omitempty"`
	Reconnect  bool              `json:"reconnect"`
	CreatedAt  time.Time         `json:"createdAt"`
	UpdatedAt  time.Time         `json:"updatedAt"`
	// Error and Warning are public CLI error codes
	Error   string `json:"error,omitempty"`
	Warning string `json:"warning,omitempty"`
}

func (u UpdateRecord) Status() ipc.UpdateStatus {
	return ipc.UpdateStatus{
		ID: u.ID, Phase: u.Phase, Target: u.Target, Identifier: u.Identifier,
		Reconnect: u.Reconnect, Error: u.Error, Warning: u.Warning,
	}
}

func (s *Store) LoadUpdate() (UpdateRecord, error) {
	var record UpdateRecord
	if err := readJSON(s.path(updateFile), &record, 64<<10); err != nil {
		return UpdateRecord{}, err
	}
	if record.ID == "" || record.Phase == "" {
		return UpdateRecord{}, fmt.Errorf("%w: incomplete update record", ErrUnreadable)
	}
	return record, nil
}

func (s *Store) SaveUpdate(record UpdateRecord) error {
	if record.ID == "" || record.Phase == "" {
		return fmt.Errorf("store: incomplete update record")
	}
	return s.save(s.path(updateFile), record)
}

func (s *Store) ClearUpdate() error {
	return s.remove(s.path(updateFile))
}
