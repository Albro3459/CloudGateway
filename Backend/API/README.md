# CloudGateway Regional API

FastAPI control plane for one regional WireGuard host. Every region runs the same API
beside its local `wg0` interface. Firebase is the product source of truth for users,
roles, regions, limits, stored configs, and desired peers.

## Runtime Model

Public requests use `https://api.<origin>/api/*` for global/account traffic and
`https://<regionId>.<origin>/api/*` for regional traffic. The apex API hostname points
at the display-order-1 region. Cloudflare proxies HTTPS to Caddy, which strips `/api`
and forwards to FastAPI on loopback. WireGuard uses unproxied `wg.<regionId>.<origin>`
records.

The OCI bootstrap installs a pushed GitHub ref and runs `cloudgateway-api.service`
as root on `127.0.0.1`, with Uvicorn proxy headers disabled. Root access is needed
for live WireGuard and ACL changes. Caddy and the host firewall enforce HTTPS,
Authenticated Origin Pulls, Host/SNI checks, and outer rate limits. Built-in
OpenAPI and docs routes are disabled.

`/etc/wireguard/wg0.conf` stays interface-only. Client and mesh peers are applied
at runtime. Sync reads desired product state from Firebase and removes unknown
peers. It also writes best-effort `Mesh/{regionId}` and `Policy/{regionId}` status
snapshots, without changing desired client state.

`cloudgateway-register-region` discovers the host's public IPv4 and upserts region
metadata. A successful Cloudflare edge health check enables the region. A failed
check preserves the existing enabled state, so a new region stays disabled and an
already-serving region stays enabled. Registration preserves client subcollections
and allocator fields. Terraform owns DNS records.

## Core Responsibilities

The API verifies Firebase identities, enforces access and capacity limits, provisions
users, and issues device sign-in tokens. Client creation reserves Firestore state
before applying a live peer. Account deletion coordinates peer removal, a fleet-wide
non-active fence, policy refresh, and hard deletion. Boot/manual sync repairs live
peer, mesh, and policy state from Firebase.

## Architecture

* [src/app.py](src/app.py), [src/main.py](src/main.py): app setup, injected dependencies,
  request IDs, logs, errors, and Uvicorn entry point.
* [src/routes.py](src/routes.py): HTTP workflows coordinating Firebase, WireGuard,
  account cleanup, and policy propagation.
* [src/models.py](src/models.py), [src/enums.py](src/enums.py), [src/errors.py](src/errors.py):
  camelCase HTTP models, enums, and error status mapping.
* [src/auth.py](src/auth.py), [src/firebase.py](src/firebase.py): Firebase bearer
  verification, access checks, provisioning, transactions, and Firestore queries.
* [src/device_auth.py](src/device_auth.py), [src/device_auth_firebase.py](src/device_auth_firebase.py):
  temporary device authorization, shared rate limits, and custom-token signing.
* [src/repository.py](src/repository.py): domain models, limits, account slots, and
  paired tunnel-address allocation.
* [src/wireguard.py](src/wireguard.py): key/config generation, peer and route changes,
  and the exclusive `/run/cloudgateway-wireguard.lock`. Commands use argument lists
  with `shell=False`.
* [src/policy.py](src/policy.py), [src/policy_sync.py](src/policy_sync.py): account ACL
  apply/read-back and coalesced policy reconciliation, using a separate policy lock.
* [src/sync.py](src/sync.py), [src/register.py](src/register.py): peer/mesh/policy
  repair and region registration commands.
* [src/settings.py](src/settings.py), [src/logs.py](src/logs.py): environment settings
  and structured logs.

## Routes

Internal routes omit `/api`. All JSON fields use camelCase.

* `GET /health`: unauthenticated regional health.
* `GET /regions`: unauthenticated enabled region names and display order.
* `POST /auth/check-access`: provisioned-user access check and role.
* `POST /device/code`, `/device/verify`, `/device/approve`, `/device/token`: device
  authorization, with shared limits and `Cache-Control: no-store`.
* `GET /capacity`: authenticated local capacity, counting `creating` and `active` clients.
* `POST /clients`: provisioned users create their own regional WireGuard client.
* `DELETE /clients/{clientId}`: users remove their own clients, admins may remove any.
* `DELETE /account`: recent self-sign-in, account-wide peer removal and data deletion.
* `POST /users`: admin provisioning with best-effort SES access email.
* `POST /admin/sync`: admin peer, mesh, and policy repair for this region.
* `POST /sync/refresh`: provisioned-user policy refresh, accepted asynchronously.

See the [API contract](../../docs/api-contract.md) for payloads, permissions, and
errors, and the [Firebase reference](../Firebase/README.md) for data and rules.
Invalid identities return `401 AUTH_REQUIRED`. Firebase token-verification outages
return retryable `503 AUTH_UNAVAILABLE`: retain the session, retry, and keep access
unconfirmed until verification succeeds.

## Settings

[src/settings.py](src/settings.py) defines the defaults. All settings use the
`CLOUDGATEWAY_` prefix:

* API: `REGION_ID`, `API_PORT`, `API_HOSTNAME`, `DASHBOARD_CORS_ORIGIN`,
  `FIREBASE_CREDENTIALS_FILE`.
* WireGuard: `WG_INTERFACE`, `WG_SERVER_PUBLIC_KEY`, `WG_ENDPOINT_HOSTNAME`,
  `WG_PORT`, `WG_DNS_IPV4`, `WG_DNS_IPV6`, `WG_TUNNEL_IPV4_CIDR`, `WG_TUNNEL_IPV6_CIDR`.
* Registration: `REGION_DISPLAY_NAME`, `REGION_DISPLAY_ORDER`, `REGION_CAPACITY_LIMIT`.
* SES: `SES_REGION`, `SES_SENDER`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`.

The dashboard origin must be HTTPS. HTTP is allowed only for `localhost` or literal
loopback IPs. Deployed settings live in root-owned, mode-`0600`
`/etc/cloudgateway/api.env`. Keep credential values out of source control. Production
services must not set `FIREBASE_AUTH_EMULATOR_HOST` or `FIRESTORE_EMULATOR_HOST`.

## Local Development

Use Python 3.12 or newer. See [tool versions](../../docs/tool-versions.md).
From the repo root:

```sh
cd Backend/API
python3 -m venv .venv
./.venv/bin/python -m pip install -e ".[dev]"
CLOUDGATEWAY_REGION_ID=local-region \
CLOUDGATEWAY_WG_SERVER_PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
./.venv/bin/uvicorn src.main:app --host 127.0.0.1 --no-proxy-headers --port 8000
```

The placeholder key is for startup/health checks. Live WireGuard operations require
a real interface and keys. Route/domain tests use fakes instead of host WireGuard.

Run `./scripts/test.sh api` from the repo root for API validation. The separate
`./scripts/test.sh firebase` target runs API tests marked `emulator` alongside
Firestore rules tests, with local Auth and Firestore emulators. Other API tests
need no Firebase credentials or emulators.

The test runner reuses successful editable dependency setup while the API
project metadata, Python environment, and installed package metadata match.
Source-only edits need no reinstall. Dependency changes or missing tools
trigger another sync. The success fingerprint lives inside the ignored `.venv`.

## Deployment And Operations

The bootstrap creates `/opt/cloudgateway/api`, its `.venv`, `/etc/cloudgateway/api.env`,
`cloudgateway-api.service`, `cloudgateway-sync-peers.service`,
`cloudgateway-install-api [ref]`, and `cloudgateway-register-region`.

* [OCI reference](../../Infrastructure/OCI/README.md): Terraform and bootstrap.
* [Deployment setup](../../docs/github-deployment-setup.md): pushed-ref rollout.
* [Service operations](../../docs/service-operations.md): restarts, logs, and triage.
* [Drift repair](../../docs/wireguard-drift-repair.md): peer, mesh, and policy repair.
* [Regional deployment](../../docs/regional-deployment.md): new-region runbook.

## Secrets And Logging

Control-plane logs may include request IDs, operations, region IDs, user IDs, and
emails. Device authorization logs must omit codes, proofs, approval identities,
auth/custom tokens, and request bodies.

Never log or paste WireGuard private keys, full configs, Firebase credentials,
auth tokens, or `/etc/cloudgateway/api.env`. Never log VPN traffic, DNS queries,
destination or packet metadata, or per-user connection history.
