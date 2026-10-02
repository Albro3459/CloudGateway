# Device authorization

Device authorization lets a client sign into an existing CloudGateway account
through the web dashboard. The API stores temporary requests in Firestore.
The browser explicitly approves or denies a request, and the device exchanges
its proof for a Firebase custom token. This flow does not create accounts or
change VPN clients, WireGuard peers, or iOS behavior.

## Protocol

See [API contract](api-contract.md) for endpoint payloads and error codes.
Requests live for 300 seconds. The device polls at most once every five seconds.
The browser needs both the random request ID and the six-digit displayed code.
A code alone cannot locate or approve a request. Codes may repeat across requests.

Each attempt needs a fresh 32-byte secret generated on the device with a
cryptographic random generator. Send its lowercase SHA-256 hex digest at creation.
Send the original bytes encoded as canonical unpadded base64url only in the
polling body. Keep the secret in memory and discard it when the attempt ends.
Never bundle it, derive it from a device ID, reuse it, or put it in a URL.

The complete verification link contains the request ID and code in the site's
hash fragment. It never contains the device secret or a Firebase token.
Device names are unverified descriptions. Approval always requires a click by
the signed-in user and asks them to match the displayed code on their device.
Framed pages stop before mounting the approval flow or contacting the API.
Approval links require an HTTPS dashboard origin. HTTP is allowed only for
`localhost` or literal loopback IPs during development. A dev server can bind to
`0.0.0.0` while its configured dashboard origin uses `http://localhost:<port>`.
An approval login checks account access without depending on region availability
or free VPN slots.

A pending request can become approved or denied. The first decision wins.
An approved request is claimed as consumed in a Firestore transaction before
minting a custom token. Only that winner can mint. Signing failure or a lost
response requires a new attempt, even if the device did not receive a token.
Do not reopen consumed requests. Exchange a received custom token promptly
with Firebase Auth and discard it. Consuming our request once does not make
Firebase's custom token itself single-use.

Firebase Auth and Firestore cannot share a transaction. Auth existence and
enabled state are checked before consumption, while product access is checked
inside the consuming transaction. Account changes in the narrow interval
between services are still subject to normal API and Firestore access checks.

## Source boundary and limits

Creation is limited to five requests per trusted source in a rolling five-minute
window. Failed browser guesses are limited to three per authenticated UID in
that window. A valid device proof can poll once every five seconds. Firestore
transactions share these limits across API processes and hosts. Invalid proofs
do not change the valid device's polling deadline.

The production API listens only on loopback. Start Uvicorn with
`--no-proxy-headers` so its connection address stays intact. Caddy replaces
`X-CloudGateway-Client-IP` with Cloudflare's `CF-Connecting-IP`. The API accepts
that dedicated header only from a loopback connection and ignores client
forwarding headers on other connections. The origin firewall and authenticated
origin pulls restrict Caddy traffic to Cloudflare. Keep all three protections
when changing proxy configuration. Existing Caddy limits cover outer traffic.

Source hashes are short-lived personal data, not anonymous data. Neither the
API nor the operator should log request bodies, codes, secrets, verifiers,
approval identities, auth tokens, or custom tokens. Log only the existing
method, path, correlation ID, status, and safe error code.

## Storage and retention

`DeviceAuthRequests` and `DeviceAuthLimits` are API-only collections. Client
SDKs, including admin users and the approving user, cannot read or write them.
Firebase Admin bypasses these rules, so API authorization is tested separately.
Records are created lazily. No user migration or empty documents are needed.

Both collections use TTL on `expiresAt`, with an index exemption for that field.
Deploy the existing Firebase index configuration and verify both TTL policies
are active before API deployment. See [Firebase operations](../Backend/Firebase/README.md).
TTL deletion is asynchronous. The API checks expiry itself and never relies on
cleanup for authorization. Limit records remain through the last attempt's
rolling window.

Backups can contain verifier records until retention removes them. Restrict
backup access as for other product data. Restoring a backup must not revive
expired requests. Do not restore these collections to recover an unfinished
login. Let them expire or exclude them from a selective recovery.

## Local validation

Run `./scripts/test.sh api web firebase infra` for the changed components.
Run `./scripts/test.sh` for the final regression gate, including Apple.
The Firebase target runs schema checking, client rules tests, and API integration
under Auth and Firestore emulators using `demo-cloudgateway`. It initializes API
dev dependencies even when run alone. Integration tests require local emulator
hosts and fail rather than falling back to a real project.

The Auth emulator accepts unsigned custom tokens and does not prove production
signing or token expiry. The Firestore emulator does not prove deployed TTL or
indexes. Verify those through the staging release checks below. See
[Auth emulator behavior](https://firebase.google.com/docs/emulator-suite/connect_auth).

For the real staging browser flow, use the small in-memory test client:

```sh
python3 scripts/device-auth-client.py --api-origin https://api.example.com --firebase-api-key PUBLIC_FIREBASE_WEB_API_KEY
```

Open the printed link, check the displayed code and account, then approve or deny.
The client polls, exchanges the custom token with Firebase, and reports success
without printing or persisting tokens. Stop it to cancel polling. The request
expires normally. Use a staging origin and its matching public Firebase API key.

## Deployment and release

Local implementation does not authorize deployment. Deployment wrappers can
push commits or tags and publish the dashboard, so use them only for a separately
authorized release.

1. Run the local validation gates and review the final API/UI contract. Back up
   Firestore before deployment.
2. Deploy Firebase rules and indexes. Verify both TTL policies are active and
   direct client get/list/writes are denied. Keep existing product rules intact.
3. Deploy the API and updated Caddy/systemd configuration. Device authorization
   is available immediately, with no feature flag or legacy compatibility path.
4. Confirm `CLOUDGATEWAY_DASHBOARD_CORS_ORIGIN` is the exact HTTPS dashboard origin.
   Keep the existing Firebase service-account file outside git, root-owned,
   readable by the API, and capable of signing Firebase custom tokens. No new
   hashing or signing secret is required. Production services must not set
   `FIREBASE_AUTH_EMULATOR_HOST` or `FIRESTORE_EMULATOR_HOST`.
5. Configure the [Cloudflare dashboard anti-framing rule](../Infrastructure/CloudFlare/README.md#dashboard-anti-framing-rule)
   and deploy the dashboard after the API endpoints are ready. Check the actual
   HTML response headers in browser DevTools, then verify that a framed approval
   page cannot render controls or send API requests.
6. Complete creation, browser approval, redemption, and Firebase custom-token
   sign-in with the real staging credentials. Verify the resulting UID and
   product permissions. Check email, Apple, and Google return paths.
7. Exercise denial, expiry, throttling, account switching, simultaneous
   redemption, and failure recovery. Verify `Cache-Control: no-store`,
   `Retry-After`, exact-origin CORS, and the trusted source boundary through the
   actual Cloudflare/Caddy path. Do not enable a Cloudflare cache rule for these
   endpoints. Check logs without printing secrets or tokens.
8. Record staging evidence before production deployment. Only after the deployed
   flow works should macOS development resume.

## Recovery and rollback

If a request expires, is denied, is consumed, or loses its redemption response,
start a new attempt with a new secret. If the store or signing credentials fail,
fix the dependency and start a fresh attempt. Do not fall back to in-memory
limits, persist custom tokens, or reopen the old request.

Rollback restores the prior site/API versions. Temporary requests expire without
a migration. Already established Firebase sessions follow existing session policy. Do not
revoke every account's sessions as an automatic rollback action.
