package cli

import (
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

const loginURL = "https://dashboard.example.com/#/auth/code?deviceRequestId=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&userCode=000012"

type loginFixture struct {
	*harness
	result    ipc.LoginResult
	finishAt  int
	remaining int
	polls     int
	onPoll    func() *ipc.Reply
	copied    int
	opened    int
	encoded   int
}

func newLoginFixture(t *testing.T) *loginFixture {
	f := &loginFixture{harness: newHarness(t, testState()), result: ipc.LoginAuthorized, finishAt: 2, remaining: 100}
	f.env = map[string]string{"TERM": "xterm", "SSH_CONNECTION": "fixture"}
	f.effects = loginEffects{
		qrMatrix: func(url string) ([][]bool, error) { f.encoded++; return encodeQR(url) },
		copy:     func(string) bool { f.copied++; return false },
		open:     func(string) bool { f.opened++; return false },
	}
	f.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		status := func(id string, finished bool) *ipc.Reply {
			if finished {
				return &ipc.Reply{Login: &ipc.LoginStatus{AttemptID: id, Phase: ipc.LoginFinished, Result: f.result}}
			}
			return &ipc.Reply{Login: &ipc.LoginStatus{AttemptID: id, Phase: ipc.LoginWaitingForApproval,
				Challenge: &ipc.LoginChallenge{VerificationURL: loginURL, UserCode: "000012", RemainingSeconds: f.remaining}}}
		}
		switch request.Action {
		case ipc.ActionBeginLogin:
			return status(request.ID, false)
		case ipc.ActionLoginStatus:
			f.polls++
			if f.onPoll != nil {
				if reply := f.onPoll(); reply != nil {
					return reply
				}
			}
			return status(request.ContextID, f.finishAt > 0 && f.polls >= f.finishAt)
		case ipc.ActionCancelLogin:
			return &ipc.Reply{Login: &ipc.LoginStatus{AttemptID: request.ContextID, Phase: ipc.LoginFinished, Result: ipc.LoginCancelled}}
		}
		return nil
	}
	return f
}

func (f *loginFixture) attemptID() string { return f.daemon.requestsFor(ipc.ActionBeginLogin)[0].ID }

func (f *loginFixture) cancellations() []string {
	var ids []string
	for _, request := range f.daemon.requestsFor(ipc.ActionCancelLogin) {
		ids = append(ids, request.ContextID)
	}
	return ids
}

func (f *loginFixture) expectCancelled(t *testing.T, cancelled bool) {
	t.Helper()
	want := []string(nil)
	if cancelled {
		want = []string{f.attemptID()}
	}
	if got := f.cancellations(); !slices.Equal(got, want) {
		t.Fatalf("cancellations %v, want %v", got, want)
	}
}

func TestLoginWithoutInteractiveStdinStillPollsToAuthorization(t *testing.T) {
	for _, flags := range [][]string{{"--json"}, {"--non-interactive"}, {}} {
		f := newLoginFixture(t)
		f.terminal = slices.Contains(flags, "--non-interactive")
		expectExit(t, f.run(append([]string{"auth", "login"}, flags...)...), 0)
		expectEqual(t, "polls", f.polls, 2)
		expectEqual(t, "starts", len(f.input.starts) == 1 && !f.input.starts[0], true)
		expectEqual(t, "reads", f.input.reads, 0)
		expectEqual(t, "closed", f.input.closes >= 1, true)
		expectEqual(t, "effects", f.opened+f.copied+f.encoded, 0)
		f.expectCancelled(t, false)
		if slices.Contains(flags, "--json") {
			expectEqual(t, "records", f.out.String(), `{"command":"auth login","data":{"expiresIn":100,"userCode":"000012","verificationURL":"`+loginURL+`"},"error":null,"operationId":null,"schemaVersion":1,"type":"login_required"}`+"\n"+
				`{"command":"auth login","data":{"access":"online","accountId":"uid1","credentials":"available","loginPending":false,"retainedSession":true,"state":"online"},"error":null,"operationId":null,"schemaVersion":1,"type":"result"}`+"\n")
		} else {
			expectEqual(t, "human", f.out.String(), "Approve sign-in: "+loginURL+"\nCode: 000012\n"+
				"Auth:         Signed in (online)\nAccount:      uid1\nAccess:       online\nCredentials:  available\n")
		}
		expectEqual(t, "begin requests", len(f.daemon.requestsFor(ipc.ActionBeginLogin)), 1)
		expectEqual(t, "attempt", f.daemon.requestsFor(ipc.ActionLoginStatus)[0].ContextID, f.attemptID())
	}
}

func TestLoginFailedShortcutsLeaveReadableChallengeAndPolling(t *testing.T) {
	f := newLoginFixture(t)
	f.terminal, f.input.shortcuts, f.input.keys, f.input.columns = true, true, []byte("co"), 1
	expectExit(t, f.run("auth", "login"), 0)
	expectEqual(t, "copied", f.copied, 1)
	expectEqual(t, "opened", f.opened, 1)
	expectEqual(t, "reads", f.input.reads >= 2, true)
	expectEqual(t, "polls", f.polls, 2)
	expectContains(t, f.out.String(), loginURL)
	expectContains(t, f.out.String(), "Press c to copy the link, o to open it, or Ctrl-C to cancel\n")
	expectContains(t, f.out.String(), "Clipboard and browser shortcuts act on this remote machine. You can approve on another device\n")
	expectEqual(t, "diagnostics", f.diag.String(), "QR unavailable or terminal too narrow. Use the approval link and code above\n"+
		"Clipboard unavailable. Use the approval link above on another device\n"+
		"Browser unavailable. Use the approval link above on another device\n")
}

func TestLoginShowsQRInAWideStyledTerminal(t *testing.T) {
	f := newLoginFixture(t)
	f.terminal, f.input.shortcuts = true, true
	delete(f.env, "SSH_CONNECTION")
	expectExit(t, f.run("auth", "login"), 0)
	expectEqual(t, "encoded", f.encoded, 1)
	expectContains(t, f.out.String(), "Code: 000012\n\x1b[30;47m")
	expectMissing(t, f.out.String(), "remote machine")
	expectEqual(t, "diagnostics", f.diag.String(), "")
}

func TestLoginNoQRKeepsShortcutsAndNeverOpensAutomatically(t *testing.T) {
	f := newLoginFixture(t)
	f.terminal, f.input.shortcuts = true, true
	expectExit(t, f.run("auth", "login", "--no-qr"), 0)
	expectEqual(t, "encoded", f.encoded, 0)
	expectEqual(t, "opened", f.opened, 0)
	expectContains(t, f.out.String(), "Press c")
}

func TestLoginNoColorSuppressesQRAndKeepsShortcuts(t *testing.T) {
	f := newLoginFixture(t)
	f.terminal, f.input.shortcuts = true, true
	f.env["NO_COLOR"] = "1"
	expectExit(t, f.run("auth", "login"), 0)
	expectEqual(t, "encoded", f.encoded, 0)
	expectMissing(t, f.out.String(), "\x1b")
	expectContains(t, f.out.String(), "Code: 000012")
	expectContains(t, f.out.String(), "Press c")
	expectEqual(t, "shortcuts requested", f.input.starts[0], true)

	dumb := newLoginFixture(t)
	dumb.terminal, dumb.input.shortcuts = true, true
	dumb.env["TERM"] = "dumb"
	expectExit(t, dumb.run("auth", "login"), 0)
	expectEqual(t, "shortcuts requested", dumb.input.starts[0], false)
	expectMissing(t, dumb.out.String(), "Press c")
}

func TestLoginOutputFailureCancelsOnlySubmittedAttempt(t *testing.T) {
	f := newLoginFixture(t)
	f.failsOutput = true
	expectExit(t, f.run("auth", "login"), 1)
	expectEqual(t, "closed", f.input.closes >= 1, true)
	f.expectCancelled(t, true)
	expectEqual(t, "polls", f.polls, 0)
}

func TestLoginTerminalResultsMapExitCodes(t *testing.T) {
	for result, exit := range map[ipc.LoginResult]int{ipc.LoginDenied: 3, ipc.LoginExpired: 8, ipc.LoginBusy: 7,
		ipc.LoginCancelled: 130, ipc.LoginOffline: 6, ipc.LoginUnavailable: 4, ipc.LoginInvalidResponse: 1} {
		f := newLoginFixture(t)
		f.result = result
		expectExit(t, f.run("auth", "login", "--json"), exit)
		expectEqual(t, "closed", f.input.closes >= 1, true)
		f.expectCancelled(t, false)
		if result == ipc.LoginExpired {
			expectEqual(t, "message", field(f.last(), "error", "message"), any("The sign-in code or acquisition deadline expired"))
		}
	}
}

func TestLoginSignalsCancelOrDetachTheAttempt(t *testing.T) {
	for _, tc := range []struct {
		signal    syscall.Signal
		cancelled bool
	}{{syscall.SIGINT, true}, {syscall.SIGTERM, true}, {syscall.SIGQUIT, true}, {syscall.SIGHUP, false}} {
		f := newLoginFixture(t)
		f.onPoll = func() *ipc.Reply {
			f.signal(tc.signal)
			return hangReply
		}
		expectExit(t, f.run("auth", "login", "--json"), 130)
		expectEqual(t, "code", field(f.last(), "error", "code"), any("interrupted"))
		f.expectCancelled(t, tc.cancelled)
		expectEqual(t, "closed", f.input.closes >= 1, true)
	}
	key := newLoginFixture(t)
	key.terminal, key.input.shortcuts, key.input.keys = true, true, []byte{3}
	expectExit(t, key.run("auth", "login", "--no-qr"), 130)
	key.expectCancelled(t, true)
}

func TestLoginTransportFailureDoesNotCancelTheAttempt(t *testing.T) {
	f := newLoginFixture(t)
	f.onPoll = func() *ipc.Reply { return dropReply }
	expectExit(t, f.run("auth", "login", "--json"), 4)
	expectEqual(t, "code", field(f.last(), "error", "code"), any("controller_unavailable"))
	f.expectCancelled(t, false)
}

func TestLoginChallengeExpiryBoundsWaitingAndExplicitTimeoutOnlyShortens(t *testing.T) {
	for _, tc := range []struct {
		flags    []string
		deadline time.Duration
	}{{nil, 2 * time.Second}, {[]string{"--timeout", "100"}, 2 * time.Second}, {[]string{"--timeout", "1"}, time.Second}} {
		f := newLoginFixture(t)
		f.remaining, f.finishAt = 2, 0
		expectExit(t, f.run(append([]string{"auth", "login", "--json"}, tc.flags...)...), 8)
		expectEqual(t, "elapsed", f.clock.elapsed(), tc.deadline)
		f.expectCancelled(t, true)
	}
}

func TestLoginRequiresTheMatchingDaemon(t *testing.T) {
	f := newLoginFixture(t)
	f.daemon.version = ipc.Version + 1
	expectExit(t, f.run("auth", "login", "--json"), 4)
	expectEqual(t, "code", field(f.last(), "error", "code"), any("incompatible_version"))
	expectEqual(t, "begin", len(f.daemon.requestsFor(ipc.ActionBeginLogin)), 0)
	f.expectCancelled(t, false)
}

func TestTerminalQRHasQuietZoneAndKeepsModuleOrientation(t *testing.T) {
	matrix := make([][]bool, 21)
	for i := range matrix {
		matrix[i] = make([]bool, 21)
	}
	matrix[0][0], matrix[1][1], matrix[2][2], matrix[3][2] = true, true, true, true
	expectEqual(t, "narrow", renderQR(matrix, 28), "")
	rendered := renderQR(matrix, 29)
	if !strings.HasPrefix(rendered, "\x1b[30;47m") || !strings.HasSuffix(rendered, "\x1b[0m\n") {
		t.Fatalf("styling: %q", rendered)
	}
	lines := strings.Split(strings.TrimSuffix(strings.TrimPrefix(rendered, "\x1b[30;47m"), "\x1b[0m\n"), "\n")
	expectEqual(t, "lines", len(lines), 15)
	expectEqual(t, "quiet 0", lines[0], strings.Repeat(" ", 29))
	expectEqual(t, "quiet 1", lines[1], strings.Repeat(" ", 29))
	expectEqual(t, "row 0", strings.HasPrefix(lines[2], "    ▀▄"), true)
	expectEqual(t, "row 2", strings.HasPrefix(lines[3], "      █"), true)
	expectEqual(t, "width", len([]rune(lines[2])), 29)
	expectEqual(t, "ragged", renderQR(append(matrix[:20:20], make([]bool, 20)), 100), "")
	expectEqual(t, "small", renderQR(matrix[:20], 100), "")
}

func TestLoginSanitizesTheHumanChallenge(t *testing.T) {
	for _, isJSON := range []bool{false, true} {
		f := newLoginFixture(t)
		answer := f.daemon.onRequest
		f.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
			reply := answer(request)
			if reply != nil && reply.Login != nil && reply.Login.Challenge != nil {
				reply.Login.Challenge.VerificationURL = "https://example.com/\x1b]0;x\x07?a=1"
				reply.Login.Challenge.UserCode = "0‮12"
			}
			return reply
		}
		if isJSON {
			expectExit(t, f.run("auth", "login", "--json"), 0)
			expectContains(t, f.out.String(), `"userCode":"0`+"‮"+`12","verificationURL":"https://example.com/\u001b]0;x\u0007?a=1"`)
		} else {
			expectExit(t, f.run("auth", "login"), 0)
			expectContains(t, f.out.String(), "Approve sign-in: https://example.com/ ]0;x ?a=1\nCode: 0 12\n")
		}
	}
}

func TestLoginRechecksTheDeadlineAfterTheAuthorizedSnapshot(t *testing.T) {
	f := newLoginFixture(t)
	answer := f.daemon.onRequest
	f.daemon.onRequest = func(request ipc.Request) *ipc.Reply {
		if request.Action == ipc.ActionSnapshot {
			f.clock.mu.Lock()
			f.clock.now = f.clock.now.Add(time.Hour)
			f.clock.mu.Unlock()
		}
		return answer(request)
	}
	expectExit(t, f.run("auth", "login", "--json"), 8)
	expectEqual(t, "code", field(f.last(), "error", "code"), any("timeout"))
	f.expectCancelled(t, true)
}

func TestBrowserOpensOnlyForAGraphicalOrdinaryUser(t *testing.T) {
	env := func(values map[string]string) func(string) string {
		return func(name string) string { return values[name] }
	}
	cases := []struct {
		euid int
		env  map[string]string
		url  string
		want bool
	}{
		{1000, map[string]string{"DISPLAY": ":0"}, loginURL, true},
		{1000, map[string]string{"WAYLAND_DISPLAY": "wayland-0"}, loginURL, true},
		{0, map[string]string{"DISPLAY": ":0"}, loginURL, false},
		{1000, map[string]string{}, loginURL, false},
		{1000, map[string]string{"DISPLAY": ":0"}, "http://example.com", false},
		{1000, map[string]string{"DISPLAY": ":0"}, "-https://example.com", false},
	}
	for _, tc := range cases {
		expectEqual(t, tc.url, canOpenBrowser(tc.euid, env(tc.env), tc.url), tc.want)
	}
}
