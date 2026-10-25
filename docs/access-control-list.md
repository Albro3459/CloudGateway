# Account-Scoped ACL: Client-to-Client Isolation

New client-to-client flows over the tunnel require both clients to belong to the same
CloudGateway account. Every regional host enforces this with an nftables filter driven by an
address-to-account map pulled from Firestore. Established and related conntrack traffic is
accepted before the account lookup. The ACL requires no VPN client configuration change.

This is the durable design and operations record. For the live-host verification procedure see
[acl-live-verification.md](acl-live-verification.md); for the reconcile pass in the context of
peer sync see [wireguard-drift-repair.md](wireguard-drift-repair.md#account-scoped-acl-policy-reconcile);
for the external HTTP contract see [api-contract.md](api-contract.md).

## Problem

WireGuard server-side `AllowedIPs` pins each client's source to its `/32` and `/128`. It does
not restrict destinations. Mesh peers carry each remote region's `/24` and `/64`, so the packet
filter must enforce account boundaries on both same-region and cross-region forwarding.
Client-side `AllowedIPs` is routing chosen by the client and cannot enforce this boundary.

## Architectural Decisions

* The tenant is `ownerUid`. Admins have ordinary account-scoped client-to-client access.
* Hosts map addresses to opaque 32-bit account slots, never uids, emails, or client names.
  Slots are allocated once and never reused or hashed from a uid.
* Forwarded infrastructure-to-admin-client traffic is allowed in both directions. This supports
  cross-region admin proxy jumps without granting every account remote infrastructure access.
  Local server access has a separate boundary, described below.
* Every host pulls the same fleet-wide map, keeping policy hashes comparable across regions.
* Propagation is event-driven: client create/delete, boot, and admin Sync All. There is no timer,
  version document, durable queue, or poke retry. A dropped poke waits for the next event or sync.
* Firestore owns desired state. Host status writes are best effort and never change desired state.

## Threat Model

In scope: one account's client reaching another account's client over the tunnel, in the same
region or across the mesh.

The filter only drops traffic that both enters and leaves `wg0` and targets a fleet tunnel
aggregate. Internet egress, the client's own regional server (`INPUT`), that server's traffic to
its local clients (`OUTPUT`), and server-to-server mesh traffic are outside this boundary.
A local server can therefore reach any of its own peers, including through an SSH proxy jump.
Server key custody controls that access. A remote server reaches a client through the target
host's forward chain, where only admin-owned destinations receive the infrastructure exemption.
Removing a client's WireGuard peer prevents it from sending tunnel packets at all. Peer removal
remains necessary alongside the ACL.

## Filter Design

One `inet` table named `cloudgateway`, installed by `wg0`'s `PostUp` from
`/etc/cloudgateway/cloudgateway.nft`. It replaces nothing in the existing `iptables`/`ip6tables`
rules: a `drop` verdict is terminal across tables, so the existing `FORWARD` accepts did not need
reordering or renumbering. The base chain runs at `priority -10`, ahead of the iptables-nft
forward chains at priority 0, so it evaluates first. The release verification exercised the drop
path on live hosts (see [Verification](#verification)).

### Objects

Every logical object is mirrored per address family. The API owns dynamic elements only. It
never creates, deletes, or reorders the table or chain and never writes `cg_tunnel4/6`.

| Object | Kind | Owner | Contents |
| --- | --- | --- | --- |
| `cg_tunnel4` / `cg_tunnel6` | interval set | `bootstrap.sh`, static | The fleet tunnel aggregates, mirroring `MESH_AGGREGATE_V4` / `MESH_AGGREGATE_V6` in `Backend/API/src/wireguard.py` |
| `cg_infra4` / `cg_infra6` | set | reconcile pass | Every region's interface address, derived as network address + 1 of that region's tunnel CIDR |
| `cg_admin4` / `cg_admin6` | set | reconcile pass | Client addresses whose owner holds the admin role |
| `cg_slot4` / `cg_slot6` | map `addr : mark` | reconcile pass | Client address to account slot |
| `cg_pairs4` / `cg_pairs6` | set `typeof <ip> daddr . meta mark` | reconcile pass | One `address . mark` concatenation per client |

`cg_pairs` uses one destination-and-slot lookup with O(n) elements, avoiding a set of every
allowed source-destination pair.

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

1. `ct state established,related accept` accepts existing conntrack traffic before any policy
   lookup. Map refreshes and role changes do not revoke those flows while conntrack still
   classifies them as established or related.
2. Four infra/admin accepts (server to admin-owned client and the reverse, per family), scoped to
   traffic both entering and leaving `wg0`.
3. Two `meta mark set ... map @cg_slot` rules. The mark carries the source's account slot; an
   unknown source does not assign a slot and relies on the packet mark already being 0. These
   assignments are unconditional; only the drop rules that consume the mark are interface scoped.
4. Two terminal drops: if the destination is inside the tunnel aggregate and
   `destination . mark` is not in `cg_pairs`, drop.

Everything else falls off the end and is accepted: egress to the internet, and any traffic not
both entering and leaving `wg0`.

### Consequences worth stating

* **An empty map denies new client-to-client flows.** That is the correct boot state. The rules
  are installed by `PostUp` and populated by the first pull. A policy-only failure leaves
  internet egress outside the ACL, although peer restoration still depends on a successful
  Firestore sync. The static `cg_tunnel4/6` sets make unknown in-aggregate destinations drop.
* **Slot 0 is reserved and never assignable.** An unmarked packet's mark defaults to 0, meaning
  "unknown source". `policy.MIN_SLOT` / `MAX_SLOT` and
  `repository.MIN_ACCOUNT_SLOT` / `MAX_ACCOUNT_SLOT` are the 32-bit mark range and must always
  agree; a test asserts the two pairs never drift.
* **A non-admin client reaching another region's server interface address is dropped**, because
  infra addresses are inside `cg_tunnel` and are not in `cg_pairs`. This is intentional. Local
  server access is unaffected because it is `INPUT`, not `FORWARD`.
* **The chain assumes packet marks arrive as 0, no other subsystem uses them, and no
  `ip rule fwmark` exists.** The source-map rules do not explicitly clear marks. Revisit mark
  ownership and masking before adding another mark consumer. The release verification found
  no other mark use.
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
  and v6 independent. Chain rules and counters are outside the hash, so agreement does not
  replace inspecting the base ruleset.

## Firestore Model

```text
Users/{uid}
  accountSlot          number, allocated once from Counters/accountSlots, never reused

Counters/accountSlots
  nextSlot             number, monotonic allocation watermark
  updatedAt

Regions/{regionId}
  tunnelIndexV4        number, per-region client-address allocation cursor with wrap
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

Status comes from live nftables read-back. Hashing the desired snapshot would hide apply drift.
The hashes cover all five named policy sets/maps per family, so changes to admin membership
affect the hashes on the next successful apply, read-back, and status write.

The fleet pull uses an unfiltered `collection_group("Instances")` read, with active-status and
non-empty-public-key filtering in the API, so it needs no new composite index. Admin membership
comes from a `UserRoles` read joined in the API.

### Account slot allocation

Allocation is once per account, inside a Firestore transaction, at user provisioning; client
reservation carries the same allocation as a fallback for an account whose `Users` document
predates a slot. `Counters/accountSlots.nextSlot` is the sole allocation authority. Only a valid
counter allocates, and only when it is strictly above every valid assigned slot. Missing,
malformed, regressed (at or below a live slot), and exhausted counters all raise
`AccountSlotUnavailableError` (`ACCOUNT_SLOT_UNAVAILABLE`, HTTP 500) rather than being
re-derived.

Client reservation exposes that error directly. The Firestore-backed `POST /users`
provisioning path wraps allocation failures as `FIREBASE_WRITE_FAILED` and attempts Auth
rollback. Both paths require recovery of the authoritative counter before retrying.

The allocating transaction reads the whole `Users` collection, but only to disprove a regressed
counter - never to reconstruct one. Account deletion hard-deletes `Users/{uid}` along with its
`accountSlot`, so a deleted account's slot exists nowhere in live data; re-deriving a counter
from live users would re-issue it and merge two accounts onto one nftables tenant. Seeding the
counter was a one-time pre-activation step, run once by the release-scoped backfill migration
before enforcement; after activation a lost counter is restored from backup, with provisioning
failing closed until then.
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

Each region document carries paired allocation cursors (`tunnelIndexV4`/`tunnelIndexV6`),
advanced in the same transaction as `reserve_client`:

* Take the next index, wrap at the top of the host range, and skip any index currently in use.
* The host range is `2 .. num_addresses - 2` of the region's v4 network, 253 indices for a `/24`,
  so the wrap is a real event after roughly 253 lifetime allocations, not a theoretical one. The
  in-use check on wrap is load-bearing and must not be treated as dead code.
* The v4 network bounds the shared index. Both families use that index and wrap together,
  even though the IPv6 `/64` has room for more addresses.
* Index-to-address recovery is best effort in both directions: either of a client's two addresses
  alone reserves its index, and a malformed or out-of-network stored address is skipped rather
  than raised, so one bad row cannot block every future allocation.
* No `releasedAt` field and no time-based TTL. With `region_capacity_limit` at 20, incrementing
  gives roughly 230 allocations of distance before an address returns, and every one of those
  allocations is itself a poke that would have corrected a stale row.

`Regions/{regionId}.tunnelIndexV4/V6` are allocation cursors that advance with wrap. Deletion
never resets them. Do not lower them manually or restore an older cursor independently of client
state.

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
* **`PolicyCoordinator.request()` runs in a response background task.** A request during an
  active pass sets the pending bit and returns; otherwise that worker drains the passes. Pass
  failures are logged and swallowed. `run_blocking()` is the admin variant: it waits for the
  coordinator to quiesce and returns an outcome from a pull started after the call. Sustained
  pokes can extend that wait, because coalescing bounds backlog rather than total work.

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
leg is blocking so the admin gets a completed policy outcome when the peer/mesh pass succeeds;
a policy failure is logged and flips `policyApplied` to false but never fails the endpoint and
never affects the peer/mesh fields.

A successful apply can still leave the status document stale if its best-effort write fails.
A peer/mesh failure returns before the policy leg. The response carries `policyApplied`,
`policyRowCount`, and `policyStatusWritten`, with the two optionals omitted on policy failure.
Older regions can omit all three; dashboards treat that as unknown.

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

A trusted out-of-band edit to `UserRoles/{uid}` needs an immediate Sync All Regions. There is
no role-change API or automatic role propagation. Until sync, hosts retain the previous admin
allow-set; existing conntrack flows can also outlive a map change.

## Account Deletion

`DELETE /account` uses a dedicated cleanup sequence and owns propagation for the whole account,
so no per-client delete fans out its own poke:

1. Snapshot the account's clients and remove their local and remote WireGuard peers. Remote
   removal runs in account-cleanup mode.
2. Fence every one of the account's client documents non-active fleet-wide by `ownerUid`, in one
   trusted repository operation, including clients whose regional host was unreachable in step 1.
   Any policy pull started after this fence excludes the account, because it is keyed by owner,
   not by which region answered. `CREATING` documents are fenced too, so a concurrent
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

Server Health on Web and iOS shows each region's policy row count, comprehensive IPv4 and
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
* Full refreshes replace dynamic contents atomically with one `nft -f -` load. Client create
  also has the additive local-row fast path described above.
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

For a fleet predating the ACL, the supported activation sequence is to destroy and rebuild every
region through `./scripts/terraform.sh` from one deploy tag. This is a destructive rollout,
not routine API maintenance. Sequential rebuilds leave a partial-enforcement window. Treat
fleet activation as complete only after the last region finishes.

### Legacy account migration (completed)

Every provisioned account needs `Users/{uid}.accountSlot` before any region enforces: an account
with no slot is skipped by `desired_policy()`, drops out of every map, and loses its own
same-account connectivity the moment enforcement begins. A release-scoped backfill migration
assigned slots to every legacy account, seeded the counter strictly above every slot assigned
anywhere (including orphaned `Users` documents), and gated the rollout behind a fleet-wide
preflight applying the same row-validation rules, so known-bad data blocked the rollout instead
of silently dropping rows on the first host that enforces. It ran before the fleet was rebuilt
with enforcement on and has been removed; the script and its runbook are in git history at
`releases/access-control-lists/`.

Provisioning has allocated a slot per account since, so this is only relevant again if a Firestore
restore ever reintroduces accounts that predate slots - in which case recover the script from git
history rather than re-deriving the counter from live users.

## Accepted Risks and Out of Scope

* A dropped poke leaves a region stale until the next fleet-wide client event or an admin Sync
  All. No timer, no retry, no durable queue.
* Account deletion sends one deliberate best-effort refresh wave. An unreachable region can
  retain an orphaned peer and stale policy until its next boot or manual sync.
* A user racing their own account deletion from a second device can orphan a peer if a client is
  created between the step 1 snapshot and step 4. Both the fence and hard delete re-query,
  excluding its document from future policy pulls. Existing host state can remain until sync;
  `cloudgateway-sync-peers` removes the peer on its next run. Creation after step 4 fails outright.
* Any regional host can reach admin-owned clients fleet-wide. Locally this was already true via
  `OUTPUT`; this extends it across the mesh, knowingly, to support admin proxy jumps.
* The boot unit re-pulls every 30s while policy keeps failing. Empty boot maps deny new
  peer-to-peer flows. Atomic apply failure retains the prior map; read-back failure can follow
  a successful apply and still leave status unchanged. Investigate persistent retries.
* Per-region map scoping, group or family sharing, and a periodic reconcile timer are out of
  scope. The version-document poll considered during design is rejected as unnecessary given
  event-driven propagation.

## Settled Decisions: Do Not Reintroduce

The contracts above are the reference: preserve rebuild-only activation on pre-ACL hosts,
API ownership of dynamic elements only, full fleet snapshots inside the policy flock, depth-1
coalescing, never-reused account slots, all-participant collision exclusion, and comprehensive
live-policy hashes. Timestamp age, `dataVintage`, and process-local `appliedSequence` values
cannot establish fleet agreement and must not replace hashes.

### Apple client surface

Web and iOS provide Server Health. The macOS menu app and CLI use the shared account/client
core, but account and admin management remain on the site or mobile app. There is no native macOS
Server Health page.

Models, mapping, status derivation, and the Server Health view model live in `CloudGatewayAppCore`.
SwiftUI stays in the iOS target. Keep the Swift policy derivation in sync with
`Frontend/Web/src/helpers/policyHelper.ts` and reuse `CloudGatewayMeshRegion` as its region input.

* `Policy/*` is read-only observability: counts, hashes, and timestamps, with no client identity,
  address, or key. A collection read failure clears policy rows and shows its own failure card.
  It must not fabricate a grid of never-synced rows or prevent fresh Regions/Mesh state applying.
  Regions/Mesh failures keep the page-level error behavior and do not apply a separately
  completed policy result.
* The shared view model clears all account-scoped state on an auth identity change and when the
  iOS view reports loss of the admin role. Session and load-generation guards reject stale work.
  Policy uses the page's existing refresh controls.
* Swift `rowCount` is `Int?`, mapped with `Int(exactly:)`. Web accepts any finite number, so a
  fractional value is usable there but unreadable in Swift. Hosts write integers. The Swift
  mapper accepts `Date` after the repository converts Firestore timestamps.

## Verification

`Backend/API/tests/test_bootstrap_contract.py` checks the bootstrap heredoc against the API's
nftables contract without running `nft`: names and object kinds, aggregates, rule order, renderer
ownership, `PostUp`/`PostDown`, and the installer gate. Negative cases mutate the text to catch
renames and reordered rules. This does not verify kernel behavior.

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
