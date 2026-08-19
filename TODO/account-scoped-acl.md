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

## Review remediation

A static review of the original implementation commit `ae99c93` raised twelve
findings across slot integrity, cross-process ordering, the create fast path,
account deletion, malformed-row handling, policy status, and documentation. All
twelve are closed: ten by implementation across Waves 1-6, two (findings 1 and
5) as accepted dispositions. The iOS Server Health parity work is deferred to
its own plan and remains an open release blocker.

Finding numbers below are durable identifiers - API source, tests, and the
release migration cite them in comments. So are the wave names in "Delivery
waves".

### Accepted dispositions - do not reintroduce

* **No existing-host nftables migration (finding 1).** This release deploys by
  destroying and rebuilding every region through `./scripts/terraform.sh` from
  one deploy tag. Bootstrap installs nftables, writes the base ruleset, and
  loads it through WireGuard `PostUp`. Never deploy this branch with
  `cloudgateway-install-api` and never mix an API-only upgrade into the rollout.
* **The depth-1 coordinator model stays (finding 5).** There may be one running
  pass and one pending pass. Repeated pokes while the pending bit is set
  coalesce. A poke arriving after the follow-up has started may set the bit
  again, deliberately, because its Firestore mutation may postdate that
  follow-up's snapshot and dropping it would lose the event. This bounds the
  *pending backlog* to one queued pass - it is not a bound on the total work a
  caller can trigger over time, and documentation must not claim otherwise. No
  durable queue, no rate limit, no refresh-cadence feature.
* **Role mutation is not a product feature in this PR.** No role-change API, UI,
  timer, or automatic propagation. A trusted operator who edits `UserRoles/{uid}`
  out of band must run Sync All Regions immediately; the fleet keeps enforcing
  the previous allow-set until they do. Reconcile still re-reads current roles,
  applies `cg_admin4/6`, and includes them in read-back and status hashes, so
  partial fleet application is visible.
* **iOS parity is deferred to its own plan, but not to a later release.** See
  "Open release blockers".

### Findings and resolutions

Severity is as assessed at review time; P1 findings blocked rollout.

**1. Existing-region upgrades could run the new API with no ACL installed** (P1).
`cloudgateway-install-api` copied `Backend/API/` and restarted the API, but the
ruleset is loaded by `wg0`'s `PostUp`, which does not rerun on an already-active
interface - so re-running bootstrap was not a migration either. The API would
call `nft` against a table that does not exist, swallow the failures, and keep
serving while cross-account forwarding stayed unrestricted. *Closed as an
accepted disposition:* rebuild-only rollout, enforced in `bootstrap.sh` - an
ACL-aware source tree refuses to install unless the live host already has `inet
cloudgateway` with the `cg_forward` chain and `cg_slot4/6` maps, with an
explicit `CLOUDGATEWAY_ALLOW_UNSAFE_API_UPGRADE=1` emergency override that warns
loudly. The gate is documented in `docs/regional-deployment.md`,
`docs/quick-deployment.md`, and `docs/deployment-handoff.md`, and
cross-referenced from `docs/service-operations.md`.

**2. Losing or corrupting the slot counter could merge two accounts** (P1,
security boundary failure). A missing or invalid `Counters/accountSlots.nextSlot`
reset to `1`, so a second account could be issued a slot already in use and the
filter would treat two tenants as one. *Closed:* `repository.next_account_slot()`
never resets once any slot exists - a valid counter is advanced past the maximum
valid assigned slot, an absent or malformed counter is re-derived only when every
assigned slot is itself valid and unique, and an exhausted counter always raises
rather than recovering downward. `firebase._allocate_account_slot()` reads the
whole `Users` collection inside the allocating transaction, so recovery cannot
race an allocation. `valid_account_slot()` is the single source of truth for the
type and range check across the package.

**3. The sequence guard did not cover the process that runs at boot** (P1). The
pull happened before the host flock was taken, and the last-applied sequence was
in-memory only, so an older boot or manual pull could wait for the flock and then
overwrite a newer map - reassociating a reused address with its former account
slot. *Closed:* the Firestore pull moved *inside* `policy.lock()`, making
`pull -> apply -> read back -> write status` one flock-ordered unit. The
process-local sequence guard was deleted rather than extended, since a later
writer now cannot begin its pull until the earlier writer has finished. Both
writers - the API's `PolicyCoordinator` and the boot/manual
`cloudgateway-sync-peers` process - call the identical `reconcile_policy()`, and
additional API workers would serialize on the same flock.

**4. The inline fast path could fail a create after the client was active** (P1).
The account-slot lookup sat outside the best-effort error boundary, so a
Firestore error after `add_peer` and `mark_client_active()` had both succeeded
returned a 500 and skipped the reconcile and remote pokes entirely. *Closed:*
`routes._write_inline_policy_row()` performs slot lookup, role lookup, address
normalization, lock acquisition, and the row apply inside one exception boundary.
Nothing in the inline path can turn a successful creation into a failed response.

**5. Refresh coalescing is not structurally bounded** (P1). Any provisioned user
can call `POST /api/sync/refresh`, there is no rate limit, and continued arrivals
keep the drain loop alive. *Closed as an accepted disposition* (see above): the
behavior is intended and unchanged, its documentation is narrowed to the
one-item pending backlog guarantee, and a sustained-arrival test asserts that a
poke arriving after the follow-up pass has started still runs a third pass.
`POST /api/admin/sync`'s policy leg is synchronous and therefore waits for the
coordinator to quiesce, which sustained pokes can extend; that is accepted, and
the outcome it reports always comes from a pass whose pull started after the
request.

**6. Admin allow-set changes were neither propagated nor observable** (P1,
privilege staleness). `desired_policy()` derived `cg_admin4/6` from `UserRoles`,
but read-back and hashing covered only `cg_slot4/6`, so a demotion changed no
published hash and Server Health still reported agreement. *Closed:* the status
hashes now cover every authorization-bearing object per family, `cg_admin4/6`
included, so a promotion or demotion changes the published hash as soon as the
next reconcile runs. Propagation itself stays operator-driven by decision -
Sync All Regions is mandatory after any out-of-band `UserRoles` edit.

**7. Existing accounts were never migrated to account slots** (P1 for rollout
availability). `desired_policy()` skips every client whose owner lacks
`Users.accountSlot`, and legacy accounts got one only on a future client
reservation - so a legacy account with active clients and no further reservation
would drop out of every map and lose its own same-account connectivity once
enforcement began. *Closed:* `releases/access-control-lists/backfill_account_slots.py`
assigns slots to every provisioned legacy account and seeds the counter strictly
above every slot assigned anywhere, including orphaned `Users` documents. It is
dry-run by default, transactional, aborts if live state changes between preflight
and apply, reports aggregate counts only, and is a no-op on re-run.

**8. Account deletion indirectly issued the pokes the design rejects** (P2, plan
deviation). Account cleanup deleted remote clients through the ordinary
`DELETE /clients/{clientId}` path, which always scheduled its own local reconcile
and fleet poke - so deletion raced the hard delete and exercised the exact
missing-role behavior the design meant to avoid. *Closed:* that handler gained an
`accountCleanup` mode which suppresses its own reconcile and fleet poke, honored
only for a self-delete that independently satisfies every condition
`DELETE /account` requires (self-only, recent authentication, role restriction),
re-checked against the replayed bearer token. A request that fails any check
fails outright rather than silently downgrading. `DELETE /account` then owns
propagation in one sequence: remove local and remote peers; fence every one of
the account's client documents non-active fleet-wide by `ownerUid` in one trusted
repository operation, including clients whose region was unreachable; send exactly
one best-effort refresh wave to the other enabled regions while `UserRoles/{uid}`
and recent authentication both still exist; queue the local reconcile; only then
hard-delete. A failure before the fence leaves clients ACTIVE and retryable.

**9. Malformed and colliding client rows were not consistently fail-closed** (P2).
An unhashable `ownerUid` could abort the pass, raw `updatedAt` values were
compared as datetimes, non-host client prefixes were accepted, duplicate
addresses were resolved first-wins, duplicate slots merged accounts, and an
oversized slot aborted the whole apply. *Closed:* `desired_policy()` validates
owner type, slot, and host prefix per row and excludes *every* participant in an
address or slot collision - counted across all candidates first, so collection
order can never pick a winner. `bare_tunnel_address()` reuses
`wireguard.is_valid_tunnel_ip`, so the policy map and peer validation cannot drift
apart on the family/host-prefix rule. `updatedAt` no longer feeds policy status at
all. Rejected rows increment an aggregate count and never log a uid, address,
slot, name, email, key, or configuration. The migration's fleet-wide preflight
applies the same rules as a release gate, so known-bad data blocks the rollout
instead of silently dropping rows on the first host that enforces.

**10. The policy lock could block the WireGuard create path** (P2, plan
deviation). Client creation held `wireguard.lock()` while the inline policy write
took the policy flock, which a reconcile holds through a Firestore status write -
so a slow status write could stall a create and make an otherwise non-blocking
peer sync shed. *Closed:* the inline write runs after the WireGuard critical
section closes, and its policy-lock acquisition is non-blocking. No Firestore
read, policy-lock acquisition, or `nft` call happens while the WireGuard lock is
held. If a full pass already owns the policy lock the row is shed and logged
(`policy_row_lock_busy`) rather than waited for - safe, because the reconcile
`create_client` queues immediately afterwards pulls after this client's commit.

**11. `dataVintage` could not reliably identify a stale region** (P2, dashboard
correctness). The maximum `updatedAt` among active rows is not monotonic:
deleting the newest row moved a freshly reconciled region backward while a stale
region kept the deleted row's later timestamp, so the dashboard could mark the
correct regions stale. A successful empty snapshot also rendered as "No applied
snapshot yet". *Closed:* `dataVintage` and the process-local `appliedSequence`
are removed from the API model, Firestore schema, rules fixtures, Web parser, UI,
and docs. Freshness is comprehensive live-policy hash agreement among *enabled*
regions - disabled regions never participate and can never be drifted - plus
`Policy.updatedAt` displayed as "Last applied". Timestamp age alone is never
drift or staleness; keep `rowCount` as the number of slot-map rows. Where no strict
majority hash exists, every comparable region is flagged rather than crowning a
plurality winner; a missing, malformed, or unreadable document renders an
explicit per-region failure state without taking down the independent Mesh cards.

**12. Status validation and documentation overstated what was verified** (P3).
The Web parser accepted a document missing `appliedSequence`; `api-contract.md`
claimed a failed apply surfaces in the status document; `wireguard-drift-repair.md`
said boot reconciliation runs inside the API process; and the plan claimed a
bootstrap rename fails the build when no test read the ruleset at all. *Closed:*
the parser requires every field. `reconcile_policy()` raises before it ever calls
the status write, so a failed apply or read-back leaves the last successful
`Policy/{regionId}` document byte-identical and writes no failure status - the
docs now say that explicitly. Boot reconciliation is documented as running inside
the `cloudgateway-sync-peers` CLI process while the two HTTP-triggered calls run
inside the long-running API process, all three serialized by the same flock.
`Backend/API/tests/test_bootstrap_contract.py` parses the `table inet cloudgateway`
heredoc offline and ties every object name, kind, tunnel aggregate, address
family, rule family, rule *ordering*, and the `cloudgateway-install-api` gate
string back to the policy renderer in both directions, with negative tests proving
a rename or reorder on either side fails it. It does not verify runtime nftables
behavior, so the live-host items below stay open.

### Delivery waves

Referenced by name from source comments.

* **Wave 1 - legacy slot migration and allocator integrity.** Findings 2 and 7.
* **Wave 2 - policy input normalization and collision handling.** Finding 9,
  plus the migration's fleet-wide policy-row preflight gate.
* **Wave 3 - cross-process ordering and create-path isolation.** Findings 3, 4,
  and 10.
* **Wave 4 - account deletion ordering.** Finding 8. The response's
  `deletedClientCount` became the fence operation's authoritative per-region
  count rather than the pre-removal snapshot size; the two agree for a fleet in
  a consistent state, so this is not an observable API change. There is no
  stored per-region client counter to repair - capacity is derived, and
  `Regions/{regionId}.tunnelIndexV4/V6` are monotonic allocator indices that must
  never roll back and are untouched by deletion.
* **Wave 5 - complete live hashes and Web status.** Findings 6 and 11.
* **Wave 6 - boot retry, contracts, and documentation.** Finding 12, plus boot
  retry: `sync.py` returns `EXIT_OK`/`EXIT_PEER_SYNC_FAILED`/`EXIT_POLICY_FAILED`,
  so a policy-only failure exits 2 and `cloudgateway-sync-peers.service` retries
  the whole idempotent peer-plus-policy pass, while a peer failure short-circuits
  before policy is attempted and a successful apply with a failed best-effort
  status write still exits 0. `AdminSyncResponse` gained
  `policyApplied`/`policyRowCount`/`policyStatusWritten` (the optionals omitted on
  failure) so Sync All distinguishes a policy failure from peer/mesh success
  without changing any existing field; a region predating this release omits all
  three and the dashboard treats that as unknown, not as failure.

### Open release blockers

**iOS Server Health Policy parity.** Write and implement a separate plan. At
minimum it must add shared `CloudGatewayAppCore` Policy models and derivation, a
Firestore mapper, repository/facade fetch contract, the iOS Firestore adapter,
independent Policy load-failure state, post-Sync-All reload, client-isolation
status UI, tests, and screenshot fixtures. Swift status semantics must match the
final Web semantics - comprehensive hash agreement among enabled regions plus
"Last applied" - rather than porting the superseded `dataVintage` model.

**Live-host verification.** Neither item is covered by the offline contract test:

* nft verdict precedence, chain priority, and the concatenated-set mark
  comparison syntax on a real host.
* The four reachability cases end to end: same-account same-region, same-account
  cross-region, cross-account denied in both directions, and the admin proxy jump
  in both directions cross-region.

### Validation and release order

1. Run targeted validation after each change through `./scripts/test.sh`; the
   release migration runs under the `release` target.
2. Run the full `./scripts/test.sh` gate after the remediation and again after
   the deferred iOS parity work lands.
3. Create a fresh Firestore backup. Run the migration dry-run, review aggregate
   counts and invariants, run `--apply`, then rerun the dry-run and require a
   no-op. Do not reuse an older backup as the rollback point.
4. Deploy every region from one tag with `./scripts/terraform.sh <all regions>`.
   The sequential interval is a rollout window with partial fleet enforcement; do
   not treat the ACL as active until the last region finishes.
5. Run Sync All Regions and confirm every enabled region reports matching
   comprehensive IPv4/IPv6 hashes and a last-applied timestamp.
6. Complete the live-host verification above before declaring the boundary
   active.

## Checklist

* [x] New-account slot allocation: counter document, `Users/{uid}.accountSlot`, allocated at provisioning or a later client reservation.
* [x] Monotonic address allocation with wrap and in-use check, replacing `_first_unused_tunnel_ip`; paired v4/v6 indices.
* [x] nftables table, sets, maps, and chain in `bootstrap.sh` `PostUp`/`PostDown`; `nftables` package installed for new or rebuilt hosts.
* [x] `reconcile_policy()`: fleet-wide pull, atomic apply, read-back, status write.
* [x] Dedicated policy flock, separate from the WireGuard flock.
* [x] Boot and `POST /api/admin/sync` call the policy reconcile.
* [x] `POST /api/sync/refresh`: provisioned user, no body, no detail, enqueue-and-return.
* [x] Fire-and-forget pokes from `POST /clients` and `DELETE /clients/{clientId}`; inline local map row on create.
* [x] `Policy/{regionId}` schema, Firestore rules, and `schema.ts`.
* [x] Server Health policy status display and failure card.
* [x] Findings 1 and 5 closed as accepted dispositions; rebuild-only rollout gate enforced in `bootstrap.sh`.
* [x] Findings 2, 3, 4, 6, 7, 8, 9, 10, 11, and 12 implemented across Waves 1-6.
* [x] Full `./scripts/test.sh` gate green after the remediation (2026-08-19).
* [ ] Write and implement the separate iOS Server Health Policy parity plan before release.
* [ ] Verify nft verdict precedence, chain priority, and the mark comparison syntax on a real host.
* [ ] Verify the four reachability cases end to end.
* [ ] Run the migration (backup, dry-run, `--apply`, no-op rerun) and rebuild every region from one tag.
* [ ] Final `./scripts/test.sh` gate after all PR blockers, including Apple, are complete.
