// Package store keeps cloudgatewayd state in one private directory. Every file
// is replaced atomically, read with a size bound, and readable only by the daemon
package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// StorageVersion is the newest on-disk format this release reads and writes
const StorageVersion = 1

var (
	ErrMissing = errors.New("store: missing")
	// ErrUnreadable covers I/O failures, oversized files, and malformed contents
	ErrUnreadable = errors.New("store: unreadable")
	// ErrNewerStorage means a newer release wrote the state directory
	ErrNewerStorage = errors.New("store: written by a newer release")
	// ErrStale refuses a record that would move a durable revision or generation backwards
	ErrStale = errors.New("store: stale record")
	// ErrReadOnly refuses writes to a store opened for cleanup with another storage version
	ErrReadOnly = errors.New("store: read-only")

	errTooLarge = errors.New("too large")
)

const (
	versionFile     = "storage.json"
	credentialsFile = "credentials.json"
	sessionFile     = "session.json"
	intentFile      = "intent.json"
	receiptsFile    = "receipts.json"
	updateFile      = "update.json"
	accountsDir     = "accounts"
	secretsDir      = "secrets"

	maxRecordBytes = 1 << 20
)

type Store struct {
	dir      string
	readOnly bool
	accounts *AccountCache
}

// Open prepares dir and checks its storage version. A newer version is
// refused so an older daemon never rewrites a format it does not understand
func Open(dir string) (*Store, error) {
	for _, path := range []string{dir, filepath.Join(dir, accountsDir), filepath.Join(dir, secretsDir)} {
		if err := privateDir(path); err != nil {
			return nil, err
		}
	}
	s := &Store{dir: dir, accounts: newAccountCache(filepath.Join(dir, accountsDir))}
	var version struct {
		StorageVersion int `json:"storageVersion"`
	}
	err := readJSON(s.path(versionFile), &version, 4<<10)
	switch {
	case errors.Is(err, ErrMissing):
		version.StorageVersion = StorageVersion
		if err := writeJSON(s.path(versionFile), version); err != nil {
			return nil, err
		}
	case err != nil:
		return nil, err
	case version.StorageVersion > StorageVersion:
		return nil, ErrNewerStorage
	case version.StorageVersion < 1:
		return nil, fmt.Errorf("%w: storage version %d", ErrUnreadable, version.StorageVersion)
	}
	// TODO: migrate older storage versions here once a second version exists
	removeTempFiles(dir)
	removeTempFiles(filepath.Join(dir, secretsDir))
	if entries, err := os.ReadDir(filepath.Join(dir, accountsDir)); err == nil {
		for _, entry := range entries {
			if entry.IsDir() {
				removeTempFiles(filepath.Join(dir, accountsDir, entry.Name()))
			}
		}
	}
	return s, nil
}

// OpenForCleanup opens dir for uninstall cleanup whatever its storage version,
// so the intent and network journal stay reachable. It creates nothing, and
// unless the storage version is current every write returns ErrReadOnly, so
// it never rewrites a format it does not understand
func OpenForCleanup(dir string) (*Store, error) {
	if info, err := os.Lstat(dir); err == nil {
		if stat, ok := info.Sys().(*syscall.Stat_t); !info.IsDir() || !ok || int(stat.Uid) != os.Geteuid() {
			return nil, fmt.Errorf("%s is not a directory owned by the daemon user", dir)
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	var version struct {
		StorageVersion int `json:"storageVersion"`
	}
	readOnly := readJSON(filepath.Join(dir, versionFile), &version, 4<<10) != nil || version.StorageVersion != StorageVersion
	accounts := newAccountCache(filepath.Join(dir, accountsDir))
	accounts.readOnly = readOnly
	return &Store{dir: dir, readOnly: readOnly, accounts: accounts}, nil
}

// ReadOnly reports whether writes are refused
func (s *Store) ReadOnly() bool { return s.readOnly }

func (s *Store) Dir() string { return s.dir }

// Accounts is the per-account inventory cache
func (s *Store) Accounts() *AccountCache { return s.accounts }

func (s *Store) path(name string) string { return filepath.Join(s.dir, name) }

// LoadReceipts returns the operation registry's durable receipts
func (s *Store) LoadReceipts() ([]byte, error) {
	return readFile(s.path(receiptsFile), maxRecordBytes)
}

func (s *Store) SaveReceipts(data []byte) error {
	if s.readOnly {
		return ErrReadOnly
	}
	return writeFile(s.path(receiptsFile), data)
}

func (s *Store) save(path string, value any) error {
	if s.readOnly {
		return ErrReadOnly
	}
	return writeJSON(path, value)
}

func (s *Store) remove(path string) error {
	if s.readOnly {
		return ErrReadOnly
	}
	return removeFile(path)
}

// privateDir creates path as a 0700 directory owned by the daemon user
func privateDir(path string) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("%s is not a directory", path)
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || int(stat.Uid) != os.Geteuid() {
		return fmt.Errorf("%s is not owned by the daemon user", path)
	}
	if info.Mode().Perm() != 0o700 {
		return os.Chmod(path, 0o700)
	}
	return nil
}

func readFile(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("%w: %s", ErrMissing, path)
	}
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrUnreadable, err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrUnreadable, err)
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%w: %s is not a regular file", ErrUnreadable, path)
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrUnreadable, err)
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%w: %s: %w", ErrUnreadable, path, errTooLarge)
	}
	return data, nil
}

// readJSON leaves decoder errors out of the result since they can quote file contents
func readJSON(path string, value any, limit int64) error {
	data, err := readFile(path, limit)
	if err != nil {
		return err
	}
	if json.Unmarshal(data, value) != nil {
		return fmt.Errorf("%w: %s is malformed", ErrUnreadable, path)
	}
	return nil
}

func writeJSON(path string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return writeFile(path, data)
}

// writeFile replaces path with a fully synced 0600 file, so a crash leaves
// either the old or the new contents
func writeFile(path string, data []byte) (err error) {
	dir := filepath.Dir(path)
	file, err := os.CreateTemp(dir, "."+filepath.Base(path)+tempMarker+"*")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = file.Close()
			_ = os.Remove(file.Name())
		}
	}()
	if err = file.Chmod(0o600); err != nil {
		return err
	}
	if _, err = file.Write(data); err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	if err = os.Rename(file.Name(), path); err != nil {
		return err
	}
	return syncDir(dir)
}

// tempMarker names in-progress writes, which a crash can leave behind
const tempMarker = ".tmp-"

// removeTempFiles deletes leftover writes in dir. A failure never blocks startup
func removeTempFiles(dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if name := entry.Name(); entry.Type().IsRegular() && strings.HasPrefix(name, ".") && strings.Contains(name, tempMarker) {
			_ = os.Remove(filepath.Join(dir, name))
		}
	}
}

func removeFile(path string) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return syncDir(filepath.Dir(path))
}

func syncDir(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

// Secret holds credential or key material. Formatting a Secret, or an
// exported field holding one, prints a placeholder. fmt cannot call Format on
// unexported fields, so keep a Secret in exported fields or out of formatting
type Secret string

func (Secret) Format(f fmt.State, _ rune) { _, _ = io.WriteString(f, "[redacted]") }
