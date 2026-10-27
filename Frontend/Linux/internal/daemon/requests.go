package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

const (
	maxReceipts         = 64
	receiptLifetime     = 600 * time.Second
	resultLifetime      = 600 * time.Second
	reservationLifetime = 30 * time.Second
)

// SessionToken binds account work to one signed-in session. The zero value is signed out
type SessionToken struct {
	AccountID  string
	Generation uint64
}

// Reservation is an admitted request, pending until confirmed and running after
type Reservation struct {
	Request  ipc.Request
	Session  SessionToken
	Deadline time.Time
}

type receipt struct {
	Digest  string    `json:"digest"`
	Expires time.Time `json:"expires"`
}

type receiptFile struct {
	Receipts map[string]receipt `json:"receipts"`
}

type record struct {
	operation ipc.Operation
	digest    string
	stop      bool
	bound     bool
	outcome   *ipc.Outcome
	owner     SessionToken
	expires   time.Time
}

func (r *record) live(now time.Time) bool {
	return r.operation.State == ipc.OperationAccepted || r.operation.State == ipc.OperationRunning || r.expires.After(now)
}

// Registry ports CloudGatewayMacControllerRequests and the orchestrator's
// reservation slots. Non-stop requests leave a durable receipt before they are
// accepted, so a replay after restart reports unknown instead of running twice.
// Results stay in memory. Creation and ordinary commands have separate slots
type Registry struct {
	mu       sync.Mutex
	now      func() time.Time
	persist  func([]byte) error
	receipts map[string]receipt
	creation *record
	command  *record
	latestID string

	pendingCreation *Reservation
	pendingCommand  *Reservation
	runningCreation *Reservation
	runningCommand  *Reservation
}

// NewRegistry restores receipts saved by persist. data is nil on first start
func NewRegistry(data []byte, now func() time.Time, persist func([]byte) error) (*Registry, error) {
	r := &Registry{now: now, persist: persist, receipts: map[string]receipt{}}
	if data == nil {
		return r, nil
	}
	var stored receiptFile
	if err := json.Unmarshal(data, &stored); err != nil {
		return nil, err
	}
	if len(stored.Receipts) > maxReceipts {
		return nil, errors.New("too many operation receipts")
	}
	current := now()
	for id, receipt := range stored.Receipts {
		if receipt.Expires.After(current) {
			r.receipts[id] = receipt
		}
	}
	return r, nil
}

func isStop(action ipc.Action) bool {
	return action == ipc.ActionTurnOff || action == ipc.ActionDisconnectClient
}

func digest(request ipc.Request) string {
	content := []string{string(request.Action), request.Identifier, request.RegionID, request.ClientName, request.ContextID}
	if request.Mode != "" {
		content = append(content, string(request.Mode))
	}
	data, _ := json.Marshal(content)
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// begin locks the registry and expires unconfirmed reservations
func (r *Registry) begin() time.Time {
	r.mu.Lock()
	now := r.now()
	for _, pending := range []*Reservation{r.pendingCreation, r.pendingCommand} {
		if pending != nil && !pending.Deadline.After(now) {
			r.finish(pending.Request.ID, ipc.OperationUnknown, "", "", &ipc.Outcome{Kind: ipc.OutcomeExpired}, pending.Session, now)
			r.clear(pending.Request.ID)
		}
	}
	return now
}

func (r *Registry) record(id string, now time.Time) *record {
	for _, record := range []*record{r.creation, r.command} {
		if record != nil && record.operation.ID == id && record.live(now) {
			return record
		}
	}
	return nil
}

func (r *Registry) operation(id string, now time.Time) ipc.Operation {
	if record := r.record(id, now); record != nil {
		return record.operation
	}
	return ipc.Operation{ID: id, State: ipc.OperationUnknown}
}

// lookup returns the operation a replayed request already owns, or nil when
// the request is new. A failed or unknown stop may run again
func (r *Registry) lookup(request ipc.Request, now time.Time) (*ipc.Operation, ipc.ControllerFailure) {
	digest := digest(request)
	if record := r.record(request.ID, now); record != nil {
		if record.digest != digest {
			return nil, ipc.FailureInvalidRequest
		}
		if record.stop && (record.operation.State == ipc.OperationFailed || record.operation.State == ipc.OperationUnknown) {
			return nil, ""
		}
		operation := record.operation
		return &operation, ""
	}
	receipt, ok := r.receipts[request.ID]
	if !ok || !receipt.Expires.After(now) {
		return nil, ""
	}
	if receipt.Digest != digest {
		return nil, ipc.FailureInvalidRequest
	}
	operation := r.operation(request.ID, now)
	return &operation, ""
}

// Operation reports id's state. Unknown covers expired, replaced, and pre-restart work
func (r *Registry) Operation(id string) ipc.Operation {
	now := r.begin()
	defer r.mu.Unlock()
	return r.operation(id, now)
}

// Outcome hides account-bound outcomes from every session but the owner
func (r *Registry) Outcome(id string, session SessionToken) *ipc.Outcome {
	now := r.begin()
	defer r.mu.Unlock()
	record := r.record(id, now)
	if record == nil || record.outcome == nil || record.bound && record.owner != session {
		return nil
	}
	outcome := *record.outcome
	return &outcome
}

// Latest is the most recently accepted live operation, or another live one
func (r *Registry) Latest() *ipc.Operation {
	now := r.begin()
	defer r.mu.Unlock()
	var first *ipc.Operation
	for _, record := range []*record{r.creation, r.command} {
		if record == nil || !record.live(now) {
			continue
		}
		operation := record.operation
		if operation.ID == r.latestID {
			return &operation
		}
		if first == nil {
			first = &operation
		}
	}
	return first
}

// Busy reports whether each slot has a pending or running operation
func (r *Registry) Busy() (command, creation bool) {
	r.begin()
	defer r.mu.Unlock()
	return r.pendingCommand != nil || r.runningCommand != nil, r.pendingCreation != nil || r.runningCreation != nil
}

// Reserve admits a confirmable request for session, or returns the operation
// a replay of it already owns. One ordinary command may be pending or running
// at a time. Creation has its own slot and waits for any non-stop command,
// while stops may run during a creation. check runs after the slot rules,
// before the receipt is written, with the registry locked. It must not call
// the registry
func (r *Registry) Reserve(request ipc.Request, session SessionToken, check func() ipc.ControllerFailure) (ipc.Operation, ipc.ControllerFailure) {
	now := r.begin()
	defer r.mu.Unlock()
	if existing, failure := r.lookup(request, now); failure != "" || existing != nil {
		if failure != "" {
			return ipc.Operation{}, failure
		}
		return *existing, ""
	}
	stopOrIdle := func(reservation *Reservation) bool {
		return reservation == nil || isStop(reservation.Request.Action)
	}
	if request.Action == ipc.ActionCreateClient {
		if r.pendingCreation != nil || r.runningCreation != nil || !stopOrIdle(r.pendingCommand) || !stopOrIdle(r.runningCommand) {
			return ipc.Operation{}, ipc.FailureBusy
		}
	} else if r.pendingCommand != nil || r.runningCommand != nil ||
		!isStop(request.Action) && (r.pendingCreation != nil || r.runningCreation != nil) {
		return ipc.Operation{}, ipc.FailureBusy
	}
	if check != nil {
		if failure := check(); failure != "" {
			return ipc.Operation{}, failure
		}
	}
	operation, failure := r.accept(request, now)
	if failure != "" {
		return ipc.Operation{}, failure
	}
	reservation := &Reservation{Request: request, Session: session, Deadline: now.Add(reservationLifetime)}
	if request.Action == ipc.ActionCreateClient {
		r.pendingCreation = reservation
	} else {
		r.pendingCommand = reservation
	}
	return operation, ""
}

func (r *Registry) accept(request ipc.Request, now time.Time) (ipc.Operation, ipc.ControllerFailure) {
	digest := digest(request)
	expires := now.Add(receiptLifetime)
	stop := isStop(request.Action)
	// Stops stay available when receipts are full or unwritable
	if !stop {
		next := map[string]receipt{}
		for id, receipt := range r.receipts {
			if receipt.Expires.After(now) {
				next[id] = receipt
			}
		}
		if len(next) >= maxReceipts {
			return ipc.Operation{}, ipc.FailureUnavailable
		}
		next[request.ID] = receipt{Digest: digest, Expires: expires}
		data, err := json.Marshal(receiptFile{Receipts: next})
		if err != nil || r.persist(data) != nil {
			return ipc.Operation{}, ipc.FailureUnavailable
		}
		r.receipts = next
	}
	record := &record{
		operation: ipc.Operation{ID: request.ID, State: ipc.OperationAccepted},
		digest:    digest, stop: stop, bound: request.Action.AccountBound(), expires: expires,
	}
	if request.Action == ipc.ActionCreateClient {
		r.creation = record
	} else {
		r.command = record
	}
	r.latestID = request.ID
	return record.operation, ""
}

// Pending returns id's unconfirmed reservation
func (r *Registry) Pending(id string) (Reservation, bool) {
	r.begin()
	defer r.mu.Unlock()
	for _, pending := range []*Reservation{r.pendingCreation, r.pendingCommand} {
		if pending != nil && pending.Request.ID == id {
			return *pending, true
		}
	}
	return Reservation{}, false
}

// Confirm moves id's reservation to running and returns it. False means it
// was never reserved, already confirmed, or expired
func (r *Registry) Confirm(id string) (Reservation, bool) {
	return r.ConfirmChecked(id, nil)
}

// ConfirmChecked runs check on id's pending reservation and confirms it in one
// step, so a duplicate confirmation never sees a reservation another one
// already started. A failure from check ends the reservation as failed with
// outcome. check runs with the registry locked and must not call the registry
func (r *Registry) ConfirmChecked(id string, check func(Reservation) (ipc.ControllerFailure, *ipc.Outcome)) (Reservation, bool) {
	now := r.begin()
	defer r.mu.Unlock()
	slot, running := &r.pendingCommand, &r.runningCommand
	if r.pendingCreation != nil && r.pendingCreation.Request.ID == id {
		slot, running = &r.pendingCreation, &r.runningCreation
	}
	reservation := *slot
	if reservation == nil || reservation.Request.ID != id {
		return Reservation{}, false
	}
	if check != nil {
		if failure, outcome := check(*reservation); failure != "" {
			*slot = nil
			r.finish(id, ipc.OperationFailed, failure, "", outcome, reservation.Session, now)
			return Reservation{}, false
		}
	}
	*slot, *running = nil, reservation
	r.finish(id, ipc.OperationRunning, "", "", nil, SessionToken{}, now)
	return *reservation, true
}

// Fail ends a pending reservation that the controller refused to confirm.
// Running operations are untouched
func (r *Registry) Fail(id string, failure ipc.ControllerFailure, outcome *ipc.Outcome) ipc.Operation {
	now := r.begin()
	defer r.mu.Unlock()
	for _, slot := range []**Reservation{&r.pendingCreation, &r.pendingCommand} {
		if reservation := *slot; reservation != nil && reservation.Request.ID == id {
			*slot = nil
			return r.finish(id, ipc.OperationFailed, failure, "", outcome, reservation.Session, now)
		}
	}
	return r.operation(id, now)
}

// Reject ends a running operation whose effects refused to start without
// reporting an outcome. It fails as rejected
func (r *Registry) Reject(id string) ipc.Operation {
	now := r.begin()
	defer r.mu.Unlock()
	for _, slot := range []**Reservation{&r.runningCreation, &r.runningCommand} {
		if reservation := *slot; reservation != nil && reservation.Request.ID == id {
			*slot = nil
			return r.finish(id, ipc.OperationFailed, ipc.FailureRejected, "", nil, reservation.Session, now)
		}
	}
	return r.operation(id, now)
}

// Finish records a running operation's outcome. A failed outcome maps to busy,
// rejected when effects refused the work, authCleanupFailed for signOut, and
// commandFailed otherwise. A stop that timed out, unknown, and expired
// outcomes leave the operation unknown
func (r *Registry) Finish(id string, outcome ipc.Outcome, rejected bool, warning ipc.Warning) ipc.Operation {
	now := r.begin()
	defer r.mu.Unlock()
	var reservation *Reservation
	for _, running := range []*Reservation{r.runningCreation, r.runningCommand} {
		if running != nil && running.Request.ID == id {
			reservation = running
		}
	}
	if reservation == nil {
		return r.operation(id, now)
	}
	state := outcomeState(outcome)
	var failure ipc.ControllerFailure
	if state == ipc.OperationFailed {
		switch {
		case outcome.Failure == ipc.CommandBusy:
			failure = ipc.FailureBusy
		case rejected:
			failure = ipc.FailureRejected
		case reservation.Request.Action == ipc.ActionSignOut:
			failure = ipc.FailureAuthCleanupFailed
		default:
			failure = ipc.FailureCommandFailed
		}
	}
	r.clear(id)
	return r.finish(id, state, failure, warning, &outcome, reservation.Session, now)
}

func outcomeState(outcome ipc.Outcome) ipc.OperationState {
	switch outcome.Kind {
	case ipc.OutcomeStartRequested, ipc.OutcomeAlreadyActive, ipc.OutcomeCompleted:
		return ipc.OperationCompleted
	case ipc.OutcomeFailed:
		// An unconfirmed stop may still finish, so it stays uncertain
		if outcome.Failure == ipc.CommandStopTimedOut {
			return ipc.OperationUnknown
		}
		return ipc.OperationFailed
	}
	return ipc.OperationUnknown
}

func (r *Registry) finish(id string, state ipc.OperationState, failure ipc.ControllerFailure, warning ipc.Warning,
	outcome *ipc.Outcome, session SessionToken, now time.Time) ipc.Operation {
	record := r.record(id, now)
	if record == nil {
		return ipc.Operation{ID: id, State: ipc.OperationUnknown}
	}
	record.operation = ipc.Operation{ID: id, State: state, Failure: failure, Warning: warning}
	record.outcome = outcome
	record.owner = session
	if state != ipc.OperationAccepted && state != ipc.OperationRunning {
		record.expires = now.Add(resultLifetime)
	}
	return record.operation
}

func (r *Registry) clear(id string) {
	for _, slot := range []**Reservation{&r.pendingCreation, &r.pendingCommand, &r.runningCreation, &r.runningCommand} {
		if *slot != nil && (*slot).Request.ID == id {
			*slot = nil
		}
	}
}
