package cli

import (
	"cmp"
	"maps"
	"slices"
	"strings"
	"time"
	"unicode"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/jsonout"
)

// sanitize replaces control and format characters (Unicode Cc and Cf) so labels cannot drive the terminal
func sanitize(value string) string {
	return strings.Map(func(r rune) rune {
		if unicode.Is(unicode.Cc, r) || unicode.Is(unicode.Cf, r) {
			return ' '
		}
		return r
	}, value)
}

func ptr[T any](value T) *T { return &value }

// nullable encodes "" as null for values that can't be empty when present, such as enums and IDs
func nullable(value string) any {
	if value == "" {
		return nil
	}
	return value
}

// optional encodes only an absent value as null, keeping present empty strings
func optional(value *string) any {
	if value == nil {
		return nil
	}
	return *value
}

func nullableTime(value *time.Time) any {
	if value == nil {
		return nil
	}
	return *value
}

// data is one public schema 1 data object
type data interface{ json() any }

type record struct {
	kind        string
	command     string
	operationID string
	data        data
	err         *cliError
}

func (r record) line() ([]byte, error) {
	var dataValue, errValue any
	if r.data != nil {
		dataValue = r.data.json()
	}
	if r.err != nil {
		errValue = failureJSON(r.err)
	}
	line, err := jsonout.Marshal(jsonout.Object{
		"schemaVersion": 1, "type": r.kind, "command": nullable(r.command),
		"operationId": nullable(r.operationID), "data": dataValue, "error": errValue,
	})
	return append(line, '\n'), err
}

// Messages are sanitized. Suggestions are not
func failureJSON(e *cliError) jsonout.Object {
	return jsonout.Object{"code": string(e.code), "message": sanitize(e.message), "suggestion": optional(e.suggestion)}
}

type helpCommand struct{ name, arguments, summary string }

type helpData struct {
	topic         string
	usage         string
	summary       string
	commands      []helpCommand
	options       []option
	commonOptions []option
	notes         []string
	examples      []string
}

func newHelp(t topic) helpData {
	h := helpData{usage: t.usage(), summary: t.summary, options: t.options, commonOptions: commonOptions,
		notes: t.notes, examples: t.examples}
	if t.kind != kindRoot {
		h.topic = t.name()
	}
	for _, sub := range t.subtopics() {
		h.commands = append(h.commands, helpCommand{sub.name(), sub.arguments, sub.summary})
	}
	return h
}

func (h helpData) json() any {
	commands := []jsonout.Object{}
	for _, c := range h.commands {
		commands = append(commands, jsonout.Object{"name": c.name, "arguments": nullable(c.arguments), "summary": c.summary})
	}
	options := func(values []option) []jsonout.Object {
		result := []jsonout.Object{}
		for _, o := range values {
			result = append(result, jsonout.Object{"flags": o.flags(), "value": nullable(o.valueName()), "summary": o.summary()})
		}
		return result
	}
	return jsonout.Object{"topic": nullable(h.topic), "usage": h.usage, "summary": h.summary, "commands": commands,
		"options": options(h.options), "commonOptions": options(h.commonOptions), "notes": h.notes, "examples": h.examples}
}

type versionData struct{ version, build string }

func (v versionData) json() any { return jsonout.Object{"version": v.version, "build": v.build} }

type authStatus struct {
	state           string
	accountID       *string
	retainedSession bool
	access          string
	credentials     string
	loginPending    bool
}

// Restoration can briefly clear its work before the authorized account is published
func isPendingRestoration(s ipc.State) bool { return s.IsRestoring || s.Access == ipc.AccessChecking }

func isAwaitingVerification(s ipc.State) bool {
	return s.AccountID == nil && s.HasRetainedSession && s.Access == ipc.AccessUnverified
}

func newAuthStatus(s ipc.State) authStatus {
	a := authStatus{accountID: s.AccountID, retainedSession: s.HasRetainedSession, access: string(s.Access),
		credentials: "unknown", loginPending: s.LoginPending}
	switch {
	case s.AccountID != nil && s.Access == ipc.AccessOffline:
		a.state = "offline"
	case s.AccountID != nil:
		a.state = "online"
	case isPendingRestoration(s):
		a.state = "restoring"
	case s.Access == ipc.AccessDenied:
		a.state = "denied"
	case s.HasRetainedSession:
		a.state = "retained"
	default:
		a.state = "signed_out"
	}
	if s.Credentials == "available" {
		a.credentials = "available"
	}
	return a
}

func (a authStatus) json() any {
	return jsonout.Object{"state": a.state, "accountId": optional(a.accountID), "retainedSession": a.retainedSession,
		"access": a.access, "credentials": a.credentials, "loginPending": a.loginPending}
}

type tunnel struct {
	state       string
	observation string
	observedAt  *time.Time
	configID    *string
}

// publicTunnel keeps the daemon's observation. Without any observation the state is unknown
func publicTunnel(t ipc.Tunnel) tunnel {
	state := string(t.Phase)
	if t.Observation == ipc.ObservationUnavailable {
		state = string(ipc.TunnelUnknown)
	}
	return tunnel{state: state, observation: string(t.Observation), observedAt: t.ObservedAt, configID: t.ConfigID}
}

// coarseTunnel is what another daemon version may show, without account data
func coarseTunnel(t ipc.Tunnel) tunnel {
	result := publicTunnel(t)
	result.observedAt, result.configID = nil, nil
	return result
}

func (t tunnel) json() any {
	return jsonout.Object{"state": t.state, "observation": t.observation, "observedAt": nullableTime(t.observedAt),
		"configId": optional(t.configID)}
}

type modeStatus struct {
	selectedMode string
	activeMode   string
	tunnelState  string
	observation  string
	observedAt   *time.Time
}

func newModeStatus(s ipc.State) modeStatus {
	t := publicTunnel(s.Tunnel)
	m := modeStatus{tunnelState: t.state, observation: t.observation, observedAt: t.observedAt}
	if s.AccountID != nil && s.SelectedMode != nil {
		m.selectedMode = string(*s.SelectedMode)
	}
	if s.ActiveMode != nil {
		m.activeMode = string(*s.ActiveMode)
	}
	return m
}

func (m modeStatus) json() any {
	return jsonout.Object{"selectedMode": nullable(m.selectedMode), "activeMode": nullable(m.activeMode),
		"tunnelState": m.tunnelState, "observation": m.observation, "observedAt": nullableTime(m.observedAt)}
}

type operation struct {
	id       string
	state    string
	result   string
	configID *string
	warning  string
	// failure never serializes. Its public form is error
	failure *cliError
}

// newOperation keeps only the coarse state when the daemon hides an account-bound outcome
func newOperation(op ipc.Operation, outcome *ipc.Outcome) operation {
	result := operation{id: strings.ToLower(op.ID), state: string(op.State), warning: string(op.Warning)}
	switch {
	case outcome == nil:
		if op.State == ipc.OperationFailed {
			result.failure = fromControllerFailure(cmp.Or(op.Failure, ipc.FailureCommandFailed))
		} else if op.State == ipc.OperationUnknown {
			result.failure = fromControllerFailure(cmp.Or(op.Failure, ipc.FailureOutcomeUnknown))
		}
	case outcome.Kind == ipc.OutcomeStartRequested:
		result.result, result.configID, result.warning = "start_requested", &outcome.Identifier, string(outcome.Warning)
	case outcome.Kind == ipc.OutcomeAlreadyActive:
		result.result, result.configID, result.warning = "already_active", &outcome.Identifier, string(outcome.Warning)
	case outcome.Kind == ipc.OutcomeCompleted:
		result.result = "completed"
		result.warning = string(outcome.Warning)
	case outcome.Kind == ipc.OutcomeFailed:
		result.result = "failed"
		result.failure = errorCode(publicCode(string(outcome.Failure), codeInternalError))
	case outcome.Kind == ipc.OutcomeExpired:
		result.result = "expired"
		result.failure = errorCode(codeOperationExpired)
	default:
		result.result = "unknown"
		result.failure = errorCode(codeOperationUnknown)
	}
	return result
}

func (o operation) json() any {
	var errValue any
	if o.failure != nil {
		errValue = failureJSON(o.failure)
	}
	return jsonout.Object{"id": o.id, "state": o.state, "result": nullable(o.result), "configId": optional(o.configID),
		"warning": nullable(o.warning), "error": errValue}
}

type status struct {
	tunnel    tunnel
	operation *operation
	update    *update
	mode      *modeStatus
	auth      *authStatus
	// serverResponding drives the human refresh hint only
	serverResponding *bool
}

func (s status) json() any {
	object := jsonout.Object{"tunnel": s.tunnel.json(), "operation": nil, "mode": nil, "auth": nil}
	if s.operation != nil {
		object["operation"] = s.operation.json()
	}
	if s.update != nil {
		object["update"] = s.update.json()
	}
	if s.mode != nil {
		object["mode"] = s.mode.json()
	}
	if s.auth != nil {
		object["auth"] = s.auth.json()
	}
	return object
}

type update struct {
	id        string
	phase     string
	version   string
	build     string
	codeHash  string
	configID  string
	reconnect bool
	err       *cliError
	warning   *cliError
}

func newUpdate(u ipc.UpdateStatus) update {
	result := update{id: strings.ToLower(u.ID), phase: string(u.Phase), version: sanitize(u.Target.Version),
		build: sanitize(u.Target.Build), codeHash: u.Target.CodeHash, configID: u.Identifier, reconnect: u.Reconnect}
	if u.Error != "" {
		result.err = errorCode(publicCode(u.Error, codeInternalError))
	}
	if u.Warning == string(codeStorageUnavailable) {
		result.warning = newError(codeStorageUnavailable, "CloudGateway could not persist the update safely. "+
			"Reconnect suppression cannot be guaranteed after daemon restart", "")
	} else if u.Warning != "" {
		result.warning = errorCode(publicCode(u.Warning, codeInternalError))
	}
	return result
}

func (u update) json() any {
	var errValue, warningValue any
	if u.err != nil {
		errValue = failureJSON(u.err)
	}
	if u.warning != nil {
		warningValue = failureJSON(u.warning)
	}
	return jsonout.Object{"id": u.id, "phase": u.phase,
		"target":   jsonout.Object{"version": u.version, "build": u.build, "codeHash": u.codeHash},
		"configId": nullable(u.configID), "reconnect": u.reconnect, "error": errValue, "warning": warningValue}
}

type config struct {
	configID      string
	clientID      string
	index         int
	connectionURL *string
	name          string
	owner         *string
	internalIP    *string
	cloudState    string
	eligibility   string
	installed     bool
	source        string
	selected      bool
	tunnel        string
	readAt        time.Time
	updatedAt     *time.Time
}

func (c config) json() any {
	return jsonout.Object{"configId": c.configID, "clientId": c.clientID, "index": c.index,
		"connectionUrl": optional(c.connectionURL), "name": c.name, "owner": optional(c.owner),
		"internalIp": optional(c.internalIP), "cloudState": c.cloudState, "eligibility": c.eligibility,
		"installed": c.installed, "source": c.source, "selected": c.selected, "tunnel": nullable(c.tunnel),
		"readAt": c.readAt, "updatedAt": nullableTime(c.updatedAt)}
}

type region struct {
	regionID string
	name     string
	configs  []config
}

type inventory struct {
	accountID          string
	scope              string
	freshness          string
	profileObservation string
	profilesObservedAt *time.Time
	regionID           string
	regions            []region
	// isLong changes human output only
	isLong bool
}

func sanitizedText(value *string) *string {
	if value == nil {
		return nil
	}
	return ptr(sanitize(*value))
}

func newInventory(s ipc.State, accountID, regionID string, isStale, eligibleOnly, isLong bool) inventory {
	inv := inventory{accountID: accountID, scope: "authorized", freshness: "current",
		profileObservation: string(s.Tunnel.Observation), profilesObservedAt: s.Tunnel.ObservedAt, regionID: regionID, isLong: isLong}
	if s.Access == ipc.AccessOffline {
		inv.scope = "installed"
	}
	if isStale {
		inv.freshness = "stale"
	} else if s.Inventory == ipc.InventoryCached {
		inv.freshness = "cached"
	}
	for _, clients := range orderedRegions(s, accountID) {
		first := clients[0]
		if regionID != "" && first.RegionID != regionID {
			continue
		}
		var configs []config
		for i, client := range clients {
			if eligibleOnly && client.Eligibility != "eligible" {
				continue
			}
			c := config{configID: client.Identifier, clientID: client.ClientID, index: i + 1,
				connectionURL: sanitizedText(client.ConnectionURL), name: sanitize(client.ClientName),
				owner: sanitizedText(client.OwnerLabel), internalIP: sanitizedText(client.InternalIP),
				cloudState: client.CloudState, eligibility: client.Eligibility, installed: client.Installed,
				source: "cache", selected: s.SelectedIdentifier != nil && client.Identifier == *s.SelectedIdentifier,
				readAt: client.ReadAt, updatedAt: client.UpdatedAt}
			if client.Source == "cloud" {
				c.source = "cloud"
			}
			if s.Tunnel.Observation != ipc.ObservationUnavailable {
				c.tunnel = string(client.Status)
			}
			configs = append(configs, c)
		}
		if len(configs) > 0 {
			inv.regions = append(inv.regions, region{regionID: first.RegionID, name: sanitize(first.RegionName), configs: configs})
		}
	}
	return inv
}

func (inv inventory) json() any {
	regions := []jsonout.Object{}
	for _, r := range inv.regions {
		configs := []any{}
		for _, c := range r.configs {
			configs = append(configs, c.json())
		}
		regions = append(regions, jsonout.Object{"regionId": r.regionID, "name": r.name, "configs": configs})
	}
	return jsonout.Object{"accountId": inv.accountID, "scope": inv.scope, "freshness": inv.freshness,
		"profileObservation": inv.profileObservation, "profilesObservedAt": nullableTime(inv.profilesObservedAt),
		"regionId": nullable(inv.regionID), "regions": regions}
}

type creation struct{ regionID, name string }

type mutation struct {
	command       string
	operation     operation
	tunnel        tunnel
	choices       *inventory
	update        *update
	creation      *creation
	requestedMode ipc.Mode
	mode          *modeStatus
}

func (m mutation) json() any {
	object := jsonout.Object{"command": m.command, "operation": m.operation.json(), "tunnel": m.tunnel.json(), "choices": nil}
	if m.choices != nil {
		object["choices"] = m.choices.json()
	}
	if m.update != nil {
		object["update"] = m.update.json()
	}
	if m.creation != nil {
		object["creation"] = jsonout.Object{"regionId": m.creation.regionID, "name": m.creation.name}
	}
	if m.requestedMode != "" {
		object["requestedMode"] = string(m.requestedMode)
	}
	if m.mode != nil {
		object["mode"] = m.mode.json()
	}
	return object
}

type refreshData struct {
	result    ipc.RefreshResult
	inventory *inventory
}

func (r refreshData) json() any {
	var inv any
	if r.inventory != nil {
		inv = r.inventory.json()
	}
	return jsonout.Object{"result": string(r.result), "inventory": inv}
}

type doctorCheck struct {
	name        string
	status      ipc.DoctorStatus
	evidence    string
	suggestion  *string
	failureCode string
}

// newCheck sanitizes daemon text and keeps only a known public failure code
func newCheck(name string, status ipc.DoctorStatus, evidence string, suggestion *string, failureCode string) doctorCheck {
	check := doctorCheck{name: sanitize(name), status: status, evidence: sanitize(evidence), suggestion: sanitizedText(suggestion)}
	if _, ok := codes[code(failureCode)]; ok {
		check.failureCode = failureCode
	}
	return check
}

type doctorReport struct {
	checks   []doctorCheck
	timedOut bool
}

func (d doctorReport) json() any {
	checks := []jsonout.Object{}
	for _, c := range d.checks {
		object := jsonout.Object{"name": c.name, "status": string(c.status), "evidence": c.evidence,
			"suggestion": optional(c.suggestion)}
		if c.failureCode != "" {
			object["failureCode"] = c.failureCode
		}
		checks = append(checks, object)
	}
	return jsonout.Object{"checks": checks, "timedOut": d.timedOut}
}

// orderedRegions groups this account's clients by region, sorted by display order, name, then ID,
// and sorts clients by owner, name, then compound identifier
func orderedRegions(s ipc.State, accountID string) [][]ipc.Client {
	groups := map[string][]ipc.Client{}
	for _, client := range s.Clients {
		if strings.HasPrefix(client.Identifier, accountID+"/") {
			groups[client.RegionID] = append(groups[client.RegionID], client)
		}
	}
	result := slices.Collect(maps.Values(groups))
	for _, clients := range result {
		slices.SortFunc(clients, func(a, b ipc.Client) int {
			return cmp.Or(cmp.Compare(optionalRaw(a.OwnerLabel), optionalRaw(b.OwnerLabel)),
				cmp.Compare(a.ClientName, b.ClientName), cmp.Compare(a.Identifier, b.Identifier))
		})
	}
	slices.SortFunc(result, func(a, b []ipc.Client) int {
		return cmp.Or(cmp.Compare(a[0].RegionOrder, b[0].RegionOrder), cmp.Compare(a[0].RegionName, b[0].RegionName),
			cmp.Compare(a[0].RegionID, b[0].RegionID))
	})
	return result
}

func optionalRaw(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
