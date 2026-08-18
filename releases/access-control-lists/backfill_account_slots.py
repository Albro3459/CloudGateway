#!/usr/bin/env python3
"""Backfill Users/{uid}.accountSlot for legacy provisioned accounts and seed
Counters/accountSlots.nextSlot.

Context: TODO/account-scoped-acl.md ("PR blocker remediation plan" -> Wave 1)
and TODO/account-scoped-acl-review.md findings 2 and 7.

New-account provisioning (Backend/API/src/firebase.py
_provision_user_documents) already assigns Users/{uid}.accountSlot at
provisioning time, and reserve_client() has a lazy fallback for legacy
accounts that reserve a new client. This script exists for two remaining
gaps: (1) legacy accounts that never reserve another client after this
feature ships would otherwise never get a slot, and (2) the Counters/
accountSlots counter document needs to exist and sit strictly above every
already-assigned slot before runtime allocation can safely fail closed.

This script is standalone by design: it does NOT import from Backend/API. It
duplicates two constants that must stay in sync with the source of truth:

  * MIN_ACCOUNT_SLOT mirrors Backend/API/src/repository.py MIN_ACCOUNT_SLOT.
  * MAX_ACCOUNT_SLOT mirrors Backend/API/src/policy.py MAX_SLOT
    (2**32 - 1, the width of an nftables packet mark).

Dry-run is the default; --apply is required to write anything. Output is
aggregate counts only - this script must never print a uid, email, client
address, key, token, or configuration, even in error paths, since a Firestore
exception's message/args can embed a document path.

See releases/access-control-lists/README.md for the full operator runbook.
"""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from typing import Any

# Mirrors Backend/API/src/repository.py MIN_ACCOUNT_SLOT. Do not import it -
# this script must stay standalone and runnable without the API package.
MIN_ACCOUNT_SLOT = 1

# Mirrors Backend/API/src/policy.py MAX_SLOT (2**32 - 1: width of the
# nftables packet mark carrying the account slot).
MAX_ACCOUNT_SLOT = 2**32 - 1

# Firestore transactions are limited to 500 document writes. We stay well
# under that (counting the counter write) and refuse to run a migration that
# would get close, per the README's maintenance-window guidance.
MAX_TRANSACTION_WRITES = 400


class MigrationAbortedError(RuntimeError):
    """Raised to abort the apply transaction. Message text must never embed a
    uid, email, address, or Firestore document path."""


def _is_valid_slot(value: Any) -> bool:
    """A valid slot is a real int (bool excluded), in [MIN_ACCOUNT_SLOT,
    MAX_ACCOUNT_SLOT]."""
    return (
        isinstance(value, int)
        and not isinstance(value, bool)
        and MIN_ACCOUNT_SLOT <= value <= MAX_ACCOUNT_SLOT
    )


@dataclass(frozen=True)
class PlanFailures:
    malformed_slot: int = 0
    duplicate_slot: int = 0
    orphaned_slot: int = 0
    overflow: int = 0

    @property
    def blocking(self) -> bool:
        return bool(self.malformed_slot or self.duplicate_slot or self.orphaned_slot or self.overflow)


@dataclass(frozen=True)
class Plan:
    ok: bool
    failures: PlanFailures
    provisioned_count: int
    already_assigned_count: int
    # uid -> newly assigned slot. Empty when the plan is blocked or a no-op.
    assignments: dict[str, int] = field(default_factory=dict)
    unassigned_after: int = 0
    # "missing" | "malformed" | "valid"
    counter_state: str = "missing"
    counter_before: int | None = None
    # New Counters/accountSlots.nextSlot value to write, or None if no
    # counter write is needed.
    counter_after: int | None = None


def compute_plan(
    provisioned_uids: Iterable[str],
    user_slots: Mapping[str, Any],
    raw_next_slot: Any,
) -> Plan:
    """Pure planning function - no I/O.

    provisioned_uids: every uid with a UserRoles/{uid} document.
    user_slots: uid -> raw Users/{uid}.accountSlot value, present only for
        uids whose Users document has that field set (any type, including
        malformed ones). Absent entries mean "no slot recorded".
    raw_next_slot: raw Counters/accountSlots.nextSlot value, or None if the
        counter document/field doesn't exist.
    """
    provisioned = set(provisioned_uids)

    malformed_slot = 0
    orphaned_slot = 0
    slot_owners: dict[int, list[str]] = {}
    provisioned_slot: dict[str, int] = {}
    all_valid_slots: list[int] = []

    for uid, raw in user_slots.items():
        if _is_valid_slot(raw):
            all_valid_slots.append(raw)
            slot_owners.setdefault(raw, []).append(uid)
            if uid in provisioned:
                provisioned_slot[uid] = raw
            else:
                orphaned_slot += 1
        else:
            malformed_slot += 1

    # A slot shared by two or more uids is ambiguous on the wire regardless
    # of provisioning status - it still consumes slot space.
    duplicate_uids: set[str] = set()
    duplicate_slot = 0
    for uids in slot_owners.values():
        if len(uids) > 1:
            duplicate_slot += len(uids)
            duplicate_uids.update(uids)

    already_assigned = {
        uid: slot for uid, slot in provisioned_slot.items() if uid not in duplicate_uids
    }
    already_assigned_count = len(already_assigned)

    missing_uids = sorted(
        uid for uid in provisioned if uid not in provisioned_slot or uid in duplicate_uids
    )

    # Every valid slot anywhere (including orphaned/duplicated ones) still
    # occupies slot space, so new assignments must start above all of them.
    base = max(all_valid_slots) if all_valid_slots else 0

    overflow = 0
    assignments: dict[str, int] = {}
    for offset, uid in enumerate(missing_uids, start=1):
        candidate = base + offset
        if candidate > MAX_ACCOUNT_SLOT:
            overflow += 1
        else:
            assignments[uid] = candidate

    highest_after = max(assignments.values()) if assignments else base

    counter_is_valid = _is_valid_slot(raw_next_slot)
    if raw_next_slot is None:
        counter_state = "missing"
    elif counter_is_valid:
        counter_state = "valid"
    else:
        counter_state = "malformed"
    counter_before = raw_next_slot if counter_is_valid else None

    failures = PlanFailures(
        malformed_slot=malformed_slot,
        duplicate_slot=duplicate_slot,
        orphaned_slot=orphaned_slot,
        overflow=overflow,
    )
    ok = not failures.blocking

    if not ok:
        # Fail closed: refuse to write anything at all.
        assignments = {}
        counter_after: int | None = None
    else:
        # Never lower a valid counter, never reset to 1 while any slot
        # exists. A missing/malformed counter is replaced outright.
        counter_target = max(highest_after + 1, counter_before) if counter_before is not None else highest_after + 1
        counter_after = counter_target if counter_target != counter_before else None

    unassigned_after = len(missing_uids) - len(assignments)

    return Plan(
        ok=ok,
        failures=failures,
        provisioned_count=len(provisioned),
        already_assigned_count=already_assigned_count,
        assignments=assignments,
        unassigned_after=unassigned_after,
        counter_state=counter_state,
        counter_before=counter_before,
        counter_after=counter_after,
    )


def format_report(plan: Plan, mode: str) -> str:
    """Aggregate-only report text. Never includes a uid, email, address, key,
    token, or configuration - only fixed labels and counts/slot numbers."""
    counter_before_text = plan.counter_before if plan.counter_before is not None else plan.counter_state
    counter_after_text = plan.counter_after if plan.counter_after is not None else "(unchanged)"
    lines = [
        f"mode: {mode}",
        f"provisioned accounts: {plan.provisioned_count}",
        f"already assigned: {plan.already_assigned_count}",
        f"newly assigned: {len(plan.assignments)}",
        f"unassigned after: {plan.unassigned_after}",
        f"counter before: {counter_before_text}",
        f"counter after: {counter_after_text}",
        f"validation failures - malformed slot: {plan.failures.malformed_slot}",
        f"validation failures - duplicate slot: {plan.failures.duplicate_slot}",
        f"validation failures - orphaned slot: {plan.failures.orphaned_slot}",
        f"validation failures - overflow: {plan.failures.overflow}",
    ]
    return "\n".join(lines)


def _read_state(db: Any, transaction: Any | None = None) -> tuple[set[str], dict[str, Any], Any]:
    """Read UserRoles, Users, and the slot counter. transaction=None is the
    preflight/dry-run read; a transaction is passed for the in-transaction
    re-read during --apply."""
    user_roles_ref = db.collection("UserRoles")
    users_ref = db.collection("Users")
    counter_ref = db.collection("Counters").document("accountSlots")

    if transaction is None:
        role_docs = list(user_roles_ref.stream())
        user_docs = list(users_ref.stream())
        counter_snapshot = counter_ref.get()
    else:
        role_docs = list(user_roles_ref.stream(transaction=transaction))
        user_docs = list(users_ref.stream(transaction=transaction))
        counter_snapshot = counter_ref.get(transaction=transaction)

    provisioned_uids = {doc.id for doc in role_docs}

    user_slots: dict[str, Any] = {}
    for doc in user_docs:
        slot_value = (doc.to_dict() or {}).get("accountSlot")
        # An explicit null means "no slot recorded", not a malformed one: the
        # API omits the field rather than writing None, and a null can never
        # reach the wire. Anything else present is classified by compute_plan.
        if slot_value is not None:
            user_slots[doc.id] = slot_value

    raw_next_slot = None
    if getattr(counter_snapshot, "exists", False):
        counter_data = counter_snapshot.to_dict() or {}
        raw_next_slot = counter_data.get("nextSlot")

    return provisioned_uids, user_slots, raw_next_slot


def _apply_within_transaction(
    transaction: Any,
    db: Any,
    preflight_plan: Plan,
    server_timestamp: Any,
) -> Plan:
    """Re-read state inside the transaction, recompute the plan, and compare
    it to the preflight plan before writing anything. Safe to invoke
    repeatedly: Firestore may retry the wrapping transactional function on
    contention, and this recompute-and-compare is what makes that safe.

    Kept free of any Firestore SDK import so it is directly unit-testable
    with fakes; the real SDK-specific transactional() wiring lives in
    _run_apply().
    """
    provisioned_uids, user_slots, raw_next_slot = _read_state(db, transaction)
    plan = compute_plan(provisioned_uids, user_slots, raw_next_slot)

    if plan != preflight_plan:
        raise MigrationAbortedError(
            "Firestore state changed between preflight and apply; aborting with zero writes."
        )
    if not plan.ok:
        raise MigrationAbortedError("Validation failed inside the transaction; aborting with zero writes.")

    write_count = len(plan.assignments) + (1 if plan.counter_after is not None else 0)
    if write_count > MAX_TRANSACTION_WRITES:
        raise MigrationAbortedError(
            "Plan write count exceeds the safety margin; aborting with zero writes."
        )

    users_ref = db.collection("Users")
    counter_ref = db.collection("Counters").document("accountSlots")

    for uid, slot in plan.assignments.items():
        transaction.set(users_ref.document(uid), {"accountSlot": slot}, merge=True)
    if plan.counter_after is not None:
        transaction.set(
            counter_ref,
            {"nextSlot": plan.counter_after, "updatedAt": server_timestamp},
            merge=True,
        )

    return plan


def _run_apply(db: Any, preflight_plan: Plan) -> Plan:
    """Real-SDK apply path: wraps _apply_within_transaction in an actual
    Firestore transaction. Lazily imported so the module (and the test
    module that loads it) never requires firebase_admin/google-cloud-
    firestore to be installed."""
    from google.cloud.firestore_v1 import SERVER_TIMESTAMP, transactional

    @transactional
    def _txn(transaction: Any) -> Plan:
        return _apply_within_transaction(transaction, db, preflight_plan, SERVER_TIMESTAMP)

    return _txn(db.transaction())


def _resolve_credentials_path(credentials_arg: str | None) -> str | None:
    if credentials_arg:
        return credentials_arg
    return os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")


def _get_firestore_client(credentials_path: str) -> Any:
    import firebase_admin
    from firebase_admin import credentials, firestore

    if not firebase_admin._apps:
        credential = credentials.Certificate(credentials_path)
        firebase_admin.initialize_app(credential)
    return firestore.client()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Backfill Users/{uid}.accountSlot for legacy provisioned accounts and "
            "seed/advance Counters/accountSlots.nextSlot. Dry-run by default."
        )
    )
    parser.add_argument(
        "--credentials",
        type=str,
        default=None,
        help="Path to a Firebase service-account JSON file (kept outside git). "
        "Falls back to GOOGLE_APPLICATION_CREDENTIALS if omitted.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write the computed plan. Without this flag, only reports what would happen.",
    )
    args = parser.parse_args(argv)

    credentials_path = _resolve_credentials_path(args.credentials)
    if not credentials_path:
        print(
            "No credentials provided: pass --credentials <service-account.json> "
            "or set GOOGLE_APPLICATION_CREDENTIALS.",
            file=sys.stderr,
        )
        return 2

    try:
        db = _get_firestore_client(credentials_path)
    except Exception as exc:
        print(f"Failed to initialize Firestore client: {type(exc).__name__}", file=sys.stderr)
        return 2

    try:
        provisioned_uids, user_slots, raw_next_slot = _read_state(db)
    except Exception as exc:
        print(f"Failed to read Firestore state: {type(exc).__name__}", file=sys.stderr)
        return 2

    plan = compute_plan(provisioned_uids, user_slots, raw_next_slot)
    mode = "apply" if args.apply else "dry-run"

    if not plan.ok:
        print(format_report(plan, mode=mode))
        print(
            "Refusing to write: validation failures present. See counts above and "
            "the README for remediation guidance.",
            file=sys.stderr,
        )
        return 1

    write_count = len(plan.assignments) + (1 if plan.counter_after is not None else 0)
    if write_count > MAX_TRANSACTION_WRITES:
        print(format_report(plan, mode=mode))
        print(
            f"Refusing to write: plan requires {write_count} writes, exceeding the "
            f"{MAX_TRANSACTION_WRITES}-write safety margin. Run in a controlled "
            "maintenance window or split the migration; see the README.",
            file=sys.stderr,
        )
        return 1

    if not args.apply:
        print(format_report(plan, mode=mode))
        return 0

    try:
        applied_plan = _run_apply(db, plan)
    except MigrationAbortedError as exc:
        # MigrationAbortedError text is aggregate-only by construction (see the
        # class docstring), so it is safe to surface verbatim.
        print(f"Apply aborted: {exc} No writes were made.", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"Firestore error during apply: {type(exc).__name__}", file=sys.stderr)
        return 1

    print(format_report(applied_plan, mode=mode))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
