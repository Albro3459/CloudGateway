# VM / Boot Volume Loss Recovery

A lost regional VM or boot volume is recoverable without users recreating clients, because nothing client-critical lives only on the host:

* The server WireGuard private key comes from the region's `<regionId>.terraform.tfvars`, so a rebuilt host has the same public key.
* Client configs point at the non-proxied DNS endpoint `wg.<regionId>.<origin>`, not a raw IP.
* Peers are never stored on the host; Firebase is the single source of truth and `cloudgateway-sync-peers` rebuilds the live peer set at boot.

Existing client configs therefore keep working after a rebuild - users just toggle their tunnel off/on so WireGuard re-resolves the DNS name.

If Terraform state is missing, do not apply first. Run `./scripts/terraform.sh <region>
plan`; the regional preflight reports existing Cloudflare records or
`CloudGatewayManaged=true` OCI instances that must be imported or deduplicated
before Terraform can safely manage the region again.

## Standard Recovery (server key retained)

A lost host is self-healing when rebuilt with the same
`wg_server_private_key`, tunnel subnets, and endpoint hostname. The normal
self-healing sequence is:

1. Rebuild the host with `./scripts/terraform.sh <region> apply` per
   [docs/regional-deployment.md](regional-deployment.md), using a `source_ref`
   matching what should run.
2. Let Terraform update the **grey-cloud** `wg.<regionId>.<origin>` A record to
   the new public IPv4, and the proxied API record if the IP changed. Touch
   Cloudflare manually only when reconciling/importing resources before rerunning
   Terraform.
3. Registration updates `Regions/{regionId}` with the current endpoint metadata;
   `wireguardPublicKey`, `wireguardEndpointHostname`, and client docs remain
   unchanged.
4. Confirm boot peer sync succeeded with `systemctl status
   cloudgateway-sync-peers` (or run `sudo cloudgateway-sync-peers`). Firebase is
   the source of truth and the live peer set is rebuilt from it.
5. Validate `/api/health` through Cloudflare and inspect `wg show wg0` for peers
   and handshakes. WireGuard endpoint roaming updates remote mesh peers after
   the rebuilt host connects.
6. Tell affected users to toggle their WireGuard tunnel off and on so clients
   re-resolve the endpoint DNS. No config changes are needed.

A subnet change is different and is never address migration. Use this exact order:
disable mesh membership and run **Sync All Regions**, delete all
`Regions/{regionId}/Instances/*` documents without inspecting or migrating
addresses, update the authoritative registry and matching tfvars, deploy, then
explicitly re-enable mesh and run **Sync All Regions**. Verify registration and
health before enabling mesh. Users recreate clients after the new subnet is live.
Before enabling mesh, verify and backfill `wireguardPort` on every existing Region
document; this repository cannot prove live Firestore state or support a missing-
port fallback.

A Mesh status document records the last reconciliation snapshot and does not prove
a live WireGuard handshake; use `wg show wg0` on the host for that check.

For a normal rebuild, capacity stays correct because it is derived from the Firebase client docs, which remain unchanged. A subnet cutover deletes the target region's client docs by design; users recreate clients after deployment.

## Key-Loss Recovery (server key rotated or compromised)

Only if the server private key must change (compromise, or the tfvars secret is lost): existing client configs embed the old server public key and are permanently dead.

1. Disable the region (`enabled: false`).
2. Generate a new server keypair, update `wg_server_private_key` in tfvars, and rebuild.
3. Update the region doc: `wireguardPublicKey` to the new public key and endpoint IP as above.
4. Mark each previously `active` client doc under `Regions/{regionId}/Instances` as `removed` with `removedAt` (admin/Admin SDK, not the frontend).
5. Re-enable the region after validation and notify users to delete old tunnels and create new clients.
