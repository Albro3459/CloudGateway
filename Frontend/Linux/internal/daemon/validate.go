package daemon

import (
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
)

// Validate ports the macOS controller request rules. Handshake skips them so
// any CLI version can read the lifecycle and report a mismatch
func Validate(request ipc.Request) ipc.ControllerFailure {
	if request.Action == ipc.ActionHandshake {
		return ""
	}
	if request.Version != ipc.Version {
		return ipc.FailureIncompatibleVersion
	}
	if !validUUID(request.ID) || request.ContextID != "" && !validUUID(request.ContextID) {
		return ipc.FailureInvalidRequest
	}
	if request.AllowDisconnect && request.Action != ipc.ActionUpdate ||
		request.CheckServer && request.Action != ipc.ActionSnapshot ||
		(request.Mode != "") != (request.Action == ipc.ActionSetMode) ||
		request.Mode != "" && request.Mode != ipc.ModeFull && request.Mode != ipc.ModeMesh ||
		(request.Probe != "") != (request.Action == ipc.ActionDiagnostics) ||
		request.Probe != "" && !daemonProbe(request.Probe) {
		return ipc.FailureInvalidRequest
	}
	noTarget := request.Identifier == "" && request.RegionID == "" && request.ClientName == ""
	var valid bool
	switch request.Action {
	case ipc.ActionLoginStatus, ipc.ActionCancelLogin, ipc.ActionOperation, ipc.ActionConfirm:
		valid = request.ContextID != "" && noTarget
	case ipc.ActionConnect:
		valid = (request.Identifier == "" || store.ValidIdentifier(request.Identifier)) &&
			request.RegionID == "" && request.ClientName == "" && request.ContextID == ""
	case ipc.ActionDisconnectClient, ipc.ActionRemoveClient:
		valid = store.ValidIdentifier(request.Identifier) &&
			request.RegionID == "" && request.ClientName == "" && request.ContextID == ""
	case ipc.ActionCreateClient:
		name := request.ClientName
		valid = request.Identifier == "" && store.ValidComponent(request.RegionID) &&
			store.BoundedText(name, 320) && utf8.RuneCountInString(name) <= 80 && name == strings.TrimSpace(name) &&
			request.ContextID != ""
	case ipc.ActionSnapshot, ipc.ActionUserActivity, ipc.ActionAwaitRefresh, ipc.ActionBeginLogin,
		ipc.ActionSignOut, ipc.ActionTurnOff, ipc.ActionPrepareClient, ipc.ActionSetMode,
		ipc.ActionUpdate, ipc.ActionDiagnostics:
		valid = noTarget && request.ContextID == ""
	}
	if !valid {
		return ipc.FailureInvalidRequest
	}
	return ""
}

// validUUID accepts only the lowercase canonical form
func validUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for i := range len(value) {
		c := value[i]
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
				return false
			}
		}
	}
	return true
}

func daemonProbe(name string) bool {
	return slices.ContainsFunc(ipc.DoctorProbes, func(probe ipc.DoctorProbe) bool {
		return probe.Name == name && !probe.Local
	})
}
