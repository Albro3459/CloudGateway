# WireGuard Peer Drift Repair

Firebase is the single source of truth for WireGuard peers. Peers are never saved to `/etc/wireguard/wg0.conf` or any other host state file - the live `wg0` peer set is a disposable projection of the region's `active` client docs, rebuilt by `cloudgateway-sync-peers` on every boot.

Because of that, drift repair is one command on the regional host:

```sh
sudo cloudgateway-sync-peers
```

It logs structured JSON (`peer_sync_started` / `peer_sync_completed` with added/updated/removed counts) and exits nonzero on failure. The same binary runs at boot via `cloudgateway-sync-peers.service`, which retries on failure until Firebase is reachable.

## What the Sync Does

One-directional, Firebase to server. After a pass, the live peer set equals exactly the set of `active` client docs (with a `clientPublicKey`) for this region:

| Drift case | Result |
| --- | --- |
| Firebase has an `active` client the server is missing | Peer is added - the user's tunnel starts working again |
| Peer's allowed-ips differ from the client doc | Peer is updated to match Firebase |
| Client doc is `removed`/`failed`/`creating` but a matching peer exists | Peer is removed |
| Server has a peer Firebase does not know | Peer is removed - unknown peers are never adopted into Firebase |

The sync never writes to Firebase and never creates client docs from server state. An unknown server peer is either leftover drift or tampering; both deserve removal.

A missing region doc or an empty client list is a successful empty sync (the live peer set is cleared). The sync takes the same `/run/cloudgateway-wireguard.lock` flock as the API, so it cannot interleave with an in-flight create/delete.

## Diagnosing Before/After

```sh
sudo wg show wg0                      # live peers (public keys, handshakes)
sudo systemctl status cloudgateway-sync-peers
sudo journalctl -u cloudgateway-sync-peers --since "1 hour ago"
```

Compare against Firestore: the region's client docs live at `Regions/{regionId}/Instances/{clientId}` with `status`, `ownerUid`, and `clientPublicKey` fields (admin/Admin SDK access).

If a user's tunnel is down but their doc is `active` and the peer is present after a sync, the problem is not peer drift - check the endpoint DNS record, handshakes (`wg show wg0 latest-handshakes`), and Unbound per [docs/service-operations.md](service-operations.md).

## Stale Reservations

A `creating` client doc holds a tunnel IP and a capacity slot until the create request promotes it to `active` or rolls it back. If the API process dies mid-create (crash, OOM, redeploy in the request window), the doc can be left `creating` indefinitely - the peer sync ignores `creating` docs, so nothing reclaims it. Symptom: a region reports less available capacity than its `active` client docs explain. Repair by listing client docs with `status == creating` that are older than a few minutes and deleting them or marking them `removed`. There is no automatic reaper.

Never paste WireGuard private keys, full configs, Firebase credentials, or auth tokens into logs or tickets. Reference peers by client ID or public key.
