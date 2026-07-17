# Apple Shared App Core Refactor Plan

Implementation plan for preserving the current iOS application while moving
non-UI application behavior into shared Apple libraries before a macOS app is
started.

## Goal

Refactor the shipped iOS architecture so the future macOS app reuses the same
authentication workflows, API behavior, account and client operations, VPN
orchestration, offline reconciliation, and dead-tunnel presentation logic.

The result must:

* preserve all current iOS behavior and copy;
* keep the existing `CloudGatewayKit` VPN, config, secret-storage, and
  tunnel-health behavior intact;
* provide a separately named shared app layer for behavior that does not belong
  in the low-level VPN kit;
* let iOS and macOS use different SwiftUI/AppKit presentation without copying
  business workflows;
* keep Firebase, Google Sign-In presentation, app lifecycle, entitlements, and
  native notification presentation out of the packet-tunnel and low-level kit
  targets;
* make the shared app layer compile and run its tests on macOS before the macOS
  app target exists;
* avoid copying iOS source files into the future macOS target.

## Scope

Primary implementation scope:

* `Frontend/Apple/CloudGatewayKit/Package.swift`;
* a new `CloudGatewayAppCore` product and target in the existing local package;
* `Frontend/Apple/iOS/CloudGateway/CloudGatewayServicing.swift`;
* `Frontend/Apple/iOS/CloudGateway/CloudGatewayViewModel.swift`;
* `Frontend/Apple/iOS/CloudGateway/CloudGatewayFirebaseService.swift`;
* `Frontend/Apple/iOS/CloudGateway/AppleSignInNonce.swift`;
* iOS app composition and lifecycle wiring;
* iOS host-less view-model tests and screenshot fixture wiring;
* a read-only packet-extension reuse audit that defines the future macOS
  adapter boundary without changing the hardened iOS extension;
* Apple architecture, test, and macOS-readiness documentation.

This plan does not create the macOS app, macOS packet-tunnel targets,
entitlements, signing profiles, menu-bar UI, settings UI, launch-at-login
behavior, or release pipeline.

No backend, Firebase schema, API contract, Cloudflare, WireGuard protocol, or
VPN behavior change is intended.

## Implementation Progress

- [x] Stage 0: freeze the observable iOS contract and establish a green baseline.
- [x] Stage 1: add the Firebase-free `CloudGatewayAppCore` module and move passive contracts.
- [x] Stage 2: move the app model and its tests without redesigning behavior.
- [x] Stage 3: extract the shared control-plane API client from the Firebase service.
- [x] Stage 4: split shared Firebase operations from platform sign-in presentation.
- [x] Stage 5: replace implicit iOS construction with explicit platform composition.
- [x] Stage 6: move the existing presentation refresh loop out of `ContentView` without changing its lifecycle policy.
- [x] Stage 7: document the packet-extension reuse and thin-adapter boundary.
- [ ] Stage 8: update validation, architecture documentation, and macOS handoff notes.

## Current Architecture

### Already shared correctly

`CloudGatewayKit` already targets iOS 17 and macOS 14 and owns the reusable
device/VPN core:

* `CloudGatewayVPNManager` wraps `NETunnelProviderManager` behind injected
  platform identifiers;
* `CloudGatewayConfigManager` owns install, start, stop, remove, local/remote
  reconciliation, cache ordering, and stale state;
* config models and selection policies are Firebase-free;
* WireGuard config parsing and secret references are shared;
* full configs remain in shared Keychain storage while the app-group cache holds
  metadata only;
* tunnel-health evaluation, recovery, scheduling, persistence, notification
  policy, start/stop barriers, effect ordering, and bounded stop completion are
  shared;
* the iOS packet extension maps WireGuardKit, `NWPath`, User Notifications, and
  Network Extension lifecycle into those shared contracts.

This is the correct low-level boundary. It must not absorb SwiftUI, Firebase,
Google Sign-In, or app-account workflows.

### Still trapped in the iOS target

The reusable app layer is currently compiled as iOS app source:

* `CloudGatewayServicing.swift` contains domain errors, auth models, API response
  models, URL validation, notification and health-reader seams, and the entire
  app-service protocol;
* `CloudGatewayViewModel.swift` is 1,436 lines of auth, account, admin, client,
  config, tunnel, offline, and dead-tunnel orchestration. It imports only
  Foundation, Combine, and `CloudGatewayKit`; it does not import SwiftUI or
  UIKit;
* `CloudGatewayFirebaseService.swift` is 697 lines combining Firebase Auth,
  Firestore, REST endpoints, DTO decoding, Google Sign-In UI presentation, and
  production object construction;
* `AppleSignInNonce.swift` is portable CryptoKit/Foundation behavior stored in
  the iOS folder;
* the 1,747-line view-model suite recompiles app source through Xcode synchronized
  group membership instead of importing a shared module;
* the screenshot target also recompiles the same app sources and supplies a
  second zero-argument view-model initializer.

The future macOS app would otherwise have to copy or reimplement this behavior.

### Lifecycle gap

`ContentView` currently owns a five-second task that reads the shared health
snapshot and reconciles local tunnel status. There is no app-level scene,
foreground, background, sleep/wake, or reachability event seam. The packet
extension continues detecting failures correctly while the GUI is inactive,
but presentation refresh is coupled to one iOS view's task lifetime.

The refactor must preserve the current rule: health/status refresh is local and
must not perform a remote reload through a dead or disconnecting full tunnel.

### Project-file hazards

The Xcode project uses Xcode 26 synchronized filesystem groups:

* `CloudGatewayTests` receives `CloudGatewayServicing.swift` and
  `CloudGatewayViewModel.swift` through membership exceptions;
* `CloudGatewayScreenshots` receives those sources plus selected UI files and
  excludes production-only sources;
* source build phases are not a complete statement of target membership;
* moving a file before package products and synchronized-group exceptions are
  updated can silently remove it from one target or compile it twice;
* production and screenshot targets currently define different
  `CloudGatewayViewModel.init()` convenience initializers, so careless target
  membership can cause duplicate symbols.

Update package dependencies, target membership exceptions, imports, and source
moves in the same checkpoint.

### Compiler-mode hazard

The iOS targets currently declare Swift language version 5 while the local
package uses Swift tools 6.3 and Swift 6 language mode. Moving app source into
the package therefore changes its concurrency checking even if the source text
is unchanged.

Run an early compile spike for the service protocol, auth-listener token,
`@MainActor` model, deinitializer, callbacks, and test doubles. Prefer explicit
actor isolation and typed `Sendable` wrappers where required. Do not silence
module-wide errors with blanket `@unchecked Sendable`, `nonisolated(unsafe)`, or
weaker Swift settings.

## Locked Decisions

1. **Preserve behavior before redesign.** Initial extraction keeps public names,
   state, ordering, messages, timeouts, and injected defaults. Do not combine a
   source move with an async, state-model, or UX rewrite.
2. **Keep two shared layers.** `CloudGatewayKit` remains the low-level Apple
   VPN/config/tunnel-health product. `CloudGatewayAppCore` becomes a second
   product and target that depends on `CloudGatewayKit`.
3. **No SwiftUI in shared modules.** Views, scenes, themes, sheets, alerts,
   navigation, menu-bar UI, and window management remain platform-owned.
   Combine `ObservableObject` and `@Published` are acceptable in AppCore because
   they work on both supported platforms and do not force shared views.
4. **AppCore stays vendor-free.** It may import Foundation, Combine, CryptoKit,
   Security, and `CloudGatewayKit`. It must not import Firebase, GoogleSignIn,
   UIKit, AppKit, SwiftUI, or UserNotifications.
5. **Firebase never enters `CloudGatewayKit`.** If the SDK compile spike passes,
   the shared Firebase adapter lives in its own local package; neither app-core
   nor packet-extension products link it.
6. **REST is not Firebase.** API URL construction, request/response DTOs,
   bounded URLSession transport, decoding, status handling, and safe path
   validation move into a Foundation-only control-plane client.
7. **Platform UI obtains credentials.** Apple authorization request UI and the
   Google presenting window belong to the app shell. Shared auth operations
   consume platform-neutral credentials/results through injected protocols.
8. **One app workflow implementation.** Auth-state loading, access checks,
   role resolution, region and capacity loading, client operations, account
   operations, config operations, offline fallback, and dead-tunnel disconnect
   ordering must exist once in AppCore.
9. **One detector implementation.** The future macOS packet extension must use
   the existing health coordinator and monitor. It must not copy the old timer
   or create a second state machine.
10. **Do not weaken secret boundaries.** Keep Firestore memory-only before its
    first read. Never persist full WireGuard configs in the app group. Never log
    keys, configs, tokens, runtime counters, traffic, destinations, or per-user
    connection history.
11. **Keep macOS identifiers injected.** App bundle, provider bundle, app group,
    Keychain access group, tunnel display name, storage locations, and API origin
    are configuration, not constants in shared workflow code.
12. **Do not share code only by target membership.** Reusable source belongs to a
    named module with normal imports and module-owned tests. The future macOS
    target must not compile files out of the iOS directory.
13. **Keep strict concurrency honest.** Required Swift 6 fixes must preserve
    callback ordering and actor ownership. Unsafe annotations require a narrow,
    documented synchronization invariant and focused tests.

## Target Architecture

```text
CloudGatewayKit
  VPN/config/cache/Keychain/tunnel-health primitives
        |
        v
CloudGatewayAppCore
  domain models + service ports + control-plane client
  shared app model/workflows + lifecycle entry points
        |
        +--------------------------+
        |                          |
        v                          v
iOS platform composition      macOS platform composition
Firebase adapters             Firebase adapters
UIKit auth presenters         AppKit auth presenters
SwiftUI views                 native macOS views/menu bar
UNUserNotificationCenter      macOS notification/lifecycle wiring
```

Packet-tunnel targets depend on `CloudGatewayKit`, WireGuardKit, and only the
extension support that they need. They do not depend on AppCore or Firebase.
App targets may additionally link a separate vendor-adapter package; that
package is not a dependency of either shared core product.

### `CloudGatewayKit`

Retain:

* config and WireGuard domain models;
* VPN profile control and platform configuration;
* config cache, Keychain secret store, and config manager;
* tunnel health, recovery, persistence, notification policy, monitor, artifact
  driver, and lifecycle synchronization primitives.

Move `CloudGatewayAPISession` out once AppCore owns the control-plane client;
it is an app-networking timeout policy, not a VPN primitive.

### `CloudGatewayAppCore`

Suggested source layout inside the existing local package:

```text
Sources/CloudGatewayAppCore/
  Account/
    CloudGatewayAuthModels.swift
    CloudGatewayAccountWorkflow.swift
    AppleSignInNonce.swift
  API/
    CloudGatewayAPIModels.swift
    CloudGatewayAPIURLBuilder.swift
    CloudGatewayControlPlaneClient.swift
    CloudGatewayAPISession.swift
  App/
    CloudGatewayAppError.swift
    CloudGatewayAppModel.swift
    CloudGatewayPresentationMonitoring.swift
  Services/
    CloudGatewayServicing.swift
    CloudGatewayNotificationAuthorizing.swift
    CloudGatewayTunnelHealthReading.swift
  Support/
    CloudGatewayRuntimeConfiguration.swift
```

Keep the type named `CloudGatewayViewModel` during the mechanical move. Rename
it to `CloudGatewayAppModel` only in a later isolated checkpoint if that name
better describes its cross-platform role.

The initial shared model may retain all existing `@Published` fields, derived
properties, presentation strings, and async actions. An immutable state/action
controller with thin platform observable adapters is a possible later cleanup,
not a prerequisite for macOS reuse.

### Shared service composition

The current `CloudGatewayServicing` protocol is a safe migration seam but is too
broad as the final adapter boundary. Preserve it for Stages 1 and 2, then split
implementation responsibilities behind it:

* `CloudGatewayAuthenticating`: current user, auth listener, tokens, password
  reset, sign-in, linking, reauthentication, provider IDs, and sign-out;
* `CloudGatewayUserRepository`: role and client Firestore reads;
* `CloudGatewayControlPlaneServicing`: regions, access, capacity, client create
  and delete, account delete, region sync, and access grants;
* `CloudGatewayGoogleSignInPresenting`: obtains Google tokens using the current
  platform window;
* a thin shared facade that conforms to `CloudGatewayServicing` while the app
  model migrates to the smaller protocols.

Do not force the app model and every test double to change in the same checkpoint
as the source move.

### Platform composition

The iOS composition root will assemble:

* iOS `CloudGatewayPlatformConfiguration`;
* Firebase Auth adapter;
* Firebase Firestore repository;
* shared control-plane client;
* UIKit Google Sign-In presenter;
* `CloudGatewayConfigManager` with VPN, cache, and Keychain dependencies;
* shared health snapshot reader;
* iOS notification authorizer;
* shared app model.

The future macOS composition root supplies the same graph with macOS identifiers,
an AppKit presenting window, macOS lifecycle events, and its own UI.

The zero-argument production initializer must leave
`CloudGatewayFirebaseService.swift`. Prefer an explicit iOS factory/composition
type. Screenshot fixtures use their own factory rather than declaring a second
initializer on the shared type.

## Behavior Invariants

The refactor is incomplete if any of these change.

### Authentication and account

* Email validation and password handling preserve current trimming behavior.
* Unknown Firebase errors retain their useful descriptions; known credential,
  disabled-account, recent-login, already-linked, weak-password, and
  wrong-password cases retain current domain mapping.
* A newly signed-in user is not considered fully loaded until access, role,
  regions, capacity, clients, and local config reconciliation complete.
* Provisioning/access denial signs out where it does today; transient API and
  cancellation failures do not incorrectly destroy a valid session.
* Provider display and reauthentication order remains Apple, Google, password
  for account deletion and recent-login recovery.
* Provider linking and account deletion preserve grant revocation behavior.
* Account deletion checks live tunnel status, deletes remotely first, then
  removes cached and uncached local profiles with the existing retry behavior.

### Regions, clients, and admin operations

* Region sorting, default selection, selection preservation, capacity gating,
  and unavailable-capacity behavior do not change.
* Admin and non-admin client queries remain distinct.
* Client creation refreshes remote state before presenting the result.
* Client deletion acts on the option captured when confirmation opened, not a
  later drifted selection.
* Client IDs and region IDs retain path/hostname validation before URL use.
* Region sync and access-grant results retain current behavior and copy.

### Config and tunnel operations

* Install-from-cloud fetches fresh remote config before installation.
* A missing Settings VPN profile produces refresh guidance and reconciles local
  state.
* Only the target active tunnel blocks client deletion; any active tunnel blocks
  account deletion.
* Connecting and reasserting states continue to block destructive operations.
* Switching stops the active tunnel before starting the selected tunnel.
* Offline cached installed configs remain visible, region-scoped, toggleable,
  and removable without becoming online ghost rows.
* Full configs and private keys never enter app-group metadata or logs.

### Dead-tunnel presentation and disconnect

* The packet extension remains the detector and notification producer.
* The GUI ignores stale or future-invalid snapshots according to the shared
  production timing contract.
* One health snapshot causes at most one local status reconciliation unless a
  status read failed and must be retried.
* Dead-tunnel warning display remains available to signed-in and guest users
  when the indicated local tunnel is still active.
* Disconnect stops the tunnel named by the snapshot, waits until it is actually
  down, enforces the existing timeout, and only then reloads remote state over
  direct connectivity.
* A generic URL timeout is suppressed only when a fresh confirmed dead-tunnel
  warning explains the failure.
* No automatic fail-open disconnect is introduced.

## Implementation Stages

### ✅ Stage 0 - Freeze The Observable Contract

Before moving code:

* run the prescribed Apple gate and record the commit, Xcode/Swift versions,
  resolved simulator name/runtime or `APPLE_TEST_SIMULATOR` value, test counts,
  and build result;
* ~~capture the current iOS screenshot fixture output;~~ intentionally waived by
  the owner on 2026-07-17 because the existing screenshot fixtures are already
  available and launching Simulator/Computer Use would add cost without
  protecting this source extraction;
* inventory every public/target-visible type and method in
  `CloudGatewayServicing.swift`, `CloudGatewayViewModel.swift`, and
  `CloudGatewayFirebaseService.swift`;
* add missing characterization tests only for behavior that a move would
  otherwise leave unprotected;
* document the manual signed-device checks that cannot run in the host-less
  suite.

Required characterization focus:

* auth listener startup and sign-out ordering;
* access-denied versus transient refresh failures;
* account link and deletion reauthentication;
* selected region/client stability;
* offline cached-row reconciliation;
* destructive-operation live-status checks;
* dead-tunnel stale snapshot, retry, timeout, and post-disconnect reload order;
* notification authorization only when a config exists or is first installed.

Acceptance:

* no production behavior changes;
* `./scripts/test.sh apple` passes before extraction begins;
* all behavior invariants have either an automated test or an explicit
  signed-device/manual check.

Baseline record:

* commit: `9788e6e51df4ad70618adba43a84aff6bffb45f7`;
* toolchain: Xcode 26.5 (`17F42`), Swift package tools 6.3;
* simulator: iPhone 17 on the installed iOS 26.5 runtime;
* shared package: 231 tests passed;
* host-less view model: 86 tests passed;
* unsigned generic iOS build: passed;
* gate: `./scripts/test.sh apple` passed on the confirming full rerun;
* baseline observation: the first full run reported one failure in
  `testSwitchTunnelMissingActiveTunnelFromSettingsShowsRefreshGuidanceAndClearsCardWarning`;
  the isolated rerun and confirming full gate both passed. Treat any recurrence
  as a test-ordering/race defect and resolve it rather than retrying indefinitely.

Post-characterization confirmation:

* shared package: 231 tests passed;
* host-less view model: 94 tests passed;
* unsigned generic iOS build: passed;
* gate: `./scripts/test.sh apple` passed on the final characterized tree;
* review: GPT-5.6 Terra, medium reasoning, approved after the auth-listener
  publish race was closed at both the client-fetch and config-apply suspension
  boundaries and characterized with deterministic gates.

Extraction inventory:

* `CloudGatewayServicing.swift` owns the notification authorization port and
  no-op/policy helpers; app errors and Firebase auth error-code mapping;
  runtime configuration and API URL validation; authenticated-user, access,
  deletion, sync, and access-grant values; the complete authentication,
  role/region/client/account/control-plane service port plus token convenience;
  and the tunnel-health reader port/no-op. All declarations and protocol
  requirements were enumerated before extraction.
* `CloudGatewayViewModel.swift` owns app mode, provider and reauthentication
  enums, sync results, the `@MainActor ObservableObject`, every published state
  value and derived UI capability, and the complete auth, account, refresh,
  selection, health, admin, client, install, tunnel, and message workflow API.
  Its only private supporting declarations are the async-result latch and
  tunnel-status display mapping.
* `CloudGatewayFirebaseService.swift` owns production model composition, the
  concrete health-store reader, create/capacity/regions response DTOs, the live
  service implementation, private request DTOs and decoder configuration, and
  the capacity-copy helper. The live service currently combines Firebase Auth,
  Firestore, Google presentation, and REST transport; later stages split these
  responsibilities without changing its outward behavior.

Outstanding signed-device/manual checks:

* email, Apple, and Google sign-in; provider linking and each reauthentication
  path; Google/Apple credential revocation during account deletion;
* first-install notification prompt, existing-install undetermined prompt, and
  dead-tunnel notification/warning behavior while foregrounded/backgrounded;
* profile install, start, stop, switch, remove, cold-launch restoration, offline
  fallback, stale-config handling, and post-dead-tunnel direct-connect reload;
* app background/foreground and device sleep/wake reconciliation.

These checks require signing, entitlements, live Firebase/Google configuration,
or a real Network Extension. They remain explicitly outstanding and are not
claimed by the host-less or unsigned build gates.

### ✅ Stage 1 - Add AppCore And Move Passive Contracts

Add `CloudGatewayAppCore` as a library product and target in the existing
`CloudGatewayKit` package, depending only on `CloudGatewayKit`.

Move without semantic edits:

* `CloudGatewayAppError`;
* `AuthenticatedUser` and API response/value models;
* `CloudGatewayServicing` and its default token helper;
* `CloudGatewayNotificationAuthorizing`, its no-op implementation, and existing
  install authorization policy;
* `CloudGatewayTunnelHealthReading` and its no-op implementation;
* `CloudGatewayRuntimeConfiguration`;
* `CloudGatewayAPIURLBuilder`;
* `AppleSignInNonce`.

Keep Firebase numeric error-code translation in the Firebase adapter. It may
return AppCore domain errors, but Firebase constants are not domain policy.

Update the app, test, and screenshot targets to import AppCore. Do not move the
view model yet. Add focused package tests for URL/path validation, runtime
configuration, nonce hashing, and passive policies before removing their Xcode
test copies.

Acceptance:

* AppCore compiles natively on macOS;
* AppCore imports none of the forbidden vendor/UI frameworks;
* iOS, host-less tests, and screenshots use the module types without duplicate
  definitions;
* moved declarations are removed from iOS source/target membership and are not
  compiled a second time through synchronized folders;
* the AppCore target dependency list contains only `CloudGatewayKit` plus Apple
  SDK frameworks, with no Firebase or Google package product;
* the full Apple gate remains green.

Completion record:

* `CloudGatewayAppCore` now builds as a Swift 6 iOS 17/macOS 14 library with
  only `CloudGatewayKit` as a package dependency and no vendor/UI imports;
* passive contracts, URL/runtime policies, and Apple nonce behavior moved out
  of the iOS source tree; Firebase numeric error translation remains in the iOS
  adapter;
* 236 package tests (231 Kit + 5 AppCore), 94 host-less tests, the unsigned app
  build, and the generic Simulator screenshot-target build passed;
* GPT-5.6 Terra, medium reasoning, approved after confirming the explicit main
  actor annotations preserve the production and screenshot targets' prior
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` behavior.

### ✅ Stage 2 - Move The Shared App Model And Tests

Move `CloudGatewayViewModel.swift` into AppCore as one behavior-preserving unit,
including its supporting enums, sync result, async result latch, and tunnel
status presentation mapping.

Then:

* make only the access-control changes required for app, screenshot, and test
  consumers;
* move `MockGatewayService`, config/tunnel fakes, health reader fake, and the
  view-model suite into `CloudGatewayAppCoreTests` as the single source of truth;
* make screenshot fixtures import AppCore and construct the model through a
  fixture factory;
* remove synchronized-group exceptions that recompile app source into test and
  screenshot targets;
* update `scripts/test.sh apple` to run AppCore tests, then remove the migrated
  sources, membership exceptions, and scheme entries from the host-less target
  in the same checkpoint;
* if Stage 0 identifies genuinely iOS-only logic tests, move those to a clearly
  named iOS-only target first. Do not leave duplicate copies of AppCore tests or
  fakes in both targets.

Do not split the broad model during this stage. Moving and redesigning 1,436
lines at once would obscure regressions.

Acceptance:

* the same app-model suite runs as module-owned Swift package tests on macOS;
* the iOS app and screenshot fixture import one compiled AppCore product;
* no reusable source is compiled from the iOS folder by another target;
* screenshots and all Apple validation remain unchanged.

Completion record:

* `CloudGatewayViewModel` and its supporting app-model declarations now live in
  `CloudGatewayAppCore`; only members used across the module boundary are
  public;
* the 94 view-model tests and their fakes now run on macOS from
  `CloudGatewayAppCoreTests`, and the obsolete Xcode host-less target, scheme,
  membership exceptions, and duplicate iOS test sources are removed;
* auth-listener ownership now uses a typed, thread-safe, exact-once
  registration so model deinitialization preserves listener cleanup across the
  Swift 6 module boundary;
* `./scripts/test.sh apple` passed with 94 app-model XCTest cases, 236 Swift
  Testing cases, project listing, and the unsigned generic-device iOS build;
* screenshot inspection and Simulator use were waived by the owner. The fixture
  target has no generic-device destination, so it was not separately built;
* GPT-5.6 Terra, medium reasoning, approved after an API audit led to narrowing
  test-only helpers and removing accidental access modifiers. The iOS Firebase
  numeric-code mapper regression moves to the adapter test boundary in Stage 4.

### ✅ Stage 3 - Extract The Control-Plane Client

Create a Foundation-only `CloudGatewayControlPlaneClient` in AppCore. Move:

* apex and regional URL construction;
* the bounded request session and timeout policy;
* unauthenticated and bearer-token request creation;
* request and response DTOs;
* ISO-8601 decoding;
* non-2xx API message extraction and domain error translation;
* regions, access check, capacity, create/delete client, delete account, region
  sync, and grant-access endpoints.

Inject the API origin and URLSession/session protocol. Preserve the current
10-second bounded request behavior and all endpoint paths and payload fields.

Move `CloudGatewayAPISession` and its tests from the VPN kit to AppCore when the
new client owns it. Add transport tests with a fake URL protocol/session; do not
use live production endpoints.

Acceptance:

* `CloudGatewayFirebaseService` contains no URL construction, URLSession,
  request body, response DTO, or JSON decoding implementation;
* API URL/path-injection tests and every endpoint request/response contract pass;
* no backend/API behavior change is required;
* AppCore remains Firebase-free and compiles on macOS.

Completion record:

* all eight apex/regional REST endpoints, request/response DTOs, URL creation,
  bearer and unauthenticated request construction, ISO-8601 decoding, and API
  error translation now live in the Foundation-only
  `CloudGatewayControlPlaneClient`;
* the origin host and session are injected, while the production session keeps
  the existing 10-second request timeout and disabled connectivity waiting;
* `CloudGatewayFirebaseService` delegates control-plane work and retains only
  its Firebase-owned post-create user decoration and Firebase/Firestore work;
* fake-session tests cover every endpoint's URL, method, headers, body and
  response, plus region filtering/sorting, serial best-effort capacity,
  path-injection rejection, malformed/non-HTTP responses, API envelopes, and
  transport-error propagation;
* `./scripts/test.sh apple` passed with 94 app-model XCTest cases, 241 Swift
  Testing cases, project listing, and the unsigned generic-device iOS build;
* GPT-5.6 Terra, medium reasoning, approved with no actionable findings.

### ✅ Stage 4 - Split Firebase Operations From Platform Presentation

Break the remaining production service into:

* Firebase Auth adapter;
* Firebase Firestore repository;
* injected Google Sign-In presenter;
* shared control-plane client;
* a thin facade used by the shared app model during migration.

Firebase Auth and Firestore are candidates for one shared adapter, contingent
on a compile spike proving the pinned SDK versions and required APIs support the
declared macOS deployment target. If proven, isolate them in a separate local
package at `Frontend/Apple/CloudGatewayFirebaseAdapter/` so vendor dependencies
do not contaminate AppCore or the `CloudGatewayKit` package. Prove the pinned
Firebase and Google SDK products needed by the complete platform graph. If a
vendor API is platform-specific, keep only that call in a small iOS/macOS
conformer to the same AppCore protocol.

Move UIKit-specific `topViewController()` and Google sheet presentation to an
iOS presenter. The future macOS presenter will receive an `NSWindow` or other
native presentation anchor. Keep Apple authorization request construction in
each platform UI; pass identity token, raw nonce, and authorization code into
shared account actions.

Keep Firebase startup and Firestore memory-cache configuration in the platform
app lifecycle. The cache must be configured before any repository creates or
uses the default Firestore instance.

Add adapter tests for error mapping, including the raw Firebase credential code
`17004` regression migrated from the old iOS test target, Firestore document
mapping, sign-out grant cleanup, and facade delegation without contacting
production services.

Acceptance:

* no shared production service imports UIKit or AppKit;
* all Firebase error mappings and auth/account flows remain covered;
* Firestore remains memory-only and WireGuard configs never reach its disk
  cache;
* the shared vendor adapter compiles for iOS and macOS, or platform-specific
  vendor calls are limited to small protocol conformers;
* the `CloudGatewayAppCore` target dependency list remains limited to
  `CloudGatewayKit` and Apple SDK frameworks;
* AppCore and packet-extension dependency graphs contain no Firebase or Google
  products.

Completion record:

* the Firebase-free AppCore now owns the auth, client-repository, control-plane,
  and Google-presentation ports plus the thin service facade used by the shared
  app model;
* the new `CloudGatewayFirebaseAuthAdapter` local package contains Firebase Auth
  only and compiles and tests natively for the declared macOS 14 deployment
  target as well as through the iOS app graph;
* raw Firebase error mappings, including credential code `17004`, have moved to
  adapter tests, while facade tests cover Google presentation and revocation
  ordering, Apple revocation forwarding, local Google sign-out ordering,
  repository delegation, and post-create owner decoration;
* the pinned Firebase 11.15 binary Firestore product excludes macOS, so the
  Firestore repository remains a small iOS conformer; it normalizes `Timestamp`
  to `Date` before calling the shared pure document mapper, without changing the
  app lifecycle's memory-only cache configuration;
* Google Sign-In presentation is now an injected iOS UIKit presenter, leaving
  the future macOS app to provide its native presentation anchor without
  duplicating auth or facade logic;
* AppCore remains vendor- and UI-framework-free, and neither AppCore nor the
  packet extension links Firebase or Google products;
* `./scripts/test.sh apple` passed with 94 app-model XCTest cases, 246 Swift
  Testing cases, 2 native macOS Firebase-adapter tests, Xcode project listing,
  and the unsigned generic-device iOS build;
* GPT-5.6 Terra, medium reasoning, approved with no actionable findings.

### ✅ Stage 5 - Make Platform Composition Explicit

Create an iOS composition root/factory and remove the production convenience
initializer from `CloudGatewayFirebaseService.swift`.

The factory owns:

* bundle and app-group identifiers;
* Keychain access-group resolution;
* API origin;
* creation order for Firebase, Firestore repository, control-plane client,
  config manager, health reader, notification authorizer, and auth presenter;
* construction of the shared app model.

Make `CloudGatewayPlatformConfiguration` the only route for app/provider/app
group/tunnel identifiers. Do not add `#if os(macOS)` branches with production
bundle strings in shared workflow code.

Replace the screenshot model initializer with an explicit fixture factory so
production, tests, screenshots, iOS, and macOS each have clear composition.

Acceptance:

* shared types have no hidden dependency on `Bundle.main`, `UIApplication`, or
  app-global Firebase singletons beyond injected adapter boundaries;
* iOS starts with the same identifiers, storage, cache, auth listener, and
  notification behavior;
* a macOS composition test can construct AppCore with fakes and macOS platform
  identifiers before a UI target exists.

Completion record:

* `CloudGatewayIOSCompositionRoot` now configures Firebase, applies the
  memory-only Firestore cache, resolves the Keychain access group, constructs
  the complete service/config/health graph, and creates exactly one shared app
  model in dependency order;
* the same `CloudGatewayPlatformConfiguration` value supplies the app, provider,
  app-group, tunnel, cache, Keychain, and health-store identifiers, while the API
  origin remains an iOS composition value;
* the Google client ID is resolved after Firebase startup and injected into the
  UIKit presenter, removing its Firebase singleton lookup;
* the SwiftUI app owns the model with `StateObject`, `ContentView` observes only
  an injected model, and the model and view receive the same notification
  authorizer;
* the old production and screenshot convenience initializers are gone; the
  simulator-only screenshot target has its own explicit fixture factory and
  no-op notification adapter, source-audited under the screenshot/simulator
  waiver;
* a native macOS AppCore smoke test constructs the model with fake services and
  storage plus injected macOS platform identifiers;
* the first gate exposed one remaining zero-argument `#Preview` call; it now uses
  explicit production composition and is excluded from the screenshot target;
* `./scripts/test.sh apple` then passed with 95 app-model XCTest cases, 246 Swift
  Testing cases, 2 native macOS Firebase-adapter tests, Xcode project listing,
  and the unsigned generic-device iOS build;
* GPT-5.6 Terra, medium reasoning, approved with no actionable findings.

### ✅ Stage 6 - Extract The Existing Presentation Refresh Loop

Move the health/status refresh algorithm out of the SwiftUI view while
preserving the current view-task lifetime exactly.

Add AppCore operations for:

* the immediate local health read currently performed on appearance;
* the cancellable health/status monitoring loop currently run by `.task`;
* explicit user refresh.

The shared operation uses the existing five-second cadence, owns no more than
one loop for a model instance, and exits when its caller task is cancelled.
Inject clock/sleep behavior for deterministic tests. `ContentView` continues to
start the operation from the same appearance/task hooks, but no longer contains
the polling and reconciliation algorithm.

Do not add new scene-phase, foreground, background, wake, reachability, or
automatic remote-refresh policy during this behavior-preserving refactor. The
future macOS shell may call the same AppCore operations from its native
lifecycle. Any change to iOS activation/wake behavior needs separate approval
and before/after acceptance criteria.

Acceptance:

* only one presentation refresh loop can run;
* appearance performs the same immediate health read as today;
* caller cancellation stops polling without affecting packet-extension
  detection;
* stale completions cannot overwrite a newer selection or loop;
* existing dead-tunnel ordering tests and new presentation-loop tests pass.

Completion record:

* `ContentView` retains the same `.onAppear` and `.task` ownership, but now calls
  AppCore operations for the immediate local health read and cancellable
  health/status monitor instead of containing the polling algorithm;
* the shared monitor preserves refresh-completion-plus-five-seconds cadence,
  performs its first tick immediately, and exits with its caller's cancellation;
* a generation token makes a replacement monitor authoritative, while late
  local-state completions must still match the active generation and current
  dead-health snapshot before they can update model state;
* the production sleeper uses `ContinuousClock`, and an injected controlled
  sleeper makes cadence, cancellation, and replacement tests deterministic;
* tests cover appearance reads, five-second cadence, cancellation, replacement,
  and a cancellation-insensitive late cache completion without adding remote,
  scene-phase, wake, reachability, or background policy;
* the first full gate exposed a stale source list in the adapter package for a
  new sibling source file; keeping the small sleeper contract with the existing
  AppCore passive contracts made every incremental package graph discover it;
* `./scripts/test.sh apple` then passed with 99 app-model XCTest cases, 246 Swift
  Testing cases, 2 native macOS Firebase-adapter tests, Xcode project listing,
  and the unsigned generic-device iOS build;
* GPT-5.6 Terra, medium reasoning, approved with no actionable findings.

### ✅ Stage 7 - Document The Packet-Extension Reuse Boundary

The health state machine is already shared, but the iOS provider still contains
runtime, notification, path, lifecycle, stop-deadline, and WireGuard mapping
types. Classify each type before macOS implementation, but do not extract new
support targets without a macOS consumer:

* keep `NEPacketTunnelProvider` entry points, provider-specific start/stop
  callbacks, entitlements, and capability differences platform-owned;
* keep WireGuard runtime/backend-restart calls behind the existing runtime
  protocol. macOS reports backend restart unsupported until the fork exposes a
  verified public entry point;
* mark start/stop lifecycle and stop-deadline coordination as candidates for
  shared extension support when a macOS implementation proves the same contract;
* document `NWPath` fingerprinting, route generation, and parsed-config-to-
  WireGuardKit mapping as candidate shared code, not new targets in this PR;
* keep notification authorization and foreground presentation policy in each
  containing app;
* keep outage-notification request registration, reconciliation, delivery, and
  withdrawal in each packet extension behind the shared health notification
  contract.

Do not move code merely to reduce file length. Extraction waits until both
extensions can consume the same implementation without importing app UI or
platform identity.

Acceptance:

* Stage 7 makes no production iOS extension change;
* the documented macOS extension implementation consists of Network Extension,
  WireGuard capability, path source, notification, and lifecycle adapters, not
  a copied detector or recovery state machine;
* stop-before-start-completion, callback loss, stale session, and bounded stop
  invariants remain explicit;
* no Firebase/AppCore dependency enters either extension.

Completion record:

* `Frontend/Apple/macOS/README.md` now maps each packet-tunnel concern to the
  exact shared public API and the thin native adapter the future macOS target
  must own, without compiling iOS sources or adding a support target early;
* the handoff explicitly preserves start identity, joined stop, missing and
  duplicate callback bounds, stale-generation fences, FIFO effect ordering,
  the five-second physical-stop deadline, single-monitor ownership, and the
  privacy/no-probe contract;
* direct API inspection corrected the draft to instantiate the public
  `CloudGatewayTunnelHealthMonitor`, which encapsulates its internal
  coordinator and artifact driver, instead of describing those internal types
  as separately importable;
* `PacketTunnelProvider.swift` remained byte-for-byte unchanged in the stage
  diff, and no Firebase, AppCore, UI, or platform identity entered the packet
  extension boundary;
* `./scripts/test.sh apple` passed with 99 app-model XCTest cases, 246 Swift
  Testing cases, 2 native macOS Firebase-adapter tests, Xcode project listing,
  and the unsigned generic-device iOS build;
* GPT-5.6 Terra, medium reasoning, approved with no actionable findings.

### Stage 8 - Documentation And macOS Handoff

Update:

* `Frontend/Apple/CloudGatewayKit/README.md` with the two-product boundary;
* `Frontend/Apple/iOS/README.md` with composition, lifecycle, and test ownership;
* `Frontend/Apple/macOS/README.md` with exact reusable products and remaining
  platform adapters;
* `docs/apple-ios-app.md` with the implemented dependency graph;
* `scripts/test.sh` and test READMEs with the actual package and Xcode gates.

Delete obsolete one-time Xcode test wiring instructions once AppCore owns the
tests. Record any signed-device checks that remain outstanding rather than
claiming they ran.

Acceptance:

* a macOS implementer can identify the product to import for every non-UI
  workflow without reading iOS source;
* durable docs match target dependencies and actual test commands;
* the TODO can be archived only after all automated gates and required manual
  checks are complete.

## Automated Test Matrix

### AppCore

* guest and authenticated startup;
* auth listener transitions and cancellation;
* sign-in, password reset, provider linking, recent-login recovery, sign-out,
  and account deletion;
* role and access precedence;
* region sorting, selection, capacity, client merge, and admin operations;
* install, start, stop, switch, remove, and destructive-operation guards;
* offline cold launch, cached rows, cross-region active tunnel, and online ghost
  prevention;
* URL building, client path validation, DTO decoding, API status/error mapping,
  and bounded timeout configuration;
* dead-tunnel freshness, warning visibility, local status retry, timeout,
  disconnect completion, and post-disconnect remote reload;
* presentation-loop startup, cancellation, immediate first read, cadence, and
  single-loop behavior;
* notification authorization policy;
* nonce generation shape and SHA-256 behavior.

### Firebase adapter

* Firebase error to AppCore error mapping;
* current-user and auth-listener mapping;
* provider linking and reauthentication delegation;
* Apple/Google grant revocation semantics;
* token refresh behavior;
* Firestore role and client mapping, including timestamps and owner fallback;
* memory-cache configuration ordering;
* Google cancellation versus real error behavior;
* no real credentials, projects, or production endpoints.

### CloudGatewayKit and packet extension

Retain all config-manager, config-selection, secret-store, tunnel-status,
tunnel-health evaluator/coordinator/monitor, notification fence, artifact
driver, effect arbiter, pending-start, start/stop-join, and stop-completion
coverage.

Add extension-support contract tests later, when the macOS extension provides a
second consumer and candidate code is actually promoted.

## Manual Validation Matrix

Run on a signed iOS device after the final refactor:

* email/password, Apple, and Google sign-in;
* Google callback URL routing and cancellation;
* link each missing provider and exercise recent-login recovery;
* guest dashboard, user dashboard, and admin dashboard;
* region capacity, client create/delete, sync, and access grant;
* install, connect, disconnect, switch, remove, and Settings-deleted profile;
* offline cold launch with an installed/connected cached config;
* first-install notification prompt and foreground dead-tunnel banner;
* dead-tunnel display while signed in and signed out;
* dead-tunnel disconnect followed by successful direct-network reload;
* account deletion while disconnected and blocking while a tunnel is active;
* app background/foreground and device sleep/wake with an active tunnel;
* ~~screenshot fixture output~~ (waived for this refactor; do not inspect images
  or use Simulator/computer-use) and release archive/build behavior.

Future macOS validation is a separate implementation gate, but it must reuse the
same AppCore contract suite before adding platform-specific UI tests.

## Validation Commands

During implementation, use the repository entry point:

```sh
./scripts/test.sh apple
```

That gate must continue to include:

* `CloudGatewayKit` tests;
* `CloudGatewayAppCore` tests on the macOS host;
* project listing/integrity;
* unsigned generic iOS build;
* any remaining host-less iOS-only logic tests.

Use the signed Apple gate and manual device matrix only when credentials,
entitlements, and a device are available. Do not replace the prescribed Apple
script with raw app-scheme simulator tests because the packet-tunnel extension
links a device-only WireGuard Go bridge.

## Suggested Reviewable Checkpoints

1. AppCore target plus passive contracts and tests.
2. App model plus package-owned tests and screenshot import conversion.
3. Control-plane client plus transport contract tests.
4. Firebase/Auth/Firestore split plus injected Google presenter.
5. iOS composition root and platform configuration cleanup.
6. Existing presentation polling algorithm ownership, with unchanged iOS task
   lifetime.
7. Packet-extension reuse audit and macOS adapter documentation only.
8. Documentation, test-script cleanup, full unsigned gate, then signed device
   validation.

Each checkpoint must build and pass before starting the next. Avoid a single
large move that mixes Xcode membership changes, package boundaries, Firebase
splitting, lifecycle changes, and packet-extension changes.

## Non-Goals

* Sharing `ContentView`, screen layouts, themes, navigation, sheets, alerts,
  menu-bar UI, settings UI, or other SwiftUI/AppKit views.
* Designing the macOS UI or deciding menu-bar versus window-first product UX.
* Creating macOS targets, entitlements, signing, launch-at-login, or releases.
* Changing backend endpoints, payloads, Firebase schema, Firestore rules, or
  access policy.
* Retuning dead-tunnel timing, recovery, copy, or fail-closed behavior.
* Exposing macOS WireGuard backend restart before the fork provides and validates
  a supported API.
* Replacing Combine/ObservableObject during the initial extraction.
* Introducing a new dependency-injection framework or state-management
  framework.
* Large SwiftUI cleanup of the 2,278-line iOS `ContentView`.
* Logging or analytics for VPN, auth tokens, configs, traffic, DNS, destinations,
  or connection history.

## Completion Criteria

The refactor is ready for macOS implementation when all of the following are
true:

* `CloudGatewayAppCore` is a named, Firebase-free shared product that compiles
  and tests on macOS and is imported by iOS;
* the app model, service contracts, API client, domain models, errors, account
  workflows, offline behavior, and dead-tunnel presentation logic no longer
  live in the iOS source tree;
* iOS and screenshot targets no longer recompile shared app source through
  synchronized-group membership;
* Firebase/Firestore behavior is shared where SDK-compatible and all native
  presentation is behind thin iOS/macOS adapters;
* iOS production and screenshot construction use explicit factories;
* SwiftUI views contain presentation and event wiring, not the health polling or
  remote/local orchestration state machines;
* packet extensions reuse one shared tunnel-health implementation and have a
  documented thin-adapter boundary;
* the full Apple gate passes after every stage and at completion;
* required signed-device checks pass or are explicitly recorded as outstanding;
* the future macOS app can be implemented without copying a Swift file from
  `Frontend/Apple/iOS/`.
