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

A rebuild or destroy uses the same mandatory drain order, even when the host is already lost:

1. Run `python3 scripts/region-lifecycle.py prepare-drain <regionId>`; this disables the target and mesh membership and records the drain timestamp.
2. In the dashboard, run **Sync All Regions** across every remaining enabled region.
3. Run `python3 scripts/region-lifecycle.py verify-drain <regionId>`.
4. Rebuild the host with `./scripts/terraform.sh <region> apply` per [docs/regional-deployment.md](regional-deployment.md). The wrapper blocks before deploy tag, `source_ref`, or Terraform mutation if verification fails. Use the same `wg_server_private_key` when it is retained and a `source_ref` matching what should run.
5. Let Terraform update the **grey-cloud** `wg.<regionId>.<origin>` A record to the new public IPv4, and the proxied API record if the IP changed. Touch Cloudflare manually only when reconciling/importing resources before rerunning Terraform.
6. Update `Regions/{regionId}.wireguardEndpointIpv4` (and `wireguardEndpointIpv6` if used) to the new IP. `wireguardPublicKey`, `wireguardEndpointHostname`, and client docs are unchanged.
7. Confirm the boot peer sync succeeded: `systemctl status cloudgateway-sync-peers` (or run `sudo cloudgateway-sync-peers`). The live peer set is rebuilt from Firebase.
8. Validate `/api/health` through Cloudflare. Registration may restore `enabled=true`, but preserves `meshEnabled=false`; explicitly enable mesh and run Sync All only after validation.
9. Tell affected users to toggle their WireGuard tunnel off and on (clients resolve the endpoint DNS at tunnel-up). No config changes are needed.

A Mesh status document records the last reconciliation snapshot and does not prove a live WireGuard handshake; use `wg show wg0` on the host for that check.

Capacity stays correct because it is derived from Firebase client docs, which did not change.

## Key-Loss Recovery (server key rotated or compromised)

Only if the server private key must change (compromise, or the tfvars secret is lost): existing client configs embed the old server public key and are permanently dead.

1. Disable the region (`enabled: false`).
2. Generate a new server keypair, update `wg_server_private_key` in tfvars, and rebuild.
3. Update the region doc: `wireguardPublicKey` to the new public key and endpoint IP as above.
4. Mark each previously `active` client doc under `Regions/{regionId}/Instances` as `removed` with `removedAt` (admin/Admin SDK, not the frontend).
5. Re-enable the region after validation and notify users to delete old tunnels and create new clients.
