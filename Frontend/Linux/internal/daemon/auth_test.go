package daemon

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/cloud"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network/networktest"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
)

func (h *harness) loginStatus(id string) *ipc.LoginStatus {
	return h.do(ipc.Request{Action: ipc.ActionLoginStatus, ContextID: id}).Login
}

// waitLogin polls until the attempt reaches phase or finishes
func (h *harness) waitLogin(id string, phase ipc.LoginPhase) *ipc.LoginStatus {
	h.t.Helper()
	var status *ipc.LoginStatus
	h.eventually("login phase "+string(phase), func() bool {
		status = h.loginStatus(id)
		return status.Phase == phase || status.Phase == ipc.LoginFinished
	})
	return status
}

func TestDeviceLoginCommitsCredentialsAndPublishesInventory(t *testing.T) {
	h := newHarness(t)
	h.open()
	id := newID()

	begun := h.do(ipc.Request{Action: ipc.ActionBeginLogin, ID: id}).Login
	expect(t, "first phase", begun.Phase, ipc.LoginRequestingCode)
	waiting := h.waitLogin(id, ipc.LoginWaitingForApproval)
	expect(t, "phase", waiting.Phase, ipc.LoginWaitingForApproval)
	expect(t, "code", waiting.Challenge.UserCode, "012345")
	expect(t, "remaining", waiting.Challenge.RemainingSeconds >= 295, true)
	expect(t, "pending state", h.snapshot().LoginPending, true)
	h.cloud.polls <- pollReply{poll: cloud.DevicePoll{Pending: true, Interval: 10 * time.Second}}
	h.cloud.polls <- pollReply{poll: cloud.DevicePoll{CustomToken: "custom-" + userA}}
	done := h.waitLogin(id, ipc.LoginFinished)

	expect(t, "result", done.Result, ipc.LoginAuthorized)
	// The second poll waited at least the server's longer interval
	expect(t, "elapsed", h.clock.Now().Sub(testStart), 15*time.Second)
	state := h.settled()
	expect(t, "account", deref(state.AccountID), any(userA))
	expect(t, "access", state.Access, ipc.AccessOnline)
	expect(t, "credentials", state.Credentials, "available")
	expect(t, "inventory", state.Inventory, ipc.InventoryCurrent)
	expect(t, "clients", len(state.Clients), 2)
	st := h.st()
	creds, err := st.LoadCredentials()
	if err != nil {
		t.Fatal(err)
	}
	expect(t, "saved", creds.AccountID+" "+creds.ProjectID+" "+string(creds.RefreshToken), userA+" "+testProject+" refresh-"+userA)
	session, _ := st.LoadSession()
	// Startup recovered an empty session record as generation 1, so login took the next one
	expect(t, "generation", session.Generation, uint64(2))
	expect(t, "credential generation", creds.Generation, uint64(2))
	expect(t, "repeat", h.do(ipc.Request{Action: ipc.ActionBeginLogin, ID: newID()}).Login.Result, ipc.LoginAuthorized)
	for _, reply := range h.replies {
		for _, secret := range []string{"refresh-" + userA, "id-" + userA, "custom-" + userA} {
			if strings.Contains(reply, secret) {
				t.Fatalf("reply leaked %q: %s", secret, reply)
			}
		}
	}
}

func TestDeviceLoginDenialExpiryAndOffline(t *testing.T) {
	tests := []struct {
		name   string
		setup  func(*harness)
		polls  []pollReply
		result ipc.LoginResult
		access ipc.AccessState
	}{
		{name: "access denied", setup: func(h *harness) { h.cloud.set(func(f *fakeCloud) { delete(f.roles, userA) }) },
			polls: []pollReply{{poll: cloud.DevicePoll{CustomToken: "custom-" + userA}}}, result: ipc.LoginDenied, access: ipc.AccessDenied},
		{name: "browser denial", polls: []pollReply{{err: cloudError(cloud.KindDeviceDenied, 403, false)}},
			result: ipc.LoginDenied, access: ipc.AccessUnverified},
		{name: "code expires", setup: func(h *harness) { h.cloud.set(func(f *fakeCloud) { f.code.ExpiresIn = 10 * time.Second }) },
			polls: []pollReply{{poll: cloud.DevicePoll{Pending: true, Interval: 5 * time.Second}}}, result: ipc.LoginExpired, access: ipc.AccessUnverified},
		{name: "server expired", polls: []pollReply{{err: cloudError(cloud.KindDeviceExpired, 410, false)}},
			result: ipc.LoginExpired, access: ipc.AccessUnverified},
		{name: "consumed", polls: []pollReply{{err: cloudError(cloud.KindDeviceConsumed, 409, false)}},
			result: ipc.LoginInvalidResponse, access: ipc.AccessUnverified},
		{name: "offline access check", setup: func(h *harness) {
			h.cloud.set(func(f *fakeCloud) { f.accessErr = cloudError(cloud.KindOffline, 0, false) })
		}, polls: []pollReply{{poll: cloud.DevicePoll{CustomToken: "custom-" + userA}}}, result: ipc.LoginOffline, access: ipc.AccessUnverified},
		{name: "account ID config identifiers cannot hold", setup: func(h *harness) {
			h.cloud.set(func(f *fakeCloud) { f.customTokens["custom-odd"] = "user:odd" })
		}, polls: []pollReply{{poll: cloud.DevicePoll{CustomToken: "custom-odd"}}}, result: ipc.LoginInvalidResponse, access: ipc.AccessUnverified},
		{name: "exchange fails", setup: func(h *harness) {
			h.cloud.set(func(f *fakeCloud) { f.signInErr = cloudError(cloud.KindSignInRequired, 400, false) })
		}, polls: []pollReply{{poll: cloud.DevicePoll{CustomToken: "custom-" + userA}}}, result: ipc.LoginUnavailable, access: ipc.AccessUnverified},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			h := newHarness(t)
			if test.setup != nil {
				test.setup(h)
			}
			h.open()
			id := newID()
			h.do(ipc.Request{Action: ipc.ActionBeginLogin, ID: id})
			for _, poll := range test.polls {
				h.cloud.polls <- poll
			}

			status := h.waitLogin(id, ipc.LoginFinished)

			expect(t, "result", status.Result, test.result)
			state := h.snapshot()
			expect(t, "account", deref(state.AccountID), nil)
			expect(t, "access", state.Access, test.access)
			expect(t, "retained", state.HasRetainedSession, false)
			st := h.st()
			if _, err := st.LoadCredentials(); err == nil {
				t.Fatal("credentials were saved")
			}
		})
	}
}

func TestLoginCancelTargetsOnlyItsAttemptAndAnotherIsBusy(t *testing.T) {
	h := newHarness(t)
	h.open()
	id := newID()
	h.do(ipc.Request{Action: ipc.ActionBeginLogin, ID: id})
	h.waitLogin(id, ipc.LoginWaitingForApproval)

	other := newID()
	expect(t, "second attempt", h.do(ipc.Request{Action: ipc.ActionBeginLogin, ID: other}).Login.Result, ipc.LoginBusy)
	stranger := h.do(ipc.Request{Action: ipc.ActionCancelLogin, ContextID: other}).Login
	expect(t, "stranger cancel", stranger.Result, ipc.LoginUnavailable)
	expect(t, "still waiting", h.loginStatus(id).Phase, ipc.LoginWaitingForApproval)
	cancelled := h.do(ipc.Request{Action: ipc.ActionCancelLogin, ContextID: id}).Login

	expect(t, "cancelled", cancelled.Result, ipc.LoginCancelled)
	expect(t, "pending", h.snapshot().LoginPending, false)
	// A frontend that disappeared without cancelling leaves the attempt running until expiry
	next := newID()
	expect(t, "new attempt", h.do(ipc.Request{Action: ipc.ActionBeginLogin, ID: next}).Login.Phase, ipc.LoginRequestingCode)
}

func TestLoginWithRetainedSessionRestoresInstead(t *testing.T) {
	h := newHarness(t)
	h.seedSession(userA, 1)
	h.cloud.set(func(f *fakeCloud) { f.accessErr = cloudError(cloud.KindOffline, 0, false) })
	h.open()
	h.settled()
	h.cloud.set(func(f *fakeCloud) { f.accessErr = nil })
	id := newID()

	begun := h.do(ipc.Request{Action: ipc.ActionBeginLogin, ID: id}).Login
	expect(t, "phase", begun.Phase, ipc.LoginRestoring)
	done := h.waitLogin(id, ipc.LoginFinished)

	expect(t, "result", done.Result, ipc.LoginAuthorized)
	expect(t, "account", deref(h.settled().AccountID), any(userA))
}

func TestRestoreRetainedSessionOnlineAndOffline(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	expect(t, "installed", h.up(configA).outcome.Kind, ipc.OutcomeStartRequested)
	h.close(h.c)

	h.cloud.set(func(f *fakeCloud) { f.accessErr = cloudError(cloud.KindOffline, 0, false) })
	h.open()
	state := h.settled()

	expect(t, "account", deref(state.AccountID), any(userA))
	expect(t, "access", state.Access, ipc.AccessOffline)
	expect(t, "inventory", state.Inventory, ipc.InventoryCached)
	expect(t, "clients", len(state.Clients), 1)
	row := state.Clients[0]
	expect(t, "row", row.Identifier+" "+row.Source+" "+row.Eligibility+" "+row.RegionName, configA+" cache eligible San Jose")
	expect(t, "owner", deref(row.OwnerLabel), nil)
	expect(t, "order", row.RegionOrder, 1000)
	expect(t, "status", row.Status, ipc.ClientTunnelConnected)
	expect(t, "selected", deref(state.SelectedIdentifier), any(configA))
	// Offline access still starts the retained, authorized config
	expect(t, "offline up", h.up("").outcome.Kind, ipc.OutcomeAlreadyActive)
}

func TestRestoreFailuresNeverGrantOfflineAccess(t *testing.T) {
	tests := []struct {
		name      string
		err       error
		access    ipc.AccessState
		retained  bool
		authorize bool
	}{
		{name: "denied", err: cloudError(cloud.KindAccessDenied, 403, false), access: ipc.AccessDenied},
		{name: "service failure", err: cloudError(cloud.KindUnavailable, 500, false), access: ipc.AccessUnreachable, retained: true, authorize: true},
		{name: "auth backend unavailable", err: &cloud.Error{Op: "test", Kind: cloud.KindUnavailable, Status: 503, Code: cloud.CodeAuthUnavailable},
			access: ipc.AccessUnreachable, retained: true, authorize: true},
		{name: "offline without prior authorization", err: cloudError(cloud.KindOffline, 0, false), access: ipc.AccessUnreachable, retained: true},
		{name: "rejected credentials", err: nil, access: ipc.AccessUnverified},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			h := newHarness(t)
			if test.authorize {
				h.signedIn(userA)
				h.close(h.c)
			} else {
				h.seedSession(userA, 1)
			}
			h.cloud.set(func(f *fakeCloud) {
				f.accessErr = test.err
				if test.err == nil {
					f.refreshErr = cloudError(cloud.KindSignInRequired, 400, false)
				}
			})
			h.open()
			state := h.settled()

			expect(t, "account", deref(state.AccountID), nil)
			expect(t, "access", state.Access, test.access)
			expect(t, "retained", state.HasRetainedSession, test.retained)
			expect(t, "clients", len(state.Clients), 0)
			reply := h.do(ipc.Request{Action: ipc.ActionAwaitRefresh})
			want := map[ipc.AccessState]ipc.RefreshResult{ipc.AccessDenied: ipc.RefreshSignInRequired,
				ipc.AccessUnreachable: ipc.RefreshUnavailable, ipc.AccessUnverified: ipc.RefreshSignInRequired}[test.access]
			expect(t, "refresh", reply.Refresh, want)
		})
	}
}

func TestInventoryRefreshFallsBackOnlyAfterTransportFailure(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)

	h.cloud.set(func(f *fakeCloud) { f.inventoryErr = cloudError(cloud.KindOffline, 0, false) })
	reply := h.do(ipc.Request{Action: ipc.ActionAwaitRefresh})
	expect(t, "offline refresh", reply.Refresh, ipc.RefreshUnavailable)
	expect(t, "offline access", reply.State.Access, ipc.AccessOffline)
	expect(t, "offline inventory", reply.State.Inventory, ipc.InventoryCached)
	expect(t, "offline rows", len(reply.State.Clients), 1)

	h.cloud.set(func(f *fakeCloud) { f.inventoryErr = &cloud.Error{Op: "test", Kind: cloud.KindInvalidResponse} })
	reply = h.do(ipc.Request{Action: ipc.ActionAwaitRefresh})
	expect(t, "malformed refresh", reply.Refresh, ipc.RefreshUnavailable)
	expect(t, "malformed inventory", reply.State.Inventory, ipc.InventoryUnavailable)
	expect(t, "malformed rows", len(reply.State.Clients), 0)

	h.cloud.set(func(f *fakeCloud) { f.inventoryErr = cloudError(cloud.KindAccessDenied, 403, false) })
	reply = h.do(ipc.Request{Action: ipc.ActionAwaitRefresh})
	expect(t, "denied refresh", reply.Refresh, ipc.RefreshDenied)
	expect(t, "denied access", reply.State.Access, ipc.AccessDenied)
	expect(t, "denied session", reply.State.HasRetainedSession, false)
	// Denial keeps the VPN running
	expect(t, "tunnel", reply.State.Tunnel.Phase, ipc.TunnelConnected)
	expect(t, "redacted", deref(reply.State.Tunnel.ConfigID), nil)
	st := h.st()
	saved, _ := st.Accounts().Load(userA)
	expect(t, "cache denied", saved.AccessAllowed, false)
}

func TestRoleDowngradeInvalidatesTheCache(t *testing.T) {
	h := newHarness(t)
	h.cloud.set(func(f *fakeCloud) {
		f.roles[userA] = cloud.RoleAdmin
		f.clients = append(f.clients, clientDoc(userB, "client-other", "Other", 4))
	})
	state := h.signedIn(userA)
	expect(t, "admin rows", len(state.Clients), 3)
	h.up(configA)

	h.cloud.set(func(f *fakeCloud) { f.roles[userA] = cloud.RoleUser })
	reply := h.do(ipc.Request{Action: ipc.ActionAwaitRefresh})

	expect(t, "refresh", reply.Refresh, ipc.RefreshRefreshed)
	expect(t, "user rows", len(reply.State.Clients), 2)
	// The downgrade wiped the retained installation, so it needs a fresh install
	for _, client := range reply.State.Clients {
		expect(t, "installed "+client.Identifier, client.Installed, false)
	}
}

func TestLogoutKeepsTunnelAndSuppressesBootResume(t *testing.T) {
	h := newHarness(t)
	h.signedIn(userA)
	h.up(configA)
	before := h.owned()

	out := h.run(ipc.Request{Action: ipc.ActionSignOut})

	expect(t, "logout", out.outcome.Kind, ipc.OutcomeCompleted)
	state := h.snapshot()
	expect(t, "account", deref(state.AccountID), nil)
	expect(t, "retained", state.HasRetainedSession, false)
	expect(t, "tunnel", state.Tunnel.Phase, ipc.TunnelConnected)
	expect(t, "redacted", deref(state.Tunnel.ConfigID), nil)
	expect(t, "owned", h.owned(), before)
	intent := h.intent()
	expect(t, "suppression", intent.Suppression, store.SuppressLogout)
	st := h.st()
	session, _ := st.LoadSession()
	expect(t, "session", session, store.Session{Generation: 2, RevokedThrough: 1})
	saved, _ := st.Accounts().Load(userA)
	expect(t, "cache kept", len(saved.Configs), 1)
	expect(t, "selection kept", saved.SelectedIdentifier, configA)

	// After a reboot the VPN stays off
	h.close(h.c)
	h.host = networktest.NewUbuntu()
	h.open()
	expect(t, "after reboot", h.snapshot().Tunnel.Phase, ipc.TunnelDisconnected)
	expect(t, "resume", !h.resuming(), true)
}

func TestInterruptedLogoutFinishesAtStartup(t *testing.T) {
	h := newHarness(t)
	h.seedSession(userA, 1)
	st := h.st()
	if err := st.SaveSession(store.Session{Generation: 2, RevokedThrough: 1, LogoutCleanup: true}); err != nil {
		t.Fatal(err)
	}

	h.open()

	state := h.snapshot()
	expect(t, "retained", state.HasRetainedSession, false)
	if _, err := st.LoadCredentials(); err == nil {
		t.Fatal("credentials survived logout")
	}
	session, _ := st.LoadSession()
	expect(t, "marker", session.LogoutCleanup, false)
}

func TestTokenRefreshIsCachedRotatedAndChecked(t *testing.T) {
	h := newHarness(t)
	h.cloud.set(func(f *fakeCloud) { f.rotate = true })
	h.signedIn(userA)
	h.cloud.mu.Lock()
	refreshes := h.cloud.refreshes
	h.cloud.mu.Unlock()
	// Restore and the first inventory refresh shared one cached ID token
	expect(t, "refreshes", refreshes, 1)
	creds, _ := h.st().LoadCredentials()
	expect(t, "rotated", string(creds.RefreshToken), "refresh-"+userA+"#1")

	h.clock.Advance(56 * time.Minute)
	h.cloud.set(func(f *fakeCloud) { f.project = "another-project" })
	reply := h.do(ipc.Request{Action: ipc.ActionAwaitRefresh})

	expect(t, "refresh", reply.Refresh, ipc.RefreshSignInRequired)
	expect(t, "retained", reply.State.HasRetainedSession, false)
	if _, err := h.st().LoadCredentials(); err == nil {
		t.Fatal("credentials survived a project change")
	}
}

func TestLoginFinishingDuringLogoutIsCancelled(t *testing.T) {
	h := newHarness(t)
	h.open()
	id := newID()
	h.do(ipc.Request{Action: ipc.ActionBeginLogin, ID: id})
	// Logout has saved its revocation marker and not yet cleared credentials
	h.c.mu.Lock()
	h.c.signingOut = true
	h.c.mu.Unlock()

	h.cloud.polls <- pollReply{poll: cloud.DevicePoll{CustomToken: "custom-" + userA}}
	status := h.waitLogin(id, ipc.LoginFinished)

	expect(t, "result", status.Result, ipc.LoginCancelled)
	if _, err := h.st().LoadCredentials(); err == nil {
		t.Fatal("credentials were saved")
	}
}

func TestNewLoginClearsEarlierDenial(t *testing.T) {
	h := newHarness(t)
	h.cloud.set(func(f *fakeCloud) { delete(f.roles, userA) })
	h.open()
	denied := newID()
	h.do(ipc.Request{Action: ipc.ActionBeginLogin, ID: denied})
	h.cloud.polls <- pollReply{poll: cloud.DevicePoll{CustomToken: "custom-" + userA}}
	expect(t, "first", h.waitLogin(denied, ipc.LoginFinished).Result, ipc.LoginDenied)
	expect(t, "access", h.snapshot().Access, ipc.AccessDenied)
	h.cloud.set(func(f *fakeCloud) { f.accessErr = cloudError(cloud.KindOffline, 0, false) })

	offline := newID()
	h.do(ipc.Request{Action: ipc.ActionBeginLogin, ID: offline})
	h.cloud.polls <- pollReply{poll: cloud.DevicePoll{CustomToken: "custom-" + userB}}

	expect(t, "second", h.waitLogin(offline, ipc.LoginFinished).Result, ipc.LoginOffline)
	expect(t, "access", h.snapshot().Access, ipc.AccessUnverified)
}

func TestCallersRejectedTogetherShareOneRefresh(t *testing.T) {
	h := newHarness(t)
	h.cloud.set(func(f *fakeCloud) { f.rotate = true })
	h.signedIn(userA)
	h.c.mu.Lock()
	tokens := h.c.tokenSource(h.c.creds.Generation)
	h.c.mu.Unlock()
	ctx := context.Background()
	rejected, err := tokens(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	h.cloud.mu.Lock()
	before := h.cloud.refreshes
	h.cloud.mu.Unlock()

	var wg sync.WaitGroup
	fresh := make([]cloud.Secret, 4)
	for i := range fresh {
		wg.Go(func() { fresh[i], _ = tokens(ctx, rejected) })
	}
	wg.Wait()

	h.cloud.mu.Lock()
	expect(t, "refreshes", h.cloud.refreshes-before, 1)
	h.cloud.mu.Unlock()
	for _, token := range fresh {
		if token == rejected || token != fresh[0] {
			t.Fatalf("tokens = %v, rejected %v", fresh, rejected)
		}
	}
}
