# WireGuard Peer Drift Repair

Firebase is the single source of truth for WireGuard peers and mesh routes. Nothing is ever saved to `/etc/wireguard/wg0.conf` or any other host state file - the live `wg0` peer set and route table are a disposable projection of the region's `active` client docs plus its mesh-enabled sibling regions, rebuilt by `cloudgateway-sync-peers` on every pass.

Because of that, drift repair is one command on the regional host:

```sh
sudo cloudgateway-sync-peers
```

It logs structured JSON (`peer_sync_started` / `peer_sync_completed` with client and mesh added/updated/removed counts) and exits nonzero on failure. A pass that fails partway still reports what it changed, in a `peer_sync_partial` line carrying the same counters. There is no periodic re-sync: `cloudgateway-sync-peers.service` runs at boot and on demand from the admin dashboard's **Sync All Regions** action.

## What the Sync Does

One-directional, Firebase to server. After a pass, the live peer set equals exactly the union of this region's `active` client docs (with a `clientPublicKey`) and the mesh peers derived from every other enabled, `meshEnabled` region doc:

| Drift case | Result |
| --- | --- |
| Firebase has an `active` client the server is missing | Peer is added - the user's tunnel starts working again |
| Peer's allowed-ips differ from the client doc | Peer is updated to match Firebase |
| Client doc is `removed`/`failed`/`creating` but a matching peer exists | Peer is removed |
| Server has a client-classified peer Firebase does not know | Peer is removed - unknown peers are never adopted into Firebase |
| A sibling region is mesh-enabled and complete/non-overlapping | Mesh peer is applied (re-applied every pass; idempotent, re-resolves the endpoint hostname); endpoint/port/AllowedIPs/keepalive drift is reported as an update |
| A sibling region is missing mesh config, or its subnet overlaps another mesh candidate | Mesh peer is skipped (`skipped-incomplete` / `skipped-overlap`); this is a configuration failure, not pending work; no peer or route is applied for it |
| A mesh candidate's endpoint hostname fails to resolve (`wg set peer ... endpoint` resolves it and exits nonzero) | Only that candidate fails: it is not counted as applied, the other candidates are still applied, and the pass exits nonzero after logging `mesh_peer_apply_failed`. Client peer removal runs first, so a revoked user's peer is still removed. A candidate that failed but is still live with exactly its desired ranges keeps its route (it is still carrying traffic); one that never applied, or whose live ranges differ, gets none |
| A mesh candidate collides with this host's own tunnel network or another candidate, or two candidates share a public key | The whole candidate set is rejected before anything is applied - cryptokey routing is exclusive, so applying either would silently steal ranges from a peer that already owns them. `desired_mesh_peers` filters all three upstream, so a live host reaches this only if that guard is bypassed |
| This region's own `meshEnabled` is off | Any previously-applied mesh peers and routes are torn down (rollback) |

The sync never creates client docs from server state, and there is no per-peer route deletion path for mesh peers. An unknown server peer is either leftover drift or tampering; both deserve removal.

A missing region doc or an empty client list is a successful empty sync (the live peer set is cleared). The sync takes the same `/run/cloudgateway-wireguard.lock` flock as the API, so it cannot interleave with an in-flight create/delete. `cloudgateway-sync-peers` (boot and post-registration) waits for that lock; `POST /api/admin/sync` takes it non-blocking and answers `409 SYNC_IN_PROGRESS` instead of queueing, so admin retries cannot pile up on the host. Every `wg`/`ip` call and the endpoint DNS lookup are individually time-bounded so a wedged call cannot pin the lock.

## Mesh Route Reconciliation

Mesh peers need routes, not just `wg set` allowed-ips: `wg-quick` only auto-installs routes for peers present in the conf file, and runtime-added peers get none. Each pass sweeps `dev wg0` routes rather than deleting per-peer, so the route table converges to the desired mesh set the same way the peer set does:

* Scope: only routes inside the managed aggregates `10.0.0.0/16` (v4) and `fd42:42:42::/48` (v6). Every region's tunnel subnet sits inside them. Nothing outside them is ever touched.
* Skipped unconditionally: this region's own on-link tunnel network, and any route with `proto kernel`.
* Everything else in scope that isn't a currently-desired mesh CIDR is deleted. A deleted route whose CIDR doesn't belong to any current region doc is logged as `mesh_route_reclaimed` (WARNING) - the operator should treat that as a signal a region doc was deleted or rewritten out from under a live route.
* Desired mesh CIDRs are always `ip route replace`d (idempotent), matching the always-re-apply behavior for mesh peers.

## The One Firebase Write

The sync's contract is otherwise one-directional and read-only against Firebase. The single carve-out: while still holding the WireGuard lock, after live peer/route reconciliation the host writes a best-effort full-replacement `Mesh/{regionId}` status doc - server metadata only (region IDs, CIDRs, public keys, endpoint hostnames, and endpoint ports), never per-user data and never handshake timestamps. Skipped-incomplete entries may omit malformed fields and carry a `reasonCode`. A Firestore write failure there is logged (`mesh_status_write_failed`) and does not fail, retry, or roll back an already-successful sync. A status document proves the reconciliation snapshot only; it does not prove a WireGuard handshake. Use `wg show wg0` for live link state.

## Account-Scoped ACL Policy Reconcile

The client-to-client isolation filter (`Backend/API/src/policy.py`, base ruleset in
`/etc/cloudgateway/cloudgateway.nft`, installed by `bootstrap.sh` `PostUp` - see
[TODO/account-scoped-acl.md](../TODO/account-scoped-acl.md)) has its own one-directional
Firebase-to-host reconcile, `reconcile_policy()`, separate from the peer/mesh sync above. It has no
systemd unit or CLI entry point of its own; it runs inside whichever process calls it, triggered by:

* Boot, so a rebuilt or rebooted host repopulates its entire policy map from Firestore without
  needing any peer to poke it. This one runs in the separate `cloudgateway-sync-peers` process,
  not the long-running API process.
* `POST /api/admin/sync` (Sync All), which also reconciles peers and mesh - see
  [docs/api-contract.md](api-contract.md).
* `POST /api/sync/refresh`, the poke any provisioned user's client create/delete triggers on every
  other region - see [docs/api-contract.md](api-contract.md).

A pass pulls the fleet-wide client/account snapshot from Firestore, applies it to
`cg_infra4/6`, `cg_admin4/6`, `cg_slot4/6`, and `cg_pairs4/6` atomically as a single `nft -f -`
load (never incrementally), reads back the live `cg_slot4/6` maps, and writes a best-effort
`Policy/{regionId}` status doc. Status is read back from the live map, not the pulled snapshot, so
it describes what is actually on the wire, not what the region intended to apply - the same rule
`write_mesh_status` follows for `Mesh/{regionId}`. A status write failure never fails a pass. The
status doc is intentionally opaque: row count, data vintage, and map hashes only - never a uid,
email, address, or key.

Concurrency is independent of the peer sync: `reconcile_policy()` takes its own flock at
`/run/cloudgateway-policy.lock`, deliberately not `wireguard.lock()`, so a full policy pass never
contends with `add_peer` on the client create path and never makes an admin's non-blocking Sync
All shed with `409 SYNC_IN_PROGRESS`. Traffic-driven policy pokes in one region never slow client
creation in another. Any number of pokes arriving during a running pull coalesce to one follow-up
pull (depth-1; not a queue).

The flock covers the whole ordered operation, not just the apply: a pass takes the lock first,
then pulls the Firestore snapshot, applies it atomically, reads back the live map, and writes
status - all before releasing it. A later writer therefore cannot pull until the earlier writer has
applied, read back, and written status, so an older snapshot can no longer wait outside the lock
and overwrite a newer map with stale state. Ordering is the flock's job, not a counter's: the
long-running API process (`PolicyCoordinator`) and the separate boot/manual `cloudgateway-sync-peers`
process both call the identical `reconcile_policy()` and are serialized against each other by that
one lock alone. There is no process-local sequence guard or `appliedSequence` ordering signal any
more; no process-local value is or may be presented as a fleet ordering guarantee.

Client creation's inline local policy row (`_write_inline_policy_row()`) runs after the WireGuard
critical section closes, not inside it, and takes the policy flock non-blocking. If a full pass
already owns the lock, the row is shed and logged (`policy_row_lock_busy`) rather than waited for -
the create path's own already-queued reconcile covers it. No Firestore read or nft call happens
while the WireGuard lock is held any more, so a slow policy pull or status write can no longer
stall client creation or make a non-blocking Sync All shed, and a policy failure never turns a
successful client create into an error response.

**Open verification item:** nft verdict precedence (a `drop` in `cg_forward` terminating evaluation
across the pre-existing `iptables`/`ip6tables` `FORWARD` chains), the `cg_forward` chain's
`priority -10` actually running ahead of those chains, and the `ip daddr @cg_tunnel4 ip daddr .
meta mark != @cg_pairs4` concatenated-set comparison syntax have **not been verified on a real
host**. This is a required check before rollout - see the checklist in
[TODO/account-scoped-acl.md](../TODO/account-scoped-acl.md).

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
