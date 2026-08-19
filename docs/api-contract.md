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
  from `window.location.origin`.
- The apex API host serves global/account traffic: `GET /regions`, `POST /auth/check-access`,
  and `DELETE /account`.
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
  users are denied and disabled as before.
- Response `200`:

```json
{
  "userId": "firebase-uid",
  "email": "user@example.com",
  "role": "user"
}
```

### `POST /clients`

- Requires Firebase bearer auth. Creates a client only for the authenticated user.
- Request:

```json
{
  "regionId": "us-sanjose-1",
  "clientName": "Phone"
}
```

- `clientName` is required and must be non-blank.
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

- Apex. Requires Firebase bearer auth from a recent sign-in, restricted to `user`-role accounts.
- Real ordering: snapshot the caller's client docs; remove their WireGuard peers (local directly,
  remote via `DELETE /clients/{clientId}` in `accountCleanup` mode - see above); mark every one of
  the account's client documents non-active fleet-wide in one trusted repository operation (the
  fence), including clients on a region whose host was unreachable during peer removal; send
  exactly one best-effort policy refresh wave to every other enabled region while
  `UserRoles/{uid}` and the caller's recent authentication still exist; queue the local policy
  reconcile separately; only then hard-delete the account's client docs, account doc, role doc,
  and Firebase Auth user.
- The hard delete does not start until every other enabled region has accepted the refresh
  (`202` from `POST /sync/refresh`) or been recorded as unreachable. An accepted refresh no
  longer depends on the caller's token once its `202` returns. The fence commits before the
  refresh wave goes out, so from that point no policy pull anywhere - on any region, including one
  that races ahead of the refresh - can restore the deleting account's connectivity.
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
  pre-removal snapshot. For a fleet in a consistent state the two counts agree, so this is not an
  observable contract change.
- An unreachable region is an accepted risk, not a retry loop: it keeps an orphaned WireGuard peer
  and a stale policy row until its next boot or a manual `cloudgateway-sync-peers` run (see
  [docs/wireguard-drift-repair.md](../docs/wireguard-drift-repair.md)). Its Firestore client rows
  are already non-active by the time the account documents are hard-deleted, so the orphaned peer
  cannot be used to reach a live account.

### `POST /users`

- Requires Firebase bearer auth with admin role.
- Logically global and hosted by every regional API. It does not accept `regionId` and does not
  mutate regional state.
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

- `syncedAt` is UTC, serialized with a `Z` suffix and (when non-zero) fractional seconds - parse it
  as ISO 8601 rather than matching the example literally.
- `added`/`updated`/`removed` count **client** peer changes only. `meshApplied` counts every
  desired mesh peer applied this pass (re-applies included, so it is not just newly-added peers);
  `meshAdded`/`meshUpdated`/`meshRemoved` count mesh peers that newly appeared, had endpoint/port/
  allowed-IPs/keepalive drift repaired, or disappeared on the interface this pass; `meshSkipped`
  counts candidate regions skipped for overlap or incomplete mesh fields;
  `meshRoutesAdded`/`meshRoutesRemoved` count the `wg0` mesh route changes from the route sweep.
  `meshEnabled` is true only when this region's doc exists, is `enabled: true`, **and** carries
  `meshEnabled: true` as observed this pass - it is not the raw `Regions/{regionId}.meshEnabled`
  flag. `Mesh/{regionId}.meshEnabled` persists this same combined value, so a disabled region
  publishes `false` there even while its Region doc says `true`.
  `noChanges` means no live mutation: no client add/update/remove, mesh add/update/remove, or
  route add/remove. It deliberately excludes `meshApplied` and `meshSkipped`, so a stable pass
  can report `meshApplied > 0`, `meshUpdated == 0`, and `noChanges == true`; skipped-only passes
  are also `noChanges == true`.
- `meshStatusWritten` is false when the pass reconciled the interface but failed to persist its
  `Mesh/{regionId}` snapshot. The live peer set is still correct; only the durable snapshot the
  dashboard renders mesh link status from is stale, until the next successful pass overwrites it.
  A status-write failure never fails the sync, so this is the only machine-readable signal of it.
  The field is **optional for consumers**: regions are installed independently
  (`sudo cloudgateway-install-api <ref>`), so a dashboard build that ships before every region is
  reinstalled will see responses without it. Treat absent as unknown and render nothing - do not
  treat it as a missing required field, or every not-yet-upgraded region reports
  `INCOMPATIBLE_RESPONSE` during a rollout.
- `clientPeersDegraded` counts active client documents this pass refused to build a peer from
  because their public key or tunnel IP was missing or malformed. Such a record is skipped rather
  than fatal: it is excluded from the desired set, mesh reconciliation and the route sweep still
  run to completion, and - when its public key is at least syntactically valid - its already-live
  peer is protected from the unknown-peer removal sweep so a malformed document never disconnects
  a connected user. Protection follows status, not shape: a degraded record that is also revoked
  or no longer active is not protected, and its peer is removed normally. A non-zero count means
  an `Instances/*` document needs repair; the response, the audit log, and the
  `client_peer_degraded` log event all report the count and the region only - never the public
  key, owner email, client name, or tunnel IP. Like `meshStatusWritten`, the field is required on
  the server and **optional for consumers**, for the same staggered-rollout reason.
- `meshPeers` lists every mesh candidate this pass considered (not just applied ones), with
  `status` one of `applied` / `skipped-overlap` / `skipped-incomplete`. `skipped-overlap` and
  `skipped-incomplete` are persistent configuration failures, not pending work; runtime overlap
  defense remains active. `applied` and `skipped-overlap` entries carry the complete current
  snapshot, including `endpointPort`; incomplete entries retain their reason code and may omit
  invalid fields. It deliberately omits the peer's WireGuard public key - the durable
  `Mesh/{regionId}` Firestore doc carries it. The current response shape is strict: missing
  `meshUpdated` or other required fields is incompatible.
- `appliedAt` on each `Mesh/{regionId}.peers.*` entry is a Firestore server timestamp: the instant
  Firestore **recorded** the host's applied-state snapshot, not the instant WireGuard actually
  changed. It is slightly later than the real application, and deliberately so - a trustworthy
  source beats a precise one read off an untrusted host clock. Because `write_mesh_status` persists
  the snapshot in a single write, every peer's `appliedAt` shares its instant with the document's
  `updatedAt`. Staleness is derived from `updatedAt`, so nothing in the 24h logic depends on
  `appliedAt`; it is an operator-facing "last recorded" label only.
- `log` is an admin audit artifact. It can include user emails, client names,
  client IDs, public keys, tunnel IPs, statuses, and removed-peer details.

- `log` is a plaintext audit report (no ANSI/color) listing each added/updated/removed peer:
  added/updated peers include the owning `clientId`/`email`, removed peers (host peers with no
  matching active client) are listed by public key only. It never contains private keys, full
  configs, or tokens. Its mesh section is server metadata only (region IDs, CIDRs, endpoint
  hostnames, route changes) and never includes a mesh peer's public key or any per-user data.
- This pass also reconciles the account-scoped ACL policy map (`reconcile_policy()`), the same
  full pull-apply-read back-status pass `POST /api/sync/refresh` enqueues - see
  [docs/wireguard-drift-repair.md](../docs/wireguard-drift-repair.md). So Sync All is also the
  repair path for a dropped or lost policy poke, not just for peer/mesh drift.
- The policy leg is synchronous: unlike `POST /api/sync/refresh`, this endpoint waits for the
  policy pass before responding. It coalesces with any pass already in flight and then waits for
  the coordinator to quiesce, so sustained pokes on the un-rate-limited `POST /api/sync/refresh`
  can hold this response open for longer than one pass. That is accepted (depth-1 bounds the
  pending backlog, never the total work callers can trigger); the outcome reported always comes
  from a pass whose Firestore pull started after the Sync All request, so a longer wait only
  returns a fresher result.
- `policyApplied` is `true` only when this pass's `reconcile_policy()` call completed without
  raising. It stays `true`/`false` for the entire response even though everything above it
  (`added`, `meshApplied`, ...) is about the independent peer/mesh pass - the two legs share a
  request but not a failure mode: a policy failure never fails this endpoint or touches the
  peer/mesh fields, and the response is still `200`. On failure the response carries exactly
  `"policyApplied": false` with `policyRowCount` and `policyStatusWritten` both omitted
  (`response_model_exclude_none=True` drops null fields rather than serializing them), so a caller
  should treat their absence as "policy leg failed," not as zero. On success `policyRowCount` is
  the row count read back from the live map (mirrors `Policy/{regionId}.rowCount`) and
  `policyStatusWritten` mirrors `meshStatusWritten`'s meaning for the policy status doc: `false`
  means the map applied correctly but the best-effort `Policy/{regionId}` write failed, so the
  dashboard should warn mildly rather than treat the pass as failed. All three fields are
  **optional for consumers** for the same staggered-rollout reason as `meshStatusWritten`: a region
  that predates this release omits all three, and a dashboard build must treat their absence as
  unknown, not as `policyApplied: false`.
- The Firestore pull that feeds `reconcile_policy()` is fail-closed per row, not per pass: a
  malformed entry (wrong type, a host prefix other than `/32`/`/128`, an address outside the tunnel
  aggregate, or an invalid/out-of-range account slot) is skipped and counted in an aggregate
  skipped-row total, never logged with its uid, address, or slot, and never aborts the pass. Every
  participant in a duplicate address or duplicate account-slot collision is excluded, not just the
  later row in collection order - a collision removes connectivity for the colliding rows rather
  than granting it to whichever happened to win.

### `POST /sync/refresh`

- Requires Firebase bearer auth for any provisioned user (`require_provisioned_user`). Not
  admin-only - any client's own token is enough.
- Regional: reconciles this API server's local region's account-scoped ACL policy map only. It
  never touches WireGuard peers.
- Request body: none.
- Response `202`: deliberately carries no detail - no region health, no row counts, and no error
  information. A caller learns nothing from the response beyond "the request was accepted."
- The reconcile is enqueued and the request returns immediately, so the caller's timeout never
  matters and each request costs approximately nothing.
- No dedicated secret and no rate limit. The caller's own Firebase token is replayed, matching the
  existing cross-region pattern in `_delete_remote_client` (`Backend/API/src/routes.py:722`).
  Depth-1 coalescing in `reconcile_policy()` bounds the *pending backlog* to one queued follow-up
  pass at a time - it does not bound the total number of sequential refreshes a caller can trigger
  over time, and there is no rate limit (see
  [docs/wireguard-drift-repair.md](../docs/wireguard-drift-repair.md)).
- Failure behaviour: because the pass is detached from the response, a failed apply is never
  reported in this endpoint's response, and it does not surface in `Policy/{regionId}` either -
  `reconcile_policy()` raises before it ever calls the status write, so a failed apply or a failed
  read-back leaves the previous successful `Policy/{regionId}` document exactly as it was, and no
  failure status is ever written there. The failure is visible only in host logs
  (`policy_refresh_failed`); a stale-but-valid `Policy` doc can sit next to a region that is
  actively failing to apply. Use `POST /api/admin/sync` (Sync All) as the repair path for a dropped
  or failed poke - its response now distinguishes a policy failure via `policyApplied` (see
  `POST /admin/sync` above).
- Poke sites: `POST /clients` and `DELETE /clients/{clientId}` (ordinary, non-cleanup deletes) call
  this on every other region, fire-and-forget after the response, so a dropped poke never blocks or
  fails the caller's request. A dropped poke leaves the un-poked region's policy map stale until the
  next fleet-wide client event or an admin Sync All - this is an accepted risk, not a bug (see
  [TODO/account-scoped-acl.md](../TODO/account-scoped-acl.md)). `DELETE /account` is different: it
  calls this endpoint synchronously, inside the request, exactly once per other enabled region, as
  the deliberate last propagation step before its hard delete (see `DELETE /account` above); it
  does not also fire the fire-and-forget poke, and the per-client deletes it issues in
  `accountCleanup` mode suppress their own poke so the account delete is never fanned out twice.

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

- Error codes are uppercase snake case.
- Required codes: `AUTH_REQUIRED`, `ADMIN_REQUIRED`, `USER_NOT_PROVISIONED`, `INVALID_REQUEST`,
  `REGION_DISABLED`, `REGION_MISMATCH`, `LIMIT_REACHED`, `CAPACITY_REACHED`, `CLIENT_NOT_FOUND`,
  `DUPLICATE_EMAIL`, `ACCOUNT_DISABLED`, `SYNC_IN_PROGRESS`, `WIREGUARD_APPLY_FAILED`,
  `FIREBASE_WRITE_FAILED`, `ROLE_DEFAULT_MISSING`, `INTERNAL_ERROR`.
- HTTP status mapping:
  - `401`: auth failures (`AUTH_REQUIRED`).
  - `403`: permission failures (`ADMIN_REQUIRED`, `USER_NOT_PROVISIONED`).
  - `400`: invalid request and region errors (`INVALID_REQUEST`, `REGION_DISABLED`,
    `REGION_MISMATCH`).
  - `404`: missing clients (`CLIENT_NOT_FOUND`).
  - `409`: duplicate email, disabled account, capacity/limit failures, and a sync already running
    on the region (`DUPLICATE_EMAIL`, `ACCOUNT_DISABLED`, `LIMIT_REACHED`, `CAPACITY_REACHED`,
    `SYNC_IN_PROGRESS`).
  - `500`: host mutation failures, missing/malformed role defaults, and unexpected failures
    (`WIREGUARD_APPLY_FAILED`, `FIREBASE_WRITE_FAILED`, `ROLE_DEFAULT_MISSING`, `INTERNAL_ERROR`).

## Enums

- Roles: `user`, `admin`.
- Client statuses: `creating`, `active`, `failed`, `removed`.
- Operation results: `success`, `failed`, `noop`.
