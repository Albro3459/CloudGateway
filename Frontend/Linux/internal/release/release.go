package release

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

const maxManifestBytes = 64 << 10

var ErrStorageDowngrade = errors.New("release: downgrade crosses a storage format change")

// Release is the verified identity of an installed release directory
type Release struct {
	ipc.BuildIdentity
	Dir            string
	IPCVersion     int
	StorageVersion int
}

// Read verifies the manifest in dir, usually a release directory or the
// current link, against the pinned key. The resolved directory name must
// match the signed version
func Read(dir string) (Release, error) { return read(dir, PublicKey) }

// Running reads the release that holds this executable at bin/<name>. Call it
// once at startup since an update can switch current while the daemon runs
func Running() (Release, error) {
	executable, err := os.Executable()
	if err != nil {
		return Release{}, err
	}
	return running(executable, PublicKey)
}

func running(executable, publicKey string) (Release, error) {
	resolved, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return Release{}, err
	}
	return read(filepath.Dir(filepath.Dir(resolved)), publicKey)
}

func read(dir, publicKey string) (Release, error) {
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return Release{}, err
	}
	data, err := readBounded(filepath.Join(resolved, ManifestName))
	if err != nil {
		return Release{}, err
	}
	signature, err := readBounded(filepath.Join(resolved, SignatureName))
	if err != nil {
		return Release{}, err
	}
	m, err := Verify(data, signature, publicKey)
	if err != nil {
		return Release{}, err
	}
	if filepath.Base(resolved) != m.Version {
		return Release{}, fmt.Errorf("release: %s holds release %s", resolved, m.Version)
	}
	return Release{
		BuildIdentity:  ipc.BuildIdentity{Version: m.Version, Build: m.Version, CodeHash: CodeHash(data)},
		Dir:            resolved,
		IPCVersion:     m.IPCVersion,
		StorageVersion: m.StorageVersion,
	}, nil
}

func readBounded(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxManifestBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxManifestBytes {
		return nil, fmt.Errorf("release: %s is too large", path)
	}
	return data, nil
}

// CheckDowngrade refuses replacing installed with next when next reads an
// older storage format than installed may have written. install.sh applies
// the same rule
func CheckDowngrade(installed, next Release) error {
	if next.StorageVersion >= installed.StorageVersion {
		return nil
	}
	return fmt.Errorf("%w: %s reads storage format %d but %s writes %d",
		ErrStorageDowngrade, next.Version, next.StorageVersion, installed.Version, installed.StorageVersion)
}
