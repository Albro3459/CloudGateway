package release

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidVersion(t *testing.T) {
	for _, good := range []string{"0.0.0", "1.0.0", "1.10.0", "999999999999999999.0.0"} {
		if !ValidVersion(good) {
			t.Errorf("ValidVersion(%q) = false", good)
		}
	}
	for _, bad := range []string{"", "1.0", "1.0.0.0", "v1.0.0", "1.0.0-rc.1", "1.0.0+5", "01.0.0", "1..0", "1.0.-1", "1000000000000000000.0.0", "0.0.0-dev"} {
		if ValidVersion(bad) {
			t.Errorf("ValidVersion(%q) = true", bad)
		}
	}
}

func writeDaemon(t *testing.T, root, version, contents string) string {
	t.Helper()
	dir := filepath.Join(root, "releases", version)
	if err := os.MkdirAll(filepath.Join(dir, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, DaemonPath)
	if err := os.WriteFile(path, []byte(contents), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func link(t *testing.T, root, version string) string {
	t.Helper()
	current := filepath.Join(root, "current")
	_ = os.Remove(current)
	if err := os.Symlink("releases/"+version, current); err != nil {
		t.Fatal(err)
	}
	return current
}

func TestInstalledIdentityThroughCurrentLink(t *testing.T) {
	root := t.TempDir()
	daemon := writeDaemon(t, root, "1.0.1", "abc")
	installed := NewInstalled(link(t, root, "1.0.1"))

	got, err := installed.Identity()
	const abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
	if err != nil || got.Version != "1.0.1" || got.Build != "1.0.1" || got.CodeHash != abc {
		t.Fatalf("identity = %+v, %v", got, err)
	}
	if hash, err := Hash(daemon); err != nil || hash != abc {
		t.Fatalf("Hash = %s, %v", hash, err)
	}

	// A replaced file is hashed again even when its size matches
	if err := os.Remove(daemon); err != nil {
		t.Fatal(err)
	}
	writeDaemon(t, root, "1.0.1", "xyz")
	if got, _ := installed.Identity(); got.CodeHash == abc || len(got.CodeHash) != 64 {
		t.Fatalf("replaced daemon kept codeHash %s", got.CodeHash)
	}

	writeDaemon(t, root, "1.0.2", "abc")
	link(t, root, "1.0.2")
	if got, err := installed.Identity(); err != nil || got.Version != "1.0.2" || got.CodeHash != abc {
		t.Fatalf("after switching current = %+v, %v", got, err)
	}
}

func TestInstalledIdentityRefusesBrokenReleases(t *testing.T) {
	root := t.TempDir()
	writeDaemon(t, root, "dev", "abc")
	installed := NewInstalled(link(t, root, "dev"))
	if _, err := installed.Identity(); err == nil || !strings.Contains(err.Error(), "is not a release directory") {
		t.Errorf("unversioned dir: %v", err)
	}

	if err := os.MkdirAll(filepath.Join(root, "releases", "1.0.0", DaemonPath), 0o755); err != nil {
		t.Fatal(err)
	}
	link(t, root, "1.0.0")
	if _, err := installed.Identity(); err == nil || !strings.Contains(err.Error(), "is not a regular file") {
		t.Errorf("daemon dir: %v", err)
	}

	link(t, root, "1.0.3")
	if _, err := installed.Identity(); err == nil {
		t.Error("dangling current link read")
	}
	if _, err := NewInstalled(filepath.Join(root, "missing")).Identity(); err == nil {
		t.Error("missing current link read")
	}
}
