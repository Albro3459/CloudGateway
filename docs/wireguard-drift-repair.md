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

A missing region doc or an empty client list is a successful empty sync (the live peer set is cleared). The sync takes the same `/run/cloudgateway-wireguard.lock` flock as the API, so it cannot interleave with an in-flight create/delete. `cloudgateway-sync-peers` (boot and post-registration) waits for that lock; `POST /api/admin/sync` takes it non-blocking and answers `409 SYNC_IN_PROGRESS` instead of queueing, so admin retries cannot pile up on the host. Every `wg`/`ip` call and the endpoint DNS lookup are individually time-bounded so a wedged call cannot pin the lock. `getaddrinfo` cannot itself be cancelled, so the caller's bound only frees the caller: lookups run on one process-wide resolver worker behind a non-queueing gate, and while a lookup is stuck every further lookup returns unresolved immediately (forcing a re-apply of that mesh peer next pass) instead of stacking up threads.

## Mesh Route Reconciliation

Mesh peers need routes, not just `wg set` allowed-ips: `wg-quick` only auto-installs routes for peers present in the conf file, and runtime-added peers get none. Each pass sweeps `dev wg0` routes rather than deleting per-peer, so the route table converges to the desired mesh set the same way the peer set does:

* Scope: only routes inside the managed aggregates `10.0.0.0/16` (v4) and `fd42:42:42::/48` (v6). Every region's tunnel subnet sits inside them. Nothing outside them is ever touched.
* Skipped unconditionally: this region's own on-link tunnel network, and any route with `proto kernel`.
* Everything else in scope that isn't a currently-desired mesh CIDR is deleted. A deleted route whose CIDR doesn't belong to any current region doc is logged as `mesh_route_reclaimed` (WARNING) - the operator should treat that as a signal a region doc was deleted or rewritten out from under a live route.
* Desired mesh CIDRs are always `ip route replace`d (idempotent), matching the always-re-apply behavior for mesh peers.
* A route command failure is part of the same partial-failure model as the mesh peer apply phase: the pass still emits one `peer_sync_partial` line (with `routeReconciliationFailed: true`) plus a `mesh_route_reconcile_failed` line, and an earlier mesh-peer failure stays the error the pass exits with. A route-only failure is that error itself. Both repair on the next successful pass.

## The One Firebase Write

The sync's contract is otherwise one-directional and read-only against Firebase. The single carve-out: while still holding the WireGuard lock, after live peer/route reconciliation the host writes a best-effort full-replacement `Mesh/{regionId}` status doc - server metadata only (region IDs, CIDRs, public keys, endpoint hostnames, and endpoint ports), never per-user data and never handshake timestamps. Skipped-incomplete entries may omit malformed fields and carry a `reasonCode`. A Firestore write failure there is logged (`mesh_status_write_failed`) and does not fail, retry, or roll back an already-successful sync. A status document proves the reconciliation snapshot only; it does not prove a WireGuard handshake. Use `wg show wg0` for live link state.

## Account-Scoped ACL Policy Reconcile

The client-to-client isolation filter (`Backend/API/src/policy.py`, base ruleset in
`/etc/cloudgateway/cloudgateway.nft`, installed by `bootstrap.sh` `PostUp` - see
[TODO/account-scoped-acl.md](../TODO/account-scoped-acl.md)) has its own one-directional
Firebase-to-host reconcile, `reconcile_policy()`, separate from the peer/mesh sync above.
`reconcile_policy()` itself is one function, not a process, and has no systemd unit or CLI entry
point of its own - but at boot it runs as part of the `cloudgateway-sync-peers` CLI process (a
`Type=oneshot` systemd unit), not inside the long-running API process. It is called from:

* Boot, and any manual `sudo cloudgateway-sync-peers`, so a rebuilt or rebooted host repopulates
  its entire policy map from Firestore without needing any peer to poke it. This call runs inside
  the `cloudgateway-sync-peers` CLI process, right after that same run's peer/mesh pass completes -
  they are two separate reconciles inside one `oneshot` invocation, not two processes. A
  policy-only failure here (the peer/mesh pass having already succeeded) makes `sync.py`'s
  `main()` return `EXIT_POLICY_FAILED` (2), so `cloudgateway-sync-peers.service`
  (`Restart=on-failure`, `RestartSec=30`, `StartLimitIntervalSec=0`) retries the whole idempotent
  peer-plus-policy pass indefinitely - see [docs/service-operations.md](service-operations.md) for
  the operator-facing diagnosis story.
* `POST /api/admin/sync` (Sync All), which also reconciles peers and mesh and runs inside the
  long-running API process via `PolicyCoordinator` - see [docs/api-contract.md](api-contract.md).
* `POST /api/sync/refresh`, the poke any provisioned user's client create/delete triggers on every
  other region, also inside the long-running API process - see [docs/api-contract.md](api-contract.md).

All three call the identical `reconcile_policy()` and are serialized against each other by the
`/run/cloudgateway-policy.lock` flock described below - there is no separate code path for boot vs.
request-triggered policy reconcile, only a different calling process.

A pass pulls the fleet-wide client/account snapshot from Firestore, applies it to
`cg_infra4/6`, `cg_admin4/6`, `cg_slot4/6`, and `cg_pairs4/6` atomically as a single `nft -f -`
load (never incrementally), then reads back every authorization-bearing live object for both
address families - `cg_tunnel4/6`, `cg_infra4/6`, `cg_admin4/6`, `cg_slot4/6`, and `cg_pairs4/6` -
canonicalizes and hashes each family into one comprehensive `mapHashV4`/`mapHashV6`, and writes a
best-effort `Policy/{regionId}` status doc. Status is read back from the live map, not the pulled
snapshot, so it describes what is actually on the wire, not what the region intended to apply - the
same rule `write_mesh_status` follows for `Mesh/{regionId}`. A status write failure never fails a
pass (the apply already happened and is not worth discarding over a status write). The reverse
case matters more: if the Firestore pull, the `nft -f -` apply, or the read-back itself raises,
that raise happens before `write_policy_status` is ever called, so nothing is written at all - the
previous successful `Policy/{regionId}` document is left exactly as it was, and no failure status
is ever recorded there. A failed pass is visible only in host logs (`policy_refresh_failed`) and,
for Sync All, in that call's response (`policyApplied: false` - see
[docs/api-contract.md](api-contract.md)). Operationally this means a stale-but-valid `Policy` doc
and a healthy-looking Server Health card can coexist with a region that is actively failing to
apply; the signal is comprehensive hashes disagreeing across enabled regions, or an `updatedAt`
that stops advancing while the rest of the fleet keeps changing - host logs are authoritative. The
status doc is intentionally opaque: `regionId`, `mapHashV4`/`mapHashV6`, `rowCount` (the
`cg_slot4` row count), and `updatedAt` (a server timestamp for the last successful apply/read-back,
shown in Server Health as "Last applied") - never a uid, email, address, or key. Because roles are
re-read from `UserRoles` and applied to `cg_admin4/6` on every pass, an admin allow-set change is
visible in the comprehensive hash as soon as the next reconcile runs; there is no role-mutation
API, UI, timer, or automatic propagation, so a trusted operator who edits `UserRoles` out of band
must run Sync All Regions immediately, and the fleet keeps enforcing the previous allow-set until
they do.

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

**Account deletion against an unreachable region** converges the same way as any other missed
peer sync, not through a special repair path. `DELETE /account` marks every one of the account's
client documents non-active fleet-wide - including a region whose host could not be reached to
remove its live peer or accept a cleanup-mode client delete - before the account documents are
hard-deleted. That region's client docs are therefore already `removed` by the time it next runs a
sync: its next boot, or a manual `cloudgateway-sync-peers`, removes the orphaned peer exactly like
the "client-classified peer Firebase does not know"/"doc is removed but a matching peer exists"
rows in the drift table above, and its policy reconcile drops the stale `cg_slot4/6`/`cg_pairs4/6`
rows on the same pass, since both reconciles read the same non-active Firestore state. There is no
separate repair path and no retry loop for this case; it is the accepted risk recorded in
[TODO/account-scoped-acl.md](../TODO/account-scoped-acl.md).

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
