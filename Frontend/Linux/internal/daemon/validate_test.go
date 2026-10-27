package daemon

import (
	"strings"
	"testing"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

func TestValidate(t *testing.T) {
	const id = "6f9619ff-8b86-d011-b42d-00cf4fc964ff"
	const context = "0f8fad5b-d9cb-469f-a165-70867728950e"
	base := func(action ipc.Action) ipc.Request { return ipc.Request{Version: ipc.Version, ID: id, Action: action} }
	with := func(action ipc.Action, edit func(*ipc.Request)) ipc.Request {
		request := base(action)
		edit(&request)
		return request
	}
	for _, test := range []struct {
		name    string
		request ipc.Request
		want    ipc.ControllerFailure
	}{
		{"handshake any version", ipc.Request{Version: 99, Action: ipc.ActionHandshake}, ""},
		{"snapshot", base(ipc.ActionSnapshot), ""},
		{"snapshot check server", with(ipc.ActionSnapshot, func(r *ipc.Request) { r.CheckServer = true }), ""},
		{"wrong version", with(ipc.ActionSnapshot, func(r *ipc.Request) { r.Version = 2 }), ipc.FailureIncompatibleVersion},
		{"wrong version before field checks", ipc.Request{Version: 0, ID: "bad", Action: ipc.ActionConnect}, ipc.FailureIncompatibleVersion},
		{"unknown action", base("lifecycle"), ipc.FailureInvalidRequest},
		{"uppercase id", with(ipc.ActionSnapshot, func(r *ipc.Request) { r.ID = strings.ToUpper(id) }), ipc.FailureInvalidRequest},
		{"braced id", with(ipc.ActionSnapshot, func(r *ipc.Request) { r.ID = "{" + id[1:35] + "}" }), ipc.FailureInvalidRequest},
		{"missing id", with(ipc.ActionSnapshot, func(r *ipc.Request) { r.ID = "" }), ipc.FailureInvalidRequest},
		{"check server elsewhere", with(ipc.ActionConnect, func(r *ipc.Request) { r.CheckServer = true }), ipc.FailureInvalidRequest},
		{"operation", with(ipc.ActionOperation, func(r *ipc.Request) { r.ContextID = context }), ""},
		{"confirm", with(ipc.ActionConfirm, func(r *ipc.Request) { r.ContextID = context }), ""},
		{"confirm without context", base(ipc.ActionConfirm), ipc.FailureInvalidRequest},
		{"confirm bad context", with(ipc.ActionConfirm, func(r *ipc.Request) { r.ContextID = "context" }), ipc.FailureInvalidRequest},
		{"login status with identifier", with(ipc.ActionLoginStatus, func(r *ipc.Request) { r.ContextID, r.Identifier = context, "a/b/c" }), ipc.FailureInvalidRequest},
		{"cancel login", with(ipc.ActionCancelLogin, func(r *ipc.Request) { r.ContextID = context }), ""},
		{"begin login", base(ipc.ActionBeginLogin), ""},
		{"begin login with context", with(ipc.ActionBeginLogin, func(r *ipc.Request) { r.ContextID = context }), ipc.FailureInvalidRequest},
		{"bare connect", base(ipc.ActionConnect), ""},
		{"connect identifier", with(ipc.ActionConnect, func(r *ipc.Request) { r.Identifier = "uid/us-sanjose-1/c1" }), ""},
		{"connect bad identifier", with(ipc.ActionConnect, func(r *ipc.Request) { r.Identifier = "uid/../c1" }), ipc.FailureInvalidRequest},
		{"connect region", with(ipc.ActionConnect, func(r *ipc.Request) { r.RegionID = "us" }), ipc.FailureInvalidRequest},
		{"disconnect client", with(ipc.ActionDisconnectClient, func(r *ipc.Request) { r.Identifier = "uid/us/c1" }), ""},
		{"disconnect without identifier", base(ipc.ActionDisconnectClient), ipc.FailureInvalidRequest},
		{"remove two segments", with(ipc.ActionRemoveClient, func(r *ipc.Request) { r.Identifier = "uid/c1" }), ipc.FailureInvalidRequest},
		{"remove with context", with(ipc.ActionRemoveClient, func(r *ipc.Request) { r.Identifier, r.ContextID = "uid/us/c1", context }), ipc.FailureInvalidRequest},
		{"create", with(ipc.ActionCreateClient, func(r *ipc.Request) { r.RegionID, r.ClientName, r.ContextID = "us-a", "Work laptop", context }), ""},
		{"create 80 runes", with(ipc.ActionCreateClient, func(r *ipc.Request) {
			r.RegionID, r.ClientName, r.ContextID = "us-a", strings.Repeat("é", 80), context
		}), ""},
		{"create 81 runes", with(ipc.ActionCreateClient, func(r *ipc.Request) {
			r.RegionID, r.ClientName, r.ContextID = "us-a", strings.Repeat("a", 81), context
		}), ipc.FailureInvalidRequest},
		{"create padded name", with(ipc.ActionCreateClient, func(r *ipc.Request) { r.RegionID, r.ClientName, r.ContextID = "us-a", " Mac", context }), ipc.FailureInvalidRequest},
		{"create control name", with(ipc.ActionCreateClient, func(r *ipc.Request) { r.RegionID, r.ClientName, r.ContextID = "us-a", "Ma\u0007c", context }), ipc.FailureInvalidRequest},
		{"create format name", with(ipc.ActionCreateClient, func(r *ipc.Request) { r.RegionID, r.ClientName, r.ContextID = "us-a", "Ma​c", context }), ipc.FailureInvalidRequest},
		{"create empty name", with(ipc.ActionCreateClient, func(r *ipc.Request) { r.RegionID, r.ContextID = "us-a", context }), ipc.FailureInvalidRequest},
		{"create bad region", with(ipc.ActionCreateClient, func(r *ipc.Request) { r.RegionID, r.ClientName, r.ContextID = "us/a", "Mac", context }), ipc.FailureInvalidRequest},
		{"create without context", with(ipc.ActionCreateClient, func(r *ipc.Request) { r.RegionID, r.ClientName = "us-a", "Mac" }), ipc.FailureInvalidRequest},
		{"set mode", with(ipc.ActionSetMode, func(r *ipc.Request) { r.Mode = ipc.ModeMesh }), ""},
		{"set mode missing", base(ipc.ActionSetMode), ipc.FailureInvalidRequest},
		{"set mode unknown", with(ipc.ActionSetMode, func(r *ipc.Request) { r.Mode = "split" }), ipc.FailureInvalidRequest},
		{"mode elsewhere", with(ipc.ActionConnect, func(r *ipc.Request) { r.Mode = ipc.ModeFull }), ipc.FailureInvalidRequest},
		{"update allow disconnect", with(ipc.ActionUpdate, func(r *ipc.Request) { r.AllowDisconnect = true }), ""},
		{"allow disconnect elsewhere", with(ipc.ActionTurnOff, func(r *ipc.Request) { r.AllowDisconnect = true }), ipc.FailureInvalidRequest},
		{"diagnostics", with(ipc.ActionDiagnostics, func(r *ipc.Request) { r.Probe = "network_tools" }), ""},
		{"diagnostics local probe", with(ipc.ActionDiagnostics, func(r *ipc.Request) { r.Probe = "daemon" }), ipc.FailureInvalidRequest},
		{"diagnostics unknown probe", with(ipc.ActionDiagnostics, func(r *ipc.Request) { r.Probe = "shell" }), ipc.FailureInvalidRequest},
		{"diagnostics without probe", base(ipc.ActionDiagnostics), ipc.FailureInvalidRequest},
		{"probe elsewhere", with(ipc.ActionSnapshot, func(r *ipc.Request) { r.Probe = "dns" }), ipc.FailureInvalidRequest},
		{"turn off with identifier", with(ipc.ActionTurnOff, func(r *ipc.Request) { r.Identifier = "a/b/c" }), ipc.FailureInvalidRequest},
		{"prepare client", base(ipc.ActionPrepareClient), ""},
		{"sign out with client name", with(ipc.ActionSignOut, func(r *ipc.Request) { r.ClientName = "Mac" }), ipc.FailureInvalidRequest},
	} {
		if got := Validate(test.request); got != test.want {
			t.Errorf("%s: got %q, want %q", test.name, got, test.want)
		}
	}
}
