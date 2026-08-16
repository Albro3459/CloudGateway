# iOS Server Health: Admin Mesh + Sync All Regions

Goal: bring the iOS admin surface to parity with the web `ServerHealth` page shipped on this branch. Replace the per-region "Sync Region" button with an admin-only Server Health page that owns mesh membership, mesh link status, mesh warnings, and an all-region sync fan-out. No API change: the page uses the existing `POST /api/admin/sync` per region plus direct Firestore reads of `Regions/*` and `Mesh/*`, exactly like the web.

This supersedes the note in `shared-subnet-mesh.md` that Server Health is web-only.

## Parity target

| Web | iOS equivalent |
| --- | --- |
| `/server-health` route, admin-gated, redirects non-admins | `ServerHealthView` presented as a full-screen cover; dismissed when the user is not an admin |
| `AppNav` Activity icon (admins only) | Admin-only nav button in `signedInNav` |
| Home "Sync All Regions" → confirm → navigate with `runSync` state | Admin panel "Server Health" button opens the page; the page owns confirm + run (see deltas) |
| `SyncRegionsConfirmModal` | Confirmation sheet listing every enabled region |
| Mesh membership checkboxes writing `Regions/{id}.meshEnabled` | Toggles writing the same single field through the Firestore SDK |
| Link rows per unordered region pair | Same rows, same four statuses |
| Warnings list with reason-code text | Same list |
| `RegionSyncCard` per region (counts, mesh counts, peers, log, download) | Per-region result card with the same counts, expandable log, and `ShareLink` export |
| `getMeshStaleness` 24h "(stale)" hint | Same |

## Architectural decisions

* **Shared-first, per `AGENTS.md`.** All derivation, parsing, models, and the page view model live in `CloudGatewayAppCore` so macOS can reuse them. Only SwiftUI views stay in `Frontend/Apple/iOS/CloudGateway/`.
* **No API change.** Mesh state comes from Firestore (`Regions/*`, `Mesh/*`), the fan-out reuses `POST /api/admin/sync` once per enabled region. `firestore.rules` already grants admins `get, list` on `Mesh` and a `meshEnabled`-only update on `Regions`; nothing in Firebase changes.
* **Sync All replaces per-region sync.** `syncSelectedRegion`, `canSyncSelectedRegion`, `syncResult`, `dismissSyncResult`, `CloudGatewaySyncResult`, and `SyncResultView` are deleted. Periphery fails the build on the leftovers, so removal is not optional. The public `syncRegion` goes too — the fan-out is the only caller, so a single-region entry point on the protocols would be dead API.
* **Strict response parsing, per-region isolation.** A malformed or old-shape response fails that region's card only, mirroring the web's `incompatible-response` failure type. One region failing never aborts the others.
* **Separate view model.** `CloudGatewayViewModel` is already 1.5k lines and owns tunnel/auth state. Server Health gets its own `@MainActor ObservableObject` with its own `isSyncing`/`isLoading`, so a 45s fan-out never sits behind the dashboard's working overlay.
* **Simple, gated state.** No revision-stamped overrides or load generations (see stage 5). A toggle is disabled while its own write is in flight, which is what makes the simpler model correct.
* **New iOS Swift files join the app target automatically, but not Screenshots.** The `CloudGateway` folder is a file-system synchronized group for the app target only; the `CloudGatewayScreenshots` target opts into exactly three files via a `membershipExceptions` list in the pbxproj (`ContentView.swift`, `CloudGatewayTheme.swift`, `Assets.xcassets`). `ContentView` will reference `ServerHealthView`, so every new view file it pulls in must be added to that exception set or the Screenshots target stops building. This is a small, deliberate pbxproj edit.

## Resolved blockers

**Request timeout.** `CloudGatewayAPISession.requestTimeout` is 10s (deliberate: a dead full-tunnel blackholes traffic). A region sync routinely exceeds that; the web uses `REGION_SYNC_TIMEOUT_MS = 45_000`. Do not raise the session default. Add `CloudGatewayAPISession.adminSyncRequestTimeout: TimeInterval = 45` and set `URLRequest.timeoutInterval` on the admin-sync request only, which overrides the session configuration for that request. Note the semantic difference from the web: `timeoutInterval` is an idle timer (reset by incoming bytes), not the web's wall-clock abort. For a POST that returns a single body after the pass finishes they behave the same, and the idle form is fine here.

A sync pass has no server-side duration bound (only 20s-per-subprocess and 5s-per-DNS-resolve limits inside it), so a client-side timeout can fire while the host still holds its sync flock. The next attempt then gets `409 SYNC_IN_PROGRESS` — see failure classification below.

**Per-region failure isolation.** The generic `send` throws `.invalidAPIResponse` on any decode failure and `.accessDenied` on any non-2xx, which collapses "this one host is unreachable" into the same shape as "the whole call failed" and drops the request ID. Rather than catching and re-classifying thrown errors, the admin-sync path is non-throwing end to end:

* A private `sendAdminSync(regionId:idToken:) async -> CloudGatewayRegionSyncOutcome` owns the request and classifies the result. It never throws, so the task group has nothing to catch.
* The transport call itself is shared with the rest of the client via a small private helper returning `(Data, HTTPURLResponse)`; only the classification is sync-specific. No duplicated URLSession handling, and no changes to how any other endpoint reports errors.
* `ErrorResponse.Detail` gains `requestId` so an API failure can render it the way the web's failure card does.
* **`409 SYNC_IN_PROGRESS` is a first-class outcome, not a generic failure.** The API takes a non-blocking flock around the whole reconcile pass; a concurrent sync (another admin, the web dashboard, or a boot pass) makes the second request fail fast with 409. Classify it as `.alreadyRunning` and render "A sync is already running on this region — try again shortly," not a red failure card. This also covers the orphaned-pass case where our own 45s timeout fired but the host is still reconciling. (The web now renders the same card - see "Flagged during audit" below.)
* **Never assume the error body is JSON.** The FastAPI app always emits the JSON envelope, but the API sits behind Caddy and orange-cloud Cloudflare, which can answer 502/524 with HTML on origin timeout. If the envelope doesn't decode, fall back to a generic message with the HTTP status; never surface raw body text.

This is also why the public `syncRegion` is removed instead of kept alongside: the fan-out is its only consumer, and one seam keeps `MockGatewayService` honest.

**`syncedAt` parsing.** `JSONDecoder.gatewayAPI` uses `.iso8601`, which rejects fractional seconds; pydantic v2 serializes the tz-aware UTC `datetime` as `2026-08-15T20:38:37.814426Z` (fractional seconds, `Z` suffix — not the `+00:00` offset form the api-contract example shows). This is invisible today only because `syncedAt` is typed `String`. Keep it a `String` on the wire model and parse explicitly with `ISO8601DateFormatter`, trying `.withFractionalSeconds` first and falling back to the plain format (both handle `Z` and offset forms). An unparseable value is an incompatible response, matching the web's `Date.parse` check. Do not switch the field to `Date` and do not change the shared decoder's date strategy.

## Work stages

### 1. Mesh validation port

New `CloudGatewayAppCore/CloudGatewayMeshValidation.swift`, a direct port of `Frontend/Web/src/helpers/meshValidation.ts`:

* `isValidWireGuardPublicKey` (43 base64 chars + `=`, decodes to 32 bytes)
* `isValidEndpointHostname` (IPv4 literal, IPv6 literal, or dotted labels, ≤253 chars)
* `isValidMeshNetworkSyntaxV4` / `isValidMeshNetworkV4` (exact `/24`, `.0` host, inside `10.0.0.0/16`)
* `isValidMeshNetworkSyntaxV6` / `isValidMeshNetworkV6` (exact `/64`, canonical form required, inside `fd42:42:42::/48`)
* `isValidMeshEndpointPort` (integer 1...65535)
* `networksOverlap` (same third octet for v4, same first four words for v6)

Canonical-form matching for IPv6 is load-bearing (`formatIPv6Canonical`); port it rather than leaning on `IPv6Address`, so Swift and TypeScript agree on what "current snapshot" means.

### 2. Mesh models and derivation port

New `CloudGatewayAppCore/CloudGatewayMeshStatus.swift`, a port of `meshHelper.ts`:

* `CloudGatewayMeshPeerStatus` (`applied`, `skippedOverlap`, `skippedIncomplete`), `CloudGatewayMeshPeerEntry`, `CloudGatewayMeshDoc`
* `CloudGatewayMeshRegion`: the Firestore region document, distinct from the API-shaped `CloudGatewayRegion` (which carries no mesh fields). Fields: `regionId`, `displayName`, `enabled`, `displayOrder`, `meshEnabled`, `wireguardPublicKey`, `wireguardEndpointHostname`, `wireguardPort`, `tunnelNetworkV4`, `tunnelNetworkV6`.
* `isRegionMeshPending`, `buildMeshLinkRows`, `hasAnyMeshPending`, `collectMeshWarnings`, `getMeshStaleness`, `meshStaleThreshold = 24h`

Port the semantics exactly, including the parts the web comments call out: `skipped-incomplete` entries survive parsing with empty fields; `applied`/`skipped-overlap` require a complete current snapshot; disabled regions are rendered but never counted as pending; duplicate-key and cross-candidate overlap checks are scoped to enabled regions; only a live host's own stale entry counts as removal-pending.

### 3. Firestore access

* `CloudGatewayAppServiceFacade.swift`: extend `CloudGatewayClientRepository` with `fetchMeshRegions() async throws -> [CloudGatewayMeshRegion]`, `fetchMeshDocs() async throws -> [String: CloudGatewayMeshDoc]`, and `setRegionMeshEnabled(regionId:enabled:) async throws`. Surface all three on `CloudGatewayServicing` and forward them in the facade.
* Every conformer updates with the protocols: `CloudGatewayAppServiceFacade` + `CloudGatewayIOSFirestoreRepository` (production), `CloudGatewayScreenshotService` (implements `CloudGatewayServicing` directly — give it static mesh fixtures so Server Health is screenshotable), `MockGatewayService`, and `FacadeRepositoryFake`/`FacadeControlPlaneFake` in the facade tests.
* New pure mapper `CloudGatewayFirestoreMeshMapper` next to `CloudGatewayFirestoreClientMapper` (`[String: Any]` in, models out) so parsing is unit-testable without Firebase.
* `CloudGatewayIOSFirestoreRepository`: implement the three methods against `collection("Regions")`, `collection("Mesh")`, and a single-field `updateData(["meshEnabled": enabled])`. `Timestamp` → `Date` conversion must be recursive, not top-level like `clients(from:)`: the mapper lives in AppCore and cannot import FirebaseFirestore, and `Mesh/*` docs carry `appliedAt` timestamps nested inside every `peers.{regionId}` entry as well as the top-level `updatedAt`.
* The Firestore cache is memory-only (composition root), so these reads always hit the server: a permission-denied from a stale admin role surfaces immediately rather than being masked by a disk cache.
* Sort regions with the existing display-order-then-id rule (`CloudGatewayConfigSelection.sortedRegions` semantics) so the page order matches the dashboard.
* The enabled-region list for the confirm sheet and the fan-out comes from these Firestore docs, not from `fetchRegions()`: the API-shaped `CloudGatewayRegion.enabled` is hardcoded `true` by the client and never carries the real flag.

### 4. Sync response contract and fan-out

* Extend `CloudGatewayRegionSyncResponse` with `meshUpdated`, `meshEnabled`, `meshApplied`, `meshAdded`, `meshRemoved`, `meshSkipped`, `meshRoutesAdded`, `meshRoutesRemoved`, `meshStatusWritten: Bool?`, `meshPeers: [CloudGatewayRegionSyncMeshPeer]`. `meshStatusWritten` stays optional: absent means an older regional host, which is unknown, not a failure. Present-but-wrong-type is malformed (`decodeIfPresent` throwing on a type mismatch gives this for free).
* New `CloudGatewayAppCore/CloudGatewayRegionSyncParsing.swift`. Decode a lenient DTO, then validate, mirroring `parseRegionSyncResponse`: counters non-negative (Decodable rejects non-integers; the `>= 0` check is explicit), `syncedAt` non-empty and parseable per the rule above, `meshPeers` present; `applied`/`skipped-overlap` peers require hostname, port, v4 and v6 to be valid, and `skipped-overlap` additionally requires a known reason code; `skipped-incomplete` requires a known reason code and tolerates absent or blank optional fields but rejects present-and-invalid ones. Unknown `status` or unknown reason code ⇒ malformed. Also require `response.regionId == requestedRegionId`.
* `CloudGatewayRegionSyncOutcome`: `regionId` plus `success(CloudGatewayRegionSyncResponse)` | `alreadyRunning` | `failure(message:, requestId:, isIncompatibleResponse:)`. Built only by `sendAdminSync`, which classifies transport error, HTTP 409 (`SYNC_IN_PROGRESS`), other non-2xx (message + code + request ID from the JSON envelope when it decodes, generic message with status otherwise), strict-parse rejection, and success. All types `Sendable` — the protocol requires it and the task group crosses isolation.
* `syncRegions(regionIds:idToken:) async -> [CloudGatewayRegionSyncOutcome]` on the control-plane client and `CloudGatewayServicing`: `withTaskGroup`, one non-throwing child per region, results re-ordered to the input order. Regions number in the low single digits, so full parallelism matches the web's `Promise.allSettled`. (The API's flock makes parallel requests to *different* hosts safe; same-host contention is the 409 case.)
* One `idToken` fetched immediately before the fan-out and reused across it, like the web. No mid-fan-out refresh/retry: an expiry surfaces as that region's `AUTH_REQUIRED` failure card.
* Rendering note: `meshEnabled` in the response is the combined `region.enabled && region.meshEnabled`, not the raw Firestore flag — label the chip "Mesh enabled/disabled" exactly as the web does and don't cross-check it against the toggle state.
* Failure messages must stay short and safe: the API error message or a generic fallback. Never fold response bodies or log text into a banner.

### 5. Server Health view model

New `CloudGatewayAppCore/CloudGatewayServerHealthViewModel.swift`:

* Published: `regions`, `meshDocs`, `linkRows`, `warnings`, `anyPending`, `isLoading`, `isSyncing`, `syncResults`, `bannerText`, `togglingRegionIds`. Derived values are recomputed once per state change, not on every view read.
* `load()` reads regions and mesh docs concurrently, then rebuilds derived state.
* `toggleMesh(region:)` stays deliberately simple: mark the region as toggling (which disables its control), write the single field, then reload on success; on failure revert the local value and show a banner. No revision stamps, no override map, no load generations.
  * What makes that sound is the gating: the control cannot issue a second write for a region while one is in flight, and `load()` results are dropped while any toggle is in flight, with a reload issued when it completes. The web needed override bookkeeping because a background refresh could land mid-toggle; a single gated refresh path removes the race instead of reconciling it.
* `syncAll()` targets enabled regions only, then re-reads `Mesh/*` after the fan-out settles (the response is ephemeral; `Mesh/*` is the durable state the link rows render). Mesh toggles and Sync All are mutually exclusive while either runs.
* Identity guard: capture `service.currentUser?.uid` before each async step and drop results if it changed, matching `performForCurrentUser` in the existing view model. This is the one guard worth keeping — sign-out mid-fan-out must not repopulate the page.

### 6. iOS UI

* New `Frontend/Apple/iOS/CloudGateway/ServerHealthView.swift` (do not grow `ContentView.swift`, already 2281 lines): header + Sync All button with the pending ring treatment, mesh membership toggles with `Disabled`/`Pending`/last-applied labels, link rows in the four status colors, warnings section with the reason-code sentences from `formatWarningReason`, and per-region result cards.
* New `RegionSyncResultCard` view: counts, mesh counts, mesh peer chips, the `meshStatusWritten == false` warning sentence, expandable log, and `ShareLink` for the `.log` export (reuse the pattern already in `SyncResultView` before it is deleted).
* `ContentView.swift`: add an admin-only Server Health nav button, replace the admin panel's "Sync <Region>" button with "Server Health", present `.fullScreenCover`, and delete the `syncResultPresented` sheet and `SyncResultView`.
* Shared view helpers currently `private` in `ContentView.swift` (`ThemedPanel`, `SectionHeader`, `DetailLine`, `MessageBanner`, `PrimaryButtonStyle`, `SecondaryButtonStyle`, and `EmptyState`/`FlowLayout` if used) must be demoted to internal for reuse from the new file. Keep them in `ContentView.swift` — moving them to a new file would force that file into the Screenshots exception set too. The Periphery app scan builds both the app and Screenshots schemes; internal helpers used from either are retained.
* Add `ServerHealthView.swift` (and `RegionSyncResultCard` if it's a separate file) to the Screenshots target's `membershipExceptions` so `ContentView` still compiles there.
* Dismiss the cover when `appMode != .signedIn` or the role stops being admin (`role` and `appMode` are both `@Published`, so `.onChange` on either works; role is re-resolved on every refresh/pull-to-refresh).
* Theme: add mesh status colors to `CloudGatewayTheme` alongside the existing tokens. Note the existing warning family is `warningSoft`/`warningStrong`/`warningSoftEdge` (no bare `warning`); follow that naming.

## Deliberate deltas from web

* **No cross-page hand-off.** The web's `pendingRunSync` machinery exists because Home confirms and Server Health runs across a route change. On iOS the admin panel button just opens the page, and the page owns confirm-and-run, so the whole run-now signal, `autoRunHandled` ref, and "confirmed sync has not run yet" state disappear.
* **Pull-to-refresh instead of a nav refresh button.** The app already uses `.refreshable` everywhere; the web needed an in-card retry only because its nav refresh hides below `sm`. Keep an explicit retry button on the unavailable-data state.
* **Log export via `ShareLink`**, not a file download. Never write the sync log to disk or logs: it carries user emails, client names, client IDs, public keys, and tunnel IPs.

## Tests and validation

`./scripts/test.sh apple` (SwiftPM view-model tests + Periphery + unsigned build). New test files in `Tests/CloudGatewayAppCoreTests/`:

* `CloudGatewayMeshValidationTests` — port `meshValidation.test.ts`
* `CloudGatewayMeshStatusTests` — port `meshHelper.test.ts` (link statuses, pending matrix, stale detection, warnings, reason-still-present cases)
* `CloudGatewayRegionSyncParsingTests` — port the sync cases from `APIHelper.test.ts` (missing fields, bad counters, unknown status, unknown reason code, absent vs. malformed `meshStatusWritten`, region-id mismatch), plus the real `syncedAt` shapes: fractional-seconds `Z`, plain `Z`, and offset form
* `CloudGatewayServerHealthViewModelTests` — port behaviors from `ServerHealth.test.tsx`: admin gating, toggle rollback on write failure, a refresh landing mid-toggle not clobbering it, fan-out with one region failing while the rest succeed, a 409 rendering as already-running rather than failure, mesh re-read after sync, sign-out mid-flight drops results

`MockGatewayService` gains the three repository methods, a `syncRegions` seam with call counts and per-region outcome injection, and loses its `syncRegion` stub. Known casualties by name:

* `CloudGatewayViewModelTests`: `testSyncSelectedRegionCapturesResult` and `testSyncCompletionCannotPublishPreviousUsersAuditLog` are deleted (their auth-isolation intent moves to the Server Health view-model tests). `testDeferredAuthReloadRunsOnceAndSkipsWhenUserUnchanged` only uses sync as its in-flight operation — retarget it to another gated operation, don't delete it.
* `CloudGatewayControlPlaneClientTests`: `controlPlaneEndpointContractsStayStable` drops its `syncRegion` leg; add fan-out coverage (per-region 409 / non-JSON 502 / incompatible-shape classification) either there or in a dedicated test.
* `CloudGatewayAppServiceFacadeTests`: `FacadeRepositoryFake` and `FacadeControlPlaneFake` implement the new methods; add forwarding assertions matching the existing style.

Web, API, Firebase, and infra are untouched by this work — no `./scripts/test.sh` targets beyond `apple` are needed. The items in "Flagged during audit" below are deliberately out of scope here; picking any of them up means running that surface's target too.

## Docs

* `Frontend/Apple/iOS/README.md`: replace the per-region `POST /admin/sync` paragraph with the Server Health surface, the all-region fan-out, the Firestore `Regions`/`Mesh` reads, and the `meshEnabled`-only write. Keep the admin-only log-sensitivity warning.
* `Frontend/Apple/macOS/README.md`: add the mesh repository methods to the "not yet conformed on macOS" table.
* `TODO/shared-subnet-mesh.md`: drop the "Server Health page is web-only for this PR" line once this lands.

## Flagged during audit (web/API, not iOS work)

Found while auditing this plan; none block the iOS work, but they belong to the owning surfaces:

* ~~**`docs/api-contract.md` `syncedAt` example is wrong.**~~ Fixed: the example now shows the real `Z`-suffixed fractional-second form, with a note to parse it as ISO 8601.
* ~~**Web renders `409 SYNC_IN_PROGRESS` as a generic red failure card.**~~ Fixed: `runRegionSync` tags it `failureType: "sync-in-progress"` and `RegionSyncCard` renders the same "already running" card iOS does.
* **Firestore rules let an admin set `meshEnabled=true` on a disabled region.** The web only disables the toggle client-side; the rule checks `hasOnly(['meshEnabled'])` but not `resource.data.enabled`. Verified inert — every sync path re-filters on `enabled is True` — so this is defense-in-depth, not a vulnerability. Optionally tighten the rule to require `resource.data.enabled == true` when setting `true`.

## Risks

* **Firestore permission surprises.** `Mesh` list requires `isAdmin()`; a role that is stale on the client produces a permission-denied read. Handle it as the unavailable-data state, not a crash.
* **Duplicated derivation logic.** `meshHelper.ts` and the Swift port must stay in step; a future change to link/pending semantics has to land in both. The ported test suites are what keep them honest.
* **Older regional hosts.** A region that has not been reinstalled returns no `meshStatusWritten`. Treat as unknown; never render it as a failure.
