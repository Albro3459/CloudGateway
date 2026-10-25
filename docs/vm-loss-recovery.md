# VM / Boot Volume Loss Recovery

A regional VM or boot volume can be rebuilt without users recreating clients when
you retain the server WireGuard key, tunnel subnets, endpoint hostname, and Firebase data.
Client configs use the DNS-only `wg.<regionId>.<origin>` endpoint. The host keeps
interface configuration only, and boot sync restores live peers and policy from Firestore.

Keep secure backups of regional tfvars, Terraform state, and Firestore. Tfvars and
state contain deployment secrets. Firestore backups can contain client private
keys and full configs. Never publish them or attach them to tickets.

If Terraform state is missing, do not apply first. Run
`./scripts/terraform.sh <region> plan` to identify unmanaged Cloudflare records or
`CloudGatewayManaged=true` OCI instances. Import the canonical resources and
reconcile duplicates before applying.

## Standard Recovery (server key retained)

1. Recover the region's tfvars and state. Preserve `wg_server_private_key`, both
   tunnel subnets, and `wg_endpoint_hostname`. Follow the backup and preflight
   steps in [regional deployment](regional-deployment.md).
2. Rebuild with `./scripts/terraform.sh <region> apply`. This command creates and
   pushes a fresh deploy commit/tag, updates `source_ref`, and applies the saved
   plan. Review the source and replacement plan before confirming.
3. Let Terraform update the DNS-only WireGuard `A` record and proxied API `A`
   record to the new public IPv4. Manual DNS changes are only for reconciling or
   importing resources before rerunning Terraform.
4. Confirm registration refreshed `Regions/{regionId}` with current endpoint
   metadata and successful edge health. The server public key, endpoint hostname,
   and client documents should be unchanged.
5. Confirm peer and policy sync succeeded:

```sh
sudo systemctl start cloudgateway-sync-peers.service
sudo systemctl status cloudgateway-sync-peers.service
sudo journalctl -u cloudgateway-sync-peers.service --since "1 hour ago"
```

6. Validate `/api/health` through Cloudflare and inspect `wg show wg0` for peers
   and live handshakes. For mesh regions, run **Sync All Regions** and verify
   remote routes and handshakes. Endpoint roaming can update a remote peer after
   the rebuilt host sends authenticated traffic.
7. Ask affected users to toggle their tunnel off and on so it re-resolves DNS.
   Existing configs need no changes.

`Mesh/{regionId}` records a reconciliation snapshot and does not prove a live
handshake. See [service operations](service-operations.md) for diagnosis.

## Key-Loss Recovery (server key rotated or compromised)

Rotate only when the key is compromised or no secure copy can be recovered.
Existing client configs embed the old server public key and must be replaced.

1. Disable the region (`enabled: false`).
2. Back up Firestore, generate a new server keypair, and update
   `wg_server_private_key` in the private regional tfvars.
3. Before rebuilding, mark previously `active` clients under
   `Regions/{regionId}/Instances` as `removed` with `removedAt`, using trusted
   Admin SDK access. Retain the documents for history. This prevents boot sync
   from restoring those clients after registration enables the region.
4. Rebuild. Registration writes the new server public key and current endpoint
   metadata and enables the region when edge health passes. Do not assume the
   earlier `enabled: false` survives successful registration.
5. Validate host services, edge health, and peer/policy sync. For mesh regions,
   run **Sync All Regions** to replace the old server key across the fleet.
6. Confirm the region is enabled and ask users to delete old tunnels and create
   new clients. Treat client keys/configs as compromised too if the incident
   exposed Firebase or downloaded configs.
