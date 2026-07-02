# TODO

Planning notes for upcoming CloudGateway work.

* [Apple MVP progression](apple-mvp.md): iOS-first VPN app milestones, CloudGatewayKit scope, and WireGuardKit integration plan.
* [MVP 0 implementation plan](apple-mvp-0-implementation.md): concrete iOS entitlement and tunnel proof steps.
* [Apple MVP 1 Firebase Auth and config source](apple-mvp-1-firebase-auth.md): Firebase Auth, Firestore reads, access checks, user-selected configs, config cache, and iOS setup notes.
* [Apple MVP 2 implementation record](apple-mvp-2-implementation.md): region-aware API routing, capacity, create/delete, refresh/sync, service seam, and view-model tests as shipped. High-level milestone tracking stays in [Apple MVP progression](apple-mvp.md).
* [Apple MVP 3 overview](apple-mvp-3-implementation.md): the "first usable app" program - parent doc linking the pieces below. Planning/spec, not yet built.
  * [MVP 3 apex API routing and backend hardening](mvp-3-apex-and-api.md): the `api.` subdomain, `GET /regions`, region-vs-global routing, Caddy/Cloudflare/DNS, and Firestore rules hardening (web + iOS + backend + infra).
  * [Apple MVP 3 iOS UI build](apple-mvp-3-ui.md): full SwiftUI rebuild - theme, pages/components, services & state, local storage, auth, and guest flow.
  * [Apple MVP 3 sign in with Apple and Google](apple-mvp-3-providers.md): the deferred providers, wired last.
* [Apple app UX polish and VPN profile follow-up](apple-app-polish.md): post-MVP iOS polish checklist for required display names, per-client VPN controls, admin visibility, loading/refresh behavior, details modals, and sync results.
* [WireGuard Apple fork plan](wireguard-apple-fork.md): CloudGateway fork setup, Xcode 26 patch branch, and verification steps.
