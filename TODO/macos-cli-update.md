# Update the VPN extension over SSH

Status: implemented, reviewed, and unsigned validation passed

## Problem

After replacing CloudGateway.app, the controller hands over to the installed app
but the running VPN extension can still be an older signed artifact. CLI `up`
then reports a generic setup error and sends the user to the menu app. Extension
replacement is currently initiated by the menu, even when initial approval and
VPN preferences already exist.

Expose an update workflow that can stop the VPN, replace the extension, verify
it, and restore the same connection after the issuing SSH session disappears.
Persist the operation so controller restart does not lose its intent.

## CLI contract

```text
cloudgateway update
cloudgateway update --allow-disconnect
cloudgateway update --allow-disconnect --json
cloudgateway status --operation <operation-id>
cloudgateway doctor
```

`update` activates the VPN extension bundled in the already-installed app at
`/Applications/CloudGateway.app`. It does not download, build, or install an app
release. Initial setup stays in the GUI. `doctor` remains read-only.

- No active tunnel: update and leave the VPN disconnected
- Active tunnel without `--allow-disconnect`: explain that replacement requires
  stopping the VPN, show the opt-in command, and make no VPN changes
- Active tunnel with the flag: record the exact observed config, stop and confirm,
  update, verify readiness, and request a start of that same config
- An already matching extension is a successful no-op, with no disconnect
- Never infer the reconnect target from a row index or a later last selection.
  Same config means the same stable client identifier under normal `up` rules,
  including an authorized cloud config revision if the contents changed. It does
  not mean pinning old WireGuard bytes or exporting a secret reference
- Require a uniquely identified, currently authorized target before accepting an
  active-tunnel update. Refuse before stopping if it cannot be restored safely
- Pre-stop checks use account/config/profile metadata. Do not require a secret
  RPC against the new extension before replacement, since that endpoint can be
  unavailable during the version mismatch being repaired. Check actual secret
  availability through the normal start path after authenticated readiness
- Connecting/reasserting tunnels count as active. A disconnect already in
  progress must settle before deciding whether reconnect is intended
- Signed-out updates are allowed when disconnected. Reconnecting requires the
  same authorized account and existing config/secret access, using normal `up`
  rules. New login and initial VPN preference approval remain GUI setup
- Common help, JSON, noninteractive, and caller timeout options apply. The flag
  is the explicit authorization, with no hidden prompt or implicit disconnect

Show the operation ID before confirming execution. After confirmation, frontend
timeout, Ctrl-C, output failure, or SSH loss detaches observation without
cancelling the controller-owned workflow. Before confirmation, no disruptive work
runs. Explain the distinction in help and the SSH example.

## Controller-owned sequence

1. Verify the installed app/extension signatures and current build identity.
   Check authenticated no-op before requiring disconnect consent or reconnect
   authorization. Inspect registration and fresh profiles for real updates
2. Persist a prepared operation, target identity, captured profile/reconnect
   decision, consent, and confirmation deadline before acceptance
3. On confirmation, recheck that target and captured profile decision still match.
   Reject a newly active/different config instead of capturing another target.
   Persist confirmation before any stop or OS submission. An initially off
   reservation stays off even when the disconnect flag was supplied
4. Stop through the existing confirmed-stop API. Never replace an extension
   while an owned tunnel is active or observation is unavailable
5. Request OS replacement from the signed controller process. Keep the request
   and its delegate alive independently of the CLI and menu
6. Verify the installed target through the authenticated extension ping. An OS
   activation callback alone is not proof the expected extension is ready
7. If reconnect was recorded, recheck account, inventory, config, and current
   installed target, then use the start path for the captured identifier. Add a
   non-displacing start policy: a different active profile cancels reconnect,
   rather than stopping that profile as an ordinary explicit `up` may do
8. Persist the outcome and expose it through operation status

Reconnect completion means the existing `up` contract: the start was submitted
or the same config is already active. Do not claim verified traffic connectivity.
Retain observed tunnel state separately from the operation outcome.

The controller must retain ownership and avoid idle exit while actionable work
or a live activation request remains. CLI loss must not cancel or release it.
Different request IDs report busy during an active update. The same ID and
payload return the existing reservation/status; a different payload under
that ID is rejected. No duplicate OS requests. Current menu activation forwards
to the same controller-owned adapter. The existing extension-attempt orchestrator
is the sole activation gate, shared with retained legacy request/callback paths.

## Durable state and recovery

Use a bounded, versioned private controller record under the existing macOS
application-support directory and atomic owner-only file writes. Store one update
operation, its phase, operation ID, target signed identity, timestamps/deadlines,
disconnect consent, reconnect flag, original account and stable config identifier,
and result. Keep secrets and configs in their existing stores. No tokens, private
keys, raw configs, VPN traffic, or connection history belong in the journal.

Write intent before effects. A write failure must prevent the next stop,
activation, or reconnect. An unconfirmed prepared operation expires without
effects. Resume a confirmed operation on the next controller start, including
handoff, by observing actual extension/profile state before deciding the next
step. No blind replay of `down`, activation, or `up` based only on a saved phase.

An active operation is separate from ordinary in-memory command receipts, whose
results currently expire after ten minutes and disappear on restart. Keep pending
update state until resolved; retain one terminal result for a bounded period
(ten minutes) for `status --operation`. Never turn an expired terminal record back
into work. Unknown journal versions, corrupt records, and unsafe file ownership
block automatic update recovery and leave ordinary status/local stop available.

- Same target already authenticated: proceed to any recorded reconnect
- Request outcome uncertain after restart: reconcile readiness first and safely
  resubmit activation only when no live request remains in this process
- New app/extension target supersedes the recorded target: record that outcome,
  suppress reconnect, and require a new update request
- Restoring account: wait for bounded existing session restoration before start
- Logout, account change, access denial, or a newer explicit unscoped `down` or
  scoped stop of the captured config clears reconnect intent irreversibly, even
  if the same account signs in again. Observe core auth events as well as IPC
  admission. `up` during an active update reports busy
- An initially disconnected update must never start a tunnel during recovery
- Reboot recovery happens when the on-demand controller next starts. Do not
  promise automatic launch or unattended networking before existing setup/auth
  prerequisites are satisfied

Suppress reconnect in memory immediately, then persist the journal change. If
that write fails, attempt a separate bounded operation-ID revocation marker in
private storage, checked before recovery. Always preserve local stop even when
both writes fail. Report an explicit persistence warning in that case: durable
suppression cannot be guaranteed across restart when every write fails. Do not
claim otherwise or reject `down`. Prefer revocation before account actions, and
use the auth event hook for changes outside CLI admission.

The workflow operation ID also identifies its extension attempt, so recovery can
reconcile the two records. Prepared orphan attempts expire without OS submission.
An attempt without a valid owning workflow cannot authorize reconnect. If one
record write fails, stop advancing until consistent state is persisted. Retained
legacy attempts remain exclusively gated and never acquire reconnect intent.

## Apple approval and restart

Submit the supported SystemExtensions activation/replacement request from the
installed, entitled app executable. Do not bypass macOS approval or change SIP,
MDM policies, or unrelated preferences. Existing approval can allow an update,
but does not guarantee every replacement is unattended.

Expose distinct durable states for activating, approval required, restart
required, checking readiness, reconnecting, completed, failed, and superseded.
Keep an approval request alive while the controller lives. On restart reconcile
and, if necessary, recreate the request rather than assuming its old callback
will arrive. Approval/reboot states must be visible to an SSH user without a GUI.
Reconnect only after authenticated readiness and valid account authorization.

When approval or reboot is required, CLI observation returns promptly with exit
4, the operation ID and the pending phase. The durable operation stays running;
this is not a terminal failure or cancellation. Once Apple reports completion,
allow at most 120 seconds for authenticated readiness before recording failure
and releasing ordinary mutation admission. A failed update leaves the VPN off.

If the verified installed app changes while approval is pending, suppress
reconnect, persist a superseded/handoff outcome and close admission. Keep the
live OS request fenced until the old owner process exits, ending that request.
The next controller reconciles registration/readiness before new submission.
Do not let an approval wait block verified app handoff indefinitely, or release
the activation slot while another process can still own that request.

Do not disconnect automatically to start an update without the flag. Clearly
state that the SSH session may disappear if it uses the VPN being stopped.

## Status and errors

Add update-specific status data to versioned CLI JSON without changing existing
field meanings. `status --operation` must find the durable operation after
reconnection or controller restart. Normal `status` should show an active update
and the independently observed tunnel. Redact account/config identifiers and
outcomes from signed-out or other-account sessions.

Use existing exit categories: setup/approval/restart requirements 4, unavailable
config/selection 5, service failure 6, busy 7, caller deadline 8, VPN failure 9,
and unknown/superseded outcome 10. Add stable error codes within those categories
where needed. Preserve the accepted/result/error NDJSON contract.

Replace generic setup guidance with the actual readiness state. A version/hash
mismatch should recommend `cloudgateway update`; initial setup and actual Apple
approval should retain appropriate GUI guidance. `doctor` should distinguish
these states without initiating updates.

## Validation and boundaries

Use host-free tests for the durable workflow and real controller/CLI integration.
Cover interrupted SSH, restart at each effect boundary, initially disconnected
behavior, exact reconnect target, confirmed stop, idempotency, write failures,
account changes, explicit stop suppression, approval/reboot, changed targets,
and menu/CLI concurrency. Assert no start before authenticated readiness.

Run `./scripts/test.sh macos` unsigned only. Static packaged CLI checks must not
activate an extension, change preferences, or touch the installed app/VPN.
Signed live replacement and SSH route-loss verification require a later explicit
runtime exercise; unsigned tests do not establish Apple approval behavior.

The implementation sequence is in
[macos-cli-update-implementation.md](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-cli-update-implementation.md).
