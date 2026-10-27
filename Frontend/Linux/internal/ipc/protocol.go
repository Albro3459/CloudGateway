// Package ipc defines the local protocol between the cloudgateway CLI and
// cloudgatewayd. Messages are length-framed JSON over a Unix socket. The daemon
// derives the caller from SO_PEERCRED, so requests never carry a UID or account
package ipc

import "time"

// Version changes whenever request or reply meaning changes. Handshake keeps a
// stable shape across versions so a CLI can report a mismatch
const Version = 1

const (
	MaxRequestBytes = 64 << 10
	MaxReplyBytes   = 4 << 20
)

type Action string

const (
	ActionHandshake        Action = "handshake"
	ActionSnapshot         Action = "snapshot"
	ActionOperation        Action = "operation"
	ActionConfirm          Action = "confirm"
	ActionUserActivity     Action = "userActivity"
	ActionAwaitRefresh     Action = "awaitRefresh"
	ActionBeginLogin       Action = "beginLogin"
	ActionLoginStatus      Action = "loginStatus"
	ActionCancelLogin      Action = "cancelLogin"
	ActionSignOut          Action = "signOut"
	ActionConnect          Action = "connect"
	ActionTurnOff          Action = "turnOff"
	ActionDisconnectClient Action = "disconnectClient"
	ActionPrepareClient    Action = "prepareClient"
	ActionCreateClient     Action = "createClient"
	ActionRemoveClient     Action = "removeClient"
	ActionSetMode          Action = "setMode"
	ActionUpdate           Action = "update"
	ActionDiagnostics      Action = "diagnostics"
)

// RequiresConfirmation lists actions the daemon reserves first. Effects start
// only after the CLI flushes the accepted ID and sends ActionConfirm
func (a Action) RequiresConfirmation() bool {
	switch a {
	case ActionSignOut, ActionConnect, ActionTurnOff, ActionDisconnectClient,
		ActionCreateClient, ActionRemoveClient, ActionSetMode, ActionUpdate:
		return true
	}
	return false
}

// AccountBound outcomes are hidden from other sessions after logout or an account change
func (a Action) AccountBound() bool {
	switch a {
	case ActionConnect, ActionCreateClient, ActionDisconnectClient, ActionRemoveClient, ActionSetMode:
		return true
	}
	return false
}

type Mode string

const (
	ModeFull Mode = "full"
	ModeMesh Mode = "mesh"
)

type Request struct {
	Version int    `json:"version"`
	ID      string `json:"id"`
	Action  Action `json:"action"`
	// Identifier is the compound config ID signedInUID/regionId/clientId
	Identifier string `json:"identifier,omitempty"`
	RegionID   string `json:"regionId,omitempty"`
	ClientName string `json:"clientName,omitempty"`
	// ContextID names an existing operation, login attempt, or client creation context
	ContextID       string `json:"contextId,omitempty"`
	Mode            Mode   `json:"mode,omitempty"`
	AllowDisconnect bool   `json:"allowDisconnect,omitempty"`
	// CheckServer asks a snapshot to probe whether the connected server responds.
	// Human status asks for it. JSON status never does
	CheckServer bool `json:"checkServer,omitempty"`
	// Probe names one daemon-side doctor check
	Probe string `json:"probe,omitempty"`
}

// ControllerFailure is a request-level failure, as opposed to a command outcome
type ControllerFailure string

const (
	FailureInvalidRequest      ControllerFailure = "invalidRequest"
	FailureIncompatibleVersion ControllerFailure = "incompatibleVersion"
	FailureUnavailable         ControllerFailure = "unavailable"
	FailureTimeout             ControllerFailure = "timeout"
	FailureBusy                ControllerFailure = "busy"
	FailureRejected            ControllerFailure = "rejected"
	FailureOutcomeUnknown      ControllerFailure = "outcomeUnknown"
	FailurePreparationExpired  ControllerFailure = "preparationExpired"
	FailureCommandFailed       ControllerFailure = "commandFailed"
	FailureAuthCleanupFailed   ControllerFailure = "authCleanupFailed"
)

type Reply struct {
	Version int `json:"version"`
	// Release is the running daemon's release version
	Release    string            `json:"release"`
	InstanceID string            `json:"instanceId"`
	Error      ControllerFailure `json:"error,omitempty"`
	Lifecycle  *Lifecycle        `json:"lifecycle,omitempty"`
	State      *State            `json:"state,omitempty"`
	Operation  *Operation        `json:"operation,omitempty"`
	Outcome    *Outcome          `json:"outcome,omitempty"`
	Refresh    RefreshResult     `json:"refresh,omitempty"`
	Creation   *Creation         `json:"creation,omitempty"`
	Login      *LoginStatus      `json:"login,omitempty"`
	Update     *UpdateStatus     `json:"update,omitempty"`
	Check      *DoctorCheck      `json:"check,omitempty"`
}

type LifecycleState string

const (
	LifecycleCurrent LifecycleState = "current"
	// LifecycleDraining means the daemon is restarting onto the installed release
	LifecycleDraining LifecycleState = "draining"
	// LifecycleInvalidInstallation means no readable installed release exists
	LifecycleInvalidInstallation LifecycleState = "invalidInstallation"
)

type BuildIdentity struct {
	Version string `json:"version"`
	Build   string `json:"build"`
	// CodeHash is the lowercase hex SHA-256 of the release manifest
	CodeHash string `json:"codeHash"`
}

// Lifecycle answers every handshake, whatever the caller's IPC version. Keep its
// shape stable so a mismatched CLI can still report the tunnel and the version error
type Lifecycle struct {
	Running   BuildIdentity  `json:"running"`
	Installed *BuildIdentity `json:"installed,omitempty"`
	State     LifecycleState `json:"state"`
	Tunnel    Tunnel         `json:"tunnel"`
}

type AccessState string

const (
	AccessUnverified  AccessState = "unverified"
	AccessChecking    AccessState = "checking"
	AccessOnline      AccessState = "online"
	AccessOffline     AccessState = "offline"
	AccessDenied      AccessState = "denied"
	AccessUnreachable AccessState = "unreachable"
)

type InventoryFreshness string

const (
	InventoryUnavailable InventoryFreshness = "unavailable"
	InventoryRefreshing  InventoryFreshness = "refreshing"
	InventoryCurrent     InventoryFreshness = "current"
	InventoryCached      InventoryFreshness = "cached"
)

// TunnelPhase is the public tunnel state from the research observation mapping
type TunnelPhase string

const (
	TunnelDisconnected  TunnelPhase = "disconnected"
	TunnelConnecting    TunnelPhase = "connecting"
	TunnelConnected     TunnelPhase = "connected"
	TunnelDisconnecting TunnelPhase = "disconnecting"
	TunnelUnknown       TunnelPhase = "unknown"
)

type Observation string

const (
	ObservationCurrent     Observation = "current"
	ObservationStale       Observation = "stale"
	ObservationUnavailable Observation = "unavailable"
)

// ClientTunnel is one inventory row's tunnel status
type ClientTunnel string

const (
	ClientTunnelInvalid       ClientTunnel = "invalid"
	ClientTunnelDisconnected  ClientTunnel = "disconnected"
	ClientTunnelConnecting    ClientTunnel = "connecting"
	ClientTunnelConnected     ClientTunnel = "connected"
	ClientTunnelReasserting   ClientTunnel = "reasserting"
	ClientTunnelDisconnecting ClientTunnel = "disconnecting"
)

type Tunnel struct {
	Phase       TunnelPhase `json:"phase"`
	Observation Observation `json:"observation"`
	ObservedAt  *time.Time  `json:"observedAt,omitempty"`
	// ConfigID is nil when nothing is active or the active profile belongs to another account
	ConfigID *string `json:"configId,omitempty"`
}

type Client struct {
	Identifier    string       `json:"identifier"`
	ClientID      string       `json:"clientId"`
	RegionID      string       `json:"regionId"`
	RegionName    string       `json:"regionName"`
	RegionOrder   int          `json:"regionOrder"`
	ClientName    string       `json:"clientName"`
	OwnerLabel    *string      `json:"ownerLabel,omitempty"`
	InternalIP    *string      `json:"internalIp,omitempty"`
	ConnectionURL *string      `json:"connectionUrl,omitempty"`
	CloudState    string       `json:"cloudState"`  // creating|active|failed|removed
	Eligibility   string       `json:"eligibility"` // eligible|inactive|config_missing|region_unavailable
	Installed     bool         `json:"installed"`
	Source        string       `json:"source"` // cloud|cache
	ReadAt        time.Time    `json:"readAt"`
	UpdatedAt     *time.Time   `json:"updatedAt,omitempty"`
	Status        ClientTunnel `json:"status,omitempty"`
}

// State is the account-filtered daemon view. Clients, selection, and selected
// mode only ever describe AccountID
type State struct {
	AccountID          *string            `json:"accountId,omitempty"`
	HasRetainedSession bool               `json:"hasRetainedSession"`
	IsRestoring        bool               `json:"isRestoring"`
	AccessAuthorized   bool               `json:"accessAuthorized"`
	Access             AccessState        `json:"access"`
	Credentials        string             `json:"credentials"` // available|unknown
	LoginPending       bool               `json:"loginPending"`
	Inventory          InventoryFreshness `json:"inventory"`
	Clients            []Client           `json:"clients"`
	Tunnel             Tunnel             `json:"tunnel"`
	SelectedIdentifier *string            `json:"selectedIdentifier,omitempty"`
	SelectedMode       *Mode              `json:"selectedMode,omitempty"`
	ActiveMode         *Mode              `json:"activeMode,omitempty"`
	CreationAllowed    bool               `json:"creationAllowed"`
	// ServerResponding answers CheckServer for a connected tunnel. Nil when not checked
	ServerResponding *bool `json:"serverResponding,omitempty"`
}

type OperationState string

const (
	OperationAccepted  OperationState = "accepted"
	OperationRunning   OperationState = "running"
	OperationCompleted OperationState = "completed"
	OperationFailed    OperationState = "failed"
	OperationUnknown   OperationState = "unknown"
)

type Warning string

const (
	WarningSelectionNotSaved                Warning = "selection_not_saved"
	WarningInventoryNotRefreshed            Warning = "inventory_not_refreshed"
	WarningLocalCleanupIncomplete           Warning = "local_cleanup_incomplete"
	WarningReconnectSuppressionNotPersisted Warning = "reconnect_suppression_not_persisted"
)

// Operation is part of the handshake every daemon version answers, so keep its
// shape stable, like Lifecycle
type Operation struct {
	ID      string            `json:"id"`
	State   OperationState    `json:"state"`
	Failure ControllerFailure `json:"failure,omitempty"`
	Warning Warning           `json:"warning,omitempty"`
}

type OutcomeKind string

const (
	OutcomeStartRequested OutcomeKind = "startRequested"
	OutcomeAlreadyActive  OutcomeKind = "alreadyActive"
	OutcomeCompleted      OutcomeKind = "completed"
	OutcomeFailed         OutcomeKind = "failed"
	OutcomeUnknown        OutcomeKind = "unknown"
	OutcomeExpired        OutcomeKind = "expired"
)

// CommandFailure values are the public CLI error codes a failed outcome maps to
type CommandFailure string

const (
	CommandSignInRequired         CommandFailure = "sign_in_required"
	CommandAccessDenied           CommandFailure = "access_denied"
	CommandSetupRequired          CommandFailure = "setup_required"
	CommandCredentialsUnavailable CommandFailure = "credentials_unavailable"
	CommandIncompatibleVersion    CommandFailure = "incompatible_version"
	CommandConfigUnavailable      CommandFailure = "config_unavailable"
	CommandSelectionUnavailable   CommandFailure = "selection_unavailable"
	CommandClientActive           CommandFailure = "client_active"
	CommandNetworkUnavailable     CommandFailure = "network_unavailable"
	CommandBusy                   CommandFailure = "busy"
	CommandStopTimedOut           CommandFailure = "stop_timed_out"
	CommandVPNFailed              CommandFailure = "vpn_failed"
	CommandInternalError          CommandFailure = "internal_error"
)

// Outcome is the account-bound result of a finished operation
type Outcome struct {
	Kind       OutcomeKind    `json:"kind"`
	Identifier string         `json:"identifier,omitempty"`
	Warning    Warning        `json:"warning,omitempty"`
	Failure    CommandFailure `json:"failure,omitempty"`
}

type RefreshResult string

const (
	RefreshRefreshed      RefreshResult = "refreshed"
	RefreshUnavailable    RefreshResult = "unavailable"
	RefreshDenied         RefreshResult = "denied"
	RefreshSignInRequired RefreshResult = "sign_in_required"
	RefreshSkipped        RefreshResult = "skipped"
	RefreshSuperseded     RefreshResult = "superseded"
	RefreshTimedOut       RefreshResult = "timed_out"
)

type Capacity struct {
	Known     bool `json:"known"`
	Limit     int  `json:"limit,omitempty"`
	Allocated int  `json:"allocated,omitempty"`
}

type CreationRegion struct {
	RegionID     string    `json:"regionId"`
	DisplayName  string    `json:"displayName"`
	Enabled      bool      `json:"enabled"`
	DisplayOrder int       `json:"displayOrder"`
	Capacity     *Capacity `json:"capacity,omitempty"`
}

// Creation is a short-lived client creation context. createClient must name its ID
type Creation struct {
	ID      string           `json:"id"`
	Regions []CreationRegion `json:"regions"`
}

type LoginPhase string

const (
	LoginRequestingCode     LoginPhase = "requestingCode"
	LoginWaitingForApproval LoginPhase = "waitingForApproval"
	LoginExchangingToken    LoginPhase = "exchangingToken"
	LoginRestoring          LoginPhase = "restoring"
	LoginFinished           LoginPhase = "finished"
)

type LoginResult string

const (
	LoginAuthorized      LoginResult = "authorized"
	LoginBusy            LoginResult = "busy"
	LoginCancelled       LoginResult = "cancelled"
	LoginExpired         LoginResult = "expired"
	LoginDenied          LoginResult = "denied"
	LoginInvalidResponse LoginResult = "invalidResponse"
	LoginOffline         LoginResult = "offline"
	LoginUnavailable     LoginResult = "unavailable"
)

type LoginChallenge struct {
	VerificationURL  string `json:"verificationURL"`
	UserCode         string `json:"userCode"`
	RemainingSeconds int    `json:"remainingSeconds"`
}

type LoginStatus struct {
	AttemptID string          `json:"attemptId"`
	Phase     LoginPhase      `json:"phase"`
	Challenge *LoginChallenge `json:"challenge,omitempty"`
	Result    LoginResult     `json:"result,omitempty"`
}

// UpdatePhase keeps the macOS schema. Linux emits only prepared, activating,
// checking_readiness, completed, failed, and superseded
type UpdatePhase string

const (
	UpdatePrepared          UpdatePhase = "prepared"
	UpdateStopping          UpdatePhase = "stopping"
	UpdateActivating        UpdatePhase = "activating"
	UpdateApprovalRequired  UpdatePhase = "approval_required"
	UpdateRestartRequired   UpdatePhase = "restart_required"
	UpdateCheckingReadiness UpdatePhase = "checking_readiness"
	UpdateReconnecting      UpdatePhase = "reconnecting"
	UpdateCompleted         UpdatePhase = "completed"
	UpdateFailed            UpdatePhase = "failed"
	UpdateSuperseded        UpdatePhase = "superseded"
)

type UpdateStatus struct {
	ID         string        `json:"id"`
	Phase      UpdatePhase   `json:"phase"`
	Target     BuildIdentity `json:"target"`
	Identifier string        `json:"identifier,omitempty"`
	Reconnect  bool          `json:"reconnect"`
	// Error and Warning are public CLI error codes
	Error   string `json:"error,omitempty"`
	Warning string `json:"warning,omitempty"`
}

// Operation maps an update record to its generic operation view, as on macOS
func (u UpdateStatus) Operation() Operation {
	state := OperationRunning
	var failure ControllerFailure
	switch u.Phase {
	case UpdatePrepared:
		state = OperationAccepted
	case UpdateCompleted:
		state = OperationCompleted
	case UpdateSuperseded:
		state, failure = OperationUnknown, FailureOutcomeUnknown
	case UpdateFailed:
		state, failure = OperationFailed, FailureCommandFailed
	}
	return Operation{ID: u.ID, State: state, Failure: failure}
}

type DoctorStatus string

const (
	DoctorPass    DoctorStatus = "pass"
	DoctorWarning DoctorStatus = "warning"
	DoctorFail    DoctorStatus = "fail"
	DoctorUnknown DoctorStatus = "unknown"
)

type DoctorCheck struct {
	Name        string       `json:"name"`
	Status      DoctorStatus `json:"status"`
	Evidence    string       `json:"evidence"`
	Suggestion  *string      `json:"suggestion,omitempty"`
	FailureCode *string      `json:"failureCode,omitempty"`
}
