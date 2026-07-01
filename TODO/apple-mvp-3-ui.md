# Apple MVP 3: iOS UI Build

Status: Planning. Part of the [Apple MVP 3 program](apple-mvp-3-implementation.md). Depends on the [apex/API piece](mvp-3-apex-and-api.md) for the region source and routing.

Goal: a full SwiftUI rebuild of the iOS app matching the React site's visual language, dark-mode-first with a theme abstraction, including the Apple-review-safe guest flow. Connection status, error recovery, and privacy-safe diagnostics are part of this build (MVP 3 is the finished app).

Boundary: SwiftUI/app-lifecycle and theme code live in the iOS app target; `CloudGatewayKit` stays UI- and auth-agnostic (shared config manager, models, reconciliation, cache, tunnel lifecycle). The `CloudGatewayServicing` seam and the host-less `CloudGatewayTests` bundle carry over.

## Theme System

Mirror the web semantic tokens in [Frontend/Web/src/input.css](../Frontend/Web/src/input.css), which defines tokens (`page`, `card`, `nav`, `primary`, `accent`, `content`, `edge`, `success`, `warning`, `danger`, …) with separate light/dark values resolved from the Tailwind palette.

* Add a `Theme` struct of semantic `Color` tokens plus an environment value in the app target (not CloudGatewayKit).
* Ship only the dark palette now; structure so a light palette is a second value later. Force dark (`.preferredColorScheme(.dark)`); no runtime toggle yet, but **no hardcoded colors anywhere**.
* Dark-mode mapping (token → Tailwind shade), from `input.css` `.dark`:
  * page = gray-950, card = gray-900, inset = gray-800, inset-strong = gray-700, disabled = gray-800
  * nav = blue-950, nav-btn = gray-800, nav-btn-hover = gray-700
  * primary = blue-600, primary-hover = blue-500, primary-soft = blue-950, accent = blue-400, accent-strong = blue-300, focus = blue-500
  * content = gray-100, content-secondary = gray-300, content-muted = gray-400, content-faint = gray-500, content-disabled = gray-600
  * edge = gray-700, edge-subtle = gray-800, edge-faint = gray-800
  * success = green-700, warning-soft = yellow-950 / warning-strong = yellow-300, danger = red-600, danger-content = red-400
* Task: resolve each shade to its exact Tailwind v4 default hex during implementation (do not eyeball); produce a token→hex table as the first UI deliverable.

## Navigation And Root State

Replace the single `ContentView` `Form` with a root view that switches on an explicit app state from the view model:

* `loading` — initial launch while local/auth state resolves.
* `guest` — not signed in (chose "Continue as Guest", or signed out). Shows the dashboard in guest mode.
* `signedIn` — Firebase user present and access-checked. Shows the full dashboard.

Details:

* Root renders `LoginView` or `DashboardView`. Guests land on `DashboardView` (regions-only); "Sign in" presents `LoginView`. About is reachable from both nav bars.
* Add a first-class mode enum so guest is not conflated with a signed-in user who has no configs (today `isSignedIn` doubles as both).
* View model stays the single state owner; screens are thin.

## Pages And Components

### Login

Mirror [Frontend/Web/src/pages/Login.tsx](../Frontend/Web/src/pages/Login.tsx) and `~/GitHub/StreamTrack/APP/app/LoginPage.tsx` (email/password → provider buttons → Continue as Guest):

* Nav bar: "About" (left) → About; title "CloudGateway".
* Email + password fields (validation parity: email contains `@`/`.`, password non-empty).
* "Reset password" action (Firebase reset email; confirm first).
* Primary "Login" button (email/password).
* "or" divider, then **placeholder** "Continue with Google" and "Continue with Apple" buttons (disabled / "coming soon" until the [providers piece](apple-mvp-3-providers.md)).
* "Continue as Guest" secondary button → dashboard in guest mode.
* Thin "Request access" row: `mailto:` to the support email (`Brodsky.Alex22@gmail.com`, per [AccessMessages.tsx](../Frontend/Web/src/components/AccessMessages.tsx)).
* Version label (bottom).

### Dashboard

Mirror [Frontend/Web/src/pages/Home.tsx](../Frontend/Web/src/pages/Home.tsx), with a guest variant:

* Nav bar: "About" (left). Right side: signed-in → account + "Logout"; guest → "Sign in" → Login.
* Regions: visible to everyone. Signed-in shows capacity (fanned out per region via `GET /capacity`); guests see names/order only.
* Client table (see VPN Table): signed-in → the user's clients; guest → empty with a "Sign in to see your VPN clients" CTA (button → Login).
* Create/mutating controls: signed-in behave as MVP 2; guest → a prompt offering "Sign in" (→ Login) and "Request access" (mailto).
* Admin: "Grant User Access" and "Sync Region Clients" for admins (as web).
* Connection status + error banners (success/error), matching the web banner UX.

### VPN Table

Port [Frontend/Web/src/components/VPNTable.tsx](../Frontend/Web/src/components/VPNTable.tsx) into a SwiftUI list: rows with client display name, region, status (color-coded), selection, and per-row actions. Signed-in only; guest sees the empty CTA instead. Reconcile with the existing MVP 2 install/update/delete flows.

### About

Port [Frontend/Web/src/pages/About.tsx](../Frontend/Web/src/pages/About.tsx) into a themed SwiftUI About screen.

### Modals

* Delete confirmation (destructive) — already present in MVP 2; restyle.
* Guest action prompt (sign-in / request-access).
* Optional config detail / QR + copy/download for parity with the web QR modal — decide during build whether iOS needs it given it installs directly.

## Services And State Management

* Extend `CloudGatewayViewModel` with the `loading`/`guest`/`signedIn` mode and a guest load path: fetch regions from the apex `GET /regions`; do **not** call `check-access`, `fetchOwnedClients`, `/capacity`, or Firestore.
* Signed-in path unchanged from MVP 2 aside from the apex region source and the per-region capacity fan-out.
* Keep the `CloudGatewayServicing` seam; add `fetchRegions()` (apex) and gate mutating methods behind `signedIn`. Extend the mock + host-less tests for the guest path.

## Local Storage

* Keep the app-group `CloudGatewayConfigCache` snapshot (last installed config) in `CloudGatewayKit` as today.
* Only surface the cached/installed config when signed in (see below); the cache itself may persist across sign-out but is not shown to a guest.

## Auth Management

* Email/password remains the working path; provider buttons are placeholders until the [providers piece](apple-mvp-3-providers.md).
* Guest = tokenless, no Firebase user. "Continue as Guest" sets `guest` without authenticating.
* Sign-out returns to `guest`/login and clears the in-app signed-in state.

## Signed-Out Installed-Config Handling

Today the tunnel/installed-config section shows even when logged out. Change: surface installed/cached config and tunnel controls **only when signed in**. When signed out (including guest), hide them entirely.

Decision: on sign-out, **leave the OS VPN profile installed and the tunnel usable**, only hide the in-app UI. Accounts are device-independent — a user should sign in/out on any device without tearing down a tunnel they may still use. A user who wants to remove a stale profile does so in iOS Settings > VPN.

## Guest Flow (summary)

Guest can: browse enabled regions (names/order). Guest cannot: see clients, capacity, or installed configs; create/delete/sync. Every gated action routes to sign-in or request-access. Empty client table shows a sign-in CTA.

## Testing

Extend the host-less `CloudGatewayTests` bundle:

* Guest load: regions-only, no `check-access`/`fetchOwnedClients`/`/capacity`/Firestore calls.
* Gating: create/delete disabled or prompting in guest mode.
* Signed-out hiding of installed config.
* Mode transitions: guest → signedIn → guest.

SwiftUI views themselves are not unit-tested (consistent with the existing limitation); rely on manual/device verification for visuals.

## Open Items

* Provider button placeholder style: disabled vs "coming soon" tag vs hidden-until-ready (leaning: visible disabled with a subtle "coming soon").
* Whether iOS needs the config detail / QR modal.

## Acceptance

* Full dark-themed Login / Dashboard / About matching the React visuals, all colors from the theme layer.
* Guest can browse regions; every action routes to sign-in / request-access; empty table shows a sign-in CTA.
* Signed-in dashboard retains MVP 2 functionality on the apex region source.
* Installed configs shown only when signed in; sign-out leaves the tunnel installed and hides the UI.
* Host-less tests cover guest load, gating, and signed-out hiding; `./scripts/test.sh apple` green.
