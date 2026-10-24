# Remove clients from the macOS CLI

Status: reviewed, ready to implement. Updated 2026-10-24

## Goal

Expose the completed controller removal operation through `cloudgateway remove`.
The CLI selects a client, reserves the operation, prints its ID, confirms it, and
observes the result. The controller owns authorization, durable eviction, cloud
deletion, and inactive profile cleanup.

The app Remove action stays deferred. Do not change the backend, shared Apple
production code, IPC version, or controller deletion policy for this feature.
Use the current ticket branch, make local commits, and never push.

## Command and confirmation

```sh
cloudgateway remove <client-uuid> --yes
cloudgateway remove <region> <index> --yes
cloudgateway remove <client-uuid> --yes --json --non-interactive
cloudgateway status --operation <operation-id> --json
```

Require an explicit selector and `--yes` in every execution mode. Missing either
is a usage error before connecting to the controller. Do not infer the last
selection. `--yes` acknowledges permanent cloud client deletion. It does not
permit disconnecting a VPN or bypass controller checks. No terminal prompt or
new terminal input machinery is needed. Help works without `--yes` and without
connecting. Reject `--yes` on other commands and reject value forms such as
`--yes=false`. Use the existing common JSON, noninteractive, and timeout options.

Reuse UUID and region/index resolution from `up` and targeted `down`, including
exact region IDs, display names, city aliases, ambiguity errors, and region-local
ordering. Resolve once from settled, account-filtered inventory and send the
resulting canonical identifier unchanged. UUIDs are preferred for scripts.
Indices can change after inventory refresh, so users should rerun `ls` first.
Include authorized rows even when disabled, configless, or never installed.
Do not require connect eligibility, creation capacity, or extension readiness.
Cached rows may identify a target, but the controller must authorize online
before deletion. Missing or ambiguous targets never reserve removal.

## Execution and output

Use the matching-build frontend client and existing reserve/confirm/poll path
with `.removeClient` and the canonical identifier. Do not add direct HTTP,
Firebase, Keychain, or VPN calls. Wait for restoration, verification, and active
inventory refresh within the existing 30-second caller deadline. Preserve
existing sign-in, denied, unreachable, draining, and version-mismatch handling.

Flush the accepted operation ID before confirmation. An output failure must
leave the reservation unconfirmed. After confirmation, timeout, cancellation,
lost replies, and SSH detach stop CLI observation while controller work can
continue. Never automatically retry removal or substitute another target.
Retain the operation ID and `status --operation` guidance on every uncertain
removal result, including a returned typed `unknown` that bypasses the existing
mutation catch block. If lookup remains unknown, direct the user to refresh
online inventory and inspect the original client UUID before another manual
removal attempt. Test typed unknown separately from lost confirmation in both
text and JSON, keeping exit 10 and no resend. Reuse account-switch rejection and
result redaction from the controller.

Add `remove` to the mutation output command. Preserve the versioned JSON envelope,
accepted/result/error records, operation UUID, typed outcomes, warnings, tunnel
observation, and existing exit codes. No extra account/client payload is needed.
Print `Client removed` only for a visible typed `.completed` outcome. If a session
change redacts the outcome, preserve coarse `Command completed` rendering and
null outcome fields without reconstructing hidden target data or warnings.
Completed removal with `local_cleanup_incomplete` or `inventory_not_refreshed`
remains exit 0 and shows
the warning. `client_active` remains exit 4 with explicit disconnect guidance.
Unknown results remain exit 10. Never claim that an unrelated VPN stopped or
that retained Keychain secrets were deleted.

Operation lookup and receipt retention keep the existing controller semantics:
unconfirmed reservations expire after 30 seconds, receipts last 600 seconds
from acceptance, and the latest in-memory result lasts 600 seconds from
completion unless replaced sooner. Restart can yield unknown without redispatch
while the receipt is retained. Expiry does not prove whether deletion occurred.

## Implementation tasks

Implement each task before its review. Use a fresh Sol reviewer, resolve findings
in at most three review rounds per task, then record validation, check off the
task, and commit before proceeding. All builds stay unsigned. No live cloud or
VPN mutations are part of validation.

### Task 1: command, handoff, and output

- [ ] Add the command, mandatory selector and `--yes` validation, local help,
  and dispatch to the existing session mutation path
- [ ] Resolve from settled account inventory without filtering unavailable
  rows, send exactly one removal reservation, and reuse confirmation/polling
- [ ] Add `remove` mutation records and successful text, retaining typed failures,
  warnings, operation lookup, and accepted-ID-before-confirm behavior
- [ ] Add parser and CLI harness coverage for valid selectors/options, local
  usage rejection, no implicit selection, ambiguous/missing targets, disabled
  or configless rows, account/build/session gates, warnings and failures,
  output failure, timeout/cancellation/lost confirmation, and no retry
- [ ] Run `./scripts/test.sh macos`, review the implementation, record the
  result here, and commit the completed task

### Task 2: integration, documentation, and final validation

- [ ] Add CLI-to-real-frontend/orchestrator removal coverage using existing
  test infrastructure. Verify the exact identifier, acceptance before execution,
  single dispatch, active-client refusal, successful warnings, caller loss,
  and account changes. Verify cancellation leaves confirmed work running, while
  session changes preserve rejection/redaction. Reuse controller/helper tests
  for backend/profile semantics
- [ ] Extend packaged direct/symlink CLI smoke checks for removal help and local
  invalid invocations, including missing selector and missing `--yes`
- [ ] Update the macOS README with command examples, permanent deletion consent,
  selectors, active-profile behavior, warning success, uncertainty/recovery,
  retained secrets, and app-only deferral. Correct existing CLI-deferral text
- [ ] Run final `./scripts/test.sh macos` unsigned, `git diff --check`, and an
  aggregate review of the complete CLI change. Record results and review rounds,
  check off the plan, commit, and stop with a clean working tree

## Review and validation record

Plan review round 1: fresh Sol xhigh reviewer agreed with command/confirmation
policy and controller reuse. Accepted both findings: explicit recovery guidance
for typed unknown results, and coarse output for redacted success. Added separate
caller-loss and account-change integration requirements. Fresh Sol xhigh review
round 2 passed with no remaining actionable blockers. Manual plan review and
`git diff --check` passed
