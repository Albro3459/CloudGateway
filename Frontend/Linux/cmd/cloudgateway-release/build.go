package main

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/install"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/release"
)

const (
	modulePath    = "github.com/Albro3459/CloudGateway/Frontend/Linux"
	buildinfoPath = modulePath + "/internal/buildinfo"
)

// Values are stamped with -ldflags -X, which splits on spaces
var configValuePattern = regexp.MustCompile(`^[A-Za-z0-9_.()-]+$`)

type firebaseConfig struct {
	apiKey     string
	projectID  string
	databaseID string
}

// loadFirebase reads KEY=VALUE lines from path, then lets the environment override them
func loadFirebase(path string, required bool, getenv func(string) string) (firebaseConfig, error) {
	values := map[string]string{}
	file, err := os.Open(path)
	switch {
	case err == nil:
		defer file.Close()
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			key, value, ok := strings.Cut(line, "=")
			if !ok {
				return firebaseConfig{}, fmt.Errorf("%s: expected KEY=VALUE, got %q", path, line)
			}
			values[strings.TrimSpace(key)] = strings.Trim(strings.TrimSpace(value), `"'`)
		}
		if err := scanner.Err(); err != nil {
			return firebaseConfig{}, err
		}
	case required || !errors.Is(err, os.ErrNotExist):
		return firebaseConfig{}, err
	}
	get := func(key string) string {
		if value := getenv(key); value != "" {
			return value
		}
		return values[key]
	}
	config := firebaseConfig{
		apiKey:     get("CLOUDGATEWAY_FIREBASE_API_KEY"),
		projectID:  get("CLOUDGATEWAY_FIREBASE_PROJECT_ID"),
		databaseID: get("CLOUDGATEWAY_FIREBASE_DATABASE_ID"),
	}
	if config.databaseID == "" {
		config.databaseID = "(default)"
	}
	if config.apiKey == "" || config.projectID == "" {
		return firebaseConfig{}, fmt.Errorf("set CLOUDGATEWAY_FIREBASE_API_KEY and CLOUDGATEWAY_FIREBASE_PROJECT_ID in the environment or %s", path)
	}
	for _, value := range []string{config.apiKey, config.projectID, config.databaseID} {
		if !configValuePattern.MatchString(value) {
			return firebaseConfig{}, fmt.Errorf("firebase config value %q has unsupported characters", value)
		}
	}
	return config, nil
}

func moduleDir() (string, error) {
	output, err := exec.Command("go", "list", "-m", "-f", "{{.Path}} {{.Dir}}").Output()
	if err != nil {
		return "", fmt.Errorf("run from Frontend/Linux: go list -m: %w", err)
	}
	path, dir, _ := strings.Cut(strings.TrimSpace(string(output)), " ")
	if path != modulePath || dir == "" {
		return "", fmt.Errorf("run from Frontend/Linux, not module %q", path)
	}
	return dir, nil
}

// buildEnv pins everything that changes compiler output: the go.mod
// toolchain, the baseline CPU level, and no experiments, FIPS mode, or local GOFLAGS
func buildEnv(toolchain, arch string) []string {
	return append(os.Environ(), "GOTOOLCHAIN="+toolchain, "CGO_ENABLED=0", "GOOS=linux", "GOARCH="+arch,
		"GOAMD64=v1", "GOARM64=v8.0", "GOEXPERIMENT=", "GOFIPS140=off", "GOFLAGS=")
}

// moduleToolchain reads the toolchain line from go.mod and checks go resolves to it
func moduleToolchain(module string) (string, error) {
	data, err := os.ReadFile(filepath.Join(module, "go.mod"))
	if err != nil {
		return "", err
	}
	toolchain := ""
	for _, line := range strings.Split(string(data), "\n") {
		if fields := strings.Fields(line); len(fields) == 2 && fields[0] == "toolchain" {
			toolchain = fields[1]
		}
	}
	if toolchain == "" {
		return "", errors.New("go.mod has no toolchain line to pin the release build")
	}
	command := exec.Command("go", "env", "GOVERSION")
	command.Dir = module
	command.Env = buildEnv(toolchain, "amd64")
	output, err := command.Output()
	if err != nil {
		return "", fmt.Errorf("go env GOVERSION with GOTOOLCHAIN=%s: %w", toolchain, err)
	}
	if version := strings.TrimSpace(string(output)); version != toolchain {
		return "", fmt.Errorf("go resolves to %s, not the go.mod toolchain %s", version, toolchain)
	}
	return toolchain, nil
}

// sourceCommit returns HEAD and refuses uncommitted or untracked changes in
// dir, which the build would compile, unless allowDirty is set
func sourceCommit(dir string, allowDirty bool) (string, bool, error) {
	git := func(args ...string) (string, error) {
		command := exec.Command("git", args...)
		command.Dir = dir
		output, err := command.Output()
		if err != nil {
			return "", fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
		}
		return strings.TrimSpace(string(output)), nil
	}
	commit, err := git("rev-parse", "--verify", "HEAD")
	if err != nil {
		return "", false, err
	}
	status, err := git("status", "--porcelain", "--untracked-files=all", "--", ".")
	if err != nil {
		return "", false, err
	}
	dirty := status != ""
	if dirty && !allowDirty {
		return "", true, fmt.Errorf("%s has uncommitted changes. Commit them, or pass -allow-dirty for a test build:\n%s", dir, status)
	}
	return commit, dirty, nil
}

// compile builds both executables reproducibly and returns them by release path
func compile(module, toolchain, arch, version string, firebase firebaseConfig) (map[string][]byte, error) {
	dir, err := os.MkdirTemp("", "cloudgateway-release-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	ldflags := strings.Join([]string{
		"-s", "-w", "-buildid=",
		"-X", buildinfoPath + ".Version=" + version,
		"-X", buildinfoPath + ".FirebaseAPIKey=" + firebase.apiKey,
		"-X", buildinfoPath + ".FirebaseProjectID=" + firebase.projectID,
		"-X", buildinfoPath + ".FirebaseDatabaseID=" + firebase.databaseID,
	}, " ")
	binaries := map[string][]byte{}
	for _, executable := range release.Executables {
		output := filepath.Join(dir, path.Base(executable))
		command := exec.Command("go", "build", "-trimpath", "-buildvcs=false", "-ldflags", ldflags,
			"-o", output, "./cmd/"+path.Base(executable))
		command.Dir = module
		command.Env = buildEnv(toolchain, arch)
		command.Stdout, command.Stderr = os.Stderr, os.Stderr
		if err := command.Run(); err != nil {
			return nil, fmt.Errorf("build %s for linux/%s: %w", executable, arch, err)
		}
		if binaries[executable], err = os.ReadFile(output); err != nil {
			return nil, err
		}
	}
	return binaries, nil
}

type packageParams struct {
	outDir         string
	version        string
	storageVersion int
	signer         ed25519.PrivateKey
	publicKey      string
	// binaries maps each architecture to its executables by release path
	binaries map[string]map[string][]byte
}

// packageRelease writes archives, the signed manifest, and the stamped
// installer to a new outDir/linux-v<version> and returns the manifest codeHash
func packageRelease(p packageParams) (string, error) {
	if err := os.MkdirAll(p.outDir, 0o755); err != nil {
		return "", err
	}
	// Mkdir claims the release dir, so an existing one, even empty, is never
	// reused. Assets go to a temp dir that replaces the empty claim at the end,
	// so a killed build never leaves a partial release
	finalDir := filepath.Join(p.outDir, "linux-v"+p.version)
	if err := os.Mkdir(finalDir, 0o755); err != nil {
		if errors.Is(err, os.ErrExist) {
			return "", fmt.Errorf("%s already exists. Refusing to overwrite release %s", finalDir, p.version)
		}
		return "", err
	}
	dir, err := os.MkdirTemp(p.outDir, ".linux-v"+p.version+"-")
	if err != nil {
		os.Remove(finalDir)
		return "", err
	}
	defer os.RemoveAll(dir)
	complete := false
	defer func() {
		if !complete {
			os.Remove(finalDir)
		}
	}()

	manifest := release.Manifest{
		SchemaVersion: release.SchemaVersion, Version: p.version,
		IPCVersion: ipc.Version, StorageVersion: p.storageVersion,
	}
	for _, arch := range release.Arches {
		files := map[string][]byte{release.UnitName: install.Unit}
		for _, executable := range release.Executables {
			if p.binaries[arch][executable] == nil {
				return "", fmt.Errorf("no %s build of %s", arch, executable)
			}
			files[executable] = p.binaries[arch][executable]
		}
		archive, err := writeArchive(files)
		if err != nil {
			return "", err
		}
		name := release.ArchiveName(p.version, arch)
		if err := os.WriteFile(filepath.Join(dir, name), archive, 0o644); err != nil {
			return "", err
		}
		manifest.Entries = append(manifest.Entries, entry(arch, release.KindArchive, name, archive))
		for name, contents := range files {
			manifest.Entries = append(manifest.Entries, entry(arch, release.KindFile, name, contents))
		}
	}
	data, err := manifest.Encode()
	if err != nil {
		return "", err
	}
	signature := ed25519.Sign(p.signer, data)
	if _, err := release.Verify(data, signature, p.publicKey); err != nil {
		return "", err
	}
	script, err := stampInstaller(install.Script, p.version, p.publicKey)
	if err != nil {
		return "", err
	}
	for name, contents := range map[string][]byte{release.ManifestName: data, release.SignatureName: signature, "install.sh": script} {
		if err := os.WriteFile(filepath.Join(dir, name), contents, 0o644); err != nil {
			return "", err
		}
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		return "", err
	}
	// macOS refuses rename over an empty dir. Remove fails if anything filled the claim
	if err := os.Remove(finalDir); err != nil {
		return "", err
	}
	if err := os.Rename(dir, finalDir); err != nil {
		return "", err
	}
	complete = true
	return release.CodeHash(data), nil
}

func entry(arch, kind, name string, contents []byte) release.Entry {
	sum := sha256.Sum256(contents)
	return release.Entry{Arch: arch, Kind: kind, Path: name, Size: int64(len(contents)), SHA256: hex.EncodeToString(sum[:])}
}

// writeArchive writes a tar.gz with sorted entries, zero mtimes, root
// ownership, and fixed modes so the same inputs give the same bytes
func writeArchive(files map[string][]byte) ([]byte, error) {
	names := map[string]bool{}
	for name := range files {
		names[name] = true
		for dir := path.Dir(name); dir != "."; dir = path.Dir(dir) {
			names[dir+"/"] = true
		}
	}
	sorted := make([]string, 0, len(names))
	for name := range names {
		sorted = append(sorted, name)
	}
	slices.Sort(sorted)

	var out bytes.Buffer
	compressor, err := gzip.NewWriterLevel(&out, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	archive := tar.NewWriter(compressor)
	for _, name := range sorted {
		header := &tar.Header{
			Name: name, Typeflag: tar.TypeDir, Mode: 0o755, ModTime: time.Unix(0, 0),
			Uname: "root", Gname: "root", Format: tar.FormatUSTAR,
		}
		contents := files[name]
		if !strings.HasSuffix(name, "/") {
			header.Typeflag, header.Size = tar.TypeReg, int64(len(contents))
			if !strings.HasPrefix(name, "bin/") {
				header.Mode = 0o644
			}
		}
		if err := archive.WriteHeader(header); err != nil {
			return nil, err
		}
		if _, err := archive.Write(contents); err != nil {
			return nil, err
		}
	}
	if err := archive.Close(); err != nil {
		return nil, err
	}
	if err := compressor.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

// stampInstaller fills the release version and pinned key placeholders in install.sh
func stampInstaller(script []byte, version, publicKey string) ([]byte, error) {
	if !release.ValidVersion(version) {
		return nil, fmt.Errorf("invalid version %q", version)
	}
	if _, err := release.ParsePublicKey(publicKey); err != nil {
		return nil, err
	}
	for placeholder, value := range map[string]string{"RELEASE_VERSION": version, "PINNED_PUBLIC_KEY": publicKey} {
		line := []byte("\n" + placeholder + "=\"\"\n")
		if bytes.Count(script, line) != 1 {
			return nil, fmt.Errorf("install.sh needs exactly one %s=\"\" line", placeholder)
		}
		script = bytes.Replace(script, line, []byte("\n"+placeholder+"=\""+value+"\"\n"), 1)
	}
	return script, nil
}
