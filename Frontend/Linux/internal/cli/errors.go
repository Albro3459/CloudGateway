package cli

import (
	"context"
	"errors"
	"fmt"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

type code string

const (
	codeUsage                       code = "usage"
	codeInternalError               code = "internal_error"
	codeNotImplemented              code = "not_implemented"
	codeInvalidResponse             code = "invalid_response"
	codeSignInRequired              code = "sign_in_required"
	codeAccessDenied                code = "access_denied"
	codeSetupRequired               code = "setup_required"
	codeCredentialsUnavailable      code = "credentials_unavailable"
	codeIncompatibleVersion         code = "incompatible_version"
	codeUntrustedBuild              code = "untrusted_build"
	codeInstallationRequired        code = "installation_required"
	codeControllerUnavailable       code = "controller_unavailable"
	codeControllerRejected          code = "controller_rejected"
	codeConfigUnavailable           code = "config_unavailable"
	codeSelectionUnavailable        code = "selection_unavailable"
	codeClientActive                code = "client_active"
	codeNetworkUnavailable          code = "network_unavailable"
	codeRefreshSkipped              code = "refresh_skipped"
	codeRefreshSuperseded           code = "refresh_superseded"
	codeInterrupted                 code = "interrupted"
	codeBusy                        code = "busy"
	codeTimeout                     code = "timeout"
	codeStopTimedOut                code = "stop_timed_out"
	codeVPNFailed                   code = "vpn_failed"
	codeCommandFailed               code = "command_failed"
	codeExtensionMismatch           code = "extension_mismatch"
	codeInitialSetupRequired        code = "initial_setup_required"
	codeExtensionReplacementBlocked code = "extension_replacement_blocked"
	codeApprovalRequired            code = "approval_required"
	codeRestartRequired             code = "restart_required"
	codeInvalidBundle               code = "invalid_bundle"
	codeCheckingReadiness           code = "checking_readiness"
	codeActivationFailed            code = "activation_failed"
	codeReadinessFailed             code = "readiness_failed"
	codeDisconnectRequired          code = "disconnect_required"
	codeStorageUnavailable          code = "storage_unavailable"
	codeObservationUnavailable      code = "observation_unavailable"
	codeUpdateSuperseded            code = "update_superseded"
	codeReconnectSuppressed         code = "reconnect_suppressed"
	codeOperationUnknown            code = "operation_unknown"
	codeOperationExpired            code = "operation_expired"
)

type codeInfo struct {
	exit       int
	message    string
	suggestion string
}

// Apple-only codes keep their macOS text since Linux never emits them
var codes = map[code]codeInfo{
	codeUsage:                  {2, "Invalid command line", "Run: cloudgateway help"},
	codeInternalError:          {1, "CloudGateway hit an unexpected error", ""},
	codeNotImplemented:         {1, "This command is not available in this build yet", ""},
	codeInvalidResponse:        {1, "The daemon returned an invalid response", "Try again. Run cloudgateway doctor if this continues"},
	codeSignInRequired:         {3, "Sign-in required", "Run: cloudgateway auth login"},
	codeAccessDenied:           {3, "Account access was denied", "Sign in again after access is restored"},
	codeSetupRequired:          {4, "VPN setup is not finished", "Run: cloudgateway doctor"},
	codeCredentialsUnavailable: {4, "Saved credentials or secure storage are unavailable", "Run: cloudgateway doctor"},
	codeIncompatibleVersion: {4, "CloudGateway is updating, or this CLI does not match the running daemon",
		"Wait for the daemon restart to finish, or run: sudo systemctl restart cloudgatewayd"},
	codeUntrustedBuild:        {4, "CloudGateway could not verify its running build", "Reinstall CloudGateway with the installer"},
	codeInstallationRequired:  {4, "CloudGateway is not installed", "Install CloudGateway with the installer, then try again"},
	codeControllerUnavailable: {4, "Unable to reach the CloudGateway daemon", "Check it with: systemctl status cloudgatewayd"},
	codeControllerRejected: {4, "The CloudGateway daemon rejected this request",
		"Run the command as root or as the operator account enrolled during installation"},
	codeConfigUnavailable:    {5, "That config is missing or unusable", "Run: cloudgateway list"},
	codeSelectionUnavailable: {5, "No usable config is selected", "Run cloudgateway ls, then cloudgateway up <client-uuid>"},
	codeClientActive:         {4, "That client still has an active VPN profile", "Disconnect that client and wait for it to stop before removing it"},
	codeNetworkUnavailable:   {6, "Unable to reach CloudGateway", "Check the network connection, then try again"},
	codeRefreshSkipped:       {6, "Inventory refresh did not run", "Run: cloudgateway refresh"},
	codeRefreshSuperseded:    {7, "Another operation superseded this inventory refresh", "Run: cloudgateway refresh"},
	codeInterrupted:          {130, "The caller was interrupted", ""},
	codeBusy:                 {7, "Another operation is in progress", "Wait for it to finish, then try again"},
	codeTimeout:              {8, "The command did not finish before its deadline", "Try again with a longer --timeout"},
	codeStopTimedOut:         {8, "The VPN has not confirmed stop", "Run: cloudgateway status"},
	codeVPNFailed:            {9, "The VPN operation failed", "Run: cloudgateway status"},
	codeCommandFailed:        {9, "The command failed", "Run: cloudgateway status"},
	codeExtensionMismatch:    {4, "The running VPN extension does not match the installed app", "Run: cloudgateway update"},
	codeExtensionReplacementBlocked: {4, "The running VPN extension has the installed version and build number but different code, so macOS will not replace it",
		"Install a CloudGateway build with a higher VPN extension build number, then run: cloudgateway update"},
	codeInitialSetupRequired: {4, "Initial VPN setup is required", "Open CloudGateway on this Mac to finish initial setup"},
	codeApprovalRequired: {4, "macOS approval is required for the VPN extension",
		"Approve CloudGateway in System Settings on this Mac, then check the operation"},
	codeRestartRequired: {4, "macOS must restart to finish the VPN extension update",
		"Restart this Mac, then check the operation. The controller resumes when next started"},
	codeInvalidBundle:     {4, "The installed VPN extension bundle is invalid", "Reinstall CloudGateway in /Applications"},
	codeCheckingReadiness: {4, "CloudGateway is still checking VPN extension readiness", "Run: cloudgateway status"},
	codeActivationFailed:  {9, "CloudGateway could not activate the installed release", "Run: cloudgateway doctor"},
	codeReadinessFailed:   {9, "The restarted daemon did not pass readiness checks", "Run: cloudgateway doctor"},
	codeDisconnectRequired: {4, "Updating the VPN extension requires stopping the active VPN",
		"Run: cloudgateway update --allow-disconnect. This can disconnect SSH if it uses the VPN"},
	codeStorageUnavailable:     {6, "CloudGateway could not persist the update safely", "Check this machine's available storage and permissions"},
	codeObservationUnavailable: {6, "CloudGateway cannot observe the current VPN profiles", "Run: cloudgateway status"},
	codeUpdateSuperseded:       {10, "The installed release changed during this update", "Check the operation before requesting another update"},
	codeReconnectSuppressed: {10, "The VPN update did not reconnect because its original connection is no longer authorized",
		"Check the current VPN state and account before requesting a start"},
	codeOperationUnknown: {10, "The operation result is unknown or no longer retained", "Run cloudgateway status before trying again"},
	codeOperationExpired: {10, "The operation expired before it ran", "Run the command again"},
}

func (c code) exitCode() int { return codes[c].exit }

// publicCode accepts a code string from the daemon, falling back for unknown values
func publicCode(value string, fallback code) code {
	if _, ok := codes[code(value)]; ok {
		return code(value)
	}
	return fallback
}

// cliError is a public failure. A nil suggestion is absent, and data rides along in the error record
type cliError struct {
	code        code
	message     string
	suggestion  *string
	data        data
	operationID string
}

func (e *cliError) Error() string { return string(e.code) + ": " + e.message }

// newError fills an empty message or suggestion from the code's defaults
func newError(c code, message, suggestion string) *cliError {
	if message == "" {
		message = codes[c].message
	}
	if suggestion == "" {
		suggestion = codes[c].suggestion
	}
	e := &cliError{code: c, message: message}
	if suggestion != "" {
		e.suggestion = &suggestion
	}
	return e
}

func errorCode(c code) *cliError { return newError(c, "", "") }

// errNoConnection means the socket couldn't connect or the connection dropped mid-call, as when the
// daemon restarts. A live daemon replying unavailable is a controllerFailure instead
var errNoConnection = errors.New("no daemon connection")

// errRestarting is a socket that refuses connections. The daemon keeps its
// socket file across a restart, so nobody listening means it is starting
var errRestarting = fmt.Errorf("%w: socket refused", errNoConnection)

// controllerFailure is a request-level failure the daemon replied with
type controllerFailure ipc.ControllerFailure

func (f controllerFailure) Error() string { return string(f) }

func fromControllerFailure(failure ipc.ControllerFailure) *cliError {
	switch failure {
	case ipc.FailureIncompatibleVersion:
		return errorCode(codeIncompatibleVersion)
	case ipc.FailureUnavailable:
		return errorCode(codeControllerUnavailable)
	case ipc.FailureTimeout:
		return errorCode(codeTimeout)
	case ipc.FailureBusy:
		return errorCode(codeBusy)
	case ipc.FailureRejected:
		return errorCode(codeControllerRejected)
	case ipc.FailureOutcomeUnknown:
		return errorCode(codeOperationUnknown)
	case ipc.FailurePreparationExpired:
		return errorCode(codeOperationExpired)
	case ipc.FailureCommandFailed:
		return errorCode(codeCommandFailed)
	case ipc.FailureAuthCleanupFailed:
		return newError(codeCredentialsUnavailable, "Sign-out cleanup did not finish", "")
	}
	return errorCode(codeInvalidResponse)
}

// asError maps any failure to its stable public category so raw errors never reach output
func asError(err error) *cliError {
	var public *cliError
	var failure controllerFailure
	switch {
	case errors.As(err, &public):
		return public
	case errors.As(err, &failure):
		return fromControllerFailure(ipc.ControllerFailure(failure))
	case errors.Is(err, errNoConnection):
		return errorCode(codeControllerUnavailable)
	case errors.Is(err, context.Canceled):
		return errorCode(codeInterrupted)
	case errors.Is(err, context.DeadlineExceeded):
		return errorCode(codeTimeout)
	}
	return errorCode(codeInternalError)
}

func isControllerFailure(err error, failure ipc.ControllerFailure) bool {
	var value controllerFailure
	return errors.As(err, &value) && ipc.ControllerFailure(value) == failure
}
