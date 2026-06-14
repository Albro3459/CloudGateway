# VM / Boot Volume Loss Recovery

A lost regional VM or boot volume is recoverable without users recreating clients, because nothing client-critical lives only on the host:

* The server WireGuard private key comes from the region's `<regionId>.terraform.tfvars`, so a rebuilt host has the same public key.
* Client configs point at the non-proxied DNS endpoint `wg.<regionId>.<origin>`, not a raw IP.
* Peers are never stored on the host; Firebase is the single source of truth and `cloudlaunch-sync-peers` rebuilds the live peer set at boot.

Existing client configs therefore keep working after a rebuild - users just toggle their tunnel off/on so WireGuard re-resolves the DNS name.

## Standard Recovery (server key retained)

1. Optionally set `Regions/{regionId}.enabled` to `false` to pause new client work during the rebuild.
2. Rebuild the host: `terraform apply` per [docs/regional-deployment.md](regional-deployment.md) (the plan will show the instance being replaced). Use the same `wg_server_private_key` and a `source_ref` matching what should run.
3. Update the **grey-cloud** `wg.<regionId>.<origin>` A record to the new public IPv4, and the proxied API record if the IP changed.
4. Update `Regions/{regionId}.wireguardEndpointIpv4` (and `wireguardEndpointIpv6` if used) to the new IP. `wireguardPublicKey`, `wireguardEndpointHostname`, and client docs are unchanged.
5. Confirm the boot peer sync succeeded: `systemctl status cloudlaunch-sync-peers` (or run `sudo cloudlaunch-sync-peers`). The live peer set is rebuilt from the region's `active` client docs.
6. Validate `/api/health` through Cloudflare, then re-enable the region if it was disabled.
7. Tell affected users to toggle their WireGuard tunnel off and on (clients resolve the endpoint DNS at tunnel-up). No config changes are needed.

`activeClientCount` stays correct - it tracks Firebase state, which did not change.

## Key-Loss Recovery (server key rotated or compromised)

Only if the server private key must change (compromise, or the tfvars secret is lost): existing client configs embed the old server public key and are permanently dead.

1. Disable the region (`enabled: false`).
2. Generate a new server keypair, update `wg_server_private_key` in tfvars, and rebuild.
3. Update the region doc: `wireguardPublicKey` to the new public key, endpoint IP as above, `activeClientCount` to `0`.
4. Mark each previously `active` client doc `removed` with `removedAt` (admin/Admin SDK, not the frontend).
5. Re-enable the region after validation and notify users to delete old tunnels and create new clients.
