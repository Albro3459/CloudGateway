package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/buildinfo"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/cloud"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/daemon"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/release"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
)

const (
	// shutdownBound is how long SIGTERM or an update waits for in-flight
	// requests and running cloud work, well under the unit's TimeoutStopSec.
	// The tunnel is kernel state, so stopping never touches it
	shutdownBound = 5 * time.Second
	cleanupBound  = 60 * time.Second
)

func main() {
	// journald adds its own timestamps
	log.SetFlags(0)
	switch {
	case len(os.Args) == 1:
		os.Exit(run())
	case len(os.Args) == 2 && os.Args[1] == "cleanup":
		os.Exit(cleanup())
	}
	log.Print("usage: cloudgatewayd [cleanup]")
	os.Exit(2)
}

func run() int {
	// Handle SIGTERM from the start, so a stop during startup still exits cleanly
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	if err := daemon.Harden(); err != nil {
		log.Printf("harden process: %v", err)
		return 1
	}
	config, err := daemon.LoadConfig(buildinfo.DaemonConfig)
	if err != nil {
		log.Printf("load config: %v", err)
		return 1
	}
	st, err := store.Open(buildinfo.StateDir)
	if err != nil {
		log.Printf("open state: %v", err)
		return 1
	}
	client, err := cloud.New(cloud.DefaultConfig())
	if err != nil {
		log.Printf("cloud configuration: %v", err)
		return 1
	}
	controller, err := daemon.NewController(daemon.Options{Store: st, Cloud: client, Releases: newReleases()})
	if err != nil {
		log.Printf("start controller: %v", err)
		return 1
	}
	if ctx.Err() != nil {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownBound)
		defer cancel()
		controller.Close(shutdownCtx)
		return 0
	}
	server := daemon.NewServer(controller, config.OperatorUID)
	listener, err := daemon.Listen(buildinfo.SocketPath, config.OperatorUID)
	if err != nil {
		log.Printf("listen: %v", err)
		return 1
	}
	controller.Start()

	served := make(chan error, 1)
	go func() { served <- server.Serve(listener) }()
	code := 0
	select {
	case <-ctx.Done():
	case <-controller.Exit():
		// systemd restarts the daemon on the installed release
	case err := <-served:
		log.Printf("serve: %v", err)
		code = 1
	}
	// Refuse new work first, then let in-flight requests answer, then give
	// running cloud work whatever remains of the bound
	controller.Drain()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownBound)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
	controller.Close(shutdownCtx)
	return code
}

// cleanup removes owned networking for uninstall. The installer runs it as
// root after stopping the service, and it needs no socket or cloud access
func cleanup() int {
	if err := daemon.Harden(); err != nil {
		log.Printf("harden process: %v", err)
		return 1
	}
	// Uninstall must remove owned resources even when a newer release wrote the state
	st, err := store.OpenForCleanup(buildinfo.StateDir)
	if err != nil {
		log.Printf("open state: %v", err)
		return 1
	}
	if st.ReadOnly() {
		log.Print("state is not writable by this release. Removing owned resources without saving intent")
	}
	ctx, cancel := context.WithTimeout(context.Background(), cleanupBound)
	defer cancel()
	if err := daemon.Cleanup(ctx, st, network.Options{}); err != nil {
		log.Printf("cleanup: %v", err)
		return 1
	}
	return 0
}

// releases reads the running release once and the installed one on demand,
// since an update can switch the current link while the daemon runs
type releases struct {
	running   ipc.BuildIdentity
	installed *release.Installed
}

func newReleases() releases {
	running := ipc.BuildIdentity{Version: buildinfo.Version, Build: buildinfo.Build()}
	// /proc/self/exe opens the file this process started from, even after an update replaced it
	hash, err := release.Hash("/proc/self/exe")
	if err != nil {
		log.Printf("hash the running executable: %v", err)
	}
	running.CodeHash = hash
	return releases{running: running, installed: release.NewInstalled(buildinfo.CurrentLink)}
}

func (r releases) Running() ipc.BuildIdentity { return r.running }

func (r releases) Installed() (ipc.BuildIdentity, error) { return r.installed.Identity() }
