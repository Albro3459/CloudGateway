package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/install"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/release"
)

func TestRunValidatesArguments(t *testing.T) {
	cases := []struct {
		args []string
		want string
	}{
		{nil, "Usage:"},
		{[]string{"publish"}, `unknown command "publish"`},
		{[]string{"keygen"}, `unknown command "keygen"`},
		{[]string{"build", "-out", "o"}, "build needs -version in x.y.z form"},
		{[]string{"build", "-version", "v1.0.0", "-out", "o"}, "build needs -version in x.y.z form"},
		{[]string{"build", "-version", "1.0.0"}, "build needs -out"},
		{[]string{"build", "-version", "1.0.0", "-out", "o", "extra"}, `unexpected argument "extra"`},
		{[]string{"build", "-bogus"}, "flag provided but not defined: -bogus"},
	}
	for _, c := range cases {
		var stdout, stderr bytes.Buffer
		if code := run(c.args, &stdout, &stderr); code != 2 || !strings.Contains(stderr.String(), c.want) {
			t.Errorf("run(%q) = %d, stderr %q", c.args, code, stderr.String())
		}
	}
	options, err := parseBuildArgs([]string{"-version", "1.0.2", "-out", "o", "-env", "e", "-allow-dirty"}, io.Discard)
	if err != nil || options != (buildOptions{version: "1.0.2", outDir: "o", envPath: "e", allowDirty: true}) {
		t.Fatalf("parseBuildArgs = %+v, %v", options, err)
	}
}

func TestLoadFirebase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "release.env")
	contents := "# comment\nCLOUDGATEWAY_FIREBASE_API_KEY=\"file-key\"\nCLOUDGATEWAY_FIREBASE_PROJECT_ID=file-project\n"
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{"CLOUDGATEWAY_FIREBASE_PROJECT_ID": "env-project"}
	config, err := loadFirebase(path, true, func(key string) string { return env[key] })
	if err != nil || config != (firebaseConfig{apiKey: "file-key", projectID: "env-project", databaseID: "(default)"}) {
		t.Fatalf("config = %+v, %v", config, err)
	}

	missing := filepath.Join(t.TempDir(), "missing.env")
	if _, err := loadFirebase(missing, false, func(string) string { return "" }); err == nil || !strings.Contains(err.Error(), "CLOUDGATEWAY_FIREBASE_API_KEY") {
		t.Errorf("no config: %v", err)
	}
	if _, err := loadFirebase(missing, true, func(string) string { return "x" }); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("missing explicit file: %v", err)
	}
	env = map[string]string{"CLOUDGATEWAY_FIREBASE_API_KEY": "a b", "CLOUDGATEWAY_FIREBASE_PROJECT_ID": "p"}
	if _, err := loadFirebase(missing, false, func(key string) string { return env[key] }); err == nil || !strings.Contains(err.Error(), "unsupported characters") {
		t.Errorf("space in value: %v", err)
	}
}

func TestWriteArchiveIsDeterministic(t *testing.T) {
	files := map[string][]byte{
		"bin/cloudgatewayd":     []byte("daemon"),
		"bin/cloudgateway":      []byte("cli"),
		"cloudgatewayd.service": install.Unit,
	}
	first, err := writeArchive(files)
	if err != nil {
		t.Fatal(err)
	}
	second, _ := writeArchive(files)
	if !bytes.Equal(first, second) {
		t.Fatal("archive bytes differ between builds")
	}

	compressed, err := gzip.NewReader(bytes.NewReader(first))
	if err != nil {
		t.Fatal(err)
	}
	if !compressed.ModTime.IsZero() || compressed.Name != "" {
		t.Errorf("gzip header %+v", compressed.Header)
	}
	reader := tar.NewReader(compressed)
	var listing []string
	for {
		header, err := reader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if header.Uid != 0 || header.Gid != 0 || header.Uname != "root" || header.Gname != "root" || header.ModTime.Unix() != 0 {
			t.Errorf("%s header %+v", header.Name, header)
		}
		listing = append(listing, header.Name+" "+os.FileMode(header.Mode).String())
	}
	want := []string{"bin/ -rwxr-xr-x", "bin/cloudgateway -rwxr-xr-x", "bin/cloudgatewayd -rwxr-xr-x", "cloudgatewayd.service -rw-r--r--"}
	if strings.Join(listing, "\n") != strings.Join(want, "\n") {
		t.Fatalf("listing:\n%s", strings.Join(listing, "\n"))
	}
}

func TestStampInstaller(t *testing.T) {
	archives := map[string][]byte{"amd64": []byte("abc"), "arm64": []byte("arm")}
	stamped, err := stampInstaller(install.Script, "1.2.3", 2, archives)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"\nRELEASE_VERSION=\"1.2.3\"\n", "\nSTORAGE_VERSION=\"2\"\n",
		"\nAMD64_ARCHIVE_SIZE=\"3\"\n", "\nAMD64_ARCHIVE_SHA256=\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"\n",
		"\nARM64_ARCHIVE_SIZE=\"3\"\n",
	} {
		if !bytes.Contains(stamped, []byte(want)) {
			t.Errorf("stamped installer lacks %q", want)
		}
	}
	if _, err := stampInstaller(stamped, "1.2.3", 2, archives); err == nil {
		t.Error("stamped an already stamped installer")
	}
	if _, err := stampInstaller(install.Script, "1.2.3\"; reboot; \"", 2, archives); err == nil {
		t.Error("stamped an invalid version")
	}
	if _, err := stampInstaller(install.Script, "1.2.3", 0, archives); err == nil {
		t.Error("stamped storage version 0")
	}
	if _, err := stampInstaller(install.Script, "1.2.3", 2, map[string][]byte{"amd64": []byte("abc")}); err == nil {
		t.Error("stamped without an arm64 archive")
	}
}

func TestPackageReleaseWritesAssetsOnce(t *testing.T) {
	out := t.TempDir()
	params := fixtureParams(out, "1.0.0", 1)
	if err := packageRelease(params); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(out, "linux-v1.0.0")
	script, _ := os.ReadFile(filepath.Join(dir, "install.sh"))
	for _, arch := range release.Arches {
		archive, err := os.ReadFile(filepath.Join(dir, release.ArchiveName("1.0.0", arch)))
		sum := sha256.Sum256(archive)
		if err != nil || !bytes.Contains(script, []byte(strings.ToUpper(arch)+"_ARCHIVE_SHA256=\""+hex.EncodeToString(sum[:])+"\"")) {
			t.Errorf("%s archive not stamped into install.sh: %v", arch, err)
		}
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 3 {
		t.Errorf("release assets: %v", entries)
	}
	if entries, _ := os.ReadDir(out); len(entries) != 1 {
		t.Errorf("left temporary output: %v", entries)
	}

	if err := packageRelease(params); err == nil || !strings.Contains(err.Error(), "Refusing to overwrite release 1.0.0") {
		t.Fatalf("second package: %v", err)
	}
}

func TestCompileStampsVersion(t *testing.T) {
	if testing.Short() {
		t.Skip("cross-compiles the executables")
	}
	module, err := moduleDir()
	if err != nil {
		t.Fatal(err)
	}
	toolchain, err := moduleToolchain(module)
	if err != nil {
		t.Fatal(err)
	}
	firebase := firebaseConfig{apiKey: "test-key", projectID: "test-project", databaseID: "(default)"}
	binaries, err := compile(module, toolchain, "arm64", "9.8.7", firebase)
	if err != nil {
		t.Fatal(err)
	}
	for _, executable := range release.Executables {
		if !bytes.Contains(binaries[executable], []byte("9.8.7")) {
			t.Errorf("%s lacks the stamped version", executable)
		}
	}
}

func TestSourceCommitRefusesDirtyTree(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("needs git")
	}
	dir := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		command := exec.Command("git", append([]string{"-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"}, args...)...)
		command.Dir = dir
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, output)
		}
	}
	git("init", "-q")
	writeFile(t, filepath.Join(dir, "main.go"), "package main\n", 0o644)
	git("add", "main.go")
	git("commit", "-q", "-m", "init")

	commit, dirty, err := sourceCommit(dir, false)
	if err != nil || dirty || len(commit) < 40 {
		t.Fatalf("clean tree: %q %v %v", commit, dirty, err)
	}
	writeFile(t, filepath.Join(dir, "extra.go"), "package main\n", 0o644)
	if _, _, err := sourceCommit(dir, false); err == nil || !strings.Contains(err.Error(), "?? extra.go") {
		t.Errorf("untracked file: %v", err)
	}
	if again, dirty, err := sourceCommit(dir, true); err != nil || !dirty || again != commit {
		t.Errorf("allow dirty: %q %v %v", again, dirty, err)
	}
}

// fixtureParams packages shell scripts as executables so installer tests can run them
func fixtureParams(out, version string, storageVersion int) packageParams {
	binaries := map[string]map[string][]byte{}
	for _, arch := range release.Arches {
		binaries[arch] = map[string][]byte{}
		for _, executable := range release.Executables {
			name := filepath.Base(executable)
			binaries[arch][executable] = []byte("#!/bin/sh\necho \"" + name + " " + version + " $*\" >>\"$CLOUDGATEWAY_TEST_LOG\"\n")
		}
	}
	return packageParams{outDir: out, version: version, storageVersion: storageVersion, binaries: binaries}
}
