# Remove clients through the macOS controller

Status: complete, reviewed and validated unsigned. Updated 2026-10-24

## Scope

The controller owns one operation that deletes a cloud VPN client and removes
its local usable configuration. This branch implements the controller,
production adapters, IPC, and regression coverage. Future menu app and CLI removal
flows will share that operation. Frontend commands, selectors, menus, dialogs,
and help remain deferred.

This document defines behavior. The ordered work and verification are in
[the implementation plan](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-remove-controller-implementation.md).
The reviewed planning checkpoint is committed. The user has authorized
implementation, task reviews, unsigned validation, and local commits.

## Implemented boundaries

- The [controller](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift)
  owns auth, session fencing, inventory, selection, and accepted command tasks
- The [IPC orchestrator](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift)
  reserves and confirms mutations, serializes them, and retains operation results
- The [shared API client](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayControlPlaneClient.swift)
  already sends regional DELETE requests and decodes owner, region, client, and status
- The [API route](/Users/alexbrodsky/GitHub/CloudGateway/Backend/API/src/routes.py:383)
  checks requester role and target owner, removes the live regional peer, then
  marks the Firebase client removed. Further policy propagation runs afterward
- The [iOS deletion flow](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayViewModel.swift:693)
  binds deletion to an explicit client and blocks deletion of an active target
- The [account cache](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacAccountCache.swift)
  authorizes offline configs, persists selection, and durably evicts one target.
  The macOS profile adapter and config coordinator remove exact inactive profiles

No backend, Firebase schema/rules, iOS behavior, new dependency, or root helper is
needed. Retain the existing system-secret retention policy. Committed secrets
cannot be rolled back, so this feature does not claim to erase them from Keychain.
Deleting a cloud client revokes its peer and local controller eligibility.

## Contract for both frontends

Use the ordinary authenticated `.removeClient` IPC mutation with exactly one
canonical `accountId/regionId/clientId` identifier. Require the identifier even
when that client is selected. Resolve names, indexes, and aliases in the future
frontend, then submit the resolved identifier. Never delete the current selection
implicitly or accept a caller-supplied owner UID, config, or endpoint.

The first component identifies the signed-in account's local namespace. For an
admin viewing another user's client, it is **not** the API target owner. Derive
the API owner UID from the exact authoritative cloud option. Require a unique
match by region and client within the current account's visible inventory.
Reject duplicate/ambiguous matches and missing owner metadata. Ordinary users
can remove their own clients. Admins can remove visible clients owned by others,
subject to a fresh role check and the backend's final authorization.

Use the existing reservation, confirmation, request digest, operation lookup,
busy handling, and session-bound result redaction. Reservation has no cloud or
local destructive side effects. Only confirmation starts execution. A frontend
detach or output error after confirmation does not cancel accepted work.
The app can ask for confirmation in a dialog and the CLI can provide its own
confirmation policy later. Controller confirmation is the shared execution handoff.

Ordinary remove requests require the current signed build and matching controller
protocol. Include removal in confirmation, account-bound outcome, activity, and
update-draining admission rules. It is not a compatible cross-build stop action.
Preserve lifecycle/status/stop/lookup compatibility and the existing result TTL.
The generic outcomes include two removal additions: `clientActive` failure
and `localCleanupIncomplete` warning. Keep `inventoryNotRefreshed` for a successful
delete whose final cloud refresh fails. Define cleanup warning precedence below.

## Execution policy

1. Require a settled signed-in session and exclusive mutation admission. Refresh
   access role and cloud options inside the accepted command, using existing
   bounded inventory reads. Require fresh successful cloud reads. Offline/cache
   inventory alone never authorizes deletion
2. Fence every awaited auth, inventory, cache, and profile boundary with the
   captured session token and controller epoch. Observe role changes through
   the existing role invalidation path. Re-resolve only the submitted identifier
   in that fresh inventory and capture its owner/region/client tuple
3. Load current owned profiles through the config coordinator. A missing target
   profile is fine. Reject duplicate/malformed target profiles or an unreadable
   profile list. Reject the target while connecting, connected, reasserting, or
   disconnecting with `clientActive`. This uses macOS `needsConfirmedStop`,
   which is stricter than iOS during disconnecting. Ask the caller to disconnect
   explicitly and wait. Do not stop or reconnect any tunnel as part of removal
4. Before dispatching DELETE, atomically evict that identifier's installed cache
   snapshot, authorized hash, and selection if selected. Also remove its installed
   metadata and selectable option from the current presentation. Abort before
   DELETE if durable eviction fails. Preserve other clients, authorization, and
   selection. Drain any older inventory publication before eviction so it cannot
   restore a cached authorization afterward
5. After token acquisition, recheck the session and the target profile's inactive
   status at the transport handoff, using the production-used, host-free request
   helper specified in implementation step 4. Use the existing regional API with the captured
   owner/region/client tuple. Do not set account-cleanup mode. Submit once
6. Validate a successful response against all three captured identity fields and
   `.removed`. Preserve knowledge of a verified remote success before doing
   cancellable refresh/cleanup work. A mismatched/malformed reply is uncertain
7. After confirmed remote removal, remove only the matching inactive owned VPN
   profile through the coordinator and production adapter. Reload preferences
   and verify absence. Recheck session and inactive status before mutation.
   Never remove an active profile, another client's profile, or another account's
   namespace. Missing profile is a successful no-op. Keep retained system secrets
8. Refresh/publish remaining inventory and capacity through existing paths as
   available. Keep the removed target excluded from the command's publication.
   Never choose a replacement selection, install a profile, or start a tunnel.
   An unrelated connected client stays connected

The config coordinator serializes local checks and profile removal against
installation/start work. Controller command ownership blocks other frontend
mutations, inventory publication, and managed update/reconnect during execution.
An external macOS action can still change VPN status. A final active check blocks
DELETE where observable, and cleanup rechecks independently. Do not promise an
atomic transaction across Firebase, HTTP, and NetworkExtension.

## Failure, partial success, and recovery

| Point | Result and recovery |
| --- | --- |
| Auth/access denial before DELETE | Existing sign-in/access failure and denial invalidation policy. No DELETE or profile removal |
| Cloud fetch/network failure before DELETE | `networkUnavailable`, no cached/offline delete and no profile removal |
| Target missing, removed, ambiguous, or owner unavailable before dispatch | `configUnavailable`, refresh the list. Do not invent backend success or delete a different record |
| Target active | `clientActive`, caller must disconnect that target first. Other clients may stay active |
| Cache eviction or profile observation failure before dispatch | Safe typed storage/VPN failure, no DELETE |
| Auth denial returned by DELETE | `accessDenied`, existing account-denial invalidation. Do not call it a retryable network error |
| Other error, timeout, cancellation, malformed reply, or transport loss after dispatch | `unknown`. The backend may have removed the peer or client. Never replay automatically. Keep the pre-dispatch cache eviction and require fresh inventory before another attempt |
| Verified remote success, local profile cleanup fails or session changes | Completed with `localCleanupIncomplete`. The cloud deletion remains successful. Leave an active or unobservable profile untouched. Keep the target excluded from controller connect eligibility in the original session. Do not assert that the profile is stopped |
| Verified remote success, cleanup succeeds, inventory refresh fails | Completed with `inventoryNotRefreshed`. The target stays evicted, ask for refresh |
| Verified remote success and cleanup/refresh succeed | Completed without warning |

When both cleanup and refresh fail, `localCleanupIncomplete` takes precedence
and its message instructs refreshing too. If the profile is active or its state
is unknown, recovery instructs an explicit Disconnect or System Settings stop
before further cleanup. Removal itself never submits a stop. The result carries sanitized typed
codes, never raw SDK/API error text. `unknown` is not a failed delete assertion.
The current shared HTTP client maps non-401/403 errors broadly, so do not infer
404, already removed, or a definitive no-write result by parsing its message.

After a crash/restart, unexpired persisted request receipts prevent duplicate
execution of the same request ID, while the in-memory result may be unknown.
Receipt protection lasts 600 seconds from acceptance. Results remain in memory
for 600 seconds after completion, and running results have their existing
lifetime. These are separate clocks. Startup discards expired receipts, so an
old ID can be admitted again after receipt expiry. Frontends must never resend
an uncertain DELETE automatically, including after the receipt window. This is
bounded replay protection, with no permanent exactly-once guarantee.
Pre-dispatch cache eviction prevents the target being offered offline, even if
DELETE succeeded just before the process died. A later authoritative refresh
may restore a still-active cloud client after an uncertain/failed request. A
removed cloud record must not restore cached metadata or selection. Normal
operation lookup and Refresh are the recovery surface. Do not add a durable
delete queue, automatic DELETE retry, or startup profile deletion in this feature.
An orphan profile can remain after a crash or failed cleanup, and an external
action may activate it. Its existence in preferences must not make it an eligible
controller config. The controller does not promise to stop it as part of removal.

## Acceptance

- Both frontends can use the same identifier, operation handoff, typed outcome,
  and snapshot without direct Firebase, HTTP, Keychain, or VPN mutation code
- Owner/admin authorization, active-target rejection, cache eviction before the
  request, and absence of unrelated VPN effects are controller invariants
- Remote success survives cleanup/refresh errors. Uncertain requests are honest
  and never retried automatically. Account changes cannot delete a new session's
  local state or expose the original account's outcome
- Real controller/coordinator/IPC coverage and unsigned macOS validation pass
  before the implementation is complete

## Plan review

Round 1, Secure Codex `gpt-6-astra`, high reasoning, requested revision:

1. Dispatch checks and HTTP coverage lacked an importable production seam.
   Implementation step 4 now names a macOS core request helper and a
   request-scoped AppCore session wrapper used by production and host-free tests.
   Its final session/profile checks run after token loading, and the handoff
   marker conservatively separates local failures from uncertain network work
2. Replay guarantees exceeded receipt retention. Both plans now distinguish the
   600-second acceptance-based receipt window from completion-based result
   retention, describe expiry/restart behavior, and require before/after tests
3. Cleanup promised a stopped profile despite possible external activation.
   The plans now leave active/unobservable profiles untouched, retain confirmed
   cloud success with a cleanup warning, and require explicit-stop recovery and
   zero automatic stop/remove calls in that case

All three findings accepted and resolved. Round 2, a fresh Secure Codex
`gpt-6-astra` review with high reasoning, passed with no remaining actionable
findings. The reviewer checked the revised contracts against production source,
including the transport seam, receipt clocks, and active-profile cleanup policy.
At the planning checkpoint, the parent agreed the plans were ready for
implementation. Manual document review and local reference checks passed. No
removal implementation, tests, builds, or live operations were performed during
that planning task. The subsequent task reviews and validation are recorded in
the implementation plan. Final aggregate branch review passed in round 1 on
Secure Codex 6.1 Sol High with no actionable findings. All tasks are checked off,
validated unsigned, and committed locally.
