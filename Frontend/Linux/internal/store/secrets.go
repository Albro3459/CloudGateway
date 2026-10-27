package store

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"path/filepath"
)

// SecretRecord is one retained canonical WireGuard config, bound to the
// config it was authorized for
type SecretRecord struct {
	ConfigID   string `json:"configId"`
	ConfigHash string `json:"configHash"`
	Config     Secret `json:"config"`
}

func (r SecretRecord) valid() bool {
	return ValidIdentifier(r.ConfigID) && validHash(r.ConfigHash) && r.Config != ""
}

// ValidSecretReference reports whether reference has the opaque 32 lowercase hex form
func ValidSecretReference(reference string) bool {
	return len(reference) == 32 && isLowerHex(reference)
}

// PutSecret stores record under a new random reference
func (s *Store) PutSecret(record SecretRecord) (string, error) {
	if !record.valid() {
		return "", errors.New("store: invalid secret record")
	}
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", err
	}
	reference := hex.EncodeToString(bytes[:])
	if err := s.save(s.secretPath(reference), record); err != nil {
		return "", err
	}
	return reference, nil
}

func (s *Store) GetSecret(reference string) (SecretRecord, error) {
	if !ValidSecretReference(reference) {
		return SecretRecord{}, fmt.Errorf("%w: invalid secret reference", ErrMissing)
	}
	var record SecretRecord
	if err := readJSON(s.secretPath(reference), &record, 64<<10); err != nil {
		return SecretRecord{}, err
	}
	if !record.valid() {
		return SecretRecord{}, fmt.Errorf("%w: invalid secret record", ErrUnreadable)
	}
	return record, nil
}

// DeleteSecret succeeds when the record is already gone
func (s *Store) DeleteSecret(reference string) error {
	if !ValidSecretReference(reference) {
		return errors.New("store: invalid secret reference")
	}
	return s.remove(s.secretPath(reference))
}

func (s *Store) secretPath(reference string) string {
	return filepath.Join(s.dir, secretsDir, reference)
}
