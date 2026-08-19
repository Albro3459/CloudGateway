# Review: iOS ACL Policy Parity (`4c0c604` + `74984eb`)

Scope: the `TODO/ios-policy-parity.md` plan doc and the iOS/AppCore implementation
in `74984eb`, reviewed against the web reference it claims parity with
(`policyHelper.ts`, `coerce.ts`, `ServerHealth.tsx`, `RegionSyncCard.tsx`,
`APIHelper.ts`, `firebaseDbHelper.ts`), plus `Backend/Firebase/firestore.rules`,
`Backend/Firebase/schema.ts`, and `Backend/API/src/firebase.py` for the write side.

Method: three parallel reviewers - derivation/mapper/security, UI/fixtures/docs, and
view-model/parsing/contracts/tests - each reading the actual code rather than trusting
the plan's claims or the passing test names. `./scripts/test.sh apple` was re-run
independently.

Status: COMPLETE. All three findings fixed - see "Resolution" at the end.

Severity key: **P1** correctness/security bug - **P2** parity or robustness gap -
**P3** nit / doc drift.

---

## Summary

One real defect, both of the remaining items doc-level. The port is unusually faithful:
derivation, parsing strictness, failure isolation, panel copy, and severity colors all
match the web source closely enough to have been checked line-by-line without turning up
a semantic divergence.

| # | Sev | Finding | Status |
| --- | --- | --- | --- |
| 1 | P2 | `rowCount` mapper traps (`Int(_: Double)`) on exactly 2^63; the guard meant to prevent it is off by one ULP, and its test uses a value that never reaches the bug | fixed |
| 2 | P3 | `updatedAt` coercion silently narrower than web `dateOrNull`, while the comment claims full `coerce.ts` parity | fixed |
| 3 | P3 | `TODO/account-scoped-acl.md` still says iOS parity "remains an open release blocker" in two places after the blocker was closed | fixed |

No P1. No security findings: the surface carries counts and hashes only, `Policy/*` is
admin-read / no-client-write, and iOS never writes it.

---

## Substantive findings

### [P2] `rowCount` boundary value traps: `Int(_: Double)` crash at exactly 2^63
**Area:** mapper
**File:** `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayFirestorePolicyMapper.swift:56-60`

`integer(_:)` guards with `value <= Double(Int.max)`, but `Double(Int.max)` is not
`Int.max`: `9223372036854775807` is not representable as a `Double` and rounds up to
`9223372036854775808.0` (2^63). So the guard admits `2^63` exactly, and the very next
line `Int(value)` traps on it. The comment above the guard claims it exists precisely so
"a corrupt Firestore number must be rejected before the conversion rather than after it,"
and the type doc claims the mapper "never throws" - both are false for this one value.

Verified locally on this machine (Swift 5.10 effective):

```
GUARD PASSED - Int(9.223372036854776e+18) would trap
```

and running the real conversion aborts with `_assertionFailure` (Double value cannot be
converted to Int because it is outside the representable range).

Failure scenario: a `Policy/{regionId}` document whose `rowCount` is written (or corrupted)
to the double `9.223372036854776e18` crashes the iOS app - a hard abort, not a caught error -
the moment an admin opens Server Health, and keeps crashing on every retry until the
document is fixed. `1.0e19` is correctly rejected; only the boundary value gets through.
Note the web side has no such failure mode (`numberOrNull` accepts any finite number),
so this is an iOS-only regression introduced by the `Int?` narrowing.

Fix: use a strict upper bound, or drop the hand-rolled range check entirely:

```swift
private static func integer(_ value: Double) -> Int? {
    Int(exactly: value.rounded(.towardZero))   // or: guard value >= -0x1p63, value < 0x1p63
}
```

`Int(exactly:)` already returns nil for NaN, infinity, fractional, and out-of-range values,
which would collapse `rowCount(_:)`'s remainder check and `integer(_:)` into one call.

Reachability, stated honestly: `Policy/*` is Admin-SDK-write-only in `firestore.rules:61-64`
and `Backend/API/src/firebase.py:805` writes `status.row_count`, a Python `int`, so no client
- hostile or otherwise - can inject this value today. This is a latent trap in code whose
stated contract is that it cannot trap, not a live crash. Rated P2 for that reason.

Related, same file: the unit test that is supposed to cover this,
`CloudGatewayPolicyStatusTests.testRowCountRejectsAValueBeyondIntsRange`
(`Tests/CloudGatewayAppCoreTests/CloudGatewayPolicyStatusTests.swift`), uses `1e300`, which
the guard does reject. The one input that gets through - the boundary itself - is untested,
so the suite reads as proving a property it does not prove. Its comment even states the
exact hazard ("`Int(_: Double)` traps rather than returning nil, so an out-of-range number
has to be rejected before the conversion or a corrupt doc crashes the app").

### [P3] `updatedAt` coercion is narrower than the web's `dateOrNull`, undocumented as a divergence
**Area:** mapper
**File:** `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayFirestorePolicyMapper.swift:35-37`

The plan says coercion "matches `Frontend/Web/src/helpers/coerce.ts`", and the `rowCount`
divergence is documented at length - but the `updatedAt` divergence is not. Web
`dateOrNull` accepts a `Date`, an ISO string, an epoch number, and any `{ toDate() }`
object; the Swift helper accepts `Date` only. A `Policy/*` doc whose `updatedAt` was ever
written as a string or number renders `unreadable` on iOS and fine on web.

Today this is only theoretical - `Backend/API/src/firebase.py:806` writes
`_server_timestamp()`, and the iOS repository converts `Timestamp` -> `Date` recursively
before the mapper runs - so `Date`-only is the right narrow contract. The gap is the
comment, which claims full `coerce.ts` parity while silently narrowing one of the three
coercions. The existing test
(`testUpdatedAtAcceptsADateAndRejectsAStringOrNumber`) already pins the narrower behavior,
so only the doc comment needs a sentence, matching the one `rowCount` already carries.

### [P3] Stale "open release blocker" wording left in two places after the blocker was closed
**Area:** docs
**File:** TODO/account-scoped-acl.md:172-173, TODO/account-scoped-acl.md:200-201
**Description:** Commit 74984eb updates the "Open release blockers" section (line ~390) to `*Closed:* implemented per TODO/ios-policy-parity.md` and checks off the checklist item at line 445, but leaves two other summary passages unchanged:
- Line 172-173 (end of "Review remediation" intro): "The iOS Server Health parity work is deferred to its own plan and remains an open release blocker."
- Line 200-201 (accepted dispositions bullet): "**iOS parity is deferred to its own plan, but not to a later release.** See 'Open release blockers'."

Both statements are now false/stale - the work is done and the blocker is closed - and the second one points a reader at the "Open release blockers" section expecting to find iOS parity still listed as open, when it is now marked closed there. This is exactly the kind of self-contradicting doc state the plan's own "Docs" section says the pass was supposed to fix across "all six files above." A reader skimming top-to-bottom hits the stale "remains an open release blocker" line before reaching the corrected section further down.

---

## Notes (not defects)

### Web's explicit-null docs-map case has no Swift analogue (correct, worth noting)
**Area:** derivation
**File:** `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayPolicyStatus.swift:56`

`policyHelper.test.ts` has two distinct never-synced cases - "region with no Policy doc"
(explicit `null` value in the `Map`) and "region missing entirely from the docs map". The
Swift port has only the second, because `[String: CloudGatewayPolicyDoc]` cannot hold a
null and the two collapse into one lookup. This is the right modeling choice and the type
doc calls it out. Noted only so the 17-vs-16 test-count difference against the TS suite is
not mistaken for a missed port.

---

## Areas checked and found clean

### Clean: derivation port is faithful
**Area:** derivation

`buildPolicyStatusRows`, `isPolicyDocUsable`, `majorityValue`, and `isDrifted` are a
line-accurate port of `policyHelper.ts`. Checked specifically:

* Strict-majority arithmetic (`winnerCount * 2 > values.count`) is identical, so the
  unspecified Swift `Dictionary` iteration order genuinely cannot change the result - a
  strict majority is unique. The plan's reasoning here is correct.
* `allValues.count >= 2` lone-region guard, disabled-region exclusion from `usable` while
  still rendering `doc`, and unreadable-excluded-from-comparison all match.
* The `compactMap`/`guard let` treatment of the hashes avoids the force-unwraps the TS
  gets via `as string`, so tightening `isPolicyDocUsable` later cannot become a trap.
* Ordering is preserved (`regions.map`), matching the web's row order.

### Clean: no PII in the shared policy types
**Area:** security

`CloudGatewayPolicyDoc` carries only `regionId`, two hashes, a count, and a timestamp. No
uid, email, client name, address, or key reaches AppCore from `Policy/*`, and the mapper
reads only those four keys, so an unexpected field added server-side cannot leak through.
`Policy/{regionId}` is `allow get, list: if isAdmin()` / `allow write: if false`
(`Backend/Firebase/firestore.rules:61-64`) and iOS only ever reads it, matching the
"observability-only" rule in the plan.

### Clean: UI, security, screenshot fixtures, docs
**Area:** ui | security | fixtures | docs

No P1/P2/P3 findings in this scope. Verified clean:

* `ServerHealthView.swift` `clientIsolationPanel`, `policyRow`, state label/sentence/color
  helpers, and `policyLoadFailed` card text/wording/severity color all match web
  `Frontend/Web/src/pages/ServerHealth.tsx` (~lines 636-712) verbatim, including the
  per-state paragraph text, the "Never synced" empty-doc omission, the drift
  IPv4-only/IPv6-only/both wording, and the ok/drifted/unreadable/disabled/neverSynced
  color mapping (`policyRowClasses` in `ServerHealth.tsx:64-69` vs
  `policyRowBackground/Foreground/Border` in `ServerHealthView.swift`) - danger for
  drifted+unreadable, success for ok, neutral inset for disabled+neverSynced.
* `RegionSyncResultCard`'s `policyApplied == false` and
  `policyApplied == true && policyStatusWritten == false` notes match
  `RegionSyncCard.tsx:103-118` text and severity (warning vs muted/secondary) verbatim,
  and correctly leave the overall card outcome successful in both cases.
* Header/subtitle and file-level comment updates accurately describe the new
  client-isolation feed alongside mesh/link/peer-sync.
* `CloudGatewayPolicyStatus.buildPolicyStatusRows` (AppCore, cross-checked since the view
  consumes it directly) confirms `.unreadable` rows always carry a non-nil `doc` (present
  but not fully usable), so `policyRow`'s `if let doc = row.doc` branch renders partial
  rowCount/updatedAt/hash chips for unreadable regions exactly like web's
  `{row.doc && (...)}` block - no nil-as-confident-claim issue, no crash.
* Security: `PolicyHashChip` only ever receives `mapHashV4`/`mapHashV6` strings (via
  `CloudGatewayPolicyDoc`, itself built only from those two hashes + rowCount + updatedAt
  + regionId by `CloudGatewayFirestorePolicyMapper`). No uid/email/client name/address/key
  reaches the view or the `UIPasteboard.general.string` copy path. Copy pattern
  (`UIPasteboard` + `UINotificationFeedbackGenerator` + transient `didCopy` label) is
  identical to the existing `ContentView.copyAllDetails` (`ContentView.swift:1563-1570`).
* `CloudGatewayIOSFirestoreRepository.fetchPolicyDocs()` only reads `Policy/*` (comment
  correctly notes Admin-SDK-write-only, client never writes); mapper narrows raw Firestore
  doc data down to the 5 known fields before it ever reaches the view, so no risk of an
  unexpected extra Firestore field leaking to the UI.
* `CloudGatewayScreenshotFixtures.swift`: `makePolicyDocs` produces deterministic, fixed
  hash/rowCount/date values that intentionally agree across all fixture regions (comment
  says so), rendering an `ok` state - correct and non-misleading; sync outcome fixture sets
  `policyApplied: true, policyStatusWritten: true` consistently so no spurious warning
  notes appear in the screenshot target. `fetchPolicyDocs()` conformance added correctly.
* Docs: `Frontend/Apple/iOS/README.md`, `Frontend/Apple/macOS/README.md`,
  `Frontend/Apple/CloudGatewayKit/README.md`, and `docs/service-operations.md` edits all
  accurately describe delivered behavior (Policy/* read, observability-only/no-write,
  independent failure isolation, iOS listed alongside Web for the Sync All repair path and
  the policy display description). `TODO/ios-policy-parity.md`'s "Parity target" table and
  "Checklist" entries were spot-checked against actual symbols and all exist as claimed:
  `CloudGatewayPolicyStatus.swift`/`buildPolicyStatusRows`,
  `CloudGatewayFirestorePolicyMapper.policyDoc(documentId:data:)`, `fetchPolicyDocs()` on
  `CloudGatewayServicing`/`CloudGatewayClientRepository`/facade plus all conformers
  (`CloudGatewayIOSFirestoreRepository`, `MockGatewayService`, `FacadeRepositoryFake`,
  `CloudGatewayScreenshotService`), `@Published policyRows`/`policyLoadFailed` on the view
  model, `clientIsolationPanel`, and the `RegionSyncResultCard` notes.
* All `theme.*` tokens referenced by the new code (`dangerContent`, `dangerSoft`,
  `dangerSoftEdge`, `successSoft`, `successStrong`, `successSoftEdge`, `inset`,
  `contentSecondary`, `edgeSubtle`, `warningStrong`) exist in
  `Frontend/Apple/iOS/CloudGateway/CloudGatewayTheme.swift`.

Minor stylistic (below P3 threshold, not reported as findings): iOS hash-chip truncation
uses `.truncationMode(.middle)` vs web's CSS end-truncation (`truncate`), and iOS's
`accessibilityLabel` omits the hash value that web's `aria-label` includes - both are
inconsequential UX differences, not correctness or security issues.

### Clean: `CloudGatewayServerHealthViewModel` policy failure isolation
**Area:** view-model
**File:** `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayServerHealthViewModel.swift:83-240`

Traced `load()`, `syncAll()`, `fetchServerHealthState()`, `apply()`, and `recomputeDerivedState()` end
to end. Confirmed by reading (not just trusting the comments):

* `fetchServerHealthState()` starts all three unstructured `Task`s up front (so Policy runs
  concurrently with Regions/Mesh regardless of await order), awaits `policyTask.result` into a
  captured `Result` first, then `try await`s `regionsTask`/`meshDocsTask`. If either of those
  throws, the function throws before returning the tuple, so the already-completed Policy
  `Result` is discarded and `apply()` is never called - matches the plan's "a Regions or Mesh
  failure ... does not apply a separately completed policy result" and is exercised by
  `testRegionsFailureKeepsPageLevelErrorAndDoesNotApplyASeparatelySucceededPolicyResult`.
* `apply()` unconditionally sets `self.regions`/`self.meshDocs` before the `switch policyResult`,
  so a Policy failure can never blank fresh Regions/Mesh state - confirmed structurally, not just
  by the passing test.
* `recomputeDerivedState()` short-circuits `policyRows = []` whenever `policyLoadFailed`, rather
  than calling `buildPolicyStatusRows` on the now-empty `policyDocs`, so a failed read cannot
  manufacture `neverSynced` rows for every region.
* Both `load()` and `syncAll()`'s post-fan-out re-read route through the same
  `fetchServerHealthState()`/`apply()` pair, so Policy genuinely reloads after Sync All.
* The `loadGeneration`/`uid`/`togglingRegionIds` guards sit above `apply()` and gate the whole
  tuple (Regions+Mesh+Policy) together - there is no separate, ungated path for the Policy half,
  so a stale in-flight Policy result cannot outrun a newer load. Verified this isn't just
  test-asserted but structurally true: `apply()` is the only call site that touches
  `policyDocs`/`policyLoadFailed`, and every call to it is behind the same guard.

No race condition, stale-write, or error-swallowing bug found in this file.

### Clean: `CloudGatewayRegionSyncParsing` policy field strictness matches `APIHelper.ts`
**Area:** sync-parsing
**File:** `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayRegionSyncParsing.swift:134-168`

Compared line-by-line against `Frontend/Web/src/helpers/APIHelper.ts:550-593`
(`hasOwn(...) && typeof !== "boolean"` / `isNonNegativeInteger`):

* Absent key -> `dict["key"] == nil` -> field parses as `nil`, response still accepted. Matches
  `hasOwn(...)` false branch on web.
* Present explicit `null` -> `dict["key"]` is `.some(.null)` (not Swift-nil), so
  `dict["key"] != nil` is true and `nonNegativeInt`/`boolValue` reject `.null`, causing the whole
  `guard` to fail and `parse` to return `nil` (reject the response). Matches web's
  `hasOwn(...) && typeof value.x !== "boolean"` treating `null` as a bad type.
  the Swift port additionally tests this directly (`testRejectsExplicitNullPolicy*`), which the
  web suite does not exercise explicitly (web's `syncResponse()` fixture only ever omits the
  fields, it never sets them to literal `null`) - net effect is Swift has slightly *more*
  coverage here, not less.
- `nonNegativeInt` reuses the same helper as the pre-existing counter fields (`added`, `meshUpdated`,
  etc.), rejecting any `JSONValue` that isn't `.int` (so a JSON `12.0`/`1.5` decodes to `.double`,
  not `.int`, and is rejected) and any negative `Int`. Matches `isNonNegativeInteger`'s
  `Number.isInteger(value) && value >= 0`.
- No cross-field relationship is enforced among `policyApplied`/`policyRowCount`/`policyStatusWritten`,
  matching the web comment "rowCount and statusWritten are only ever present alongside a true
  policyApplied, but a present value of the wrong shape is still a malformed response" - i.e. that
  invariant is a documented *convention* the host follows, not something either parser enforces.
  Confirmed both parsers only ever check each field's own shape independently.

Test coverage (`CloudGatewayRegionSyncParsingTests.swift`) hits every case the web suite hits
(absent-all, false `policyApplied` success, full success, false `policyStatusWritten` success,
non-boolean rejection for both bool fields, negative/fractional `policyRowCount` rejection) plus
the explicit-null cases above. No vacuous assertions - each test reads a specific field off the
parsed result and asserts a concrete value or `nil`/rejection.

### Clean: contracts and iOS Firestore `Policy` read
**Area:** contracts
**File:** `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayPassiveContracts.swift:257,349`,
`Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayAppServiceFacade.swift:69,315`,
`Frontend/Apple/iOS/CloudGateway/CloudGatewayIOSPlatformAdapters.swift:61-70`

`fetchPolicyDocs()` on `CloudGatewayServicing`/`CloudGatewayClientRepository` is a straight
passthrough on the facade (`try await repository.fetchPolicyDocs()`), same shape as
`fetchMeshDocs()`. The iOS repository implementation is a structural mirror of `fetchMeshDocs()`:
reads `database.collection("Policy")`, recurses each document through the existing
`convertingTimestamps` before handing it to `CloudGatewayFirestorePolicyMapper.policyDoc`, and
keys the output dictionary by `document.documentID`. Any Firestore error (including
permission-denied) propagates as a thrown error out of `getDocuments`, which is exactly what the
view model's `Result` capture expects.

Compared to web's `getPolicyDocs()` (`Frontend/Web/src/helpers/firebaseDbHelper.ts:200-212`):
both populate the returned map only from documents actually present in the snapshot - neither
seeds entries for known-but-undocumented regions. So "region absent from the map" and "region
present with an unusable doc" are the same two cases on both platforms; no divergence for the
view model/derivation layer to compensate for. This matches the plan's "Absent vs. null" resolved
decision.

### Clean: facade/mock/fake test conformers
**Area:** tests
**File:** `Frontend/Apple/CloudGatewayKit/Tests/CloudGatewayAppCoreTests/MockGatewayService.swift:414-424`,
`Frontend/Apple/CloudGatewayKit/Tests/CloudGatewayAppCoreTests/CloudGatewayAppServiceFacadeTests.swift`

`MockGatewayService.fetchPolicyDocs()` follows the exact same call-count/gate/error-injection
shape as the pre-existing `fetchMeshDocs()`, so the concurrency tests that gate Policy while
leaving Regions/Mesh ungated (`testStalePolicyResultIsDroppedWhenANewerLoadCompletesFirst`,
`testUidMismatchDuringLoadDropsPolicyResultLikeMeshResult`) exercise a real race between two
`load()` calls rather than a scripted sequence - verified by reading `AsyncTestGate` usage and the
call-count-based `waitUntil` synchronization, not just trusting the test names. The facade test
addition is a plain passthrough assertion (`#expect(policyDocs == ["us-a": policyDoc])`) - non-
vacuous since `FacadeRepositoryFake.fetchPolicyDocs()` returns a mutable stored property the test
sets independently beforehand.

No test in this scope passes vacuously (e.g. asserting only `XCTAssertNotNil` on something
trivially non-nil, or asserting a default value that would hold with or without the code under
test). Each policy-specific view-model test asserts a value that would differ under a plausible
bug (wrong hash surviving a stale write, non-empty `policyRows` after a failed read, banner text
set on a policy-only failure, etc).

No P1/P2/P3 findings in this scope: view-model, sync-parsing, contracts, and their tests are a
faithful, race-safe port with no error-swallowing, stale-apply, or vacuous-test issues found.

---

## Verification performed

### Verified: the plan's Apple validation claim is real
**Area:** validation

`./scripts/test.sh apple` was re-run independently during this review on the commit under
review and exited 0: Periphery scans (app project, Kit tests, Firebase adapter tests),
CloudGatewayKit/AppCore package tests, Firebase auth adapter tests, and the unsigned
no-device iOS build all reported OK, ending in `** BUILD SUCCEEDED **` /
`All checks passed.` The "Validation record" section of `TODO/ios-policy-parity.md` is
accurate for the Apple target. The full-suite claim (API/web/infra/Firebase) was not
re-run here.

---

## Resolution

All three findings were fixed in the follow-up commit on this branch.

**1 (P2), `rowCount` trap.** `integer(_:)` and the separate
`truncatingRemainder` check were replaced with a single `Int(exactly:)`, and the
helper deleted:

```swift
private static func rowCount(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return Int(exactly: number.doubleValue)
}
```

`Int(exactly:)` rejects NaN, infinity, fractional, and out-of-range values in one
step, so the off-by-one-ULP range check is gone rather than corrected. Behavior is
identical for every input the suite already asserted (`12.0`, `12`, `-1`, `0`,
`3.5`, NaN, infinity, `1e300`, `NSNumber(true/false)`, a string) - verified by
running the replacement against all of them before the edit - and `2^63` now
returns nil instead of trapping. The doc comment records why a hand-rolled range
check must not come back.

`testRowCountRejectsAValueBeyondIntsRange` now covers `0x1p63` and `-0x1p65`
alongside `1e300`, and `testRowCountAcceptsIntegralDoubleIntNegativeAndZero`
pins `-0x1p63` to `Int.min` - the far edge that is exactly representable and
genuinely valid - so a future reviewer cannot narrow the accepted range by
mistake either.

**2 (P3), `updatedAt` narrowing.** Comment-only. The type-level doc no longer
claims flat `coerce.ts` parity; it points at the two deliberate narrowings, and
`date(_:)` now carries the same kind of divergence note `rowCount` already had.

**3 (P3), stale blocker wording.** Both passages in `TODO/account-scoped-acl.md`
now read as shipped and link the parity plan. The accepted-dispositions bullet
keeps the point it exists to make - iOS parity belongs to this release, not a
later one.

Validation: `./scripts/test.sh apple` re-run after the fixes, exit 0, all stages
OK including the three Periphery scans (confirming the deleted `integer(_:)` left
no dead-code residue) and the unsigned no-device iOS build.
