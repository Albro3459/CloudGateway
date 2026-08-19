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
  regionId
  mapHashV4            hash of the complete live IPv4 policy read back from nftables
  mapHashV6
  rowCount
  updatedAt             server timestamp of the last successful apply/read-back
```

`Policy/{regionId}` is observability only, read by admins, written by each region's host via the Admin SDK, mirroring the existing `Mesh/{regionId}` rules block (`Backend/Firebase/firestore.rules:52`). Status must describe what is actually on the wire, read back from the live map, not what the region intended to apply; a status derived from the pulled snapshot would always look healthy and would report nothing.

The hashes cover every nftables object that affects the IPv4 or IPv6 decision,
not only the address-to-slot maps. Server Health compares enabled regions for
hash agreement and displays `updatedAt` as "Last applied"; age by itself is not
drift. A missing, malformed, or unreadable status is an explicit failure.

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
* Depth-1 coalescing. Any number of pokes arriving during a running pull set a pending bit; when the pull finishes and the bit is set, clear it and pull once more. Requests coalesce while the bit is already set. A request arriving after the follow-up starts may set it again because that request may announce a newer Firestore mutation. Do not convert this into a real queue.
* The shared policy flock covers `pull -> apply -> read-back -> status` for both the API process and the boot/manual sync process. Pulling inside the lock makes cross-process application order match snapshot order; a process-local sequence number cannot provide that guarantee.

The poke reconciles the policy map only. A region's peer set is its own local active clients plus mesh regions and cannot be changed by another region's client, so a full sync on the poke path would reconcile peers that provably did not change, re-resolve mesh endpoint hostnames, and reapply routes, any of which can hang.

## API surface

`POST /api/sync/refresh`

* Any provisioned user, via `require_provisioned_user`. Not admin-only.
* No body, no detail in the response, no information about region health, counts, or errors.
* Policy map only. Enqueues and returns immediately, so the caller does not wait for reconciliation.
* No dedicated secret and no rate limit. The caller's own Firebase token is replayed, matching the existing cross-region pattern in `_delete_remote_client` (`Backend/API/src/routes.py:722`). Depth-1 coalescing bounds the pending backlog to one follow-up, not the total number of sequential refreshes a caller can trigger.

`POST /api/admin/sync` is unchanged: admin only, full pass, detailed response, used by Server Health's Sync All. `meshEnabled` toggling and detailed logs stay admin.

Poke sites, fire-and-forget after the response via `BackgroundTasks`, with a short per-region timeout and never affecting the request result:

* `POST /clients` after the client document commits. The best-effort local map row is written after releasing the WireGuard lock, using only the separate non-blocking policy flock, so a client whose sibling is in the same region can work immediately without making successful creation depend on the policy fast path.
* `DELETE /clients/{clientId}`.

## Account deletion

`DELETE /account` uses a dedicated cleanup sequence. It first removes the
account's peers, then marks every client non-active in Firestore so every later
policy snapshot excludes the account. While `UserRoles/{uid}` and the caller's
recent authentication still exist, it sends exactly one best-effort policy
refresh wave to the other enabled regions and queues the local reconcile. Only
then does it hard-delete the account documents and Auth user.

Remote per-client cleanup suppresses its ordinary reconcile and fleet poke so
account deletion cannot create an accidental fan-out. If a region is
unreachable, deletion may proceed after recording that failure; its orphaned
peer and stale policy row converge on the next boot/manual sync. The central
non-active fence prevents any new pull from restoring the deleting account.

## Dashboard requirements

Server Health shows each enabled region's policy row count, comprehensive IPv4
and IPv6 policy hashes, and `updatedAt` as "Last applied." Hash disagreement is
drift; timestamp age alone is not. Disabled regions do not participate in the
comparison. A missing, malformed, or unreadable `Policy/{regionId}` renders an
explicit failure card and must never crash or hide the independent Mesh status.

Drift is not a failure of the sync pass. Status writes remain best effort and a status write failure never makes a pass fail.

## Host and deploy requirements

* Install `nftables` in `bootstrap.sh`.
* Create the table, sets, maps, and chain in `PostUp`; tear down in `PostDown`. Rules are installed empty, before any pull.
* Static objects (`cg_tunnel`, `cg_infra`) come from the same allocation source the mesh already uses. Adding a region adds its interface address to `cg_infra` fleet-wide.
* Map contents are applied atomically as a single `nft -f -` load, never incrementally.
* Firestore rules gain a `Policy/{regionId}` block mirroring `Mesh/{regionId}`: admin read, Admin SDK write.
* No Terraform subnet, tfvars, registry, MTU, or OCI ingress change. No VPN client configuration change. Web and iOS Server Health must both expose the final policy status before release.

## Accepted risks and out of scope

* A dropped poke leaves a region stale until the next fleet-wide client event or an admin Sync All. No timer, no retry, no durable queue.
* Account deletion sends one deliberate best-effort refresh wave. An unreachable region can retain an orphaned peer and stale policy until its next boot/manual sync.
* Any regional host can reach admin-owned clients fleet-wide. Locally this is already true via `OUTPUT`; this extends it across the mesh, knowingly, to support admin proxy jumps.
* Per-region map scoping, group or family sharing, and a periodic reconcile timer are out of scope. The version-document poll considered during design is rejected as unnecessary given event-driven propagation.

## PR blocker remediation plan

The static review in [account-scoped-acl-review.md](account-scoped-acl-review.md)
found release blockers in slot migration/integrity, cross-process policy ordering,
the create fast path, account deletion, malformed-row handling, policy status,
and documentation. All work in this section must land before this branch is
released unless an item explicitly says it is deferred.

### Decisions after review

* **Existing-host nft migration is not required.** This release will deploy
  every region through `./scripts/terraform.sh`, which destroys and rebuilds
  each host from the same deploy tag. Bootstrap installs nftables, writes the
  base ruleset, and loads it through WireGuard `PostUp`. Do not deploy this
  branch with `cloudgateway-install-api` or mix an API-only upgrade into the
  rollout.
* **The current depth-1 coordinator model stays.** There may be one running
  pass and one pending pass. Repeated requests while the pending bit is already
  set coalesce. A request arriving after the follow-up starts may set the bit
  again because its Firestore mutation may be newer than that follow-up's
  snapshot; dropping it would lose the event. Documentation must say this
  bounds pending backlog, not the total work a caller can request over time.
* **New accounts already receive slots.** `_provision_user_documents()` assigns
  `Users/{uid}.accountSlot`, and `reserve_client()` has a lazy fallback. The
  migration below is for legacy provisioned accounts and for establishing the
  allocator counter before the stricter runtime invariant takes effect.
* **Role mutation is not a product feature in this PR.** No role-change API,
  UI, timer, or automatic role propagation is added. A trusted operator who
  changes `UserRoles/{uid}` must run Sync All immediately. Reconcile must still
  read current roles, apply `cg_admin4/6`, and include those sets in live
  read-back and status hashes so partial fleet application is visible.
* **Policy health is hash agreement plus last-applied time.** Remove
  `dataVintage` staleness and the process-local `appliedSequence` from the
  status contract. Compare comprehensive live-policy hashes across enabled
  regions and display `Policy.updatedAt` as the last successful apply. Equal
  comprehensive hashes mean the enforced state agrees even when regions last
  reconciled at different times.
* **iOS parity is deferred to its own implementation plan, but not to a later
  release.** The current iOS Server Health surface has no `Policy/*` model,
  mapper, repository method, view-model state, or UI. That work remains an
  explicit blocker before this ACL release can ship.

### Wave 1 - legacy slot migration and allocator integrity

Create a release-scoped migration package:

```text
releases/access-control-lists/
  backfill_account_slots.py
  README.md
```

The script uses the Firebase Admin SDK with either
`--credentials <service-account-json>` or `GOOGLE_APPLICATION_CREDENTIALS`;
the service-account file remains outside git. It is dry-run by default and
requires an explicit `--apply` flag. It must:

* Read the live `Users` and `UserRoles` collections and target every
  provisioned account, including accounts with no active client.
* Preserve valid existing slots, reject duplicate/out-of-range/malformed
  slots, assign missing slots deterministically, and never print a uid, email,
  client address, key, token, or configuration.
* Create or advance `Counters/accountSlots.nextSlot` above the maximum assigned
  slot in the same transaction as the writes. Re-running it is a no-op.
* Abort if live counts or invariants change during the transaction; never
  partially assign a second slot range.
* Report only aggregate counts: provisioned, already assigned, newly assigned,
  next slot, and validation failures.

The latest pre-ACL backup (`backup-20260817T004747Z.json`) scopes the current
migration at six provisioned accounts, one admin, nine active clients across
four owners, zero existing slots, and no counter document. Its active rows have
valid owners, `/32` and `/128` addresses, timestamps, and no duplicate
addresses. Take a new backup immediately before running the migration and
validate the live dry-run rather than treating these historical counts as an
apply precondition.

After migration, runtime allocation must fail closed when the counter is
missing, malformed, exhausted, or not strictly above every assigned slot. It
must never reset to slot `1`. Add unit coverage for first migration, idempotent
rerun, partial prior assignment, counter corruption, duplicate slots, overflow,
and concurrent transaction retry.

### Wave 2 - policy input normalization and collision handling

Normalize every Firestore value before it can become a `PolicyRow`:

* `ownerUid` is a nonempty string with a valid, unique account slot in
  `1...2^32-1`.
* Client addresses are strings with exact `/32` and `/128` host prefixes and
  are inside the expected tunnel aggregates.
* `updatedAt`, while it remains on the client model for other features, is a
  real timestamp or `None`; it no longer feeds policy status.
* A duplicate IPv4 address, IPv6 address, or account slot excludes every row
  participating in the collision. Collection order must never choose a winner.
* Each rejected row increments the aggregate skipped count without logging its
  uid, address, slot, name, email, key, or configuration. One malformed row
  must not abort or retain an unsafe fleet map.

Keep the migration's live preflight equally strict so known-bad data blocks the
release before hosts enforce it. Cover wrong types, host-prefix mismatches,
out-of-aggregate addresses, duplicate participants in different collection
orders, invalid slots, and mixed valid/invalid snapshots.

**Landed.** `backfill_account_slots.py`'s fleet-wide policy-row preflight (mirroring the same
owner/slot/address/collision rules standalone) is the release gate for known-bad data: it blocks both dry-run and
`--apply` with exit code 1 when any row fails, before any region enforces the ACL. `updatedAt` no
longer feeds policy status - `DesiredPolicy.data_vintage` and `PolicyStatus.data_vintage` are gone
from the API. Between Wave 2 and Wave 5, `write_policy_status` kept writing
`Policy/{regionId}.dataVintage` as `null` so the documented Firestore shape stayed unchanged in the
interim, and Server Health rendered "No applied snapshot yet" with an "unknown" staleness signal for
every region; that interim state ended with Wave 5, which removes `dataVintage` from the schema
entirely and replaces it with comprehensive live-policy hash agreement (see
[docs/service-operations.md](../docs/service-operations.md)).

### Wave 3 - cross-process ordering and create-path isolation

**Landed.** The policy flock now covers the complete ordered operation:

```text
lock -> pull current Firestore snapshot -> apply -> read back -> write status -> unlock
```

Both `PolicyCoordinator` and the boot/manual `cloudgateway-sync-peers` process call the identical
`reconcile_policy()`, so a later writer can only pull after the prior writer has applied, read back,
and written status - an older snapshot can no longer wait outside the flock and overwrite a newer
map. The process-local sequence guard and the `appliedSequence` status field are gone as an
ordering signal; no process-local value is presented as a fleet ordering guarantee. Between Wave 3
and Wave 5, `write_policy_status` kept writing `Policy/{regionId}.appliedSequence` as a literal
`null`, the same interim pattern Wave 2 used for `dataVintage`, so the documented Firestore shape
stayed unchanged; that interim state ended with Wave 5, which removes both fields from schema,
parser, and UI.

`_write_inline_policy_row()` now runs after the WireGuard critical section closes, not inside it.
Slot lookup, role lookup, address normalization, policy-lock acquisition, and the row apply all sit
inside one best-effort exception boundary, so a policy error can never turn a client that is already
ACTIVE with a live peer into a 500 response. Lock acquisition is non-blocking: if a full pass already
owns it, the row is shed and logged (`policy_row_lock_busy`) rather than waited for, relying on the
create path's own already-queued reconcile. No Firestore read or nft call happens while the
WireGuard lock is held any more, so a slow policy pull or status write can no longer stall client
creation or make a non-blocking Sync All shed with `409 SYNC_IN_PROGRESS`.

The depth-1 pending-bit coordinator is unchanged by design: it bounds the *pending backlog* to one
queued follow-up pass, not the total work callers can trigger over time - not a queue, not a rate
limit, not a refresh-cadence feature. Concurrency coverage added: API-versus-boot serialization, an
inline row racing a full pass, a busy policy lock not failing create, and a poke arriving after the
follow-up pass has already started.

### Wave 4 - account deletion ordering

**Landed.** `DELETE /account` replaced the accidental per-client poke fan-out finding 8 identified
(the ordinary `DELETE /clients/{clientId}` path always scheduled its own local reconcile and fleet
poke, so remote per-client removal during account deletion raced the hard delete) with one
deliberate sequence: snapshot the account's clients; remove their local and remote WireGuard peers,
remote removal going through `DELETE /clients/{clientId}`'s new `accountCleanup` mode; mark every
one of the account's client documents non-active fleet-wide in one trusted repository operation
(the fence), including clients on a region whose host was unreachable during peer removal; send
exactly one best-effort policy refresh wave to every other enabled region while `UserRoles/{uid}`
and the caller's recent authentication still exist; queue the local reconcile separately; only then
hard-delete the account documents and Auth user. A failure before the fence still leaves clients
ACTIVE and retryable, exactly as before this wave.

`accountCleanup` is gated, not trusted from the flag alone: the receiving region re-checks
self-only (`userId == user.uid`), recent authentication, and the `user`-role restriction against
the replayed bearer token before honoring it, and a request that fails any of those checks fails
the whole delete instead of silently downgrading to an ordinary one. When accepted, it suppresses
that handler's own local reconcile and fleet poke, so account deletion issues exactly one
propagation wave fleet-wide - never the two-poke fan-out the pre-Wave-4 code produced.

There is no stored per-region client counter in Firestore to repair - capacity is derived, and the
only per-region counters, `Regions/{regionId}.tunnelIndexV4/V6`, are monotonic address allocator
indices that must never roll back and are untouched by account deletion. "Repair the per-region
counters" is satisfied by the fence operation's own authoritative read instead: it returns
per-region counts of account client documents seen and transitioned, grouped by each document's
region path rather than its `regionId` field so a document whose field disagrees with its path is
still counted and fenced correctly, and `deletedClientCount` in the `DELETE /account` response is
now that authoritative count rather than the pre-removal snapshot size - the two agree for a fleet
in a consistent state, so this is not an observable API change.

An unreachable region remains the existing accepted risk, not a fixed one: its orphaned peer and
stale policy row converge only at its next boot or a manual `cloudgateway-sync-peers` run, while its
Firestore client rows are already non-active for that whole window. The bounded consequence is that
a deleted account's existing configuration can still reach that one region until it syncs; it can
never reach another account, because slots are never reused, and every other region already refuses
it. Tests cover local-only, remote, mixed-region, unreachable-region,
partial failure/retry, a spoofed `accountCleanup` flag, no duplicate poke fan-out, and that every
policy snapshot pulled after the fence excludes the deleting account.

### Wave 5 - complete live hashes and Web status

Read back every object that affects authorization for both families:

* `cg_tunnel4/6`
* `cg_infra4/6`
* `cg_admin4/6`
* `cg_slot4/6`
* `cg_pairs4/6`

Canonicalize each object's elements and compute one composite live-policy hash
per address family. `mapHashV4`/`mapHashV6` become hashes of the complete family
policy, not only `cg_slot4/6`. Keep `rowCount` as the number of slot-map rows.
The status document becomes:

```text
Policy/{regionId}
  regionId
  mapHashV4
  mapHashV6
  rowCount
  updatedAt        server timestamp; last successful live apply/read-back
```

Remove `dataVintage` and `appliedSequence` from the API model, Firestore schema,
Web parser, UI, tests, and documentation. Server Health compares hashes only
among enabled regions, flags every comparable region when no strict majority
exists, and displays `updatedAt` as "Last applied" without treating age alone
as drift or staleness. Missing, malformed, and collection-read-failure states
remain explicit and must not take down Mesh cards.

Current roles are re-read on every pass. Add tests proving an operator role
change followed by Sync All changes `cg_admin4/6`, changes the comprehensive
hash, and converges every enabled region. Document Sync All as mandatory after
any trusted out-of-band `UserRoles` edit; do not add role mutation support.

**Landed.** `Policy/{regionId}` is now exactly `regionId`, `mapHashV4`, `mapHashV6`, `rowCount`,
`updatedAt` - `dataVintage` and `appliedSequence` are gone from `schema.ts`, its comments, the
Firestore rules test fixtures, and every doc that described them; the Wave 2/Wave 3 interim
null-placeholder state is over. `mapHashV4`/`mapHashV6` are one composite hash per address family
over every authorization-bearing live object read back from the host - `cg_tunnel4/6`,
`cg_infra4/6`, `cg_admin4/6`, `cg_slot4/6`, `cg_pairs4/6` - not only the slot map; `rowCount` stays
the `cg_slot4` row count. `updatedAt` is the last successful live apply/read-back and Server Health
shows it as "Last applied"; timestamp age alone is never drift or staleness, and the staleness
concept from the interim waves is gone entirely. Drift is comprehensive hash disagreement among
enabled regions only - disabled regions are excluded and can never be drifted - and a missing,
malformed, or unreadable `Policy/{regionId}` renders an explicit per-region failure state without
taking down the independent Mesh status. Because reconcile re-reads `UserRoles` and applies
`cg_admin4/6` on every pass, an admin allow-set change is visible in the comprehensive hash as soon
as the next reconcile runs; there is still no role-mutation API, UI, timer, or automatic
propagation - a trusted operator who edits `UserRoles` out of band must run Sync All Regions
immediately, and the fleet keeps enforcing the previous allow-set until they do.
`Backend/Firebase/README.md` and `docs/service-operations.md`/`docs/wireguard-drift-repair.md`
were updated to match. iOS Server Health Policy parity, the live-host verification items, and the
final full `./scripts/test.sh` gate remain open, tracked separately below.

### Wave 6 - boot retry, contracts, and documentation

* A policy-only failure in `cloudgateway-sync-peers` returns nonzero so systemd
  retries the idempotent peer-plus-policy pass. Admin Sync All can retain its
  current API response contract, but logs and status must distinguish its
  policy failure from peer success.
* Correct the failure contract: a failed apply is visible in logs and leaves
  the last successful `Policy/{regionId}` document unchanged; it does not write
  a new failure status.
* Document boot reconciliation as the separate sync CLI process, not part of
  the long-running API process.
* Add a real offline contract check between bootstrap and the policy layer for
  the table name, chain, object names, object types, tunnel aggregates, and both
  rule families. Do not claim a bootstrap rename fails the build until this
  check exists.
* Update API, Firebase, deployment, operations, drift-repair, and privacy/logging
  documentation for the final migration, account deletion, hash, role-sync,
  retry, and rollout behavior.

### Deferred Apple plan, still blocking release

Before release, write and implement a separate iOS Server Health parity plan.
At minimum it must add shared `CloudGatewayAppCore` Policy models and derivation,
a Firestore mapper, repository/facade fetch contract, the iOS Firestore adapter,
independent Policy load-failure state, post-Sync-All reload, client-isolation
status UI, tests, and screenshot fixtures. The Swift status semantics must match
the final Web semantics from Wave 5 rather than porting the superseded
`dataVintage` model.

### Validation and release order

1. Run targeted validation after each wave through `./scripts/test.sh`; update
   the test entry point so the release migration tests run under a named target.
2. Run the full `./scripts/test.sh` gate after the remediation and again after
   the deferred iOS parity work lands.
3. Create a fresh Firestore backup. Run the migration dry-run, review aggregate
   counts/invariants, run `--apply`, then rerun dry-run and require a no-op.
4. Deploy every region from one tag with `./scripts/terraform.sh <all regions>`.
   The sequential interval is a rollout window with partial fleet enforcement;
   do not treat the ACL as active until the last region finishes.
5. Run Sync All Regions and confirm every enabled region reports matching
   comprehensive IPv4/IPv6 hashes and a last-applied timestamp.
6. Complete the nftables host verification and the four end-to-end reachability
   cases before declaring the boundary active.

## Checklist

* [x] New-account slot allocation: counter document, `Users/{uid}.accountSlot`, allocated at provisioning or a later client reservation.
* [x] Wave 1 - legacy slot migration, counter seeding, fail-closed runtime allocation, and migration tests.
* [x] Monotonic address allocation with wrap and in-use check, replacing `_first_unused_tunnel_ip`; paired v4/v6 indices.
* [x] nftables table, sets, maps, and chain in `bootstrap.sh` `PostUp`/`PostDown`; `nftables` package installed for new or rebuilt hosts.
* [x] Deployment decision: rebuild every region through `terraform.sh`; no API-only or mixed host rollout.
* [x] `reconcile_policy()`: fleet-wide pull, atomic apply, read-back, status write.
* [x] Dedicated policy flock, separate from the WireGuard flock.
* [x] Depth-1 pending-bit coalescing; repeated requests cannot create more than one queued pass at a time.
* [x] Wave 2 - strict policy input normalization and fail-closed collision handling.
* [x] Wave 3 - cross-process pull/apply serialization on one flock-ordered path for both writers, sequence-guard removal, and non-blocking post-WireGuard inline row.
* [x] Boot and `POST /api/admin/sync` call the policy reconcile.
* [x] `POST /api/sync/refresh`: provisioned user, no body, no detail, enqueue-and-return.
* [x] Fire-and-forget pokes from `POST /clients` and `DELETE /clients/{clientId}`; inline local map row on create.
* [x] Wave 4 - account cleanup mode, clients-non-active fence, one authenticated fleet refresh, then hard delete.
* [x] `Policy/{regionId}` schema, Firestore rules, and `schema.ts`.
* [x] Server Health policy status display and failure card.
* [x] Wave 5 - comprehensive live-policy hashes, `updatedAt` last-applied display, enabled-region comparison, and mandatory Sync All after out-of-band role edits.
* [ ] Wave 6 - boot retry behavior, bootstrap/API contract checks, and final documentation alignment.
* [ ] Write and implement the separate iOS Server Health Policy parity plan before release.
* [ ] Verify nft verdict precedence, chain priority, and the mark comparison syntax on a real host.
* [ ] Verify the four reachability cases end to end: same-account same-region, same-account cross-region, cross-account denied both directions, admin proxy jump in both directions cross-region.
* [ ] Final `./scripts/test.sh` gate after all PR blockers, including Apple, are complete.

Original static review findings are tracked in
[account-scoped-acl-review.md](account-scoped-acl-review.md).

The final two live-host items need a running regional host and cannot be closed
from a workstation. The API renderer has byte-for-byte unit coverage, but the
current tests do not parse `bootstrap.sh` or prove that its object names and
aggregates still match the renderer. Add that contract check as part of the
review fixes. What also stays unproven until a host runs it is nftables' own
behaviour - that `priority -10` really evaluates ahead of the existing iptables
`FORWARD` accepts, that a `drop` verdict is terminal across tables, and that the
`ip daddr . meta mark != @cg_pairs` concatenation parses and matches as
intended. Confirm those before relying on the boundary.
