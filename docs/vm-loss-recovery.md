# VM / Boot Volume Loss Recovery

If a regional VM or its boot volume is lost, the server's WireGuard private key and `/etc/wireguard/wg0.conf` are gone with it. Existing client configs for that region are permanently dead: users must rotate by deleting old clients and creating new ones. This is the accepted recovery model — there is no config recovery and no migration.

The server never stores client private keys, and Firebase stores product state, not host secrets, so nothing in Firebase can resurrect the old tunnel.

## Steps

1. Disable the region so the dashboard stops offering it and the API rejects new work:
   * Set `Regions/{regionId}.enabled` to `false` and update `updatedAt`.

2. Redeploy the regional host by following [docs/regional-deployment.md](regional-deployment.md) end to end. A fresh deployment generates a new server WireGuard keypair and may receive a new public IPv4.

3. Update the `Regions/{regionId}` doc for the new host:
   * `wireguardEndpointIpv4` (and `wireguardEndpointIpv6` if used) to the new public IP
   * `wireguardPublicKey` to the new server public key
   * `wireguardPort`, `wireguardDnsIpv4`, `wireguardDnsIpv6` if they changed
   * `activeClientCount` to `0` — the new host starts with no peers
   * `updatedAt`

4. Update the Cloudflare `A` record for `<regionId>.<origin>` if the public IPv4 changed. Keep the record proxied with Authenticated Origin Pulls enforced.

5. Clean up the dead client docs in that region: set each previously `active` doc to `removed` with `removedAt` (admin/Admin SDK, not the frontend). Their stored configs point at the old server key/IP and will never connect.

6. Re-enable the region (`enabled: true`) after the deployment runbook validation passes (`/api/health`, test client create/delete, WireGuard handshake).

7. Notify affected users that they must create new clients in that region. Old configs cannot be repaired and should be deleted from their devices.
