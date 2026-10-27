package cli

import (
	"errors"
	"slices"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

func withData(c code, d data) *cliError {
	e := errorCode(c)
	e.data = d
	return e
}

func (s *session) refresh(regionID string, isList, isLong bool) (data, error) {
	if err := s.requireCurrent(); err != nil {
		return nil, err
	}
	for {
		reply, err := s.call(ipc.Request{Action: ipc.ActionAwaitRefresh})
		if err != nil {
			return nil, err
		}
		result := reply.Refresh
		if result == "" {
			return nil, errorCode(codeInvalidResponse)
		}
		if result == ipc.RefreshTimedOut && s.cli.clock.now().Add(pollInterval).Before(s.deadline) {
			if err := s.sleep(); err != nil {
				return nil, err
			}
			continue
		}
		state, err := stateOf(reply)
		if err != nil {
			return nil, err
		}
		canResolveRegion := false
		switch result {
		case ipc.RefreshRefreshed:
			canResolveRegion = true
		case ipc.RefreshDenied, ipc.RefreshSignInRequired:
		default:
			canResolveRegion = state.AccessAuthorized && (state.Access == ipc.AccessOnline || state.Access == ipc.AccessOffline) &&
				!isPendingRestoration(state) && !isAwaitingVerification(state) &&
				(state.Inventory == ipc.InventoryCurrent || state.Inventory == ipc.InventoryCached)
		}
		var inv *inventory
		if state.AccountID != nil && (regionID == "" || canResolveRegion) {
			resolved := regionID
			if regionID != "" {
				if resolved, err = resolveInventoryRegion(regionID, state, *state.AccountID); err != nil {
					return nil, err
				}
			}
			value := newInventory(state, *state.AccountID, resolved, result != ipc.RefreshRefreshed, false, isLong)
			inv = &value
		}
		var d data = refreshData{result: result, inventory: inv}
		if isList && inv != nil {
			d = *inv
		}
		switch result {
		case ipc.RefreshRefreshed:
			if inv == nil {
				return nil, errorCode(codeInvalidResponse)
			}
			return d, nil
		case ipc.RefreshTimedOut:
			return nil, withData(codeTimeout, d)
		case ipc.RefreshUnavailable:
			return nil, withData(codeNetworkUnavailable, d)
		case ipc.RefreshDenied:
			return nil, withData(codeAccessDenied, d)
		case ipc.RefreshSignInRequired:
			return nil, withData(codeSignInRequired, d)
		case ipc.RefreshSkipped:
			return nil, withData(codeRefreshSkipped, d)
		case ipc.RefreshSuperseded:
			return nil, withData(codeRefreshSuperseded, d)
		}
		return nil, errorCode(codeInvalidResponse)
	}
}

func (s *session) add(regionInput, name string, accepted func(string) error) (data, error) {
	if err := s.requireCurrent(); err != nil {
		return nil, err
	}
	state, settled, err := s.pollSettled(func(state ipc.State) bool { return state.Inventory == ipc.InventoryRefreshing })
	if err != nil {
		return nil, err
	}
	if !settled {
		return nil, errorCode(codeTimeout)
	}
	if state.AccountID == nil {
		return nil, accountError(state, "")
	}
	if !state.CreationAllowed {
		return nil, errorCode(codeBusy)
	}
	prepared, err := s.call(ipc.Request{Action: ipc.ActionPrepareClient})
	if isControllerFailure(err, ipc.FailureUnavailable) {
		current, snapshotErr := s.call(ipc.Request{Action: ipc.ActionSnapshot})
		if s.ctx.Err() != nil {
			return nil, errorCode(codeInterrupted)
		}
		if snapshotErr == nil && current.State != nil && current.State.AccountID == nil {
			if current.State.Access == ipc.AccessDenied {
				return nil, errorCode(codeAccessDenied)
			}
			if !current.State.HasRetainedSession || current.State.Access != ipc.AccessUnreachable {
				return nil, errorCode(codeSignInRequired)
			}
		}
		return nil, newError(codeNetworkUnavailable, "Unable to load regions for client creation. Try again", "")
	}
	if err != nil {
		return nil, err
	}
	if prepared.Creation == nil {
		return nil, errorCode(codeInvalidResponse)
	}
	var regions []ipc.CreationRegion
	var rows []regionRow
	for _, r := range prepared.Creation.Regions {
		if r.Enabled {
			regions = append(regions, r)
			rows = append(rows, regionRow{r.RegionID, r.DisplayName})
		}
	}
	regionID, err := resolveRegion(regionInput, rows, "the enabled creation regions")
	if err != nil {
		return nil, err
	}
	index := slices.IndexFunc(regions, func(r ipc.CreationRegion) bool { return r.RegionID == regionID })
	capacity := regions[index].Capacity
	if capacity == nil || !capacity.Known {
		return nil, newError(codeNetworkUnavailable, "Unable to check capacity for "+regionID+". Try again", "")
	}
	if capacity.Allocated >= capacity.Limit {
		return nil, newError(codeConfigUnavailable, "Region "+regionID+" has no available client capacity", "")
	}
	return s.submit(ipc.ActionCreateClient, submission{creation: &creation{regionID: regionID, name: name},
		contextID: prepared.Creation.ID}, accepted)
}

func (s *session) mutate(action ipc.Action, sel *selector, mode ipc.Mode, accepted func(string) error) (data, error) {
	// Bare down works on any compatible daemon and while signed out
	if action == ipc.ActionTurnOff {
		if err := s.handshake(); err != nil {
			return nil, err
		}
	} else if err := s.requireCurrent(); err != nil {
		return nil, err
	}
	var identifier string
	switch action {
	case ipc.ActionConnect, ipc.ActionDisconnectClient, ipc.ActionRemoveClient, ipc.ActionSetMode:
		state, settled, err := s.pollSettled(func(state ipc.State) bool {
			if sel != nil || action == ipc.ActionSetMode {
				return state.Inventory == ipc.InventoryRefreshing
			}
			selected := slices.ContainsFunc(state.Clients, func(c ipc.Client) bool {
				return state.SelectedIdentifier != nil && c.Identifier == *state.SelectedIdentifier
			})
			return state.AccountID != nil && state.Inventory == ipc.InventoryRefreshing && !selected
		})
		if err != nil {
			return nil, err
		}
		if !settled {
			return nil, errorCode(codeTimeout)
		}
		if state.AccountID == nil {
			return nil, accountError(state, "")
		}
		if sel != nil {
			if state.Inventory == ipc.InventoryUnavailable {
				return nil, errorCode(codeNetworkUnavailable)
			}
			if identifier, err = resolveSelector(*sel, state, *state.AccountID); err != nil {
				return nil, err
			}
		}
	}
	return s.submit(action, submission{identifier: identifier, mode: mode}, accepted)
}

type submission struct {
	identifier string
	mode       ipc.Mode
	creation   *creation
	contextID  string
}

const removalRecovery = ". If the result is still unknown, refresh online inventory with cloudgateway refresh, " +
	"then run cloudgateway ls and inspect the original client UUID before another manual removal attempt"

// submit reserves the operation, writes the accepted ID, then confirms and observes it. Nothing is ever resent
func (s *session) submit(action ipc.Action, sub submission, accepted func(string) error) (data, error) {
	id := newUUID()
	isRemove := action == ipc.ActionRemoveClient
	observationFailure := func(err error) error {
		failure := asError(err)
		if failure.operationID != "" && !(isRemove && failure.code == codeOperationUnknown) {
			return failure
		}
		recovery := ""
		if isRemove {
			recovery = removalRecovery
		}
		suggestion := "Check this operation before retrying: cloudgateway status --operation " + id + recovery
		return &cliError{code: failure.code, message: failure.message, suggestion: &suggestion, data: failure.data, operationID: id}
	}
	request := ipc.Request{Action: action, ID: id, Identifier: sub.identifier, Mode: sub.mode, ContextID: sub.contextID}
	if sub.creation != nil {
		request.RegionID, request.ClientName = sub.creation.regionID, sub.creation.name
	}
	reservation, err := s.call(request)
	if err == nil && (reservation.Operation == nil || !sameID(reservation.Operation.ID, id) ||
		reservation.Operation.State != ipc.OperationAccepted) {
		err = errorCode(codeInvalidResponse)
	}
	if err != nil {
		if isRemove {
			return nil, observationFailure(err)
		}
		return nil, err
	}
	// Writes are unbuffered. A failed write leaves the reservation unconfirmed
	if err := accepted(id); err != nil {
		return nil, err
	}
	result, err := s.observe(action, id, sub)
	if err != nil {
		return nil, observationFailure(err)
	}
	return result, nil
}

func (s *session) confirm(id string) (ipc.Reply, error) {
	reply, err := s.call(ipc.Request{Action: ipc.ActionConfirm, ContextID: id})
	return reply, confirmFailure(err)
}

// confirmFailure reports a lost confirmation as uncertain, since it may have started the work.
// The caller's own deadline or interruption stays as is
func confirmFailure(err error) error {
	var public *cliError
	if err != nil && !(errors.As(err, &public) && (public.code == codeTimeout || public.code == codeInterrupted)) {
		return controllerFailure(ipc.FailureOutcomeUnknown)
	}
	return err
}

func (s *session) observe(action ipc.Action, id string, sub submission) (data, error) {
	reply, err := s.confirm(id)
	if err != nil {
		return nil, err
	}
	for {
		if reply.Operation == nil || !sameID(reply.Operation.ID, id) {
			return nil, errorCode(codeInvalidResponse)
		}
		if reply.Operation.State != ipc.OperationAccepted && reply.Operation.State != ipc.OperationRunning {
			break
		}
		if err := s.sleep(); err != nil {
			return nil, err
		}
		if reply, err = s.call(ipc.Request{Action: ipc.ActionOperation, ContextID: id}); err != nil {
			return nil, err
		}
	}
	op := s.operationOf(reply)
	var choices *inventory
	if action != ipc.ActionRemoveClient && op.failure != nil && op.failure.code == codeSelectionUnavailable {
		// Use a new account-filtered snapshot, never the reservation's old account view
		if current, err := s.call(ipc.Request{Action: ipc.ActionSnapshot}); err == nil && current.State != nil && current.State.AccountID != nil {
			value := newInventory(*current.State, *current.State.AccountID, "", false, true, false)
			choices = &value
		}
	}
	m := mutation{command: mutationCommand(action), operation: *op, tunnel: s.tunnelOf(reply), choices: choices,
		update: replyUpdate(reply), creation: sub.creation, requestedMode: sub.mode}
	if action == ipc.ActionSetMode && reply.State != nil {
		mode := newModeStatus(*reply.State)
		m.mode = &mode
	}
	if op.failure != nil {
		failure := copyError(op.failure)
		failure.data, failure.operationID = m, id
		return nil, failure
	}
	if op.state != string(ipc.OperationCompleted) {
		return nil, errorCode(codeInvalidResponse)
	}
	return m, nil
}

func mutationCommand(action ipc.Action) string {
	switch action {
	case ipc.ActionConnect:
		return "up"
	case ipc.ActionTurnOff, ipc.ActionDisconnectClient:
		return "down"
	case ipc.ActionCreateClient:
		return "add"
	case ipc.ActionRemoveClient:
		return "remove"
	case ipc.ActionSetMode:
		return "mode"
	}
	return "logout"
}
