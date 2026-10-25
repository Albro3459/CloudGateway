# WireGuard Peer Drift Repair

Firestore is the source of truth for desired client peers, mesh membership, and
policy. Runtime peers and mesh routes are disposable state. Keep
`/etc/wireguard/wg0.conf` interface-only and never save peers to a host state file.

Repair a regional host through the configured systemd unit:

```sh
sudo systemctl start cloudgateway-sync-peers.service
sudo systemctl status cloudgateway-sync-peers.service
sudo journalctl -u cloudgateway-sync-peers.service --since "1 hour ago"
```

Systemd supplies `/etc/cloudgateway/api.env` and the venv executable. The unit
runs at boot and retries failures every 30 seconds indefinitely. Successful
passes have no timer. **Sync All Regions** in Server Health runs peer/mesh and
policy repair through the API across enabled regions.

## What the Sync Does

A pass reads Firestore and reconciles the live `wg0` peer set:

| State | Result |
| --- | --- |
| An enabled region has a valid `active` client missing from the host | Add its peer |
| The client's live AllowedIPs differ from Firestore | Restore its recorded IPv4/IPv6 AllowedIPs |
| A live peer has no desired active client or mesh entry | Remove it, including removed/failed/creating clients and unknown peers |
| An active client has a valid public key but malformed/missing tunnel IPs | Skip applying it and protect its existing live peer from removal |
| An active client has an invalid public key | Skip it, without protecting any live peer |
| The local region is missing or disabled | Use an empty desired client and mesh set, removing live peers |
| The local and sibling regions are enabled and `meshEnabled`, with valid non-overlapping metadata | Reapply the mesh peer, resolving its endpoint each pass |
| A mesh candidate has missing/invalid metadata, duplicate server keys, or overlapping subnets | Skip it as `skipped-incomplete` or `skipped-overlap` and remove obsolete state |
| Local `meshEnabled` is false | Remove previously applied mesh peers and routes |

Malformed active clients count toward `clientPeersDegraded` in the admin response
and produce the count-only `client_peer_degraded` event. A successful sync with a
nonzero count needs record repair. It does not prove every active client was
applied. The sync never adopts unknown host peers into Firestore.

The WireGuard flock at `/run/cloudgateway-wireguard.lock` covers Firestore reads,
mutations, and mesh status publication. CLI runs wait for it. Admin sync takes it
non-blocking and returns `409 SYNC_IN_PROGRESS` if busy. Commands and endpoint
lookups are time-bounded. A single resolver worker with a non-queueing gate
prevents stuck lookups from accumulating threads. Unresolved endpoints force a
reapply attempt, and unexpected resolver errors log only the exception type.

## Mesh Route Reconciliation

Runtime `wg set` does not install routes, so every pass separately sweeps routes
on `dev wg0`:

* Manage only ranges inside `10.0.0.0/16` and `fd42:42:42::/48`.
* Preserve the local on-link network and all `proto kernel` routes.
* Replace desired mesh routes and remove other in-scope routes. A removed route
  absent from all region documents logs `mesh_route_reclaimed`, which can signal
  deleted or rewritten region metadata.
* Keep a route after a failed mesh reapply only if the peer was already live
  with exactly its desired AllowedIPs. A peer that never applied, or whose
  ranges differ, receives no route.

The upstream candidate builder rejects conflicting subnets and duplicate keys.
The lower-level mesh validator also rejects an unsafe candidate set before any
mesh apply, while allowing client removal and the remaining reconciliation to run.

## Partial Failures

Client applies, unknown-peer removals, mesh applies, and route commands run
independently. Client removal runs before mesh application, so broken endpoint
DNS cannot prevent revocation. A mutation failure does not stop the remaining
phases. The first error is raised after reconciliation and failed mutations are
never counted as changes.

A partially failed pass logs `peer_sync_partial` with completed changes and
`clientApplyFailed`, `peerRemovalFailed`, `meshApplyFailed`, and
`routeReconciliationFailed`. Individual failure events are
`client_peer_apply_failed`, `peer_removal_failed`, `mesh_peer_apply_failed`, and
`mesh_route_reconcile_failed`. Client failures log counts and interface only.

There is no rollback. Retry the idempotent pass after fixing the cause. Peer/mesh
failure exits the CLI with `1` and skips policy. If peers succeed and policy
fails, it exits `2`. The systemd unit retries either failure. See
[service operations](service-operations.md#cloudgateway-sync-peersservice-firebase-peer-sync).

## The One Firebase Write

Peer sync writes a best-effort full replacement of `Mesh/{regionId}` while holding
the WireGuard lock. It contains server metadata and reconciliation results,
without per-user data or handshake timestamps. Incomplete entries can omit
malformed fields and include a `reasonCode`.

`mesh_status_write_failed` leaves live peer/route changes in place and does not
fail the sync. Admin sync reports `meshStatusWritten: false`. The existing
snapshot can therefore lag live state. An applied snapshot proves reconciliation,
not a live handshake. Use `wg show wg0` for current link state.

## Account-Scoped ACL Policy Reconcile

`reconcile_policy()` in `Backend/API/src/policy_sync.py` runs separately from
peer/mesh reconciliation. It populates the nftables base ruleset installed by
bootstrap's `PostUp`. See [ACL design](access-control-list.md).

The same function runs from:

* The boot/manual CLI, after a successful peer/mesh pass.
* `POST /api/admin/sync`, through the API's `PolicyCoordinator`.
* `POST /api/sync/refresh`, which queues a policy-only refresh. Provisioned-user
  client create/delete flows poke other regions through this endpoint.

All callers take `/run/cloudgateway-policy.lock` before pulling the fleet snapshot
and hold it through atomic `nft -f -` apply, live read-back, and status write.
This orders writers across processes so an older pulled snapshot cannot overwrite
a newer map. It is independent of the WireGuard lock. API refresh requests
coalesce to at most one pending follow-up pass.

Client creation's inline local policy row runs after its WireGuard critical
section and takes the policy flock non-blocking. If busy, it logs
`policy_row_lock_busy` and relies on the queued reconcile. Policy failure does
not turn a successful client create into an API error.

After apply, the pass reads all authorization-bearing live objects in both
families: `cg_tunnel4/6`, `cg_infra4/6`, `cg_admin4/6`, `cg_slot4/6`, and
`cg_pairs4/6`. It hashes them into `mapHashV4`/`mapHashV6` and writes
`Policy/{regionId}` with those hashes, `rowCount` (IPv4 slot rows), and a server
`updatedAt` timestamp. No UID, email, tunnel address, or key appears in the status.

A status-write failure logs `policy_status_write_failed`, leaves applied policy
in place, and does not fail the pass. Admin sync reports
`policyStatusWritten: false`. A pull, apply, or read-back failure logs
`policy_refresh_failed`, leaves the prior successful status document untouched,
and reports `policyApplied: false` on admin sync. Thus a valid-looking old status
can coexist with a current failure. Hash disagreement across enabled regions is
drift, while timestamp age alone is not. Read host logs and sync results to
diagnose failures.

`UserRoles` is read on every full policy pass. After an out-of-band role change,
run **Sync All Regions** immediately. There is no automatic role-change
propagation or timer, and the previous admin allow-set remains until reconcile.

Account deletion marks its clients non-active fleet-wide before hard-deleting
account documents. An unreachable host keeps its old peer/policy until a later
boot or manual sync removes them. During that gap, the old config can still use
that region's egress and reach the deleted account's own stale clients. Run sync
when the host returns. See [service operations](service-operations.md#account-scoped-acl-client-to-client-isolation)
for account-slot recovery and the accepted stale-host risk.

Live nftables verdict/priority verification is recorded in
[ACL live verification](acl-live-verification.md). Repeat it when the ruleset,
kernel/nftables version, or fleet shape changes.

## Diagnosing Before/After

```sh
sudo wg show wg0
sudo wg show wg0 latest-handshakes
sudo ip -4 route show dev wg0
sudo ip -6 route show dev wg0
sudo systemctl status cloudgateway-sync-peers.service
sudo journalctl -u cloudgateway-sync-peers.service --since "1 hour ago"
```

Compare live peers with `Regions/{regionId}/Instances/{clientId}` using trusted
Admin SDK access. Check `status`, `ownerUid`, `clientPublicKey`, and assigned tunnel
addresses. If the document is active and the peer is present after sync, check
endpoint DNS, handshakes, forwarding, AdGuard Home, and Unbound per
[service operations](service-operations.md).

## Stale Reservations

A `creating` client reserves an IP and capacity until promoted or rolled back.
An API crash during create can leave it indefinitely. Peer sync ignores it and
there is no automatic reaper. If allocated capacity exceeds active clients,
inspect old `creating` records. After confirming no request is still in flight,
delete the stale reservation or mark it `removed` through trusted admin access,
then sync to remove any leftover live peer.

Never paste private keys, full configs, Firebase credentials, or tokens into
logs or tickets. Keep live peer/policy inspection private and refer to client IDs
or public keys when reporting drift.
