# macOS review fixes implementation plan

Baseline: `a57baad`, branch `apple`, 2026-10-02
Status: complete, all eight implemented and validated

Implement all eight findings from [the fresh review](macos-review.md).
For status-read failure, retain the last observed status and the existing error
message. Do not add visible menu states.

## Implementation

1. **M2, keep local stop available during inventory refresh**
   Separate inventory activity from VPN command/cancellation activity. Continue
   gating connections on inventory authorization, but allow Turn Off to run
   through the serialized coordinator during remote reads. Fence account changes.
2. **SEC2, confirm backend stop before completing the provider callback**
   A deadline must not invoke NetworkExtension stop completion. Keep the backend
   fenced and complete pending stop callbacks only after actual shutdown.
   The app's stop timeout remains an error and prevents switching.
3. **SEC1, propagate WireGuard startup failures**
   Check the Go device Up result, close failed resources, and return a failed
   handle so the existing sanitized provider error reaches NetworkExtension.
4. **SEC3, fail unconfirmed network-settings startup**
   Stop treating a settings deadline as successful startup. Handle missing,
   delayed, and failed completion without allowing a late callback to revive
   success or race a subsequent settings operation. Keep payload logs suppressed.
5. **AUTH-2, distinguish verifier outages from denied access**
   Keep invalid/revoked/disabled identities as authentication errors. Return a
   retryable service error for Firebase certificate and backend failures.
   Preserve the native session/cache on that response without treating it as
   successful authorization or enabling new online inventory.
6. **AUTH-1, exclude removed history from the authorization cap**
   Filter removed client rows before enforcing the bounded live inventory cap.
   Preserve ownership, duplicate, config hash, and installed-cache checks.
7. **M1, drain cancelled commands before enabling replacements**
   Keep cancellation busy until the coordinator finishes the running command
   and mandatory secret/profile recovery. Do not await a command from inside
   the actor operation that owns it. Maintain session fences and retained VPN.
8. **M3, retain observed VPN status when preferences reads fail**
   Preserve the prior snapshot and its existing error on a failed read. Clear
   that error only after a successful preferences read, separately from inventory
   and command errors. Keep the current menu/icon states.

## WireGuard dependency delivery

The WireGuard fork is an existing git submodule. Make local fork commits and
point both Apple projects and Go bridge builds at that submodule, so validation
and checkout use the fixed source without requiring a remote push. Record the
submodule revision in the final CloudGateway commit. No repository is pushed.
Keep shared dependency changes compatible with iOS and macOS, with focused
host-free validation through the project test entry point.

## Validation

Add regressions for the eight failure paths, including cancellation cleanup,
local stop during refresh, read-error persistence, removed history, verifier
outages versus real denial, stop deadlines, backend failure, and delayed settings.
Root owns sequential test/build runs. Use `./scripts/test.sh api apple` during
implementation and a full no-target gate for final validation. Do not activate
extensions, install VPN profiles, sign in, or change live networking.

## Review and commits

Commit this plan before production edits. Implement all eight before starting
review. Then run at most two review loops: inspect the complete changes, record
and fix concrete findings, validate corrections, and check again. Do not start a
third loop. Update review notes and operations docs to reflect the final behavior
and any remaining runtime limits, then make logical local commits.

Signed extension replacement, System Keychain ACL/XPC, Firebase persistence,
and actual delayed OS networking callbacks remain separate runtime gates.

## Completion

All eight changes are implemented. Review loop 1 corrections are recorded in
the component/integration notes. Review loop 2 found no remaining confirmed
issues, and no third loop ran. The full no-target `./scripts/test.sh` passed
with exit 0. Log: `/tmp/cloudgateway-macos-eight-fixes-full.log`.
The WireGuard fork and containing repository are committed locally, without a push.
