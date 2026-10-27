package cli

import (
	"context"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

func TestJSONGoldenLinesAreCompleteAndVersioned(t *testing.T) {
	h := newHarness(t, testState())
	expectExit(t, h.run("--version", "--json"), 0)
	expectExit(t, h.run("list", "--bogus", "--json"), 2)
	expectExit(t, h.run("auth", "status", "--json"), 0)
	expectEqual(t, "output", h.out.String(),
		`{"command":"version","data":{"build":"7","version":"1.2.0"},"error":null,"operationId":null,"schemaVersion":1,"type":"result"}`+"\n"+
			`{"command":"list","data":null,"error":{"code":"usage","message":"Unknown option '--bogus'","suggestion":"Run: cloudgateway help"},"operationId":null,"schemaVersion":1,"type":"error"}`+"\n"+
			`{"command":"auth status","data":{"access":"online","accountId":"uid1","credentials":"available","loginPending":false,"retainedSession":true,"state":"online"},"error":null,"operationId":null,"schemaVersion":1,"type":"result"}`+"\n")
	expectEqual(t, "diagnostics", h.diag.String(), "")
}

func TestUsageErrorsKeepJSONAndTheirCommand(t *testing.T) {
	h := newHarness(t)
	expectExit(t, h.run("--bogus", "list", "--json"), 2)
	expectExit(t, h.run("--json=yes", "status"), 2)
	expectEqual(t, "output", h.out.String(),
		`{"command":"list","data":null,"error":{"code":"usage","message":"Unknown option '--bogus'","suggestion":"Run: cloudgateway help"},"operationId":null,"schemaVersion":1,"type":"error"}`+"\n"+
			`{"command":"status","data":null,"error":{"code":"usage","message":"--json does not take a value","suggestion":"Run: cloudgateway help"},"operationId":null,"schemaVersion":1,"type":"error"}`+"\n")
	expectEqual(t, "diagnostics", h.diag.String(), "")
	expectEqual(t, "dials", h.daemon.acceptCount(), 0)
}

func TestVersionStringsAreSanitizedAndLocal(t *testing.T) {
	h := newHarness(t)
	h.version = [2]string{"1.2\x1b[31m", "7‮"}
	expectExit(t, h.run("--version"), 0)
	expectEqual(t, "output", h.out.String(), "CloudGateway 1.2 [31m (7 )\n")
	for _, isJSON := range []bool{false, true} {
		var outputs []string
		for _, alias := range []string{"version", "--version", "-v"} {
			h := newHarness(t)
			arguments := []string{alias}
			if isJSON {
				arguments = append(arguments, "--json")
			}
			expectExit(t, h.run(arguments...), 0)
			outputs = append(outputs, h.out.String())
			expectEqual(t, "dials", h.daemon.acceptCount(), 0)
		}
		if outputs[0] != outputs[1] || outputs[1] != outputs[2] {
			t.Fatalf("version aliases differ: %q", outputs)
		}
	}
}

func TestHelpJSONUsesTheSharedDefinitions(t *testing.T) {
	h := newHarness(t)
	expectExit(t, h.run("help", "list", "--json"), 0)
	record := h.last()
	expectEqual(t, "command", field(record, "command"), any("help"))
	expectEqual(t, "topic", field(record, "data", "topic"), any("list"))
	expectEqual(t, "usage", field(record, "data", "usage"), any("cloudgateway list [--region <region>] [--refresh] [--long] [options]"))
	options := field(record, "data", "options").([]any)
	expectEqual(t, "options", len(options), 3)
	expectEqual(t, "region value", field(options[0], "value"), any("region"))
	expectEqual(t, "refresh value", field(options[1], "value"), nil)
	expectEqual(t, "long flags", strings.Join(toStrings(field(options[2], "flags")), ","), "-l,--long")
	var common []string
	for _, o := range field(record, "data", "commonOptions").([]any) {
		flags := toStrings(field(o, "flags"))
		common = append(common, flags[len(flags)-1])
	}
	expectEqual(t, "common", strings.Join(common, ","), "--help,--json,--non-interactive,--timeout")

	h.reset()
	expectExit(t, h.run("--json"), 0)
	root := h.last()
	expectEqual(t, "root topic", field(root, "data", "topic"), nil)
	expectContains(t, strings.Join(toStrings(field(root, "data", "notes")), "\n"),
		"Request acceptance reserves work. `up` succeeds after start submission or if already active. "+
			"`down` succeeds only after a confirmed stop. Check `status` for the observed tunnel state")
	expectEqual(t, "dials", h.daemon.acceptCount(), 0)
}

func toStrings(value any) []string {
	var result []string
	for _, item := range value.([]any) {
		result = append(result, item.(string))
	}
	return result
}

func TestHelpAndVersionNeverReachTheDaemon(t *testing.T) {
	h := newHarness(t)
	expectExit(t, h.run(), 0)
	if !strings.HasPrefix(h.out.String(), "Control the CloudGateway VPN on this machine\n\nUsage: cloudgateway <command> [options]\n") {
		t.Fatalf("root help:\n%s", h.out.String())
	}
	expectContains(t, h.out.String(), "  up [<client-uuid> | <region> <index>]")
	expectContains(t, h.out.String(), "\nCommon options:\n  -h, --help           Show help for the current command\n")
	expectMissing(t, h.out.String(), "--controller")
	expectExit(t, h.run("auth", "login", "--help"), 0)
	expectExit(t, h.run("--version"), 0)
	if !strings.HasSuffix(h.out.String(), "CloudGateway 1.2.0 (7)\n") {
		t.Fatalf("version:\n%s", h.out.String())
	}
	expectExit(t, h.run("bogus"), 2)
	expectEqual(t, "diagnostics", h.diag.String(), "Error: Unknown command 'bogus'\nRun: cloudgateway help\n")
	for _, arguments := range [][]string{{"update", "--help"}, {"help", "update"}, {"--json", "update", "--help"}} {
		h := newHarness(t)
		expectExit(t, h.run(arguments...), 0)
		expectContains(t, h.out.String(), "--allow-disconnect")
		expectContains(t, h.out.String(), "SSH")
		expectContains(t, h.out.String(), "Activate the CloudGateway release installed on this machine")
	}
	for _, arguments := range [][]string{{"remove", "--help"}, {"help", "remove"}, {"remove", "78ab8633-ae25-4287-885f-57bbbf6e7f63", "--help"}} {
		h := newHarness(t)
		expectExit(t, h.run(arguments...), 0)
		expectContains(t, h.out.String(), "--yes")
		expectContains(t, h.out.String(), "permanent")
	}
	expectEqual(t, "dials", h.daemon.acceptCount(), 0)
}

func TestHelpHumanLayout(t *testing.T) {
	h := newHarness(t)
	expectExit(t, h.run("help", "update"), 0)
	expectEqual(t, "update help", h.out.String(), `Activate the CloudGateway release installed on this machine

Usage: cloudgateway update [--allow-disconnect] [options]

Options:
  --allow-disconnect  Accepted for compatibility. Linux updates keep the VPN connected

Common options:
  -h, --help           Show help for the current command
  --json               Print versioned JSON records, one per line, without decoration or shortcuts
  --non-interactive    Disable keyboard shortcuts and prompts, even in a terminal
  --timeout <seconds>  Stop waiting after this many seconds (default 30). Confirmed VPN work keeps running

Notes:
  Restarts the daemon onto the installed release. Does not download or install a release
  A matching release succeeds without a restart. The VPN stays connected while the daemon restarts
  --allow-disconnect is accepted for compatibility and has no effect
  The accepted ID prints before execution is confirmed. Output failure before confirmation leaves work unconfirmed
  Waits up to 300 seconds by default. After confirmation, timeout, Ctrl-C, or SSH loss detaches observation. The daemon keeps running the update
  Use status --operation to follow an accepted update, including across the daemon restart

Examples:
  cloudgateway update
  cloudgateway update --json
  ssh my-server cloudgateway update
  cloudgateway status --operation <operation-id>
`)
}

func TestExitCodesCoverEveryTypedFailure(t *testing.T) {
	commandFailures := map[ipc.CommandFailure]int{
		ipc.CommandSignInRequired: 3, ipc.CommandAccessDenied: 3, ipc.CommandSetupRequired: 4, ipc.CommandCredentialsUnavailable: 4,
		ipc.CommandIncompatibleVersion: 4, ipc.CommandConfigUnavailable: 5, ipc.CommandSelectionUnavailable: 5,
		ipc.CommandNetworkUnavailable: 6, ipc.CommandClientActive: 4, ipc.CommandBusy: 7, ipc.CommandStopTimedOut: 8,
		ipc.CommandVPNFailed: 9, ipc.CommandInternalError: 1,
	}
	for failure, exit := range commandFailures {
		op := newOperation(ipc.Operation{ID: "a", State: ipc.OperationFailed}, &ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: failure})
		expectEqual(t, string(failure), op.failure.code, code(failure))
		expectEqual(t, string(failure)+" exit", op.failure.code.exitCode(), exit)
	}
	controller := []struct {
		failure ipc.ControllerFailure
		code    code
		exit    int
	}{
		{ipc.FailureInvalidRequest, codeInvalidResponse, 1}, {ipc.FailureIncompatibleVersion, codeIncompatibleVersion, 4},
		{ipc.FailureUnavailable, codeControllerUnavailable, 4}, {ipc.FailureTimeout, codeTimeout, 8}, {ipc.FailureBusy, codeBusy, 7},
		{ipc.FailureRejected, codeControllerRejected, 4}, {ipc.FailureOutcomeUnknown, codeOperationUnknown, 10},
		{ipc.FailurePreparationExpired, codeOperationExpired, 10}, {ipc.FailureCommandFailed, codeCommandFailed, 9},
		{ipc.FailureAuthCleanupFailed, codeCredentialsUnavailable, 4},
	}
	for _, tc := range controller {
		e := asError(controllerFailure(tc.failure))
		if e.code != tc.code || e.code.exitCode() != tc.exit {
			t.Errorf("%s: %s %d", tc.failure, e.code, e.code.exitCode())
		}
	}
	outcomes := []struct {
		outcome *ipc.Outcome
		state   ipc.OperationState
		code    code
	}{
		{&ipc.Outcome{Kind: ipc.OutcomeStartRequested, Identifier: "uid1/r/c"}, ipc.OperationCompleted, ""},
		{&ipc.Outcome{Kind: ipc.OutcomeAlreadyActive, Identifier: "uid1/r/c", Warning: ipc.WarningInventoryNotRefreshed}, ipc.OperationCompleted, ""},
		{&ipc.Outcome{Kind: ipc.OutcomeCompleted}, ipc.OperationCompleted, ""},
		{&ipc.Outcome{Kind: ipc.OutcomeUnknown}, ipc.OperationUnknown, codeOperationUnknown},
		{&ipc.Outcome{Kind: ipc.OutcomeExpired}, ipc.OperationUnknown, codeOperationExpired},
		{&ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandStopTimedOut}, ipc.OperationUnknown, codeStopTimedOut},
		{nil, ipc.OperationRunning, ""}, {nil, ipc.OperationFailed, codeCommandFailed}, {nil, ipc.OperationUnknown, codeOperationUnknown},
	}
	for _, tc := range outcomes {
		op := newOperation(ipc.Operation{ID: "a", State: tc.state}, tc.outcome)
		got := code("")
		if op.failure != nil {
			got = op.failure.code
		}
		expectEqual(t, "outcome", got, tc.code)
	}
	for c, exit := range map[code]int{codeUsage: 2, codeNotImplemented: 1, codeUntrustedBuild: 4, codeInterrupted: 130,
		codeExtensionMismatch: 4, codeDisconnectRequired: 4, codeActivationFailed: 9, codeReadinessFailed: 9,
		codeStorageUnavailable: 6, codeObservationUnavailable: 6, codeRefreshSkipped: 6, codeRefreshSuperseded: 7,
		codeUpdateSuperseded: 10, codeReconnectSuppressed: 10, codeInstallationRequired: 4} {
		expectEqual(t, string(c), c.exitCode(), exit)
	}
}

func TestSanitizeReplacesControlAndFormatCharacters(t *testing.T) {
	expectEqual(t, "sanitize", sanitize("a\x1b[31mb\u009bc‮d​e\nf"), "a [31mb c d e f")
	h := newHarness(t, testState(withClients(testClient("uid1/r1/c1", "Region\x1b]0;title\x07", 0, "Mac\x1b[2J‮",
		func(c *ipc.Client) { c.OwnerLabel = ptr("Ann\r\n") }))))
	expectExit(t, h.run("list"), 0)
	expectExit(t, h.run("list", "--json"), 0)
	expectExit(t, h.run("--\x1b[31m"), 2)
	for _, text := range []string{h.out.String(), h.diag.String()} {
		for _, bad := range []string{"\x1b", "‮", "\x07", "\r"} {
			expectMissing(t, text, bad)
		}
	}
	expectContains(t, h.out.String(), "uid1/r1/c1")
	expectContains(t, h.out.String(), "Region ]0;title  (r1)")
}

func TestStylesOnlyInteractiveTerminalsWithoutNoColor(t *testing.T) {
	cases := []struct {
		terminal bool
		env      map[string]string
		args     []string
		styled   bool
	}{
		{true, map[string]string{"TERM": "xterm-256color"}, nil, true},
		{true, map[string]string{"NO_COLOR": ""}, nil, true},
		{true, map[string]string{"NO_COLOR": "1"}, nil, false},
		{true, map[string]string{"TERM": "dumb"}, nil, false},
		{false, map[string]string{}, nil, false},
		{true, map[string]string{}, []string{"--non-interactive"}, false},
		{true, map[string]string{}, []string{"--json"}, false},
	}
	for _, tc := range cases {
		h := newHarness(t)
		h.terminal, h.env = tc.terminal, tc.env
		h.run(tc.args...)
		expectEqual(t, "styled", strings.Contains(h.out.String(), "\x1b["), tc.styled)
	}
}

func TestOutputFailureExitsAsInternal(t *testing.T) {
	h := newHarness(t)
	h.failsOutput = true
	expectExit(t, h.run("--version"), 1)
}

// Swift sorts keys with a case-insensitive numeric comparison. Byte order matches it for every schema key
func TestSchemaKeysSortTheSameByteWiseAndCaseInsensitively(t *testing.T) {
	keys := []string{"schemaVersion", "type", "command", "operationId", "data", "error", "code", "message", "suggestion",
		"version", "build", "state", "accountId", "retainedSession", "access", "credentials", "loginPending", "selectedMode",
		"activeMode", "tunnelState", "observation", "observedAt", "configId", "id", "result", "warning", "tunnel", "operation",
		"mode", "auth", "update", "scope", "freshness", "profileObservation", "profilesObservedAt", "regionId", "regions", "name",
		"configs", "clientId", "index", "connectionUrl", "owner", "internalIp", "cloudState", "eligibility", "installed", "source",
		"selected", "readAt", "updatedAt", "choices", "creation", "requestedMode", "inventory", "phase", "target", "codeHash",
		"reconnect", "checks", "status", "evidence", "failureCode", "timedOut", "topic", "usage", "summary", "commands", "options",
		"commonOptions", "notes", "examples", "arguments", "flags", "value", "verificationURL", "userCode", "expiresIn"}
	byteOrder := slices.Clone(keys)
	slices.Sort(byteOrder)
	folded := slices.Clone(keys)
	slices.SortFunc(folded, func(a, b string) int { return strings.Compare(strings.ToLower(a), strings.ToLower(b)) })
	if !slices.Equal(byteOrder, folded) {
		t.Fatalf("orders differ:\n%v\n%v", byteOrder, folded)
	}
}

// Swift encodes a present empty string as "". Only absent values become null
func TestPresentEmptyStringsStayEmpty(t *testing.T) {
	h := newHarness(t, testState(func(s *ipc.State) {
		s.AccountID, s.Tunnel.Phase, s.Tunnel.ConfigID = ptr(""), ipc.TunnelConnected, ptr("")
	}, withClients(testClient("/us-east-1/c1", "East", 0, "Mac", func(c *ipc.Client) {
		c.OwnerLabel, c.ConnectionURL, c.InternalIP = ptr(""), ptr(""), ptr("")
	}))))
	h.daemon.operation = &ipc.Operation{ID: "6f9619ff-8b86-d011-b42d-00c04fc964ff", State: ipc.OperationCompleted}
	h.daemon.outcome = &ipc.Outcome{Kind: ipc.OutcomeStartRequested}
	expectExit(t, h.run("list", "--json"), 0)
	config := field(field(h.last(), "data", "regions").([]any)[0], "configs").([]any)[0]
	for _, key := range []string{"owner", "connectionUrl", "internalIp"} {
		expectEqual(t, key, field(config, key), any(""))
	}
	expectEqual(t, "inventory account", field(h.last(), "data", "accountId"), any(""))
	h.reset()
	expectExit(t, h.run("list"), 0)
	expectContains(t, h.out.String(), "  1  Mac ()  c1\n")
	h.reset()
	expectExit(t, h.run("ls", "--long"), 0)
	expectContains(t, h.out.String(), "Tunnel IP:       Unavailable\n     Connection URL:  \n     Owner email:     \n")
	h.reset()
	expectExit(t, h.run("status", "--json"), 0)
	expectEqual(t, "account", field(h.last(), "data", "auth", "accountId"), any(""))
	expectEqual(t, "tunnel config", field(h.last(), "data", "tunnel", "configId"), any(""))
	expectEqual(t, "operation config", field(h.last(), "data", "operation", "configId"), any(""))
	h.reset()
	expectExit(t, h.run("status"), 0)
	expectContains(t, h.out.String(), "Config:       \n")
	expectContains(t, h.out.String(), "Account:      \n")

	doctor := newHarness(t)
	doctor.probes = []probe{{name: "resolver", requirement: ipc.DoctorSetup, timeout: probeTimeout, run: func(context.Context) doctorCheck {
		return newCheck("resolver", ipc.DoctorFail, "", ptr(""), "")
	}}}
	expectExit(t, doctor.run("doctor", "--json"), 4)
	expectEqual(t, "output", doctor.out.String(), `{"command":"doctor","data":{"checks":[{"evidence":"","name":"resolver","status":"fail","suggestion":""}],"timedOut":false},"error":{"code":"setup_required","message":"","suggestion":""},"operationId":null,"schemaVersion":1,"type":"error"}`+"\n")
	doctor.reset()
	expectExit(t, doctor.run("doctor"), 4)
	expectEqual(t, "human", doctor.out.String(), "[fail] resolver: \n  \n")
	expectEqual(t, "diagnostics", doctor.diag.String(), "Error: \n\n")
}

func TestLastSignalDecidesTheInterruption(t *testing.T) {
	h := newHarness(t)
	ctx, watch, stop := h.cli().watchSignals()
	defer stop()
	h.signal(syscall.SIGINT)
	h.signal(syscall.SIGHUP)
	<-ctx.Done()
	deadline := time.Now().Add(time.Second)
	for watch.interruption() != interruptDetached && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	expectEqual(t, "interruption", watch.interruption(), interruptDetached)
	h.signal(syscall.SIGTERM)
	for watch.interruption() != interruptCancelled && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	expectEqual(t, "interruption", watch.interruption(), interruptCancelled)
}
