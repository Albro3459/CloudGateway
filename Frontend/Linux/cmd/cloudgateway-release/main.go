// Command cloudgateway-release generates the release signing key and builds
// signed Linux release assets. It is a developer tool and is never shipped
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/release"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
)

const usage = `Usage:
  go run ./cmd/cloudgateway-release keygen -out <private key path>
  go run ./cmd/cloudgateway-release build -version <x.y.z> -key <private key path> -out <dir> [-env <file>] [-allow-dirty]

keygen writes a new Ed25519 private key with mode 0600 and prints the public
key to paste into release.PublicKey in internal/release/manifest.go.

build cross-compiles linux/amd64 and linux/arm64 from this module at HEAD with
the go.mod toolchain, then writes signed release assets and the stamped
install.sh to <dir>/linux-v<x.y.z>. It refuses uncommitted changes unless
-allow-dirty is set. A dirty build needs a test key other than the release key,
and pins that key in its binaries and installer so published installs reject
it. It reads the Firebase web config from
CLOUDGATEWAY_FIREBASE_API_KEY, CLOUDGATEWAY_FIREBASE_PROJECT_ID, and
CLOUDGATEWAY_FIREBASE_DATABASE_ID, or from Secrets/release.env. It never
uploads anything
`

var errUsage = errors.New("usage")

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	var err error
	switch {
	case len(args) == 0:
		err = errUsage
	case args[0] == "keygen":
		err = keygen(args[1:], stdout, stderr)
	case args[0] == "build":
		err = build(args[1:], stdout, stderr)
	case args[0] == "-h" || args[0] == "--help" || args[0] == "help":
		fmt.Fprint(stdout, usage)
		return 0
	default:
		err = fmt.Errorf("%w: unknown command %q", errUsage, args[0])
	}
	switch {
	case err == nil:
		return 0
	case errors.Is(err, errUsage):
		if err != errUsage {
			fmt.Fprintf(stderr, "cloudgateway-release: %s\n", strings.TrimPrefix(err.Error(), "usage: "))
		}
		fmt.Fprint(stderr, usage)
		return 2
	default:
		fmt.Fprintf(stderr, "cloudgateway-release: %v\n", err)
		return 1
	}
}

func parseFlags(set *flag.FlagSet, args []string, stderr io.Writer) error {
	set.SetOutput(stderr)
	set.Usage = func() {}
	if err := set.Parse(args); err != nil {
		return fmt.Errorf("%w: %v", errUsage, err)
	}
	if set.NArg() > 0 {
		return fmt.Errorf("%w: unexpected argument %q", errUsage, set.Arg(0))
	}
	return nil
}

func keygen(args []string, stdout, stderr io.Writer) error {
	set := flag.NewFlagSet("keygen", flag.ContinueOnError)
	out := set.String("out", "", "private key path")
	if err := parseFlags(set, args, stderr); err != nil {
		return err
	}
	if *out == "" {
		return fmt.Errorf("%w: keygen needs -out", errUsage)
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	der, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		return err
	}
	encoded, err := release.EncodePublicKey(public)
	if err != nil {
		return err
	}
	file, err := os.OpenFile(*out, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if err := pem.Encode(file, &pem.Block{Type: "PRIVATE KEY", Bytes: der}); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "Wrote the release signing key to %s. Keep it offline and out of git\n", *out)
	fmt.Fprintf(stdout, "Set release.PublicKey in internal/release/manifest.go to:\n%s\n", encoded)
	return nil
}

type buildOptions struct {
	version    string
	keyPath    string
	outDir     string
	envPath    string
	allowDirty bool
}

func parseBuildArgs(args []string, stderr io.Writer) (buildOptions, error) {
	var options buildOptions
	set := flag.NewFlagSet("build", flag.ContinueOnError)
	set.StringVar(&options.version, "version", "", "release version")
	set.StringVar(&options.keyPath, "key", "", "private key path")
	set.StringVar(&options.outDir, "out", "", "output directory")
	set.StringVar(&options.envPath, "env", "", "Firebase config file")
	set.BoolVar(&options.allowDirty, "allow-dirty", false, "build with uncommitted changes")
	if err := parseFlags(set, args, stderr); err != nil {
		return options, err
	}
	switch {
	case !release.ValidVersion(options.version):
		return options, fmt.Errorf("%w: build needs -version in x.y.z form", errUsage)
	case options.keyPath == "":
		return options, fmt.Errorf("%w: build needs -key", errUsage)
	case options.outDir == "":
		return options, fmt.Errorf("%w: build needs -out", errUsage)
	}
	return options, nil
}

func build(args []string, stdout, stderr io.Writer) error {
	options, err := parseBuildArgs(args, stderr)
	if err != nil {
		return err
	}
	module, err := moduleDir()
	if err != nil {
		return err
	}
	commit, dirty, err := sourceCommit(module, options.allowDirty)
	if err != nil {
		return err
	}
	publicKey, testKey := release.PublicKey, ""
	if dirty {
		if testKey, err = testPublicKey(options.keyPath); err != nil {
			return err
		}
		publicKey = testKey
	}
	signer, err := loadSigner(options.keyPath, publicKey)
	if err != nil {
		return err
	}
	toolchain, err := moduleToolchain(module)
	if err != nil {
		return err
	}
	// The archives are compressed in this process, so its Go must match too
	if runtime.Version() != toolchain {
		return fmt.Errorf("run the release tool with %s, not %s: GOTOOLCHAIN=%s go run ./cmd/cloudgateway-release", toolchain, runtime.Version(), toolchain)
	}
	envPath, explicit := options.envPath, options.envPath != ""
	if !explicit {
		envPath = filepath.Join(module, "Secrets", "release.env")
	}
	firebase, err := loadFirebase(envPath, explicit, os.Getenv)
	if err != nil {
		return err
	}
	finalDir := filepath.Join(options.outDir, "linux-v"+options.version)
	if _, err := os.Lstat(finalDir); !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("%s already exists. Refusing to overwrite release %s", finalDir, options.version)
	}
	binaries := map[string]map[string][]byte{}
	for _, arch := range release.Arches {
		fmt.Fprintf(stderr, "Building linux/%s with %s\n", arch, toolchain)
		if binaries[arch], err = compile(module, toolchain, arch, options.version, firebase, testKey); err != nil {
			return err
		}
	}
	codeHash, err := packageRelease(packageParams{
		outDir: options.outDir, version: options.version, storageVersion: store.StorageVersion,
		signer: signer, publicKey: publicKey, binaries: binaries,
	})
	if err != nil {
		return err
	}
	printPublishSteps(stdout, finalDir, options.version, codeHash, toolchain, commit, dirty)
	return nil
}

// testPublicKey encodes the public half of a dirty build's key, which must not be the release key
func testPublicKey(path string) (string, error) {
	signer, err := readSigner(path)
	if err != nil {
		return "", err
	}
	encoded, err := release.EncodePublicKey(signer.Public().(ed25519.PublicKey))
	if err != nil {
		return "", err
	}
	if encoded == release.PublicKey {
		return "", fmt.Errorf("-allow-dirty needs a test key from cloudgateway-release keygen, not the release key")
	}
	return encoded, nil
}

// loadSigner reads a PKCS #8 Ed25519 key and requires it to match the pinned public key
func loadSigner(path, publicKey string) (ed25519.PrivateKey, error) {
	pinned, err := release.ParsePublicKey(publicKey)
	if err != nil {
		return nil, err
	}
	signer, err := readSigner(path)
	if err != nil {
		return nil, err
	}
	if !pinned.Equal(signer.Public()) {
		return nil, fmt.Errorf("%s does not match release.PublicKey", path)
	}
	return signer, nil
}

func readSigner(path string) (ed25519.PrivateKey, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if info.Mode().Perm()&0o077 != 0 {
		return nil, fmt.Errorf("%s is readable by other users. Run chmod 600 on it", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil || block.Type != "PRIVATE KEY" {
		return nil, fmt.Errorf("%s is not a PEM private key", path)
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	signer, ok := key.(ed25519.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("%s is not an Ed25519 key", path)
	}
	return signer, nil
}

func printPublishSteps(out io.Writer, dir, version, codeHash, toolchain, commit string, dirty bool) {
	assets := []string{"install.sh", release.ManifestName, release.SignatureName}
	for _, arch := range release.Arches {
		assets = append(assets, release.ArchiveName(version, arch))
	}
	var paths []string
	for _, asset := range assets {
		paths = append(paths, fmt.Sprintf("%q", filepath.Join(dir, asset)))
	}
	fmt.Fprintf(out, "Built CloudGateway for Linux %s from %s with %s in %s\ncodeHash %s\n", version, commit, toolchain, dir, codeHash)
	if dirty {
		fmt.Fprintln(out, "The working tree had uncommitted changes, so this build pins its test key and published installers reject it. Don't publish it")
	}
	fmt.Fprintf(out, "\nNothing was uploaded. To publish, push %s, then run:\n", commit)
	fmt.Fprintf(out, "  gh release create linux-v%s --repo Albro3459/CloudGateway --target %s --title \"CloudGateway for Linux %s\" --notes \"CloudGateway %s for Linux amd64 and arm64. Source commit %s\" --latest=false \\\n    %s\n",
		version, commit, version, version, commit, strings.Join(paths, " "))
}
