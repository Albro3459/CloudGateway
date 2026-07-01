# MVP 2 Implementation Record

Status: Completed. This documents what shipped for MVP 2 (native config manager), mirroring the MVP 0 and MVP 1 implementation docs. See the acceptance summary in [apple-mvp.md](apple-mvp.md) (MVP 2 section).

Goal: turn the iOS app into a real CloudGateway config manager for signed-in users — region-aware API routing, capacity-aware create/delete, refresh, admin sync, and install of only the explicitly selected config — with Firebase/Firestore/API as the source of truth and the Apple cache demoted to an offline/stale fallback.

## Scope

Built on top of the MVP 1 Firebase/Auth/Firestore/API trust model. No pasted-config UI, QR codes, external WireGuard app, or manual config files. No auto-selection or auto-install. SwiftUI/app-lifecycle code stays in the app target; shared, platform-neutral logic stays in `CloudGatewayKit`; the packet tunnel extension stays Firebase-free.

## Region-Aware API Routing

Regional calls are routed to `https://<regionId>.gocloudlaunch.com/api/*` in the iOS adapter [CloudGatewayFirebaseService.swift](../Frontend/Apple/iOS/CloudGateway/CloudGatewayFirebaseService.swift):

* `regionalAPIURL(regionId:path:)` builds the per-region base URL from the injected `apiOriginHost`.
* `firstEnabledRegionURL(regions:path:)` picks the first enabled region for access verification (replacing the MVP 1 hardcoded `us-sanjose-1` check-access URL).
* All calls send `Authorization: Bearer <firebase-id-token>` and decode JSON with an ISO-8601 date strategy.

Endpoints used (mirroring [docs/api-contract.md](../docs/api-contract.md) and the web app):

* `POST /api/auth/check-access` — first enabled region.
* `GET /api/capacity` — per selected/enumerated region.
* `POST /api/clients` — create in the selected region.
* `DELETE /api/clients/{clientId}` — delete in the config's region (path segment encoded once by `URLComponents`).
* `POST /api/admin/sync` — admin-only selected-region peer sync.

## Firestore Reads

Direct Firestore reads (the app never writes product docs):

* enabled `Regions` via `fetchEnabledRegions()`.
* `UserRoles/{uid}` via `fetchUserRole(uid:)`, used as the authorization anchor; the Firestore role takes precedence over the API access-check role, which is the fallback.
* owned `Instances` via `fetchOwnedClients(uid:)`.

## Capacity

`GET /api/capacity` results are attached to regions in the kit model `CloudGatewayRegionCapacity` ([CloudGatewayConfigModels.swift](../Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayKit/CloudGatewayConfigModels.swift)):

* `known(limit:allocated:)` / `unknown` states, plus `isAtCapacity`, `isKnown`, and `displayText` ("N / M used" or "Capacity unavailable").
* `CloudGatewayFirebaseService.addCapacity(to:idToken:)` decorates the already-fetched enabled regions with per-region capacity, folding a failed capacity request into `.unknown` rather than dropping the region.

## Shared Models And Selection Logic (CloudGatewayKit)

Platform-neutral, unit-tested statics in `CloudGatewayConfigSelection`:

* `sortedRegions`, `clientOptions(clients:regions:)`, `clientOptions(in:options:)`, `usableOptions`.
* `mergeClients(existing:fetched:)` — region/clientId-keyed merge where an existing (e.g. just-created) client overrides the fetched copy.
* `resolvedRegionSelection(current:regions:)` and `prunedClientSelection(current:regionId:options:)` — selection ensure/prune rules.
* `selectedRegion(id:in:)`, `selectedOption(clientId:in:)`, `usableSelection(_:)` (active config + enabled region gate).

## Service Seam

The view model is decoupled from Firebase behind a Firebase-free protocol so it can be tested with a mock:

* [CloudGatewayServicing.swift](../Frontend/Apple/iOS/CloudGateway/CloudGatewayServicing.swift): `CloudGatewayServicing` protocol, the `AuthenticatedUser` value type, `CloudGatewayAppError`, and the protocol-facing DTOs.
* `CloudGatewayFirebaseService` conforms to it and maps Firebase `User` -> `AuthenticatedUser`; the live wiring (`convenience init()`) lives in an extension in the Firebase file so the core view model never references Firebase.

## View Model

[CloudGatewayViewModel.swift](../Frontend/Apple/iOS/CloudGateway/CloudGatewayViewModel.swift), `@MainActor`, injected with `CloudGatewayServicing` + `CloudGatewayConfigManager`:

* published `regions`, `clientOptions`, `selectedRegionId`, `selectedClientId`, `newClientName`, plus derived `selectedRegion`, `filteredClientOptions`, `selectedClientOption`, `selectedConfigOption`.
* gating: `createDisabled` (at-capacity aware), `deleteDisabled`, `installDisabled`, `canSyncSelectedRegion` (admin).
* flows: `refresh`, `createClient`, `deleteSelectedClient`, `syncSelectedRegion`, `installSelectedClient`, start/stop/remove.
* `loadRemoteState` fetches enabled regions once, then decorates with capacity (no duplicate fetch), merges any just-created client, applies remote state, and runs region-ensure + client-prune.

## UI

[ContentView.swift](../Frontend/Apple/iOS/CloudGateway/ContentView.swift):

* Regions section: enabled-region picker, capacity readout (red when full), and an admin-only "Sync Selected Region" button.
* Create section: name field + "Create In Selected Region" (disabled at capacity).
* Owned Configs section: selectable list with status.
* Selected Config section: install/update, plus delete with a destructive confirmation alert.
* Tunnel section: install/start/stop/remove status.

## Reconciliation And Cache

Handled in the kit's `CloudGatewayConfigManager` (`applyRemoteState`, `removeInstalledConfigIfMatches`, `markRemoteRefreshUnavailable`, stale/`remoteInvalidInstalledConfig` states). Remote truth overwrites the cache after auth; a removed/changed/missing remote config surfaces stale state and blocks start until the user reselects; when remote is unavailable the cached tunnel stays usable but is flagged stale. No local/remote merge; no auto-select.

## Testing

* `CloudGatewayKit` tests (`swift test`): selection/merge/prune/capacity/reconciliation/cache — [CloudGatewayConfigSelectionTests.swift](../Frontend/Apple/CloudGatewayKit/Tests/CloudGatewayKitTests/CloudGatewayConfigSelectionTests.swift), [CloudGatewayConfigManagerTests.swift](../Frontend/Apple/CloudGatewayKit/Tests/CloudGatewayKitTests/CloudGatewayConfigManagerTests.swift).
* iOS view-model tests ([CloudGatewayTests/](../Frontend/Apple/iOS/CloudGatewayTests/)): a host-less logic bundle using a mock `CloudGatewayServicing` and in-memory kit fakes, covering remote-load dedup, sign-out branching, capacity gating, selection prune, create-merge, and role resolution. Wired into `test_apple` in [scripts/test.sh](../scripts/test.sh) via `xcodebuild test` on the `CloudGatewayTests` scheme.

## Acceptance Criteria

MVP 2 (per [apple-mvp.md](apple-mvp.md)) is complete:

* Firebase/Firestore/API are the authenticated source of truth. ✅
* Local cache is offline/stale only and is overwritten by remote truth after auth. ✅
* No auto-selection of configs. ✅
* No pasted config UI, QR codes, external WireGuard app, or manual config files. ✅
* Shared sorting/filtering/reconciliation/cache covered by CloudGatewayKit tests. ✅
* `./scripts/test.sh apple` passes (CloudGatewayKit tests + unsigned no-device build; now also the view-model tests). ✅

## Validation

```sh
./scripts/test.sh apple            # swift test + unsigned no-device build + view-model tests
./scripts/test.sh apple --signed   # signed no-device build when provisioning is available
```

The view-model simulator can be overridden with `APPLE_TEST_SIMULATOR` (defaults to `iPhone 17`).

## Known Limitations

* The view-model tests run as a host-less logic bundle because the app scheme cannot build for the simulator (the packet-tunnel extension links WireGuard's device-only `libwg-go.a`). See [CloudGatewayTests/README.md](../Frontend/Apple/iOS/CloudGatewayTests/README.md) for the one-time Xcode wiring.
* The thin Firebase/URLSession/Firestore adapter itself remains build-validated only; its decode/DTO shapes are covered indirectly.
* Capacity is best-effort: a failed capacity request shows "Capacity unavailable" and create is still allowed so the regional API can return the authoritative limit rejection.
* Live sign-in and end-to-end connect/disconnect are verified on device, not in the scripted gate.

## Expected Follow-Up

MVP 3 (product flow): Sign in with Apple, account/session handling, connection status and error recovery, privacy-safe diagnostics, and polish around the MVP 2 config-manager flows.
