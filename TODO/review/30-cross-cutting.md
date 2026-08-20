# X-1: Cross-Cutting Seam Review (shared-subnet ↔ access-control-lists)

Runs after the per-chunk passes and builds on their findings. Scope is the seam
between the two stacked PRs, not the internals of either.

## Focus

- [x] Mesh subnet-width `AllowedIPs` vs the nftables account boundary
- [x] Address-allocation change (mesh) vs account-slot addressing (ACL)
- [x] Lock interaction between the WireGuard lock and the policy lock
- [x] Boot / bring-up ordering across `bootstrap.sh`, wg PostUp, API startup, policy sync
- [x] Threat-model gaps neither PR covers alone
- [x] Contradictions or duplicated logic between the two PRs' client surfaces

## Findings

(appended incrementally below)

### [P2] A reused account slot can grant temporary cross-account nftables authorization on any host that hasn't resynced since the reuse
- **Location:** `Backend/API/src/firebase.py:1089-1126` (`_allocate_account_slot`) + `Backend/API/src/repository.py:343-399`
  (`next_account_slot` recovery path) — the slot-reuse mechanism ACL-B flagged P2 and ACL-E flagged P1 (same
  defect class, see those docs) — combined here with the fleet-wide, per-host-independently-refreshed policy
  pull in `Backend/API/src/policy_sync.py:88-182` (`desired_policy`) and `Infrastructure/OCI/host/bootstrap.sh:169-195`
  (`cg_slot4`/`cg_pairs4`, host-local nftables state).
- **Failure:** ACL-B/ACL-E already established that a hard-deleted account's slot can be reissued to a new
  account (via `Counters/accountSlots` corruption on the runtime path, or unconditionally on the backfill
  script's primary path). Neither of those chunk docs traces the consequence through to the host filter,
  which is the actual authorization boundary — that's the seam this pass covers. Concretely: Account A holds
  slot 12 and is hard-deleted (`hard_delete_account_documents`, `firebase.py:381-401`, removes `Users/A`,
  `UserRoles/A`, and every `Instances` doc it owns). A region host `R-stale` last ran `reconcile_policy`
  *before* A's deletion and still has A's old `(address_A, mark=12)` rows in its live `cg_slot4`/`cg_pairs4`
  (nftables state is a full-replace snapshot per pass — `policy.py`'s `apply_map` — but only as of whenever
  that host's *own* last pass ran; there is no fleet-wide push, only per-host pull). Slot 12 is later reissued
  to new Account B (the ACL-B/ACL-E bug). `R-stale` has not yet re-synced (e.g. it was unreachable during the
  fan-out poke in `routes.py:479-483`/`519-523` — an already-accepted risk per `routes.py:501-507` — or it
  simply hasn't had its next scheduled/triggered pass). If `A`'s freed tunnel address (`address_A`) is
  separately reused by `next_tunnel_index` (a normal, *intended* event, not a bug — see Focus 2) for a client
  of a third account C, or if B's own client traffic transits `R-stale` as a mesh hop, `R-stale`'s stale
  `(address_A, 12)` row and the live-elsewhere-correct `(address_B_client, 12)` rows are simultaneously
  authorized on that one host under the same mark, even though Firestore (and every already-resynced host)
  correctly reflects only B ↔ 12. Concretely, a client that presents `address_A` as its source on `R-stale`
  (e.g. if C's client happens to transit `R-stale`, or a residual/racing packet from A's teardown window)
  gets marked `12` and is then authorized against every current slot-12 (Account B) destination pairing on
  that host — a genuine, if narrow and timing-dependent, cross-account authorization, not merely a Firestore
  bookkeeping inconsistency. This is a materially different (and more severe) consequence than either ACL-B
  or ACL-E described: they characterized the bug as "the same slot number gets handed to two identities";
  this finding shows it can become "two identities are simultaneously and transparently authorized against
  each other on any host that hasn't caught up," for as long as that host's staleness window lasts.
- **Reachability note (why P2, not P1/P0):** this requires the underlying slot-reuse bug to have already
  fired (itself narrow: counter corruption on the runtime path, or the migration script's documented primary-
  path bug — both independently flagged, both requiring an unusual precondition: a hard-deleted
  highest-slot account), **and** a host that hasn't resynced across the reuse boundary. Neither condition is
  reachable in ordinary steady-state operation without one of the already-flagged bugs firing first, so this
  is best read as an *impact clarification* of ACL-B's P2 / ACL-E's P1 rather than a new independent defect —
  but it is the concrete reason slot reuse is a boundary-severity issue and not just an identity-bookkeeping
  one, which is what the handoff asked this pass to determine.
- **Fix:** fixing ACL-B's P2 / ACL-E's P1 at the source (never let a valid stored counter be undercut by a
  live scan that can't see hard-deleted docs — see those docs' fix suggestions) closes this consequence too,
  since slot values would then truly never be reused. No additional seam-specific mitigation is needed beyond
  that; the per-host staleness window itself (bounded by `routes.py:501-507`'s already-accepted "unreachable
  region" risk) is not new and is not proposed for change here.

## Clean (no findings)

### Focus 5 (remainder): Threat-model gaps neither PR covers alone
- **Region-as-trusted-infrastructure boundary is unchanged by mesh, not expanded:** considered whether mesh's
  subnet-wide `AllowedIPs` lets a compromised/malicious region operator forge traffic sourced as another
  region's client to reach a third client fleet-wide. It cannot: WireGuard's cryptokey routing rejects an
  inbound packet whose source address isn't within the *sending peer's* configured `AllowedIPs`
  (`_validate_mesh_peer`/`_validate_mesh_network`, `wireguard.py:875-970`, confirmed under Focus 1 — each
  mesh peer's `AllowedIPs` is exactly and only that region's own `/24`/`/64`). A malicious region can only
  ever originate traffic sourced from addresses within its *own* subnet — i.e. it can impersonate clients it
  already terminates the real WireGuard tunnels for, which is a pre-existing trust assumption ("a region is
  trusted infrastructure for its own locally-connected clients") that predates both PRs, not a new capability
  either PR introduces. What mesh *does* newly expose is that this pre-existing local-impersonation capability
  now has fleet-wide reach (a compromised region's own client can now reach other regions' clients of the
  same account, whereas pre-mesh it could only reach same-region peers) — but that reach is still gated by
  the *same account's* slot pairing the ACL PR enforces; it does not let a compromised region cross into a
  *different* account's traffic without also exploiting the slot-reuse class of bug above.
- **`reconcile_policy`'s multiple un-batched Firestore reads** (`list_admin_uids`, `list_account_slots`,
  `list_policy_clients`, `list_regions` — `policy_sync.py:101-173`) are not wrapped in a single transaction/
  snapshot, so a slot could in principle be allocated between the `list_account_slots` read and the
  `list_policy_clients` read. Traced the consequence: `desired_policy` fails closed on any owner with no
  valid slot at the time of *its own* read (`policy_sync.py:126-130`, "an owner with no valid slot is skipped,
  never defaulted") — worst case is a newly-created client is skipped for one pass and picked up on the next
  poke/boot, never a spurious authorization. Not a threat-model gap.

### Focus 6: Contradictions or duplicated logic between the two PRs' client surfaces — CLEAN
- **`Frontend/Web/src/helpers/policyHelper.ts` vs `Frontend/Web/src/helpers/meshHelper.ts`:** read both in
  full. They are structurally parallel (both key a `Map<regionId, Doc | null>`, both have a "usable/pending"
  gate, both render into the same `ServerHealth.tsx` page) but model genuinely different domains: `meshHelper.ts`
  computes **bilateral per-link** state between region pairs (`MeshLinkStatus`: `both-applied`/`one-sided`/
  `not-synced`/`stale`, `meshHelper.ts:123-125`, `283-347`) plus a 24h staleness threshold
  (`MESH_STALE_THRESHOLD_MS`, `meshHelper.ts:403-405`), while `policyHelper.ts` computes **fleet-wide hash
  consensus** across all regions (majority-vs-drift, `policyHelper.ts:60-92`) with no staleness/time
  component at all (ACL-D's parity matrix already notes this omission is deliberate and symmetric on iOS).
  These are appropriately separate algorithms for separate authorization models (peer-to-peer link agreement
  vs fleet-wide map agreement), not duplicated logic that should be consolidated — and they already share
  what *is* common (the `dateOrNull`/`stringOrNull` coercion primitives live once in `coerce.ts` and both
  helpers import from there, `policyHelper.ts:15`). No contradiction in the derived states either: a region
  can independently be `mesh: stale` and `policy: ok` (or vice versa) without either page's copy implying the
  other, since the two panels render from separate `*DocsById` maps under the same page-level generation
  guard (confirmed clean by ACL-D for the policy side; SS-B's own pass covered the mesh side).
- **Apple side:** `CloudGatewayPolicyStatus.swift`/`CloudGatewayFirestorePolicyMapper.swift` (ACL) and the
  mesh-side mapper/view-model code (SS-C's scope) follow the identical split — verified no shared mutable
  state or cross-import between the two beyond the same `CloudGatewayServerHealthViewModel`'s single
  generation counter, which both legitimately participate in (already validated by ACL-D).
- **No duplicated logic found that risks silently diverging** beyond the already-flagged, independently-owned
  `Int(Double)` conversion-trap instance in the *mesh* Swift mapper (`12-ss-apple.md`, out of this chunk's
  scope, already fixed on the ACL side per ACL-D's matrix) — that is a within-PR inconsistency already on
  record, not a cross-PR contradiction.

### Focus 1: Mesh subnet-width `AllowedIPs` vs the nftables account boundary — CLEAN
- **Verified:** `Backend/API/src/wireguard.py:45-46` defines `MESH_AGGREGATE_V4 = "10.0.0.0/16"` /
  `MESH_AGGREGATE_V6 = "fd42:42:42::/48"`. `_validate_mesh_network` (`wireguard.py:875-883`)
  rejects any mesh peer's `allowed_network_v4/v6` that is not exactly a `/24`/`/64` **and**
  not `is_subnet_of(network, aggregate)` for that same constant. `Infrastructure/OCI/host/bootstrap.sh:171-172`
  installs `cg_tunnel4 { elements = { 10.0.0.0/16 } }` / `cg_tunnel6 { elements = { fd42:42:42::/48 } }` —
  the literal values match the Python constants byte-for-byte, and `Backend/API/tests/test_bootstrap_contract.py`
  (owned by ACL-A, cross-checked here) parses bootstrap.sh's source text directly and pins this, with a
  negative-mutation test proving a drift would fail the build. Since every mesh peer's `AllowedIPs` is a
  region's own tunnel `/24`/`/64`, and that CIDR is validated at registration time to fall inside the exact
  same aggregate the nftables `cg_tunnel4/6` sets enforce (`policy.py`'s `POLICY_TABLE`/`cg_forward` reads
  those same sets back for its hash, never writes them), routing can never carry a destination the filter
  doesn't also recognize as "tunnel scope, subject to the pairs check." `_validate_mesh_peer` (`wireguard.py:952-970`)
  additionally rejects a mesh candidate that overlaps the local host's own tunnel network or another mesh
  candidate, so cryptokey routing ambiguity (already reviewed clean by SS-A) can't create an address the
  local filter would misclassify either.
- **Mechanism double-checked:** `cg_forward`'s pairing rule (`bootstrap.sh:188-190`) sets `meta mark` from
  `ip saddr map @cg_slot4` (the packet's *source* client's own slot), then drops unless
  `(daddr, mark) ∈ cg_pairs4`. `policy.py:350-353` (`render_client_row_script`) adds `cg_pairs4 { address . slot }`
  per client row — i.e. each client is paired with *its own* slot, not a per-pair tuple. Because both ends of
  an account share one slot, this is symmetric in both directions (A→B and B→A each independently resolve
  correctly) without needing a cross-product of every pair. Traced this by hand for the two-hop cross-region
  case (client A, region R1 → mesh peer → region R2 → client B): the packet transits `cg_forward` with
  `iifname wg0 oifname wg0` at **both** R1 (local egress toward the mesh peer) and R2 (mesh ingress toward
  local client B) — this is the "double transit" ACL-C flagged (see handoff resolution below) — and both
  hops must independently authorize since either one dropping ends the flow.
- **Conclusion:** the filter fully contains what mesh routing now permits; no gap between subnet-width
  `AllowedIPs` and the nftables account boundary.

### Focus 2: Address-allocation change (mesh) vs account-slot addressing (ACL) — CLEAN
- **Verified:** the two allocation axes are orthogonal and don't share an ID space.
  `next_tunnel_index` (`repository.py:295-318`) is a **per-region** monotonic index into that region's own
  `/24`/`/64` (`region_tunnel_index_bounds`), wraps after ~253 lifetime allocations, and explicitly reuses a
  freed index once its owning client is gone (`next_tunnel_index`'s own docstring: "the in-use skip after a
  wrap is what stops a still-live client's address from being handed out twice" — a *dead* client's address
  is fair game). `next_account_slot` (`repository.py:343-399`) is a **fleet-wide** monotonic counter with an
  explicit "never reused" invariant (`repository.py:71-73`, `343-350`) and no wraparound. One produces a
  routing identity (which /32 a client answers to on the wire); the other produces an authorization identity
  (which nft mark a client's traffic carries). Nothing in `policy_sync.desired_policy` or `wireguard.py`
  derives one from the other, and `PolicyRow` carries both independently (`address_v4`/`address_v6` from the
  tunnel-index axis, `slot` from the account-slot axis).
- **Mesh interaction specifically:** because mesh peer `AllowedIPs` are whole region subnets (not
  per-client `/32`s — confirmed under Focus 1), a client's tunnel-address reuse (a normal, frequent event
  per the wraparound design) needs **no** mesh peer/WireGuard reconfiguration at all; the already-installed
  mesh peer's `AllowedIPs` already covers the reused address. So address-index churn is invisible to mesh
  routing, and mesh routing changes don't touch tunnel-index allocation. The only place the two axes
  interact is exactly the scenario written up under Focus 5 below (address-index reuse landing on a stale
  host at the same time as a slot-reuse bug fires) — that's a real finding, but it's a *slot*-identity bug's
  consequence, not a flaw in the address/slot separation itself.
- **Conclusion:** no interaction bug between the mesh address-allocation change and account-slot addressing.

### Focus 3: Lock interaction between the WireGuard lock and the policy lock — CLEAN
- **Verified independently of ACL-A's own lock-separation note** (which covered `routes.py`'s create/delete
  paths): `Backend/API/src/sync.py:399-410` (`run_sync`, the mesh+client peer sync pass) acquires and fully
  releases `wireguard.lock()` inside its own `with` block, returning an `outcome` before `main()`
  (`sync.py:573-655`) ever calls `reconcile_policy(...)` at `sync.py:635`, which acquires `policy.lock()`
  separately. The two locks are never held concurrently by the same call stack in the boot/manual-sync path
  (`cloudgateway-sync-peers` → `main()` → `run_sync()` *then* `reconcile_policy()`, strictly sequential, not
  nested). `Backend/API/src/routes.py:197` (`create_client`) takes `wireguard.lock()`, adds the peer, and the
  `with` block closes before `_write_inline_policy_row` (`routes.py:984-1017`) takes `policy.lock(blocking=False)`
  at line 1016 — confirmed by reading the intervening code, not just trusting ACL-A's note. `wireguard.py`
  has zero references to the `policy` module and vice versa's `policy.py`/`policy_sync.py` have zero
  references to `wireguard.lock()` (only import `is_valid_tunnel_ip`/`MESH_AGGREGATE_V4/V6`, pure functions).
  No lock-ordering inversion, no nesting, no path that reads policy or wireguard state outside the lock that
  guards it.
- **Conclusion:** no deadlock or ordering-inversion risk between the two locks anywhere in the seam.

### Focus 4: Boot / bring-up ordering — CLEAN (fail-closed throughout)
- **Traced the full boot sequence:** `Infrastructure/OCI/host/bootstrap.sh:212` — `PostUp = nft -f
  /etc/cloudgateway/cloudgateway.nft` is the **first** `PostUp` line, so the `cg_forward` table (with empty
  `cg_infra4/6`, `cg_admin4/6`, `cg_slot4/6`, `cg_pairs4/6`) is loaded before `wg-quick up` even finishes
  bringing the interface up; `wg-quick` treats a `PostUp` failure as fatal and tears the interface back down
  (confirmed by ACL-C, re-verified here), so "interface up" implies "filter table loaded" as a hard
  invariant, not a race. `cloudgateway-sync-peers.service` (`bootstrap.sh:813-829`) — the only thing that
  ever adds a peer (client or mesh) to the interface — has `After=network-online.target
  wg-quick@$WG_INTERFACE.service`, so no peer can be added before that `PostUp` has already run. There is no
  boot ordering in which peers exist on the wire before the (empty, fail-closed) filter table exists.
- **The remaining window is intra-process, not intra-boot:** `sync.main()` runs `run_sync()` (adds/updates
  peers under `wireguard.lock()`) and *then* `reconcile_policy()` (populates `cg_slot`/`cg_pairs` under
  `policy.lock()`) sequentially in the same process invocation (see Focus 3). Between those two calls, a
  newly-added client or mesh peer is live on the interface (WireGuard will decrypt/route for it) but not yet
  represented in `cg_slot4/6`/`cg_pairs4/6`. This is the literal answer to "what is the filter state in that
  window": **still fail-closed**. `meta mark set ip saddr map @cg_slot4` (`bootstrap.sh:188`) leaves the mark
  unset (0, `MIN_SLOT` reserved per `policy.py:36-37`) for any source address not yet in the map, and an
  unset mark can never appear in `cg_pairs4` (built only from valid slots ≥ `MIN_SLOT`), so `ip daddr
  @cg_tunnel4 ip daddr . meta mark != @cg_pairs4 drop` (`bootstrap.sh:190`) drops it. The same reasoning
  applies to the very first ever sync pass: `cg_infra4/6`/`cg_admin4/6` are also populated only by
  `reconcile_policy`, so infra/admin traffic is denied too until the first successful policy pass, not just
  client-to-client.
- **Answering the checklist question directly: can a client route traffic across the account boundary
  during this window? No.** Every state this window can be in is either "not yet paired" (drop) or "same as
  before this pass started" (whatever the last successful policy apply produced) — there is no state in
  which a *newly*-live peer gains unpaired cross-account reachability, because the default for "not yet in
  the map" is deny, not allow. The inline per-client path (`create_client`) reinforces this: the WireGuard
  peer is added first, then the policy row (Focus 3), and until that row lands the new client's own traffic
  is unmarked (denied outbound) and no one else can reach it either (it has no `cg_pairs4` entry as a
  destination).
- **Conclusion:** no window, at boot or at runtime, where the filter is more permissive than intended;
  every gap fails closed.

## Handoffs from per-chunk reviewers

Context passed forward by earlier chunks. Resolve or confirm each in this pass.

### From ACL-C (`22-acl-infra.md`)
- **Cross-region mesh traffic transits `cg_forward` twice.** WireGuard-forwarded
  packets re-enter `wg0` on both `iif` and `oif`, so cross-region client-to-client
  traffic also traverses the *local* region's forward chain. ACL-C resolved this as
  not-a-bug because every region's policy map is built from a fleet-wide
  client/account snapshot rather than a region-local one — but that resolution
  depends on the snapshot actually being fleet-wide on every region at all times.
  Verify that invariant at the seam, including what happens when one region's
  policy sync lags or fails while another region's does not.
- **nft semantics unverified on a real host.** `docs/wireguard-drift-repair.md`
  self-discloses that nft verdict precedence, the priority `-10` ordering vs the
  legacy iptables rules, and the concatenated-set drop syntax have **not** been
  verified on a real host. This is the single largest pre-deploy risk the ACL PR
  carries, and it is not something static review can close.

**Resolution:** Confirmed at the code level (not just the docs level ACL-C checked). `desired_policy`
(`policy_sync.py:88-182`) makes every one of its reads fleet-wide and unfiltered by region —
`list_policy_clients` streams `collection_group("Instances")` across the whole fleet
(`firebase.py:744-765`), `list_account_slots` streams all of `Users` (`firebase.py:767-775`),
`list_regions` returns every region doc (`firebase.py:139-...`). So "every region's policy map is
built from a fleet-wide snapshot" is true as a *construction* invariant on every call. It is **not**
true as a real-time invariant: each host's live `cg_slot4/6`/`cg_pairs4/6` is only as fresh as that
host's own last successful `reconcile_policy` pass — there is no fleet-wide push, only independent
per-host pulls under each host's own `policy.lock()`. When one region's sync lags or fails, that
region's forward chain evaluates a *stale* fleet snapshot, not a wrong-shaped one. The code already
identifies and accepts this exact risk for account deletion — `routes.py:501-507` explicitly documents
"a region that never answers in step 1 or step 3 keeps an orphaned peer and a stale policy row until
its next boot or a manual cloudgateway-sync-peers" as a preserved, accepted risk from a prior review
finding — so this is not a new gap, and the double-transit property is actually a mitigant, not a
weakness: cross-region client-to-client traffic must independently pass **both** the source and
destination region's forward chains, so a single lagging region's stale (too-permissive) row is
insufficient on its own unless the *other* hop is also stale in the same direction. The one place this
staleness class becomes a genuine boundary concern (not just a delayed-convergence one) is documented
above as the new P2 finding (slot reuse + stale host). Second bullet (nft semantics unverified on a
real host): confirmed this remains true and is explicitly out of reach for static review — carrying it
forward unchanged as the largest pre-deploy risk, per ACL-C's own framing.

### From ACL-A (`20-acl-policy.md`)
- P2 `_infra_address` degenerate-CIDR gap (`policy_sync.py:53-74`) checks the
  computed infra address against the fleet-wide mesh aggregate but not against the
  region's own declared CIDR — relevant to the mesh↔ACL addressing seam.

**Resolution:** Confirmed the finding stands, but the seam narrows its practical reachability
considerably. The *only* writer of a `RegionDoc`'s `tunnelNetworkV4`/`tunnelNetworkV6` field is
`upsert_region` (`firebase.py:144-...`, `167`), which is only ever called with a `RegionRegistration`
built by `build_registration` (`register.py:94-118`), which validates through
`validate_local_tunnel_settings` (`wireguard.py:855-872`) — a function the *mesh* PR added/wired in
specifically so a region can't register a tunnel network that later fails host-side validation
(per SS-A's own "Clean" note on `register.py`). That function rejects anything whose prefix length
isn't exactly `/24` (v4) or `/64` (v6) (`wireguard.py:866-867`), so a degenerate `/32` region CIDR can
never enter Firestore through the normal registration flow, including idempotent re-registration. The
gap ACL-A found is therefore reachable only via direct Firestore document manipulation bypassing the
API entirely (the same "trusted operator with Firestore console access" precondition as ACL-B's slot-
corruption P2) — real defense-in-depth worth having, but not reachable through any code path either PR
exposes. Severity/fix recommendation from ACL-A stands unchanged; this is additional reachability
context for the summary, not a reason to close it.

### From ACL-B (`21-acl-api.md`)
- P2 account-slot counter-recovery path can reissue a hard-deleted account's slot
  (`firebase.py:1089-1126`, `repository.py:343-404`). Slot reuse is the ACL
  boundary's identity primitive — check what a reused slot means for stale nft set
  elements and for mesh addressing.

**Resolution:** Traced through to the host filter — see the new `[P2]` finding above ("A reused
account slot can grant temporary cross-account nftables authorization on any host that hasn't
resynced since the reuse"). For mesh addressing specifically: tunnel-address reuse (the mesh-adjacent
axis) is orthogonal and not implicated on its own (see Focus 2) — mesh peer `AllowedIPs` are whole
subnets, so address-index churn needs no peer reconfiguration and isn't a leak vector by itself. The
compounding risk is slot reuse (an *account identity* bug) landing on a stale per-host nftables
snapshot (a *staleness* condition each host already has for independent reasons), which together can
briefly and transparently authorize the reused-slot's new account against residual rows from the old
one on any host that hasn't resynced past the reuse point. Treated as an impact clarification of
ACL-B's P2 (same defect class as ACL-E's P1, per that handoff), not a separate defect.

### From ACL-E (`24-acl-migration.md`)
- **P1 backfill/runtime allocator divergence.** `compute_plan()`
  (`releases/access-control-lists/backfill_account_slots.py:180`) derives its
  new-slot floor from a live `Users` scan only, while the runtime
  `next_account_slot()` (`Backend/API/src/repository.py:373`) trusts a valid stored
  counter directly. Strictly more reachable than ACL-B's P2: it fires on the
  migration's *primary* path whenever a valid counter sits above the live max
  because of a hard-deleted account. Same root cause as ACL-B's P2 — hard-deleted
  `Users` docs are invisible to a live scan — so treat the two as one defect class
  in the summary.

**Resolution:** Confirmed as one defect class with ACL-B's P2, per instruction — both are "a live scan
that can't see hard-deleted `Users`/`Instances` docs undercuts a trustworthy stored counter," differing
only in which code path (runtime recovery vs. migration primary path) triggers it. The seam contributes
the missing piece both per-chunk docs stopped short of: what slot reuse actually *does* downstream, once
it reaches the nftables layer — written up as the new `[P2]` finding above. Migration-specific severity/
fix recommendations are left to ACL-E's own doc per the ground rules (no new findings about migration
sequencing from this pass); this resolution only adds the runtime/host-filter consequence.

### From SS-A (`10-ss-api.md`)
- P2 route-reconciliation failure in `wireguard.py:474-605` bypasses the
  partial-progress log and can discard an earlier mesh-peer apply error. Relevant
  to the seam: a silently-dropped mesh apply error means host state can diverge from
  Firestore without the policy layer knowing.

**Resolution:** Checked the actual seam impact and it's narrower than the "policy layer doesn't know"
framing suggests. `sync.main()` (`sync.py:573-655`) calls `run_sync()` first and returns
`EXIT_PEER_SYNC_FAILED` immediately on *any* exception from it (`sync.py:596-605`), **before** ever
reaching the `reconcile_policy()` call at `sync.py:635` — so a policy pass is already unconditionally
skipped whenever wireguard sync fails for *any* reason, regardless of whether the specific failure is
the swallowed mesh-peer-apply error or the route-reconciliation error that swallowed it. This "peer-
failure-skips-policy" behavior is itself deliberate and already tested (ACL-B's doc: "full success,
policy-after-peer-success failure, peer-failure-skips-policy"). So the SS-A bug's seam consequence is
observability only (which specific error gets logged/reported for that failed pass) — it does not
change *whether* the policy pass runs, and it does not leave nftables in a more-permissive state
(fail-closed default, unaffected by which error triggered the skip). SS-A's P2 severity is correct as
scoped to `wireguard.py`; the seam does not elevate it.

## Summary

All six focus items resolved; one new finding, all five handoffs resolved.

**1 finding, P2:** "A reused account slot can grant temporary cross-account nftables authorization on
any host that hasn't resynced since the reuse" — the seam-level consequence of the ACL-B P2 / ACL-E P1
slot-reuse defect class, traced through `policy_sync.py`'s per-host, pull-based (not pushed) fleet
snapshot to the live `cg_slot4/6`/`cg_pairs4/6` nftables state. Requires the underlying slot-reuse bug
to have already fired (itself narrow) plus a stale, not-yet-resynced host, so it's an impact
clarification of already-flagged findings rather than an independently reachable new defect — but it is
the concrete reason slot reuse is boundary-severity, not just a bookkeeping inconsistency.

**No P0/P1 findings.** The single most important question this pass was asked — does the nftables
account boundary actually contain what mesh's subnet-wide `AllowedIPs` now permits — is answered yes:
every mesh peer's `AllowedIPs` is validated at apply time to be a `/24`/`/64` strictly inside the same
`MESH_AGGREGATE_V4`/`V6` aggregate that bootstrap.sh's `cg_tunnel4`/`cg_tunnel6` sets enforce, and that
correspondence is pinned by `test_bootstrap_contract.py`'s negative-mutation tests. Address allocation
(mesh, per-region monotonic tunnel index) and account-slot addressing (ACL, fleet-wide monotonic slot)
are orthogonal ID spaces with no collision path. The WireGuard lock and policy lock never nest or
invert in any traced call path (`sync.main()`'s strictly sequential `run_sync()` → `reconcile_policy()`,
and `routes.py`'s `create_client` releasing `wireguard.lock()` before `_write_inline_policy_row` takes
`policy.lock()`). Boot/bring-up ordering is fail-closed throughout: the nft table (PostUp's first
command) always loads before any peer can exist on the wire (`cloudgateway-sync-peers` is ordered
`After=` `wg-quick@...`), and the one real intra-process window (peer sync completing before policy
sync starts within one `sync.main()` invocation) leaves new peers unmarked/unpaired, which the filter
denies by default rather than permits. No threat-model gap was found that either PR's own review missed,
beyond the slot-reuse consequence above, which both ACL-B and ACL-E already flagged from the Firestore
side. No contradiction or unwanted duplication was found between the mesh and ACL client surfaces
(`meshHelper.ts`/`policyHelper.ts` and their Apple counterparts model different domains — bilateral link
state vs. fleet-wide hash consensus — and already share their common coercion primitives via
`coerce.ts`).

**Handoffs:**
1. **ACL-C — fleet-wide snapshot invariant:** confirmed true as a *construction* invariant (every
   `desired_policy` read is fleet-wide/unfiltered) but not as a real-time one — each host is only as
   fresh as its own last successful `reconcile_policy` pass, and the code already documents this exact
   staleness as an accepted risk (`routes.py:501-507`, "a region that never answers... keeps a stale
   policy row"). The double-transit property is a mitigant (both hops must independently authorize), not
   a weakness. The one place staleness becomes boundary-severity is the new P2 finding above.
2. **ACL-C — nft semantics unverified on a real host:** confirmed unresolved and unresolvable by static
   review; carried forward unchanged as the largest pre-deploy risk.
3. **ACL-A — `_infra_address` degenerate-CIDR gap:** finding stands, but the seam shows it's reachable
   only via direct Firestore manipulation — the mesh PR's `validate_local_tunnel_settings` (wired into
   `build_registration`) rejects any non-`/24`/`/64` region CIDR before it can ever reach Firestore
   through the API.
4. **ACL-B — account-slot reuse:** traced through to the host filter; write-up is the new P2 finding
   above (temporary cross-account nftables authorization on a stale host, not just an identity
   collision).
5. **ACL-E — backfill/runtime allocator divergence:** confirmed as the same defect class as ACL-B's P2
   per instruction; the seam's contribution is the same downstream host-filter consequence (new P2
   finding above), not a change to the migration-scoped severity ACL-E already assigned.
