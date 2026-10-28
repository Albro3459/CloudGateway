package daemon

import (
	"context"
	"errors"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
)

const (
	updateConfirmWindow = 30 * time.Second
	updateRetention     = 600 * time.Second
)

// Linux update restarts the daemon onto the installed release and keeps the
// tunnel up. It emits prepared, activating, checking_readiness, completed,
// failed, and superseded only, and allowDisconnect has no effect

func terminalUpdate(phase ipc.UpdatePhase) bool {
	return phase == ipc.UpdateCompleted || phase == ipc.UpdateFailed || phase == ipc.UpdateSuperseded
}

// loadUpdate finishes a record the previous daemon left before restarting
func (c *Controller) loadUpdate() {
	record, err := c.store.LoadUpdate()
	if err != nil {
		if !errors.Is(err, store.ErrMissing) {
			c.logf("update record unreadable")
		}
		return
	}
	finish := func(phase ipc.UpdatePhase, code string) {
		record.Phase, record.Error, record.UpdatedAt = phase, code, c.now()
		if err := c.store.SaveUpdate(record); err != nil {
			c.logf("saving the update record failed")
		}
	}
	switch record.Phase {
	case ipc.UpdatePrepared:
		finish(ipc.UpdateFailed, "operation_expired")
	case ipc.UpdateActivating, ipc.UpdateCheckingReadiness:
		finish(ipc.UpdateCheckingReadiness, "")
		installed, installedErr := c.releases.Installed()
		switch {
		case c.releases.Running() == record.Target:
			finish(ipc.UpdateCompleted, "")
			c.logf("update to %s completed", record.Target.Version)
		case installedErr == nil && installed != record.Target:
			finish(ipc.UpdateSuperseded, "update_superseded")
		default:
			finish(ipc.UpdateFailed, "readiness_failed")
			c.logf("restarted daemon does not run the update target")
		}
	}
	c.update = &record
}

// updateStatusLocked returns the retained update. Finished records answer for 600 seconds
func (c *Controller) updateStatusLocked() *ipc.UpdateStatus {
	record := c.update
	if record == nil {
		return nil
	}
	now := c.now()
	if record.Phase == ipc.UpdatePrepared && !now.Before(record.CreatedAt.Add(updateConfirmWindow)) {
		record.Phase, record.Error, record.UpdatedAt = ipc.UpdateFailed, "operation_expired", now
		if err := c.store.SaveUpdate(*record); err != nil {
			c.logf("saving the update record failed")
		}
	}
	if terminalUpdate(record.Phase) && !now.Before(record.UpdatedAt.Add(updateRetention)) {
		return nil
	}
	status := record.Status()
	return &status
}

func (c *Controller) updatePendingLocked() bool {
	status := c.updateStatusLocked()
	return status != nil && !terminalUpdate(status.Phase)
}

func (c *Controller) ownsUpdate(id string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	status := c.updateStatusLocked()
	return status != nil && status.ID == id
}

func (c *Controller) updateReply(ctx context.Context, status ipc.UpdateStatus) ipc.Reply {
	state := c.state(ctx, false)
	operation := status.Operation()
	return ipc.Reply{State: &state, Operation: &operation, Update: &status}
}

// reserveUpdate prepares an update to the installed release, or completes at
// once when the running release already matches it
func (c *Controller) reserveUpdate(ctx context.Context, request ipc.Request) ipc.Reply {
	command, creation := c.registry.Busy()
	c.mu.Lock()
	running := c.releases.Running()
	refuse := func(code string) ipc.Reply {
		c.mu.Unlock()
		status := ipc.UpdateStatus{ID: request.ID, Phase: ipc.UpdateFailed, Target: running, Error: code}
		reply := c.updateReply(ctx, status)
		reply.Operation.Failure = ipc.FailureCommandFailed
		if code == string(ipc.CommandBusy) {
			reply.Operation.Failure = ipc.FailureBusy
		}
		return reply
	}
	if status := c.updateStatusLocked(); status != nil && status.ID == request.ID {
		c.mu.Unlock()
		return c.updateReply(ctx, *status)
	}
	if command || creation || c.draining || c.closing || c.preparing || c.commands > 0 || c.stops > 0 ||
		c.updatePendingLocked() || c.restore != nil || c.login != nil {
		return refuse(string(ipc.CommandBusy))
	}
	target, err := c.releases.Installed()
	if err != nil {
		return refuse("installation_required")
	}
	now := c.now()
	record := store.UpdateRecord{ID: request.ID, Phase: ipc.UpdatePrepared, Target: target, CreatedAt: now, UpdatedAt: now}
	if target == running {
		record.Phase = ipc.UpdateCompleted
	}
	if err := c.store.SaveUpdate(record); err != nil {
		return refuse("storage_unavailable")
	}
	c.update = &record
	status := record.Status()
	c.mu.Unlock()
	return c.updateReply(ctx, status)
}

// confirmUpdate persists the activating record, then asks the process to
// exit so systemd restarts it on the installed release
func (c *Controller) confirmUpdate(ctx context.Context, id string) ipc.Reply {
	c.mu.Lock()
	status := c.updateStatusLocked()
	record := c.update
	if status == nil || status.ID != id || record.Phase != ipc.UpdatePrepared {
		c.mu.Unlock()
		if status != nil && status.ID == id {
			return c.updateReply(ctx, *status)
		}
		return c.operationReply(ctx, id)
	}
	next := *record
	next.UpdatedAt = c.now()
	installed, err := c.releases.Installed()
	switch {
	case err != nil || installed != record.Target:
		next.Phase, next.Error = ipc.UpdateSuperseded, "update_superseded"
	case c.closing || c.commands > 0 || c.stops > 0 || c.preparing:
		next.Phase, next.Error = ipc.UpdateFailed, string(ipc.CommandBusy)
	default:
		next.Phase = ipc.UpdateActivating
	}
	if err := c.store.SaveUpdate(next); err != nil && next.Phase == ipc.UpdateActivating {
		next.Phase, next.Error = ipc.UpdateFailed, "storage_unavailable"
	}
	c.update = &next
	if next.Phase == ipc.UpdateActivating {
		c.draining = true
		c.logf("restarting onto release %s", next.Target.Version)
		c.exitOnce.Do(func() { close(c.exit) })
	}
	c.notifyLocked()
	result := next.Status()
	c.mu.Unlock()
	return c.updateReply(ctx, result)
}
