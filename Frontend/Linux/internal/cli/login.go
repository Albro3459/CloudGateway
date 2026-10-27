package cli

import (
	"context"
	"encoding/base64"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/jsonout"
)

// loginInput owns the terminal while login waits for approval
type loginInput interface {
	// start enables raw, non-blocking stdin when shortcuts are allowed and stdin is a foreground terminal
	start(shortcuts bool) bool
	readKeys() []byte
	width() int
	close()
}

type loginEffects struct {
	qrMatrix func(url string) ([][]bool, error)
	copy     func(url string) bool
	open     func(url string) bool
}

func systemEffects(c *CLI) loginEffects {
	return loginEffects{
		qrMatrix: encodeQR,
		// OSC 52 asks the terminal to set its clipboard, which also works over many SSH sessions
		copy: func(url string) bool {
			if !c.isOutputTerminal {
				return false
			}
			_, err := io.WriteString(c.stdout, "\x1b]52;c;"+base64.StdEncoding.EncodeToString([]byte(url))+"\x07")
			return err == nil
		},
		open: func(url string) bool {
			if !canOpenBrowser(os.Geteuid(), c.getenv, url) {
				return false
			}
			cmd := exec.Command("xdg-open", url)
			if cmd.Start() != nil {
				return false
			}
			go func() { _ = cmd.Wait() }()
			return true
		},
	}
}

// canOpenBrowser needs a graphical session and an ordinary user, so root never launches a browser
func canOpenBrowser(euid int, getenv func(string) string, url string) bool {
	return euid != 0 && (getenv("DISPLAY") != "" || getenv("WAYLAND_DISPLAY") != "") && strings.HasPrefix(url, "https://")
}

const loginStartupLimit = 30 * time.Second

// login prints the device approval challenge, then waits for the daemon's result. Explicit
// cancellation and the deadline cancel this attempt. A detached caller leaves it running until expiry
func (c *CLI) login(ctx context.Context, watch *signalWatch, inv invocation, showsQR bool) (data, error) {
	id := newUUID()
	startedAt := c.clock.now()
	var callerDeadline time.Time
	s := &session{cli: c, ctx: ctx, deadline: startedAt.Add(loginStartupLimit)}
	if inv.timeout > 0 {
		callerDeadline = startedAt.Add(inv.timeout)
		s.deadline = minTime(s.deadline, callerDeadline)
	}
	defer s.close()
	interactive := c.isOutputTerminal && !inv.isJSON && !inv.isNonInteractive && c.getenv("TERM") != "dumb"
	shortcuts := c.input.start(interactive)
	defer c.input.close()
	submitted, shouldCancel, fromResult := false, false, false
	result, err := func() (data, error) {
		if err := s.open(); err != nil {
			return nil, err
		}
		if err := s.handshake(); err != nil {
			return nil, err
		}
		if !s.current {
			return nil, s.versionError()
		}
		submitted = true
		reply, err := s.call(ipc.Request{Action: ipc.ActionBeginLogin, ID: id})
		if err != nil {
			return nil, err
		}
		printed := false
		var challengeDeadline time.Time
		for {
			if ctx.Err() != nil {
				return nil, errorCode(codeInterrupted)
			}
			status := reply.Login
			if status == nil || !sameID(status.AttemptID, id) {
				return nil, errorCode(codeInvalidResponse)
			}
			if challenge := status.Challenge; challenge != nil {
				expiresAt := c.clock.now().Add(time.Duration(challenge.RemainingSeconds) * time.Second)
				if challengeDeadline.IsZero() || expiresAt.Before(challengeDeadline) {
					challengeDeadline = expiresAt
				}
				// The challenge expiry replaces the startup limit. An explicit timeout can only shorten it
				s.deadline = challengeDeadline
				if !callerDeadline.IsZero() {
					s.deadline = minTime(callerDeadline, challengeDeadline)
				}
				if !printed {
					if err := c.printChallenge(*challenge, inv, showsQR && interactive && c.allowsStyle(inv), shortcuts); err != nil {
						shouldCancel = true
						return nil, err
					}
					printed = true
				}
			}
			if !c.clock.now().Before(s.deadline) {
				return nil, errorCode(codeTimeout)
			}
			if status.Result != "" {
				if status.Result != ipc.LoginAuthorized {
					fromResult = true
					return nil, loginFailure(status.Result)
				}
				snapshot, err := s.call(ipc.Request{Action: ipc.ActionSnapshot})
				if err != nil {
					return nil, err
				}
				if !c.clock.now().Before(s.deadline) {
					return nil, errorCode(codeTimeout)
				}
				if snapshot.State == nil || snapshot.State.AccountID == nil || !snapshot.State.AccessAuthorized {
					return nil, errorCode(codeInvalidResponse)
				}
				return newAuthStatus(*snapshot.State), nil
			}
			if shortcuts && status.Challenge != nil {
				for _, key := range c.input.readKeys() {
					switch key {
					case 3:
						shouldCancel = true
						return nil, errorCode(codeInterrupted)
					case 'c':
						if !c.effects.copy(status.Challenge.VerificationURL) {
							_, _ = io.WriteString(c.stderr, "Clipboard unavailable. Use the approval link above on another device\n")
						} else {
							// The terminal never confirms OSC 52, and some ignore it
							_, _ = io.WriteString(c.stderr, "Sent the link to the terminal clipboard. If nothing pastes, use the link above\n")
						}
					case 'o':
						if !c.effects.open(status.Challenge.VerificationURL) {
							_, _ = io.WriteString(c.stderr, "Browser unavailable. Use the approval link above on another device\n")
						}
					}
				}
			}
			if err := s.sleepFor(min(250*time.Millisecond, max(0, s.deadline.Sub(c.clock.now())))); err != nil {
				return nil, err
			}
			if reply, err = s.call(ipc.Request{Action: ipc.ActionLoginStatus, ContextID: id}); err != nil {
				return nil, err
			}
		}
	}()
	if err == nil {
		return result, nil
	}
	c.input.close()
	// Reaching the caller or challenge deadline cancels the attempt, unlike an expired result from the daemon
	var public *cliError
	if !fromResult && errors.As(err, &public) && public.code == codeTimeout {
		shouldCancel = true
	}
	if watch.interruption() == interruptCancelled {
		shouldCancel = true
	}
	if watch.interruption() == interruptDetached {
		shouldCancel = false
	}
	if submitted && shouldCancel {
		c.cancelLogin(id)
	}
	return nil, err
}

// cancelLogin uses its own short deadline and connection, since the caller's may already be gone
func (c *CLI) cancelLogin(id string) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	conn, err := ipc.Dial(ctx, c.socketPath)
	if err != nil {
		return
	}
	defer conn.Close()
	_, _ = conn.Call(ctx, ipc.Request{ID: newUUID(), Action: ipc.ActionCancelLogin, ContextID: id})
}

func (c *CLI) printChallenge(challenge ipc.LoginChallenge, inv invocation, showsQR, shortcuts bool) error {
	if inv.isJSON {
		line, err := jsonout.Marshal(jsonout.Object{"schemaVersion": 1, "type": "login_required", "command": "auth login",
			"operationId": nil, "error": nil, "data": jsonout.Object{"verificationURL": challenge.VerificationURL,
				"userCode": challenge.UserCode, "expiresIn": challenge.RemainingSeconds}})
		if err == nil {
			_, err = c.stdout.Write(append(line, '\n'))
		}
		return err
	}
	text := "Approve sign-in: " + sanitize(challenge.VerificationURL) + "\nCode: " + sanitize(challenge.UserCode) + "\n"
	if _, err := io.WriteString(c.stdout, text); err != nil {
		return err
	}
	if showsQR {
		rendered := ""
		if matrix, err := c.effects.qrMatrix(challenge.VerificationURL); err == nil {
			rendered = renderQR(matrix, c.input.width())
		}
		if rendered == "" {
			_, _ = io.WriteString(c.stderr, "QR unavailable or terminal too narrow. Use the approval link and code above\n")
		} else if _, err := io.WriteString(c.stdout, rendered); err != nil {
			return err
		}
	}
	if shortcuts {
		if _, err := io.WriteString(c.stdout, "Press c to copy the link, o to open it, or Ctrl-C to cancel\n"); err != nil {
			return err
		}
		_, ssh := c.lookupEnv("SSH_CONNECTION")
		_, tty := c.lookupEnv("SSH_TTY")
		if ssh || tty {
			if _, err := io.WriteString(c.stdout, "Clipboard and browser shortcuts act on this remote machine. You can approve on another device\n"); err != nil {
				return err
			}
		}
	}
	return nil
}

func loginFailure(result ipc.LoginResult) *cliError {
	switch result {
	case ipc.LoginBusy:
		return errorCode(codeBusy)
	case ipc.LoginCancelled:
		return errorCode(codeInterrupted)
	case ipc.LoginExpired:
		return newError(codeTimeout, "The sign-in code or acquisition deadline expired", "Run: cloudgateway auth login")
	case ipc.LoginDenied:
		return errorCode(codeAccessDenied)
	case ipc.LoginOffline:
		return errorCode(codeNetworkUnavailable)
	case ipc.LoginSignInRequired:
		return errorCode(codeSignInRequired)
	case ipc.LoginUnavailable:
		return newError(codeCredentialsUnavailable, "Sign-in could not finish. Try again", "")
	}
	return errorCode(codeInvalidResponse)
}
