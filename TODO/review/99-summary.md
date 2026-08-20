# 99-summary: Stacked PR Review Consolidation

## 1. Header

This is the consolidation of a completed ten-pass review of two stacked PRs on the
`access-control-lists` branch, per `TODO/review/00-review-plan.md`.

| PR | Range | Scale |
| --- | --- | --- |
| Shared Subnet Mesh | `e4db044..bc7d99a` | 97 files, +15482 / -917 |
| Account-Scoped ACL (stacked on mesh) | `bc7d99a..HEAD` (`57bc1d2`) | 69 files, +11006 / -139 |

Account-Scoped ACL branches off the `shared-subnet` head (`bc7d99a`) and is stacked on
top of it — every ACL finding below assumes the mesh code beneath it as given context,
not as something ACL re-implements. **Shared Subnet Mesh is already deployed**
(`deploy-v1.0.25`). **Account-Scoped ACL is code-complete but not yet deployed.**

All ten chunk passes are complete, each with its own `## Findings` and
`## Clean (no findings)` sections on disk:

| ID | Area | Doc |
| --- | --- | --- |
| SS-A | Mesh — API core | `10-ss-api.md` |
| SS-B | Mesh — Web dashboard | `11-ss-web.md` |
| SS-C | Mesh — Apple | `12-ss-apple.md` |
| SS-D | Mesh — Infra/Firebase/scripts/docs | `13-ss-infra.md` |
| ACL-A | ACL — Policy engine | `20-acl-policy.md` |
| ACL-B | ACL — API integration | `21-acl-api.md` |
| ACL-C | ACL — Host filter (nftables) + Firebase + docs | `22-acl-infra.md` |
| ACL-D | ACL — Web + Apple clients | `23-acl-clients.md` |
| ACL-E | ACL — Release migration script | `24-acl-migration.md` |
| X-1 | Cross-cutting seam between the two PRs | `30-cross-cutting.md` |

This document deduplicates and severity-ranks every finding across all ten docs. It adds
no new findings of its own.

## 2. Verdict

Neither PR has a P0. That is the headline good news, and it is earned: reviewers traced
the account boundary by hand at every seam — mesh `AllowedIPs` vs. the nftables account
boundary, the two allocation axes (per-region tunnel index vs. fleet-wide account slot),
lock ordering between `wireguard.lock()` and `policy.lock()`, and boot/bring-up ordering —
and found every gap fails closed, not open. The client surfaces (web and Apple, both PRs)
are unusually well-tested for their race-prone paths, and the two teams' Swift/TypeScript
ports of the mesh and policy logic are near-line-for-line faithful with symmetric test
coverage.

That said, this branch is not yet in shippable shape as-is. There is one real P1 defect
class — hard-deleted `Users` docs are invisible to a live scan, which lets both the
runtime account-slot recovery path and the migration script's primary path reissue a
deleted account's slot, and X-1 traced that all the way to the nftables layer: a reused
slot can produce a real, if narrow and timing-dependent, cross-account authorization on a
host that hasn't resynced. It requires two uncommon preconditions (a hard-deleted
highest-slot account, then either counter corruption or the migration script's normal
path) to fire, but it violates an invariant the code repeatedly documents as load-bearing
("never reused"), and the fix is well-scoped (stop deriving the slot floor from a live
scan that can't see hard deletes). Separately, SS-C found a real PII/session-hygiene bug
on iOS (a shared-device sync-log leak between two admins) and a Swift-only crash trap —
both P1, both narrow in blast radius (admin-only surfaces) but both concrete and
reachable without any adversarial input.

The single largest risk to a clean deploy is not in any of the eleven findings below: it
is ACL-C's self-disclosed, still-unresolved item that nft verdict precedence, the
`priority -10` ordering against the legacy iptables rules, and the concatenated-set drop
syntax have never been verified on a real host. Every static trace in this review assumes
that syntax means what the code believes it means. That assumption should be tested on a
real host, in a controlled window, before this ships — it is cheap to verify and expensive
to be wrong about.

Recommendation: fix the slot-reuse defect class and the two SS-C Apple findings (all are
well-scoped, none requires a design change), then do a real-host nft verification pass
before deploying ACL. Nothing else on this list blocks a deploy, but the P2/P3 backlog
(mostly narrow-path bugs and test-coverage gaps) should be worked down at normal priority
afterward.

## 3. Findings table

Thirteen findings were written across the ten chunk docs. Three of them (ACL-B's P2,
ACL-E's P1, X-1's P2) are one underlying defect reported from three angles and are merged
into a single row per the deduplication notes in section 4, leaving **11 rows** in the
table below. Counts by severity (post-merge, merged row counted once at its highest
severity):

| Severity | Count |
| --- | --- |
| P0 | 0 |
| P1 | 3 |
| P2 | 7 |
| P3 | 1 |
| **Total rows** | **11** |

(Raw pre-merge finding count across all docs: 13 — P1: 3, P2: 9, P3: 1. The merge folds
one P2 + one P1 + one P2 into one P1 row, which is why the row P1 count (3) equals the
raw P1 count: the two ACL-B/X-1 P2s disappear into the merged row, and ACL-E's raw P1
becomes that row's severity.)

| Severity | Finding | Chunk | Source doc | `path:line` |
| --- | --- | --- | --- | --- |
| P1 | Hard-deleted `Users` docs are invisible to a live scan, letting a deleted account's slot be reissued — reachable via runtime counter-recovery *or* the migration script's primary path, and traced through to a real (if narrow) cross-account nftables authorization on a stale host. See dedup notes. | ACL-B / ACL-E / X-1 | `21-acl-api.md`, `24-acl-migration.md`, `30-cross-cutting.md` | `Backend/API/src/firebase.py:1089-1126`, `Backend/API/src/repository.py:343-404`, `Backend/API/src/firebase.py:381-401`, `releases/access-control-lists/backfill_account_slots.py:180-189`, `Backend/API/src/policy_sync.py:88-182`, `Infrastructure/OCI/host/bootstrap.sh:169-195` |
| P1 | `Int(Double)` conversion trap in the mesh Firestore mapper crashes on a boundary value (`2^63`) — same bug class already fixed in the sibling policy mapper, not applied here | SS-C | `12-ss-apple.md` | `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayFirestoreMeshMapper.swift:128-132` |
| P1 | `CloudGatewayServerHealthViewModel` is a session-long singleton with no reset on sign-out/account-swap, so a shared device can leak one admin's sync log (emails, client names, public keys, tunnel IPs) to the next admin who signs in | SS-C | `12-ss-apple.md` | `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayServerHealthViewModel.swift` (no reset method); composition at `Frontend/Apple/iOS/CloudGateway/CloudGatewayIOSCompositionRoot.swift:64`; dismiss-only gap at `Frontend/Apple/iOS/CloudGateway/ContentView.swift:92-112` |
| P2 | Hung DNS resolution during mesh drift-check leaks worker threads in the long-lived API process (unbounded `ThreadPoolExecutor` growth) | SS-A | `10-ss-api.md` | `Backend/API/src/wireguard.py:723-746` (`_resolve_endpoint_addresses`), reached via `wireguard.py:973-993`/`502-503` from `sync_peers` (`wireguard.py:462`), exposed via `routes.py:664` |
| P2 | Route-reconciliation failure bypasses the partial-progress log and can silently discard an earlier mesh-peer apply error | SS-A | `10-ss-api.md` | `Backend/API/src/wireguard.py:474-500` (`sync_peers`), `wireguard.py:529-605` (`_reconcile_mesh_routes`/`_reconcile_routes_for_family`) |
| P2 | Cross-tab auth race can strand a completed sign-in on the Login page (a concurrent same-origin-tab auth event overwrites shared state mid-attempt) | SS-B | `11-ss-web.md` | `Frontend/Web/src/pages/Login.tsx:205-206`, `231-232`, `259-260`, `299-315` |
| P2 | "Sync All Regions" is not gated on an in-flight mesh-membership toggle, so a sync can fan out before a just-toggled region's Firestore write is durable, silently skipping that region for the pass | SS-B | `11-ss-web.md` | `Frontend/Web/src/pages/ServerHealth.tsx:520-534` (button gate) vs. `:302-347` (`handleToggleMesh`), `:152`/`:549`/`:573` (`togglingRegionIds`) |
| P2 | `_infra_address` can add an unrelated live client address to `cg_infra` for a degenerate (`/32`) region tunnel CIDR, granting it infra/admin-level nftables reachability | ACL-A | `20-acl-policy.md` | `Backend/API/src/policy_sync.py:53-74` (`_infra_address`) |
| P2 | Backfill migration's test suite has no case combining a valid counter above the live max with a pending new assignment — the one case that would have caught the merged P1 slot-reuse defect | ACL-E | `24-acl-migration.md` | `releases/access-control-lists/test_backfill_account_slots.py:191-200` (`test_valid_counter_at_or_below_max_is_advanced_never_reused`) |
| P2 | No test coverage for the migration's 400-write transaction guard (boundary and refusal paths both untested) | ACL-E | `24-acl-migration.md` | `releases/access-control-lists/backfill_account_slots.py:552-556` (`_apply_within_transaction`), `:670-679` (`main()` pre-check); no reference in `releases/access-control-lists/test_backfill_account_slots.py` |
| P3 | No test coverage for a degenerate (`/31`/`/32`) region tunnel CIDR in `desired_policy`'s infra derivation — the gap that lets the ACL-A P2 above regress silently even after a fix | ACL-A | `20-acl-policy.md` | `Backend/API/tests/test_policy_sync.py:275-345` |

## 4. Deduplication notes

Three findings from three different reviewers are one underlying defect, viewed from
three different angles, and are collapsed into the single merged P1 row in the table
above:

- **ACL-B's P2** ("Account-slot recovery path can reissue a deleted account's slot",
  `21-acl-api.md`) — the *runtime* angle. `next_account_slot`'s counter-recovery branch
  (taken when `Counters/accountSlots.nextSlot` is absent or malformed) derives the next
  slot from `max(assigned_slots) + 1` over a live scan of the `Users` collection. Once
  `hard_delete_account_documents` removes a deleted account's `Users/{uid}` doc, that
  account's slot is invisible to the scan, so counter corruption after the fact can
  reissue it. Cites: `Backend/API/src/firebase.py:1089-1126` (`_allocate_account_slot`),
  `Backend/API/src/repository.py:343-404` (`next_account_slot` recovery branch),
  `Backend/API/src/firebase.py:381-401` (`hard_delete_account_documents`).

- **ACL-E's P1** ("Backfill ignores a valid `Counters/accountSlots.nextSlot` when
  choosing new slot values", `24-acl-migration.md`) — the *migration* angle, and the more
  reachable of the two: `compute_plan()` in the standalone backfill script derives its
  new-slot floor from `max(all_valid_slots)` over the live scan *unconditionally*, even
  when `counter_before` is a perfectly valid, higher value — it never trusts a valid
  stored counter the way the runtime allocator does. This fires on the migration's
  *primary* path any time a valid counter sits above the live max because of a
  hard-deleted account, not only on the narrower runtime path where the counter itself
  must first become corrupted. Cites:
  `releases/access-control-lists/backfill_account_slots.py:180` (`base = max(all_valid_slots)...`)
  through `:189` (`assignments[uid] = candidate`), contrasted with
  `Backend/API/src/repository.py:343-399` (`next_account_slot`).

- **X-1's P2** ("A reused account slot can grant temporary cross-account nftables
  authorization on any host that hasn't resynced since the reuse", `30-cross-cutting.md`)
  — the *host-filter consequence* angle, which neither ACL-B nor ACL-E traced through to
  the actual authorization boundary. Once a slot is reissued (either bug above), a region
  host that last ran `reconcile_policy` before the original account's deletion still has
  that account's stale `(address, mark=slot)` rows live in `cg_slot4/6`/`cg_pairs4/6`
  (nftables state is a full-replace snapshot, but only as of that host's own last pass —
  there is no fleet-wide push, only per-host pull). If the freed tunnel address is
  separately reused by a third account's client (a normal, intended event on its own —
  see X-1's Focus 2), that stale host authorizes the old and new slot-holders against each
  other under the same mark until it resyncs — a genuine, if narrow and timing-dependent,
  cross-account authorization, not merely a Firestore bookkeeping inconsistency. Cites:
  `Backend/API/src/firebase.py:1089-1126`, `Backend/API/src/repository.py:343-399`,
  `Backend/API/src/policy_sync.py:88-182` (`desired_policy`),
  `Infrastructure/OCI/host/bootstrap.sh:169-195` (`cg_slot4`/`cg_pairs4`).

All three reviewers independently identified the same root cause — "hard-deleted `Users`
docs are invisible to a live scan" — and X-1's own resolution notes explicitly instruct
treating ACL-B's P2 and ACL-E's P1 as one defect class, and treating the X-1 P2 as an
"impact clarification" of that same class rather than an independently reachable new
defect. The merged row above is filed at **P1** (ACL-E's severity, the highest of the
three and the most reachable path), since the runtime and migration variants are the same
bug with different trigger conditions and the host-filter consequence is what makes the
underlying bug boundary-severity rather than a bookkeeping curiosity. Fixing the root
cause (never let a valid stored/derivable slot ceiling be undercut by a live scan that
can't see hard-deleted docs) closes all three simultaneously; no separate seam-specific
mitigation is needed per X-1's own analysis.

No other cross-doc duplicates were found. All other findings are independent defects
reported once, by one reviewer, in one doc.

## 5. Pre-deploy risks that static review cannot close

The largest pre-deploy risk this branch carries is not a finding in the table above — it
is a self-disclosed open verification item that no amount of source reading can resolve.

ACL-C (`22-acl-infra.md`) flagged it directly against `docs/wireguard-drift-repair.md`'s
own "Open verification item" section: nft **verdict precedence** (whether `drop` inside
`cg_forward` actually terminates evaluation ahead of the legacy `iptables`/`ip6tables`
`FORWARD` chains), the **`priority -10`** base-chain ordering relative to those legacy
rules, and the **concatenated-set drop syntax**
(`ip daddr @cg_tunnel4 ip daddr . meta mark != @cg_pairs4 drop`) have **not been verified
on a real host**.

X-1 (`30-cross-cutting.md`) picked this up as a handoff and confirmed it remains
unresolved: "confirmed this remains true and is explicitly out of reach for static
review — carrying it forward unchanged as the largest pre-deploy risk, per ACL-C's own
framing." Every other conclusion in this review that depends on the nftables filter
actually behaving as its source text describes — the fail-closed boot-ordering analysis
(X-1 Focus 4), the "no window where the filter is more permissive than intended" claim,
the account-boundary containment claim (X-1 Focus 1) — is a *static* trace of what the
nft syntax is supposed to do, cross-checked against `test_bootstrap_contract.py`'s
parsing of the same source text. None of it is a substitute for confirming the kernel's
actual netfilter verdict-precedence behavior on the real target OS/kernel combination
with the real legacy iptables rules already in place.

Put plainly: this is the single largest risk the ACL PR carries into deploy, and it is
exactly the kind of thing that fails silently and expensively if wrong — a misordered or
misinterpreted verdict precedence would not produce a build failure or a test failure, it
would produce a host that looks correctly configured and isn't. It should be verified on
a real host, in a controlled window, before ACL is deployed to any live region.

## 6. Confirmed-clean coverage

Three chunks — **ACL-C**, **ACL-D**, and **SS-D** — closed with zero findings after full
scope coverage, and are worth citing directly rather than letting "clean" get lost next
to the defect list above:

- **ACL-C** (`22-acl-infra.md`) verified the nftables table/chain/PostUp/PostDown
  structure, boot-state fail-closed defaults, and PostUp/PostDown ordering against
  `bootstrap.sh`; verified `firestore.rules`' `Policy/{regionId}` (admin-get/list,
  write-false) and `Counters/{id}` (fully closed to clients) have no cross-account or
  non-admin read path, backed by `firestore.rules.test.ts`'s denial-path tests; verified
  every operator-facing doc claim in scope against the actual bootstrap.sh/policy.py
  behavior with no drift found. Its one open item is the real-host nft verification gap
  carried into section 5 above, not a finding against any file it reviewed.
- **ACL-D** (`23-acl-clients.md`) built a full web/iOS parity matrix for the
  `Policy/{regionId}` status surface across fourteen behaviors (usability gating, numeric
  coercion, timestamp coercion, consensus/drift math, disabled-region exclusion, state
  derivation, read-failure isolation, staleness/generation guarding, sync-response field
  parsing, UI copy, and privacy) and found the web and Apple implementations a faithful,
  near-line-for-line port of each other with symmetric hostile-input test coverage on
  both platforms. The two documented divergences (fractional `rowCount` handling;
  `updatedAt` accepting only `Date` on iOS vs. more shapes on web) were traced and shown
  non-reachable given the real write path, not left as unresolved risk.
- **SS-D** (`13-ss-infra.md`) verified every operator-facing doc claim across the full
  `docs/*.md` set, `Infrastructure/OCI/README.md`, and the terraform/preflight/bootstrap
  toolchain against the implementing code, including the mesh-range `firestore.rules`
  diff (`Regions.meshEnabled` field-scoped update rule, admin-only `Mesh/{regionId}`)
  backed by denial-path tests, and closed with zero findings after cross-checking every
  claim rather than taking any of them on faith.

Beyond those three full-clean chunks, **X-1** (`30-cross-cutting.md`) answered its
primary chartered question — does the nftables account boundary actually contain what
mesh's subnet-wide `AllowedIPs` now permits — in the **affirmative, verified by
construction**: every mesh peer's `AllowedIPs` is validated at apply time to be a
`/24`/`/64` strictly inside the same `MESH_AGGREGATE_V4`/`V6` aggregate that
`bootstrap.sh`'s `cg_tunnel4`/`cg_tunnel6` sets enforce, and that correspondence is pinned
by `test_bootstrap_contract.py`'s negative-mutation tests (a rename or reorder in
`bootstrap.sh` fails the build). X-1 additionally closed all six of its chartered focus
items clean except for the one merged finding above: address-allocation orthogonality
(mesh's per-region tunnel index vs. ACL's fleet-wide account slot share no ID space), lock
ordering (`wireguard.lock()`/`policy.lock()` never nest or invert in any traced call
path), boot/bring-up ordering (fail-closed throughout, including the one real
intra-process window between peer sync and policy sync), and no contradiction or
unwanted duplication between the mesh and ACL client surfaces (`meshHelper.ts` and
`policyHelper.ts`, and their Apple counterparts, model different domains and already
share their common coercion primitives).

Every remaining chunk (SS-A, SS-B, SS-C, ACL-A, ACL-B, ACL-E) also carries substantial
clean coverage alongside its findings — documented in each doc's own
`## Clean (no findings)` section — but those chunks did produce findings and are
represented in the table in section 3 rather than summarized again here.

## 7. Suggested fix order

Highest-value first, grouped by what blocks what:

1. **Real-host nft verification** (section 5). Not a code fix, but do this before
   anything else ships to a live region — it is the one item nothing else on this list
   substitutes for, and every fix below assumes the filter behaves as its source
   describes.
2. **Fix the merged P1 slot-reuse defect class** (section 4). Stop deriving the new-slot
   floor from a live `Users` scan that can't see hard deletes, in both places: the
   runtime recovery path (`repository.py:343-404`) and the migration's primary path
   (`backfill_account_slots.py:180-189`). This is one root-cause fix with two call sites,
   and it also closes the X-1 host-filter consequence without any separate mitigation.
   Add the two ACL-E test-coverage rows (section 3, the valid-counter-above-max case and
   the 400-write boundary case) alongside the fix so the fix is pinned.
3. **Fix the two SS-C Apple P1s** (section 3). Both are narrow in blast radius
   (admin-only Server Health surface) but concrete: apply the same `Int(exactly:)` fix
   already used in the sibling policy mapper to `CloudGatewayFirestoreMeshMapper`, and
   give `CloudGatewayServerHealthViewModel` a reset/clear path wired into the existing
   identity-change handling, mirroring the pattern it replaced
   (`CloudGatewayViewModel.clearRemoteState()`).
4. **Work down the P2 backlog** at normal priority — none of it blocks a deploy on its
   own: the SS-A DNS-thread-leak and route-reconciliation-error-swallowing bugs (both
   narrow-path, both in the already-deployed mesh code), the SS-B cross-tab login race
   and "Sync All Regions" gating gap (both web-only, both self-correct with a retry), and
   the ACL-A `_infra_address` degenerate-CIDR gap (real defense-in-depth, but only
   reachable via direct Firestore manipulation since `validate_local_tunnel_settings`
   already rejects any non-`/24`/`/64` region CIDR through the normal registration path).
5. **The one P3** (ACL-A's missing degenerate-CIDR test case) — pick up alongside item 4
   whenever `_infra_address` is touched for its own fix, since the same test case pins
   both.
