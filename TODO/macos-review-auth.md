# macOS authentication review

Baseline: `8cc964a`, 2026-10-02
Status: fresh source review complete, 2 open P2 findings

## Confirmed findings

### AUTH-1 (P2): Removed client history eventually blocks every online config

- Trigger: an account has 1,001 readable `Instances` documents, even when only
  one is active. For admins, this count includes every owner's removed clients.
- Evidence: `CloudGatewayMacInventoryService.swift:78-79` queries all Instances
  with only an owner filter for users. The mapper preserves `removed` rows
  (`CloudGatewayAppServiceFacade.swift:330-348`).
  `CloudGatewayMacAccountCache.swift:108` rejects the entire options array above
  1,000 before `:117` filters usable configs and enabled regions.
  Backend deletion retains each document with `status=removed`
  (`Backend/API/src/firebase.py:742`, `:864-874`).
- Impact: a full inventory refresh throws `invalidMetadata`, and the controller
  clears both online options and installed rows in its generic failure handler
  (`CloudGatewayMacAppController.swift:268-272`). Current active configs become
  unavailable until old cloud documents are removed. Refresh cannot recover.
  This can happen through ordinary create/delete history without exceeding a
  region's active capacity.
- Fix: discard removed history before enforcing the bounded authorization
  inventory limit. Keep the installed cache limit and fail closed on duplicate
  identifiers or invalid active config material. Bound/page the Firestore read
  separately if fleet history also needs a download limit.
- Validation: source trace only. No code changes or tests run.

### AUTH-2 (P2): A Firebase verification outage signs out valid accounts and clears offline inventory

- Trigger: the regional API remains reachable, but Firebase certificate fetch
  or revocation/user lookup fails temporarily during `/api/auth/check-access`.
- Evidence: `Backend/API/src/firebase.py:90-94` catches every exception from
  `verify_id_token(..., check_revoked=True)` as `AuthRequiredError`.
  `Backend/API/src/errors.py:5` maps that error to HTTP 401.
  `CloudGatewayMacInventoryService.swift:65` treats every 401 as confirmed
  access denial. Restoration and refresh then persist `cache.deny` and sign out
  (`CloudGatewayMacAppController.swift:204-210`, `:260-267`).
  The installed Firebase Admin SDK distinguishes `CertificateFetchError` from
  invalid tokens (`firebase_admin/_token_gen.py:404-405`), and revocation checks
  call `get_user` (`firebase_admin/_auth_client.py:756-761`). These are actual
  upstream operations, not solely local token parsing.
- Impact: a temporary infrastructure failure removes the valid local session
  and its offline config metadata. Profiles and secrets remain installed. The
  user must finish browser sign-in again, and a later online selection installs
  fresh metadata/profile state because the installed cache was cleared. The
  displayed claim that account access was denied is false for this trigger.
- Scope: the root cause is shared API error handling. The macOS-specific
  consequence is destructive denial handling during restoration and refresh.
- Fix: return a retryable service error for certificate/transport/backend
  failures. Reserve 401 for invalid, expired, revoked, disabled, or deleted
  identities. macOS should keep its session/cache when the check is unavailable
  and expose a retry without treating that response as authorization success.
- Validation: repository and installed dependency source trace only. No outage
  was induced, and no live auth or tests were run.

## Evidence and limits

- Reviewed the device secret generator and HTTP client, exact approval URL
  validation, redirects, response bounds/status mapping, monotonic polling,
  expiry, backoff, cancellation, and late response fences.
- Reviewed Firebase custom-token session publication, exchange/sign-out
  generations, failed cleanup quarantine, startup marker handling, auth
  listeners, and controller sign-in/restoration/sign-out integration.
- Reviewed UID/session fences, role downgrade persistence, owner filtering,
  online authorization/config hashes, installed selection, per-account cache
  storage, and transport-only offline fallback.
- Traced device-auth request creation, approval, secret binding, atomic token
  consumption, product access checks, API verification, and Firestore rules.
- Read existing browser, device-client, Firebase exchange, and account-cache
  tests as evidence. They cover cancellation, late SDK completion, cleanup
  failure, role downgrade, and account isolation through fakes. They do not
  cover the two integration failures recorded above.
- No severe auth bypass, exposed auth token, or device-secret leak confirmed
  within this review scope. No unresolved source hypothesis is presented as a
  finding.
- No code changes, builds, tests, live sign-in, endpoint requests, or VPN
  actions. Actual Firebase SDK listener/keychain persistence ordering,
  abrupt process-exit marker durability, signed macOS runtime behavior, and
  deployed approval/Firestore contracts still require runtime verification.
