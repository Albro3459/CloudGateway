// Command cloudgateway-release builds Linux release assets. It is a developer
// tool and is never shipped
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/release"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
)

const usage = `Usage:
  go run ./cmd/cloudgateway-release build -version <x.y.z> -out <dir> [-env <file>] [-allow-dirty]

build cross-compiles linux/amd64 and linux/arm64 from this module at HEAD with
the go.mod toolchain, then writes both archives and an install.sh stamped with
the release version, storage version, and each archive's size and SHA-256 to
<dir>/linux-v<x.y.z>. It refuses uncommitted changes unless -allow-dirty is
set. It reads the Firebase web config from CLOUDGATEWAY_FIREBASE_API_KEY,
CLOUDGATEWAY_FIREBASE_PROJECT_ID, and CLOUDGATEWAY_FIREBASE_DATABASE_ID, or
from Secrets/release.env. It never uploads anything
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

type buildOptions struct {
	version    string
	outDir     string
	envPath    string
	allowDirty bool
}

func parseBuildArgs(args []string, stderr io.Writer) (buildOptions, error) {
	var options buildOptions
	set := flag.NewFlagSet("build", flag.ContinueOnError)
	set.StringVar(&options.version, "version", "", "release version")
	set.StringVar(&options.outDir, "out", "", "output directory")
	set.StringVar(&options.envPath, "env", "", "Firebase config file")
	set.BoolVar(&options.allowDirty, "allow-dirty", false, "build with uncommitted changes")
	if err := parseFlags(set, args, stderr); err != nil {
		return options, err
	}
	switch {
	case !release.ValidVersion(options.version):
		return options, fmt.Errorf("%w: build needs -version in x.y.z form", errUsage)
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
	toolchain, err := moduleToolchain(module)
	if err != nil {
		return err
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
		if binaries[arch], err = compile(module, toolchain, arch, options.version, firebase); err != nil {
			return err
		}
	}
	err = packageRelease(packageParams{
		outDir: options.outDir, version: options.version, storageVersion: store.StorageVersion, binaries: binaries,
	})
	if err != nil {
		return err
	}
	printPublishSteps(stdout, finalDir, options.version, toolchain, commit, dirty)
	return nil
}

func printPublishSteps(out io.Writer, dir, version, toolchain, commit string, dirty bool) {
	assets := []string{"install.sh"}
	for _, arch := range release.Arches {
		assets = append(assets, release.ArchiveName(version, arch))
	}
	var paths []string
	for _, asset := range assets {
		paths = append(paths, fmt.Sprintf("%q", filepath.Join(dir, asset)))
	}
	fmt.Fprintf(out, "Built CloudGateway for Linux %s from %s with %s in %s\n", version, commit, toolchain, dir)
	if dirty {
		fmt.Fprintln(out, "The working tree had uncommitted changes, so this build doesn't match the commit. Don't publish it")
		return
	}
	fmt.Fprintf(out, "\nNothing was uploaded. To publish, push %s, then run:\n", commit)
	fmt.Fprintf(out, "  gh release create linux-v%s --repo Albro3459/CloudGateway --target %s --title \"CloudGateway for Linux %s\" --notes \"CloudGateway %s for Linux amd64 and arm64. Source commit %s\" --latest=false \\\n    %s\n",
		version, commit, version, version, commit, strings.Join(paths, " "))
}
