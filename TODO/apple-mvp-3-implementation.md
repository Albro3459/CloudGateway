# Apple MVP 3: First Usable App (Overview)

Status: Planning. This is the overview/parent for MVP 3, which is larger than prior MVPs and split into separate docs per moving piece.

Goal (from [apple-mvp.md](apple-mvp.md)): turn the working VPN proof into the first genuinely usable CloudGateway iOS app. MVP 3 *is* the finished app, not a slice — a full UI rebuild matching the React site (dark-mode-first), an Apple-review-safe guest flow, and, folded into the UI work, connection status, error recovery, and privacy-safe diagnostics.

## Pieces (each has its own doc)

* **[Apex API routing and backend hardening](mvp-3-apex-and-api.md)** — cross-client (web + iOS + backend + infra): the `api.` subdomain, `GET /regions`, region-vs-global routing, Caddy/Cloudflare/DNS, and Firestore rules hardening.
* **[iOS UI build](apple-mvp-3-ui.md)** — full SwiftUI rebuild: theme layer, pages & components, services & state, local storage, auth management, and the guest flow.
* **[Sign in with Apple and Google](apple-mvp-3-providers.md)** — the deferred providers, wired last.

## Why A Guest Flow

Apple reviewers routinely force a no-account path even for paid or account-gated apps (observed firsthand on a prior app whose search was gated behind paid APIs), so build it proactively rather than risk a 4.2 / 2.1 "login wall" rejection. Guest = not signed in (tokenless; not Firebase anonymous auth). A guest can browse enabled regions and nothing else; every real action routes to sign-in or request-access. Details live in the UI doc; the unauthenticated region source lives in the apex doc.

## Build Order

1. **Apex / API** (backend + infra + web + iOS routing) — foundation. See [apex doc](mvp-3-apex-and-api.md).
2. **iOS UI for signed-in users** (theme + screens) — [UI doc](apple-mvp-3-ui.md).
3. **Guest flow** (regions-only, gating, hide installed configs when logged out) — UI doc.
4. **Firestore rules hardening** (read-only) — apex doc; safe any time after step 1.
5. **Providers**: Sign in with Apple, then Google — [providers doc](apple-mvp-3-providers.md).

Each step lands independently and keeps `./scripts/test.sh` green.

## Program Decisions

1. **Apex `api.gocloudlaunch.com`** — A record → the `displayOrder: 1` region's IP; every region's Caddy also serves the subdomain (cert reused); Cloudflare-proxied and rate-limited. Carries global/read traffic; region-specific mutations hit `<regionId>.gocloudlaunch.com`.
2. **`GET /regions`** (apex, unauthenticated) = region list only (`regionId`, `displayName`, `displayOrder`), no capacity; the single region-list source for every client. **`GET /capacity`** (region host, authenticated) = per-region capacity, fanned out by signed-in clients only.
3. **Guests** are tokenless and see region name/order only.
4. **Sign-out** leaves the installed tunnel in place and only hides the in-app config UI (accounts are device-independent).
5. **Firestore becomes read-only from clients.** Verified repo-wide: no client-SDK writes in web or iOS, no Cloud Functions, and all mutations go through the backend Admin SDK (which bypasses rules).

## Availability Note

Global reads + `check-access` depend on the `displayOrder: 1` region. This is **not a new risk**: today `check-access` already targets the first enabled region, so that region being down already blocks sign-in for everyone. The apex formalizes existing behavior. A health-checked/failover DNS record could remove it later.

## Program Acceptance

MVP 3 is complete when:

* A new user can launch, continue as guest, and see enabled regions with no account.
* A guest attempting any client action is routed to sign-in or request-access; the guest client table shows a sign-in call-to-action.
* Email/password sign-in leads to the full config-manager dashboard; sign-out returns to a guest/login state and hides installed-config UI.
* The UI matches the React site's visual language, dark-mode-only, with all colors from the theme layer.
* Firestore is read-only from clients; all mutations go through the API; guest region data comes from the apex `GET /regions`, not relaxed rules.
* All clients route global/read traffic (regions, check-access) to `api.gocloudlaunch.com` and region-specific calls (capacity, create/delete/sync) to the `<regionId>` host.
* Installed/cached configs are shown only when signed in.
* Sign in with Apple and Google work (wired last).
* `./scripts/test.sh apple` (and `api`) pass, including guest-path, apex, and rules coverage.

## Follow-Up

MVP 4: macOS reuse of CloudGatewayKit.
