# Shared VPN Contract

Source-of-truth contract for the shared regional VPN platform. API, frontend, infrastructure, and documentation tracks must follow this contract exactly. If a track discovers a gap, the contract is updated first, then parallel work continues.

## Naming

- JSON and Firestore field naming is camelCase everywhere.
- Use `clientId` in route docs, frontend helpers, responses, and examples. Never use snake case for the client identifier field in external contracts.
- Python internals may use snake_case only behind Pydantic aliases. External request/response JSON stays camelCase.

## External API URLs

- Regional API base URL is `https://<regionId>.<origin>/api`.
- `<origin>` is the current frontend origin host without protocol, for example `gocloudlaunch.com` or `gateway.gocloudlaunch.com`.
- For a frontend loaded from `https://gateway.gocloudlaunch.com`, region `us-sanjose-1` calls `https://us-sanjose-1.gateway.gocloudlaunch.com/api/*`.
- FastAPI internal routes do not include `/api`. Caddy strips `/api/*` before proxying to FastAPI.
- `REACT_APP_API_ORIGIN` is only a local/dev override. When set, frontend API helpers send API calls to `${REACT_APP_API_ORIGIN}/api/*`. In production it is unset and the regional API URL is derived from `window.location.origin` plus the selected `regionId`.
- There is no global API router and no frontend base-domain config.

## API Routes

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
  "serverEndpointHostname": "wg.us-sanjose-1.gateway.gocloudlaunch.com",
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
- The API verifies the client document at `Users/{userId}/Regions/{regionId}/Instances/{clientId}` exists and matches the requested IDs before mutating WireGuard.
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
- Logically global and hosted by every regional API. It does not accept `regionId` and does not mutate regional state.
- Request:

```json
{
  "email": "user@example.com",
  "password": "temporary-password",
  "displayName": "User Name"
}
```

- `displayName` is optional.
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
- Required codes: `AUTH_REQUIRED`, `ADMIN_REQUIRED`, `INVALID_REQUEST`, `REGION_DISABLED`, `REGION_MISMATCH`, `LIMIT_REACHED`, `CAPACITY_REACHED`, `CLIENT_NOT_FOUND`, `DUPLICATE_EMAIL`, `INVALID_PASSWORD`, `WIREGUARD_APPLY_FAILED`, `FIREBASE_WRITE_FAILED`, `INTERNAL_ERROR`.
- HTTP status mapping:
  - `401`: auth failures (`AUTH_REQUIRED`).
  - `403`: permission failures (`ADMIN_REQUIRED`).
  - `400`: invalid request, region mismatch, invalid password (`INVALID_REQUEST`, `REGION_DISABLED`, `REGION_MISMATCH`, `INVALID_PASSWORD`).
  - `404`: missing clients (`CLIENT_NOT_FOUND`).
  - `409`: duplicate email and capacity/limit failures (`DUPLICATE_EMAIL`, `LIMIT_REACHED`, `CAPACITY_REACHED`).
  - `500`: host mutation failures and unexpected failures (`WIREGUARD_APPLY_FAILED`, `FIREBASE_WRITE_FAILED`, `INTERNAL_ERROR`).

## Enums

- Roles: `user`, `admin`.
- Client statuses: `creating`, `active`, `failed`, `removed`.
- Operation results: `success`, `failed`, `noop`.

## Firebase Paths

- Region documents: `Regions/{regionId}`.
- User documents: `Users/{uid}`.
- Client documents: `Users/{uid}/Regions/{regionId}/Instances/{clientId}`.
- Role documents: `Roles/{uid}`.

## `Regions/{regionId}` Fields

- `regionId`: string, same as document ID.
- `displayName`: string.
- `enabled`: boolean.
- `wireguardEndpointIpv4`: string raw public IPv4 of the server, for operations/display.
- `wireguardEndpointIpv6`: string or null.
- `wireguardEndpointHostname`: string non-proxied DNS hostname used as the client config endpoint, `wg.<regionId>.<origin>`.
- `wireguardPort`: number, default `51820`.
- `wireguardDnsIpv4`: string.
- `wireguardDnsIpv6`: string.
- `wireguardPublicKey`: string.
- `capacityLimit`: number.
- `activeClientCount`: number.
- `displayOrder`: number, optional.
- `healthStatus`: string, optional.
- `updatedAt`: Firestore timestamp.

## `Users/{uid}` Fields

- `uid`: string, same as document ID.
- `email`: string.
- `displayName`: string or null.
- `createdAt`: Firestore timestamp.
- `disabled`: boolean, optional.

## `Roles/{uid}` Fields

- `role`: `user` or `admin`.
- `updatedAt`: Firestore timestamp.

## Client Document Fields

- `clientId`: string UUIDv4, same as document ID.
- `ownerUid`: string.
- `ownerEmail`: string.
- `ownerDisplayName`: string or null.
- `clientName`: string.
- `regionId`: string.
- `status`: `creating`, `active`, `failed`, or `removed`.
- `assignedTunnelIpv4`: string CIDR.
- `assignedTunnelIpv6`: string CIDR.
- `serverEndpointIpv4`: string raw public IPv4.
- `serverEndpointHostname`: string DNS endpoint hostname used in the stored config.
- `serverPublicKey`: string.
- `clientPublicKey`: string.
- `wireguardConfig`: string or null.
- `createdAt`: Firestore timestamp.
- `updatedAt`: Firestore timestamp.
- `removedAt`: Firestore timestamp or null.
- `lastErrorCode`: string or null.
- `lastErrorMessage`: string or null.

## Frontend Permissions

- Authenticated users can read enabled region docs.
- Normal users can read their own user document and own client documents.
- Admins can read all user, role, and client documents.
- Frontend clients cannot create, update, or delete VPN client documents directly. Client mutation goes through regional FastAPI using the Firebase Admin SDK.
- Admins can write `Regions`, `Users`, and `Roles` documents from the frontend where existing admin UI needs it, but not client documents.

## User Limits

- Normal users default to 3 active clients per region.
- Admins can create clients only for themselves, but can exceed the normal user limit up to server capacity.
- Admins can delete clients for any user.

## Frontend API Selection

- Client create/delete calls use the active region tab's `regionId` to derive `https://<regionId>.<origin>/api/*`.
- `<origin>` is derived from `window.location.host`, preserving the current frontend port only for localhost/dev hosts.
- For localhost/dev, prefer `REACT_APP_API_ORIGIN` when set instead of deriving a regional hostname.
- Missing `displayOrder` sorts as `1000`.
- `POST /users` uses `REACT_APP_API_ORIGIN` in local/dev when set. In production it uses the first enabled region sorted by `displayOrder` then `regionId`, because the route is logically global and hosted by every regional API. If there is no enabled region, the frontend shows a controlled error and does not call the API.

## API Deployment Handoff

- Host install directory: `/opt/cloudlaunch/api`.
- Python virtualenv: `/opt/cloudlaunch/api/.venv`.
- App import path: `src.main:app`.
- Dependency metadata: `API/pyproject.toml`. Infrastructure installs the package into the venv from `/opt/cloudlaunch/api`.
- systemd service name: `cloudlaunch-api.service`.
- systemd runs as `root`, working directory `/opt/cloudlaunch/api`, binding only to `127.0.0.1`.
- Environment file path: `/etc/cloudlaunch/api.env`, mode `0600`, owned by `root`.
- Required environment variables:
  - `CLOUDLAUNCH_REGION_ID`
  - `CLOUDLAUNCH_API_PORT`
  - `CLOUDLAUNCH_FIREBASE_CREDENTIALS_FILE`
  - `CLOUDLAUNCH_WG_INTERFACE`
  - `CLOUDLAUNCH_WG_SERVER_PUBLIC_KEY`
  - `CLOUDLAUNCH_WG_ENDPOINT_HOSTNAME`
  - `CLOUDLAUNCH_WG_PORT`
  - `CLOUDLAUNCH_WG_DNS_IPV4`
  - `CLOUDLAUNCH_WG_DNS_IPV6`
  - `CLOUDLAUNCH_WG_TUNNEL_IPV4_CIDR`
  - `CLOUDLAUNCH_WG_TUNNEL_IPV6_CIDR`
- Default values: `CLOUDLAUNCH_API_PORT=8000`, `CLOUDLAUNCH_WG_INTERFACE=wg0`, `CLOUDLAUNCH_WG_PORT=51820`.
- Peer state: Firebase is the single source of truth for WireGuard peers. Peers are never written to `/etc/wireguard/wg0.conf` or any other host state file; the file is written once by bootstrap with interface settings only. The `cloudlaunch-sync-peers` entry point (systemd `cloudlaunch-sync-peers.service`) rebuilds the live peer set from Firebase on every boot and on demand, one-directionally (Firebase wins; unknown server peers are removed; sync never writes to Firebase). API routes hold the `/run/cloudlaunch-wireguard.lock` flock across each WireGuard mutation plus its matching Firebase write.
