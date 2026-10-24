# Implement controller-owned client removal

Status: implementation in progress. Updated 2026-10-23

Follow [the behavior plan](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-remove-controller.md).
Implement only the controller operation and its adapters/IPC. Frontend removal
commands and UI remain separate work. Implementation is authorized. Complete
each task, review it in at most three rounds, validate it, check it off, and
commit it before starting the next task. Use Codex 6.1 Sol with high reasoning
for implementation and reviews, starting subagents on Main and switching all
subagent work to Secure if Main reaches its usage limit. Validation is unsigned.

## 1. Add the typed removal contract

- [x] Extend [core contracts](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacControllerContracts.swift)
  with inventory deletion using the resolved owner/region/client tuple and
  signed-in user. Reuse `CloudGatewayDeleteClientResponse` from AppCore
- [x] Add `clientActive` failure and `localCleanupIncomplete` warning. Keep
  `completed`, `failed`, and `unknown` operation meanings. Update exhaustive
  mappings in the CLI, menu projection, and managed-update failure conversion
  as needed for compilation, without adding a removal frontend flow
- [x] Extend [IPC contracts](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerContracts.swift)
  with ordinary `.removeClient`: one valid canonical identifier, all creation,
  login, update, and context fields absent. Include it in `requiresConfirmation`
  and `hasAccountBoundOutcome`. Existing digest already includes action/identifier
- [x] Keep protocol 2 for this current-build-only action and preserve control
  version 1. Do not send the new typed cases to mismatched builds through
  compatible lookup/confirmation. Add round-trip and compatibility fixtures
- [x] Reuse the current snapshot and latest operation. No per-row removal
  capability or owner UID needs to cross IPC for this controller-only step

Acceptance: malformed/cross-build requests fail, round-trip operation outcomes
work, and existing app/CLI callers and compatible stop/status keep compiling.

## 2. Add target-scoped durable cache eviction

- [x] In [the account cache](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacAccountCache.swift),
  add an atomic account/identifier-scoped eviction. Remove the config snapshot,
  matching authorized hash, and selection only if selected. Validate namespace
  and retain other configs, role, access flag, and hashes
- [x] Eviction must succeed even for an authorized client that was never
  installed. Failure to persist aborts remote dispatch. Avoid a broad account
  deny for an ordinary single-client removal
- [x] In the controller, drain existing inventory tasks/commits before removal
  admission or refuse while they run. Hold new refresh publication until the
  command finishes using existing command/deferred-refresh ownership
- [x] Keep installed metadata and presentation in sync with eviction, including
  the empty-options fallback path that can otherwise render installed cache

Acceptance: reloading a new cache instance cannot restore the evicted client or
its selection. Unrelated cached clients remain usable. A failed eviction sends
zero DELETE requests. An older refresh cannot publish after the eviction.

## 3. Add exact inactive-profile removal

Primary files: [config coordinator and profile protocol](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacConfigCoordinator.swift)
and [production profile adapter](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacVPNProfileAdapter.swift).

- [x] Add coordinator support for fresh target-inactive validation and removal
  under existing `runCommand` serialization/generation checks. Require the
  controller authorization closure at awaited boundaries
- [x] Add an adapter remove operation for an exact canonical identifier. Load
  app-owned managers, reject duplicate/invalid matches, allow absence, require
  the matching profile's `needsConfirmedStop == false`, then use preferences
  removal and reload to confirm absence. Revalidate ownership/identity/status
  at the final mutation boundary
- [x] Fail closed on unreadable preferences. Never fall back to the first
  manager or selected manager. Do not call stop, start, install, or replacement
- [x] Keep reference/ownership matching within existing metadata rules. Do not
  use `secrets.rollback` for committed secrets or add a committed-secret delete
  API. Retained secret garbage collection remains separate work

Acceptance: absent/disconnected/invalid targets, all four active/transition
states, duplicate profiles, observation/removal/reload failure, external status
changes, and concurrent install/start are covered. Other profiles stay untouched.

## 4. Wire the existing regional DELETE API

Add a narrow `CloudGatewayMacClientRemovalRequest` helper in
`/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacClientRemovalRequest.swift`.
The production inventory adapter delegates deletion to it, and host-free core
tests exercise that same helper. The app-only inventory adapter is not importable
by those tests, so a fake inventory service alone cannot verify the HTTP boundary.

- [ ] Give the helper the captured target tuple, injected token loader, the
  existing bounded no-redirect session, a final controller authorization closure,
  and dispatch evidence callback. Reuse the existing origin and session settings
  from [the inventory adapter](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacInventoryService.swift)
- [ ] Check session/cancellation before loading the token. After token acquisition,
  invoke the existing control-plane `deleteClient(clientId:userId:regionId:idToken:)`
  once with the authoritative owner, using a request-scoped wrapper implementing
  the existing AppCore `CloudGatewayControlPlaneSession` protocol
- [ ] At the wrapper's `data(for:)` boundary, run the final authorization closure:
  validate the original session, reload/check the exact target profile through
  the coordinator, then recheck session/cancellation after that awaited check.
  If it fails, do not call the underlying session and report pre-dispatch failure
- [ ] After that gate succeeds, record dispatch evidence immediately before
  forwarding once to the underlying session. This is a conservative network
  handoff marker, not proof that bytes reached the server. A failure before the
  wrapper is entered, including token/URL construction failure, is pre-dispatch.
  An underlying timeout/cancellation is uncertain. Scope the wrapper to this
  DELETE so unrelated inventory requests cannot trip the callback
- [ ] Validate returned userId, regionId, clientId, and removed status. Record
  validated remote success in the original operation before any post-response
  cancellation/session gate. Keep actor-bound response handling in the helper,
  or return a small macOS Sendable receipt if a boundary needs it. Do not change
  the shared response type merely for this feature
- [ ] Preserve known 401/403 denial classification. Treat other post-dispatch
  errors conservatively because the shared API error contract lacks status/code
  detail. Do not change shared HTTP error behavior or parse message text

Acceptance: helper tests inject a session that records actual URLRequests and
returns HTTP fixtures through the real shared API decoder. Assert exact method,
URL, owner/region body, and absence of account-cleanup mode. Suspend token loading
and the final profile check to prove an account change or active target prevents
underlying dispatch. Cover token denial, dispatch timeout/response loss, response
mismatch, and a successful response racing account change. Use the helper in the
controller test inventory service too, so handoff assertions exercise this real
path. Review the app adapter's thin delegation manually and compile it unsigned.

## 5. Implement the domain operation

In [the controller](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift):

- [ ] Add `removeClient(identifier:onCompletion:) -> Bool` following the existing
  accepted-task/completion pattern. Synchronous rejection returns a typed reason
- [ ] Capture session token/epoch and the explicit identifier. Refuse restoration,
  auth settling, inventory publication, another command, shutdown, or pending
  cancellation. Keep `hasPendingWork` and refresh deferral accurate
- [ ] Refresh role/options with bounded reads inside the command. Resolve exactly
  one matching cloud record, require owner metadata, and enforce current role
  plus owner rules. Do not require a usable config, enabled region, spare
  capacity, or installed profile to delete a known client
- [ ] Check inactive target, persist cache eviction, update presentation, then
  recheck session/inactive status at dispatch. Capture known remote success
  independently of subsequent session cancellation
- [ ] After remote success, perform fenced local cleanup and refresh. Publish
  only to the original current session. Exclude the confirmed removed target
  even if a subsequent inventory read contains an older copy
- [ ] If post-response observation finds an active or unobservable profile, leave
  it untouched and return successful removal with `localCleanupIncomplete`.
  Assert zero stop/remove calls in that case. Recovery asks for explicit stop
  before cleanup. Do not infer that logout or account change stopped a tunnel
- [ ] Apply the behavior plan's failure table and warning precedence. Never
  restore the pre-delete cached snapshot on error. Only fresh authoritative
  inventory can make a still-active target eligible again
- [ ] Preserve original-account success in completion while letting IPC redact
  it after session change. Do not clean up profiles or selection using the new
  account's state. Keep success/unknown sticky across deferred cleanup failures

Acceptance: successful deletion, inactive/uninstalled/disabled-region/configless
clients, admin deletion, own/foreign selection, unrelated active VPN, startup,
auth/role change, denied/failed/uncertain requests, refresh failures, and persisted
offline fallback are tested through the real domain controller and cache.

## 6. Expose the operation to both clients through IPC

- [ ] Route `.removeClient` in [the production service](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift)
  to the domain method through the existing effects boundary
- [ ] In [the orchestrator](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift),
  include removal in activity and normal mutation admission. Bind reservations
  to a settled current session and explicit account-scoped identifier. Recheck
  session on confirmation, then let the domain refresh/revalidate the target
- [ ] Reuse the existing persisted request receipt, 30-second unconfirmed expiry,
  independent execution, operation polling, and result TTL. Confirm once.
  Within the receipt lifetime, duplicate requests return their existing/unknown
  operation and do not redispatch. Receipts expire 600 seconds after acceptance.
  Results expire 600 seconds after completion, with existing running-result
  behavior. Startup drops expired receipts, so replay protection after restart
  ends at receipt expiry. Never automate a resend of an uncertain DELETE
- [ ] Refuse removal during managed update, startup reconciliation, activation,
  or draining. Keep signed-out global stop available under its existing rules
- [ ] Verify cancellation, detach, and restart behavior through the actual
  orchestrator/domain handoff, not only injected final outcomes

Acceptance: two frontend clients cannot race removes or remove during a start.
No side effects occur before confirmation. Account switch between reserve and
confirm rejects. Disconnecting one frontend after confirmation leaves work owned
by the controller. Changed payload with the same ID is rejected. Restart receipts
prevent replay within their lifetime without pretending the prior result survived.
Test a restart before expiry yielding unknown with zero redispatch, and a restart
after expiry showing the old ID can be admitted. Do not promise permanent deduplication.

## 7. Verify the implementation and document the controller contract

- [ ] Extend the existing core/cache/coordinator and IPC contract/request/outcome
  suites under [macOS tests](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests)
  with focused removal tests. Update service fakes for the protocol method
- [ ] Include deterministic suspension points at fresh role/inventory reads,
  durable eviction, dispatch, response, profile removal, and final refresh.
  Assert actual request counts, cache reloads, selection, installed profiles,
  start/stop/install call counts, and cross-account output redaction
- [ ] Specifically exercise eviction followed by restart with offline reads,
  success followed by refresh failure, response loss after backend execution,
  success racing logout/account switch, stale inventory publication, and late
  active-profile observation. Use existing doubles, no live cloud/VPN changes
- [ ] Update [the macOS README](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/README.md)
  with the controller contract and explicit frontend deferral. Do not advertise
  a working CLI remove command or app Remove action before those exist
- [ ] Run `./scripts/test.sh macos` for tests, strict Periphery, unsigned arm64
  app/extension build, packaging, and existing CLI smoke checks. Production IPC
  dispatch provides a real reference to the operation, avoid broad dead-code
  suppression. Shared Apple production code should remain unchanged. If a
  necessary shared change is approved later, validate iOS first and macOS too
- [ ] Complete code review with Codex 6.1 Sol High using the account policy above,
  resolve actionable findings, and rerun validation when changes warrant it
  before committing the completed implementation

The planning checkpoint is committed as `b0ebb97d`. The user authorized
implementation, unsigned validation, task reviews, and local commits afterward.
Do not create a PR or push.

## Implementation record

### Task 1: typed removal contract

Implemented and reviewed with Main Codex 6.1 Sol High. Review round 1 passed
with no actionable findings. `./scripts/test.sh macos` passed: 627 macOS tests,
strict Periphery scans, unsigned arm64 app/extension build, packaging, and 58
CLI smoke checks. Temporary unavailable inventory/IPC stubs and a narrow
protocol Periphery annotation are removed by the later integration tasks.

### Task 2: durable target cache eviction

Implemented on Secure after Main reached its usage limit. Secure Codex 6.1 Sol
High review round 1 passed with no actionable findings. Full unsigned macOS
validation passed: 637 core/IPC tests, both strict Periphery scans, app/extension
build, packaging, and CLI smoke checks. Task 5 connects the controller eviction
seam to DELETE and adds dispatch-order assertions.

### Task 3: exact inactive-profile removal

Secure Codex 6.1 Sol High review round 1 passed with no actionable findings.
Full unsigned macOS validation passed: 662 macOS tests, both strict Periphery
scans, app/extension build, packaging, and 58 CLI smoke checks. Production uses
the same removal helper covered by preference-failure and activation-race tests.
Task 5 connects the coordinator APIs and removes their temporary annotations.
