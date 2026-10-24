# macOS client removal core review

Status: review complete, no confirmed actionable findings. Updated 2026-10-24

- Reviewer: Codex review subagent, depth 1, `gpt-6.1-sol`, high reasoning
- Reviewer account: `codex_secure`, no external GitHub review posted
- Snapshot: `mac-remove-client` at `b5cc728b`, comparison `mac-cli..b5cc728b`
- Initial working tree and index were clean
- Scope: removal domain controller, IPC orchestration and request receipts, account cache, config coordinator, profile removal, production adapters, and backend API contract
- Existing add review fixes in `07825f1c` are present in the reviewed snapshot. Findings in earlier review notes are not assumed to remain open

## Confirmed findings

No confirmed actionable bugs in the assigned scope at this snapshot

## Verified scope

- Fresh access and authoritative inventory reads precede target resolution. The exact account namespace, unique region/client match, and authoritative owner govern deletion. Admin targets use their actual owner UID
- Durable cache eviction removes the target snapshot, authorized hash, and target selection before DELETE. Other configs and selection survive. Inventory publication filters verified removals
- The production HTTP helper checks cancellation, the captured session, and inactive profiles after token loading. It marks dispatch once and validates response owner, region, client, and removed status
- Verified remote success is recorded before cancellable cleanup. Cleanup and refresh failures preserve successful cloud removal with typed warnings. Non-auth HTTP failures and lost or invalid responses after dispatch remain uncertain
- IPC reservation is side-effect free. Confirmation rechecks session, build, update state, and domain admission. Accepted execution belongs to the controller and survives frontend loss. Creation and removal remain mutually exclusive, while the independent stop/creation slots preserve the add fix
- Duplicate request IDs check a digest before admission. Unconfirmed reservations expire after 30 seconds. Persisted receipts use the 600-second acceptance clock. Live running results do not expire, and retained terminal results use a separate 600-second completion clock. Account-bound outcomes require the original session token
- The config coordinator rejects concurrent install/start/removal work. Profile removal reloads the exact owned manager, checks identifier/reference and inactive status, removes it, and verifies absence. Missing target profiles succeed without selecting a different profile
- The production inventory adapter waits for server-backed Firestore snapshots, binds token use to the original user, and disables HTTP redirects. The backend authorizes the owner/admin tuple, removes the peer before the terminal client write, and returns the response fields checked by the client

## Evidence inspected

- [Domain controller](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:913), including session invalidation, deferred inventory, durable eviction, final publication, and typed outcomes
- [IPC orchestration](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift:429), [receipts and retained results](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerRequests.swift:59), and [wire contract](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerContracts.swift)
- [Cache eviction](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacAccountCache.swift:169), [coordinator](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacConfigCoordinator.swift), [profile metadata](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacProfileMetadata.swift), and [profile removal helper](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacProfileRemoval.swift)
- [Removal HTTP helper](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacClientRemovalRequest.swift), [production inventory adapter](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacInventoryService.swift), [production profile adapter](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacVPNProfileAdapter.swift), and [service wiring](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift:75)
- [Shared HTTP decoding](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayControlPlaneClient.swift:135), [backend removal route](/Users/alexbrodsky/GitHub/CloudGateway/Backend/API/src/routes.py:383), [authorization](/Users/alexbrodsky/GitHub/CloudGateway/Backend/API/src/repository.py:215), and [request/response models](/Users/alexbrodsky/GitHub/CloudGateway/Backend/API/src/models.py:58)
- Existing [controller and IPC coverage](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:2622) traces active/absent/admin/configless targets, cache write failure, session changes before and after dispatch, auth denial, generic HTTP errors, lost replies, cleanup and refresh failures, caller loss, concurrent reservations, stale inventory, restart replay, and result expiry
- Existing [HTTP helper coverage](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacClientRemovalRequestTests.swift), [profile helper coverage](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacProfileRemovalTests.swift), [coordinator coverage](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacConfigCoordinatorTests.swift:363), and [cache coverage](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacAccountCacheTests.swift:288) exercise production-used helper boundaries

## Existing behavior and documented tradeoffs

- Committed Keychain secrets remain retained. Failed cleanup or a crash can leave an orphan inactive profile. Removal never submits a stop or promises atomicity against external System Settings activation. These are explicit choices in the [removal contract](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-remove-controller.md)
- Uncertain DELETE is never retried automatically. A later authoritative read may restore a still-active client, and expired receipts allow manual reuse after the bounded replay window. Neither behavior proves that an earlier request failed
- In-memory retention remains bounded to the current result per command/creation slot. A later command replaces the previous command result. The single-result behavior already existed in `mac-cli`, and the independent creation slot preserves concurrent add/stop outcomes
- Shared HTTP errors other than 401/403 use a broad error type. Removal correctly checks dispatch evidence first and reports uncertainty. The ordinary add-error classification and stop-during-creation defects documented in older reviews were fixed in `07825f1c`, so they are not current removal findings

## Validation and limitations

Source review and inspection of existing coverage only. No tests, builds, live cloud calls, VPN operations, signed IPC, Keychain, or NetworkExtension runtime checks run by this reviewer. The parent owns shared validation. Only this assigned report may be edited. No production/test code, index, commit, branch, or external review changes
