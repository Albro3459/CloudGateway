# WireGuard Peer Drift Repair

Firebase is the single source of truth for WireGuard peers and mesh routes. Nothing is ever saved to `/etc/wireguard/wg0.conf` or any other host state file - the live `wg0` peer set and route table are a disposable projection of the region's `active` client docs plus its mesh-enabled sibling regions, rebuilt by `cloudgateway-sync-peers` on every pass.

Because of that, drift repair is one command on the regional host:

```sh
sudo cloudgateway-sync-peers
```

It logs structured JSON (`peer_sync_started` / `peer_sync_completed` with client and mesh added/updated/removed counts) and exits nonzero on failure. There is no periodic re-sync: `cloudgateway-sync-peers.service` runs at boot (twice - once early for client peers, once more at the end of bootstrap after region registration, so mesh peers for already-known regions are picked up), and it also runs on demand from the admin dashboard's sync action.

## What the Sync Does

One-directional, Firebase to server. After a pass, the live peer set equals exactly the union of this region's `active` client docs (with a `clientPublicKey`) and the mesh peers derived from every other enabled, `meshEnabled` region doc:

| Drift case | Result |
| --- | --- |
| Firebase has an `active` client the server is missing | Peer is added - the user's tunnel starts working again |
| Peer's allowed-ips differ from the client doc | Peer is updated to match Firebase |
| Client doc is `removed`/`failed`/`creating` but a matching peer exists | Peer is removed |
| Server has a client-classified peer Firebase does not know | Peer is removed - unknown peers are never adopted into Firebase |
| A sibling region is mesh-enabled and complete/non-overlapping | Mesh peer is applied (re-applied every pass; idempotent, re-resolves the endpoint hostname); endpoint/port/AllowedIPs/keepalive drift is reported as an update |
| A sibling region is missing mesh config, or its subnet overlaps another mesh candidate | Mesh peer is skipped (`skipped-incomplete` / `skipped-overlap`); no peer or route is applied for it |
| This region's own `meshEnabled` is off | Any previously-applied mesh peers and routes are torn down (rollback) |

The sync never creates client docs from server state, and there is no per-peer route deletion path for mesh peers. An unknown server peer is either leftover drift or tampering; both deserve removal.

A missing region doc or an empty client list is a successful empty sync (the live peer set is cleared). The sync takes the same `/run/cloudgateway-wireguard.lock` flock as the API, so it cannot interleave with an in-flight create/delete.

## Mesh Route Reconciliation

Mesh peers need routes, not just `wg set` allowed-ips: `wg-quick` only auto-installs routes for peers present in the conf file, and runtime-added peers get none. Each pass sweeps `dev wg0` routes rather than deleting per-peer, so the route table converges to the desired mesh set the same way the peer set does:

* Scope: only routes inside the aggregates `10.0.0.0/16` (v4) and `fd42:42:42::/48` (v6) - documentation-only ranges that every region's tunnel subnet sits inside. Nothing outside them is ever touched.
* Skipped unconditionally: this region's own on-link tunnel network, and any route with `proto kernel`.
* Everything else in scope that isn't a currently-desired mesh CIDR is deleted. A deleted route whose CIDR doesn't belong to any current region doc is logged as `mesh_route_reclaimed` (WARNING) - the operator should treat that as a signal a region doc was deleted or rewritten out from under a live route.
* Desired mesh CIDRs are always `ip route replace`d (idempotent), matching the always-re-apply behavior for mesh peers.

## The One Firebase Write

The sync's contract is otherwise one-directional and read-only against Firebase. The single carve-out: while still holding the WireGuard lock, after live peer/route reconciliation the host writes a best-effort full-replacement `Mesh/{regionId}` status doc - server metadata only (region IDs, CIDRs, public keys, endpoint hostnames, and endpoint ports), never per-user data and never handshake timestamps. Skipped-incomplete entries may omit malformed fields and carry a `reasonCode`. A Firestore write failure there is logged (`mesh_status_write_failed`) and does not fail, retry, or roll back an already-successful sync.

Drain verification uses these status snapshots as a freshness and membership barrier: after `prepare-drain`, every remaining enabled region must run Sync All so its `Mesh/{regionId}.updatedAt` is strictly newer than the target's `drainRequestedAt` and its peer map omits the drained region and public key. A status document proves the reconciliation snapshot only; it does not prove a WireGuard handshake. Use `wg show wg0` for live link state.

## Diagnosing Before/After

```sh
sudo wg show wg0                      # live peers (public keys, handshakes)
sudo ip -4 route show dev wg0         # live v4 routes, including mesh
sudo ip -6 route show dev wg0         # live v6 routes, including mesh
sudo systemctl status cloudgateway-sync-peers
sudo journalctl -u cloudgateway-sync-peers --since "1 hour ago"
```

Compare against Firestore: the region's client docs live at `Regions/{regionId}/Instances/{clientId}` with `status`, `ownerUid`, and `clientPublicKey` fields (admin/Admin SDK access).

If a user's tunnel is down but their doc is `active` and the peer is present after a sync, the problem is not peer drift - check the endpoint DNS record, handshakes (`wg show wg0 latest-handshakes`), and AdGuard Home / Unbound per [docs/service-operations.md](service-operations.md).

## Stale Reservations

A `creating` client doc holds a tunnel IP and a capacity slot until the create request promotes it to `active` or rolls it back. If the API process dies mid-create (crash, OOM, redeploy in the request window), the doc can be left `creating` indefinitely - the peer sync ignores `creating` docs, so nothing reclaims it. Symptom: a region reports less available capacity than its `active` client docs explain. Repair by listing client docs with `status == creating` that are older than a few minutes and deleting them or marking them `removed`. There is no automatic reaper.

Never paste WireGuard private keys, full configs, Firebase credentials, or auth tokens into logs or tickets. Reference peers by client ID or public key.
