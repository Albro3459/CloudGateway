package daemon

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadConfig(t *testing.T) {
	owner := uint32(os.Getuid())
	write := func(t *testing.T, contents string, mode os.FileMode) string {
		t.Helper()
		path := filepath.Join(t.TempDir(), "daemon.json")
		if err := os.WriteFile(path, []byte(contents), mode); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, mode); err != nil {
			t.Fatal(err)
		}
		return path
	}

	config, err := loadConfig(write(t, `{"operatorUid": 1000}`, 0o644), owner)
	if err != nil || config != (Config{OperatorUID: 1000}) {
		t.Fatalf("config = %+v, err = %v", config, err)
	}
	if _, err := loadConfig(filepath.Join(t.TempDir(), "daemon.json"), owner); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("missing err = %v", err)
	}
	for _, contents := range []string{``, `{}`, `{"operatorUid": -1}`, `{"operatorUid": "1000"}`,
		`{"operatorUid": 4294967295}`, `{"operatorUid": 1000} {}`, `[1000]`} {
		if _, err := loadConfig(write(t, contents, 0o644), owner); err == nil {
			t.Fatalf("%q loaded", contents)
		}
	}
	for _, mode := range []os.FileMode{0o664, 0o646} {
		if _, err := loadConfig(write(t, `{"operatorUid": 1000}`, mode), owner); err == nil {
			t.Fatalf("mode %o loaded", mode)
		}
	}
	if _, err := loadConfig(write(t, `{"operatorUid": 1000}`, 0o600), owner+1); err == nil {
		t.Fatal("loaded a file with the wrong owner")
	}
	if _, err := loadConfig(t.TempDir(), owner); err == nil {
		t.Fatal("loaded a directory")
	}
}
