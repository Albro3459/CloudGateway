package cli

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

const probeTimeout = 5 * time.Second

type probe struct {
	name        string
	requirement ipc.DoctorRequirement
	timeout     time.Duration
	run         func(ctx context.Context) doctorCheck
}

func (c *CLI) doctor(ctx context.Context, timeout time.Duration) (data, error) {
	probes := c.probes
	if probes == nil {
		probes = c.catalogProbes()
	}
	return runDoctor(ctx, c.clock, probes, timeout)
}

// runDoctor runs probes in order within the overall timeout. Only a failed required check fails
// doctor: cancellation or the deadline first, then the first setup failure, then any online failure
func runDoctor(ctx context.Context, clk clock, probes []probe, timeout time.Duration) (data, error) {
	deadline := clk.now().Add(timeout)
	var checks []doctorCheck
	var setupFailure *cliError
	onlineFailed, timedOut := false, false
	for _, p := range probes {
		remaining := deadline.Sub(clk.now())
		if remaining <= 0 {
			timedOut = true
			break
		}
		check := boundedProbe(ctx, p, min(p.timeout, remaining))
		checks = append(checks, check)
		if check.status == ipc.DoctorFail {
			if p.requirement == ipc.DoctorSetup && setupFailure == nil {
				// The evidence is the message even when empty. Only an absent suggestion takes the code's default
				setupFailure = errorCode(publicCode(check.failureCode, codeSetupRequired))
				setupFailure.message = check.evidence
				if check.suggestion != nil {
					setupFailure.suggestion = check.suggestion
				}
			}
			if p.requirement == ipc.DoctorOnline {
				onlineFailed = true
			}
		}
		if ctx.Err() != nil {
			break
		}
		if !clk.now().Before(deadline) {
			timedOut = true
			break
		}
	}
	report := doctorReport{checks: checks, timedOut: timedOut}
	switch {
	case ctx.Err() != nil:
		return nil, withData(codeInterrupted, report)
	case timedOut:
		return nil, withData(codeTimeout, report)
	case setupFailure != nil:
		setupFailure.data = report
		return nil, setupFailure
	case onlineFailed:
		return nil, withData(codeNetworkUnavailable, report)
	}
	return report, nil
}

// boundedProbe returns at the probe deadline even when the probe itself does not
func boundedProbe(ctx context.Context, p probe, timeout time.Duration) doctorCheck {
	probeCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	result := make(chan doctorCheck, 1)
	go func() { result <- p.run(probeCtx) }()
	select {
	case check := <-result:
		return check
	case <-probeCtx.Done():
	}
	if ctx.Err() != nil {
		return newCheck(p.name, ipc.DoctorUnknown, "The check was interrupted", nil, "")
	}
	status := ipc.DoctorFail
	if p.requirement == ipc.DoctorOptional {
		status = ipc.DoctorUnknown
	}
	return newCheck(p.name, status, "The check did not finish before its deadline",
		ptr("Run doctor again after checking this machine's setup and network"), "")
}

// catalogProbes runs the local checks here and asks the daemon for the rest by name
func (c *CLI) catalogProbes() []probe {
	daemon := &doctorDaemon{cli: c}
	probes := make([]probe, 0, len(ipc.DoctorProbes))
	for _, entry := range ipc.DoctorProbes {
		p := probe{name: entry.Name, requirement: entry.Requirement, timeout: probeTimeout}
		switch entry.Name {
		case "installation":
			p.run = c.installationCheck
		case "daemon":
			p.timeout, p.run = 6*time.Second, daemon.check
		default:
			name := entry.Name
			p.run = func(ctx context.Context) doctorCheck { return daemon.probe(ctx, name) }
		}
		probes = append(probes, p)
	}
	return probes
}

func (c *CLI) installationCheck(context.Context) doctorCheck {
	if entries, err := os.ReadDir(c.currentLink); err != nil || len(entries) == 0 {
		return newCheck("installation", ipc.DoctorFail, "No readable installed release at "+c.currentLink,
			ptr(codes[codeInstallationRequired].suggestion), string(codeInstallationRequired))
	}
	return newCheck("installation", ipc.DoctorPass, "The installed release at "+c.currentLink+" is present and readable", nil, "")
}

type doctorDaemon struct {
	cli   *CLI
	ready atomic.Bool
}

func (d *doctorDaemon) check(ctx context.Context) doctorCheck {
	fail := func(evidence string, c code) doctorCheck {
		return newCheck("daemon", ipc.DoctorFail, evidence, ptr(codes[c].suggestion), string(c))
	}
	conn, err := ipc.Dial(ctx, d.cli.socketPath)
	if errors.Is(err, fs.ErrPermission) {
		return fail("The daemon socket does not accept this user", codeControllerRejected)
	}
	if err != nil {
		return fail("The daemon socket is not reachable", codeControllerUnavailable)
	}
	defer conn.Close()
	reply, err := conn.Call(ctx, ipc.Request{ID: newUUID(), Action: ipc.ActionHandshake})
	switch {
	case err == nil && reply.Error == ipc.FailureRejected:
		return fail("The daemon rejected this user", codeControllerRejected)
	case err != nil || reply.Lifecycle == nil:
		return fail("The daemon handshake did not complete", codeControllerUnavailable)
	case reply.Version != ipc.Version:
		return fail("The daemon speaks IPC version "+strconv.Itoa(reply.Version)+", and this CLI speaks "+strconv.Itoa(ipc.Version),
			codeIncompatibleVersion)
	case reply.Lifecycle.State == ipc.LifecycleInvalidInstallation:
		return fail("The daemon found no readable installed release", codeInstallationRequired)
	case reply.Lifecycle.State != ipc.LifecycleCurrent:
		return fail("The daemon is restarting onto the installed release", codeIncompatibleVersion)
	}
	d.ready.Store(true)
	return newCheck("daemon", ipc.DoctorPass, "The daemon accepted this user and answered the handshake, running release "+
		reply.Release, nil, "")
}

func (d *doctorDaemon) probe(ctx context.Context, name string) doctorCheck {
	if !d.ready.Load() {
		return newCheck(name, ipc.DoctorUnknown, "Skipped because the daemon is unavailable", nil, "")
	}
	conn, err := ipc.Dial(ctx, d.cli.socketPath)
	if err != nil {
		return newCheck(name, ipc.DoctorUnknown, "The daemon did not answer this check", nil, "")
	}
	defer conn.Close()
	reply, err := conn.Call(ctx, ipc.Request{ID: newUUID(), Action: ipc.ActionDiagnostics, Probe: name})
	if err != nil || reply.Error != "" || reply.Check == nil {
		return newCheck(name, ipc.DoctorUnknown, "The daemon did not answer this check", nil, "")
	}
	check := reply.Check
	switch check.Status {
	case ipc.DoctorPass, ipc.DoctorWarning, ipc.DoctorFail, ipc.DoctorUnknown:
	default:
		return newCheck(name, ipc.DoctorUnknown, "The daemon returned an unrecognized check status", nil, "")
	}
	return newCheck(name, check.Status, check.Evidence, check.Suggestion, optionalRaw(check.FailureCode))
}
