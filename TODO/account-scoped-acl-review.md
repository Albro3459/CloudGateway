# Account-Scoped ACL: PR Review Follow-up

Static review of commit `ae99c93` on `access-control-lists`, covering the API,
Firestore model and rules, nftables host integration, dashboard, tests, and
documentation against [account-scoped-acl.md](account-scoped-acl.md).

Verdict: changes requested. The new-host design is substantially implemented,
but the feature is not ready to roll out to existing regions. The first three
findings can either leave the boundary absent or allow the wrong account slot
to be enforced.

Post-review decisions supersede two original dispositions; the implementation
plan in [account-scoped-acl.md](account-scoped-acl.md#pr-blocker-remediation-plan)
is authoritative. Finding 1 is handled by rebuilding every region through
`terraform.sh`, so no live-host nft migration will be implemented. Finding 5's
current pending-bit behavior is the intended depth-1 queue and remains; only
its documentation is narrowed so it does not claim to bound total caller work.
The iOS Server Health Policy surface is recorded as a separate blocker to plan
and implement before release.

No tests were run during this review. The recovered implementation thread says
`api`, `infra`, `firebase`, and `web` all passed immediately before `ae99c93` was
created. This review also ran `git diff --check` successfully and otherwise used
static inspection only.

## Findings

Severity reflects production impact. P1 findings should block rollout.

### 1. Existing-region upgrades can run the new API with no ACL installed

P1, confirmed.

`Infrastructure/OCI/host/bootstrap.sh:165-208` writes the nftables ruleset and
adds its `PostUp` load, but the live API updater at `bootstrap.sh:535-557` copies
only `Backend/API/` and restarts the API. An existing region upgraded with
`cloudgateway-install-api` therefore has policy code calling `nft` but no
`inet cloudgateway` table or forward chain. Those failures are swallowed, so
the API continues serving while cross-account forwarding remains unrestricted.

Re-running bootstrap is not a complete migration: `systemctl enable --now
wg-quick@wg0` does not rerun `PostUp` when the interface is already active.
Add an explicit, idempotent host migration that installs and loads the ruleset,
verifies the live chain, then performs a full policy reconcile. Alternatively,
require a planned region rebuild and record that as the only supported rollout.
The general deployment guide already classifies firewall changes as host-level;
the missing piece is an ACL-specific cutover gate that prevents an API-only
upgrade or an incomplete bootstrap re-run.

### 2. Losing or corrupting the slot counter can merge two accounts

P1, confirmed security boundary failure.

`Backend/API/src/repository.py:294-302` resets a missing or invalid
`Counters/accountSlots.nextSlot` to `1`, and
`Backend/API/src/firebase.py:1008-1015` allocates that value without checking
existing `Users/*` slots. If the counter is lost after slot `1` already exists,
the next account also receives slot `1`. The nftables policy then treats the two
accounts as the same tenant and permits cross-account traffic.

The allocator must fail closed or recover transactionally above the maximum
existing valid slot. The policy builder must also reject duplicate slots and
values outside the 32-bit mark range instead of applying or retaining an
ambiguous map.

### 3. The sequence guard does not cover the process that runs at boot

P1, confirmed.

`Backend/API/src/policy_sync.py:162-186` pulls desired state before taking the
host flock. The API's last-applied sequence is in-memory only
(`policy_sync.py:238-240,327-329`), while the separate
`cloudgateway-sync-peers` process calls `reconcile_policy(sequence=1)` without a
guard at `Backend/API/src/sync.py:621`.

An older boot/manual pull can therefore wait for the flock, then overwrite a
newer map applied by the API. The same flaw appears if the API ever gains more
than one worker. After address reuse, the stale row can associate a newly owned
address with its former account slot. Serialize pull plus apply across all
processes, or use a host-shared generation that every writer checks under the
flock.

### 4. The inline fast path can fail a create after the client is active

P1, confirmed.

`Backend/API/src/routes.py:882` calls `repository.get_account_slot()` before the
`try` in `_write_inline_policy_row`. A Firestore error escapes after the peer was
added and `mark_client_active()` succeeded. The caller receives a 500, and the
local reconcile and remote pokes at `routes.py:284-293` are never scheduled.

Move the slot lookup inside the best-effort error boundary. The inline path must
not change a successful client creation into a failed response.

### 5. Refresh coalescing is not structurally bounded

P1, confirmed availability and cost risk.

`Backend/API/src/policy_sync.py:270-284` loops whenever `_pending` is set. A poke
arriving during the follow-up schedules a third pass, and continued calls can
keep the loop alive indefinitely. Because any provisioned user can call
`POST /api/sync/refresh` and there is no rate limit, one caller can continuously
drive fleet-wide Firestore reads and make `run_blocking()` wait indefinitely.

The current test covers only a burst that stops during the first pass. Define
explicit backpressure for arrivals during the follow-up and add a sustained-
arrival test. If the endpoint remains available to every provisioned user, a
rate or minimum refresh cadence is needed for the documented bounded-cost
claim.

### 6. Admin allow-set changes are neither propagated nor observable

P1, confirmed privilege-staleness risk.

`desired_policy()` derives `cg_admin4/6` from `UserRoles` at
`Backend/API/src/policy_sync.py:99-105`, but `LivePolicyMap` reads and hashes
only `cg_slot4/6` at `Backend/API/src/policy.py:43-53,159-163`. A role promotion
or demotion does not change either published hash, and no role-change path
triggers a fleet reconcile. A demoted admin can therefore retain cross-region
infrastructure reach while Server Health still reports matching maps.

Read back and hash every authorization-bearing object, including `cg_admin`,
and make role mutation trigger or require an immediate all-region reconcile.

### 7. Existing accounts are never migrated to account slots

P1 for rollout availability, confirmed.

`desired_policy()` skips every client whose owner lacks `Users.accountSlot`
(`Backend/API/src/policy_sync.py:71-86`). Legacy accounts receive a slot only
when they reserve another client (`Backend/API/src/firebase.py:528-557`). An
existing account with two active clients and no future reservation remains
absent from every policy map indefinitely, so its same-account connectivity is
lost when enforcement is enabled.

Backfill all provisioned accounts transactionally before loading the ACL on any
region, and advance the counter past every assigned value.

### 8. Account deletion indirectly issues the pokes the design rejects

P2, confirmed plan deviation.

The comment at `Backend/API/src/routes.py:451-463` says account deletion must
not poke because no ordering around removal of `UserRoles/{uid}` is safe. But
remote clients are deleted through the ordinary `DELETE /clients/{clientId}`
path (`routes.py:760-809`), and that handler always schedules local and remote
policy refreshes at `routes.py:397-405`.

Those background pokes can race the hard delete and exercise the exact missing-
role/disable behavior the comment claims to avoid. Give account cleanup a path
that suppresses propagation, or replace the rejected ordering rationale with a
safe service-authenticated deletion/reconcile design.

### 9. Malformed and colliding client rows are not consistently fail-closed

P2, confirmed.

The policy pull promises to skip malformed rows, but several inputs escape that
contract:

* `ownerUid` can be an unhashable value and abort `account_slots.get()` at
  `Backend/API/src/policy_sync.py:80`.
* Raw `updatedAt` values from `Backend/API/src/firebase.py:981-982` are compared
  as datetimes at `policy_sync.py:107` and can abort the pass or write a
  malformed vintage.
* `bare_tunnel_address()` at `policy_sync.py:33-46` accepts client prefixes
  other than `/32` and `/128`, unlike WireGuard peer validation.
* Duplicate addresses are first-wins: the later row is skipped, but the first
  row remains associated with an address whose ownership is ambiguous.
* Positive duplicate slots merge accounts; oversized slots abort the whole
  apply instead of isolating the bad rows.

Normalize repository output, validate slots and host prefixes before building
the map, and exclude every participant in an address or slot collision.

### 10. The policy lock can still block the WireGuard create path

P2, confirmed plan deviation.

Client creation holds `wireguard.lock()` while `_write_inline_policy_row()`
takes the policy flock (`Backend/API/src/routes.py:184-268,891-893`). A reconcile
holds that policy flock through the Firestore status write
(`Backend/API/src/policy_sync.py:172-210`), which has no explicit timeout. A
slow status write can therefore stall a create while it holds the WireGuard
lock and can make an otherwise non-blocking peer sync shed.

Move the best-effort inline policy write outside the WireGuard critical section
or make its policy-lock acquisition non-blocking. Avoid network I/O while
holding the host mutation lock where possible.

### 11. `dataVintage` cannot reliably identify a stale region

P2, confirmed dashboard correctness issue.

`dataVintage` is the maximum `updatedAt` among currently active rows
(`Backend/API/src/policy_sync.py:104-108`). It is not monotonic: deleting the
newest row moves a freshly reconciled region backward while a stale region
retains the deleted row's later timestamp. The dashboard can consequently mark
the correct regions stale. A successful empty snapshot also has a null vintage,
which the UI renders as "No applied snapshot yet" at
`Frontend/Web/src/pages/ServerHealth.tsx:687` even though `updatedAt` proves a
pass completed.

Use a monotonic policy mutation generation or tombstone/version signal that
advances on create, delete, and role change. For an empty successful snapshot,
render the applied time rather than claiming no snapshot was applied.

### 12. Status validation and documentation overstate what is verified

P3, confirmed.

* `Frontend/Web/src/helpers/policyHelper.ts:50-57` treats a document with a
  missing `appliedSequence` as usable even though the schema requires it.
* `docs/api-contract.md:338-340` says a failed apply surfaces in the Policy
  status document, but failed applies do not write status; the old document
  remains.
* `docs/wireguard-drift-repair.md:52` says boot reconciliation runs as part of
  the API process, but boot uses the separate sync CLI process.
* `account-scoped-acl.md:177-178` says renaming a bootstrap object fails the
  build. `Backend/API/tests/test_policy.py:23` checks only the table-name
  constant; no test reads or validates the bootstrap ruleset.

Correct the claims and add a real contract check between the bootstrap object
names/aggregates and the API renderer.

## Plan deviations

* Host objects are complete only for a newly built or explicitly migrated
  region; the ACL plan does not turn the general host-level rebuild rule into a
  concrete fleet cutover gate.
* Slot allocation works for newly provisioned users and on a future client
  reservation, not for all existing provisioned accounts.
* The dedicated flock exists, but depth-1 bounded work and the sequence guard
  do not hold across the actual API/boot process boundary.
* Account deletion does generate policy pokes indirectly through remote client
  deletion.
* Status is read back only from the slot maps, not from all enforcement-bearing
  sets/maps, so it is not a complete description of what is on the wire.
* Policy failure at boot is logged and `sync.py` still returns success; the
  systemd retry path therefore does not retry a policy-only failure.
* The dashboard surface exists, but its freshness signal is non-monotonic and
  its successful-empty-state copy is incorrect.

The implementation does match the planned 202 response, provisioned-user auth,
empty response body, monotonic tunnel address allocator, Firestore rules/schema,
new-host nftables objects, atomic nft batch application, create/delete trigger
sites, and Server Health policy card.

## Fix checklist and accepted dispositions

* [x] Close finding 1 by requiring every region to be rebuilt through
  `terraform.sh`; do not add an existing-host nftables migration.
* [ ] Backfill legacy account slots and make counter recovery collision-safe.
* [ ] Make snapshot ordering effective across API, boot, and any future workers.
* [ ] Keep inline policy lookup/apply failures from escaping client creation.
* [x] Accept the current depth-1 pending-bit behavior for finding 5 and narrow
  its documentation to the one-item pending backlog guarantee.
* [x] Re-read, apply, read back, hash, and display admin allow-set changes;
  require manual Sync All after any trusted out-of-band role edit.
  Landed in Wave 5: reconcile re-reads `UserRoles` and applies `cg_admin4/6` on every pass, and
  `cg_admin4/6` is now part of the comprehensive `mapHashV4`/`mapHashV6` read-back, so an admin
  promotion or demotion changes the published hash. No role-mutation API/UI/timer was added; docs
  now say a trusted operator must run Sync All Regions immediately after any out-of-band
  `UserRoles` edit, and the fleet keeps enforcing the previous allow-set until they do.
* [ ] Replace accidental per-client deletion pokes with the authenticated,
  account-scoped cleanup and one-refresh-wave ordering in the implementation
  plan.
* [x] Make malformed/duplicate rows fail closed without aborting the fleet pass.
  Fixed in Wave 2: `Backend/API/src/policy_sync.py` (`bare_tunnel_address`,
  `desired_policy`) validates owner/slot/address before building a row and
  excludes every participant in a duplicate address or slot, and
  `releases/access-control-lists/backfill_account_slots.py` runs the same
  rules as a fleet-wide preflight gate ahead of enforcement.
* [ ] Remove policy-lock contention from the WireGuard create critical section.
* [x] Replace `dataVintage` with comprehensive live-policy hash agreement and
  show `Policy.updatedAt` as last applied.
  Landed in Wave 5: `dataVintage` and `appliedSequence` are removed entirely from `schema.ts`,
  `Backend/Firebase/README.md`, the Firestore rules test fixtures, and every doc. `Policy/{regionId}`
  is now `regionId`, `mapHashV4`, `mapHashV6`, `rowCount`, `updatedAt`; the hashes cover every
  authorization-bearing live object (`cg_tunnel4/6`, `cg_infra4/6`, `cg_admin4/6`, `cg_slot4/6`,
  `cg_pairs4/6`) per family, drift is comprehensive hash disagreement among enabled regions only,
  and `updatedAt` is displayed as "Last applied" with age alone never treated as drift or
  staleness.
* [ ] Correct status validation, failure semantics, process-model docs, and the
  claimed bootstrap/API contract test.
* [ ] Write and implement the separate iOS Server Health Policy parity plan.
* [ ] Run `./scripts/test.sh` after the fixes.
* [ ] Complete the two existing live-host verification items before rollout.
