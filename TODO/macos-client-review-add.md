# CLI add review

Reviewer: Main Codex (`codex_main`), `gpt-6.1-sol`, high reasoning, depth 1
Date: 2026-10-24
Checkout: `/Users/alexbrodsky/GitHub/CloudGateway`
Current snapshot: `b5cc728b` on `mac-remove-client`
Original add snapshot: `373f854f32c496eba7e3b0de21cfbd7e97a91590`, PR #16

Scope: CLI add parsing and region selection, preparation and IPC reservation/confirmation, controller creation, cancellation and session fences, independent stop, output, production inventory adapter, and HTTP behavior. Review only. Parent owns validation and commits.

## Current findings

No new confirmed actionable bugs found in this scope at `b5cc728b`. The historical findings below were independently traced at both snapshots and are fixed in the current branch. No additional defects confined to the original add commit were confirmed.

## Historical findings at the original add snapshot

Both issues already existed in the controller before `373f854f` and affected the new CLI add path. They were documented in the previous review and fixed by `07825f1c`. They are not current findings.

### P2: Ordinary creation HTTP failures reported account denial, fixed

Original location, with line numbers at `373f854f`: `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:953`

- Trigger: an authorized account reaches its per-region client limit while the region has free capacity, then runs `cloudgateway add sanjose "Mac mini"`. Preparation succeeds, but the POST returns HTTP 409. HTTP 500/503 follows the same classification path.
- User impact: CLI reports `access_denied`, exit 3, and an auth recovery hint for a client-limit or server failure while the account remains authorized. Signing in cannot resolve that condition.
- Causal trace: `/Users/alexbrodsky/GitHub/CloudGateway/Backend/API/src/firebase.py:574` checks region capacity separately from the owner limit. `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayControlPlaneClient.swift:252` maps 401/403 to `apiAccessDenied` and other non-2xx to `accessDenied`. `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacInventoryService.swift:139` forwards the creation error. The old controller catches ordinary `accessDenied` explicitly and produces `.failed(.accessDenied)`.
- Verification: read the original source with `git show`, confirmed the same catch exists in its parent, and inspected the fix diff and current catch at `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:1124`. Current HEAD reserves auth handling for the actual denial cases and treats an ordinary error after attempted creation as unknown, with retained authorization.
- Minimal fix: remove the ordinary `accessDenied` catch from the auth classification and use the conservative attempted-creation path. This is already implemented.
- Existing evidence: `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:3443` runs shared HTTP decoding through controller/IPC/CLI for 401/403/409/500/503 in text and JSON, checking retained authorization and one POST. Inspected, not run in this review.

### P2: Accepted creation blocked an independent local stop, fixed

Original locations, with line numbers at `373f854f`:

- `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift:430`
- `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:916`
- `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:1049`

Trigger: leave an owned VPN connected, confirm add, hold its POST or final inventory read, then run `cloudgateway down` from another caller. Target Disconnect is also affected.

User impact and cause: IPC rejects stop while add occupies the single pending/running slot. The domain independently rejects it because creation owns `commandTask` and stop requires that task to be absent. A slow cloud-only operation blocks the user's local stop.

Verification: read both original admission gates and the same code in the add commit's parent. Current `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift:437` permits stop beside creation and retains separate pending/running slots. Current `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:649` admits stop independently of `creationTask`. Creation and stop retain separate outcomes.

Minimal fix: separate creation ownership from local stop at both IPC and domain admission layers while preserving each completion/result. This is already implemented. Existing fixtures at `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:4156`, `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:4223`, and `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:4298` cover held POST/final inventory, both reservation/confirmation orders, completion order, exactly one POST, and account changes. Inspected, not run in this review.

## Inspected current behavior

- Parsing: `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIArguments.swift:373` requires region and name, trims the name, enforces scalar/byte bounds, and rejects terminal controls before connecting. The backend's 80-character name contract agrees.
- Region selection: `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLISelectors.swift:32` prefers an exact full ID, otherwise matches normalized display name or city alias and rejects ambiguity. `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIMutations.swift:49` uses prepared enabled regions, including regions absent from current client inventory, and requires known free capacity before reservation.
- Preparation: `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift:628` owns the preparation task, propagates caller cancellation, and bounds its lifetime. The production closure at `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift:99` captures the domain's session-bound creation context. A stale closure cannot create under a replacement session.
- Auth failure during preparation: the best-effort snapshot at `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIMutations.swift:65` preserves denied/signed-out states. Its cancellation check and common caller deadline remain intact. This fix was already included in the final original add commit.
- Reservation/confirmation: `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift:429` validates preparation before reserving. Confirmation at `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift:492` checks the reserved session and preparation expiry, consumes the context, and starts controller-owned work. `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIMutations.swift:148` writes acceptance before confirming. Output failure leaves work unconfirmed.
- Duplicate prevention: `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerRequests.swift:56` checks payload digests and durable bounded receipts. Repeated confirmation returns the retained operation. After confirmation, caller timeout/cancellation detaches observation and does not cancel or automatically resubmit creation.
- Production creation: `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:1085` checks access and session around asynchronous boundaries, preserves verified creation when final inventory fails, and does not install/connect a VPN profile. `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacInventoryService.swift:139` checks cancellation/current account after token retrieval and after the HTTP response.
- Results: `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIRecords.swift:240` retains typed warnings/errors and permits coarse results after account redaction. `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIRenderer.swift:44` prints creation success only for the completed result. Unknown/failed results do not print a created-client claim. JSON carries the requested normalized name and canonical region.

## Tradeoffs and limits

The add command intentionally leaves VPN state unchanged and directs users to list inventory for the new UUID. Uncertain creation is not automatically retried. The controller conservatively marks creation attempted before the adapter's token/POST work, so some failures with no actual dispatch can still be unknown. This is existing conservative behavior, not a new defect. Account-bound detailed outcomes are intentionally redacted after logout/session replacement, so an actual denial that signs the account out can leave the CLI with coarse `command_failed` rather than the old session's typed auth outcome.

Replay protection is bounded, and in-memory result retention is bounded. These are existing documented limits, not a guarantee of permanent request idempotency or durable completed results.

Reviewed the original add diff, current integration changes, relevant production paths, existing CLI add/parser/output fixtures, controller HTTP fixtures, and creation/stop/session fixtures. Static inspection only. No tests, builds, signed IPC checks, live Firebase/HTTP, Keychain, NetworkExtension, cloud/VPN calls, or external review comments were performed. Prior validation logs are historical evidence only. Only this report was written by this reviewer. No production/test files, index state, branches, or commits were changed by this reviewer.
