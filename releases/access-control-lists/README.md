# Account-scoped ACL: legacy account-slot migration

This is a one-time, release-scoped migration for the account-scoped client
isolation feature (`TODO/account-scoped-acl.md`). It exists to close two
review findings before any region enforces the nftables ACL
(`TODO/account-scoped-acl-review.md`):

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

   Review the aggregate counts (below) and confirm there are zero validation
   failures. If any validation failure is nonzero, stop - see "Validation
   failures" below.
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
identifying meaning), and a count for each validation-failure category. It
never prints a uid, email, client address, key, token, or configuration
value, including in error paths: any Firestore exception is surfaced by its
type name only, since exception messages/args can embed document paths.

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
