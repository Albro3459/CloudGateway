# CloudGateway Regional API

FastAPI control plane for one shared regional WireGuard host. Each deployed OCI region runs its own copy of this API on the VM that owns the region's `wg0` interface.

The API is regional, not global:

```text
Dashboard
  -> https://<regionId>.<origin>/api/*
      -> Cloudflare proxied DNS
      -> Caddy on the regional OCI host
      -> FastAPI on 127.0.0.1
      -> Firebase Admin SDK
      -> local WireGuard commands
```

Caddy strips `/api/*` before proxying to FastAPI, so the application routes are plain `/health`, `/capacity`, `/clients`, `/clients/{clientId}`, `/users`, and `/auth/check-access`.

## Runtime Model

The API is installed by the OCI host bootstrap from a pushed GitHub ref. It runs as `cloudgateway-api.service`, as root, bound only to `127.0.0.1`. Public HTTPS, Cloudflare Authenticated Origin Pulls, Host/SNI checks, and rate limiting are handled by Caddy and the host firewall.

The API runs as root because it owns the privileged mutation path for the live WireGuard interface. It still keeps the exposed surface small: no built-in OpenAPI/docs routes are enabled, and external browser traffic reaches it only through the regional Caddy `/api/*` proxy.

See [Infrastructure/OCI/README.md](../../Infrastructure/OCI/README.md) for Terraform and host bootstrap details, and [docs/service-operations.md](../../docs/service-operations.md) for service restart and log inspection notes.

## Core Responsibilities

* Verify Firebase bearer tokens on protected requests.
* Enforce provisioned-user and admin-only access rules.
* Read users, roles, regions, and client documents from Firestore.
* Reserve client IDs, tunnel IPs, and regional capacity in Firestore transactions.
* Generate per-client WireGuard keypairs and client config text.
* Apply live `wg0` peer changes with `wg set` under a local lock.
* Store dashboard-visible client state and WireGuard configs in Firebase.
* Rebuild the live WireGuard peer set from Firebase through `cloudgateway-sync-peers`.
* Self-seed the Firestore region doc at boot through `cloudgateway-register-region`: discover the public IPv4, write IP/public-key/endpoint, and enable the region only once the full Cloudflare path validates (health checked through the edge, not just loopback). DNS records are managed by Terraform, not the host.

Firebase is the product source of truth for users, regions, roles, limits, stored configs, and the desired WireGuard peer set. The host's `/etc/wireguard/wg0.conf` stays interface-only and never stores client peers.

## Architecture

[src/main.py](src/main.py)

* Uvicorn entry point. Exposes `app = create_app()`.

[src/app.py](src/app.py)

* Builds the FastAPI app.
* Wires settings, token verification, repository, and WireGuard manager dependencies.
* Adds request IDs, structured request logging, and common error handlers.

[src/routes.py](src/routes.py)

* Defines API routes and request workflows.
* Holds the create/delete coordination between Firebase state and live WireGuard mutation.

[src/auth.py](src/auth.py)

* Extracts Firebase bearer tokens.
* Requires provisioned users or admins depending on the route.
* Disables unprovisioned Firebase accounts during access checks.

[src/firebase.py](src/firebase.py)

* Firebase Admin SDK adapter.
* Verifies ID tokens, creates Auth users, and implements Firestore-backed repository operations.

[src/repository.py](src/repository.py)

* Domain model and repository interface.
* Region/user/client dataclasses, limits, tunnel IP assignment, and access checks.

[src/wireguard.py](src/wireguard.py)

* Local WireGuard adapter.
* Generates keys, renders client configs, validates inputs, applies/removes peers, reads current peers, and syncs drift.
* Uses `subprocess.run([...], shell=False)` and an exclusive flock at `/run/cloudgateway-wireguard.lock`.

[src/sync.py](src/sync.py)

* `cloudgateway-sync-peers` command.
* Reads active clients for the local region from Firebase and makes the live `wg0` peer set match exactly.
* Sync is one-way: Firebase wins, unknown server peers are removed, and sync never writes to Firebase.

[src/logs.py](src/logs.py), [src/errors.py](src/errors.py), [src/enums.py](src/enums.py), [src/models.py](src/models.py), [src/settings.py](src/settings.py)

* Shared logging, typed errors, enums, Pydantic request/response models, and `CLOUDGATEWAY_*` settings.

## Routes

All request/response JSON uses camelCase.

* `GET /health`: unauthenticated health check for the regional API.
* `POST /auth/check-access`: verifies the Firebase token, confirms the user is provisioned, and returns the user's role.
* `GET /capacity`: returns local regional capacity, counting `creating` plus `active` client docs.
* `POST /clients`: creates one WireGuard client for the authenticated user in this region.
* `DELETE /clients/{clientId}`: removes one WireGuard client. Normal users can remove their own clients; admins can remove clients for any user.
* `POST /users`: admin-only user provisioning route. It creates or completes Firebase Auth, `Users/{uid}`, and `UserRoles/{uid}` state, then sends a best-effort SES access email to the user.

For the full route, URL, and error contract, see [docs/api-contract.md](../../docs/api-contract.md). For Firestore paths, security rules, and indexes, see [Backend/Firebase/README.md](../Firebase/README.md).

## Settings

Runtime config is read from environment variables with the `CLOUDGATEWAY_` prefix:

* `CLOUDGATEWAY_REGION_ID`
* `CLOUDGATEWAY_API_PORT`
* `CLOUDGATEWAY_DASHBOARD_CORS_ORIGIN`
* `CLOUDGATEWAY_FIREBASE_CREDENTIALS_FILE`
* `CLOUDGATEWAY_WG_INTERFACE`
* `CLOUDGATEWAY_WG_SERVER_PUBLIC_KEY`
* `CLOUDGATEWAY_WG_ENDPOINT_HOSTNAME`
* `CLOUDGATEWAY_WG_PORT`
* `CLOUDGATEWAY_WG_DNS_IPV4`
* `CLOUDGATEWAY_WG_DNS_IPV6`
* `CLOUDGATEWAY_WG_TUNNEL_IPV4_CIDR`
* `CLOUDGATEWAY_WG_TUNNEL_IPV6_CIDR`
* `CLOUDGATEWAY_SES_REGION`
* `CLOUDGATEWAY_SES_SENDER`
* `CLOUDGATEWAY_AWS_ACCESS_KEY_ID`
* `CLOUDGATEWAY_AWS_SECRET_ACCESS_KEY`

On deployed hosts these values are written by the OCI bootstrap to `/etc/cloudgateway/api.env`, which is root-owned and mode `0600`.

## Local Development

Use Python `3.12` or newer. See [docs/tool-versions.md](../../docs/tool-versions.md) for the repo's expected tooling versions.

Install the package in editable mode with development dependencies:

```sh
cd Backend/API
python -m venv .venv
./.venv/bin/python -m pip install -e ".[dev]"
```

Run the API locally:

```sh
cd Backend/API
CLOUDGATEWAY_REGION_ID=local-region \
CLOUDGATEWAY_WG_SERVER_PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
./.venv/bin/uvicorn src.main:app --host 127.0.0.1 --port 8000
```

Useful local checks:

```sh
cd Backend/API
./.venv/bin/python -m pyright src tests
./.venv/bin/python -m pytest
```

The placeholder `CLOUDGATEWAY_WG_SERVER_PUBLIC_KEY` above is only for local startup/health checks. Local WireGuard operations need a real WireGuard interface and real keys. Most route and domain checks should use the test fakes instead of touching host WireGuard.

## Deployment And Operations

The host bootstrap installs this API from GitHub and creates:

* `/opt/cloudgateway/api`
* `/opt/cloudgateway/api/.venv`
* `/etc/cloudgateway/api.env`
* `cloudgateway-api.service`
* `cloudgateway-sync-peers.service`
* `cloudgateway-install-api [ref]`
* `cloudgateway-register-region` (run once at end of bootstrap to self-seed the region doc)

Related docs:

* [Infrastructure/OCI/README.md](../../Infrastructure/OCI/README.md): regional host and Terraform package.
* [docs/github-deployment-setup.md](../../docs/github-deployment-setup.md): pushed-ref deployment contract and API rollout helper.
* [docs/service-operations.md](../../docs/service-operations.md): service restarts, logs, and triage.
* [docs/wireguard-drift-repair.md](../../docs/wireguard-drift-repair.md): peer sync behavior and repair flow.
* [docs/regional-deployment.md](../../docs/regional-deployment.md): new-region deployment runbook.

## Secrets And Logging

Structured API logs are required for operating the control plane. They may include request IDs, route names, operation status, region IDs, user IDs, and emails.

Never log or paste:

* WireGuard private keys
* full WireGuard configs
* Firebase service account credentials
* Firebase auth tokens
* `/etc/cloudgateway/api.env`
* VPN traffic details, DNS queries, destination IPs, packet metadata, or per-user browsing history
