# macOS menu fixes review, loop 1

Baseline: committed implementation plan in `TODO/macos-review-implementation.md`,
working tree on branch `apple`, 2026-10-02
Status: finding corrected and validated, final source review clear

## Confirmed findings

### R1-M1 · P2 · Do not block replacement sessions on cancelled remote reads

- Trigger: Sign out while inventory is waiting for a server-only Firestore query. Sign back in or restore a retained account before the SDK finishes that old request
- Source: `Frontend/Apple/macOS/CloudGateway/CloudGatewayMacAppController.swift:351` waits for the cancelled inventory task inside the cancellation barrier. All future inventory/restore/browser access checks await that barrier at lines 235, 181, and 71. `CloudGatewayMacInventoryService.swift:94–100` waits on a continuation resumed only by the Firestore callback, with no cancellation handler or app-level deadline
- Impact: A read from the previous session delays the next session's access check and keeps VPN commands blocked. Task cancellation alone does not finish the continuation. This is a new regression from draining read-only inventory along with mandatory profile/secret recovery. The delay lasts until the SDK callback, even when the old task's result has already been fenced out. The same barrier also awaits a cancelled restoration task at line 352, and Firebase token retrieval uses another callback-only continuation in `CloudGatewayFirebaseAuthAdapter.idToken`. A permanent SDK hang was not established
- Fix: Keep draining tracked VPN commands and required installation recovery. Avoid making account replacement wait for remote read-only operations, or make the Firestore continuation complete promptly on cancellation with a single-resume guard that discards a late callback. Preserve the guards around cache invalidation/authorization so stale session work cannot mutate current authorization
- Evidence: Static await/dependency trace. The existing/new drain tests pause coordinator profile/secret work and do not exercise cancelled Firestore reads or the app's replacement-session barrier. No live account or Firestore operation was performed

Correction: cancellation now drains the captured VPN command and coordinator
recovery only. Cancelled inventory/restoration reads retain their existing epoch
and cancellation fences and do not delay replacement sessions.

## Coverage

Reviewed the complete app controller and config coordinator, the menu state and
profile observation, inventory access/read handling, account cache, native VPN
profile adapter and stop waiter, browser access-check composition, and Firebase
token callback boundary. Reviewed changed coordinator/menu/cache/inventory-error
tests and matching macOS README/runbook updates.

- M1: The coordinator's busy flag now drains after success, failure, and required installation recovery. Capturing old command tasks before clearing app presentation prevents replacement commands overtaking cleanup. R1-M1 identifies the additional read-only waits introduced by that barrier
- M2: Inventory activity is separate from VPN command/cancellation activity. Local Turn Off remains available during remote reads, while Connect remains gated. Concurrent read completion cannot start another VPN command
- M3: Failed reads preserve the snapshot and the existing preferences error. Inventory/command success can no longer clear that independent error. Successful preferences reads clear it. No new menu state was added
- Authorization: Removed history no longer counts toward the bounded live inventory limit. Ownership validation and installed hash pruning remain in place. Verifier outages remain unavailable rather than authorizing fresh inventory or denying the retained session

## Evidence and limits

No other confirmed finding in this review scope. Captured cancellation tasks were
checked for cycles: each replacement task captures the preceding barrier, so the
current barrier does not wait on itself. Coordinator drain waits from the app
remain outside the operation that owns the busy flag.

Root owns validation. This reviewer performed no production edits, builds, tests,
index changes, commits, live sign-ins, or VPN actions. Source and changed tests
establish the control flow. Actual Firebase callback latency, Apple preferences
callbacks/status notifications, and signed extension behavior remain runtime
checks. The existing tests cover coordinator recovery draining and menu state,
without exercising native controller replacement during a cancelled SDK read.

A failed first preferences read has no earlier status to retain. Retaining the
last successful observation can also be stale. Those are limits of the approved
existing-state presentation, not additional findings in this loop.
