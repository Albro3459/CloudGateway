# Shared VPN Plan

## Goal

Rewrite CloudLaunch into a shared regional VPN platform.

The new architecture keeps one long-lived WireGuard server per OCI region. Users no longer deploy or terminate their own OCI servers. The dashboard adds/removes WireGuard clients on existing regional servers and shows stored configs from Firebase.

This is a clean cutoff. No backwards compatibility with old Lambda-created VPN stacks or old configs.

## Final Decisions

- One VPN server per region.
- WireGuard traffic does not go through Cloudflare.
- Regional API traffic uses Cloudflare DNS/proxy at `https://<region>.gocloudlaunch.com/api/*`.
- WireGuard client configs use the server's actual public IPv4 endpoint.
- Remove Cloudflare Worker from the new flow.
- Remove AWS Lambda from the new flow.
- Keep AWS only for SES emails.
- Use FastAPI for the regional API.
- Run FastAPI bare metal with `systemd`, bound to `127.0.0.1`.
- Run WireGuard bare metal on the host.
- Do not run WireGuard in Docker.
- Use Caddy for automatic HTTPS, `/api/*` stripping, reverse proxy, and rate limiting.
- Use the StreamTrack Caddy pattern: custom Caddy build with `github.com/mholt/caddy-ratelimit`.
- Store user-visible WireGuard configs in Firebase.
- Firebase is the product source of truth for users, regions, clients, roles, limits, and stored configs.
- Firebase is the product source of truth, but `/etc/wireguard/wg0.conf` is the persistent host WireGuard config.
- Add/remove client must update Firebase, update `/etc/wireguard/wg0.conf`, and apply the live `wg0` change.
- No startup reconciliation job is required.

## Architecture

```text
React dashboard
  -> Firebase Auth
  -> Firebase reads for dashboard data/config display
  -> https://<region>.gocloudlaunch.com/api/*
      -> Cloudflare proxied DNS
      -> Caddy on regional OCI server
      -> FastAPI on 127.0.0.1
      -> Firebase Admin SDK
      -> WireGuard host commands

WireGuard client
  -> server public IPv4:51820
  -> wg0 on regional OCI server
```

Cloudflare is only for the regional API. It is not part of the VPN data path.

## Regional Server

Each regional server is created manually through the Terraform stack after VCN, subnet, firewall/security rules, and DNS are prepared.

The Terraform/cloud-init setup should install and configure:

- WireGuard.
- IP forwarding and firewall/NAT rules.
- Optional AdGuard/Unbound DNS stack.
- Python runtime and FastAPI app.
- Firebase Admin credentials.
- Custom Caddy binary with rate limiting support.
- `systemd` services for FastAPI, Caddy, and WireGuard.

The recommended server shape is 2 OCPU and 8-12 GB RAM.

## Caddy

Caddy listens on public `80` and `443`.

Caddy must:

- Manage automatic HTTPS.
- Rate limit API routes.
- Strip `/api/*` before proxying to FastAPI.
- Proxy only to `127.0.0.1:<fastapi_port>`.
- Log API requests at the HTTP layer, but never VPN traffic.

FastAPI should expose clean routes such as `/clients`, `/clients/{client_id}`, `/health`, and should not need to know it is mounted under `/api`.

## FastAPI

FastAPI is the regional control plane. It should be small and boring.

Required behavior:

- Verify Firebase ID tokens on every protected request.
- Use typed Pydantic request/response models.
- Use enums for event names, roles, statuses, and operation results.
- Use structured JSON logs.
- Wrap route handlers and major operation steps in `try/except`.
- Raise typed exceptions from helpers and map them to clear HTTP responses.
- Avoid broad exception swallowing. Failures must log and return a controlled response.
- Generate a fresh WireGuard keypair per client.
- Assign a unique tunnel IPv4/IPv6 per client.
- Store generated client config in Firebase.
- Apply peer changes to local WireGuard immediately.
- Read server deployment config from local env/files, including region ID, public IPv4, WireGuard port, server tunnel DNS IPs, and server public key.

Do not use shell string execution for privileged commands. Use `subprocess.run([...], shell=False)`, strict validation, and a local lock around WireGuard mutation.

## API Routes

Initial routes:

- `GET /health`
- `POST /clients`
- `DELETE /clients/{client_id}`
- Optional admin route: `POST /users`

`POST /clients` creates one WireGuard client in the current region.

`DELETE /clients/{client_id}` removes one WireGuard client from the current region.

The UI selects the regional API hostname instead of asking one global API to route the request.

Each server must have its own region ID in deployment config created by the Terraform stack. Add/remove client requests must include a region ID. The API must compare the requested region ID against the server configured region ID and return an error on mismatch. Do not depend on parsing the region from the hostname.

## Client Create Flow

1. Receive request.
2. Log request received with request ID, action, user UID, email, display name, target email/name if admin-specified, and region.
3. Verify Firebase token.
4. Validate request body.
5. Read user/role/region metadata from Firebase.
6. Check per-region user limit and server capacity.
7. Use a Firestore transaction to reserve the client document, assigned tunnel IP, and counters.
8. Generate fresh WireGuard client keys.
9. Build the client config using the generated client private key, assigned tunnel IPs, server tunnel DNS IPs, server public key, and server public IPv4 endpoint.
10. Acquire local WireGuard mutation lock.
11. Apply the peer to `wg0`.
12. Store final config and running status in Firebase.
13. Log success.
14. Return the client/config data needed by the UI.

If a later step fails after reservation, mark the client failed or roll back the reservation in Firebase. Log the failure and cleanup result.

## Client Delete Flow

1. Receive request.
2. Log request received with request ID, action, user UID, email, display name, target client ID, target email/name if known, and region.
3. Verify Firebase token.
4. Validate request region ID against server configured region ID.
5. Validate ownership/admin permissions.
6. Read client document from Firebase.
7. Acquire local WireGuard mutation lock.
8. Remove the peer from `wg0`.
9. Use Firebase transaction/update to mark the client removed and release counters/IP reservation.
10. Log success.
11. Return success response.

If WireGuard removal fails, log failure and keep Firebase status clear enough for retry/manual repair.

## Firebase

Firebase stores product state and dashboard-visible config data.

Expected collections:

- `Regions/{regionId}`
- `Users/{uid}`
- `Users/{uid}/Regions/{regionId}/Instances/{clientId}`
- `Roles/{roleId}`

Region documents should include:

- display name
- enabled flag
- API hostname
- WireGuard public endpoint IPv4/IPv6
- WireGuard DNS tunnel IPv4/IPv6
- WireGuard public key
- port
- capacity limit
- active client count
- optional health/status metadata

Client documents should include:

- owner UID
- owner email
- owner display name
- client ID
- client display name
- region
- status
- created date
- removed date when applicable
- assigned tunnel IPv4/IPv6
- client public key
- WireGuard config string

Configs are intentionally stored in Firebase so users can view, copy, download, and QR-code them from the dashboard.

## Logging

API logs are required. VPN traffic logs are forbidden.

API logs must be structured JSON and include safe control-plane context:

- request ID
- event enum
- timestamp
- region
- route/action
- HTTP method/status
- authenticated UID
- authenticated email
- authenticated display name
- target UID/email/name when relevant
- client ID when relevant
- operation status
- duration
- warnings
- exception type/message when failures occur

API logs may include user emails and names because they are needed for operation/debugging.

Never log:

- WireGuard private keys
- full WireGuard configs
- Firebase service account secrets
- auth tokens
- DNS queries
- domains requested by VPN users
- destination IPs requested by VPN users
- browsing/app traffic metadata
- packet metadata
- per-user VPN connection history

WireGuard, DNS, and ad-blocking components must not be configured to keep traffic logs. Runtime counters/handshake data exposed by WireGuard are acceptable for live operations, but the application must not persist them.

## Frontend

The CloudGateway UI becomes a shared-client manager.

Required changes:

- Remove deploy-server flow.
- Remove terminate-server flow.
- Show regions from Firebase.
- Let users select a region.
- Let users add/remove clients in that region.
- Show stored configs from Firebase.
- Keep QR code and download/copy config behavior.
- Show active/failed/removed statuses.
- Admins can view/manage users across regions.
- Normal users manage their own clients.

The frontend calls the selected regional API at `https://<region>.gocloudlaunch.com/api/*`.

## Limits

Normal users:

- 3 clients per region by default.
- Can manage their own clients.

Admins:

- Can create/remove clients for any user.
- Can exceed normal user limits up to server capacity.

Server capacity:

- Start with 15-25 clients per region.
- Track active counts in Firebase.
- Use Firestore transactions for reservation/counter updates.

## WireGuard

WireGuard must run directly on the host.

The server keeps local host-only config/secrets:

- server private key
- persistent `/etc/wireguard/wg0.conf` with interface settings and active peers
- systemd service files
- temporary apply files if needed

The server does not keep a second persistent client database outside Firebase. `/etc/wireguard/wg0.conf` is the actual WireGuard service config, not a separate product database.

Add/remove client must update Firebase and `/etc/wireguard/wg0.conf`, then apply the live `wg0` change with WireGuard-native commands/config sync. The persistent config file is what survives reboot. No startup reconciliation job is required.

Use the existing example configs as the template source:

- Client config shape: `OCI/wireguard_configs/example.wg0-client.conf`
- Server config shape: `OCI/wireguard_configs/example.wg0-server.conf`

The client endpoint is public IPv4 only for the initial implementation. IPv6 is still supported inside the tunnel through the assigned IPv6 address and `AllowedIPs = ::/0`.

The server example and cloud-init template must be updated for shared-server mode: no initial static `[Peer]` should be written during Terraform/cloud-init. Peers are added and removed later by the FastAPI control plane.

## Deployment

Deployment is rare and manual.

Flow:

1. Prepare OCI networking.
2. Apply Terraform stack for the regional server.
3. Cloud-init configures host services.
4. Add/update the region document in Firebase.
5. Add/update Cloudflare DNS record for `https://<region>.gocloudlaunch.com/api/*`.
6. Verify `/api/health`.
7. Verify add/remove client from the dashboard.
8. Verify WireGuard connects using the raw server public IPv4 endpoint.

## Implementation Order

1. Finalize Firebase schema and region documents.
2. Create regional FastAPI app from reusable Lambda code where it still fits.
3. Add structured logging, typed models, enums, and typed exceptions.
4. Implement WireGuard helper with fresh key generation, IP assignment, local lock, persistent `wg0.conf` updates, and live apply/remove peer actions.
5. Update OCI Terraform/cloud-init for shared regional server setup.
6. Add custom Caddy build/config using the StreamTrack rate-limit pattern.
7. Update frontend to remove deploy/terminate server flows and add client management.
8. Remove Worker/Lambda dependencies from the active path.
9. Manually deploy one region and test end to end.
10. Roll out additional regions.

## Non-Goals

- No old stack migration.
- No old config recovery.
- No global API router.
- No Cloudflare Worker in the new path.
- No Docker for WireGuard.
- No VPN traffic logging.
- No high-scale orchestration or distributed queue unless real usage proves it is needed.
