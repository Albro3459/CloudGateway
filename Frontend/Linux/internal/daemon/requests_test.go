package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

type receiptStore struct {
	now    time.Time
	data   []byte
	fail   bool
	writes int
}

func newReceiptStore() *receiptStore {
	return &receiptStore{now: time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)}
}

func (s *receiptStore) make(t *testing.T) *Registry {
	t.Helper()
	registry, err := NewRegistry(s.data, func() time.Time { return s.now }, func(data []byte) error {
		s.writes++
		if s.fail {
			return errors.New("write failed")
		}
		s.data = data
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return registry
}

var nextID int

func newID() string {
	nextID++
	return fmt.Sprintf("00000000-0000-4000-8000-%012d", nextID)
}

func request(action ipc.Action) ipc.Request {
	return ipc.Request{Version: ipc.Version, ID: newID(), Action: action}
}

func connect(identifier string) ipc.Request {
	r := request(ipc.ActionConnect)
	r.Identifier = identifier
	return r
}

func creation() ipc.Request {
	r := request(ipc.ActionCreateClient)
	r.RegionID, r.ClientName, r.ContextID = "region", "Mac", newID()
	return r
}

var (
	alice = SessionToken{AccountID: "account", Generation: 1}
	bob   = SessionToken{AccountID: "other", Generation: 2}
)

func reserve(t *testing.T, r *Registry, request ipc.Request) ipc.Operation {
	t.Helper()
	operation, failure := r.Reserve(request, alice, nil)
	if failure != "" {
		t.Fatalf("reserve %s: %s", request.Action, failure)
	}
	return operation
}

func confirm(t *testing.T, r *Registry, id string) {
	t.Helper()
	if _, ok := r.Confirm(id); !ok {
		t.Fatalf("confirm %s failed", id)
	}
}

func complete(t *testing.T, r *Registry, request ipc.Request) {
	t.Helper()
	reserve(t, r, request)
	confirm(t, r, request.ID)
	r.Finish(request.ID, ipc.Outcome{Kind: ipc.OutcomeCompleted}, false, "")
}

// lookup and acceptRaw reach the receipt layer below the slot rules, like the macOS request tests
func lookup(r *Registry, request ipc.Request) (*ipc.Operation, ipc.ControllerFailure) {
	now := r.begin()
	defer r.mu.Unlock()
	return r.lookup(request, now)
}

func acceptRaw(r *Registry, request ipc.Request) ipc.ControllerFailure {
	now := r.begin()
	defer r.mu.Unlock()
	_, failure := r.accept(request, now)
	return failure
}

func state(operation *ipc.Operation) ipc.OperationState {
	if operation == nil {
		return "nil"
	}
	return operation.State
}

func TestRegistryStopSurvivesFullDurableReceiptsAndWriteFailure(t *testing.T) {
	store := newReceiptStore()
	r := store.make(t)
	for range maxReceipts {
		complete(t, r, request(ipc.ActionSignOut))
	}
	durable, writes := string(store.data), store.writes
	store.fail = true
	stop := request(ipc.ActionTurnOff)
	if operation := reserve(t, r, stop); operation.State != ipc.OperationAccepted {
		t.Fatalf("stop = %+v", operation)
	}
	if operation, _ := lookup(r, stop); state(operation) != ipc.OperationAccepted {
		t.Fatalf("lookup = %v", state(operation))
	}
	confirm(t, r, stop.ID)
	if operation := r.Operation(stop.ID); operation.State != ipc.OperationRunning {
		t.Fatalf("running = %+v", operation)
	}
	if operation := r.Finish(stop.ID, ipc.Outcome{Kind: ipc.OutcomeCompleted}, false, ""); operation.State != ipc.OperationCompleted {
		t.Fatalf("finished = %+v", operation)
	}
	if latest := r.Latest(); latest == nil || latest.ID != stop.ID {
		t.Fatalf("latest = %+v", latest)
	}
	if store.writes != writes || string(store.data) != durable {
		t.Fatal("stop wrote receipts")
	}
	if _, failure := r.Reserve(request(ipc.ActionSignOut), alice, nil); failure != ipc.FailureUnavailable {
		t.Fatalf("failure = %q", failure)
	}
}

func TestRegistryFailedAdmissionDoesNotConsumeFinalDurableSlot(t *testing.T) {
	store := newReceiptStore()
	r := store.make(t)
	for range maxReceipts - 1 {
		signOut := request(ipc.ActionSignOut)
		reserve(t, r, signOut)
		r.Fail(signOut.ID, ipc.FailureRejected, nil)
	}
	previous := r.Latest()
	durable := string(store.data)
	command := connect("account/region/client")
	store.fail = true
	if _, failure := r.Reserve(command, alice, nil); failure != ipc.FailureUnavailable {
		t.Fatalf("failure = %q", failure)
	}
	if operation, _ := lookup(r, command); operation != nil {
		t.Fatalf("lookup = %+v", operation)
	}
	if latest := r.Latest(); *latest != *previous {
		t.Fatalf("latest = %+v", latest)
	}
	if command, _ := r.Busy(); command {
		t.Fatal("failed admission holds the command slot")
	}
	if string(store.data) != durable {
		t.Fatal("receipts changed")
	}
	store.fail = false
	reserve(t, r, command)
	if operation := reserve(t, r, command); operation != (ipc.Operation{ID: command.ID, State: ipc.OperationAccepted}) {
		t.Fatalf("replay = %+v", operation)
	}
	r.Fail(command.ID, ipc.FailureRejected, nil)
	if _, failure := r.Reserve(request(ipc.ActionSignOut), alice, nil); failure != ipc.FailureUnavailable {
		t.Fatalf("failure = %q", failure)
	}
}

func TestRegistryRestartMarksUnfinishedWorkUnknownWithoutRedispatch(t *testing.T) {
	for _, running := range []bool{false, true} {
		store := newReceiptStore()
		r := store.make(t)
		command := connect("account/region/client")
		reserve(t, r, command)
		if running {
			confirm(t, r, command.ID)
		}
		restored := store.make(t)
		operation, failure := restored.Reserve(command, alice, nil)
		if failure != "" || operation != (ipc.Operation{ID: command.ID, State: ipc.OperationUnknown}) {
			t.Fatalf("replay = %+v, %q", operation, failure)
		}
		if _, ok := restored.Pending(command.ID); ok {
			t.Fatal("replay after restart created a reservation")
		}
		if _, ok := restored.Confirm(command.ID); ok {
			t.Fatal("replay after restart confirmed")
		}
		if restored.Operation(command.ID).State != ipc.OperationUnknown || restored.Latest() != nil {
			t.Fatal("restored registry kept a result")
		}
	}
}

func TestRegistryKnownOutcomeSurvivesWriteFailureUntilReceiptExpires(t *testing.T) {
	store := newReceiptStore()
	r := store.make(t)
	command := connect("account/region/client")
	reserve(t, r, command)
	confirm(t, r, command.ID)
	store.fail = true
	writes := store.writes
	if operation := r.Finish(command.ID, ipc.Outcome{Kind: ipc.OutcomeCompleted}, false, ""); operation.State != ipc.OperationCompleted {
		t.Fatalf("finish = %+v", operation)
	}
	if operation, _ := lookup(r, command); state(operation) != ipc.OperationCompleted {
		t.Fatalf("lookup = %v", state(operation))
	}
	if store.writes != writes {
		t.Fatal("finish wrote receipts")
	}
	restored := store.make(t)
	if operation, _ := lookup(restored, command); state(operation) != ipc.OperationUnknown {
		t.Fatalf("restored = %v", state(operation))
	}
	store.now = store.now.Add(600 * time.Second)
	if operation, _ := lookup(restored, command); operation != nil {
		t.Fatalf("expired receipt = %+v", operation)
	}
	if restored.Operation(command.ID).State != ipc.OperationUnknown {
		t.Fatal("expired operation is known")
	}
}

func TestRegistryRejectsIdentifierReuseWithChangedPayload(t *testing.T) {
	r := newReceiptStore().make(t)
	first := connect("account/region/first")
	reserve(t, r, first)
	second := first
	second.Identifier = "account/region/second"
	if _, failure := r.Reserve(second, alice, nil); failure != ipc.FailureInvalidRequest {
		t.Fatalf("failure = %q", failure)
	}
	stop := ipc.Request{Version: ipc.Version, ID: first.ID, Action: ipc.ActionTurnOff}
	if _, failure := r.Reserve(stop, alice, nil); failure != ipc.FailureInvalidRequest {
		t.Fatalf("failure = %q", failure)
	}
	r.Fail(first.ID, ipc.FailureRejected, nil)
	stop = request(ipc.ActionTurnOff)
	reserve(t, r, stop)
	changed := stop
	changed.Identifier = "account/region/first"
	if _, failure := lookup(r, changed); failure != ipc.FailureInvalidRequest {
		t.Fatalf("failure = %q", failure)
	}
}

func TestRegistryDoesNotPersistResultsOrStopState(t *testing.T) {
	store := newReceiptStore()
	r := store.make(t)
	command := connect("account/region/client")
	complete(t, r, command)
	stop := request(ipc.ActionTurnOff)
	reserve(t, r, stop)
	confirm(t, r, stop.ID)
	if operation := r.Finish(stop.ID, ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandStopTimedOut}, false, ""); operation != (ipc.Operation{ID: stop.ID, State: ipc.OperationUnknown}) {
		t.Fatalf("stop = %+v", operation)
	}
	if operation, _ := lookup(r, stop); operation != nil {
		t.Fatalf("unknown stop lookup = %+v", operation)
	}
	if operation := reserve(t, r, stop); operation.State != ipc.OperationAccepted {
		t.Fatalf("stop retry = %+v", operation)
	}
	text := string(store.data)
	for _, leaked := range []string{"completed", "connect", "account/region/client", stop.ID} {
		if strings.Contains(text, leaked) {
			t.Fatalf("receipts contain %q: %s", leaked, text)
		}
	}
	restored := store.make(t)
	if restored.Latest() != nil || restored.Operation(command.ID).State != ipc.OperationUnknown || restored.Operation(stop.ID).State != ipc.OperationUnknown {
		t.Fatal("restored registry kept a result")
	}
}

func TestRegistryRetainsOnlyLatestResultWithoutLosingAntiReplayReceipts(t *testing.T) {
	r := newReceiptStore().make(t)
	first := connect("account/region/first")
	second := connect("account/region/second")
	complete(t, r, first)
	complete(t, r, second)
	if r.Operation(first.ID).State != ipc.OperationUnknown {
		t.Fatal("replaced result is still known")
	}
	if operation, _ := r.Reserve(first, alice, nil); operation.State != ipc.OperationUnknown {
		t.Fatalf("first replay = %+v", operation)
	}
	if r.Operation(second.ID).State != ipc.OperationCompleted || r.Latest().ID != second.ID {
		t.Fatal("latest result lost")
	}
	if operation := r.Finish(first.ID, ipc.Outcome{Kind: ipc.OutcomeFailed}, false, ""); operation.State != ipc.OperationUnknown {
		t.Fatalf("late finish = %+v", operation)
	}
	if r.Latest().ID != second.ID {
		t.Fatal("late finish changed latest")
	}
}

func TestRegistryKeepsCreationAndStopResultsIndependent(t *testing.T) {
	for _, stopFirst := range []bool{false, true} {
		for _, creationFinishesFirst := range []bool{false, true} {
			store := newReceiptStore()
			r := store.make(t)
			add := creation()
			stop := request(ipc.ActionDisconnectClient)
			stop.Identifier = "account/region/client"
			order := []ipc.Request{add, stop}
			if stopFirst {
				order = []ipc.Request{stop, add}
			}
			for _, request := range order {
				if operation := reserve(t, r, request); operation.State != ipc.OperationAccepted {
					t.Fatalf("reserve = %+v", operation)
				}
				confirm(t, r, request.ID)
			}
			first, second := stop, add
			if creationFinishesFirst {
				first, second = add, stop
			}
			r.Finish(first.ID, ipc.Outcome{Kind: ipc.OutcomeCompleted}, false, "")
			if r.Operation(second.ID).State != ipc.OperationRunning {
				t.Fatal("finishing one slot changed the other")
			}
			store.now = store.now.Add(601 * time.Second)
			if r.Operation(first.ID).State != ipc.OperationUnknown || r.Latest().ID != second.ID {
				t.Fatal("expired result or latest is wrong")
			}
			r.Finish(second.ID, ipc.Outcome{Kind: ipc.OutcomeCompleted}, false, "")
			if operation, _ := r.Reserve(second, alice, nil); operation.State != ipc.OperationCompleted {
				t.Fatalf("replay = %+v", operation)
			}
			if outcome := r.Outcome(second.ID, alice); outcome == nil || *outcome != (ipc.Outcome{Kind: ipc.OutcomeCompleted}) {
				t.Fatalf("owner outcome = %+v", outcome)
			}
			if outcome := r.Outcome(second.ID, bob); outcome != nil {
				t.Fatalf("other session sees %+v", outcome)
			}
			store.now = store.now.Add(600 * time.Second)
			if r.Latest() != nil {
				t.Fatal("results outlived 600 seconds")
			}
		}
	}
}

func TestRegistryRejectsCrossSlotIdentifierCollisions(t *testing.T) {
	for _, stopFirst := range []bool{false, true} {
		r := newReceiptStore().make(t)
		add := creation()
		stop := ipc.Request{Version: ipc.Version, ID: add.ID, Action: ipc.ActionTurnOff}
		first, second := add, stop
		if stopFirst {
			first, second = stop, add
		}
		reserve(t, r, first)
		check := func(want ipc.OperationState) {
			t.Helper()
			if _, failure := lookup(r, second); failure != ipc.FailureInvalidRequest {
				t.Fatalf("lookup failure = %q", failure)
			}
			if _, failure := r.Reserve(second, alice, nil); failure != ipc.FailureInvalidRequest {
				t.Fatalf("reserve failure = %q", failure)
			}
			if r.Operation(first.ID).State != want {
				t.Fatalf("state = %s", r.Operation(first.ID).State)
			}
		}
		check(ipc.OperationAccepted)
		confirm(t, r, first.ID)
		check(ipc.OperationRunning)
		r.Finish(first.ID, ipc.Outcome{Kind: ipc.OutcomeCompleted}, false, "")
		check(ipc.OperationCompleted)
	}
}

func TestRegistryStopDoesNotEraseCreationWhenDurableStorageIsFullOrUnavailable(t *testing.T) {
	store := newReceiptStore()
	r := store.make(t)
	add := creation()
	reserve(t, r, add)
	confirm(t, r, add.ID)
	for range maxReceipts - 1 {
		if failure := acceptRaw(r, request(ipc.ActionSignOut)); failure != "" {
			t.Fatal(failure)
		}
	}
	store.fail = true
	stop := request(ipc.ActionTurnOff)
	reserve(t, r, stop)
	confirm(t, r, stop.ID)
	r.Finish(stop.ID, ipc.Outcome{Kind: ipc.OutcomeCompleted}, false, "")
	if operation, _ := lookup(r, add); state(operation) != ipc.OperationRunning {
		t.Fatalf("creation = %v", state(operation))
	}
	if r.Operation(stop.ID).State != ipc.OperationCompleted {
		t.Fatal("stop result lost")
	}
	restored := store.make(t)
	if operation, _ := lookup(restored, add); state(operation) != ipc.OperationUnknown {
		t.Fatalf("restored creation = %v", state(operation))
	}
	if operation, _ := lookup(restored, stop); operation != nil {
		t.Fatalf("restored stop = %+v", operation)
	}
}

func TestRegistryDeduplicatesModesInMemoryAndAfterRestart(t *testing.T) {
	store := newReceiptStore()
	r := store.make(t)
	mesh := request(ipc.ActionSetMode)
	mesh.Mode = ipc.ModeMesh
	full := mesh
	full.Mode = ipc.ModeFull
	reserve(t, r, mesh)
	if operation := reserve(t, r, mesh); operation.State != ipc.OperationAccepted {
		t.Fatalf("replay = %+v", operation)
	}
	if _, failure := r.Reserve(full, alice, nil); failure != ipc.FailureInvalidRequest {
		t.Fatalf("failure = %q", failure)
	}
	confirm(t, r, mesh.ID)
	if operation := reserve(t, r, mesh); operation.State != ipc.OperationRunning {
		t.Fatalf("running replay = %+v", operation)
	}
	if store.writes != 1 {
		t.Fatalf("writes = %d", store.writes)
	}
	restored := store.make(t)
	if operation := reserve(t, restored, mesh); operation.State != ipc.OperationUnknown {
		t.Fatalf("restored replay = %+v", operation)
	}
	if _, failure := restored.Reserve(full, alice, nil); failure != ipc.FailureInvalidRequest {
		t.Fatalf("failure = %q", failure)
	}
	for _, leaked := range []string{"mesh", "setMode"} {
		if strings.Contains(string(store.data), leaked) {
			t.Fatalf("receipts contain %q", leaked)
		}
	}
}

func TestRegistryUnconfirmedReservationExpiresAfter30Seconds(t *testing.T) {
	store := newReceiptStore()
	r := store.make(t)
	command := connect("account/region/client")
	reserve(t, r, command)
	store.now = store.now.Add(30*time.Second - time.Millisecond)
	if _, ok := r.Pending(command.ID); !ok {
		t.Fatal("reservation expired early")
	}
	store.now = store.now.Add(time.Millisecond)
	if _, ok := r.Confirm(command.ID); ok {
		t.Fatal("confirmed an expired reservation")
	}
	if operation := r.Operation(command.ID); operation != (ipc.Operation{ID: command.ID, State: ipc.OperationUnknown}) {
		t.Fatalf("operation = %+v", operation)
	}
	if outcome := r.Outcome(command.ID, alice); outcome == nil || outcome.Kind != ipc.OutcomeExpired {
		t.Fatalf("outcome = %+v", outcome)
	}
	if busy, _ := r.Busy(); busy {
		t.Fatal("expired reservation holds the slot")
	}
	if operation, _ := r.Reserve(command, alice, nil); operation.State != ipc.OperationUnknown {
		t.Fatalf("replay = %+v", operation)
	}
}

func TestRegistrySlotRules(t *testing.T) {
	expect := func(t *testing.T, r *Registry, request ipc.Request, want ipc.ControllerFailure) {
		t.Helper()
		if _, failure := r.Reserve(request, alice, nil); failure != want {
			t.Fatalf("%s: failure = %q, want %q", request.Action, failure, want)
		}
	}
	t.Run("pending command blocks commands, stops, and creation", func(t *testing.T) {
		r := newReceiptStore().make(t)
		command := connect("")
		reserve(t, r, command)
		expect(t, r, request(ipc.ActionSetMode), ipc.FailureBusy)
		expect(t, r, request(ipc.ActionTurnOff), ipc.FailureBusy)
		expect(t, r, creation(), ipc.FailureBusy)
		confirm(t, r, command.ID)
		expect(t, r, request(ipc.ActionTurnOff), ipc.FailureBusy)
		expect(t, r, creation(), ipc.FailureBusy)
		r.Finish(command.ID, ipc.Outcome{Kind: ipc.OutcomeStartRequested, Identifier: "account/region/client"}, false, "")
		if command, creation := r.Busy(); command || creation {
			t.Fatal("slots still busy")
		}
		expect(t, r, creation(), "")
	})
	t.Run("creation admits only stops", func(t *testing.T) {
		r := newReceiptStore().make(t)
		add := creation()
		reserve(t, r, add)
		expect(t, r, connect(""), ipc.FailureBusy)
		expect(t, r, creation(), ipc.FailureBusy)
		confirm(t, r, add.ID)
		expect(t, r, request(ipc.ActionSignOut), ipc.FailureBusy)
		stop := request(ipc.ActionTurnOff)
		expect(t, r, stop, "")
		if command, creation := r.Busy(); !command || !creation {
			t.Fatal("both slots should be busy")
		}
	})
	t.Run("pending or running stop admits creation", func(t *testing.T) {
		r := newReceiptStore().make(t)
		stop := request(ipc.ActionDisconnectClient)
		stop.Identifier = "account/region/client"
		reserve(t, r, stop)
		add := creation()
		expect(t, r, add, "")
		r.Fail(add.ID, ipc.FailurePreparationExpired, nil)
		confirm(t, r, stop.ID)
		expect(t, r, creation(), "")
	})
	t.Run("check runs after slot rules and before the receipt", func(t *testing.T) {
		store := newReceiptStore()
		r := store.make(t)
		calls := 0
		refuse := func() ipc.ControllerFailure { calls++; return ipc.FailureRejected }
		if _, failure := r.Reserve(request(ipc.ActionRemoveClient), alice, refuse); failure != ipc.FailureRejected {
			t.Fatalf("failure = %q", failure)
		}
		if store.writes != 0 || calls != 1 {
			t.Fatalf("writes = %d, calls = %d", store.writes, calls)
		}
		reserve(t, r, connect(""))
		if _, failure := r.Reserve(request(ipc.ActionSetMode), alice, refuse); failure != ipc.FailureBusy || calls != 1 {
			t.Fatalf("failure = %q, calls = %d", failure, calls)
		}
	})
}

func TestRegistryFailAtConfirmationKeepsOutcomeWithOwner(t *testing.T) {
	r := newReceiptStore().make(t)
	setMode := request(ipc.ActionSetMode)
	setMode.Mode = ipc.ModeMesh
	reserve(t, r, setMode)
	outcome := ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandSignInRequired}
	if operation := r.Fail(setMode.ID, ipc.FailureRejected, &outcome); operation != (ipc.Operation{ID: setMode.ID, State: ipc.OperationFailed, Failure: ipc.FailureRejected}) {
		t.Fatalf("operation = %+v", operation)
	}
	if got := r.Outcome(setMode.ID, alice); got == nil || *got != outcome {
		t.Fatalf("owner outcome = %+v", got)
	}
	if r.Outcome(setMode.ID, bob) != nil || r.Outcome(setMode.ID, SessionToken{AccountID: "account", Generation: 2}) != nil {
		t.Fatal("outcome visible to another session")
	}
	if _, ok := r.Confirm(setMode.ID); ok {
		t.Fatal("confirmed a failed reservation")
	}
	signOut := request(ipc.ActionSignOut)
	reserve(t, r, signOut)
	if got := r.Outcome(signOut.ID, bob); got != nil {
		t.Fatalf("outcome before finish = %+v", got)
	}
	confirm(t, r, signOut.ID)
	r.Finish(signOut.ID, ipc.Outcome{Kind: ipc.OutcomeCompleted}, false, "")
	if got := r.Outcome(signOut.ID, bob); got == nil {
		t.Fatal("non-account outcome hidden from another session")
	}
}

func TestRegistryFinishMapsOutcomes(t *testing.T) {
	for _, test := range []struct {
		action   ipc.Action
		outcome  ipc.Outcome
		rejected bool
		warning  ipc.Warning
		want     ipc.Operation
	}{
		{ipc.ActionConnect, ipc.Outcome{Kind: ipc.OutcomeStartRequested, Identifier: "a/b/c"}, false, "", ipc.Operation{State: ipc.OperationCompleted}},
		{ipc.ActionConnect, ipc.Outcome{Kind: ipc.OutcomeAlreadyActive, Identifier: "a/b/c"}, false, "", ipc.Operation{State: ipc.OperationCompleted}},
		{ipc.ActionTurnOff, ipc.Outcome{Kind: ipc.OutcomeCompleted}, false, ipc.WarningReconnectSuppressionNotPersisted,
			ipc.Operation{State: ipc.OperationCompleted, Warning: ipc.WarningReconnectSuppressionNotPersisted}},
		{ipc.ActionConnect, ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandBusy}, true, "", ipc.Operation{State: ipc.OperationFailed, Failure: ipc.FailureBusy}},
		{ipc.ActionConnect, ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandConfigUnavailable}, true, "", ipc.Operation{State: ipc.OperationFailed, Failure: ipc.FailureRejected}},
		{ipc.ActionSignOut, ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandInternalError}, false, "", ipc.Operation{State: ipc.OperationFailed, Failure: ipc.FailureAuthCleanupFailed}},
		{ipc.ActionConnect, ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandVPNFailed}, false, "", ipc.Operation{State: ipc.OperationFailed, Failure: ipc.FailureCommandFailed}},
		{ipc.ActionTurnOff, ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandStopTimedOut}, false, "", ipc.Operation{State: ipc.OperationUnknown}},
		{ipc.ActionCreateClient, ipc.Outcome{Kind: ipc.OutcomeUnknown}, false, "", ipc.Operation{State: ipc.OperationUnknown}},
		{ipc.ActionConnect, ipc.Outcome{Kind: ipc.OutcomeExpired}, false, "", ipc.Operation{State: ipc.OperationUnknown}},
	} {
		r := newReceiptStore().make(t)
		req := request(test.action)
		if test.action == ipc.ActionCreateClient {
			req = creation()
		}
		reserve(t, r, req)
		confirm(t, r, req.ID)
		test.want.ID = req.ID
		if got := r.Finish(req.ID, test.outcome, test.rejected, test.warning); got != test.want {
			t.Fatalf("%s %+v: got %+v, want %+v", test.action, test.outcome, got, test.want)
		}
		if got := r.Outcome(req.ID, alice); got == nil || *got != test.outcome {
			t.Fatalf("outcome = %+v", got)
		}
		if command, creation := r.Busy(); command || creation {
			t.Fatal("finished operation holds a slot")
		}
	}
}

func TestNewRegistryRestoresOnlyValidUnexpiredReceipts(t *testing.T) {
	now := time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	persist := func([]byte) error { return nil }
	if _, err := NewRegistry([]byte(`{"receipts":`), clock, persist); err == nil {
		t.Fatal("restored corrupt receipts")
	}
	receipts := map[string]receipt{}
	for range maxReceipts + 1 {
		receipts[newID()] = receipt{Digest: "d", Expires: now.Add(time.Minute)}
	}
	data, _ := json.Marshal(receiptFile{Receipts: receipts})
	if _, err := NewRegistry(data, clock, persist); err == nil {
		t.Fatal("restored more than maxReceipts receipts")
	}
	expired, live := newID(), newID()
	data, _ = json.Marshal(receiptFile{Receipts: map[string]receipt{
		expired: {Digest: "d", Expires: now}, live: {Digest: "d", Expires: now.Add(time.Second)},
	}})
	r, err := NewRegistry(data, clock, persist)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.receipts) != 1 || r.receipts[live].Digest != "d" {
		t.Fatalf("receipts = %+v", r.receipts)
	}
}

func TestRegistryConfirmCheckedIsAtomicWithDuplicates(t *testing.T) {
	r := newReceiptStore().make(t)
	command := connect("account/region/client")
	reserve(t, r, command)
	checks := 0
	pass := func(reservation Reservation) (ipc.ControllerFailure, *ipc.Outcome) {
		checks++
		if reservation.Request.ID != command.ID || reservation.Session != alice {
			t.Fatalf("reservation = %+v", reservation)
		}
		return "", nil
	}
	if _, ok := r.ConfirmChecked(command.ID, pass); !ok {
		t.Fatal("first confirmation failed")
	}
	refuse := func(Reservation) (ipc.ControllerFailure, *ipc.Outcome) {
		checks++
		return ipc.FailureRejected, &ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandSignInRequired}
	}
	if _, ok := r.ConfirmChecked(command.ID, refuse); ok {
		t.Fatal("duplicate confirmation started the operation again")
	}
	if checks != 1 {
		t.Fatalf("checks = %d, the duplicate ran its check", checks)
	}
	if operation := r.Operation(command.ID); operation.State != ipc.OperationRunning {
		t.Fatalf("duplicate changed the running operation: %+v", operation)
	}
	if busy, _ := r.Busy(); !busy {
		t.Fatal("duplicate freed the command slot")
	}
	r.Finish(command.ID, ipc.Outcome{Kind: ipc.OutcomeStartRequested, Identifier: "account/region/client"}, false, "")
	if outcome := r.Outcome(command.ID, alice); outcome == nil || outcome.Kind != ipc.OutcomeStartRequested {
		t.Fatalf("outcome = %+v", outcome)
	}
}

func TestRegistryConfirmCheckedFailureEndsOnlyThePendingReservation(t *testing.T) {
	r := newReceiptStore().make(t)
	stop := request(ipc.ActionTurnOff)
	reserve(t, r, stop)
	confirm(t, r, stop.ID)
	add := creation()
	reserve(t, r, add)
	outcome := &ipc.Outcome{Kind: ipc.OutcomeFailed, Failure: ipc.CommandSignInRequired}
	if _, ok := r.ConfirmChecked(add.ID, func(Reservation) (ipc.ControllerFailure, *ipc.Outcome) {
		return ipc.FailurePreparationExpired, outcome
	}); ok {
		t.Fatal("refused confirmation succeeded")
	}
	if operation := r.Operation(add.ID); operation != (ipc.Operation{ID: add.ID, State: ipc.OperationFailed, Failure: ipc.FailurePreparationExpired}) {
		t.Fatalf("creation = %+v", operation)
	}
	if got := r.Outcome(add.ID, alice); got == nil || *got != *outcome {
		t.Fatalf("outcome = %+v", got)
	}
	if command, creation := r.Busy(); !command || creation {
		t.Fatalf("busy = %v, %v", command, creation)
	}
}

func TestRegistryFailLeavesRunningOperationsAndRejectEndsThem(t *testing.T) {
	r := newReceiptStore().make(t)
	command := connect("account/region/client")
	reserve(t, r, command)
	confirm(t, r, command.ID)
	if operation := r.Fail(command.ID, ipc.FailureRejected, nil); operation.State != ipc.OperationRunning {
		t.Fatalf("Fail changed a running operation: %+v", operation)
	}
	if busy, _ := r.Busy(); !busy {
		t.Fatal("Fail freed a running slot")
	}
	if operation := r.Reject(command.ID); operation != (ipc.Operation{ID: command.ID, State: ipc.OperationFailed, Failure: ipc.FailureRejected}) {
		t.Fatalf("reject = %+v", operation)
	}
	if busy, _ := r.Busy(); busy {
		t.Fatal("Reject kept the slot")
	}
	if r.Outcome(command.ID, alice) != nil {
		t.Fatal("Reject recorded an outcome")
	}
	pending := request(ipc.ActionSignOut)
	reserve(t, r, pending)
	if operation := r.Reject(pending.ID); operation.State != ipc.OperationAccepted {
		t.Fatalf("Reject changed a pending reservation: %+v", operation)
	}
}
