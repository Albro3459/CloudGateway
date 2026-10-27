package release

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

// DaemonPath is the daemon executable inside a release directory. Its SHA-256 is the codeHash
const DaemonPath = "bin/cloudgatewayd"

// Hash returns the lowercase hex SHA-256 of the file at path
func Hash(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	return hashFile(file)
}

func hashFile(file *os.File) (string, error) {
	sum := sha256.New()
	if _, err := io.Copy(sum, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(sum.Sum(nil)), nil
}

// Installed reads the release the current link points at. Its version is the
// resolved directory name and its codeHash is the SHA-256 of bin/cloudgatewayd.
// The daemon asks on every request, so the hash is cached by file identity
type Installed struct {
	link string

	mu   sync.Mutex
	info os.FileInfo
	hash string
}

func NewInstalled(link string) *Installed { return &Installed{link: link} }

func (i *Installed) Identity() (ipc.BuildIdentity, error) {
	dir, err := filepath.EvalSymlinks(i.link)
	if err != nil {
		return ipc.BuildIdentity{}, err
	}
	version := filepath.Base(dir)
	if !ValidVersion(version) {
		return ipc.BuildIdentity{}, fmt.Errorf("release: %s is not a release directory", dir)
	}
	hash, err := i.daemonHash(filepath.Join(dir, DaemonPath))
	if err != nil {
		return ipc.BuildIdentity{}, err
	}
	return ipc.BuildIdentity{Version: version, Build: version, CodeHash: hash}, nil
}

func (i *Installed) daemonHash(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("release: %s is not a regular file", path)
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	if i.info != nil && os.SameFile(i.info, info) && i.info.Size() == info.Size() && i.info.ModTime().Equal(info.ModTime()) {
		return i.hash, nil
	}
	hash, err := hashFile(file)
	if err != nil {
		return "", err
	}
	i.info, i.hash = info, hash
	return hash, nil
}
