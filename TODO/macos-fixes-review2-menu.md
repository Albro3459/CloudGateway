# macOS menu fixes review, loop 2

Baseline: final working tree on branch `apple`, 2026-10-02
Status: final review complete, no new confirmed findings

This is the second and final review loop from
[the approved implementation plan](macos-review-implementation.md).

## Confirmed findings

None.

## Loop 1 correction

R1-M1 is resolved in the final controller. `cancelPendingWork` cancels and clears
inventory/restoration tasks but does not await their SDK callbacks. The barrier
still retains and drains the prior VPN command and the coordinator's required
installation recovery. Replacement access checks wait for that command barrier,
without waiting for an old Firestore or token read.

Late remote results still cross cancellation/account/epoch checks before updating
presentation. `cache.authorize` checks cancellation on entry. Confirmed role
invalidation remains account-scoped and runs through the cache actor.

## Final coverage

- Reviewed final controller restoration, browser access-check composition, inventory refresh, command selection/retry, stop, sign-out, shutdown, presentation, and cancellation ordering
- Verified cancellation chains capture earlier barriers rather than waiting on themselves. Commands remain disabled until the old command and mandatory secret/profile recovery finish
- Reviewed coordinator busy/drain completion through success, cancellation, profile-save recovery, rollback, commit, and metadata-save failure
- Checked inventory and VPN command activity remain separate. Turn Off stays available during remote reads, while Connect and Refresh remain gated by inventory activity
- Checked retained VPN observations and preferences errors remain independent of inventory/command errors. Only a successful preferences read clears the preferences error
- Checked cache authorization still preserves ownership, live inventory bounds, removed-history exclusion, config hash pruning, role downgrade, and account isolation
- Rechecked access error classification and native profile adapter integration. Retryable verifier failures do not authorize new inventory or trigger session/cache denial
- Reviewed the coordinator drain, menu/status, cache/history, and access-classification regression coverage from the implementation. No test or build was run by this reviewer

## Evidence and limits

Static source/control-flow review found no additional confirmed bug in this scope.
Root owns build/test validation and the final full-suite gate. This reviewer made
no production edits, index changes, commits, live sign-ins, or VPN changes.

Signed extension activation, actual preferences/status callbacks, Firebase callback
latency and persistence, System Keychain/XPC, and retained VPN behavior remain
runtime checks. Cancelling an SDK read may leave its underlying callback pending,
but it no longer blocks replacement sessions through the app cancellation barrier.

The approved presentation retains the last successful VPN observation. It can be
stale, and a failed initial read has no earlier status to retain. The existing
preferences error remains the indication that a read could not finish.
