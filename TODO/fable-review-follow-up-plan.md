# Fable Review Follow-Up Plan

Plan to resolve the Fable code review of the `apple` PR (`743e500..HEAD`).
Decisions below reflect the maintainer's chosen approach for each finding.
Items marked **Ignore** are intentionally not being changed and are recorded so
they are not re-raised.

---

## Cross-cutting: auth provider ordering standard - DONE

**Resolution:** iOS - login screen already Email/Apple/Google; `missingLinkProviders`
now uses an explicit `[.password, .apple, .google]` order; `accountDeleteReauthMethod`
and `prepareRecentLoginRecovery` reordered to Apple -> Google -> password. Web -
`Login.tsx` already Email/Apple/Google; link modal reordered Apple before Google;
`ALL_AUTH_PROVIDER_IDS` reordered; `reauthenticateForAccountDeletion` and
`reauthenticateForAccountLinking` reordered to Apple -> Google -> password;
`requiresPasswordReauth` now true only when neither Apple nor Google is linked so the
delete modal's password field matches the reauth precedence. Tests lock the order on
both platforms. Apple + Web suites green.

Apply everywhere before the individual fixes so the UI is consistent.

- **Login and linking a new provider** - always order providers:
  1. Email & password
  2. Apple
  3. Google
- **Reauthentication (delete account / recent-login recovery)** - email & password
  goes **last** when other providers are linked, for convenience:
  1. Apple
  2. Google
  3. Email & password

Audit and normalize ordering in:
- iOS: `Frontend/Apple/iOS/CloudGateway/ContentView.swift` (login screen, account-link
  sheet, reauth prompts) and any provider list in `CloudGatewayViewModel.swift`.
- Web: `Frontend/Web/src/pages/Login.tsx`, the account-link sheet and the
  reauth branch in `Frontend/Web/src/pages/Home.tsx`.

---

## Medium

### 1. Account-linking reauth must not revoke Apple/Google grants (iOS) - DONE
**Decision:** Works today (user just re-links on next sign-in) but we should not
revoke a grant merely to link a new provider.

**Resolution:** `reauthenticateWithApple`/`reauthenticateWithGoogle` take a
`revoke: Bool`; the revoke/disconnect only runs when `revoke` is true. Account
deletion passes `revoke: true`; the account-link recovery flows
(`completeAccountLinkAppleReauth`, `prepareRecentLoginRecovery`) pass
`revoke: false`. Screenshot fixture + mock updated. Tests assert the flag per
path; full apple suite green.

**Approach:** Split the reauth methods into two variants:
- Deletion variant - keeps `Auth.auth().revokeToken(withAuthorizationCode:)`
  (Apple) and `GIDSignIn.disconnect()` (Google). Used only by account deletion.
- Plain reauth variant - performs `user.reauthenticate(with:)` only, no revoke /
  disconnect. Used by the account-linking recovery flow.

**Files:**
- `Frontend/Apple/iOS/CloudGateway/CloudGatewayFirebaseService.swift:184-205`
  (`reauthenticateWithApple`, `reauthenticateWithGoogle`) - add non-revoking
  variants (or a `revoke: Bool` parameter, default false).
- `CloudGatewayViewModel.swift:358-381` (`completeAccountLinkAppleReauth`) and
  `:598-615` (Google link recovery) - call the plain reauth variant.
- Leave `deleteAccount*` paths (`:543-565`) on the revoking variant.

### 2. Delete confirmation must delete the intended client only (iOS) - DONE
**Decision:** Great catch - delete exactly the client named in the alert.

**Resolution:** New `deleteClient(_ option:)` deletes the explicitly-passed
option; the alert captures `clientPendingDelete` into a local constant and passes
it, so a background refresh cannot drift the target. `selectedClientId` is cleared
only when it matches the deleted client. Regression test proves the captured
client is deleted even when the selection drifts. Full apple suite green.

**Approach:** The confirm handler currently calls `deleteSelectedClient()`, which
resolves `selectedClientOption` at confirm time and can drift after a background
refresh prunes/moves the selection. Delete `clientPendingDelete` directly.

**Files:**
- `Frontend/Apple/iOS/CloudGateway/ContentView.swift:145-158` - pass the captured
  `clientPendingDelete` into the delete call.
- `CloudGatewayViewModel.swift:518-541` - add/repurpose a
  `deleteClient(_ option:)` that takes the explicit option instead of reading
  `selectedClientOption`.

### 3. Offline cold launch must surface cached, installed VPNs (iOS) - DONE
**Decision:** Show cached configs when offline and allow toggling them; bypass the
Firestore pull when there is no connectivity.

**Resolution:** `displayedClientOptions` renders snapshot-backed rows from
`installedSnapshots` when a remote refresh is unavailable, region-filtered and
de-duped against the remote list. `applyRemoteRefreshUnavailable` reloads the
local cache before marking rows stale. A `remoteRefreshUnavailable` flag gates
the fallback so a client removed remotely while online does not linger as a
ghost row. Covered by CloudGatewayKit + iOS view-model tests; full apple suite
green.

**Approach:** Client rows render only from `filteredClientOptions`, which is
populated by `applyRemoteState` after a successful network load. When the remote
fetch fails, fall back to rendering rows from the cached
`installedSnapshots`/tunnel statuses so an installed (possibly connected) tunnel
stays visible and controllable (start/stop). Reconcile with remote once
connectivity returns.

**Files:**
- `Frontend/Apple/iOS/CloudGateway/CloudGatewayViewModel.swift:846-852`
  (`loadLocalState`/`applyLocal`) - expose installed snapshots as toggleable rows.
- `ContentView.swift:609-661` (`clientsPanel`) - render a snapshot-backed row set
  when `filteredClientOptions` is empty but snapshots exist; keep the VPN toggle
  wired to the tunnel manager (which is local/offline-capable).
- Ensure `markRemoteRefreshUnavailable` stale text attaches to rows that actually
  render.

### 4. Account-deletion race can orphan a live WireGuard peer (API) - DONE
**Decision:** Accept the race. Do **not** delete the `UserRoles` doc first and do
**not** add fencing. The only way to trigger it is a user racing their *own*
account deletion from a second device/browser in a sub-second window; the cost is
a single orphaned peer that the next `cloudgateway-sync-peers` reconciles. Not
worth the complexity.

**Why not "delete role first" (rejected):** deleting `UserRoles` first breaks the
flow under the current code:
- `check_access` (which the client calls right after login/reload) runs
  `require_role_or_disable_unprovisioned` (`auth.py:51-57`); with the role gone it
  calls `disable_auth_user` -> `revoke_refresh_tokens` (`firebase.py:295-301`),
  disabling the account and revoking tokens.
- Token verification uses `verify_id_token(check_revoked=True)` (`firebase.py:84`),
  so once revoked the user's still-unexpired ID token is rejected too - including a
  retry of `DELETE /account`.
- `_ensure_account_delete_allowed` (`routes.py:596-602`) only allows an
  unprovisioned retry when `role is None` **and** the `Users` doc is also gone;
  mid-deletion the `Users` doc still exists, so a retry raises "not available".

Making role-first safe would require relaxing `_ensure_account_delete_allowed` for
an in-progress state, stopping `check_access` from disabling/revoking during a
deletion, and surviving `check_revoked` - too much for the race it closes.

**Approach:** No code change to the fencing. Add a short code comment at
`delete_account` noting the accepted race and that `cloudgateway-sync-peers`
reconciles any orphaned peer. (Optional: leave the ordering as-is; snapshot ->
remove peers -> hard delete.)

**Files:**
- `Backend/API/src/routes.py:374-395` (`delete_account`) - comment only.

### 5. Region unreachable must not permanently wedge deletion (API) - DONE
**Resolution:** `_delete_remote_client` classifies failures - HTTPError (host
answered: challenge/auth/HTTP status) stays non-transient and aborts;
URLError/TimeoutError (unreachable) is marked transient. `_remove_account_peers`
continues past a transient failure (logging `ACCOUNT_DELETE_PEER_UNREACHABLE`) so
the account docs are hard-deleted and `cloudgateway-sync-peers` removes the
orphaned peer (sync drops host peers with no matching active client). Local peer
failures stay fatal. Tests cover both branches. API suite green.

**Decision:** Distinguish a genuinely unreachable server (DNS/connection error)
from a Cloudflare challenge / auth failure. On unreachable, still remove/mark the
client in Firestore so a later peer-sync (when the host returns) reconciles the
peer. Challenge/auth failures should still abort so we do not lose the peer
silently.

**Approach:**
- In `_remove_account_peers`, classify the failure:
  - Connection refused / DNS resolution failure / timeout (host truly
    unreachable) -> proceed to write the terminal/REMOVED state (or delete the doc)
    for that client and continue the deletion. Peer reconciliation happens on the
    next `cloudgateway-sync-peers` when the host is back.
  - Cloudflare challenge / HTTP auth error -> abort as today (do not assume the
    peer is gone).

**Files:**
- `Backend/API/src/routes.py:635-666` (`_remove_account_peers`,
  `_delete_remote_client`) - branch on the URL/HTTP error type.
- Confirm the sync path removes peers whose docs are terminal/absent.

### 6. Delete-account errors must be visible and human-readable (Web) - DONE
**Resolution:** Added a `deleteAccountError` state rendered inline inside the
delete-account modal (mirrors the link sheet's `linkError`), cleared on
open-start and modal close. `handleDeleteAccount` now sets the inline error for
both API failures (`response.error`) and thrown Firebase errors via a new
`getDeleteAccountErrorMessage` code mapper (popup-cancel codes still suppressed).
No more error banners painted behind the overlay. Tests cover API-failure and
mapped-Firebase-error cases. Web suite green.

**Decision:** Handle these errors properly.

**Approach:**
- Add an inline error region inside the delete-account modal (mirror the link
  sheet's `linkError`) so the message is not painted behind the modal overlay.
- Map Firebase error codes to friendly copy (reuse/extend the link flow's
  `getLinkErrorMessage`) instead of showing raw `error.message`.

**Files:**
- `Frontend/Web/src/pages/Home.tsx:812` (banner), `:1156-1188` (modal),
  `:320-326` (error handling) - render error inside the modal; add code mapping.

---

## Low - to fix

### iOS / CloudGatewayKit - DONE (password-trim also removed on iOS; Web password-trim + capacity note below)
- **PacketTunnelProvider `handleAppMessage` returns the private key.** It is dead
  code (nothing calls `sendProviderMessage`). Remove the override. If it is ever
  reintroduced for runtime stats, strip `PrivateKey`/`PresharedKey` lines first.
  `Frontend/Apple/iOS/CloudGatewayTunnel/PacketTunnelProvider.swift:35-48`.
- **Role fallback double-optional.** `(try? await fetchUserRole(...)) ?? access.role`
  is `String??`; a missing `UserRoles` doc yields `.some(nil)` and drops the
  `access.role` fallback. Flatten so a missing doc still falls back to the
  check-access role. `CloudGatewayViewModel.swift:883`.
- **Password trimming - remove it everywhere.** Never trim a user's password, on
  sign-in, sign-up, or link, on **web or iOS**. Trim email only.
  - iOS: `CloudGatewayViewModel.swift:289` (sign-in, already raw - verify),
    `:335-342` (`linkEmailPassword`), `:545-549`, `:578-582` (reauth) - stop
    trimming password.
  - Web: audit `Login.tsx` / `CreateUser.tsx` / `Home.tsx` link+reauth for any
    password `.trim()` and remove.
- **`clearRemoteState` leaves the password populated.** Clear `password` on
  sign-out; leave `email`. `CloudGatewayViewModel.swift:924-942`.
- **`clientId` interpolated into the API path.** Handle the unvalidated path
  segment: validate `clientId` against a safe charset (parity with region-id
  validation) before building the path, or switch to the Firestore doc ID.
  `CloudGatewayServicing.swift:117-126`, `CloudGatewayFirebaseService.swift:423`.
- **Parser: trailing `[Peer]` header.** Error on a `[Peer]` section with no
  public key that appears as the final line, instead of silently dropping it.
  `GatewayWireGuardConfigParser.swift:76`.
- **Parser: allow prefix-less addresses.** Accept `Address`/`AllowedIPs` values
  without a `/prefix` as implicit `/32` (IPv4) / `/128` (IPv6).
  `GatewayWireGuardConfigParser.swift:274-286`.
- **`cache.save` failure after tunnel install.** If `cache.save` throws after the
  profile + keychain secret are written, the app shows the config as not
  installed. Surface an error telling the user the install partially completed and
  to refresh/reinstall (which reconciles), rather than failing silently. Keep the
  installed profile. `CloudGatewayConfigManager.swift:93`.
- **(Optional, only if quick) Per-region capacity fetched serially.** 1-3 regions
  today, so low impact. If trivial, parallelize with `withTaskGroup`.
  `CloudGatewayFirebaseService.swift:351-369`.
  **Deferred (intentionally):** the app target is Swift 5 mode and `withTaskGroup`
  would capture the non-Sendable service `self` in `@Sendable` task closures for a
  negligible gain on 1-3 sequential requests. Skipped per "only if quick".

**Resolution (iOS / CloudGatewayKit):** removed the `handleAppMessage` override;
flattened the role double-optional; stopped trimming passwords everywhere on iOS
(email still trimmed) and clear `password`/`deleteAccountPassword` on sign-out;
added `validatedClientId` (safe charset) before interpolating `clientId` into the
delete path; parser now errors on a trailing `[Peer]` with no public key and
normalizes prefix-less `Address`/`AllowedIPs` to `/32`//`/128`; `cache.save`
failure after install now throws `installCachePersistFailed` (keeps the profile).
Tests added/updated across CloudGatewayKit + iOS suites; apple suite green.
Web password-trim audit tracked with the Web fixes below.

### Web - DONE
- **Account dropdown never closes on outside click / Escape.** Add outside-click
  and Escape handling to close the menu. `Home.tsx:748-797`.
- **`account-exists-with-different-credential` copy.** Remove the misleading
  "Sign in with email and password first." sentence from both the Apple and
  Google handlers. `Login.tsx:43-45, 64-66`.
- **Reauth provider ordering (see standard above).** When multiple providers are
  linked, offer reauth as Apple -> Google -> Email & password (email last).
  `Home.tsx:277-285, 1177-1188`.

**Resolution (Web):** account menu now closes on outside mousedown / Escape via a
gated `useEffect` + `accountMenuRef`; the misleading account-exists sentence is
replaced with "Sign in with a method you've already linked."; reauth ordering
handled with the cross-cutting standard; and the Web password-trim audit removed
all password `.trim()` (email still trimmed) across `Login.tsx` and `Home.tsx`
(`CreateUser.tsx` had none). Tests added for menu close-on-Escape/outside-click.
Web suite green.

---

## Low - intentionally not changing (Ignore)

- **Status label `.connecting -> "Connected"` / `.disconnecting -> "Disconnected"`**
  - intentional and correct. Apple's tunnel state callbacks are delayed and
  inconsistent; Control Center updates optimistically and immediately, so we
  match that behavior. `CloudGatewayViewModel.swift:1071-1087`.
- **`_origin_host` hardcoded fallback domain** - single environment; not an issue.
  `routes.py:675-681`.
- **Validate `region_id` before cross-region call** - no injection risk; a bad
  value only produces an unresolved-host error. `routes.py:646`.
- **`ACCOUNT_DELETE_STARTED` logs email** - acceptable, keep. `routes.py:374-380`.
- **Cache headers on `/regions`** - unnecessary. `routes.py:60-71`.
- **`api.gocloudlaunch.com` hardcoded in Caddy template** - fine, keep.
  `Infrastructure/OCI/host/Caddyfile.template:6`.
