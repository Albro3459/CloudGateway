package store

import (
	"errors"
	"fmt"
)

// Credentials are the retained Firebase sign-in for one session generation
type Credentials struct {
	AccountID    string `json:"accountId"`
	ProjectID    string `json:"projectId"`
	Generation   uint64 `json:"generation"`
	RefreshToken Secret `json:"refreshToken"`
}

func (c Credentials) valid() bool {
	return c.AccountID != "" && c.ProjectID != "" && c.RefreshToken != ""
}

func (s *Store) LoadCredentials() (Credentials, error) {
	var credentials Credentials
	if err := readJSON(s.path(credentialsFile), &credentials, 64<<10); err != nil {
		return Credentials{}, err
	}
	if !credentials.valid() {
		return Credentials{}, fmt.Errorf("%w: incomplete credentials", ErrUnreadable)
	}
	return credentials, nil
}

func (s *Store) SaveCredentials(credentials Credentials) error {
	if !credentials.valid() {
		return errors.New("store: incomplete credentials")
	}
	return s.save(s.path(credentialsFile), credentials)
}

func (s *Store) ClearCredentials() error {
	return s.remove(s.path(credentialsFile))
}

// Session is the durable auth generation record. Logout saves a session with
// the old generation revoked and LogoutCleanup set before clearing credentials,
// so a restart finishes the logout and never resumes revoked work
type Session struct {
	// Generation advances on every login, logout, and account change
	Generation uint64 `json:"generation"`
	AccountID  string `json:"accountId,omitempty"`
	// RevokedThrough revokes every generation at or below it
	RevokedThrough uint64 `json:"revokedThrough"`
	// LogoutCleanup marks a logout whose local cleanup has not finished
	LogoutCleanup bool `json:"logoutCleanup,omitempty"`
}

func (s Session) Revoked(generation uint64) bool { return generation <= s.RevokedThrough }

func (s *Store) LoadSession() (Session, error) {
	var session Session
	if err := readJSON(s.path(sessionFile), &session, 4<<10); err != nil {
		return Session{}, err
	}
	return session, nil
}

// SaveSession refuses to move the generation or revocation backwards. Without
// a readable record it also refuses to reuse or unrevoke any generation that
// saved credentials or the intent still name
func (s *Store) SaveSession(session Session) error {
	s.sessionMu.Lock()
	defer s.sessionMu.Unlock()
	current, err := s.LoadSession()
	if err == nil && (session.Generation < current.Generation || session.RevokedThrough < current.RevokedThrough) {
		return ErrStale
	}
	if err != nil {
		floor, floorErr := s.sessionFloor()
		if floorErr != nil {
			return floorErr
		}
		if session.RevokedThrough < floor || floor > 0 && session.Generation <= floor {
			return ErrStale
		}
	}
	return s.save(s.path(sessionFile), session)
}

// RecoverSession replaces a missing or malformed session record with one that
// revokes every generation saved credentials or the intent still name, and
// returns it. A readable record is returned unchanged, and an OS read failure
// is returned, since the record may still be fine
func (s *Store) RecoverSession() (Session, error) {
	s.sessionMu.Lock()
	defer s.sessionMu.Unlock()
	current, err := s.LoadSession()
	switch {
	case err == nil:
		return current, nil
	case errors.Is(err, ErrIO):
		return Session{}, err
	}
	floor, err := s.sessionFloor()
	if err != nil {
		return Session{}, err
	}
	return s.writeRevokedSession(floor)
}

// RebuildSession replaces the session record whatever its state, revoking
// every generation at or below known and any that readable credentials or the
// intent name. Logout uses it when the record can't be read, since revoking
// more is the safe direction
func (s *Store) RebuildSession(known uint64) (Session, error) {
	s.sessionMu.Lock()
	defer s.sessionMu.Unlock()
	floor, _ := s.sessionFloor()
	return s.writeRevokedSession(max(floor, known))
}

func (s *Store) writeRevokedSession(floor uint64) (Session, error) {
	session := Session{Generation: floor + 1, RevokedThrough: floor}
	if err := s.save(s.path(sessionFile), session); err != nil {
		return Session{}, err
	}
	return session, nil
}

// sessionFloor is the highest generation saved credentials or the intent name.
// An OS read failure returns ErrIO, since the floor may be too low
func (s *Store) sessionFloor() (uint64, error) {
	var floor uint64
	credentials, err := s.LoadCredentials()
	if errors.Is(err, ErrIO) {
		return 0, err
	}
	if err == nil {
		floor = credentials.Generation
	}
	intent, err := s.LoadIntent()
	if errors.Is(err, ErrIO) {
		return 0, err
	}
	if err == nil {
		floor = max(floor, intent.SessionGeneration)
	}
	return floor, nil
}
