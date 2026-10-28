// Package cli implements the cloudgateway command line front end. It parses
// arguments, talks to cloudgatewayd over the local socket, and renders human
// output or schema 1 NDJSON compatible with the macOS CLI
package cli

import (
	"cmp"
	"context"
	"io"
	"os"
	"os/signal"
	"slices"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/buildinfo"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

// CLI runs one cloudgateway invocation
type CLI struct {
	stdout           io.Writer
	stderr           io.Writer
	isOutputTerminal bool
	lookupEnv        func(string) (string, bool)
	socketPath       string
	currentLink      string
	version          string
	build            string
	clock            clock
	notify           func(chan<- os.Signal, ...os.Signal) func()
	input            loginInput
	effects          loginEffects
	// probes overrides the doctor catalog
	probes []probe
}

// New wires the CLI to the process's stdio, terminal, environment, and daemon socket
func New() *CLI {
	c := &CLI{stdout: os.Stdout, stderr: os.Stderr, isOutputTerminal: isTerminal(1), lookupEnv: os.LookupEnv,
		socketPath: buildinfo.SocketPath, currentLink: buildinfo.CurrentLink, version: buildinfo.Version,
		build: buildinfo.Build(), clock: realClock, notify: notifySignals, input: &terminalInput{}}
	c.effects = systemEffects(c)
	return c
}

func notifySignals(ch chan<- os.Signal, signals ...os.Signal) func() {
	signal.Notify(ch, signals...)
	return func() { signal.Stop(ch) }
}

func (c *CLI) getenv(name string) string {
	value, _ := c.lookupEnv(name)
	return value
}

func (c *CLI) allowsStyle(inv invocation) bool {
	return c.isOutputTerminal && !inv.isJSON && !inv.isNonInteractive && c.getenv("NO_COLOR") == "" && c.getenv("TERM") != "dumb"
}

// Run executes arguments and returns the process exit code
func (c *CLI) Run(arguments []string) int {
	// Handling SIGPIPE makes a closed stdout fail the write with EPIPE instead of killing the process
	defer c.notify(make(chan os.Signal, 1), syscall.SIGPIPE)()
	inv, usage := parse(arguments)
	if usage != nil {
		isJSON := slices.ContainsFunc(arguments, func(a string) bool { return a == "--json" || strings.HasPrefix(a, "--json=") })
		return c.emit(usage.command, "", nil, newError(codeUsage, usage.message, ""), isJSON, false)
	}
	styled := c.allowsStyle(inv)
	switch inv.action {
	case actionHelp:
		return c.emit("help", "", newHelp(inv.topic), nil, inv.isJSON, styled)
	case actionVersion:
		return c.emit("version", "", versionData{sanitize(c.version), sanitize(c.build)}, nil, inv.isJSON, styled)
	}
	ctx, watch, stop := c.watchSignals()
	defer stop()
	cmd := inv.command
	var result data
	var err error
	switch cmd.kind {
	case cmdDoctor:
		result, err = c.doctor(ctx, cmp.Or(inv.timeout, 30*time.Second))
	case cmdAuthLogin:
		result, err = c.login(ctx, watch, inv, cmd.showsQR)
	default:
		result, err = c.execute(ctx, inv)
	}
	return c.emit(cmd.name(), cmd.operationID, result, err, inv.isJSON, styled)
}

type interruption int32

const (
	notInterrupted interruption = iota
	interruptCancelled
	interruptDetached
)

type signalWatch struct{ kind atomic.Int32 }

func (w *signalWatch) interruption() interruption { return interruption(w.kind.Load()) }

// watchSignals turns termination signals into cancellation. Confirmed work only detaches, since
// nothing is ever resent. The last signal decides the kind, and SIGHUP marks a detach so login
// leaves its attempt running
func (c *CLI) watchSignals() (context.Context, *signalWatch, func()) {
	ctx, cancel := context.WithCancel(context.Background())
	signals := make(chan os.Signal, 4)
	stopNotify := c.notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGQUIT, syscall.SIGHUP)
	watch := &signalWatch{}
	done := make(chan struct{})
	go func() {
		for {
			select {
			case sig := <-signals:
				kind := interruptCancelled
				if sig == syscall.SIGHUP {
					kind = interruptDetached
				}
				watch.kind.Store(int32(kind))
				cancel()
			case <-done:
				return
			}
		}
	}()
	return ctx, watch, func() {
		stopNotify()
		close(done)
		cancel()
	}
}

func (c *CLI) execute(ctx context.Context, inv invocation) (data, error) {
	cmd := inv.command
	timeout := inv.timeout
	if timeout == 0 {
		timeout = 30 * time.Second
		// The daemon restart and its readiness check outlast the usual wait
		if cmd.kind == cmdUpdate {
			timeout = 300 * time.Second
		}
	}
	s := &session{cli: c, ctx: ctx, deadline: c.clock.now().Add(timeout)}
	defer s.close()
	if cmd.kind == cmdStatus && cmd.operationID != "" {
		return s.operation(cmd.operationID)
	}
	if err := s.open(); err != nil {
		return nil, err
	}
	accepted := func(id string) error {
		if inv.isJSON {
			line, err := record{kind: "accepted", command: cmd.name(), operationID: id}.line()
			if err == nil {
				_, err = c.stdout.Write(line)
			}
			return err
		}
		if cmd.kind == cmdSetMode && cmd.mode == ipc.ModeFull {
			_, _ = io.WriteString(c.stderr, "Note: "+fullModeNotice+"\n")
		}
		_, err := io.WriteString(c.stdout, "Accepted operation "+id+"\n")
		return err
	}
	switch cmd.kind {
	case cmdAuthStatus:
		return s.authStatus()
	case cmdModeStatus:
		return s.modeStatus()
	case cmdSetMode:
		return s.mutate(ipc.ActionSetMode, nil, cmd.mode, accepted)
	case cmdAdd:
		return s.add(cmd.addRegion, cmd.addName, accepted)
	case cmdUp:
		return s.mutate(ipc.ActionConnect, cmd.selector, "", accepted)
	case cmdDownTarget:
		return s.mutate(ipc.ActionDisconnectClient, cmd.selector, "", accepted)
	case cmdRemove:
		return s.mutate(ipc.ActionRemoveClient, cmd.selector, "", accepted)
	case cmdUpdate:
		return s.update(cmd.allowDisconnect, accepted)
	case cmdDown:
		return s.mutate(ipc.ActionTurnOff, nil, "", accepted)
	case cmdAuthLogout:
		return s.mutate(ipc.ActionSignOut, nil, "", accepted)
	case cmdRefresh:
		return s.refresh("", false, false)
	case cmdList:
		if cmd.refresh {
			return s.refresh(cmd.regionID, true, cmd.long)
		}
		return s.inventory(cmd.regionID, cmd.long)
	}
	return s.status(!inv.isJSON)
}

func (c *CLI) emit(command, operationID string, d data, err error, isJSON, isStyled bool) int {
	r := renderer{isStyled: isStyled}
	rec := record{kind: "result", command: command, operationID: operationID}
	var stdout, stderr string
	exit := 0
	if err == nil {
		if m, ok := d.(mutation); ok {
			rec.operationID = m.operation.id
		}
		rec.data = d
		stdout = r.render(d)
	} else {
		failure := asError(err)
		exit = failure.code.exitCode()
		rec = record{kind: "error", command: command, operationID: cmp.Or(failure.operationID, operationID),
			data: failure.data, err: failure}
		// Human network failures on ordinary mutations show only the waiting message
		m, isMutation := failure.data.(mutation)
		if failure.data != nil && !(isMutation && failure.code == codeNetworkUnavailable && m.update == nil) {
			stdout = r.render(failure.data)
		}
		stderr = r.renderError(failure)
	}
	if isJSON {
		line, err := rec.line()
		if err != nil {
			_, _ = io.WriteString(c.stderr, "Error: CloudGateway could not encode its output\n")
			return 1
		}
		stdout, stderr = string(line), ""
	}
	if stdout != "" {
		if _, err := io.WriteString(c.stdout, stdout); err != nil {
			return 1
		}
	}
	if stderr != "" {
		_, _ = io.WriteString(c.stderr, stderr)
	}
	return exit
}
