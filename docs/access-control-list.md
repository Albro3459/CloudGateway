# Account-Scoped ACL: Client-to-Client Isolation

A client may reach another client over the tunnel only when both are owned by the same
CloudGateway account. Enforcement is a stateless nftables filter on every regional host, driven
by an address-to-account map each host pulls from Firestore. Addressing, subnets, and the mesh
design are unchanged by this feature; no VPN client configuration changed.

This is the durable design and operations record. For the live-host verification procedure see
[acl-live-verification.md](acl-live-verification.md); for the reconcile pass in the context of
peer sync see [wireguard-drift-repair.md](wireguard-drift-repair.md#account-scoped-acl-policy-reconcile);
for the external HTTP contract see [api-contract.md](api-contract.md).

## Problem

Client-to-client traffic was previously unrestricted fleet-wide. Server-side `AllowedIPs` is
exactly the client's `/32` and `/128`, and forwarding was a blanket accept. Since the shared
subnet mesh landed, mesh peers carry subnet-width `AllowedIPs` plus routes for the remote `/24`
and `/64`, so any client could reach any other client's tunnel IP in any region. Nothing about
the account boundary was expressed on the wire.

`AllowedIPs` cannot fix this. It is cryptokey routing: it pins the source address a peer may use
and does not constrain destinations. Client-side `AllowedIPs` is not enforcement at all, since
the client owns its own config and CloudGateway configs are full-tunnel. The boundary has to be a
packet filter on the servers.

Because `AllowedIPs` already pins source addresses, a filter keyed on source address is
trustworthy: a client cannot present another client's tunnel IP.

## Architectural Decisions

* **The boundary is the account (`ownerUid`), not a group.** No group, team, or family concept
  exists. If sharing across accounts is ever wanted it is a separate feature; the map design
  accommodates it, and nothing here hard-codes the assumption that an account is the only
  possible unit.
* **Accounts are identified on hosts by an opaque slot, never by uid.** A monotonically allocated
  32-bit integer stored on `Users/{uid}.accountSlot`, never reused. Hosts hold `address -> slot`
  and nothing else: no uid, no email, no client name. A compromised host learns which addresses
  are equivalent, not who owns them. Slots are allocated, not hashed from the uid, so two
  accounts can never collide into one tenant.
* **Admins are ordinary tenants on the wire.** Admin powers are the dashboard and the API. An
  admin has no network reach into another account's devices. The one exception is infrastructure
  reach, below.
* **Servers may reach admin-owned clients, in both directions.** An admin can SSH into a regional
  host and connect onward to their own devices inside the tunnel, including cross-region, and
  those devices can reach the hosts. This is scoped to admin-owned clients rather than granted
  blanket, because admins have SSH on the hosts: a blanket infra exemption would let any admin
  reach every customer device with one extra hop, which is exactly the property this feature
  exists to remove.
* **Maps are identical fleet-wide.** Every host holds every client's row. Scoping each region to
  accounts with a local client is a valid optimization and is explicitly rejected: at
  `region_capacity_limit` of 20 the whole fleet map is a few dozen rows, and identical maps are
  what make the cross-region status hash comparable.
* **Propagation is event-driven only. No timer, no version document.** A client create or delete
  pokes the other regions; each poked region pulls a full snapshot from Firestore. Boot and admin
  Sync All also pull. A dropped poke leaves a region stale until the next fleet-wide client event
  or an admin sync, and that is accepted.
* **Addresses are allocated by incrementing, not first-unused.** This replaces a time-based reuse
  TTL with a distance-based one and needs no `releasedAt` bookkeeping.
* **Firestore stays the source of truth.** The refresh pulls desired state; it never writes
  desired state back. Status writes are best effort and never make a pass fail, matching the
  existing rule for `Mesh/{regionId}`.

## Threat Model

In scope: one account's client reaching another account's client over the tunnel, in the same
region or across the mesh.

Out of scope and unchanged: client to internet egress, client to its own region's server (DNS,
API), server to its own local clients, mesh server-to-server links, and any traffic that never
traverses `wg0` on both sides. A client that has been removed as a WireGuard peer cannot put
packets on the tunnel at all; the ACL is a second boundary behind cryptokey routing, not a
replacement for peer removal.

## Filter Design

One `inet` table named `cloudgateway`, installed by `wg0`'s `PostUp` from
`/etc/cloudgateway/cloudgateway.nft`. It replaces nothing in the existing `iptables`/`ip6tables`
rules: a `drop` verdict is terminal across tables, so the existing `FORWARD` accepts did not need
reordering or renumbering. The base chain runs at `priority -10`, ahead of the iptables-nft
forward chains at priority 0, so it evaluates first. Verdict precedence and priority were proved
by packet on live hosts, not by inspection (see [Verification](#verification)).

### Objects

Every logical object is mirrored per address family. The API never creates or deletes the table
or chain and never writes `cg_tunnel4/6`; it only replaces element contents.

| Object | Kind | Owner | Contents |
| --- | --- | --- | --- |
| `cg_tunnel4` / `cg_tunnel6` | interval set | `bootstrap.sh`, static | The fleet tunnel aggregates, mirroring `MESH_AGGREGATE_V4` / `MESH_AGGREGATE_V6` in `Backend/API/src/wireguard.py` |
| `cg_infra4` / `cg_infra6` | set | reconcile pass | Every region's interface address, derived as network address + 1 of that region's tunnel CIDR |
| `cg_admin4` / `cg_admin6` | set | reconcile pass | Client addresses whose owner holds the admin role |
| `cg_slot4` / `cg_slot6` | map `addr : mark` | reconcile pass | Client address to account slot |
| `cg_pairs4` / `cg_pairs6` | set `typeof <ip> daddr . meta mark` | reconcile pass | One `address . mark` concatenation per client |

`cg_pairs` is a concatenated set rather than a set of allowed source-destination pairs: one
lookup and O(n) elements instead of O(n squared). The concatenated formulation was also chosen
over comparing two map lookups because it is unambiguously supported by nft.

### Chain

Installed verbatim by `bootstrap.sh`; `$WG_INTERFACE` interpolates at write time.

```
table inet cloudgateway {
	set cg_tunnel4 { type ipv4_addr; flags interval; elements = { 10.0.0.0/16 } }
	set cg_tunnel6 { type ipv6_addr; flags interval; elements = { fd42:42:42::/48 } }
	set cg_infra4 { type ipv4_addr; }
	set cg_infra6 { type ipv6_addr; }
	set cg_admin4 { type ipv4_addr; }
	set cg_admin6 { type ipv6_addr; }
	map cg_slot4 { type ipv4_addr : mark; }
	map cg_slot6 { type ipv6_addr : mark; }
	set cg_pairs4 { typeof ip daddr . meta mark; }
	set cg_pairs6 { typeof ip6 daddr . meta mark; }
	chain cg_forward {
		type filter hook forward priority -10; policy accept;
		ct state established,related accept
		iifname "$WG_INTERFACE" oifname "$WG_INTERFACE" ip saddr @cg_infra4 ip daddr @cg_admin4 accept
		iifname "$WG_INTERFACE" oifname "$WG_INTERFACE" ip saddr @cg_admin4 ip daddr @cg_infra4 accept
		iifname "$WG_INTERFACE" oifname "$WG_INTERFACE" ip6 saddr @cg_infra6 ip6 daddr @cg_admin6 accept
		iifname "$WG_INTERFACE" oifname "$WG_INTERFACE" ip6 saddr @cg_admin6 ip6 daddr @cg_infra6 accept
		meta mark set ip saddr map @cg_slot4
		meta mark set ip6 saddr map @cg_slot6
		iifname "$WG_INTERFACE" oifname "$WG_INTERFACE" ip daddr @cg_tunnel4 ip daddr . meta mark != @cg_pairs4 drop
		iifname "$WG_INTERFACE" oifname "$WG_INTERFACE" ip6 daddr @cg_tunnel6 ip6 daddr . meta mark != @cg_pairs6 drop
	}
}
```

Rule order is load-bearing:

1. `ct state established,related accept` - return traffic for any flow already permitted. Without
   this the infra rules are one-way and SSH hangs on connect.
2. Four infra/admin accepts (server to admin-owned client and the reverse, per family), scoped to
   traffic both entering and leaving `wg0`.
3. Two `meta mark set ... map @cg_slot` rules. The mark carries the source's account slot; an
   unknown source leaves the mark cleared at 0. These rules are unconditional, not interface
   scoped - the mark is only ever consumed by the drop rules below, which are interface scoped.
4. Two terminal drops: if the destination is inside the tunnel aggregate and
   `destination . mark` is not in `cg_pairs`, drop.

Everything else falls off the end and is accepted: egress to the internet, and any traffic not
both entering and leaving `wg0`.

### Consequences worth stating

* **An empty map means no client-to-client traffic.** That is the correct boot state. The rules
  are installed by `PostUp` and populated only by the first pull, so the failure mode of an
  unreachable Firestore is "peer-to-peer is down", never "VPN is down". `cg_tunnel4/6` is what
  makes the empty state fail closed - without it an unknown destination would fall through to
  accept.
* **Slot 0 is reserved and never assignable.** An unmarked packet's mark defaults to 0, meaning
  "unknown source". `policy.MIN_SLOT` / `MAX_SLOT` and
  `repository.MIN_ACCOUNT_SLOT` / `MAX_ACCOUNT_SLOT` are the 32-bit mark range and must always
  agree; a test asserts the two pairs never drift.
* **A non-admin client reaching another region's server interface address is dropped**, because
  infra addresses are inside `cg_tunnel` and are not in `cg_pairs`. This is intentional. Local
  server access is unaffected because it is `INPUT`, not `FORWARD`.
* **The chain assumes no other subsystem uses the packet mark** and that no `ip rule fwmark`
  exists. If that ever changes, switch to a masked mark. Live verification confirmed neither is
  present on the fleet.
* **`PostDown` runs `nft delete table inet cloudgateway || true`.** The table may already be
  absent, and interface teardown must not fail on it.

### Apply, read-back, and hashing

`Backend/API/src/policy.py` owns every `nft` interaction.

* `apply_map()` renders one script and loads it with a single `nft -f -`, so the whole map
  changes atomically. The script flushes `cg_infra4/6`, `cg_admin4/6`, `cg_pairs4/6` and
  `cg_slot4/6` and then re-adds every element. It never names `cg_tunnel4/6`.
* `add_client_row()` is the additive single-row fast path used by client create. It writes
  `cg_slot`, `cg_pairs`, and `cg_admin` only - never `cg_tunnel` or `cg_infra`. There is no
  additive removal counterpart; deletions are corrected by a full reconcile.
* Every address is parsed with `ipaddress` and every slot range-checked before rendering. Nothing
  is interpolated raw: an unescaped field in an nft script is command injection into the host
  firewall. `render_policy_script`/`render_client_row_script` do not re-validate and must only
  ever be called with already-validated rows.
* `read_map()` reads the whole table in one `nft -j list table inet cloudgateway` - ten separate
  object reads would be ten round trips and ten chances for the table to change mid-read-back. It
  parses all ten named objects; a named object missing from the listing is a failure, never an
  empty object, so a missing `cg_admin4` can never hash as "no admins".
* The status hash is a sha256 hex digest per address family over every authorization-bearing
  object in that family, in the fixed order `tunnel, infra, admin, slot, pairs`, one line per
  element formatted `<object-name> <element...>`. Element order is canonicalized at construction
  (sorted by packed address, mark breaking ties; networks by network address then prefix length),
  so two regions holding identical policy can never publish different hashes because nft happened
  to list elements in a different order. The object-name label on each line is load-bearing: it
  is what makes `cg_admin4 10.0.0.2` and `cg_infra4 10.0.0.2` hash differently, and what keeps v4
  and v6 independent.

## Firestore Model

```text
Users/{uid}
  accountSlot          number, allocated once from Counters/accountSlots, never reused

Counters/accountSlots
  nextSlot             number, monotonic allocation watermark
  updatedAt

Regions/{regionId}
  tunnelIndexV4        number, per-region monotonic client-address allocator index
  tunnelIndexV6

Policy/{regionId}
  regionId
  mapHashV4            composite hash of the complete live IPv4 policy read back from nftables
  mapHashV6
  rowCount             number of cg_slot4 rows
  updatedAt            server timestamp of the last successful apply and read-back
```

`Policy/{regionId}` is observability only: admin `get`/`list`, `write: if false` for every
client, written by each region's host through the Admin SDK, mirroring the existing
`Mesh/{regionId}` rules block. `Counters/{counterId}` is `read, write: if false` - Admin SDK
only, denied to admins too, stated explicitly rather than left to default-deny.

Status must describe what is actually on the wire, read back from the live map, not what the
region intended to apply; a status derived from the pulled snapshot would always look healthy and
would report nothing. The hashes cover every nftables object that affects the IPv4 or IPv6
decision, not only the address-to-slot maps, so a role promotion or demotion changes the
published hash as soon as the next reconcile runs.

The fleet-wide pull is an unfiltered `collection_group("Instances")` read with status filtering
done in the API, which needs no new composite index. A client with no live public key cannot
source traffic and is excluded. Admin slots come from a `UserRoles` read joined in the API.

### Account slot allocation

Allocation is once per account, inside a Firestore transaction, at user provisioning; client
reservation carries the same allocation as a fallback for an account whose `Users` document
predates a slot. `Counters/accountSlots.nextSlot` is the sole allocation authority. Only a valid
counter allocates, and only when it is strictly above every valid assigned slot. Missing,
malformed, regressed (at or below a live slot), and exhausted counters all raise
`AccountSlotUnavailableError` (`ACCOUNT_SLOT_UNAVAILABLE`, HTTP 500) rather than being
re-derived.

The allocating transaction reads the whole `Users` collection, but only to disprove a regressed
counter - never to reconstruct one. Account deletion hard-deletes `Users/{uid}` along with its
`accountSlot`, so a deleted account's slot exists nowhere in live data; re-deriving a counter
from live users would re-issue it and merge two accounts onto one nftables tenant. Seeding the
counter is a one-time pre-activation step
(`releases/access-control-lists/backfill_account_slots.py --seed-initial-counter`); after
activation a lost counter is restored from backup, with provisioning failing closed until then.
`valid_account_slot()` is the single source of truth for the type and range check across the
package.

### Row validation and collisions

`desired_policy()` must never abort a pass on bad data - a malformed row is excluded and counted,
exactly like `desired_mesh_peers`. It runs two passes over the fleet snapshot:

1. Per-row validation in isolation: owner uid must be a non-empty string; the owner must hold a
   valid slot; both addresses must pass `bare_tunnel_address()`, which reuses
   `wireguard.is_valid_tunnel_ip` for the family/host-prefix rule (so the policy map and peer
   validation cannot drift apart) and additionally requires the address to sit inside the fleet
   aggregate.
2. Collision exclusion: occurrences of every candidate v4 and v6 address are counted across all
   candidates *before* any is excluded, so collection order can never pick a winner. Every
   participant in an address collision is dropped. Account-slot collisions are resolved up front
   the same way: a slot claimed by more than one uid excludes every participating uid, never just
   the loser.

Rejected rows increment an aggregate `skipped_rows` count and are logged as a count only - never
a uid, address, slot, name, email, key, or configuration. `updatedAt` never feeds the policy path
at all: `PolicyClientEntry` deliberately has no timestamp field, so a malformed timestamp cannot
abort a pass.

Infra addresses are derived per region from `tunnelNetworkV4`/`tunnelNetworkV6` and de-duplicated
before apply (a repeated element would make the atomic nft batch reject the whole set). Every
region document participates, enabled or not: a disabled region's host still exists and its
interface address is still infra. `cg_infra` bypasses the account-slot boundary, so its
derivation is an authorization boundary in its own right - only the supported `/24` and `/64`
widths are accepted, and the derived address must fall inside both the region network and the
fleet aggregate. Without the width check a stored `10.0.5.5/32` would yield `10.0.5.6`: outside
its own network, inside the aggregate, and possibly a real client's address.

## Address Allocation

Lowest-free-address allocation is gone. Each region document carries a monotonic index
(`tunnelIndexV4`/`tunnelIndexV6`) advanced in the same transaction as `reserve_client`:

* Take the next index, wrap at the top of the host range, and skip any index currently in use.
* The host range is `2 .. num_addresses - 2` of the region's v4 network, 253 indices for a `/24`,
  so the wrap is a real event after roughly 253 lifetime allocations, not a theoretical one. The
  in-use check on wrap is load-bearing and must not be treated as dead code.
* Only the v4 network bounds the range. IPv6 is a `/64` and never wraps. The v4 and v6 indices
  are written from the same value so a client's two addresses always share an index; pairing to
  the smaller v4 range is what makes the wrap possible at all.
* Index-to-address recovery is best effort in both directions: either of a client's two addresses
  alone reserves its index, and a malformed or out-of-network stored address is skipped rather
  than raised, so one bad row cannot block every future allocation.
* No `releasedAt` field and no time-based TTL. With `region_capacity_limit` at 20, incrementing
  gives roughly 230 allocations of distance before an address returns, and every one of those
  allocations is itself a poke that would have corrected a stale row.

`Regions/{regionId}.tunnelIndexV4/V6` are monotonic allocator indices. They must never roll back,
and deletion never touches them.

## Refresh Model

One `reconcile_policy()` pass does everything: pull the fleet snapshot, build the map, apply it
atomically, read it back, write status. Callers:

* **Boot.** `cloudgateway-sync-peers` runs the policy reconcile after the peer/mesh pass, so a
  rebuilt or rebooted host repopulates its entire map from Firestore without needing any peer to
  poke it. A peer-sync failure short-circuits before policy is attempted and exits
  `EXIT_PEER_SYNC_FAILED` (1); a policy-only failure exits `EXIT_POLICY_FAILED` (2) so systemd
  retries the whole idempotent peer-plus-policy pass. A successful apply whose best-effort status
  write failed still exits 0.
* **`POST /api/admin/sync`**, so Sync All is the repair path for a dropped poke.
* **`POST /api/sync/refresh`**, the poke endpoint.

Boot reconciliation runs inside the `cloudgateway-sync-peers` CLI process; the two
HTTP-triggered calls run inside the long-running API process. All three are serialized by the
same flock.

### Concurrency

* **Its own lock, separate from `wireguard.lock()`.** A policy refresh must never contend with
  `add_peer` on the client create path or make an admin's non-blocking Sync All shed with
  `SyncInProgressError`. Traffic in one region must not slow client creation in another.
* **The Firestore pull happens inside `policy.lock()`**, making `pull -> apply -> read back ->
  write status` one flock-ordered unit for both the API process and the boot/manual sync process.
  Pulling inside the lock is what makes cross-process application order match snapshot order: a
  later writer cannot begin its pull until the earlier writer has finished, so a stale snapshot
  can never wait outside the lock and then overwrite a newer map. There is no process-local
  sequence number, and one must not be reintroduced - a process-local counter cannot provide a
  cross-process guarantee, and mutual exclusion here needs no fleet-wide ordering value.
* **Depth-1 coalescing.** Any number of pokes arriving during a running pull set a pending bit;
  when the pull finishes and the bit is set, it is cleared and one more pull runs. Requests
  coalesce while the bit is already set. A request arriving after the follow-up has started may
  set it again, deliberately, because that request may announce a newer Firestore mutation.
* **The status write is best effort.** It is reported (`status_written`), never raised: the
  interface is already reconciled, so failing the pass over a status write would discard correct
  work. Conversely `reconcile_policy()` raises before it ever reaches the status write if the
  apply or read-back fails, so a failed apply leaves the last successful `Policy/{regionId}`
  document byte-identical and writes no failure status.
* **`PolicyCoordinator.request()` never blocks and never raises.** It runs from a background task
  with nothing able to observe a failure, so every exception is logged and swallowed.
  `run_blocking()` is the synchronous variant used by admin Sync All; it coalesces the same way,
  then waits for the coordinator to quiesce and returns the last completed outcome, which is
  always from a pass whose pull started after the call.

The poke reconciles the policy map only. A region's peer set is its own local active clients plus
mesh regions and cannot be changed by another region's client, so a full sync on the poke path
would reconcile peers that provably did not change, re-resolve mesh endpoint hostnames, and
reapply routes, any of which can hang.

## API Surface

### `POST /api/sync/refresh`

* Any provisioned user, via `require_provisioned_user`. Not admin-only.
* No body, no detail in the response, no information about region health, counts, or errors.
  Returns `202` immediately after enqueueing.
* Policy map only.
* No dedicated secret and no rate limit. The caller's own Firebase token is replayed, matching
  the existing cross-region pattern in `_delete_remote_client`. Depth-1 coalescing bounds the
  pending backlog to one follow-up pass; it does not bound the total number of sequential
  refreshes a caller can trigger over time.

### `POST /api/admin/sync`

Admin only, full peer/mesh pass plus a synchronous policy leg, detailed response, used by Server
Health's Sync All on Web and iOS. `meshEnabled` toggling and detailed logs stay admin. The policy
leg is blocking so the admin sees a fresh `Policy/{regionId}` immediately after the call returns;
a policy failure is logged and flips `policyApplied` to false but never fails the endpoint and
never affects the peer/mesh fields.

The response carries `policyApplied`, `policyRowCount`, and `policyStatusWritten`, with the two
optionals omitted on failure. A region predating this release omits all three; dashboards treat
that as unknown, not as failure. No pre-existing field changed meaning.

### Poke sites

Fire-and-forget after the response via `BackgroundTasks`, with a short per-region timeout, never
affecting the request result, logging region id only - never the token, uid, or response body:

* `POST /clients`, after the client document commits. The best-effort inline local map row is
  written after the WireGuard critical section closes, using only the separate policy flock taken
  non-blocking, so a client whose sibling is in the same region works immediately without a
  cross-region dependency. No Firestore read, policy-lock acquisition, or `nft` call ever happens
  while the WireGuard lock is held. Slot lookup, role lookup, address normalization, lock
  acquisition, and the row apply all sit inside one exception boundary: nothing in the inline
  path can turn a successful creation into a failed response. If a full pass already owns the
  policy lock the row is shed and logged (`policy_row_lock_busy`) rather than waited for - safe,
  because the reconcile `create_client` queues immediately afterwards pulls after this client's
  commit.
* `DELETE /clients/{clientId}`, except in account-cleanup mode. There is no inline removal, so
  the local map is corrected by a real reconcile rather than a single-row edit.

## Account Deletion

`DELETE /account` uses a dedicated cleanup sequence and owns propagation for the whole account,
so no per-client delete fans out its own poke:

1. Snapshot the account's clients and remove their local and remote WireGuard peers. Remote
   removal runs in account-cleanup mode.
2. Fence every one of the account's client documents non-active fleet-wide by `ownerUid`, in one
   trusted repository operation, including clients whose regional host was unreachable in step 1.
   From this point any policy pull in any region excludes the account, because the fence is keyed
   by owner, not by which region answered. `CREATING` documents are fenced too, so a concurrent
   `mark_client_active` cannot re-activate a client afterwards; already-removed documents are
   skipped with no write, so a retry converges and never resurrects anything; a document whose
   data cannot be parsed is fenced anyway, fail-closed.
3. While `UserRoles/{uid}` and the caller's recent authentication both still exist, send exactly
   one best-effort refresh wave to the other enabled regions synchronously, then queue the local
   reconcile. `/sync/refresh` enqueues and returns 202, so an accepted refresh no longer depends
   on the token once its response returns.
4. Only then hard-delete the account documents and the Auth user.

A failure before step 2 leaves clients `ACTIVE` and retryable; `UserRoles/{uid}` survives until
step 4 so a retry can still authorize. A failure after step 2 drops the queued local reconcile,
which is acceptable because the fence is already committed and a retry re-queues it.

The `accountCleanup` flag on `DELETE /clients/{clientId}` suppresses that handler's own reconcile
and fleet poke. It is honored only for a self-delete that independently satisfies every condition
`DELETE /account` requires (self-only, recent authentication, role restriction), re-checked
against the replayed bearer token. A request failing any check fails outright and is never
silently downgraded to an ordinary delete.

If a region is unreachable in step 1 or step 3, deletion proceeds after recording that failure;
its orphaned peer and stale policy row converge on the next boot or manual sync. The central
non-active fence prevents any new pull from restoring the deleting account.

## Dashboard Status

Server Health on Web and iOS alike shows each region's policy row count, comprehensive IPv4 and
IPv6 policy hashes, and `updatedAt` as "Last applied". Derivation is a single algorithm, written
once in `Frontend/Web/src/helpers/policyHelper.ts` and ported verbatim to
`CloudGatewayAppCore/CloudGatewayPolicyStatus.swift`; the two must stay in lockstep.

| State | Meaning |
| --- | --- |
| `ok` | Enabled, usable document, hash agrees with the fleet |
| `drifted` | Enabled, usable document, v4 or v6 hash disagrees |
| `disabled` | Region not enabled - values still render, never joins the comparison |
| `never-synced` | Enabled, no document, and the read itself succeeded |
| `unreadable` | Enabled, document present but missing or malformed fields |

Semantics that are settled:

* **Freshness is hash agreement, not timestamp age.** Timestamp age alone is never drift or
  staleness. `updatedAt` is displayed, not compared.
* **Only enabled regions participate.** A disabled region can never be drifted and can never make
  another region drift.
* **A document is usable only when `mapHashV4`, `mapHashV6`, `rowCount`, and `updatedAt` are all
  present.** Missing or invalid fields parse to null rather than a fabricated default, so "wrote
  garbage" is distinguishable from "wrote zero rows". A `rowCount` of zero alone is a valid boot
  state, not corruption.
* **No majority tie-break.** A hash held by a strict majority (>50%) of comparable regions is the
  fleet value and everyone else is drifted. Where no value clears that bar - an even split, or
  total disagreement - every comparable region is flagged rather than crowning a plurality
  winner, because the ambiguity itself is the signal. A lone comparable region has no peers and
  can never be drifted.
* **A missing, malformed, or unreadable `Policy/{regionId}` renders an explicit failure state**
  and must never crash or hide the independent Mesh status.
* Drift is not a failure of the sync pass. Status writes remain best effort and a status write
  failure never makes a pass fail.

## Host and Deploy Requirements

* `nftables` is installed by `bootstrap.sh` alongside `wireguard` and `iptables`.
* The table, sets, maps, and chain are written to `/etc/cloudgateway/cloudgateway.nft` (mode 644)
  and loaded by `PostUp = nft -f /etc/cloudgateway/cloudgateway.nft`, which runs before the
  iptables rules. `PostDown` deletes the table. Rules are installed empty, before any pull.
* `cg_tunnel4/6` is static and comes from the same allocation source the mesh uses. Adding a
  region adds its interface address to `cg_infra` fleet-wide, automatically, on the next
  reconcile - infra membership is data, not a bootstrap edit.
* Map contents are applied atomically as a single `nft -f -` load, never incrementally.
* Firestore rules carry a `Policy/{regionId}` block mirroring `Mesh/{regionId}` (admin read,
  Admin SDK write) and a `Counters/{counterId}` block denying all client access.
* No Terraform subnet, tfvars, registry, MTU, or OCI ingress change. No VPN client configuration
  change.

### Rollout gate

`cloudgateway-install-api` is not a supported upgrade path for a host that does not already have
the ACL loaded. The ruleset is loaded by `wg0`'s `PostUp`, which does not rerun on an already
active interface, so re-running bootstrap is not a migration either. An API-only upgrade onto
such a host would run policy code against a table that does not exist: `nft` calls fail, those
failures are swallowed, and cross-account forwarding stays wide open while the API keeps serving
as if nothing were wrong.

The gate lives in `cloudgateway-install-api` itself. It detects an ACL-aware source tree by the
presence of `Backend/API/src/policy.py`, then refuses to install unless the live host reports
`inet cloudgateway` containing the `cg_forward` chain and both `cg_slot4` and `cg_slot6` maps.
`CLOUDGATEWAY_ALLOW_UNSAFE_API_UPGRADE=1` overrides it for a genuine emergency and warns loudly.

The only supported rollout is destroying and rebuilding every region through
`./scripts/terraform.sh` from one deploy tag. The sequential interval between regions is a
rollout window with partial fleet enforcement; the ACL is not active until the last region
finishes.

### Legacy account migration

Every provisioned account needs `Users/{uid}.accountSlot` before any region enforces: an account
with no slot is skipped by `desired_policy()`, drops out of every map, and loses its own
same-account connectivity the moment enforcement begins.
`releases/access-control-lists/backfill_account_slots.py` assigns slots to every provisioned
legacy account and seeds the counter strictly above every slot assigned anywhere, including
orphaned `Users` documents. It is dry-run by default, transactional, aborts if live state changes
between preflight and apply, reports aggregate counts only, and is a no-op on re-run. Its
fleet-wide preflight applies the same row-validation rules as a release gate, so known-bad data
blocks the rollout instead of silently dropping rows on the first host that enforces.

## Accepted Risks and Out of Scope

* A dropped poke leaves a region stale until the next fleet-wide client event or an admin Sync
  All. No timer, no retry, no durable queue.
* Account deletion sends one deliberate best-effort refresh wave. An unreachable region can
  retain an orphaned peer and stale policy until its next boot or manual sync.
* A user racing their own account deletion from a second device can orphan a peer if a client is
  created between the step 1 snapshot and step 4. Its document is caught anyway (both the fence
  and the hard delete re-query), so no policy row survives; `cloudgateway-sync-peers` removes the
  peer on its next run. Creation after step 4 fails outright.
* Any regional host can reach admin-owned clients fleet-wide. Locally this was already true via
  `OUTPUT`; this extends it across the mesh, knowingly, to support admin proxy jumps.
* A region looping on a persistent policy failure re-pulls the fleet snapshot from Firestore
  every 30s indefinitely. The loop is the correct fail-closed behaviour - the region is not
  enforcing until it succeeds - but it is a signal to investigate, not a steady state.
* Per-region map scoping, group or family sharing, and a periodic reconcile timer are out of
  scope. The version-document poll considered during design is rejected as unnecessary given
  event-driven propagation.

## Settled Decisions: Do Not Reintroduce

These exist to stop future changes silently undoing settled decisions. Each was considered and
closed deliberately.

### Rollout and enforcement

* **No existing-host nftables migration.** This feature deploys by destroying and rebuilding
  every region through `./scripts/terraform.sh` from one deploy tag. Bootstrap installs nftables,
  writes the base ruleset, and loads it through WireGuard `PostUp`. Never deploy an ACL-aware ref
  with `cloudgateway-install-api`, and never mix an API-only upgrade into a rollout. The gate
  described above enforces this; the emergency override is not a migration path.
* **The API never owns the table or chain.** It replaces element contents only, and never touches
  `cg_tunnel4/6`. Creating, deleting, or reordering the chain from the API would put the boundary
  under the control of the process the boundary is meant to survive.

### Refresh and propagation

* **The depth-1 coordinator model stays.** There may be one running pass and one pending pass.
  Repeated pokes while the pending bit is set coalesce. A poke arriving after the follow-up has
  started may set the bit again, deliberately, because its Firestore mutation may postdate that
  follow-up's snapshot and dropping it would lose the event. This bounds the *pending backlog* to
  one queued pass - it is not a bound on the total work a caller can trigger over time, and
  documentation must not claim otherwise. Do not turn `_drain` into a real queue. No durable
  queue, no rate limit, no refresh-cadence feature.
* **`POST /api/admin/sync`'s policy leg is synchronous and therefore waits for the coordinator to
  quiesce**, which sustained pokes can extend. That is accepted; the outcome it reports always
  comes from a pass whose pull started after the request.
* **The pull stays inside the policy lock, and there is no process-local sequence guard.** The
  flock is the ordering mechanism. A sequence number was removed rather than extended because it
  cannot order two processes.
* **Role mutation is not a product feature.** There is no role-change API, UI, timer, or
  automatic propagation. A trusted operator who edits `UserRoles/{uid}` out of band must run Sync
  All Regions immediately; the fleet keeps enforcing the previous allow-set until they do.
  Reconcile still re-reads current roles, applies `cg_admin4/6`, and includes them in read-back
  and status hashes, so partial fleet application is visible.

### Data integrity

* **`Counters/accountSlots.nextSlot` is the sole allocation authority.** Never re-derive it from
  live `Users` - deletion hard-deletes `Users/{uid}` with its slot, so a live scan would re-issue
  a deleted account's slot and merge two accounts onto one nftables tenant. Missing, malformed,
  regressed, and exhausted counters must keep failing closed. Recovery is a deliberate operator
  repair from backup, never a runtime inference.
* **Collision handling excludes every participant.** Both sides of a duplicate address, and every
  uid sharing a slot, are dropped from the map. Occurrences are counted before any exclusion, so
  collection order can never elect a winner. Do not restore first-wins resolution.
* **`bare_tunnel_address()` reuses `wireguard.is_valid_tunnel_ip`.** The policy map and peer
  validation must not be able to drift apart on the family/host-prefix rule.
* **The inline create-path row can never fail a create.** It runs after the WireGuard critical
  section, takes the policy lock non-blocking, and keeps slot lookup, role lookup, address
  normalization, lock acquisition, and apply inside one exception boundary. Shedding on a busy
  lock is correct, not a bug.
* **Rejected rows are counted, never described.** No uid, address, slot, name, email, key, or
  configuration may enter a policy log line.
* **`updatedAt` stays out of the policy input path.** A malformed timestamp must never be able to
  abort a pass.
* **`_first_unused_tunnel_ip` and any `releasedAt`/TTL scheme stay gone.** The monotonic index
  with wrap and in-use skip is the allocator; the wrap and its in-use check are live code, not
  dead defensive branches.

### Status and dashboard

* **`dataVintage` and `appliedSequence` are removed and must not come back.** The maximum
  `updatedAt` among active rows is not monotonic: deleting the newest row moves a freshly
  reconciled region backward while a stale region keeps the deleted row's later timestamp, so a
  vintage-based dashboard marks the wrong regions stale. A successful empty snapshot also
  rendered as "No applied snapshot yet".
* **Hashes must stay comprehensive.** Every authorization-bearing object per family is hashed,
  `cg_admin4/6` included. Hashing only the slot maps made a demotion change no published hash
  while Server Health still reported agreement.
* **A failed apply or read-back writes no failure status.** `reconcile_policy()` raises before it
  reaches the status write, so the last successful `Policy/{regionId}` document is left
  byte-identical. Documentation must not claim a failed apply surfaces in the status document.
* **No majority tie-break** on either surface. Every comparable region is flagged when no hash
  clears a strict majority.
* **Parsers require every field.** A document missing any of `mapHashV4`, `mapHashV6`,
  `rowCount`, `updatedAt` is `unreadable`, not partially usable.

### Apple client surface

Web and iOS are the two admin surfaces this product has, and a security boundary whose status
appears on only one of them is a real gap - hence parity, not observability polish. iOS was never
broken by the ACL work: the sync parser already ignored unknown response fields,
`DeleteClientRequest.account_cleanup` is server-to-server only, and the `firestore.rules` change
was purely additive.

* **Shared-first.** Models, mapping, and derivation live in `CloudGatewayAppCore` so macOS reuses
  them; SwiftUI and the Firebase SDK repository stay in `Frontend/Apple/iOS/CloudGateway/`. A
  future macOS target supplies its own UI and Firestore adapter against the same AppCore
  contracts.
* **`CloudGatewayMeshRegion` is the region input.** It already carries `regionId`, `displayName`,
  and `enabled`, which is all the derivation needs. A second region model would duplicate the
  Firestore mapper for no gain.
* **Policy is observability-only and counts-and-hashes-only.** iOS reads `Policy/*` and never
  writes it - the collection is Admin-SDK-write in `firestore.rules`. No uid, email, client name,
  address, or key reaches this surface.
* **Failure isolation is one-directional.** Policy is the isolated feed: its failure clears the
  policy rows and shows the collection-level failure card while fresh Regions/Mesh state still
  applies. A Regions or Mesh failure keeps the existing page-level error behavior and does not
  apply a separately completed policy result. Do not add the inverse isolation, which Web does
  not have.
* **A failed Policy read renders its own card, never a grid of "Never synced,"** which would
  assert a fleet state we do not know. An absent entry means never-synced only when the read
  itself succeeded.
* **No policy-only sign-out reset and no standalone policy refresh control.** The view model's
  uid and load-generation guards plus the existing Server Health dismissal cover identity
  changes; pull-to-refresh covers reload.
* **`rowCount` is `Int?` on iOS.** TypeScript `numberOrNull` accepts any finite number, so a
  fractional `rowCount` is "usable" on Web and `unreadable` on iOS; the host only ever writes an
  integer. Coerce with `Int(exactly:)` and never a hand-rolled range check: `Double(Int.max)`
  rounds up to 2^63, so a `value <= Double(Int.max)` guard admits exactly 2^63 and the following
  `Int(value)` traps on it. `updatedAt` likewise accepts only `Date`, because the repository
  converts every `Timestamp` before the mapper runs.
* **Swift status semantics are the final Web semantics** - comprehensive hash agreement among
  enabled regions plus "Last applied" - not the superseded `dataVintage` model. Swift
  `Dictionary` iteration order is unspecified but cannot change the outcome, because a strict
  majority is unique.

## Verification

Two independent layers, and they check different things.

**Offline contract.** `Backend/API/tests/test_bootstrap_contract.py` parses the
`table inet cloudgateway` heredoc in `bootstrap.sh` as text - no `nft` binary, no network, no
host - and ties it to `src/policy.py` in both directions. It enforces the table and chain names,
every object name and kind (set vs map) and declaration text, both address families for every
logical object, the `cg_tunnel4/6` aggregates against `MESH_AGGREGATE_V4/V6`, the chain hook line
`type filter hook forward priority -10; policy accept;`, `ct state established,related accept` as
the first rule, the infra/admin accepts in both directions per family, the mark assignments, the
terminal drops, rule *ordering* (mark assignment and accepts before the drops), that every
`@cg_*` reference names a declared object, that `render_policy_script` flushes every set and map
it owns and never touches `cg_tunnel4/6`, that `render_client_row_script` touches neither
`cg_tunnel4/6` nor `cg_infra4/6`, the `PostUp`/`PostDown` lines, and the `cloudgateway-install-api`
gate strings. Negative tests mutate the heredoc in memory and prove a rename or reorder on either
side fails. It does **not** verify runtime nftables behaviour.

Run it with the API target:

```sh
./scripts/test.sh api
```

**Live host.** Verdict precedence, chain priority against the other forward-hook chains, the
concatenated-set mark comparison, and every reachability outcome are properties of a running
kernel and have no static representation. The full method, the per-flow matrix, and the release
evidence record live in [acl-live-verification.md](acl-live-verification.md). Re-run it when a
new region joins the fleet, a host is rebuilt or its kernel/nftables version changes, the base
ruleset in `bootstrap.sh` is edited, or the policy renderer/parser in `Backend/API/src/policy.py`
changes.
