# Account-Scoped ACL: Client-to-Client Isolation

Goal: a client may reach another client over the tunnel only when both are owned by the same CloudGateway account. Enforcement is a stateless nftables filter on every regional host, driven by an address-to-account map each host pulls from Firestore. Addressing, subnets, and the mesh design are unchanged.

## Problem

Client-to-client traffic is currently unrestricted fleet-wide. Server-side `AllowedIPs` is exactly the client's `/32` and `/128` (`Backend/API/src/wireguard.py:319`), and forwarding is a blanket accept (`Infrastructure/OCI/host/bootstrap.sh:161`). Since the shared subnet mesh landed, mesh peers carry subnet-width `AllowedIPs` plus routes for the remote `/24` and `/64`, so any client can reach any other client's tunnel IP in any region. Nothing about the account boundary is expressed on the wire.

`AllowedIPs` cannot fix this. It is cryptokey routing: it pins the source address a peer may use and does not constrain destinations. Client-side `AllowedIPs` is not enforcement at all, since the client owns its own config and CloudGateway configs are full-tunnel. The boundary has to be a packet filter on the servers.

Because `AllowedIPs` already pins source addresses, a filter keyed on source address is trustworthy: a client cannot present another client's tunnel IP.

## Architectural decisions

* **The boundary is the account (`ownerUid`), not a group.** No group, team, or family concept is introduced. If sharing across accounts is ever wanted, it is a separate feature and the map design accommodates it; nothing here should hard-code the assumption that an account is the only possible unit.
* **Accounts are identified on hosts by an opaque slot, never by uid.** A monotonically allocated 32-bit integer stored on `Users/{uid}`, never reused. Hosts hold `address -> slot` and nothing else: no uid, no email, no client name. A compromised host learns which addresses are equivalent, not who owns them. Slots are allocated, not hashed from the uid, so two accounts can never collide into one tenant.
* **Admins are ordinary tenants on the wire.** Admin powers are the dashboard and the API. An admin has no network reach into another account's devices. The one exception is infrastructure reach, below.
* **Servers may reach admin-owned clients, in both directions.** An admin can SSH into a regional host and connect onward to their own devices inside the tunnel, including cross-region, and those devices can reach the hosts. This is scoped to admin-owned clients rather than granted blanket, because admins have SSH on the hosts: a blanket infra exemption would let any admin reach every customer device with one extra hop, which is exactly the property this feature exists to remove.
* **Maps are identical fleet-wide.** Every host holds every client's row. Scoping each region to accounts with a local client is a valid optimization and is explicitly rejected: at `region_capacity_limit` of 20 the whole fleet map is a few dozen rows, and identical maps are what make the cross-region status hash comparable.
* **Propagation is event-driven only. No timer, no version document.** A client create or delete pokes the other regions; each poked region pulls a full snapshot from Firestore. Boot and admin Sync All also pull. A dropped poke leaves a region stale until the next fleet-wide client event or an admin sync, and that is accepted.
* **Addresses are allocated by incrementing, not first-unused.** This replaces a time-based reuse TTL with a distance-based one and needs no `releasedAt` bookkeeping.
* **Firestore stays the source of truth.** The refresh pulls desired state; it never writes desired state back. Status writes are best effort and never make a pass fail, matching the existing rule for `Mesh/{regionId}`.

## Threat model

In scope: one account's client reaching another account's client over the tunnel, in the same region or across the mesh.

Out of scope and unchanged: client to internet egress, client to its own region's server (DNS, API), server to its own local clients, mesh server-to-server links, and any traffic that never traverses `wg0` on both sides. A client that has been removed as a WireGuard peer cannot put packets on the tunnel at all; the ACL is a second boundary behind cryptokey routing, not a replacement for peer removal.

## Filter design

One `inet` table named `cloudgateway`, replacing nothing in the existing `iptables`/`ip6tables` rules. A `drop` verdict is terminal across tables, so the existing `FORWARD` accepts do not need reordering or renumbering; the new base chain is installed at a priority ahead of the filter hook so it evaluates first. Verify verdict and priority behaviour on the host before relying on it.

Chain shape, `hook forward`, policy accept:

1. `ct state established,related accept` — return traffic for any flow already permitted. Without this the infra rules are one-way and SSH hangs on connect.
2. `iifname wg0 oifname wg0 ip saddr @cg_infra ip daddr @cg_admin accept` — server to admin-owned client.
3. `iifname wg0 oifname wg0 ip saddr @cg_admin ip daddr @cg_infra accept` — admin-owned client to server, cross-region.
4. `meta mark set ip saddr map @cg_slot` — mark carries the source's account slot; an unknown source leaves the mark cleared.
5. `iifname wg0 oifname wg0 ip daddr @cg_tunnel ip daddr . meta mark != @cg_pairs drop` — drop unless the destination address is paired with the source's slot.

Everything else falls off the end and is accepted: egress to the internet, and any traffic not both entering and leaving `wg0`.

Objects, mirrored for IPv4 and IPv6:

* `cg_tunnel` — the region tunnel networks. Static, from the same allocation the mesh already uses.
* `cg_infra` — every region's interface address (`10.0.x.1`, `fd42:42:42:x::1`). Static.
* `cg_slot` — map from client address to account slot.
* `cg_pairs` — set of `address . mark` concatenations, one element per client. A single lookup and O(n) elements; a set of allowed source-destination pairs would be O(n squared) and is rejected.
* `cg_admin` — client addresses whose slot is admin-owned.

Notes and things to confirm during implementation:

* Exact nft syntax for the mark comparison must be validated on the host. The concatenated-set formulation is chosen over comparing two map lookups because it is unambiguously supported.
* The chain assumes no other subsystem uses the packet mark and that no `ip rule fwmark` exists. If that changes, switch to a masked mark.
* An empty map means no client-to-client traffic. That is the correct boot state: the rules are installed by `PostUp` and populated by the first pull, so the failure mode of an unreachable Firestore is "peer-to-peer is down", never "VPN is down".
* A non-admin client reaching another region's server interface address is dropped by rule 5, since infra addresses are inside `cg_tunnel` and are not in `cg_pairs`. This is intentional. Local server access is unaffected because it is `INPUT`, not `FORWARD` (see the existing DNS rules at `Infrastructure/OCI/host/bootstrap.sh:167`).

## Firestore model

```text
Users/{uid}
  accountSlot          number, allocated once, never reused

Policy/{regionId}
  mapHashV4            hash of the live map read back from nftables
  mapHashV6
  rowCount
  dataVintage          max updatedAt across the applied snapshot
  appliedSequence
  updatedAt
```

`Policy/{regionId}` is observability only, read by admins, written by each region's host via the Admin SDK, mirroring the existing `Mesh/{regionId}` rules block (`Backend/Firebase/firestore.rules:52`). Status must describe what is actually on the wire, read back from the live map, not what the region intended to apply; a status derived from the pulled snapshot would always look healthy and would report nothing.

`dataVintage` is the freshness signal and survives any future change that makes maps legitimately differ between regions. The hashes are the integrity signal and are comparable only while maps are identical fleet-wide.

A slot counter document is required for allocation. Allocation happens once per account, in a transaction, at user provisioning.

The fleet-wide pull is an unfiltered `collection_group("Instances")` read with status filtering done in the API, which needs no new composite index. Admin slots come from a `UserRoles` read joined in the API.

## Address allocation

`_first_unused_tunnel_ip` (`Backend/API/src/repository.py:174`) hands out the lowest free address, so a freed address can be reissued immediately. Replace it with a per-region monotonic index stored on the Region document and advanced in the same transaction as `reserve_client`:

* Take the next index, wrap at the top of the host range, and skip any address currently in use.
* The region is exactly a `/24`, so the wrap is a real event after 254 lifetime allocations, not a theoretical one. The in-use check on wrap is load-bearing and must not be treated as dead code.
* IPv6 is a `/64` and never wraps. Keep the v4 and v6 indices paired so a client's two addresses share an index; the wrap logic is v4-only.
* No `releasedAt` field and no time-based TTL. With `region_capacity_limit` at 20, incrementing gives roughly 230 allocations of distance before an address returns, and every one of those allocations is itself a poke that would have corrected a stale row.

## Refresh model

One `reconcile_policy()` pass: pull the fleet snapshot, build the map, apply it atomically, read it back, write status. Callers:

* Boot. A rebuilt or rebooted host repopulates its entire map from Firestore without needing any peer to poke it.
* `POST /api/admin/sync`, so Sync All is the repair path for a dropped poke.
* `POST /api/sync/refresh`, the poke endpoint.

Concurrency:

* Its own lock, separate from `wireguard.lock()`. A policy refresh must never contend with `add_peer` on the client create path (`Backend/API/src/routes.py:178`) or make an admin's non-blocking Sync All shed with `SyncInProgressError`. Traffic in one region must not slow client creation in another.
* Depth-1 coalescing. Any number of pokes arriving during a running pull set a flag; when the pull finishes and the flag is set, clear it and pull once more. One follow-up is sufficient because the pull is a full snapshot rather than a delta, so a pull starting after the last poke already sees everything every pending poke announced. Do not convert this into a real queue.
* A sequence guard as a backstop: stamp each pull at start and refuse to apply a snapshot whose stamp is below the last applied. Cancellation is not available in this runtime, so a slow in-flight pull must be discarded rather than stopped, or it will overwrite newer state with older state and produce a wrong map rather than a stale one.

The poke reconciles the policy map only. A region's peer set is its own local active clients plus mesh regions and cannot be changed by another region's client, so a full sync on the poke path would reconcile peers that provably did not change, re-resolve mesh endpoint hostnames, and reapply routes, any of which can hang.

## API surface

`POST /api/sync/refresh`

* Any provisioned user, via `require_provisioned_user`. Not admin-only.
* No body, no detail in the response, no information about region health, counts, or errors.
* Policy map only. Enqueues and returns immediately, so the caller's timeout never matters and each request costs approximately nothing.
* No dedicated secret and no rate limit. The caller's own Firebase token is replayed, matching the existing cross-region pattern in `_delete_remote_client` (`Backend/API/src/routes.py:722`), and depth-1 coalescing structurally bounds the work a caller can cause.

`POST /api/admin/sync` is unchanged: admin only, full pass, detailed response, used by Server Health's Sync All. `meshEnabled` toggling and detailed logs stay admin.

Poke sites, fire-and-forget after the response via `BackgroundTasks`, with a short per-region timeout and never affecting the request result:

* `POST /clients` after the client document commits. The local map row is written inline in the existing locked block, so a client whose sibling is in the same region works immediately with no cross-region dependency.
* `DELETE /clients/{clientId}`.

## Account deletion

`DELETE /account` does not poke, deliberately. There is no ordering that works: poking before `hard_delete_account_documents` refreshes peers to the pre-delete state, and poking after it means `UserRoles/{uid}` is gone, so the remote rejects the call and `require_role_or_disable_unprovisioned` (`Backend/API/src/auth.py:51`) attempts to disable a user that is being deleted.

This is accepted, and it must carry a comment at the delete site explaining why, or someone will add the poke later and reintroduce the disable behaviour. The reasoning:

* `_remove_account_peers` removes the WireGuard peers before the documents are deleted, so the deleted account cannot put a packet on the tunnel at all. Stale rows point at addresses nobody can source traffic from.
* A leak requires someone else to hold that address, which requires an allocation, which fires a poke, which triggers a full pull that deletes the stale row. It needs both the reallocation and that poke to be lost, after roughly 230 intervening allocations that each would have fixed it.
* If a region was unreachable during the deletion, `Backend/API/src/routes.py:704` already lets the deletion proceed and leaves the peer orphaned until `cloudgateway-sync-peers` reconciles. In that window the stale row grants reach only to the user's own former devices. This is an already-accepted risk for peers and the ACL adds nothing to it.

Disabling an unprovisioned user from a poked request is correct everywhere else and needs no special handling. Roles are global in Firestore, so a token cannot be provisioned in one region and not another; the only divergence is time, and account deletion is the only case that produces it.

## Dashboard requirements

Server Health shows, per region: policy row count, data vintage, and map hashes. A region whose vintage lags or whose hash differs from its peers is displayed as drifted, without requiring anyone to run a sync first. A missing or unreadable `Policy/{regionId}` renders an explicit failure card and must never crash.

Drift is not a failure of the sync pass. Status writes remain best effort and a status write failure never makes a pass fail.

## Host and deploy requirements

* Install `nftables` in `bootstrap.sh`.
* Create the table, sets, maps, and chain in `PostUp`; tear down in `PostDown`. Rules are installed empty, before any pull.
* Static objects (`cg_tunnel`, `cg_infra`) come from the same allocation source the mesh already uses. Adding a region adds its interface address to `cg_infra` fleet-wide.
* Map contents are applied atomically as a single `nft -f -` load, never incrementally.
* Firestore rules gain a `Policy/{regionId}` block mirroring `Mesh/{regionId}`: admin read, Admin SDK write.
* No Terraform subnet, tfvars, registry, MTU, or OCI ingress change. No client configuration change. No Apple or Web client change beyond the Server Health display.

## Accepted risks and out of scope

* A dropped poke leaves a region stale until the next fleet-wide client event or an admin Sync All. No timer, no retry, no durable queue.
* Account deletion does not propagate immediately, as above.
* Any regional host can reach admin-owned clients fleet-wide. Locally this is already true via `OUTPUT`; this extends it across the mesh, knowingly, to support admin proxy jumps.
* Per-region map scoping, group or family sharing, and a periodic reconcile timer are out of scope. The version-document poll considered during design is rejected as unnecessary given event-driven propagation.

## Checklist

* [x] Account slot allocation: counter document, `Users/{uid}.accountSlot`, allocated at provisioning, never reused.
* [x] Monotonic address allocation with wrap and in-use check, replacing `_first_unused_tunnel_ip`; paired v4/v6 indices.
* [x] nftables table, sets, maps, and chain in `bootstrap.sh` `PostUp`/`PostDown`; `nftables` package installed.
* [x] `reconcile_policy()`: fleet-wide pull, atomic apply, read-back, status write.
* [x] Dedicated lock, depth-1 coalescing, and sequence guard.
* [x] Boot and `POST /api/admin/sync` call the policy reconcile.
* [x] `POST /api/sync/refresh`: provisioned user, no body, no detail, enqueue-and-return.
* [x] Fire-and-forget pokes from `POST /clients` and `DELETE /clients/{clientId}`; inline local map row on create.
* [x] Comment at `DELETE /account` explaining why it deliberately does not poke.
* [x] `Policy/{regionId}` schema, Firestore rules, and `schema.ts`.
* [x] Server Health policy status display and failure card.
* [ ] Verify nft verdict precedence, chain priority, and the mark comparison syntax on a real host.
* [ ] Verify the four reachability cases end to end: same-account same-region, same-account cross-region, cross-account denied both directions, admin proxy jump in both directions cross-region.
* [x] `./scripts/test.sh api infra firebase web` and documentation updates.

The two unchecked items need a running regional host and cannot be closed from a
workstation. Everything the filter depends on is exercised offline instead: the
rendered nft script text is asserted byte-for-byte in `tests/test_policy.py`
against the object names `bootstrap.sh` installs, so a rename on either side
fails the build. What stays unproven until a host runs it is nftables' own
behaviour - that `priority -10` really evaluates ahead of the existing iptables
`FORWARD` accepts, that a `drop` verdict is terminal across tables, and that the
`ip daddr . meta mark != @cg_pairs` concatenation parses and matches as intended.
Confirm those before relying on the boundary.
