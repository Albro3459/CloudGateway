# Account-scoped ACL: legacy account-slot migration

This is a one-time, release-scoped migration for the account-scoped client
isolation feature (`TODO/account-scoped-acl.md`). It exists to close two
review findings before any region enforces the nftables ACL
(`TODO/account-scoped-acl.md`, "Review remediation"):

* **Finding 7** - existing accounts are never migrated to account slots.
  `desired_policy()` skips every client whose owner lacks
  `Users/{uid}.accountSlot`, so a legacy account with active clients and no
  future client reservation would silently drop out of every policy map once
  enforcement is enabled, losing its own same-account connectivity.
* **Finding 2** - losing or corrupting the slot counter can merge two
  accounts. If `Counters/accountSlots.nextSlot` is ever missing when a slot
  already exists, naive allocation would hand out a slot that's already in
  use, and the nftables policy would then treat two different accounts as one
  tenant. This migration establishes the counter strictly above every
  existing valid slot before the stricter runtime invariant (owned by a
  separate change to `Backend/API/src/repository.py` /
  `Backend/API/src/firebase.py`) takes effect.

It also carries the **Wave 2 fleet-wide policy-row preflight**
(`TODO/account-scoped-acl.md`, "Wave 2 - policy input normalization and
collision handling"): before any region enforces the nftables ACL, this
script re-validates every active client's owner, account slot, and tunnel
addresses against the exact same strict rules
`Backend/API/src/policy_sync.py desired_policy()` applies at runtime, so
known-bad policy data blocks the release instead of silently dropping rows
(or worse, misapplying them) on the first host that enforces the ACL. See
"Fleet-wide policy-row preflight" below.

## What this migration is - and isn't

New-account provisioning **already assigns slots**. In
`Backend/API/src/firebase.py`, `_provision_user_documents()` allocates
`Users/{uid}.accountSlot` transactionally the first time an account is
provisioned, and `reserve_client()` has a lazy fallback that allocates a slot
for any legacy account that reserves a new client. This script is **not**
how slots normally get assigned.

What it does cover:

* Legacy accounts provisioned before the ACL feature existed, that never
  reserve another client after this release ships, and so would never hit
  the lazy fallback.
* Seeding or advancing `Counters/accountSlots.nextSlot` so it exists and
  sits strictly above every slot already assigned, anywhere - including
  slots on non-provisioned ("orphaned") `Users` documents, since those still
  occupy slot space on the wire.

## Prerequisites

* Python 3 with `firebase_admin` installed (the same environment used for
  `scripts/backup_firestore.py`).
* A Firebase service-account credentials JSON file for the target project,
  kept **outside** git. Never commit it.
* A **fresh Firestore backup**, taken immediately before running this
  migration:

  ```sh
  python3 scripts/backup_firestore.py
  ```

  Do not reuse an old backup as a rollback point - take a new one right
  before you run the migration dry-run/apply sequence below.

## Credentials

Pass one of:

* `--credentials <path-to-service-account.json>`
* the `GOOGLE_APPLICATION_CREDENTIALS` environment variable

There is no default credentials path baked into the script (unlike
`scripts/backup_firestore.py`, which points at a repo-relative default this
script deliberately does not use). If neither is provided, the script exits
nonzero with a message and does nothing. The script never prints the
credentials path, its contents, or any other path-derived value.

## Run order

1. **Backup.** `python3 scripts/backup_firestore.py`
2. **Dry-run** (default - no `--apply` flag):

   ```sh
   python3 releases/access-control-lists/backfill_account_slots.py \
     --credentials /path/to/service-account.json
   ```

   Review the aggregate counts (below) and confirm there are zero account-slot
   validation failures and zero policy-row preflight failures. If any
   category is nonzero, stop - see "Validation failures" and "Fleet-wide
   policy-row preflight" below.
3. **Apply:**

   ```sh
   python3 releases/access-control-lists/backfill_account_slots.py \
     --credentials /path/to/service-account.json --apply
   ```

4. **Rerun the dry-run** and require it to report zero newly-assigned slots
   and an unchanged counter (a no-op). If it isn't a no-op, do not proceed -
   investigate before enabling enforcement on any region.

## Output

The script prints aggregate counts only - mode, provisioned account count,
already-assigned count, newly-assigned count, unassigned-after count,
counter before/after (slot numbers, which are opaque integers with no
identifying meaning), a count for each account-slot validation-failure
category, and then the policy-row preflight block: whether the preflight is
`ok` or `blocked`, how many rows were checked and how many were valid, and a
count for each policy-row failure category (below). It never prints a uid,
email, client address, key, token, or configuration value, including in
error paths: any Firestore exception is surfaced by its type name only,
since exception messages/args can embed document paths.

## Validation failures and remediation

The script is fail-closed: if any of the following categories is nonzero, it
refuses to write anything at all, in both dry-run and `--apply`.

* **Malformed slot** - a `Users` document has an `accountSlot` field that
  isn't a valid slot (not an int, a `bool`, a float, a string, zero,
  negative, or above `2**32 - 1`). Fix the document by hand (or via a
  targeted script) to hold a valid unique slot, or clear the field so this
  migration assigns one.
* **Duplicate slot** - the same valid slot value is set on two or more
  `Users` documents. This is exactly the finding-2 failure mode: if left
  alone, the nftables policy would treat those accounts as one tenant. Pick
  one document to keep the slot and clear (or reassign) it on the others
  before rerunning.
* **Orphaned slot** - a valid `accountSlot` exists on a `Users` document
  whose uid has no corresponding `UserRoles` document (not provisioned).
  This still consumes slot space and its uniqueness still matters on the
  wire, so it blocks the migration. Confirm whether the account should be
  provisioned (add a `UserRoles` document) or whether the stray slot should
  be cleared.
* **Overflow** - an account needs a new slot but the highest assigned slot
  is already at (or would exceed) `2**32 - 1` when adding the required
  count of new assignments. This should not happen in practice at current
  fleet scale; if it does, it needs design attention before this migration
  can proceed.

After remediating, rerun the dry-run from scratch - the validation categories
above are recomputed fresh each run.

## Fleet-wide policy-row preflight

Independently of the account-slot backfill above, the script reads every
active, keyed client (`Instances` documents fleet-wide, outside any
transaction - the fleet is single-digit clients, so a plain
`collection_group` scan is cheap) and validates each one with the exact same
strict rules `Backend/API/src/policy_sync.py desired_policy()` applies at
runtime: a non-empty owner, a valid account slot (counting both slots already
assigned and slots this run's plan would assign, so a legacy owner this same
run is about to fix is never misreported as a failure), and `/32`/`/128`
tunnel addresses inside the mesh aggregates, with no address or account slot
claimed by more than one participant. A slot collision is evaluated over
every account, so an account with no active client still excludes the account
it collides with - the same rule the runtime pull applies. This is the release
gate for known-bad policy data: **any nonzero policy-row failure category refuses to write
anything, in both dry-run and `--apply`**, exactly like the account-slot
validation failures above - a bad row must never reach a host's nftables
ACL map.

* **Malformed document** - an `Instances` document's data isn't a mapping, so
  the script cannot tell whether it's part of the active policy fleet.
  Inspect the document by hand; this usually means a partial/corrupt write
  rather than a normal client state. A document merely missing `status` or
  `clientPublicKey` is not a failure: the runtime read treats an absent field
  as "not active"/"not keyed", so such a document is simply outside the
  policy fleet.
* **Invalid owner** - the client's `ownerUid` is missing, not a string, or
  empty. Fix the document's `ownerUid` or remove the client if it's stale.
* **Invalid slot** - the client's owner has no valid account slot, even after
  accounting for slots this run's backfill would assign. Rerun the
  account-slot backfill first (see "Run order" above); if the owner still has
  no slot after that, the account is not provisioned (no `UserRoles`
  document) and needs investigation.
* **Invalid address** - `assignedTunnelIpv4` or `assignedTunnelIpv6` isn't a
  string, doesn't parse, is the wrong address family, doesn't carry an exact
  `/32` (v4) or `/128` (v6) host prefix, or falls outside the tunnel
  aggregates (`10.0.0.0/16`, `fd42:42:42::/48`). Fix the stored address by
  hand or re-provision the client.
* **Duplicate address** - the same IPv4 or IPv6 tunnel address is assigned to
  more than one active client. Addresses are allocated per-region,
  monotonically, and never reused while live, so this indicates corruption,
  not a legitimate collision. Every client sharing the address is excluded
  until it's resolved - reassign or remove the duplicates.
* **Duplicate slot** - two different owners hold the same account slot. This
  is the same finding-2 failure mode the account-slot validation above
  guards against, seen from the policy-row side; multiple clients belonging
  to the *same* owner sharing that owner's slot is expected and is not a
  failure. Resolve it the same way: pick one account to keep the slot and
  reassign or clear it on the other.

After remediating, rerun the dry-run from scratch - like the account-slot
validation categories, these are recomputed fresh each run and never mutate
`Instances` documents themselves (the preflight is read-only).

## The 400-write guard

Firestore transactions cap out at 500 document writes. This script uses one
transaction for the whole migration (see "How apply works" below) and
refuses to run if the plan would need more than 400 writes (counting the
counter document). If you ever see this refusal, split the migration into
multiple runs during a controlled maintenance window rather than raising the
limit - a single all-or-nothing transaction is what keeps the migration
impossible to apply "halfway."

## How apply works

`--apply` re-reads `UserRoles`, `Users`, and `Counters/accountSlots` inside a
single Firestore transaction, recomputes the exact same plan the dry-run
computed, and compares it to the dry-run's plan. If anything changed
underneath it (a new account was provisioned, a slot was written by other
means, the counter moved), the transaction aborts with zero writes and asks
you to rerun. Firestore may itself retry the transaction function on
contention; the read-recompute-compare-write sequence is what makes that
safe to repeat. Every write is `merge=True`: the `Users/{uid}` write sets
only `accountSlot` (never touching `email`, `createdAt`, or `disabled`), and
the `Counters/accountSlots` write sets only `nextSlot` and a server-side
`updatedAt`.

## Rollback and recovery

Slots are never reused, by design (`TODO/account-scoped-acl.md`). That means
the safe way to recover from any bad partial state is **not** to hand-edit
`Users.accountSlot` or `Counters/accountSlots.nextSlot` to "undo" an
assignment - a hand edit that clears or lowers a slot risks a later
allocation reusing it.

If something goes wrong:

1. Stop. Do not run `--apply` again until the state is understood.
2. Restore `Users.accountSlot` values and `Counters/accountSlots` from the
   pre-migration backup taken in step 1 of the run order above.
3. Rerun the dry-run and confirm its plan and validation counts make sense
   before applying again.

Because writes only happen inside one all-or-nothing transaction, a failed
or aborted `--apply` run cannot itself leave a partially-migrated state - the
recovery scenario above is for cases where something *other* than this
script (a bad manual edit, a bug elsewhere) corrupted the slot data.

## Release ordering constraint

This migration **must complete before any region is rebuilt with the ACL
enforced**. The rollout for this release is a full rebuild of every region
through `./scripts/terraform.sh`, not an in-place upgrade. Do not use
`cloudgateway-install-api` for this release - that path does not install or
reload the nftables ACL rule set, so an API-only upgrade would leave the host
running policy code with no table to enforce it and cross-account forwarding
still unrestricted. That helper now refuses an ACL-aware ref on a host with no
live ACL table, for exactly this reason. See
`TODO/account-scoped-acl.md` ("Decisions after review" and "Validation and
release order") for the full rollout sequence.
