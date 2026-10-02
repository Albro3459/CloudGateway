# macOS auth fixes review, loop 1

Baseline: approved implementation plan, working tree, 2026-10-02
Status: source review complete, 1 finding corrected, no open findings

## Confirmed findings

### R1-AUTH-1 (P2): SDK exception fixtures prevent API test collection

- Trigger: collect `Backend/API/tests/test_firebase_auth.py` with the installed
  Firebase Admin SDK.
- Evidence: module-level parameter lists construct
  `auth.ExpiredIdTokenError("private verifier details")` at line 21 and
  `auth.CertificateFetchError("private verifier details")` at line 41.
  Installed `firebase_admin/_token_gen.py:437-439` and `:427-431` require both
  `message` and `cause` for these constructors.
- Impact: test module import raises `TypeError`, blocking the API validation
  target and all new verifier regressions.
- Fix: pass `None` for `cause` in both fixtures. Keep the real SDK error types.
- Resolution: root added the required `None` arguments during loop 1. Source
  verified. Root owns API validation.
- Validation: inspected repository and installed dependency signatures. No
  tests or builds run by this reviewer.

## Coverage and limits

- AUTH-2: checked the actual installed SDK hierarchy. Expired/revoked ID token
  errors inherit `InvalidIdTokenError`. Certificate fetch errors inherit
  `UnknownError`. Disabled/deleted users are separate SDK identity exceptions.
  Network, backend permission, initialization, and unexpected verification
  failures map to sanitized 503 responses without authorizing the identity.
- Traced API error handling. The new `AuthUnavailableError` uses a fixed
  message, and the `ApiError` handler logs the error code without exception
  details or cause. New tests use real SDK exception classes, plus the SDK
  client revocation-check method with an injected user lookup.
- Traced native 503 handling through both restoration and inventory refresh.
  Unavailable checks preserve the Firebase session and disk cache, clear
  visible inventory, and require a successful retry. Only transport errors
  permit previously authorized cache fallback. Genuine 401/403 and SDK
  identity denials retain durable cache denial and local sign-out.
- AUTH-1: removed rows are filtered before the live inventory cap. Ownership
  checks still cover the supplied array, and duplicate identifiers, hashes,
  installed cache limits, role changes, and revoked config pruning remain.
  New tests cover large removed history, active inventory overflow, reopening
  the cache, and removal of previously installed configs from authorization.
- Inspected controller drain integration and account/session fences. New
  restoration/inventory work awaits prior cancellation before remote reads
  and cache mutation. Cancellation waits only on captured older tasks and
  coordinator recovery. The awaited tasks do not wait on their replacement
  cancellation task in the reviewed control flow. Coordinator tests cover
  referenced secret commit/cache recovery and unreferenced secret rollback.
- Native classifier tests cover response statuses, SDK denial/transport
  mapping, and preservation of `CancellationError`. Controller preservation
  and its complete task chain remain source-reviewed rather than directly
  exercised by those host-free classifier/coordinator tests.
- No further concrete defect, severe authorization flaw, or new secret leak
  confirmed in this review scope. No unresolved hypothesis promoted to a
  finding.
- No production edits, index writes, builds, tests, or live auth/VPN actions by
  this reviewer. Root owns validation. Signed runtime behavior, real Firebase
  keychain/listener ordering, and OS/Firestore cancellation latency remain
  separate runtime checks.
