# Regional API Contract

External request/response contract for the regional FastAPI control plane. For Firestore
paths, document shapes, security rules, and limits, see [Backend/Firebase/README.md](../Backend/Firebase/README.md).

## Naming

- JSON field naming is camelCase everywhere.
- Use `clientId` in routes, responses, and examples. Never use snake case for the client
  identifier field in external contracts.
- Python internals may use snake_case only behind Pydantic aliases. External request/response
  JSON stays camelCase.

## External API URLs

- Apex API base URL is `https://api.<origin>/api`, for example
  `https://api.gocloudlaunch.com/api`.
- Regional API base URL is `https://<regionId>.<origin>/api`.
- `<origin>` is the current frontend origin host without protocol, for example `gocloudlaunch.com`.
- For a frontend loaded from `https://gocloudlaunch.com`, global/read calls use
  `https://api.gocloudlaunch.com/api/*`; region `us-sanjose-1` mutations and capacity calls
  use `https://us-sanjose-1.gocloudlaunch.com/api/*`.
- FastAPI internal routes do not include `/api`. Caddy strips `/api/*` before proxying to FastAPI.
- `REACT_APP_API_ORIGIN` is only a local/dev override. When set, frontend API helpers send API
  calls to `${REACT_APP_API_ORIGIN}/api/*`. In production it is unset and API URLs are derived
  from `window.location.hostname`.
- The apex API host serves global/account traffic: `GET /regions`, `POST /auth/check-access`,
  `DELETE /account`, and device authorization (`POST /device/*`).
- Native Apple clients use the same production regional hostname shape with origin
  `gocloudlaunch.com`, and use `api.gocloudlaunch.com` for apex calls. Capacity, create,
  delete, and sync calls use the selected or target config region.

## Routes

### `GET /health`

- Unauthenticated. Rate limited by Caddy like the rest of the API surface.
- Response `200`:

```json
{
  "status": "ok",
  "regionId": "us-sanjose-1"
}
```

### `GET /regions`

- Apex. Unauthenticated.
- Returns enabled regions only, sorted by `displayOrder`. This is display-safe discovery data
  only; it never includes capacity, endpoint IPs, hostnames, WireGuard public keys, DNS settings,
  health state, or `enabled`.
- Response `200`:

```json
{
  "regions": [
    {
      "regionId": "us-sanjose-1",
      "displayName": "San Jose",
      "displayOrder": 1
    },
    {
      "regionId": "us-ashburn-1",
      "displayName": "Ashburn",
      "displayOrder": 2
    }
  ]
}
```

### `POST /auth/check-access`

- Apex. Requires Firebase bearer auth.
- Verifies that the authenticated user is provisioned and returns their role. Unprovisioned
  users are denied, disabled in Firebase Auth, and have refresh tokens revoked.
- Response `200`:

```json
{
  "userId": "firebase-uid",
  "email": "user@example.com",
  "role": "user"
}
```

`email` may be `null`. Invalid, expired, revoked, disabled, or deleted identities
return `401 AUTH_REQUIRED`. Token-verification dependency failures return
`503 AUTH_UNAVAILABLE`. Clients retain their session and retry, with access
unconfirmed until a check succeeds.

### Device authorization

Device authorization runs on the apex API. FastAPI routes are `/device/*`; Caddy strips the public
`/api` prefix from `POST /api/device/code`, `POST /api/device/verify`,
`POST /api/device/approve`, and `POST /api/device/token`. Every response from these routes, including
validation failures and dependency errors, carries `Cache-Control: no-store`. Device request
bodies reject unknown fields.

Approval links use the
configured HTTPS dashboard origin. HTTP is allowed only for `localhost` or literal loopback IPs
for development. Binding a dev server to `0.0.0.0` does not make it a valid HTTP dashboard origin.

The flow uses a fresh 32-byte device secret for each attempt. The client sends its lowercase
SHA-256 hex hash at creation, encoded secret only in token-poll bodies, and never puts either value
in a URL. The secret encoding is canonical unpadded base64url (43 characters); the server hashes
the decoded 32 bytes. A six-digit user code is a string, so leading zeroes are significant. The
server stores only the code hash. Request IDs are 32 lowercase hexadecimal characters.

#### `POST /device/code`

Unauthenticated. Request:

```json
{
  "deviceSecretHash": "64 lowercase hexadecimal characters",
  "deviceName": "Living room player"
}
```

`deviceName` is optional (or `null`), accepts at most 512 input characters, is trimmed,
and has control characters removed. A sanitized name longer than 80 characters is rejected.
An empty sanitized name becomes `null` in verification responses. The name is unverified. The API returns `201`:

```json
{
  "deviceRequestId": "0123456789abcdef0123456789abcdef",
  "userCode": "004281",
  "verificationUri": "https://gocloudlaunch.com/#/auth/code",
  "verificationUriComplete": "https://gocloudlaunch.com/#/auth/code?deviceRequestId=0123456789abcdef0123456789abcdef&userCode=004281",
  "expiresIn": 300,
  "interval": 5
}
```

Both URLs use the configured dashboard origin. The complete link passes request ID and code in the
URL fragment; it contains no device secret or Firebase token. The request expires 300 seconds after
creation. Verification, decisions, polling, and retries do not extend that time.

#### `POST /device/verify`

Requires a Firebase bearer ID token for an enabled Auth user with an enabled `Users/{uid}` record
and a recognized `UserRoles/{uid}` role. The request ID and code are both required:

```json
{
  "deviceRequestId": "0123456789abcdef0123456789abcdef",
  "userCode": "004281"
}
```

Response `200` contains only display context and state. It never includes an approving UID or
device secret:

```json
{
  "deviceName": "Living room player",
  "userCode": "004281",
  "state": "pending",
  "expiresAt": "2026-10-01T12:05:00Z"
}
```

`state` is `pending`, `approved`, `denied`, or `consumed`. The API checks the fixed expiry before
returning a stored state.

#### `POST /device/approve`

Requires the same Firebase bearer and product-access checks as `/device/verify`. Request:

```json
{
  "deviceRequestId": "0123456789abcdef0123456789abcdef",
  "userCode": "004281",
  "decision": "approve"
}
```

`decision` is exactly `approve` or `deny`. Response `200` is `{ "state": "approved" }` or
`{ "state": "denied" }`. The first valid decision wins atomically. Repeating the same decision
by the same account is idempotent; another account or a conflicting decision receives
`DEVICE_AUTH_CONFLICT`.

#### `POST /device/token`

Unauthenticated Firebase-wise; proves device possession with the secret from creation. Request:

```json
{
  "deviceRequestId": "0123456789abcdef0123456789abcdef",
  "deviceSecret": "43-character canonical unpadded base64url secret"
}
```

A valid pending poll returns `202`:

```json
{ "state": "pending", "interval": 5 }
```

Polling more often than once every five seconds returns `429 DEVICE_AUTH_THROTTLED` with integer
`Retry-After`. The approved account's Auth user must still exist and be enabled before redemption;
the API then transactionally rechecks the product user and role records and claims the request as
consumed. Only the winning request signs a Firebase custom token, outside the Firestore
transaction. Success returns `200`:

```json
{ "customToken": "Firebase custom token" }
```

The token is returned once and never persisted. A signing failure or lost response leaves the
request consumed; the device starts a new authorization flow.

#### Device authorization errors

Controlled device failures use the standard API error envelope. Request validation and unknown
request/proof mismatches share `400 DEVICE_AUTH_INVALID`; a wrong proof does not reveal stored
state. Expiry is `410 DEVICE_AUTH_EXPIRED`, denial is `403 DEVICE_AUTH_DENIED`, consumed requests
are `409 DEVICE_AUTH_CONSUMED`, and first-decision conflicts are `409 DEVICE_AUTH_CONFLICT`.
Persistent rate limits return `429 DEVICE_AUTH_THROTTLED` with an integer `Retry-After`. Invalid
configuration, Firestore failure, Auth lookup failure, or custom-token signing failure return
`503 DEVICE_AUTH_UNAVAILABLE`. Browser bearer authentication keeps the existing `401 AUTH_REQUIRED`
and `403 USER_NOT_PROVISIONED` responses. Token-verification outages return
`503 AUTH_UNAVAILABLE`, before the device service runs.

The API stores device requests in `DeviceAuthRequests/{deviceRequestId}` and shared limit windows in
`DeviceAuthLimits/{scopeId}`. Browser code/request mismatches are limited to three attempts per UID
per rolling five minutes; creation is limited to five requests per trusted source per rolling five
minutes; attempts exactly 300 seconds old have expired. A valid request poll is limited to one every
five seconds. These budgets are transactional and shared across API instances. Expired request IDs
and wrong proofs do not alter polling state. Creation source identity comes from the replaced
`X-CloudGateway-Client-IP` header only when the API's direct peer is loopback; direct non-loopback
requests use the peer address and ignore forwarded headers. Source addresses are stored as
short-lived SHA-256 digests; this is pseudonymous personal data, not anonymization. The API access
log excludes request bodies and query strings, and device errors do not include secret-bearing
exception text.

### `POST /clients`

- Requires Firebase bearer auth. Creates a client only for the authenticated user.
- Request:

```json
{
  "regionId": "us-sanjose-1",
  "clientName": "Phone"
}
```

- `regionId` must match this API server and refer to an enabled region.
- `clientName` is required, limited to 80 input characters, trimmed, and must be non-blank.
- Creation transactionally reserves capacity, the user limit, a client ID, paired tunnel
  addresses, and an account slot if needed. The server generates the client keypair.
- The response includes a private-key-bearing config. Treat it as secret material.
- Response `200`:

```json
{
  "clientId": "6f77fd32-ecf5-4dd7-9d96-6bb84de92df1",
  "regionId": "us-sanjose-1",
  "clientName": "Phone",
  "status": "active",
  "assignedTunnelIpv4": "10.0.0.2/32",
  "assignedTunnelIpv6": "fd42:42:42::2/128",
  "serverEndpointIpv4": "1.2.3.4",
  "serverEndpointHostname": "wg.us-sanjose-1.gocloudlaunch.com",
  "wireguardConfig": "..."
}
```

### `GET /capacity`

- Requires Firebase bearer auth for a provisioned user.
- Regional: returns capacity for this API server's local region only.
- Signed-in clients fan this out per region after `GET /regions`; guests never call it.
- `allocatedClientCount` counts client docs with status `creating` or `active`.
- Response `200`:

```json
{
  "regionId": "us-sanjose-1",
  "capacityLimit": 20,
  "allocatedClientCount": 8
}
```

### `DELETE /clients/{clientId}`

- Requires Firebase bearer auth.
- Request body:

```json
{
  "userId": "firebase-uid",
  "regionId": "us-sanjose-1",
  "accountCleanup": false
}
```

- Normal users can only pass their own UID. Admins can pass any target UID.
- The API verifies the client document at `Regions/{regionId}/Instances/{clientId}`
  exists and matches the requested IDs before mutating WireGuard.
- `accountCleanup` (optional, defaults to `false`) marks this delete as part of `DELETE
  /account`'s cross-region peer removal. The receiving region honors it only for a recently
  authenticated self-delete by a `user`-role account - `userId` must equal the caller's own uid,
  the caller's Firebase sign-in must be recent, and the caller's role must permit account
  deletion - and re-checks all three against the replayed bearer token itself; the flag is never
  trusted on its own. A request that fails any of those checks fails the whole delete (`400
  INVALID_REQUEST` for the self-only/role checks, `401 AUTH_REQUIRED` for stale auth); cleanup
  mode is never silently downgraded to an ordinary delete. When accepted, the handler skips its
  usual local policy reconcile and fleet poke, because `DELETE /account` owns propagation for the
  whole account (see below).
- Response `200`:

```json
{
  "userId": "firebase-uid",
  "clientId": "6f77fd32-ecf5-4dd7-9d96-6bb84de92df1",
  "regionId": "us-sanjose-1",
  "status": "removed"
}
```

### `DELETE /account`

- Apex. Requires Firebase bearer auth with `auth_time` no more than five minutes old
  and no more than one minute in the future. Missing/stale auth returns `401 AUTH_REQUIRED`.
- Available to `user`-role accounts. A Firebase identity with neither a recognized
  role nor a user document may also delete itself. Admins and other partial
  provisioning states receive `400 INVALID_REQUEST`.
- The API snapshots the caller's client docs, removes their WireGuard peers (local directly,
  remote via `DELETE /clients/{clientId}` in `accountCleanup` mode), then marks every one of
  the account's client documents non-active fleet-wide in one trusted repository operation (the
  fence), including clients on a region whose host was unreachable during peer removal. It sends
  exactly one best-effort policy refresh wave to every other enabled region while
  `UserRoles/{uid}` and the caller's recent authentication still exist, queues the local policy
  reconcile separately, then hard-deletes the account's client docs, account doc, role doc,
  and Firebase Auth user.
- The hard delete does not start until every other enabled region has accepted the refresh
  (`202` from `POST /sync/refresh`) or been recorded as unreachable. An accepted refresh no
  longer depends on the caller's token once its `202` returns. The fence commits before the
  refresh wave goes out, so any policy pull started after the fence excludes the account.
- Request body: none.
- Response `200`:

```json
{
  "userId": "firebase-uid",
  "deletedClientCount": 3
}
```

- `deletedClientCount` is the count reported by the fence's own authoritative read of the
  account's client documents (grouped by region from each document's path), not the
  pre-removal snapshot.
- An unreachable region keeps an orphaned WireGuard peer and a stale policy row
  until its next boot or a manual `cloudgateway-sync-peers` run (see
  [docs/wireguard-drift-repair.md](../docs/wireguard-drift-repair.md)). Its Firestore client rows
  are already non-active before hard deletion, so future policy pulls exclude the account.
  A Firestore fence does not itself remove stale state from an unreachable host.

### `POST /users`

- Requires Firebase bearer auth with admin role.
- Logically global and hosted by every regional API. It does not accept `regionId` and does not
  mutate regional state.
- Accepts only `email`, trimmed and limited to 320 input characters. Unknown fields are rejected.
- Creates a normal-user role assignment and account slot. An existing Auth account without
  a role assignment can be provisioned (`alreadyExisted: true`), including re-enabling an
  Auth account disabled by the unprovisioned-user access check. An already-provisioned
  account returns `DUPLICATE_EMAIL`, or `ACCOUNT_DISABLED` if its Auth user is disabled.
- After access is granted, the API sends a best-effort SES email telling the user they can sign in.
  Email failures are logged but do not change the `200` response or roll back access.
- Request:

```json
{
  "email": "user@example.com"
}
```

- Response `200`:

```json
{
  "userId": "firebase-uid",
  "email": "user@example.com",
  "role": "user",
  "alreadyExisted": false
}
```

### `POST /admin/sync`

- Requires Firebase bearer auth with admin role.
- Regional: reconciles this host's live WireGuard peer set against the region's `active` client
  docs in Firebase (the same reconcile run at boot and by `cloudgateway-sync-peers`), **and**
  reconciles the cross-region mesh: every other enabled region with `meshEnabled == true` and
  complete/non-overlapping mesh fields becomes a server-to-server peer with matching routes on
  `wg0` (see [docs/wireguard-drift-repair.md](../docs/wireguard-drift-repair.md)). Idempotent -
  mesh peers are re-applied every pass (this is what re-resolves each endpoint hostname); client
  peers keep the existing compare-then-apply behavior.
- `regionId` must equal this host's region or the request is rejected with `REGION_MISMATCH`; the
  dashboard fans out one call per region so each regional API only syncs itself. Mesh changes are
  inherently all-region operations, so the dashboard always syncs every enabled region ("Sync All
  Regions"), not a subset.
- Only one pass runs per host at a time. This endpoint takes the host's WireGuard lock
  non-blocking, so a request that arrives while a pass (or a client create/delete) holds it is
  rejected immediately with `409 SYNC_IN_PROGRESS` rather than queueing; retry after the running
  pass finishes. The boot and post-registration passes still wait for the lock.
- Request:

```json
{
  "regionId": "us-ashburn-1"
}
```

- Response `200`:

```json
{
  "regionId": "us-ashburn-1",
  "syncedAt": "2026-06-17T18:30:00.123456Z",
  "added": 1,
  "updated": 0,
  "removed": 1,
  "noChanges": false,
  "log": "CloudGateway peer sync audit log\nregion: ...\n",
  "meshEnabled": true,
  "meshApplied": 1,
  "meshAdded": 0,
  "meshUpdated": 0,
  "meshRemoved": 0,
  "meshSkipped": 0,
  "meshRoutesAdded": 0,
  "meshRoutesRemoved": 0,
  "meshStatusWritten": true,
  "clientPeersDegraded": 0,
  "meshPeers": [
    {
      "regionId": "us-sanjose-1",
      "status": "applied",
      "endpointHostname": "wg.us-sanjose-1.gocloudlaunch.com",
      "endpointPort": 51820,
      "allowedNetworkV4": "10.0.0.0/24",
      "allowedNetworkV6": "fd42:42:42::/64"
    }
  ],
  "policyApplied": true,
  "policyRowCount": 12,
  "policyStatusWritten": true
}
```

- `syncedAt` is UTC ISO 8601, with `Z` and optional fractional seconds.
- `added`, `updated`, and `removed` count client peer changes. `meshApplied` counts
  every desired mesh peer applied, including re-applies. `meshAdded`, `meshUpdated`,
  and `meshRemoved` count new peers, repaired endpoint/port/allowed-IP/keepalive drift,
  and removed peers. `meshSkipped` counts candidates with overlapping or incomplete
  configuration.
  `meshRoutesAdded` and `meshRoutesRemoved` count `wg0` route changes.
- `meshEnabled` requires this region's document to exist with both `enabled: true`
  and `meshEnabled: true`. `Mesh/{regionId}.meshEnabled` records the same combined value.
- `noChanges` covers client, mesh peer, and mesh route changes only. Re-applies,
  skipped candidates, policy changes, and status writes do not make it false.
- `meshStatusWritten: false` means live reconciliation succeeded but the best-effort
  `Mesh/{regionId}` write failed. The dashboard snapshot remains old until a later
  successful pass. This does not fail the request.
- `clientPeersDegraded` counts active documents skipped for missing/malformed public
  keys or tunnel addresses. Mesh and route repair still run. A syntactically valid key
  on a degraded active document is protected from unknown-peer removal. Removed or
  otherwise non-active documents receive no such protection. The count, audit note,
  and `client_peer_degraded` event reveal only the count and region, without client
  identities, keys, or addresses.
- `meshPeers` includes all considered candidates. `status` is `applied`,
  `skipped-overlap`, or `skipped-incomplete`. Skipped entries describe configuration
  failures. Applied and overlap entries include complete metadata and `endpointPort`.
  Incomplete entries carry `reasonCode` and may omit invalid fields. Public keys
  appear only in the durable `Mesh` snapshot, not these response entries.
- `Mesh/{regionId}.peers.*.appliedAt` and document `updatedAt` share a Firestore server
  timestamp from the snapshot write. This records when Firestore stored the result,
  slightly after live application. Mesh staleness uses `updatedAt`, not `appliedAt`.
- `log` is a plain-text admin audit report. Client changes may include emails, names,
  IDs, public keys, tunnel IPs, and statuses. Removed peers without a matching active
  client appear by public key. Join details are best-effort because enrichment runs
  after the WireGuard lock is released. Mesh entries contain server metadata only,
  with no mesh public keys or user data. Never log or share private keys, full configs,
  or tokens.
- The policy pass is synchronous and independent of peer/mesh results. It waits for
  coalesced work to finish and uses a pull started after this request. Sustained
  refresh requests can extend that wait: coalescing bounds the pending backlog,
  not the total number of passes.
- `policyApplied: true` means policy apply and live read-back succeeded.
  `policyRowCount` is the live `cg_slot4` count. `policyStatusWritten: false` means
  live application succeeded but its best-effort `Policy/{regionId}` write failed.
  A failed policy apply/read-back still returns `200`, with `policyApplied: false`
  and both other policy fields omitted, without changing peer/mesh fields.
- Consumers must accept absent `meshStatusWritten`, `clientPeersDegraded`, and all
  three policy fields during regional rollouts. Absence means unknown. Other fields,
  including `meshUpdated`, remain required. Present optional fields must have the
  documented types.
- Policy input is validated per row. Invalid types, prefixes other than `/32` or
  `/128`, out-of-aggregate addresses, and invalid account slots are excluded.
  Every participant in duplicate-address or duplicate-account-slot collisions is
  excluded. Logs report only an aggregate skipped count. See
  [ACL policy reconciliation](wireguard-drift-repair.md#account-scoped-acl-policy-reconcile).

### `POST /sync/refresh`

- Requires Firebase bearer auth for any provisioned user, including non-admins.
- Regional. Refreshes only this host's account ACL policy, with no WireGuard changes.
- Request body: none. Response: empty `202`, confirming acceptance only. The response
  contains no health, counts, or reconcile outcome.
- Reconciliation runs in the background. Failure is visible in host logs as
  `policy_refresh_failed`. Apply/read-back failures leave the previous successful
  `Policy/{regionId}` snapshot untouched. Use `POST /admin/sync` to repair and obtain
  a synchronous policy outcome.
- Uses the caller's Firebase token for cross-region calls. There is no dedicated
  secret or endpoint-specific rate limit. Coalescing allows one pending follow-up
  pass per host, without limiting total sequential refreshes. Caddy's outer API
  limits still apply.
- Client creation and ordinary client deletion queue a local reconcile and a
  best-effort refresh to every other enabled region after the response. A dropped
  refresh leaves that host's policy unchanged until another fleet client event,
  boot, or manual Sync All. The client request still succeeds.
- Account deletion sends exactly one synchronous refresh wave per other enabled
  region before hard deletion and queues its local reconcile separately. Its remote
  `accountCleanup` deletes suppress their own refreshes. See `DELETE /account` above
  and the [ACL guide](access-control-list.md).

## Error Responses

All controlled failures return this shape:

```json
{
  "error": {
    "code": "REGION_MISMATCH",
    "message": "Requested region does not match this API server.",
    "requestId": "..."
  }
}
```

Error codes are uppercase snake case. Request validation uses `400 INVALID_REQUEST`,
or `400 DEVICE_AUTH_INVALID` on device routes. Responses carry `X-Request-Id` for
correlation. The status mapping is:

| HTTP status | Codes |
| --- | --- |
| `400` | `INVALID_REQUEST`, `REGION_DISABLED`, `REGION_MISMATCH`, `DEVICE_AUTH_INVALID` |
| `401` | `AUTH_REQUIRED` |
| `403` | `ADMIN_REQUIRED`, `USER_NOT_PROVISIONED`, `DEVICE_AUTH_DENIED` |
| `404` | `CLIENT_NOT_FOUND` |
| `409` | `DUPLICATE_EMAIL`, `ACCOUNT_DISABLED`, `LIMIT_REACHED`, `CAPACITY_REACHED`, `SYNC_IN_PROGRESS`, `DEVICE_AUTH_CONSUMED`, `DEVICE_AUTH_CONFLICT` |
| `410` | `DEVICE_AUTH_EXPIRED` |
| `429` | `DEVICE_AUTH_THROTTLED` (integer `Retry-After`) |
| `503` | `AUTH_UNAVAILABLE`, `DEVICE_AUTH_UNAVAILABLE` |
| `500` | `WIREGUARD_APPLY_FAILED`, `POLICY_APPLY_FAILED`, `FIREBASE_WRITE_FAILED`, `ROLE_DEFAULT_MISSING`, `ACCOUNT_SLOT_UNAVAILABLE`, `INTERNAL_ERROR` |

`POLICY_APPLY_FAILED` is a registered host error. The policy leg of `POST /admin/sync`
reports failure through `policyApplied: false` with HTTP `200`; background refresh
failures are logged after acceptance.

`ACCOUNT_SLOT_UNAVAILABLE` means a new account slot cannot be allocated because
`Counters/accountSlots.nextSlot` is missing, malformed, exhausted, or at/below a
live account's slot. The transaction writes no user, slot, client, tunnel index,
or counter. `POST /clients` exposes this code directly. The Firestore-backed
`POST /users` provisioning path currently wraps allocation failures as
`FIREBASE_WRITE_FAILED`, with best-effort Auth rollback. Do not rebuild the counter
from live users: hard-deleted accounts' slots must never be reissued. Restore an
authoritative watermark before retrying. See [account slot allocation](access-control-list.md#account-slot-allocation)
and [counter recovery](service-operations.md).

## Enums

- Roles: `user`, `admin`.
- Client statuses: `creating`, `active`, `failed`, `removed`.
- Operation results: `success`, `failed`, `noop`.
