# ACL-D: Client-to-Client ACL — Web + Apple Client Review

Scope: `bc7d99a..HEAD`, web and Apple client surfaces for `Policy/{regionId}`
status display (Server Health), per `TODO/review/00-review-plan.md` and
`TODO/account-scoped-acl.md` ("Firestore model" / "Dashboard requirements").

## Reviewed

- [x] `Frontend/Web/src/helpers/policyHelper.ts`
- [x] `Frontend/Web/src/helpers/__tests__/policyHelper.test.ts`
- [x] `Frontend/Web/src/pages/ServerHealth.tsx`
- [x] `Frontend/Web/src/pages/__tests__/ServerHealth.test.tsx`
- [x] `Frontend/Web/src/helpers/APIHelper.ts`
- [x] `Frontend/Web/src/helpers/__tests__/APIHelper.test.ts`
- [x] `Frontend/Web/src/helpers/firebaseDbHelper.ts`
- [x] `Frontend/Web/src/components/RegionSyncCard.tsx`
- [x] `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayPolicyStatus.swift`
- [x] `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayFirestorePolicyMapper.swift`
- [x] `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayServerHealthViewModel.swift`
- [x] `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayRegionSyncParsing.swift`
- [x] `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayPassiveContracts.swift`
- [x] `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayAppServiceFacade.swift`
- [x] `Frontend/Apple/iOS/CloudGateway/ServerHealthView.swift`
- [x] `Frontend/Apple/iOS/CloudGateway/CloudGatewayIOSPlatformAdapters.swift`
- [x] `Frontend/Apple/iOS/CloudGateway/CloudGatewayScreenshotFixtures.swift`
- [x] `Frontend/Apple/CloudGatewayKit/Tests/.../CloudGatewayPolicyStatusTests.swift`
- [x] `Frontend/Apple/CloudGatewayKit/Tests/.../CloudGatewayServerHealthViewModelTests.swift`
- [x] `Frontend/Apple/CloudGatewayKit/Tests/.../CloudGatewayRegionSyncParsingTests.swift`
- [x] `Frontend/Apple/CloudGatewayKit/Tests/.../MockGatewayService.swift`
- [x] `Frontend/Apple/CloudGatewayKit/Tests/.../CloudGatewayAppServiceFacadeTests.swift`
- [x] `Frontend/Apple/CloudGatewayKit/README.md`
- [x] `Frontend/Apple/iOS/README.md`
- [x] `Backend/Firebase/firestore.rules` (cross-check only)

## Web/iOS parity matrix

| Behavior | Web file:line | Swift file:line | Matches? |
| --- | --- | --- | --- |
| Missing-field usability gate (mapHashV4/V6, rowCount, updatedAt all required) | `policyHelper.ts:44-52` (`isPolicyDocUsable`) | `CloudGatewayPolicyStatus.swift:96-98` | Yes |
| `rowCount` numeric coercion | `policyHelper.ts:20-22` `numberOrNull` (any finite JS number, incl. fractional/negative) | `CloudGatewayFirestorePolicyMapper.swift:63-66` `rowCount(_:)` (`Int(exactly:)`, rejects fractional, accepts negative) | Diverges on fractional rowCount only (web: usable; Swift: `unreadable`). Documented as deliberate (host never writes fractional) and untestable-from-outside since the write path is trusted-admin-SDK-only per `firestore.rules:61-64` — not a reachable finding. Negative/zero handling matches. |
| `rowCount` overflow/precision (`Int(Double)` trap class) | N/A (JS numbers) | `CloudGatewayFirestorePolicyMapper.swift:59-65` uses `Int(exactly:)` — correctly fixed, no trap | Swift-only; fixed correctly here (contrast with the still-open mesh-mapper instance of this bug, out of this chunk's scope, already flagged in `12-ss-apple.md`) |
| `updatedAt` Timestamp/Date coercion | `coerce.ts:19-29` `dateOrNull` (accepts Date, ISO string, epoch number, or `toDate()`-bearing object) | `CloudGatewayFirestorePolicyMapper.swift:44-46` `date(_:)` (accepts `Date` only) | Diverges in the mapper's own contract, but not in practice: `CloudGatewayIOSPlatformAdapters.swift:63-70,111-126` recursively converts every Firestore `Timestamp` to `Date` before the mapper runs, and the doc's only writer (`Backend/API/src/firebase.py`, admin SDK) always writes a server `Timestamp`. Verified reachable-only path is Date; no finding. |
| `mapHashV4`/`mapHashV6` string coercion (trim-check, keep untrimmed value) | `coerce.ts:3-5` `stringOrNull` | `CloudGatewayFirestorePolicyMapper.swift:29-32` `string(_:)` | Yes, byte-for-byte |
| Consensus/drift algorithm (strict-majority-or-drift-all) | `policyHelper.ts:60-92` | `CloudGatewayPolicyStatus.swift:100-135` | Yes |
| Disabled-region exclusion from comparison | `policyHelper.ts:107-137` | `CloudGatewayPolicyStatus.swift:54-89` | Yes |
| State derivation (`ok`/`drifted`/`disabled`/`never-synced`/`unreadable`) | `policyHelper.ts:53,95-135` | `CloudGatewayPolicyStatus.swift:34-36,71-88` | Yes |
| Collection-level read-failure isolation (Policy failure must not blank Mesh/Regions, and must not collapse to "never-synced" for every region) | `ServerHealth.tsx:206-256` (`policyPromise` local catch inside `Promise.all`, `policyLoadFailed` state) | `CloudGatewayServerHealthViewModel.swift:170-224` (`fetchServerHealthState`/`apply`, `policyLoadFailed`) | Yes |
| Stale/out-of-order load result handling for Policy specifically | Covered generically by `loadGenerationRef`/`isCurrent` (`ServerHealth.tsx:168-177,199-257`); no policy-specific race test | `loadGeneration`/`beginLoadGeneration` (`CloudGatewayServerHealthViewModel.swift:38-45,84-96`); explicit test `testStalePolicyResultIsDroppedWhenANewerLoadCompletesFirst` | Same mechanism (regions/mesh/policy set together under one generation guard in both); Swift has an extra explicit regression test, web doesn't, but the shared-plumbing argument means this isn't a live gap — see Clean notes |
| Sync-response `policyApplied`/`policyRowCount`/`policyStatusWritten` parsing (absent = older host = unknown; present-wrong-type or explicit null = malformed; independently validated, no cross-field requirement enforced) | `APIHelper.ts:159-165,548-557,591-593` `isNonNegativeInteger` | `CloudGatewayRegionSyncParsing.swift:134-166` `nonNegativeInt` | Yes, including the explicit-null and wrong-type rejection and independent (non-cross-validated) field checks |
| `policyRowCount` large-value precision (sync response, not Firestore doc) | JS `Number.isInteger`/`isFinite` (loses precision above 2^53, inherent to JSON-in-JS, not ACL-specific) | Decoded as native `Int` from JSON via custom `JSONValue`, exact up to `Int64.max` | Swift is strictly more precise here; not reachable in practice (rowCount is a small nftables row count) |
| Sync-outcome UI copy for `policyApplied`/`policyStatusWritten` (failed pass / status-not-saved banners) | `RegionSyncCard.tsx:103-118` | `ServerHealthView.swift:799-811` | Yes, same copy verbatim |
| Row rendering: rowCount fallback, updatedAt fallback/format | `ServerHealth.tsx:688-691` (`row.doc.rowCount ?? "-"`, `toLocaleString()`) | `ServerHealthView.swift:444-446` (`doc.rowCount.map(String.init) ?? "-"`, `.formatted(date:.abbreviated, time:.shortened)`) | Yes (same fallback; date format differs only in cosmetic locale rendering, both device-local timezone) |
| Staleness threshold / time-since-last-update state | Not implemented — Policy state is hash-drift-based only, no time component (contrast with `meshHelper.ts`'s `getMeshStaleness`) | Not implemented, same | Yes (both intentionally omit it; out of scope to invent) |
| Privacy: no uids/emails/client names/addresses/keys in the Policy doc, UI copy, or screenshot fixtures | `ServerHealth.tsx:638-641` (copy), `policyHelper.ts`/`firebaseDbHelper.ts` (fields are hash/count/date only) | `ServerHealthView.swift:387` (copy), `CloudGatewayPolicyDoc` (hash/count/date only), `CloudGatewayScreenshotFixtures.swift:151-163` (synthetic `aaaa…`/`bbbb…` hashes) | Yes |

## Findings

(appended below as confirmed)

## Summary

No findings in this chunk. The web (`policyHelper.ts`/`ServerHealth.tsx`/`APIHelper.ts`) and
Apple (`CloudGatewayPolicyStatus`/`CloudGatewayFirestorePolicyMapper`/
`CloudGatewayServerHealthViewModel`/`CloudGatewayRegionSyncParsing`) implementations of the
`Policy/{regionId}` status surface are a deliberate, well-documented, near-line-for-line port of
each other, with symmetric test coverage on both platforms for every malformed/hostile-input case
checked (missing fields, wrong types, explicit null, NaN/Infinity, fractional and negative
numbers, the `Int(Double)` boundary-overflow trap class, explicit-null vs. absent-field
compatibility semantics, collection-level read-failure isolation, and generation/staleness
guarding). The one instance of the `Int(Double)` conversion trap that remains open in this
diff range is in `CloudGatewayFirestoreMeshMapper.swift`, which is out of this chunk's scope
(SS-C) and is already recorded there. Privacy is clean: both clients render/store only hash and
count fields, never per-user data, and the screenshot fixtures use synthetic placeholder hashes.
The two documented Web/Swift divergences (fractional `rowCount` handling; `updatedAt` accepting
only `Date` on iOS vs. also ISO-string/epoch/`toDate()` on web) are both non-reachable given the
actual write path (admin-SDK-only Firestore writes, and Timestamp-to-Date conversion happening
in the iOS repository before the mapper ever runs), so neither rises to a reportable divergence.

## Clean (no findings)

- `Frontend/Web/src/helpers/policyHelper.ts` / `Frontend/Web/src/helpers/__tests__/policyHelper.test.ts` — verified `parsePolicyDocument`, `isPolicyDocUsable`, `majorityValue`/`isDrifted` consensus math, and `buildPolicyStatusRows`'s per-region state derivation (disabled/never-synced/unreadable/drifted/ok); every branch has a direct unit test; no throw path found for malformed input.
- `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayPolicyStatus.swift` / `CloudGatewayFirestorePolicyMapper.swift` / `Tests/.../CloudGatewayPolicyStatusTests.swift` — verified this is a faithful, deliberately-documented port of `policyHelper.ts`; confirmed the `rowCount` mapper already uses `Int(exactly:)` (the boundary-trap class of bug already fixed here, still open in the unrelated mesh mapper per `12-ss-apple.md`); confirmed `date(_:)`'s `Date`-only contract is safe in practice because `CloudGatewayIOSPlatformAdapters.swift` converts every `Timestamp` before the mapper runs; NSNumber/CFBoolean handling for `rowCount` checked and correct; tests cover `0x1p63`/`-0x1p65`/`1e300`/NaN/Infinity/fractional/negative/zero and are symmetric with the TS suite.
- `Frontend/Web/src/pages/ServerHealth.tsx` (Client isolation panel) / `Frontend/Web/src/pages/__tests__/ServerHealth.test.tsx` — verified `policyPromise`'s local `.then(...)` catch inside `Promise.all` isolates a Policy read failure from Regions/Mesh, `policyLoadFailed` renders a dedicated failure card instead of collapsing to per-region "never-synced", and drift/disabled/unreadable/never-synced copy matches the derived state; confirmed generation-guard (`loadGenerationRef`/`isCurrent`) covers Policy the same way it covers Regions/Mesh (they're all set from one `loadServerHealthData` call under one guard), so the lack of a policy-specific stale-race test is not a live gap.
- `Frontend/Web/src/helpers/APIHelper.ts` (`parseRegionSyncResponse` policy fields) / `Frontend/Web/src/helpers/__tests__/APIHelper.test.ts` — verified `policyApplied`/`policyRowCount`/`policyStatusWritten` are each independently validated (absent = older host = unknown, not required; present-and-wrong-type or explicit `null` = malformed, rejects whole response); `isNonNegativeInteger` correctly rejects NaN/Infinity/fractional/negative; test suite covers all three fields' malformed and absent cases.
- `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayRegionSyncParsing.swift` / `Tests/.../CloudGatewayRegionSyncParsingTests.swift` — verified this ports `parseRegionSyncResponse` field-for-field via the absent/null/wrong-type-preserving `JSONValue` tree; `nonNegativeInt` rejects fractional (via `.int`-only `JSONValue` case) and negative; explicit-null rejection and no-cross-field-dependency behavior both match the TS parser and are explicitly tested (`testPolicyRowCountParsesIndependentlyOfAbsentPolicyApplied`, etc).
- `Frontend/Web/src/helpers/firebaseDbHelper.ts` (`getPolicyDocs`) / `Frontend/Apple/iOS/CloudGateway/CloudGatewayIOSPlatformAdapters.swift` (`fetchPolicyDocs`, `convertingTimestamps`) — verified both read the `Policy` collection unfiltered and always populate one doc per document ID via a coercion function that never throws/returns nil, so the "unreadable" state is reachable and no document is silently dropped; confirmed against `Backend/Firebase/firestore.rules:61-64` that `Policy/*` is admin-get/list, client-unwritable (`write: if false`), matching both files' comments.
- `Frontend/Web/src/components/RegionSyncCard.tsx` / `Frontend/Apple/iOS/CloudGateway/ServerHealthView.swift` (`successCard`) — verified the `policyApplied === false` and `policyApplied === true && policyStatusWritten === false` banner copy and conditions are identical between platforms.
- `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayServerHealthViewModel.swift` / `Tests/.../CloudGatewayServerHealthViewModelTests.swift` — verified `apply`/`recomputeDerivedState` treat an empty `policyDocs` map as ambiguous only when not `policyLoadFailed` (keeps `policyRows` empty rather than fabricating "never-synced" rows during an outage); reviewed the `fetchServerHealthState` `Result`-capturing pattern that keeps a Policy throw from ever failing Regions/Mesh; test suite explicitly covers load-failure, recovery, Regions-failure-drops-a-separately-succeeded-Policy-result, syncAll re-read, and generation-based staleness for Policy.
- `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayPassiveContracts.swift` (`CloudGatewayRegionSyncResponse`/`CloudGatewayClientRepository.fetchPolicyDocs`) — verified the struct's `policyApplied`/`policyRowCount`/`policyStatusWritten` types and doc comments match the web/API contract; no coercion logic lives here.
- `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayAppServiceFacade.swift` — `fetchPolicyDocs` is a one-line pass-through to the injected repository; nothing to find.
- `Frontend/Apple/iOS/CloudGateway/ServerHealthView.swift` (Client isolation panel, rows 380-534) — verified state-label/sentence/background/foreground/border mappings are exhaustive over `CloudGatewayPolicyRegionState` and match `ServerHealth.tsx`'s `policyRowClasses`/`policyStateLabel` 1:1; rowCount/date rendering uses the same "-" fallback as web.
- `Frontend/Apple/iOS/CloudGatewayScreenshots/CloudGatewayScreenshotFixtures.swift` (`makePolicyDocs`) — verified only synthetic placeholder hashes (`"aaaa…"`/`"bbbb…"`) and a small integer `rowCount`/fixed `updatedAt` are used; no real-looking uid/email/IP/key data that could leak into App Store screenshots.
- `Frontend/Apple/CloudGatewayKit/Tests/.../MockGatewayService.swift`, `Tests/.../CloudGatewayAppServiceFacadeTests.swift` — verified the mock's `fetchPolicyDocs` gate/error/call-count plumbing is exercised by the view-model tests, and the facade test confirms `fetchPolicyDocs` passes the repository's map through unchanged (`policyDocs == ["us-a": policyDoc]`).
- `Frontend/Apple/CloudGatewayKit/README.md`, `Frontend/Apple/iOS/README.md` — verified both describe the Policy-read-failure isolation and the "row counts and hashes only, never uids/emails/client names/addresses/keys" privacy contract accurately against the actual implementation; no drift found.
