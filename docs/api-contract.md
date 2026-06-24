# Regional API Contract

External request/response contract for the regional FastAPI control plane. For Firestore
paths, document shapes, security rules, and limits, see [Firebase/README.md](../Firebase/README.md).

## Naming

- JSON field naming is camelCase everywhere.
- Use `clientId` in routes, responses, and examples. Never use snake case for the client
  identifier field in external contracts.
- Python internals may use snake_case only behind Pydantic aliases. External request/response
  JSON stays camelCase.

## External API URLs

- Regional API base URL is `https://<regionId>.<origin>/api`.
- `<origin>` is the current frontend origin host without protocol, for example `gocloudlaunch.com`.
- For a frontend loaded from `https://gocloudlaunch.com`, region `us-sanjose-1` calls
  `https://us-sanjose-1.gocloudlaunch.com/api/*`.
- FastAPI internal routes do not include `/api`. Caddy strips `/api/*` before proxying to FastAPI.
- `REACT_APP_API_ORIGIN` is only a local/dev override. When set, frontend API helpers send API
  calls to `${REACT_APP_API_ORIGIN}/api/*`. In production it is unset and the regional API URL is
  derived from `window.location.origin` plus the selected `regionId`.
- There is no global API router and no frontend base-domain config.

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

### `POST /clients`

- Requires Firebase bearer auth. Creates a client only for the authenticated user.
- Request:

```json
{
  "regionId": "us-sanjose-1",
  "clientName": "Phone"
}
```

- `clientName` is optional. Blank or missing values use a simple server default.
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
  "regionId": "us-sanjose-1"
}
```

- Normal users can only pass their own UID. Admins can pass any target UID.
- The API verifies the client document at `Regions/{regionId}/Instances/{clientId}`
  exists and matches the requested IDs before mutating WireGuard.
- Response `200`:

```json
{
  "userId": "firebase-uid",
  "clientId": "6f77fd32-ecf5-4dd7-9d96-6bb84de92df1",
  "regionId": "us-sanjose-1",
  "status": "removed"
}
```

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
  docs in Firebase (the same reconcile run at boot and by `cloudgateway-sync-peers`). Idempotent.
- `regionId` must equal this host's region or the request is rejected with `REGION_MISMATCH`; the
  dashboard fans out one call per region so each regional API only syncs itself.
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
  "syncedAt": "2026-06-17T18:30:00+00:00",
  "added": 1,
  "updated": 0,
  "removed": 1,
  "noChanges": false,
  "log": "CloudGateway peer sync audit log\nregion: ...\n"
}
```

- `log` is a plaintext audit report (no ANSI/color) listing each added/updated/removed peer:
  added/updated peers include the owning `clientId`/`email`, removed peers (host peers with no
  matching active client) are listed by public key only. It never contains private keys, full
  configs, or tokens.

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
  `DUPLICATE_EMAIL`, `ACCOUNT_DISABLED`, `WIREGUARD_APPLY_FAILED`, `FIREBASE_WRITE_FAILED`,
  `ROLE_DEFAULT_MISSING`, `INTERNAL_ERROR`.
- HTTP status mapping:
  - `401`: auth failures (`AUTH_REQUIRED`).
  - `403`: permission failures (`ADMIN_REQUIRED`, `USER_NOT_PROVISIONED`).
  - `400`: invalid request and region errors (`INVALID_REQUEST`, `REGION_DISABLED`,
    `REGION_MISMATCH`).
  - `404`: missing clients (`CLIENT_NOT_FOUND`).
  - `409`: duplicate email, disabled account, and capacity/limit failures (`DUPLICATE_EMAIL`,
    `ACCOUNT_DISABLED`, `LIMIT_REACHED`, `CAPACITY_REACHED`).
  - `500`: host mutation failures, missing/malformed role defaults, and unexpected failures
    (`WIREGUARD_APPLY_FAILED`, `FIREBASE_WRITE_FAILED`, `ROLE_DEFAULT_MISSING`, `INTERNAL_ERROR`).

## Enums

- Roles: `user`, `admin`.
- Client statuses: `creating`, `active`, `failed`, `removed`.
- Operation results: `success`, `failed`, `noop`.
