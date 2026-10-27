package release

import (
	"crypto/ed25519"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeRelease(t *testing.T, root string, m Manifest, private ed25519.PrivateKey) (string, []byte) {
	t.Helper()
	dir := filepath.Join(root, "releases", m.Version)
	if err := os.MkdirAll(filepath.Join(dir, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	data, err := m.Encode()
	if err != nil {
		t.Fatal(err)
	}
	for name, contents := range map[string][]byte{ManifestName: data, SignatureName: ed25519.Sign(private, data), "bin/cloudgatewayd": nil} {
		if err := os.WriteFile(filepath.Join(dir, name), contents, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir, data
}

func TestReadReleaseThroughCurrentLink(t *testing.T) {
	private, public := testKey(t)
	root := t.TempDir()
	dir, data := writeRelease(t, root, testManifest(), private)
	current := filepath.Join(root, "current")
	if err := os.Symlink("releases/1.0.1", current); err != nil {
		t.Fatal(err)
	}

	got, err := read(current, public)
	if err != nil {
		t.Fatal(err)
	}
	resolved, _ := filepath.EvalSymlinks(dir)
	if got.Version != "1.0.1" || got.Build != "1.0.1" || got.CodeHash != CodeHash(data) || len(got.CodeHash) != 64 ||
		got.StorageVersion != 1 || got.IPCVersion != 1 || got.Dir != resolved {
		t.Fatalf("read = %+v", got)
	}

	running, err := running(filepath.Join(current, "bin", "cloudgatewayd"), public)
	if err != nil || running != got {
		t.Fatalf("running = %+v, %v", running, err)
	}
}

func TestReadReleaseRefusesUnverifiedOrMisplaced(t *testing.T) {
	private, public := testKey(t)
	_, otherPublic := testKey(t)
	root := t.TempDir()
	dir, data := writeRelease(t, root, testManifest(), private)

	if _, err := read(dir, otherPublic); !errors.Is(err, ErrBadSignature) {
		t.Errorf("wrong key: %v", err)
	}
	if _, err := read(dir, ""); !errors.Is(err, ErrNoPublicKey) {
		t.Errorf("empty key: %v", err)
	}

	renamed := filepath.Join(root, "releases", "1.0.2")
	if err := os.Rename(dir, renamed); err != nil {
		t.Fatal(err)
	}
	if _, err := read(renamed, public); err == nil || !strings.Contains(err.Error(), "holds release 1.0.1") {
		t.Errorf("renamed dir: %v", err)
	}

	tampered := []byte(strings.Replace(string(data), `"storageVersion": 1`, `"storageVersion": 2`, 1))
	if err := os.WriteFile(filepath.Join(renamed, ManifestName), tampered, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := read(renamed, public); !errors.Is(err, ErrBadSignature) {
		t.Errorf("tampered manifest: %v", err)
	}
	if _, err := read(filepath.Join(root, "missing"), public); err == nil {
		t.Error("missing dir read")
	}
}

func TestCheckDowngrade(t *testing.T) {
	release := func(version string, storage int) Release {
		r := Release{StorageVersion: storage}
		r.Version = version
		return r
	}
	if err := CheckDowngrade(release("1.0.2", 1), release("1.0.1", 1)); err != nil {
		t.Errorf("same storage downgrade: %v", err)
	}
	if err := CheckDowngrade(release("1.0.1", 1), release("1.0.2", 2)); err != nil {
		t.Errorf("upgrade: %v", err)
	}
	err := CheckDowngrade(release("1.0.2", 2), release("1.0.1", 1))
	if !errors.Is(err, ErrStorageDowngrade) || !strings.Contains(err.Error(), "1.0.1 reads storage format 1 but 1.0.2 writes 2") {
		t.Errorf("storage downgrade: %v", err)
	}
}
