# macOS PR authentication review

PR: #15
Baseline: `origin/main...cdb817d`, 2026-10-02
Status: fresh source review complete, no new confirmed findings

## Confirmed findings

None. Reviewed the complete auth additions and their integration across API,
Firebase, Web, and the native macOS app. Earlier fixes were checked in the
current source and were not treated as proof of correctness.

## Coverage

- Device protocol: random request IDs, unbiased six-digit codes, fresh 32-byte
  device secrets, canonical base64url proof, digest binding, no token/secret in
  approval URLs, exact native approval origin, response validation, redirects,
  bounded HTTP calls, monotonic polling, expiry, backoff, and late results.
- API: request/response models, authenticated verification and explicit
  approval/denial, Auth existence/enabled checks, transactional Users/UserRoles
  checks, first-decision ownership, idempotent decisions, request-scoped proof,
  atomic consumption before signing, signing failure/replay, and sanitized
  errors/no-store responses.
- Limits and retention: transactionally shared source/UID limits, rolling
  windows, valid-proof polling limits, invalid-proof isolation, TTL definitions,
  and independent expiry checks. Traced the trusted loopback/Caddy source
  header against the configured origin mTLS boundary.
- Web: internal-only approval return paths, password/Apple/Google login return,
  approval independent of region capacity, top-level-window requirement,
  escaped unverified device description, explicit clicks, duplicate-click
  guard, UID/route/generation checks, and stale verification/decision results.
- Firebase: device collections deny all direct client reads/writes, ordinary
  owner/admin inventory rules remain intact, and memory-only native Firestore
  caching keeps cloud private configs out of the SDK disk cache.
- Native session: quarantined in-flight exchange, generation checks,
  cancellation/sign-out cleanup, startup marker, failed cleanup, listener
  integration, restoration, and local sign-out without account-wide revocation.
- Native account/cache: UID/session fences, command cleanup drain before new
  authorization, owner filtering, role downgrade persistence, metadata-only
  namespaces, config hashes/references, removed history, live/cache bounds,
  pruning, selection, and transport-only offline fallback. Account/cache
  cutoffs are intentional for this new macOS app, not migration defects.
- Shared verifier: checked installed SDK exception hierarchy and revocation
  lookup. Genuine identity denial remains 401. Certificate/backend outages
  return sanitized 503 and preserve native sessions/disk cache without
  authorizing visible online inventory.
- Read the device protocol/transaction/emulator, Web route/approval/login,
  native client/browser/session/cache, and verifier regressions as supporting
  evidence. No tests were run by this reviewer.

## Scope decisions and limits

The pre-existing `/auth/check-access` Users/UserRoles policy difference was
examined against device issuance and Firestore rules. No new PR authorization
bypass was established from that difference. Offline use retains previously
authorized configs by design, and sign-out/quit retain the running VPN.

No severe new auth flaw or token/device-secret leak was confirmed. No unresolved
source hypothesis is presented as a finding.

No production edits, builds/tests, live sign-in, VPN actions, index writes,
commits, or pushes. Root owns validation. Signed Firebase keychain/listener
ordering, abrupt-exit marker durability, deployed TTL/indexes and proxy/header
trust, real production custom-token signing, anti-framing headers, and end-to-end
browser approval still require runtime/deployment evidence.
