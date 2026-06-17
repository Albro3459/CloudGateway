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
- The API verifies the client document at `Users/{userId}/Regions/{regionId}/Instances/{clientId}`
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
  "role": "user"
}
```

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
  `INTERNAL_ERROR`.
- HTTP status mapping:
  - `401`: auth failures (`AUTH_REQUIRED`).
  - `403`: permission failures (`ADMIN_REQUIRED`, `USER_NOT_PROVISIONED`).
  - `400`: invalid request and region errors (`INVALID_REQUEST`, `REGION_DISABLED`,
    `REGION_MISMATCH`).
  - `404`: missing clients (`CLIENT_NOT_FOUND`).
  - `409`: duplicate email, disabled account, and capacity/limit failures (`DUPLICATE_EMAIL`,
    `ACCOUNT_DISABLED`, `LIMIT_REACHED`, `CAPACITY_REACHED`).
  - `500`: host mutation failures and unexpected failures (`WIREGUARD_APPLY_FAILED`,
    `FIREBASE_WRITE_FAILED`, `INTERNAL_ERROR`).

## Enums

- Roles: `user`, `admin`.
- Client statuses: `creating`, `active`, `failed`, `removed`.
- Operation results: `success`, `failed`, `noop`.
