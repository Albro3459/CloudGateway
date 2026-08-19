# iOS Server Health: Account-Scoped ACL Policy Parity

Goal: bring the iOS admin Server Health page to parity with the web
`ServerHealth` client-isolation surface shipped by `account-scoped-acl.md`. iOS
gains shared Policy models and derivation, a `Policy/*` Firestore read, an
independent policy load-failure state, a client-isolation panel, and the
policy fields of the admin sync response. No backend API, Firestore
rules/schema, infrastructure, or web change.

This closes the "iOS Server Health Policy parity" release blocker in
`account-scoped-acl.md` ("Open release blockers").

## This is parity, not a compatibility fix

iOS is not broken by the ACL release. Verified against `bc7d99a..HEAD`:

* `AdminSyncResponse` gained `policyApplied` / `policyRowCount` /
  `policyStatusWritten`. `CloudGatewayRegionSyncParsing.parse` decodes into
  `[String: JSONValue]` and reads named keys, so unknown extras are ignored and
  every existing response still parses.
* `DeleteClientRequest.account_cleanup` is server-to-server only - the API's own
  `_delete_remote_client` sets it during cross-region account deletion. No web
  or iOS app client sends it, and it defaults to false.
* The `firestore.rules` change is purely additive (`Policy/{regionId}`,
  `Counters/{counterId}`). Nothing iOS reads changed.
* No VPN client configuration change, per `account-scoped-acl.md`.

What is actually missing is visibility: an iOS admin sees mesh status green with
no signal that client isolation has drifted or that a region's policy pass
failed. A security boundary whose status appears on only one of two admin
surfaces is the problem this plan solves.

## Parity target

| Web | iOS equivalent |
| --- | --- |
| `policyHelper.ts` derivation | `CloudGatewayAppCore/CloudGatewayPolicyStatus.swift` |
| `parsePolicyDocument` | `CloudGatewayFirestorePolicyMapper.policyDoc(documentId:data:)` |
| `getPolicyDocs()` (`firebaseDbHelper.ts:203`) | `fetchPolicyDocs()` on the repository, facade, and service protocols |
| `policyDocs` / `policyLoadFailed` state (`ServerHealth.tsx:144-149`) | `@Published policyRows` / `policyLoadFailed` on `CloudGatewayServerHealthViewModel` |
| Policy read isolated from the Regions/Mesh read (`ServerHealth.tsx:215-225`) | Policy failure cannot blank Regions/Mesh; the existing Regions/Mesh page-level failure behavior stays unchanged |
| "Client isolation" card grid (`ServerHealth.tsx:636-712`) | `clientIsolationPanel` in `ServerHealthView.swift` |
| Collection-level failure card (`ServerHealth.tsx:647`) | Same card, same "this is a read failure, not a report that no region has synced" wording |
| `CopyableValue` for both comprehensive hashes | Hash chips using the `UIPasteboard` copy pattern already in `ContentView.swift` |
| `policyApplied` / `policyStatusWritten` notes (`RegionSyncCard.tsx:103-118`) | Same two notes in `RegionSyncResultCard` |
| Policy state cleared on sign-out (`ServerHealth.tsx:389`) | Existing cover dismissal plus uid/load-generation guards; no policy-only reset path (see deltas) |

## Architectural decisions

* **Shared-first, per `AGENTS.md`.** Models, mapping, and derivation live in
  `CloudGatewayAppCore` so macOS reuses them. SwiftUI and the Firebase SDK
  repository implementation stay in `Frontend/Apple/iOS/CloudGateway/`; a
  future macOS target supplies its own native UI and Firestore adapter against
  the same AppCore contracts.
* **Reuse `CloudGatewayMeshRegion` as the region input.** It already carries
  `regionId`, `displayName`, and `enabled`, which is everything
  `buildPolicyStatusRows` needs. A second region model would duplicate the
  Firestore mapper for no gain.
* **Status semantics are the final web semantics.** Comprehensive IPv4/IPv6 hash
  agreement among enabled regions plus "Last applied." Do not port the
  superseded `dataVintage` model.
* **Policy is observability-only.** Read `Policy/*`, never write it. The
  collection is Admin-SDK-write in `firestore.rules`.
* **Counts and hashes only.** No uid, email, client name, address, or key ever
  reaches this surface.

## Resolved decisions

**`rowCount` typing.** The TS `numberOrNull` accepts any finite number, so a
fractional `rowCount` is "usable" on web. Swift uses `Int?` and rejects
non-integral values, which would classify such a doc `unreadable` instead. The
host only ever writes an integer, so take `Int?` and document the divergence at
the mapper. Accept any finite integral `NSNumber` representable by `Int`,
including zero, and reject `CFBoolean`; do not add a non-negative check that the
web Firestore mapper does not have. Do not widen to `Double?` to chase
byte-for-byte parity on a value that cannot occur.

**Majority tie-break.** `majorityValue` iterates a map to find the most common
hash, and Swift `Dictionary` iteration order is unspecified where the TS `Map`
is insertion-ordered. This is not a divergence: the function only returns a
winner when it clears a strict majority, and a strict majority is unique. No
sort needed, unlike `collectMeshWarnings`.

**Absent vs. null.** `policyDocs[regionId] == nil` is the TS `Map.get() ?? null`
case - the region has never completed a reconcile pass - and maps to
`never-synced` for an enabled region. A present but incomplete doc is
`unreadable`. A `rowCount` of zero is a valid boot state, not corruption.

**Failure isolation.** `fetchMeshState()` is all-or-nothing today, matching the
web's Regions/Mesh `Promise.all`. Keep that behavior. The policy read is the one
isolated feed: capture it as a `Result` alongside the concurrent region/mesh
tasks, mirroring the web's `policyPromise` catch. A `Policy` read failure must
still apply and render fresh Regions/Mesh state, clear the current policy rows,
and show the collection-level policy failure card. A Regions or Mesh failure
keeps the existing page-level error behavior and does not apply a separately
completed policy result.

## Work stages

### 1. Policy models and derivation

New `CloudGatewayAppCore/CloudGatewayPolicyStatus.swift`, a direct port of
`Frontend/Web/src/helpers/policyHelper.ts`:

* `CloudGatewayPolicyDoc` (`regionId`, `mapHashV4`, `mapHashV6`, `rowCount`,
  `updatedAt` - all optional but `regionId`)
* `CloudGatewayPolicyRegionState`: `ok`, `drifted`, `disabled`, `neverSynced`,
  `unreadable`
* `CloudGatewayPolicyStatusRow` (`regionId`, `doc`, `state`, `driftedV4`,
  `driftedV6`), `Identifiable` on `regionId` for `ForEach`
* `buildPolicyStatusRows(regions:policyDocs:)` plus private `isPolicyDocUsable`,
  `majorityValue`, `isDrifted`

Port the consensus rule exactly: strict majority (>50%) among enabled regions
with a usable doc; **no** majority means every comparable region is flagged
drifted, because an even split has no correct side and crowning a plurality
winner would hide the ambiguity; a lone comparable region can never be drifted;
a disabled region renders its values but never joins the comparison and can
never make another region drift.

### 2. Firestore mapper

Add `CloudGatewayFirestorePolicyMapper.swift` beside the mesh mapper, with
`policyDoc(documentId:data:)` porting `parsePolicyDocument`. Keep the small
policy coercion helpers in that file rather than renaming the mesh mapper or
introducing a shared abstraction for a few conversions. Match `coerce.ts`,
including the untrimmed-return `stringOrNull` behavior. The integer helper must
reject a `CFBoolean`-backed `NSNumber`, fractional values, non-finite values,
and values outside `Int`'s range. The mapper never throws: a malformed or
partially-written doc yields nil fields, which `isPolicyDocUsable` reads as
`unreadable`.

### 3. Fetch contract

* `fetchPolicyDocs() async throws -> [String: CloudGatewayPolicyDoc]` on
  `CloudGatewayServicing` (`CloudGatewayPassiveContracts.swift:337`) and
  `CloudGatewayClientRepository` (`CloudGatewayAppServiceFacade.swift:67`), with
  the facade passthrough beside `fetchMeshDocs` (~`:310`).
* `CloudGatewayIOSFirestoreRepository.fetchPolicyDocs()` reads the `Policy`
  collection and reuses the existing `convertingTimestamps` recursion so every
  `Timestamp` is a `Date` before it reaches the mapper.
* Conformers that must gain the method: `MockGatewayService`,
  `FacadeRepositoryFake`, `CloudGatewayScreenshotService`.

### 4. Sync response policy fields

* `CloudGatewayRegionSyncResponse` gains `policyApplied: Bool?`,
  `policyRowCount: Int?`, `policyStatusWritten: Bool?`.
* `CloudGatewayRegionSyncParsing` matches `APIHelper.ts:555-557` and `:591-593`:
  absent means an older regional API that predates policy sync, parsed as nil
  and treated as unknown; present `null`, a wrong type, or a negative or
  fractional `policyRowCount` rejects the whole response as incompatible,
  exactly like the existing `meshStatusWritten` handling. Do not enforce a
  relationship among the three optional fields that the web parser does not
  enforce.
* Update all three construction sites: the parser, `MockGatewayService`, and
  `CloudGatewayScreenshotService`.

### 5. View model

`CloudGatewayServerHealthViewModel`:

* Published `policyRows` and `policyLoadFailed`, backed by private
  `[String: CloudGatewayPolicyDoc]` state so region changes can recompute rows
  without exposing raw documents to the view.
* The load issues the policy fetch concurrently with regions and mesh docs, but
  its failure sets `policyLoadFailed` instead of throwing out of the load. On
  failure, clear the private docs and published rows; while
  `policyLoadFailed == true`, `recomputeDerivedState()` must keep rows empty
  rather than manufacturing `neverSynced` rows from the empty dictionary.
* Policy results apply under the same `loadGeneration`, uid, and
  `togglingRegionIds` guards as mesh results - a stale in-flight policy read
  must not overwrite a newer one.
* `recomputeDerivedState()` rebuilds `policyRows` alongside the mesh rows, so a
  region-list change flows through both.
* `syncAll()`'s post-fan-out re-read includes policy, per the blocker's
  "post-Sync-All reload." A policy re-read failure still applies the fresh
  Regions/Mesh result and changes the panel to the collection-level failure
  card.

### 6. iOS UI

`ServerHealthView.swift`:

* New `clientIsolationPanel` between `meshLinksPanel` and `clientPeerSyncPanel`.
  Per-region cards: region name, state chip (`OK` / `Drifted` / `Unreadable` /
  `Disabled` / `Never synced`), the matching explanatory sentence, row count,
  "Last applied", and both comprehensive hashes as copyable chips.
* Colors follow the web's judgment: `ok` success, `drifted` and `unreadable`
  danger (drift is an integrity signal; unreadable means isolation status cannot
  be confirmed at all), `disabled` and `never-synced` neutral. Every token
  already exists in `CloudGatewayTheme.swift`.
* Drift text distinguishes IPv4-only, IPv6-only, and both.
* `policyLoadFailed` renders its own card instead of a grid of "Never synced",
  which would assert a fleet state we do not know.
* Panel captions carry the web's two notes: counts and hashes only, and that
  there is no role mutation here - an out-of-band `UserRoles` edit only reaches
  the fleet after an admin runs Sync All Regions.
* Update the page header/subtitle and the file-level comment, which currently
  describe Server Health as mesh membership, link status, and peer sync only,
  so the page names client-isolation health as a first-class feed.
* `RegionSyncResultCard.successCard` gains the two notes from
  `RegionSyncCard.tsx:103-118`: a warning-colored note when
  `policyApplied == false` (the region keeps enforcing its previous map; retry
  Sync All and check host logs), and a muted note when applied but
  `policyStatusWritten == false` (hashes on this page may be stale). Silent when
  nil or fully successful. Keep the overall regional outcome successful in
  both cases, matching the API and web semantics.

### 7. Tests and fixtures

`./scripts/test.sh apple`. New and updated files under
`Tests/CloudGatewayAppCoreTests/`:

* `CloudGatewayPolicyStatusTests` - port `policyHelper.test.ts`: majority
  agreement, no-majority-all-drifted, single comparable region never drifted,
  disabled excluded from comparison, never-synced, unreadable, `rowCount == 0`
  usable.
* Mapper cases beside the mesh mapper tests: missing and wrong-typed fields, the
  `NSNumber`/`CFBoolean` trap, integral bounds, and `Date` acceptance. Firebase
  `Timestamp` conversion stays in the iOS adapter and cannot be instantiated in
  the Firebase-free AppCore test target.
* `CloudGatewayServerHealthViewModelTests` - policy failure leaves fresh mesh
  intact, `policyLoadFailed` is set and cleared, a failed policy read does not
  render every region as never-synced, policy reloads after `syncAll`, and stale
  generation and uid mismatch results are dropped. Keep the existing
  Regions/Mesh failure behavior; do not add inverse isolation absent on web.
* `CloudGatewayRegionSyncParsingTests` - successful false/true policy outcomes;
  all three fields absent; and rejection of present null/wrong-typed values plus
  negative/fractional `policyRowCount`.
* `CloudGatewayScreenshotService` gains deterministic agreeing Policy docs and
  the protocol method so the screenshot target remains a complete conformer.
  The screenshot app intentionally represents a normal user and does not expose
  admin Server Health, so do not change its role or claim that it captures a
  drifted admin panel in this ticket.

## Deliberate deltas from web

* **No policy-only sign-out reset.** `ContentView` dismisses Server Health when
  app mode leaves signed-in or the role ceases to be admin. The shared view
  model's uid and load-generation guards prevent an in-flight result from a
  prior identity publishing afterward, and every presentation starts a load.
  Server Health data is fleet-scoped rather than user-owned, so keep Policy on
  the same lifecycle as the existing Regions/Mesh state instead of adding a
  policy-only reset path. Do not weaken the existing dismissal or identity
  guards.
* **No standalone policy refresh control.** Pull-to-refresh already covers it,
  matching how the mesh panels behave.

## Docs

* `Frontend/Apple/iOS/README.md:51` - note the `Policy/*` read alongside the
  existing `Regions/*` and `Mesh/*` reads for Server Health.
* `Frontend/Apple/macOS/README.md` - add the shared Policy models, mapper,
  repository contract, and Server Health state to the GUI dependency boundary;
  keep the native macOS Firestore adapter and UI explicitly unimplemented.
* `Frontend/Apple/CloudGatewayKit/README.md` - include the shared Server Health
  view model and Policy derivation in AppCore's current responsibilities.
* `docs/service-operations.md` - describe Web and iOS Server Health rather than
  the generic/web-only "admin dashboard" where policy status and Sync All
  behavior are discussed.
* `TODO/account-scoped-acl.md` - check off the iOS parity blocker and point at
  this plan.

Docs pass update: all six files above (the iOS/macOS/CloudGatewayKit READMEs,
`docs/service-operations.md`, `TODO/account-scoped-acl.md`, and this file's
Docs section) were updated to reflect the delivered state described above.

## Risks

* **Periphery is strict on the `apple` target.** Any new `public` API not
  consumed by the iOS view fails the build. Add nothing speculative, and demote
  `public` where `internal` suffices.
* **Duplicated derivation.** `policyHelper.ts` and the Swift port must stay in
  step; the ported test suite is what keeps them honest.
* **Permission-denied reads.** A stale client-side admin role produces a denied
  `Policy` read, which lands on the `policyLoadFailed` card. Correct behavior,
  but the page entry point stays admin-gated.
* **Older regional hosts.** A region predating this release omits all three sync
  policy fields. Unknown, never rendered as failure.

## Checklist

* [x] `CloudGatewayPolicyStatus.swift` models + `buildPolicyStatusRows` port.
* [x] Policy Firestore mapper with `Int?` `rowCount` and the divergence noted.
* [x] `fetchPolicyDocs()` on the service, repository, facade, and 3 conformers.
* [x] iOS `Policy` collection read with timestamp conversion.
* [x] Sync response policy fields + strict parsing parity.
* [x] View model policy state with independent failure isolation and post-sync reload.
* [x] Client isolation panel + failure card + `RegionSyncResultCard` notes.
* [x] Ported policy tests, view-model tests, parsing tests, screenshot fixtures.
* [x] Docs updated; `account-scoped-acl.md` blocker checked off.
* [x] `./scripts/test.sh apple`, then the full `./scripts/test.sh` gate the ACL release requires.

## Validation record

* `./scripts/test.sh apple` - passes. Dead-code scans (app project, Kit tests,
  Firebase adapter tests), Kit/AppCore package tests, Firebase auth adapter
  tests, and the unsigned no-device iOS build all report OK. 263 AppCore/Kit
  tests executed with 0 failures, including the new policy derivation, mapper,
  sync-response parsing, and view-model isolation cases.
* Full `./scripts/test.sh` - passes end to end with no failed step: API
  (pyright/pytest/compile/vulture), release migrations, Web
  (jest/tsc/knip/CRA build), infrastructure, Firestore rules under the
  emulator, and the Apple target.
* Signed Apple builds and on-device runs were not part of this gate; the Apple
  step is the unsigned no-device build, as `AGENTS.md` specifies.

## Integration decisions made during review

* **`CloudGatewayPolicyDoc.regionId` carries a narrow `periphery:ignore`.** The
  strict app-project scan reports it as assign-only: production reads
  `CloudGatewayPolicyStatusRow.regionId`, which is the correct source because it
  also covers the never-synced case where there is no doc at all. The field is
  kept to mirror the web `PolicyDoc` and `CloudGatewayMeshDoc` shape and is
  compared via synthesized `Equatable`, matching the existing
  `// periphery:ignore - compared via synthesized Equatable` idiom in the facade
  tests. Removing it would have forced `policyDoc(documentId:data:)` to drop its
  document-id parameter and diverge from `meshDoc(documentId:data:)`.
* **No force-unwraps in the derivation.** `buildPolicyStatusRows` binds the
  hashes through `compactMap`/`guard let` rather than `!` after
  `isPolicyDocUsable`, so a later change to that predicate cannot turn into a
  runtime trap in the admin UI.
