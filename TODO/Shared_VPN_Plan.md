# Shared VPN Plan

## Goal

Rewrite CloudLaunch into a shared regional VPN platform.

The new architecture keeps one long-lived WireGuard server per OCI region. Users no longer deploy or terminate their own OCI servers. The dashboard adds/removes WireGuard clients on existing regional servers and shows stored configs from Firebase.

This is a clean cutoff. No backwards compatibility with old Lambda-created VPN stacks or old configs.

## Final Decisions

- One VPN server per region.
- WireGuard traffic does not go through Cloudflare.
- Regional API traffic uses Cloudflare DNS/proxy at `https://<region>.<origin>/api/*`.
- WireGuard client configs use the server's actual public IPv4 endpoint.
- Remove Cloudflare Worker from the new flow.
- Remove AWS Lambda from the new flow.
- Keep AWS only for SES emails.
- Use FastAPI for the regional API.
- Run FastAPI bare metal as root with `systemd`, bound to `127.0.0.1`.
- Run WireGuard bare metal on the host.
- Do not run WireGuard in Docker.
- Use Caddy for automatic HTTPS, `/api/*` stripping, reverse proxy, and rate limiting.
- Use the StreamTrack Caddy pattern: custom Caddy build with `github.com/mholt/caddy-ratelimit`.
- Require Cloudflare Authenticated Origin Pulls for the regional API origin.
- Restrict regional API origin access with exact regional Host/SNI allowlisting and host firewall rules that only allow HTTP/HTTPS origin traffic from Cloudflare IP ranges.
- Store user-visible WireGuard configs in Firebase.
- Firebase is the product source of truth for users, regions, clients, roles, limits, and stored configs.
- Firebase is the product source of truth, but `/etc/wireguard/wg0.conf` is the persistent host WireGuard config.
- Add/remove client must update Firebase, update `/etc/wireguard/wg0.conf`, and apply the live `wg0` change.
- No startup reconciliation or startup repair job is required. On reboot, the host uses `/etc/wireguard/wg0.conf` and continues normally.
- Firebase drift from host WireGuard state is an accepted manual-repair risk for the initial implementation.
- Users create clients only for themselves. There is no admin-create-client-for-another-user flow.
- Client IDs must be globally unique UUIDv4 values.
- Delete requests must identify the target user ID, region ID, and client ID. Normal users can only target their own user ID. Admins can target any user ID.
- Admins can view all stored client config data for support.
- If a regional VM or boot volume is lost, users in that region must rotate/recreate clients. This is acceptable for the initial implementation.

## Architecture

```text
React dashboard
  -> Firebase Auth
  -> Firebase reads for dashboard data/config display
  -> https://<region>.<origin>/api/*
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
- WireGuard UDP `iptables`/`ip6tables` rate limits.
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
- Require Cloudflare Authenticated Origin Pulls so regional API requests must come through Cloudflare.
- Require the expected regional hostname in Host/SNI and reject requests for unknown hostnames.
- Configure the OCI/security-list/host firewall so public `80`/`443` origin traffic is accepted only from Cloudflare IP ranges.
- Rate limit API routes, including `/health`.
- Strip `/api/*` before proxying to FastAPI.
- Proxy only to `127.0.0.1:<fastapi_port>`.
- Log API requests at the HTTP layer, but never VPN traffic.

FastAPI should expose clean routes such as `/clients`, `/clients/{client_id}`, `/health`, and should not need to know it is mounted under `/api`.

The frontend origin will be something like `https://gocloudlaunch.com` or `https://gateway.gocloudlaunch.com`. This will be referred to as `<origin>`. Regional APIs are `https://<region>.<origin>/api/*`. The API/Caddy configuration must allow the dashboard origin for browser requests while keeping direct origin access blocked behind Cloudflare Authenticated Origin Pulls, exact regional Host/SNI checks, and Cloudflare-only origin firewall rules. Authenticated Origin Pulls alone are not enough because another Cloudflare zone could otherwise point at the same origin if host and network gates are too broad.

## FastAPI

FastAPI is the regional control plane. It should be small and boring.

FastAPI runs as root because it owns the regional control-plane mutation path for `/etc/wireguard/wg0.conf` and the live `wg0` interface. It must still bind only to `127.0.0.1` and stay reachable only through Caddy.

Required behavior:

- Verify Firebase ID tokens on every protected request.
- Use typed Pydantic request/response models.
- Use enums for event names, roles, statuses, and operation results.
- Explicitly type API fields and internal values that cross module boundaries. Do not pass raw status/action/result strings around when an enum fits.
- Use structured JSON logs.
- Wrap route handlers and major operation steps in `try/except`.
- Raise typed exceptions from helpers and map them to clear HTTP responses.
- Avoid broad exception swallowing. Failures must log and return a controlled response.
- Generate a fresh WireGuard keypair per client.
- Assign a unique tunnel IPv4/IPv6 per client.
- Accept an optional user-provided client display name.
- Store generated client config in Firebase.
- Apply peer changes to local WireGuard immediately.
- Read server deployment config from local env/files, including region ID, public IPv4, WireGuard port, server tunnel DNS IPs, and server public key.

Do not use shell string execution for privileged commands. Use `subprocess.run([...], shell=False)`, strict validation, and a local lock around WireGuard mutation.

## API Routes

Initial routes:

- `GET /health`
- `POST /clients`
- `DELETE /clients/{client_id}`

`GET /health` is intentionally kept for regional deployment checks. It must still be reached through Cloudflare/Caddy and must be rate limited like the rest of the API surface.

`POST /clients` creates one WireGuard client for the authenticated user in the current region.

`DELETE /clients/{client_id}` removes one WireGuard client owned by the authenticated user from the current region. Admins can remove clients across users when acting from the admin UI.

The UI selects the regional API hostname instead of asking one global API to route the request.

Each server must have its own region ID in deployment config created by the Terraform stack. Add/remove client requests must include a region ID. The API must compare the requested region ID against the server configured region ID and return an error on mismatch. Do not depend on parsing the region from the hostname.

`GET /health` response:

```json
{
  "status": "ok",
  "regionId": "us-sanjose-1"
}
```

`POST /clients` request:

```json
{
  "regionId": "us-sanjose-1",
  "clientName": "Phone"
}
```

`clientName` is optional. If provided, save it to the Firebase client document. If blank or missing, the API can use a simple default display name.

`POST /clients` response:

```json
{
  "clientId": "6f77fd32-ecf5-4dd7-9d96-6bb84de92df1",
  "regionId": "us-sanjose-1",
  "clientName": "Phone",
  "status": "active",
  "assignedTunnelIpv4": "10.0.0.2/32",
  "assignedTunnelIpv6": "fd42:42:42::2/128",
  "serverEndpointIpv4": "1.2.3.4",
  "wireguardConfig": "..."
}
```

`DELETE /clients/{client_id}` request:

```json
{
  "userId": "firebase-uid",
  "regionId": "us-sanjose-1"
}
```

For normal users, `userId` must match the authenticated UID. For admins, `userId` can identify any target user. The API must still verify that the client document at `Users/{userId}/Regions/{regionId}/Instances/{clientId}` exists and matches the requested IDs before mutating WireGuard.

`DELETE /clients/{client_id}` response:

```json
{
  "userId": "firebase-uid",
  "clientId": "6f77fd32-ecf5-4dd7-9d96-6bb84de92df1",
  "regionId": "us-sanjose-1",
  "status": "removed"
}
```

Initial client statuses must be represented as explicit backend/frontend enums, not loose strings:

- `creating`
- `active`
- `failed`
- `removed`

## Client Create Flow

1. Receive request.
2. Log request received with request ID, action, user UID, email, display name, optional client name, and region.
3. Verify Firebase token.
4. Validate request body.
5. Read user/role/region metadata from Firebase.
6. Check per-region user limit and server capacity.
7. Generate a globally unique UUIDv4 client ID and fresh WireGuard client keys.
8. Use a Firestore transaction to reserve the client document, assigned tunnel IP, and counters.
9. Build the client config using the generated client private key, assigned tunnel IPs, server tunnel DNS IPs, server public key, and server public IPv4 endpoint.
10. Acquire local WireGuard mutation lock.
11. Apply the peer to `wg0`.
12. Store final config and running status in Firebase.
13. Log success.
14. Return the client/config data needed by the UI.

If a later step fails after reservation, mark the client `failed` or roll back the reservation in Firebase. Log the failure and cleanup result. Do not leave `creating` records indefinitely.

If create applies a peer to WireGuard but the final Firebase doc/config write fails, remove the peer, release the assigned IP/counter reservation when possible, and mark the client document `failed` if the document exists. This cleanup is part of the active create operation only. Do not run a startup reconciliation or repair job later.

Do not add a heavy idempotency system for the initial implementation. One direct retry is acceptable only for clearly transient host command failures. Otherwise, retries after a failed create can create a new client, as long as counters/IP reservations are kept clear enough to avoid obvious leaks.

## Client Delete Flow

1. Receive request.
2. Log request received with request ID, action, user UID, email, display name, target client ID, and region.
3. Verify Firebase token.
4. Validate request user ID, region ID, and client ID.
5. Validate request region ID against server configured region ID.
6. Validate ownership/admin permissions. Normal users can only delete clients under their own UID. Admins can delete clients across users.
7. Read client document from Firebase.
8. Acquire local WireGuard mutation lock.
9. Remove the peer from `wg0`.
10. Use Firebase transaction/update to mark the client removed and release counters/IP reservation.
11. Log success.
12. Return success response.

If WireGuard removal fails because the peer is already gone, treat the WireGuard removal as complete, mark the client `removed`, and release the assigned IP/counter reservation. If WireGuard removal fails for another reason, log failure and keep Firebase status clear enough for retry/manual repair.

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
- globally unique UUIDv4 client ID
- client display name
- region
- status
- created date
- removed date when applicable
- assigned tunnel IPv4/IPv6
- client public key
- WireGuard config string

Configs are intentionally stored in Firebase so users can view, copy, download, and QR-code them from the dashboard.

Firestore rules must be updated for the shared-client model:

- Normal users can read their own user, region, client, and stored config documents.
- Normal users cannot directly create, remove, or update VPN client documents from the frontend.
- Client create/remove writes must go through regional FastAPI using the Firebase Admin SDK.
- Admins can read and update other users' documents for support and management.
- Public region metadata can be readable by authenticated users when needed by the dashboard.

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
- Let users provide an optional display name when adding a client.
- Show stored configs from Firebase.
- Keep QR code and download/copy config behavior.
- Show active/failed/removed statuses.
- Admins can view/manage users across regions, but do not create clients for other users.
- Normal users manage their own clients.
- Show region tabs above the VPN table when there is more than one region.
- Switching region tabs clears selected clients.
- Remove/delete actions apply only to clients in the active region tab.
- All IP addresses shown in the frontend must be copyable.
- On mouse hover, copyable IPs should show copy affordance such as pointer cursor, subtle highlight, underline, or copy icon.
- On click/tap, copy the raw IP/address to the clipboard and show immediate copied feedback.
- Copyable IP controls must be keyboard accessible.

The frontend calls the selected regional API at `https://<region>.<origin>/api/*`.

## Limits

Normal users:

- 3 clients per region by default.
- Can manage their own clients.

Admins:

- Can view and remove clients across users.
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

Add/remove client must update Firebase and `/etc/wireguard/wg0.conf`, then apply the live `wg0` change with WireGuard-native commands/config sync. The persistent config file is what survives reboot. No startup reconciliation or startup repair job is required. If Firebase and the host drift outside an active create/delete operation, that is a real incident and must be repaired manually.

WireGuard mutation procedure:

1. Acquire an exclusive local lock, such as `/run/cloudlaunch-wireguard.lock`, before reading or writing WireGuard state.
2. Read `/etc/wireguard/wg0.conf` and render a complete candidate config from the existing interface settings plus the desired peer set.
3. Write a timestamped `0600` backup before replacing the active config.
4. Write the candidate to a `0600` temporary file in `/etc/wireguard`.
5. Validate the candidate by running `wg-quick strip <candidate>` with `subprocess.run([...], shell=False)`.
6. Atomically replace `/etc/wireguard/wg0.conf` with the candidate using `os.replace`.
7. Apply the live interface using `wg syncconf wg0 <stripped_config_file>` generated from `wg-quick strip`.
8. If live apply fails, restore the backup config, attempt to sync the live interface back to the backup, mark the Firebase operation `failed`, and log the cleanup result.
9. Release the lock only after persistent config, live interface state, and Firebase operation status have been updated or the failure has been recorded.

The helper must never pass private keys, full configs, or auth tokens to logs. Log peer public key fingerprints or client IDs instead.

WireGuard UDP rate limiting must remain in the host firewall rules. Caddy rate limiting protects the regional API only and does not protect UDP VPN traffic.

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
5. Add/update Cloudflare DNS record for `https://<region>.<origin>/api/*`.
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
