# Shared VPN Implementation Commits

## Purpose

Plan the clean cutoff from per-user OCI VPN stacks to the shared regional VPN platform described in `TODO/Shared_VPN_Plan.md`.

This PR is intentionally large because it replaces the active architecture. Work should still be split into independent commits that can be built in separate worktrees, reviewed independently, then layered with fast-forward cherry-picks and no merge commits.

## Worktree Ownership

- API worktree owns `API/`, `Firebase/firestore.rules`, and legacy `lambda/` removal.
- Infrastructure worktree owns `OCI/` implementation files, `cloudflare/` removal, host bootstrap, Caddy, and Terraform.
- Frontend worktree owns `APP/`.
- Documentation worktree owns `README.md`, `APP/README.md`, `OCI/README.md`, and new runbooks/docs.

Avoid cross-track edits unless the task explicitly says to touch a shared contract file. Implementation tracks may remove documentation files only when deleting the obsolete folder that contains them, such as `lambda/README.md` or `cloudflare/README.md`; durable documentation updates belong to the documentation track.

After Commit 1, API, infrastructure, frontend, and documentation work should not depend on uncommitted outputs from another track. If a later task discovers an unresolved cross-track decision, update the shared contract before continuing parallel work.

## Base Contract Commit

### Commit 1: Define shared VPN contract

Purpose: make the API/frontend/Firebase contract explicit before parallel work starts.

Tasks:

- Add `TODO/Shared_VPN_Contract.md` as the source-of-truth contract for all later tracks. Do not leave open decisions, `TODO`, `confirm`, or `decide` language in this contract.
- Define JSON and Firestore naming as camelCase everywhere. Use `clientId`, not `client_id`, in route docs, frontend helpers, responses, and contract examples. Python internals may use snake_case only behind Pydantic aliases.
- Define external API URLs as regional Cloudflare-proxied origins:
  - Regional API base URL is `https://<regionId>.<origin>/api`.
  - `<origin>` is the current frontend origin host without protocol, for example `gocloudlaunch.com`.
  - For a frontend loaded from `https://gocloudlaunch.com`, region `us-sanjose-1` calls `https://us-sanjose-1.gocloudlaunch.com/api/*`.
  - FastAPI internal routes do not include `/api`; Caddy strips `/api/*` before proxying to FastAPI.
  - `REACT_APP_API_ORIGIN` is only a local/dev override. When set, frontend API helpers send API calls to `${REACT_APP_API_ORIGIN}/api/*`. In production, leave it unset and derive the regional API URL from `window.location.origin` plus the selected `regionId`.
  - There is no global API router and no frontend base-domain config.
- Define API routes:
  - `GET /health` is unauthenticated, rate limited by Caddy, and returns `{ "status": "ok", "regionId": "us-sanjose-1" }`.
  - `POST /clients` requires Firebase bearer auth, creates a client only for the authenticated user, and accepts `{ "regionId": "us-sanjose-1", "clientName": "Phone" }`. `clientName` is optional; blank/missing values use a simple server default.
  - `POST /clients` returns `{ "clientId": "...", "regionId": "...", "clientName": "...", "status": "active", "assignedTunnelIpv4": "10.0.0.2/32", "assignedTunnelIpv6": "fd42:42:42::2/128", "serverEndpointIpv4": "1.2.3.4", "wireguardConfig": "..." }`.
  - `DELETE /clients/{clientId}` requires Firebase bearer auth and accepts `{ "userId": "firebase-uid", "regionId": "us-sanjose-1" }`. Normal users can only pass their own UID. Admins can pass any target UID.
  - `DELETE /clients/{clientId}` returns `{ "userId": "...", "clientId": "...", "regionId": "...", "status": "removed" }`.
  - `POST /users` requires Firebase bearer auth with admin role, is logically global, and is hosted by every regional API. It does not accept `regionId` and does not mutate regional state.
  - `POST /users` accepts `{ "email": "user@example.com", "password": "temporary-password", "displayName": "User Name" }`. `displayName` is optional.
  - `POST /users` returns `{ "userId": "...", "email": "user@example.com", "role": "user" }`.
- Define typed error response shape for all controlled failures:
  - Response body is `{ "error": { "code": "REGION_MISMATCH", "message": "Requested region does not match this API server.", "requestId": "..." } }`.
  - Error codes are uppercase snake case. Initial required codes are `AUTH_REQUIRED`, `ADMIN_REQUIRED`, `INVALID_REQUEST`, `REGION_DISABLED`, `REGION_MISMATCH`, `LIMIT_REACHED`, `CAPACITY_REACHED`, `CLIENT_NOT_FOUND`, `DUPLICATE_EMAIL`, `INVALID_PASSWORD`, `WIREGUARD_APPLY_FAILED`, `FIREBASE_WRITE_FAILED`, and `INTERNAL_ERROR`.
  - HTTP status mapping: auth failures use `401`, permission failures use `403`, invalid request/region mismatch/invalid password use `400`, missing clients use `404`, duplicate email and capacity/limit failures use `409`, host mutation failures use `500`, and unexpected failures use `500`.
- Define enum values:
  - Roles: `user`, `admin`.
  - Client statuses: `creating`, `active`, `failed`, `removed`.
  - Operation results: `success`, `failed`, `noop`.
- Define Firebase paths:
  - Region documents: `Regions/{regionId}`.
  - User documents: `Users/{uid}`.
  - Client documents: `Users/{uid}/Regions/{regionId}/Instances/{clientId}`.
  - Role documents: `Roles/{uid}`.
- Define `Regions/{regionId}` fields:
  - `regionId`: string, same as document ID.
  - `displayName`: string.
  - `enabled`: boolean.
  - `wireguardEndpointIpv4`: string raw public IPv4 used in client configs.
  - `wireguardEndpointIpv6`: string or null.
  - `wireguardPort`: number, default `51820`.
  - `wireguardDnsIpv4`: string.
  - `wireguardDnsIpv6`: string.
  - `wireguardPublicKey`: string.
  - `capacityLimit`: number.
  - `activeClientCount`: number.
  - `displayOrder`: number, optional.
  - `healthStatus`: string, optional.
  - `updatedAt`: Firestore timestamp.
- Define `Users/{uid}` fields used by the new flow:
  - `uid`: string, same as document ID.
  - `email`: string.
  - `displayName`: string or null.
  - `createdAt`: Firestore timestamp.
  - `disabled`: boolean, optional.
- Define `Roles/{uid}` fields:
  - `role`: `user` or `admin`.
  - `updatedAt`: Firestore timestamp.
- Define client document fields:
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
  - `serverPublicKey`: string.
  - `clientPublicKey`: string.
  - `wireguardConfig`: string or null.
  - `createdAt`: Firestore timestamp.
  - `updatedAt`: Firestore timestamp.
  - `removedAt`: Firestore timestamp or null.
  - `lastErrorCode`: string or null.
  - `lastErrorMessage`: string or null.
- Define frontend permissions:
  - Authenticated users can read enabled region docs.
  - Normal users can read their own user document and own client documents.
  - Admins can read all user, role, and client documents.
  - Frontend clients cannot create, update, or delete VPN client documents directly. Client mutation goes through regional FastAPI using the Firebase Admin SDK.
  - Admins can write `Regions`, `Users`, and `Roles` documents from the frontend where existing admin UI needs it, but not client documents.
- Define user-limit behavior:
  - Normal users default to 3 active clients per region.
  - Admins can create clients only for themselves, but can exceed the normal user limit up to server capacity.
  - Admins can delete clients for any user.
- Define frontend API selection:
  - Client create/delete calls use the active region tab's `regionId` to derive `https://<regionId>.<origin>/api/*`.
  - Derive `<origin>` from `window.location.host`, preserving the current frontend port only for localhost/dev hosts.
  - For localhost/dev, prefer `REACT_APP_API_ORIGIN` when set instead of deriving a regional hostname.
  - Missing `displayOrder` sorts as `1000`.
  - `POST /users` uses `REACT_APP_API_ORIGIN` in local/dev when set. In production it uses the first enabled region sorted by `displayOrder` then `regionId`, because the route is logically global and hosted by every regional API. If there is no enabled region, the frontend shows a controlled error and does not call the API.
- Define API deployment handoff used by infrastructure:
  - Host install directory: `/opt/cloudgateway/api`.
  - Python virtualenv: `/opt/cloudgateway/api/.venv`.
  - App import path: `src.main:app`.
  - Dependency metadata: `API/pyproject.toml`; infrastructure installs the package into the venv from `/opt/cloudgateway/api`.
  - systemd service name: `cloudgateway-api.service`.
  - systemd runs as `root`, working directory `/opt/cloudgateway/api`, binding only to `127.0.0.1`.
  - Environment file path: `/etc/cloudgateway/api.env`, mode `0600`, owned by `root`.
  - Required environment variables: `CLOUDGATEWAY_REGION_ID`, `CLOUDGATEWAY_API_PORT`, `CLOUDGATEWAY_FIREBASE_CREDENTIALS_FILE`, `CLOUDGATEWAY_WG_INTERFACE`, `CLOUDGATEWAY_WG_SERVER_PUBLIC_KEY`, `CLOUDGATEWAY_WG_ENDPOINT_HOSTNAME`, `CLOUDGATEWAY_WG_PORT`, `CLOUDGATEWAY_WG_DNS_IPV4`, `CLOUDGATEWAY_WG_DNS_IPV6`, `CLOUDGATEWAY_WG_TUNNEL_IPV4_CIDR`, and `CLOUDGATEWAY_WG_TUNNEL_IPV6_CIDR`.
  - Default values: `CLOUDGATEWAY_API_PORT=8000`, `CLOUDGATEWAY_WG_INTERFACE=wg0`, and `CLOUDGATEWAY_WG_PORT=51820`.
- Note that API, frontend, infrastructure, and documentation agents must treat `TODO/Shared_VPN_Contract.md` as source of truth after Commit 1.

Validation:

- Manual review against `TODO/Shared_VPN_Plan.md`.
- Search `TODO/Shared_VPN_Contract.md` for `TODO`, `decide`, `confirm`, `TBD`, and `client_id`; the only allowed `client_id` occurrence is an explicit "do not use" note if retained.
- No runtime validation required.

## API Track

### Commit 2: Add regional FastAPI service scaffold

Purpose: introduce the new backend without depending on frontend or infrastructure changes.

Tasks:

- Create `API/` as the new regional Python service folder.
- Add package structure for:
  - app entrypoint.
  - settings/config loading.
  - Pydantic request/response models.
  - enums for roles, statuses, events, and operation results.
  - typed exceptions and HTTP error mapping.
  - structured JSON logging.
  - Firebase auth/repository boundary.
  - WireGuard boundary with test doubles.
- Implement `GET /health` returning `status` and configured `regionId`.
- Add admin-only `POST /users` scaffolding so the old create-user Lambda can be folded into this API.
- Add `API/pyproject.toml` dependency metadata and local test setup for the API folder.
- Ensure FastAPI binds cleanly to localhost when run by uvicorn.

Validation:

- Run API unit tests.
- Run Python compile/type/lint checks available in the new API toolchain.
- Manually inspect logs to confirm JSON structure and no secrets.

### Commit 3: Implement Firebase-backed client create/delete domain logic

Purpose: make the API own product-state mutation through Firebase Admin SDK.

Tasks:

- Verify Firebase ID tokens on protected routes.
- Read user, role, and region metadata from Firebase.
- Enforce region ID equals local server configured region ID.
- Enforce normal users can create/delete only their own clients.
- Allow admins to delete clients across users.
- Enforce per-region user limits and server capacity.
- Generate UUIDv4 client IDs.
- Reserve client documents, assigned tunnel IPv4/IPv6, and counters in Firestore transactions.
- Write reservation/update helpers for owner UID/email/display name, client name, status, assigned tunnel IPs, client public key, created/removed timestamps, and last error fields.
- Leave final WireGuard config generation/storage to the route integration commit after the WireGuard helper exists.
- Implement failure cleanup so `creating` records do not remain indefinitely.
- Update `Firebase/firestore.rules` so normal users/admins can read allowed documents, but frontend cannot create/update/delete client docs directly.

Validation:

- Unit tests for auth, role, ownership, region mismatch, capacity, transactions, status transitions, and failure cleanup.
- Firestore rules review against the planned read/write model.

### Commit 4: Implement WireGuard mutation helper

Purpose: make host WireGuard changes safe, local, testable, and secret-aware.

Tasks:

- Generate fresh WireGuard keypairs per client with `subprocess.run([...], shell=False)`.
- Render client configs from `OCI/wireguard_configs/example.wg0-client.conf` shape.
- Read and render complete `/etc/wireguard/wg0.conf` candidate configs.
- Add exclusive local lock such as `/run/cloudgateway-wireguard.lock`.
- Write timestamped `0600` backup before replace.
- Write candidate and stripped config as `0600` temporary files.
- Validate candidate using `wg-quick strip <candidate>`.
- Atomically replace active config with `os.replace`.
- Apply live interface with `wg syncconf wg0 <stripped_config_file>`.
- Remove peers idempotently; peer already absent should count as removed.
- On apply failure, restore backup and attempt live rollback.
- Never log private keys, full configs, Firebase credentials, auth tokens, or user traffic metadata.

Validation:

- Unit tests with temp config files and fake command runner.
- Tests for add peer, remove peer, already-missing peer, validation failure, apply failure, rollback attempt, and secret redaction.
- Manual code review for `shell=False` and strict input validation.

### Commit 5: Wire API routes to Firebase and WireGuard operations

Purpose: complete the regional control-plane behavior.

Tasks:

- Implement `POST /clients` full create flow.
- Implement `DELETE /clients/{clientId}` full delete flow.
- Add request IDs and operation-scoped structured logs.
- Add cleanup when WireGuard succeeds but final Firebase write fails.
- Add controlled HTTP responses for typed failures.
- Return UI-ready create/delete responses exactly matching contract.
- Add one direct retry only for clearly transient host command failures, if helper can identify them safely.

Validation:

- Route tests for success and controlled failures.
- Integration-style tests using fake Firebase repo and fake WireGuard helper.
- Manual review that no API route logs full configs or private keys.

### Commit 6: Fold create-user into regional API

Purpose: keep admin user creation working while removing the standalone Lambda implementation.

Tasks:

- Port the current `lambda/CreateUser` behavior into the new `API/` service.
- Add admin-only `POST /users`, as defined by Commit 1 contract.
- Verify Firebase ID token and require admin role before creating users.
- Preserve password validation rules unless contract updates them.
- Create Firebase Auth user and Firestore `Users/{uid}` plus `Roles/{uid}` documents.
- Return controlled typed errors for duplicate email, invalid password, missing auth, and Firebase failures.
- Make route reachable through the same `/api/*` path style as the rest of the new API.
- Implement the create-user placement documented by the Commit 1 contract.

Validation:

- Unit tests for password validation, admin auth, duplicate email, successful user creation, and Firestore role/user writes.
- Manual review that no password, token, or Firebase credential is logged.

### Commit 7: Remove legacy Lambda backend

Purpose: complete backend cutoff after the FastAPI replacement exists.

Tasks:

- Remove `lambda/` code, packaging scripts, Lambda README content, and stale Lambda references owned by backend.
- Remove old AWS Secrets Manager / DynamoDB assumptions from active backend docs.
- Keep AWS references only where SES email sending remains relevant.
- Ensure no backend-owned active path still treats Lambda as VPN control plane.

Validation:

- Repository search backend-owned files for `Lambda`, `/api/deploy`, `/api/secureget`, `/api/createuser`, old worker secret headers, and DynamoDB VPN limits.
- API tests still pass.

## Infrastructure Track

### Commit 8: Convert Terraform/cloud-init to shared regional host

Purpose: make OCI create one long-lived regional server instead of per-user VPN stacks.

Tasks:

- Update Terraform variables for shared-server deployment:
  - region ID.
  - API hostname.
  - dashboard CORS origin.
  - FastAPI port.
  - WireGuard public endpoint IPv4.
  - server tunnel DNS IPs.
  - Firebase credential path or injected credential payload.
  - Caddy/Cloudflare settings.
- Remove deploy-time client peer variables from Terraform.
- Update cloud-init to write server `wg0.conf` with no initial `[Peer]`.
- Preserve WireGuard bare-metal install, IP forwarding, NAT, UDP rate limits, and Unbound setup.
- Install Python runtime and API service files according to the Commit 1 deployment handoff.
- Add systemd service for FastAPI using the Commit 1 service name, working directory, config path, root expectation, and `127.0.0.1` bind address.
- Keep WireGuard running through `wg-quick@wg0`.
- Update `OCI/wireguard_configs/example.wg0-server.conf` to shared-server no-peer shape.

Validation:

- `terraform validate`.
- Rendered cloud-init manual review.
- Manual check that rendered server config has no static `[Peer]`.
- Host smoke test after manual deployment: `wg0` starts, Unbound starts, FastAPI listens only on localhost.

### Commit 9: Add Caddy origin protection and rate limiting

Purpose: make the regional public API path safe and Cloudflare-fronted.

Tasks:

- Add custom Caddy build/install flow using `github.com/mholt/caddy-ratelimit`.
- Add Caddyfile template that:
  - listens on `80`/`443`.
  - requires expected regional hostname/SNI from deployment config.
  - requires Cloudflare Authenticated Origin Pulls.
  - allows configured dashboard CORS origin.
  - rate limits `/api/*`, including `/api/health`.
  - strips `/api/*` before proxying to FastAPI.
  - proxies only to `127.0.0.1:<fastapi_port>`.
  - logs API HTTP requests only.
- Add host firewall rules that allow HTTP/HTTPS origin traffic only from Cloudflare IP ranges.
- Keep WireGuard UDP rate limiting separate from Caddy rate limiting.

Validation:

- Caddy config validation on target host.
- Manual health check through Cloudflare: `https://<region>.<origin>/api/health`.
- Manual direct-origin check should fail without Cloudflare Authenticated Origin Pulls and allowed Host/SNI.
- Confirm logs contain API metadata only, not VPN traffic data.

### Commit 10: Remove legacy Cloudflare Worker path

Purpose: complete infrastructure cutoff after Caddy owns the regional API path.

Tasks:

- Remove `cloudflare/` Worker code and wrangler config.
- Remove old Worker secret configuration from infrastructure-owned files or deleted `cloudflare/` docs.
- Remove old same-origin `/api/deploy`, `/api/secureget`, and `/api/createuser` assumptions from infrastructure-owned files or deleted `cloudflare/` docs.
- Keep any required Cloudflare DNS/proxy variables or templates aligned with the Commit 1 contract; durable prose documentation belongs to the documentation track.

Validation:

- Repository search infrastructure-owned files for Worker-only headers and old Worker route names.
- Infrastructure-owned files use the new `/api/*` routes instead of Worker proxy routes.

## Frontend Track

### Commit 11: Replace deploy/terminate model with shared-client data model

Purpose: move React from server instance management to client management.

Tasks:

- Replace old status enum with new enum `creating`, `active`, `failed`, `removed`.
- Rename frontend types from VPN instance language to VPN client language where practical.
- Read regions from Firebase `Regions/{regionId}` instead of SecureGet Lambda.
- Parse region fields for display name, enabled flag, endpoint IPs, DNS IPs, public key, port, capacity, and active count.
- Update `apiEndpoints.ts` around the Commit 1 regional API selection contract: local/dev may use `REACT_APP_API_ORIGIN`, production derives `https://<regionId>.<origin>/api/*` from the selected region ID and current frontend origin.
- Read client docs from `Users/{uid}/Regions/{regionId}/Instances/{clientId}`.
- Preserve admin read path for support across users.
- Stop frontend writes to client docs.

Validation:

- Unit tests for region/client parsing and status normalization.
- TypeScript build.

### Commit 12: Add API calls for clients and create-user

Purpose: make frontend call the new API routes for VPN clients and admin user creation.

Tasks:

- Add API helper for `POST /api/clients` through the region-aware endpoint builder.
- Add API helper for `DELETE /api/clients/{clientId}` with body `{ userId, regionId }` through the region-aware endpoint builder.
- Add admin create-user helper pointed at `POST /api/users`, not Lambda.
- Include Firebase bearer token on protected calls.
- Handle typed error responses from FastAPI.
- Remove old `ACTION.DEPLOY`, `ACTION.TERMINATE`, `/api/deploy`, `/api/secureget`, and old `/api/createuser` Worker/Lambda helper usage.
- Keep the Create Test Account UI functional by wiring it to `POST /api/users`.

Validation:

- Unit tests for API helper URL construction and error handling.
- TypeScript build.
- Manual browser check with mocked/local API if available.

### Commit 13: Build shared-client dashboard UI

Purpose: expose the new user workflow.

Tasks:

- Remove deploy-server form and terminate-server table language.
- Add region tabs above the VPN client table when more than one region exists.
- Switching region tabs clears selected clients.
- Add optional client display-name input.
- Add create-client action for authenticated user in active region.
- Add remove-client action for selected client(s) in active region.
- Ensure normal users manage only their own clients.
- Ensure admins can view/remove clients across users but cannot create clients for other users.
- Show active, failed, removed, and creating states clearly.
- Show stored configs from Firebase.
- Preserve QR code, download, and copy config behavior.
- Show assigned tunnel IPv4/IPv6 and server endpoint IP.
- Make all shown IP addresses copyable with pointer/hover affordance, keyboard access, and immediate copied feedback.

Validation:

- Component/helper tests for tab switching, selection clearing, copyable IPs, create/delete button states, and admin/user visibility.
- TypeScript build.
- Manual browser QA for desktop and mobile widths.

### Commit 14: Remove legacy frontend pages and text

Purpose: finish frontend cutoff and remove old deployment mental model.

Tasks:

- Remove or repurpose `VPNSuccess` if create-client flow no longer needs separate deployment success page.
- Remove old deployment override modal.
- Remove old "instance" labels from visible UI.
- Remove stale config fetch behavior based on public instance IP.
- Update app routes only as needed for retained pages.

Validation:

- TypeScript build.
- Manual navigation smoke test.
- Search `APP/src` for old deploy/terminate/instance wording and review any remaining intentional references.

## Documentation Track

### Commit 15: Rewrite product and architecture docs

Purpose: make repository docs match the new architecture.

Tasks:

- Rewrite root `README.md` for shared regional VPN platform.
- Update architecture diagram and component descriptions.
- Replace Lambda/Worker/Resource Manager deployment story with regional FastAPI/Caddy/WireGuard story.
- Document deployed frontend API behavior: production derives `https://<regionId>.<origin>/api/*` from the selected region ID and current frontend origin, while local/dev can still use `REACT_APP_API_ORIGIN`.
- Document Firebase as product source of truth and `/etc/wireguard/wg0.conf` as persistent host WireGuard config.
- Document clean cutoff: no migration, no old stack compatibility, old configs must be recreated.
- Document privacy/logging boundaries: API logs allowed, VPN traffic logs forbidden.

Validation:

- Manual doc review against `TODO/Shared_VPN_Plan.md`.
- Repository search documentation-owned files for stale architecture claims.

### Commit 16: Add deployment and operations runbooks

Purpose: give manual deployment, validation, and repair steps.

Tasks:

- Add regional deployment runbook:
  - prepare OCI networking.
  - apply Terraform.
  - configure Cloudflare DNS/proxy for the regional API hostname and Authenticated Origin Pulls.
  - create/update Firebase region doc.
  - validate `/api/health`.
  - create/delete test client.
  - verify WireGuard connects to raw server public IPv4 endpoint.
- Add manual repair runbook for Firebase/host WireGuard drift.
- Add VM loss recovery instructions: users rotate/recreate clients.
- Add service restart and log inspection notes for FastAPI, Caddy, WireGuard, and Unbound.
- Add Firebase schema/rules reference.

Validation:

- Manual dry-run review of each command/procedure.
- Confirm runbook avoids logging or asking operators to paste secrets into logs.

## Final Integration Commit

### Commit 17: End-to-end cleanup and cutoff verification

Purpose: make the final PR coherent after independent worktree commits are layered.

Tasks:

- Resolve naming and contract drift across API, frontend, infrastructure, and docs.
- Remove any remaining old active-path references:
  - Lambda deploy/secureget/createuser.
  - Cloudflare Worker proxy.
  - per-user OCI stack deployment.
  - old statuses `pending`, `running`, `terminated`.
  - old deploy/terminate copy.
- Verify file ownership boundaries did not leave duplicate concepts.
- Verify frontend uses the Commit 1 regional API selection contract for production builds.
- Verify create-user works through the new API and no longer depends on Lambda/Worker.
- Update `TODO/Shared_VPN_Plan.md` only if implementation decisions changed.

Validation:

- API test suite.
- Frontend test suite and build.
- `terraform validate`.
- Repository search for old architecture terms and review intentional leftovers.
- Manual one-region deployment checklist before merge:
  - `/api/health` through Cloudflare works.
  - direct origin access fails.
  - user can create one client.
  - client config uses raw server public IPv4 endpoint.
  - WireGuard connects.
  - user can remove client.
  - admin can create user through new API route.
  - Firebase shows expected status/counter changes.
  - `/etc/wireguard/wg0.conf` persists expected peer state.
  - no VPN traffic logs are created.

## Suggested Cherry-Pick Order

1. Commit 1: shared contract.
2. API commits 2-7.
3. Infrastructure commits 8-10.
4. Frontend commits 11-14.
5. Documentation commits 15-16.
6. Final integration commit 17.

API, infrastructure, frontend, and documentation tracks can be developed in parallel after Commit 1. Final integration should be done after all tracks are layered.
