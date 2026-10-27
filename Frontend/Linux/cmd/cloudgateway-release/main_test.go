package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/ed25519"
	"crypto/rand"
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

func testSigner(t *testing.T) (ed25519.PrivateKey, string) {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := release.EncodePublicKey(public)
	if err != nil {
		t.Fatal(err)
	}
	return private, encoded
}

func TestRunValidatesArguments(t *testing.T) {
	cases := []struct {
		args []string
		want string
	}{
		{nil, "Usage:"},
		{[]string{"publish"}, `unknown command "publish"`},
		{[]string{"keygen"}, "keygen needs -out"},
		{[]string{"keygen", "-out", "a", "extra"}, `unexpected argument "extra"`},
		{[]string{"build", "-key", "k", "-out", "o"}, "build needs -version in x.y.z form"},
		{[]string{"build", "-version", "v1.0.0", "-key", "k", "-out", "o"}, "build needs -version in x.y.z form"},
		{[]string{"build", "-version", "1.0.0", "-out", "o"}, "build needs -key"},
		{[]string{"build", "-version", "1.0.0", "-key", "k"}, "build needs -out"},
		{[]string{"build", "-bogus"}, "flag provided but not defined: -bogus"},
	}
	for _, c := range cases {
		var stdout, stderr bytes.Buffer
		if code := run(c.args, &stdout, &stderr); code != 2 || !strings.Contains(stderr.String(), c.want) {
			t.Errorf("run(%q) = %d, stderr %q", c.args, code, stderr.String())
		}
	}
	options, err := parseBuildArgs([]string{"-version", "1.0.2", "-key", "k", "-out", "o", "-env", "e"}, io.Discard)
	if err != nil || options != (buildOptions{version: "1.0.2", keyPath: "k", outDir: "o", envPath: "e"}) {
		t.Fatalf("parseBuildArgs = %+v, %v", options, err)
	}
}

func TestKeygenWritesPrivateKeyAndPrintsPublicKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "release.key")
	var stdout, stderr bytes.Buffer
	if code := run([]string{"keygen", "-out", path}, &stdout, &stderr); code != 0 {
		t.Fatalf("keygen = %d: %s", code, stderr.String())
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("key file %v, %v", info, err)
	}
	lines := strings.Split(strings.TrimSpace(stdout.String()), "\n")
	public := lines[len(lines)-1]
	if _, err := loadSigner(path, public); err != nil {
		t.Fatalf("printed key does not match the private key: %v", err)
	}
	if code := run([]string{"keygen", "-out", path}, io.Discard, &stderr); code != 1 || !strings.Contains(stderr.String(), "exists") {
		t.Fatalf("keygen overwrote %s: %d %s", path, code, stderr.String())
	}
}

func TestLoadSignerRequiresPinnedMatchingKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "release.key")
	if code := run([]string{"keygen", "-out", path}, io.Discard, io.Discard); code != 0 {
		t.Fatal("keygen failed")
	}
	if _, err := loadSigner(path, ""); !errors.Is(err, release.ErrNoPublicKey) {
		t.Errorf("empty pinned key: %v", err)
	}
	_, other := testSigner(t)
	if _, err := loadSigner(path, other); err == nil || !strings.Contains(err.Error(), "does not match release.PublicKey") {
		t.Errorf("other key: %v", err)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := loadSigner(path, other); err == nil || !strings.Contains(err.Error(), "readable by other users") {
		t.Errorf("open key file: %v", err)
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
	_, public := testSigner(t)
	stamped, err := stampInstaller(install.Script, "1.2.3", public)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(stamped, []byte("\nRELEASE_VERSION=\"1.2.3\"\n")) || !bytes.Contains(stamped, []byte("\nPINNED_PUBLIC_KEY=\""+public+"\"\n")) {
		t.Fatal("placeholders not stamped")
	}
	if _, err := stampInstaller(stamped, "1.2.3", public); err == nil {
		t.Error("stamped an already stamped installer")
	}
	if _, err := stampInstaller(install.Script, "1.2.3\"; reboot; \"", public); err == nil {
		t.Error("stamped an invalid version")
	}
	if _, err := stampInstaller(install.Script, "1.2.3", ""); !errors.Is(err, release.ErrNoPublicKey) {
		t.Errorf("empty key: %v", err)
	}
}

func TestPackageReleaseWritesVerifiedAssetsOnce(t *testing.T) {
	signer, public := testSigner(t)
	out := t.TempDir()
	params := fixtureParams(out, "1.0.0", 1, signer, public)
	codeHash, err := packageRelease(params)
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(out, "linux-v1.0.0")
	data, _ := os.ReadFile(filepath.Join(dir, release.ManifestName))
	signature, _ := os.ReadFile(filepath.Join(dir, release.SignatureName))
	manifest, err := release.Verify(data, signature, public)
	if err != nil || codeHash != release.CodeHash(data) || manifest.IPCVersion != 1 || manifest.StorageVersion != 1 {
		t.Fatalf("manifest %+v, codeHash %s, %v", manifest, codeHash, err)
	}
	for _, arch := range release.Arches {
		archive, ok := manifest.Archive(arch)
		contents, err := os.ReadFile(filepath.Join(dir, archive.Path))
		if !ok || err != nil || entry(arch, release.KindArchive, archive.Path, contents) != archive {
			t.Errorf("%s archive %+v %v", arch, archive, err)
		}
		if len(manifest.Files(arch)) != 3 {
			t.Errorf("%s files %+v", arch, manifest.Files(arch))
		}
	}
	entries, _ := os.ReadDir(out)
	if len(entries) != 1 {
		t.Errorf("left temporary output: %v", entries)
	}

	if _, err := packageRelease(params); err == nil || !strings.Contains(err.Error(), "Refusing to overwrite release 1.0.0") {
		t.Fatalf("second package: %v", err)
	}
	again := fixtureParams(t.TempDir(), "1.0.0", 1, signer, public)
	againHash, err := packageRelease(again)
	if err != nil || againHash != codeHash {
		t.Fatalf("repackaged codeHash %s, want %s, %v", againHash, codeHash, err)
	}
}

func TestCompileIsReproducible(t *testing.T) {
	if testing.Short() {
		t.Skip("cross-compiles the executables twice")
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
	first, err := compile(module, toolchain, "arm64", "9.8.7", firebase)
	if err != nil {
		t.Fatal(err)
	}
	// The second build hits the compile cache but links again
	second, err := compile(module, toolchain, "arm64", "9.8.7", firebase)
	if err != nil {
		t.Fatal(err)
	}
	for _, executable := range release.Executables {
		if !bytes.Contains(first[executable], []byte("9.8.7")) {
			t.Errorf("%s lacks the stamped version", executable)
		}
		if !bytes.Equal(first[executable], second[executable]) {
			t.Errorf("%s differs between builds", executable)
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
func fixtureParams(out, version string, storageVersion int, signer ed25519.PrivateKey, public string) packageParams {
	binaries := map[string]map[string][]byte{}
	for _, arch := range release.Arches {
		binaries[arch] = map[string][]byte{}
		for _, executable := range release.Executables {
			name := filepath.Base(executable)
			binaries[arch][executable] = []byte("#!/bin/sh\necho \"" + name + " " + version + " $*\" >>\"$CLOUDGATEWAY_TEST_LOG\"\n")
		}
	}
	return packageParams{outDir: out, version: version, storageVersion: storageVersion, signer: signer, publicKey: public, binaries: binaries}
}
