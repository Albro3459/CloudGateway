# Device Auth Implementation Plan

Status: implemented and verified locally on 2026-10-01. Device authorization
is available when deployed. Deployment and staging verification are pending,
including real Firebase signing, active TTL policies, provider login, and the
Cloudflare/Caddy boundary. Follow the [operator runbook](../docs/device-auth.md)
before returning to the [macOS app plan](macos-app.md).

Completed Firebase schema/rules/TTL definitions, transactional API authorization,
React approval/login returns, the test device client, and emulator integration.
The full `./scripts/test.sh` passed, including the unsigned iOS build. After
security hardening, the `api`, `web`, and `firebase` targets passed with 597 API
tests, 298 web tests, 47 rules tests, and 13 emulator tests. Browser inspection
confirmed that single and nested frames cannot expose approval controls, and
that a cross-origin parent cannot replace the approval window's `top` property.
No macOS or iOS implementation was needed. Security hardening blocks framed
approval, asks users to compare device codes, and requires HTTPS dashboard links
except for literal localhost/loopback development origins. Configure the
[Cloudflare anti-framing rule](../Infrastructure/CloudFlare/README.md#dashboard-anti-framing-rule)
and verify the deployed HTML headers before the test release.

## Outcome And Scope

A device starts an authorization request, opens `/#/auth/code` on the site,
and waits while the user signs in and explicitly approves. The API exchanges
the approved request for a Firebase custom token. The device then signs in to
the existing Firebase account and uses normal Firebase sessions and product
permissions. Firebase owns provider login and sessions. Our API owns the short
lived device authorization request.

Build the backend and browser flow with a test device client first. No macOS
target, tunnel extension, Apple entitlements, native auth adapter, or iOS changes
belong in this work. Existing login, password reset, VPN, account provisioning,
and regional client management must keep their current behavior.

The protocol follows the security guidance in
[RFC 8628](https://www.rfc-editor.org/rfc/rfc8628), with a client-generated
redemption secret. It does not claim RFC wire compatibility or expose an OAuth
authorization server. Code length and lifetime are product choices.

## Existing Integration Points

* `Backend/API/src/app.py` composes FastAPI dependencies. Add injectable device
  storage, token issuance, clock, and randomness seams where tests need them.
  Keep this service separate from the large WireGuard repository contract.
* Existing Firebase Admin initialization uses the API's service-account
  credentials. Reuse those credentials for custom-token signing. SHA-256
  verifiers require no new hashing key or Terraform secret.
* `api.<origin>/api/*` already routes to a regional API host through Caddy.
  React's `buildApexApiEndpoint` and account access check already use it. Keep
  device auth account-level and independent of region selection or capacity.
* Caddy strips `/api` before FastAPI routing and supplies dashboard CORS headers.
  Define internal routes as `/device/*`, public routes as `/api/device/*`.
* Existing token verification checks revocation. Product approval also needs
  valid `Users` and `UserRoles` records and an enabled Firebase Auth user.
  The existing role dependency alone does not check every one of these facts.
* React uses `HashRouter`. Preserve `/auth` password reset and add `/auth/code`.
  Login currently navigates to `/home`, so add a safe approval return path.
* Firebase schema types live in `Backend/Firebase/schema.ts`. Rules and indexes
  live alongside it. All validation enters through `./scripts/test.sh`.

## Wire Contract

Use camelCase JSON, bounded request bodies, strict field validation, the existing
API error envelope, and middleware correlation IDs. `deviceRequestId` identifies
the authorization request and is distinct from an error's diagnostic `requestId`.
Freeze examples and error codes in `docs/api-contract.md` before helpers work
across API and frontend boundaries.

| Public endpoint | Authentication and body | Result |
|---|---|---|
| `POST /api/device/code` | No Firebase session. `deviceSecretHash`, optional bounded `deviceName` | `deviceRequestId`, `userCode`, `verificationUri`, `verificationUriComplete`, `expiresIn`, `interval` |
| `POST /api/device/verify` | Firebase ID token. `deviceRequestId`, `userCode` | Verified display context, request status, and server expiry, without an approving UID or redemption material |
| `POST /api/device/approve` | Firebase ID token. `deviceRequestId`, `userCode`, `decision` (`approve` or `deny`) | Recorded decision, without a custom token |
| `POST /api/device/token` | Device proof. `deviceRequestId`, `deviceSecret` | Pending response, terminal error, or `customToken` |

Creation returns 201. Valid pending polls return 202 with remaining lifetime and
poll interval. Successful exchange returns 200. Define stable device-specific
errors for invalid requests/proofs, expiry, denial, consumption, unavailable
service, and throttling. Throttling returns 429 with `Retry-After`. Wrong proof
must not disclose whether a request is pending, approved, or owned by someone.
Document exact status/code pairs and have API and React tests assert them.

`verificationUri` is the site's `/#/auth/code` route. The complete link carries
the random request ID and displayed code in the hash fragment. Approval always
requires both values and an explicit user action. Code-only lookup is deferred.
No device secret, Firebase token, or custom token belongs in a URL. The optional
device name is untrusted descriptive text, never verified device identity.

The device generates a fresh 32-byte secret with an OS cryptographic random
generator for each attempt. Encode it canonically as unpadded base64url and send
the lowercase SHA-256 hex hash of its 32 bytes at creation. Send the secret only in the
HTTPS polling body. Validate exact encoding and decoded length. Compare hashes
in constant time. Reject a submitted verifier used as the secret. Keep the
secret in device memory and discard it on success, cancellation, expiry, or
quit. Cancellation can stop polling and leave the request to expire.

Generate request IDs with at least 128 random bits and user codes uniformly with
a cryptographic generator. User codes are six-character digit strings, including
leading zeros. Initial lifetime is 300 seconds, measured from creation. Polling,
verification, approval, and retries never extend it. Initial polling interval
is five seconds. The server constructs links from configured dashboard origin,
never a caller-supplied origin or Host header.

## State And Redemption

The stored state is `pending`, `approved`, `denied`, or `consumed`. Expiry is
derived from `expiresAt` and takes precedence over stored state. A successful
approval attaches the verified Firebase UID. Requests are independent, so a
user can approve several devices without maintaining an array on their user doc.

* Verify identity and product access before browser verification and decisions.
  Derive UID from the verified ID token. Never accept a target UID from the body.
* Atomically move pending to approved or denied. The first decision wins across
  accounts and API instances. Repeating the same account's same decision may
  return success. A conflicting decision returns a generic conflict.
* Before redemption, recheck Firebase Auth existence/enabled state and product
  access. Read `Users`, recognized `UserRoles`, expiry, proof, and request state
  in the consuming Firestore transaction. Role removal or disabled/deleted
  users cannot gain access from an old approval.
* Claim approved to consumed transactionally. Only the winning request may mint
  a custom token. Keep all reads before writes and do not sign tokens inside
  transaction callbacks, which Firestore can retry.
* Mint outside the transaction using the existing Admin SDK credentials. Return
  the custom token once. Never persist it. If signing fails or the response is
  lost after consumption, the device starts a fresh flow. Do not reopen the
  request or provide replay-based recovery.
* Check a fresh server time during transaction retries. Handle contention and
  missing documents without accepting stale state or falling back to memory.

Auth and Firestore cannot participate in one shared transaction. Check Auth
before claiming and document that narrow cross-service race. Normal backend/rules
access checks still apply after sign-in.
Consuming our request once does not promise the resulting Firebase custom token
is itself single-use. The device exchanges it promptly and discards it. See
[Firebase custom tokens](https://firebase.google.com/docs/auth/admin/create-custom-tokens).

## Shared Abuse Limits

Keep three shared limits:

| Limit | Initial policy |
|---|---|
| Failed browser code/request guesses | Three per authenticated UID in a rolling five-minute window |
| Creation by source | Five requests per trusted source per rolling five minutes |
| Polling | At most one valid poll per request every five seconds |

Use Firestore transactions for rolling windows and per-request polling state.
Budgets survive code changes, request changes, process restarts, and routing to
another API instance. Failed unknown-request/code checks count against the
authenticated actor without revealing existence. Check device proof before
updating polling state so an invalid caller cannot delay the device.
Successful guesses do not erase failure history. Prune bounded timestamp windows
while updating them, and use TTL only
after the window has ended. Fail closed if persistent limit storage fails.
Commit counted failures before returning an API error. Raising an exception
inside the transaction must not silently roll back the failed-guess budget.

Reuse existing Caddy limits for outer traffic control, including malformed
requests and invalid proof traffic. Use the trusted Cloudflare/Caddy source
for creation limits and test spoofed headers. Keep the loopback-only API
boundary, and change proxy source handling only if needed. Store source digests
with short retention. A plain IP hash is personal data, not anonymization.

Approval requires the random request ID and matching code. Codes can repeat
across requests because they are never looked up alone. Use direct request-ID
lookup without a global code pool, reservations, or allocation budget.

## Firebase Work

Create records lazily. No user migration, seeded empty documents, or request
arrays are needed. The proposed API-only collections are:

| Collection | Purpose and fields |
|---|---|
| `DeviceAuthRequests/{deviceRequestId}` | Secret/code verifiers, sanitized device name, state, `createdAt`, fixed `expiresAt`, `nextPollAt`, and optional `decidedUid`, `approvedUid`, `decidedAt`, `consumedAt` |
| `DeviceAuthLimits/{scopeId}` | Creation-source or failed-guess UID scope, bounded rolling attempt timestamps, cleanup `expiresAt` |

`decidedUid` records the actor for either decision. `approvedUid` exists only
after approval and must match that actor. Do not expose these stored identities
in verification or decision responses. The redeemed token identifies its own
approved account.

Code hashes do not hide a six-digit space from a privileged database reader.
They avoid routine plaintext storage. Only the raw random device secret protects
redemption. Do not store provider credentials, Firebase tokens, custom tokens,
or full request bodies in these documents.

Create the request and update its source creation limit in one transaction.
Never overwrite an existing request ID. Regenerate the random ID on a collision.
Repeated user codes need no special handling. Polling state stays on the request.

Update `schema.ts` types and `FirebaseDocumentTree`, including state-dependent
fields and timestamp semantics. Include `schema.ts` in Firebase type checking,
which currently covers test sources rather than the schema document itself.

Add explicit deny-all rules for both collections. Anonymous users, normal
users, approving users, and admins cannot read, list, or write them through
client SDKs. React uses the API. Admin SDK access bypasses Firestore rules,
so test API authorization separately from rules. See
[Firestore rule conditions](https://firebase.google.com/docs/firestore/security/rules-conditions).

Use direct document reads for requests and limits. No new composite index is
expected. Define TTL and an index exemption on each cleanup `expiresAt` field
through `firestore.indexes.json` field overrides. Verify deployment support
with the installed tooling and keep existing indexes intact. See
[index definitions](https://firebase.google.com/docs/reference/firestore/indexes).

Firestore TTL is asynchronous cleanup, often within 24 hours. The API must
reject expiry even if documents remain. Record deployment, active-policy checks,
retention, and backup handling for these temporary collections. Do not depend
on restoring expired authorization records. See
[Firestore TTL](https://firebase.google.com/docs/firestore/ttl).

## API Work

Add focused models, routes, service, and Firestore store following existing
Python conventions. Reuse the standard error envelope and Firebase initializer.
Inject test dependencies through `create_app` without extending every existing
WireGuard fake or changing provisioning behavior.

Bound inputs and device names, allow only recognized decisions, and normalize codes
without dropping leading zeros. Add shared rate-limit and authorization checks
before expensive work. Use the configured origin to build approval links.

Custom tokens identify the existing approved UID. Do not create a new user or
derive product privileges from client claims. Verify that local credentials can
sign during the staging flow. Use narrow fake token issuers and a mocked Admin
SDK call for our adapter's unit tests. Reuse Firebase's signing implementation.

Set `Cache-Control: no-store` on device responses. Confirm Caddy/Cloudflare
preserve it and do not cache these endpoints. Keep bodies, codes, secrets,
verifiers, tokens, and approval identities out of access logs and exception
messages. Existing API logging uses method/path/correlation/status. Ensure
new Firebase/signing errors are sanitized before generic exception logging.

Scope infrastructure changes to the trusted source boundary and proxy response
behavior actually needed. Update bootstrap/runtime env and operations docs
together when they change. Device auth performs no WireGuard
peer mutation and requires no new service or auth framework.

## React Work

Add a minimal approval page and typed API helpers using the existing apex API
builder and error parsing. Show the current account, code, device description
with an unverified label, and explicit Approve/Deny controls. Cover loading,
signed-out, invalid, expired, throttled, denied, consumed, and complete states.
Never auto-approve a complete link or approve in an effect.

Signed-out visitors go through existing email, Google, or Apple login and return
to the approval route. Permit only the internal device approval destination
with validated request ID/code. Reject external URLs and arbitrary redirect
paths. Do not store tokens or the device secret in browser storage. Preserve
normal login-to-home and password-reset behavior.

An approval login needs account access, not regional inventory or free slots.
Avoid the normal dashboard region-loading dependency on this return path.
Unprovisioned, disabled, deleted, and revoked accounts receive safe errors.

Fence async work against sign-out, account switches, route changes, and unmount.
Clear verified context when the account changes and require verification for
the new account before action. Late verification or approval responses must not
repopulate another account's page. Keep React StrictMode safe, disable duplicate
submissions, and escape all device-supplied display text.

## Tests Through `scripts/test.sh`

Tests land with their corresponding behavior. Keep every release check reachable
through the root entry point and fail the target when required coverage cannot
run. No production project, real credentials, or interactive login is required
for the automated suite.

| Target | Required coverage |
|---|---|
| `api` | Existing compile, pyright, vulture, pytest plus deterministic device auth unit/HTTP tests |
| `web` | Existing Jest, TypeScript, knip, production CRA build plus approval/login/helper tests |
| `firebase` | Schema type check, existing rules tests, new device collection rules tests, and actual API store/exchange tests under Auth + Firestore emulators |
| `infra` | Existing infrastructure checks whenever bootstrap, env, or proxy templates change |

API tests cover leading-zero codes, strict encodings, request-ID collisions,
repeated user codes scoped to different request IDs, no seeded records,
expiry boundaries, pending/backoff, denial, wrong proof,
verifier-as-secret rejection, replay, independent requests, access removal,
disabled/deleted Auth users, first decision wins, and lost-response/signing-failure
behavior. Assert at most one issuer call for competing redemptions. Exercise
rolling windows across their boundaries, retries, separate API instances, spoofed
source headers, unavailable stores, and secret-free logs/errors.

Rules tests seed records through privileged test context, then assert get/list
and every mutation are denied for anonymous, normal, approving, unrelated, admin,
disabled, and unprovisioned clients. Preserve all existing access tests.

Extend the Firebase emulator configuration to include Auth. Extend the Firebase
test target to start Auth and Firestore together with `demo-cloudgateway`.
Run Vitest rules tests and selected Python emulator integration tests under that
one emulator lifetime. Ensure API dev dependencies are available when running
`firebase` alone and propagate failures from both suites. A small runner is
acceptable if needed, with no parallel test framework.

Mark Python emulator tests explicitly in `pyproject.toml`. The `api` target runs
unit tests without requiring emulators. The `firebase` target runs the integration
marker and fails if emulators are absent. Guard emulator host/project settings
so tests cannot fall through to production. Use emulator-compatible token
issuance, never a real service-account file.

Integration tests use the actual Firestore store and API HTTP routes, with
separate service instances sharing one emulator database. Race creation,
approval/denial, and redemption. Test expired requests while TTL has not
deleted them. Complete create, browser approval, device exchange, and Firebase
custom-token sign-in, then assert the same UID and existing rules permissions.

The Auth emulator does not validate custom-token signatures or expiry.
Verify real signing credentials through the staging end-to-end flow.
Firestore emulator tests cannot prove deployed index or TTL behavior.
Record these limits rather than claiming production parity.
See [Auth emulator](https://firebase.google.com/docs/emulator-suite/connect_auth)
and [Firestore emulator](https://firebase.google.com/docs/emulator-suite/connect_firestore).

React tests cover explicit confirmation, no automatic approval, all terminal
states, throttling, malformed routes, duplicate clicks, account switches,
sign-out, unmount, and late responses. Extend existing Login tests for all
provider return paths and unsafe redirects. Assert `/auth` and ordinary login
still behave correctly. Manual browser checks use the minimal test device client
and each supported provider without printing secrets or tokens.

Before release run `./scripts/test.sh api web firebase`, plus `infra` if touched.
Run the full `./scripts/test.sh` after final integration to catch existing Apple
and infrastructure regressions. Document any unavailable prerequisite as a
failed release gate. Local validation is recorded in the status above.

## Logical Commits And Delegation

The main agent owns contracts, security decisions, integration, the index, and
local commits. Use `gpt-6-luna` helpers at high or xHigh effort as needed during
implementation. Helpers receive bounded tasks and file ownership, report their
changes and validation, and do not stage, commit, push, or deploy. Keep shared
files under one owner and integrate dependent work in order.

| Checkpoint | Completed work and evidence | Helper assignment |
|---|---|---|
| 1. Firebase storage contract | Schema, deny-all rules, TTL/index definitions, schema type check and rules tests, Firebase docs | Luna high, after the main agent finalizes the contract |
| 2. API device authorization | Actual transactional store, limits, routes, token issuance, unit/HTTP tests, API contract, necessary env/proxy changes | Luna xHigh for transaction/auth work, main agent resolves cross-service decisions |
| 3. Browser approval | Approval page, safe login return path, typed helpers, Jest coverage, web docs | Luna high, against the reviewed API contract |
| 4. Integrated validation and release docs | Auth/Firestore emulator exchange and races, `test.sh` integration, operator runbook, staging/release checklist | Luna xHigh for integration helpers, main agent verifies the complete flow |

API behavior tests belong in checkpoint 2 and frontend tests in checkpoint 3.
Checkpoint 4 adds integration evidence, not delayed basic coverage. Bring
emulator coverage forward if needed to establish checkpoint 2 correctness.
Split a large checkpoint only at a working, testable boundary. Do not commit
unused abstractions, incomplete endpoint sets, or knowingly failing checks.

Hold review until a logical checkpoint is complete. The main agent then reviews
the complete diff and evidence. Use a Luna xHigh review helper for substantial
auth or transaction changes when useful. A separate review agent is optional.
Prioritize auth bypass, race/expiry failures, log leaks, regressions, and dead
code. Assign bounded fixes, remove unused code, rerun affected targets, and
review the final diff again. Repeat until material findings are resolved, then
make the logical local commit. Run a final review across all checkpoints after
the integration gate. Record real limitations instead of weakening checks.

## Docs And Release Gate

Update `docs/api-contract.md`, the API/Firebase/Web READMEs, index/TTL operations
notes, and deployment instructions with the corresponding behavior. Add an
operator runbook at `docs/device-auth.md` covering constants, trusted source
handling, signing credentials, emulator commands, failure recovery, retention,
deployment, verification, and rollback. Keep the macOS plan linked here.

After implementation and local review, release proceeds as a separate authorized
operator action:

1. Back up Firestore before deployment. Confirm the existing staging Firebase
   credentials and dashboard/API origins.
   Verify real custom-token sign-in as part of the deployed end-to-end flow.
   No new signing or hashing key is assumed.
2. Deploy Firebase rules/index/TTL configuration. Verify policies are active and
   direct client access is denied. Existing product rules remain intact.
3. Deploy backend and any required host/proxy configuration. Device auth is
   available immediately. Verify exact origin/CORS and no-store behavior in staging
   before production deployment.
4. Deploy React after the API is ready. Exercise each login provider, pending,
   approval, denial, expiry, throttling, account switching, concurrent redemption,
   and the resulting Firebase UID/product permissions using a test device client.
5. Record the deployed contract and successful end-to-end evidence. Only then
   resume macOS implementation with a minimal app/system-extension proof of concept.

Existing deployment wrappers can push commits/tags or publish the site. Do not
invoke them during planning or local implementation without explicit deployment
authorization. Never push as part of the requested logical local commits.

Rollback restores the prior site/API versions. Temporary requests expire without
a data migration. Already established Firebase sessions follow existing account/session policy. Do not revoke every
device's sessions as an automatic rollback or local sign-out action.

Done means the reviewed flow works against deployed Firebase/API/React, all
required `test.sh` targets pass, docs match the deployed contract, and no macOS
or iOS implementation was required to validate it.
