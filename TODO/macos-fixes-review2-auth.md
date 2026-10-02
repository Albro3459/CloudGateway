# macOS auth fixes review, loop 2

Reviewed final working tree on 2026-10-02
Status: final source review complete, no current findings

## Confirmed findings

None. Loop 1 SDK fixture construction is corrected. No additional concrete
auth, cache, or cancellation defect was confirmed in this final pass.

## Final source checks

- `FirebaseTokenVerifier` keeps invalid, expired, revoked, disabled, and
  deleted identities on the 401 path. Checked installed SDK inheritance and
  its remote revocation/user lookup. Certificate, backend, permission, and
  initialization failures reach the separate 503 path.
- `AuthUnavailableError` returns a fixed message. The API handler logs its
  error code without the chained exception, verifier details, or credentials.
  Corrected regressions use real SDK exception constructors and the SDK client
  revocation method with a correctly constructed fake app credential.
- Native access checks classify 503 as unavailable, verify the response URL,
  and validate UID/role before success. Restoration and refresh preserve the
  Firebase session and disk cache on unavailability while hiding current
  inventory. Authorization denial still clears the cache and signs out.
  Transport-only cache fallback remains unchanged.
- Removed history is excluded before the 1,000 live-row limit. Ownership
  validation still covers every supplied row. Usable/enabled config filtering,
  duplicate checks, authorized hashes, pruning, selection, role downgrade,
  account isolation, and installed-cache bounds remain in place.
- Rechecked the revised controller cancellation path. It cancels old remote
  reads without waiting for them, keeps pending command/recovery drain busy,
  and gates replacement auth/inventory work on that drain. Late HTTP/Firestore
  completion hits task/UID/session guards before presentation or cache changes.
  `authorize` also checks cancellation on actor entry. Prior command recovery
  finishes before a new account can authorize replacement metadata.
- Read native response/error and removed-history regressions again. API
  regressions cover real identity denials, infrastructure exceptions,
  initialization, revocation lookup, sanitization, and successful access.

## Validation and limits

Root reports API pyright, vulture, and 616 pytest cases passing. Root owns the
remaining full-suite validation. This reviewer ran no tests/builds, made no
production/index edits, and performed no live auth or VPN actions.

Controller orchestration remains source-reviewed rather than directly tested
by the host-free classifier tests. Signed runtime, Firebase persistence and
listener ordering, and actual OS/Firestore cancellation latency remain runtime
checks. This concludes auth review loop 2 of 2.
