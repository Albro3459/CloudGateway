package cli

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

func check(name string, status ipc.DoctorStatus, evidence string) func(context.Context) doctorCheck {
	return func(context.Context) doctorCheck { return newCheck(name, status, evidence, nil, "") }
}

func TestDoctorSetupFailurePrecedesRequiredOnlineFailure(t *testing.T) {
	h := newHarness(t)
	h.probes = []probe{
		{name: "https", requirement: ipc.DoctorOnline, timeout: probeTimeout, run: check("https", ipc.DoctorFail, "HTTP 503")},
		{name: "installation", requirement: ipc.DoctorSetup, timeout: probeTimeout, run: check("installation", ipc.DoctorFail, "Release missing")},
		{name: "optional", requirement: ipc.DoctorOptional, timeout: probeTimeout, run: check("optional", ipc.DoctorUnknown, "Unsupported")},
	}
	expectExit(t, h.run("doctor", "--json"), 4)
	expectEqual(t, "output", h.out.String(), `{"command":"doctor","data":{"checks":[{"evidence":"HTTP 503","name":"https","status":"fail","suggestion":null},{"evidence":"Release missing","name":"installation","status":"fail","suggestion":null},{"evidence":"Unsupported","name":"optional","status":"unknown","suggestion":null}],"timedOut":false},"error":{"code":"setup_required","message":"Release missing","suggestion":"Run: cloudgateway doctor"},"operationId":null,"schemaVersion":1,"type":"error"}`+"\n")
}

func TestDoctorOptionalWarningsAndUnknownsSucceed(t *testing.T) {
	h := newHarness(t)
	h.probes = []probe{
		{name: "credentials", requirement: ipc.DoctorOptional, timeout: probeTimeout, run: check("credentials", ipc.DoctorUnknown, "Uninitialized")},
		{name: "server", requirement: ipc.DoctorOptional, timeout: probeTimeout, run: func(context.Context) doctorCheck {
			return newCheck("server", ipc.DoctorWarning, "The connected server is not responding", ptr("Run: cloudgateway refresh"), "")
		}},
		{name: "resolver", requirement: ipc.DoctorOptional, timeout: probeTimeout, run: check("resolver", ipc.DoctorFail, "systemd-resolved is inactive")},
	}
	expectExit(t, h.run("doctor"), 0)
	expectEqual(t, "human", h.out.String(), "[unknown] credentials: Uninitialized\n"+
		"[warning] server: The connected server is not responding\n  Run: cloudgateway refresh\n"+
		"[fail] resolver: systemd-resolved is inactive\n")
	h.reset()
	expectExit(t, h.run("doctor", "--json"), 0)
	expectEqual(t, "suggestion", field(field(h.last(), "data", "checks").([]any)[0], "suggestion"), nil)
	expectEqual(t, "timed out", field(h.last(), "data", "timedOut"), any(false))
}

func TestDoctorOverallDeadlinePreservesCompletedChecks(t *testing.T) {
	h := newHarness(t)
	ranLater := false
	h.probes = []probe{
		{name: "local", requirement: ipc.DoctorSetup, timeout: probeTimeout, run: func(ctx context.Context) doctorCheck {
			_ = h.clock.clock().sleep(ctx, 2*time.Second)
			return newCheck("local", ipc.DoctorPass, "Present", nil, "")
		}},
		{name: "network", requirement: ipc.DoctorOnline, timeout: probeTimeout, run: func(context.Context) doctorCheck {
			ranLater = true
			return newCheck("network", ipc.DoctorPass, "Reachable", nil, "")
		}},
	}
	expectExit(t, h.run("doctor", "--timeout", "1", "--json"), 8)
	expectEqual(t, "timed out", field(h.last(), "data", "timedOut"), any(true))
	expectEqual(t, "checks", len(field(h.last(), "data", "checks").([]any)), 1)
	expectEqual(t, "later probe", ranLater, false)
}

func TestDoctorHungProbeFailsRequiredAndUnknownsOptional(t *testing.T) {
	cancelled := make(chan struct{})
	hang := func(ctx context.Context) doctorCheck {
		<-ctx.Done()
		close(cancelled)
		return doctorCheck{}
	}
	h := newHarness(t)
	h.probes = []probe{
		{name: "local", requirement: ipc.DoctorSetup, timeout: probeTimeout, run: check("local", ipc.DoctorPass, "Present")},
		{name: "daemon", requirement: ipc.DoctorSetup, timeout: 50 * time.Millisecond, run: hang},
	}
	expectExit(t, h.run("doctor"), 4)
	expectEqual(t, "human", h.out.String(), "[pass] local: Present\n[fail] daemon: The check did not finish before its deadline\n"+
		"  Run doctor again after checking this machine's setup and network\n")
	expectEqual(t, "diagnostics", h.diag.String(), "Error: The check did not finish before its deadline\n"+
		"Run doctor again after checking this machine's setup and network\n")
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("hung probe was not cancelled")
	}
	optional := newHarness(t)
	optional.probes = []probe{{name: "service", requirement: ipc.DoctorOptional, timeout: 50 * time.Millisecond,
		run: func(ctx context.Context) doctorCheck { <-ctx.Done(); return doctorCheck{} }}}
	expectExit(t, optional.run("doctor"), 0)
	expectEqual(t, "human", optional.out.String(), "[unknown] service: The check did not finish before its deadline\n"+
		"  Run doctor again after checking this machine's setup and network\n")
}

func TestDoctorRequiredOnlineFailureKeepsReportAndReturnsSix(t *testing.T) {
	h := newHarness(t)
	h.probes = []probe{{name: "https", requirement: ipc.DoctorOnline, timeout: probeTimeout, run: check("https", ipc.DoctorFail, "HTTP 500")}}
	expectExit(t, h.run("doctor"), 6)
	expectEqual(t, "output", h.out.String(), "[fail] https: HTTP 500\n")
	expectEqual(t, "diagnostics", h.diag.String(), "Waiting for network… Try again soon.\n")
}

func TestDoctorKeepsPreciseSetupFailureCodes(t *testing.T) {
	for failureCode, exit := range map[string]int{"installation_required": 4, "controller_unavailable": 4, "controller_rejected": 4,
		"incompatible_version": 4, "vpn_failed": 9, "setup_required": 4, "bogus": 4} {
		h := newHarness(t)
		h.probes = []probe{{name: "dns_policy", requirement: ipc.DoctorSetup, timeout: probeTimeout, run: func(context.Context) doctorCheck {
			return newCheck("dns_policy", ipc.DoctorFail, "Specific \x1b state", ptr("Run: cloudgateway mode mesh"), failureCode)
		}}}
		expectExit(t, h.run("doctor", "--json"), exit)
		want := failureCode
		if failureCode == "bogus" {
			want = "setup_required"
			if _, ok := field(field(h.last(), "data", "checks").([]any)[0], "failureCode").(error); !ok {
				t.Fatal("unknown failure code serialized")
			}
		}
		expectEqual(t, "code", field(h.last(), "error", "code"), any(want))
		expectEqual(t, "message", field(h.last(), "error", "message"), any("Specific   state"))
		expectEqual(t, "suggestion", field(h.last(), "error", "suggestion"), any("Run: cloudgateway mode mesh"))
	}
}

func TestDoctorInterruptStopsAfterTheCurrentProbe(t *testing.T) {
	h := newHarness(t)
	ranLater := false
	h.probes = []probe{
		{name: "daemon", requirement: ipc.DoctorSetup, timeout: probeTimeout, run: func(ctx context.Context) doctorCheck {
			h.signal(os.Interrupt)
			<-ctx.Done()
			return doctorCheck{}
		}},
		{name: "dns", requirement: ipc.DoctorOnline, timeout: probeTimeout, run: func(context.Context) doctorCheck {
			ranLater = true
			return doctorCheck{}
		}},
	}
	expectExit(t, h.run("doctor", "--json"), 130)
	expectEqual(t, "status", field(field(h.last(), "data", "checks").([]any)[0], "status"), any("unknown"))
	expectEqual(t, "evidence", field(field(h.last(), "data", "checks").([]any)[0], "evidence"), any("The check was interrupted"))
	expectEqual(t, "later probe", ranLater, false)
}

func TestDoctorCatalogRunsLocalChecksAndAsksTheDaemonByName(t *testing.T) {
	h := newHarness(t)
	if err := os.WriteFile(filepath.Join(h.currentLink, "cloudgateway"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	h.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action != ipc.ActionDiagnostics {
			return nil
		}
		switch request.Probe {
		case "server":
			return &ipc.Reply{Check: &ipc.DoctorCheck{Name: "server", Status: ipc.DoctorWarning,
				Evidence: "The connected server is not responding", Suggestion: ptr("Run: cloudgateway refresh")}}
		case "service":
			return &ipc.Reply{Error: ipc.FailureInvalidRequest}
		case "access":
			return &ipc.Reply{Check: &ipc.DoctorCheck{Name: "access", Status: "maybe", Evidence: "?"}}
		}
		return &ipc.Reply{Check: &ipc.DoctorCheck{Name: request.Probe, Status: ipc.DoctorPass, Evidence: request.Probe + " ok"}}
	}
	expectExit(t, h.run("doctor"), 0)
	expectEqual(t, "human", h.out.String(), "[pass] installation: The installed release at "+h.currentLink+" is present and readable\n"+
		"[pass] daemon: The daemon accepted this user and answered the handshake, running release 1.2.0\n"+
		"[pass] network_tools: network_tools ok\n[pass] dns_policy: dns_policy ok\n[pass] resolver: resolver ok\n"+
		"[pass] credentials: credentials ok\n[unknown] access: The daemon returned an unrecognized check status\n"+
		"[pass] inventory: inventory ok\n[pass] network_path: network_path ok\n[pass] dns: dns ok\n[pass] https: https ok\n"+
		"[warning] server: The connected server is not responding\n  Run: cloudgateway refresh\n"+
		"[unknown] service: The daemon did not answer this check\n")
	for _, action := range h.daemon.actions() {
		if action != ipc.ActionHandshake && action != ipc.ActionDiagnostics {
			t.Fatalf("doctor sent %s", action)
		}
	}
	expectEqual(t, "probes", len(h.daemon.requestsFor(ipc.ActionDiagnostics)), len(ipc.DoctorProbes)-2)
}

func TestDoctorCatalogReportsAMissingDaemonAndSkipsItsChecks(t *testing.T) {
	h := newHarness(t)
	h.daemon.stop()
	expectExit(t, h.run("doctor", "--json"), 4)
	checks := field(h.last(), "data", "checks").([]any)
	expectEqual(t, "installation", field(checks[0], "status"), any("fail"))
	expectEqual(t, "installation code", field(checks[0], "failureCode"), any("installation_required"))
	expectEqual(t, "daemon", field(checks[1], "status"), any("fail"))
	expectEqual(t, "daemon code", field(checks[1], "failureCode"), any("controller_unavailable"))
	for _, c := range checks[2:] {
		expectEqual(t, "skipped", field(c, "evidence"), any("Skipped because the daemon is unavailable"))
	}
	expectEqual(t, "first setup failure", field(h.last(), "error", "code"), any("installation_required"))

	mismatch := newHarness(t)
	mismatch.daemon.version = ipc.Version + 1
	_ = os.WriteFile(filepath.Join(mismatch.currentLink, "cloudgateway"), nil, 0o644)
	expectExit(t, mismatch.run("doctor", "--json"), 4)
	expectEqual(t, "code", field(mismatch.last(), "error", "code"), any("incompatible_version"))
	expectEqual(t, "diagnostics", len(mismatch.daemon.requestsFor(ipc.ActionDiagnostics)), 0)
}
