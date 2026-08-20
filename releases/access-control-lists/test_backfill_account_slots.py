"""Unit tests for the legacy account-slot backfill migration.

Run with: python3 -m unittest releases/access-control-lists/test_backfill_account_slots.py

All test data below is obviously fake (uid-a, uid-b, ...); none of it is a
real uid, email, or address.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

_SPEC = importlib.util.spec_from_file_location(
    "backfill_account_slots", Path(__file__).with_name("backfill_account_slots.py")
)
assert _SPEC and _SPEC.loader
backfill = importlib.util.module_from_spec(_SPEC)
# dataclasses resolves type hints via sys.modules[cls.__module__], so the
# module must be registered before exec_module runs its class bodies.
sys.modules[_SPEC.name] = backfill
_SPEC.loader.exec_module(backfill)


# --- Fake Firestore primitives, mirroring scripts/test_backup_firestore.py ---


class FakeSnapshot:
    def __init__(self, doc_id: str, data: Any) -> None:
        self.id = doc_id
        self.exists = data is not None
        self._data = data

    def to_dict(self) -> Any:
        # Real Firestore snapshots always return a dict or None, but the row
        # preflight is defensive against a non-dict value too, so tests
        # need to be able to construct one.
        if self._data is None:
            return None
        if isinstance(self._data, dict):
            return dict(self._data)
        return self._data


class FakeDocumentRef:
    def __init__(self, collection: "FakeCollectionRef", doc_id: str) -> None:
        self._collection = collection
        self.collection_name = collection.name
        self.id = doc_id

    def get(self, transaction: Any = None) -> FakeSnapshot:
        return FakeSnapshot(self.id, self._collection.docs.get(self.id))


class FakeCollectionRef:
    def __init__(self, name: str, docs: dict[str, dict[str, Any]]) -> None:
        self.name = name
        self.docs = docs

    def document(self, doc_id: str) -> FakeDocumentRef:
        return FakeDocumentRef(self, doc_id)

    def stream(self, transaction: Any = None) -> list[FakeSnapshot]:
        return [FakeSnapshot(doc_id, data) for doc_id, data in self.docs.items()]


class FakeCollectionGroupRef:
    def __init__(self, docs: list[tuple[str, Any]]) -> None:
        self._docs = docs

    def stream(self) -> list[FakeSnapshot]:
        return [FakeSnapshot(doc_id, data) for doc_id, data in self._docs]


class FakeDb:
    def __init__(
        self,
        user_roles: dict[str, dict[str, Any]],
        users: dict[str, dict[str, Any]],
        counter: dict[str, Any] | None,
        *,
        instances: list[tuple[str, Any]] | None = None,
    ) -> None:
        counters_docs = {"accountSlots": counter} if counter is not None else {}
        self._collections = {
            "UserRoles": FakeCollectionRef("UserRoles", user_roles),
            "Users": FakeCollectionRef("Users", users),
            "Counters": FakeCollectionRef("Counters", counters_docs),
        }
        self._instances = instances or []
        # Every write this script can make goes through a transaction, so an
        # empty list here is proof that a refusal wrote nothing.
        self.transactions: list["FakeTransaction"] = []

    def collection(self, name: str) -> FakeCollectionRef:
        return self._collections[name]

    def collection_group(self, name: str) -> FakeCollectionGroupRef:
        assert name == "Instances"
        return FakeCollectionGroupRef(self._instances)

    def transaction(self) -> "FakeTransaction":
        transaction = FakeTransaction()
        self.transactions.append(transaction)
        return transaction


class FakeTransaction:
    def __init__(self) -> None:
        self.writes: list[tuple[str, str, dict[str, Any], bool]] = []

    def set(self, ref: FakeDocumentRef, data: dict[str, Any], merge: bool = False) -> None:
        self.writes.append((ref.collection_name, ref.id, dict(data), merge))


_FAKE_TIMESTAMP = "FAKE_SERVER_TIMESTAMP"


def _six_provisioned_uids() -> dict[str, dict[str, Any]]:
    return {f"uid-{c}": {"uid": f"uid-{c}", "roleId": "user"} for c in "abcdef"}


def _apply_via_fake(
    db: FakeDb, preflight_plan: Any, *, allow_initial_seed: bool = False
) -> tuple[Any, FakeTransaction]:
    transaction = FakeTransaction()
    applied_plan = backfill._apply_within_transaction(
        transaction, db, preflight_plan, _FAKE_TIMESTAMP, allow_initial_seed=allow_initial_seed
    )
    return applied_plan, transaction


class ComputePlanTests(unittest.TestCase):
    def test_initial_pre_activation_seed_from_zero_slots_and_no_counter(self) -> None:
        provisioned = {f"uid-{c}" for c in "abcdef"}
        plan = backfill.compute_plan(provisioned, {}, None, allow_initial_seed=True)

        self.assertTrue(plan.ok)
        self.assertEqual(plan.provisioned_count, 6)
        self.assertEqual(plan.already_assigned_count, 0)
        self.assertEqual(len(plan.assignments), 6)
        self.assertEqual(sorted(plan.assignments), [f"uid-{c}" for c in "abcdef"])
        self.assertEqual(sorted(plan.assignments.values()), [1, 2, 3, 4, 5, 6])
        self.assertEqual(plan.unassigned_after, 0)
        self.assertEqual(plan.counter_state, "missing")
        self.assertIsNone(plan.counter_before)
        self.assertEqual(plan.counter_after, 7)
        self.assertEqual(plan.failures, backfill.PlanFailures())

    def test_idempotent_rerun_is_empty_plan(self) -> None:
        provisioned = {f"uid-{c}" for c in "abcdef"}
        user_slots = {f"uid-{c}": i + 1 for i, c in enumerate("abcdef")}
        plan = backfill.compute_plan(provisioned, user_slots, 7)

        self.assertTrue(plan.ok)
        self.assertEqual(plan.already_assigned_count, 6)
        self.assertEqual(plan.assignments, {})
        self.assertEqual(plan.unassigned_after, 0)
        self.assertIsNone(plan.counter_after)

        applied_plan, transaction = _apply_via_fake(
            FakeDb(_six_provisioned_uids(), {u: {"accountSlot": s} for u, s in user_slots.items()}, {"nextSlot": 7}),
            plan,
        )
        self.assertEqual(transaction.writes, [])
        self.assertEqual(applied_plan, plan)

    def test_partial_prior_assignment_fills_gaps_above_existing_max(self) -> None:
        provisioned = {f"uid-{c}" for c in "abcdef"}
        user_slots = {"uid-a": 3, "uid-b": 1}
        plan = backfill.compute_plan(provisioned, user_slots, None, allow_initial_seed=True)

        self.assertTrue(plan.ok)
        self.assertEqual(plan.already_assigned_count, 2)
        # uid-c, uid-d, uid-e, uid-f get 4, 5, 6, 7 (sorted ascending by uid).
        self.assertEqual(plan.assignments, {"uid-c": 4, "uid-d": 5, "uid-e": 6, "uid-f": 7})
        self.assertEqual(plan.counter_after, 8)

    # --- Counter lifecycle: seeding vs. post-activation corruption -------

    def test_counter_corruption_variants_are_seeded_only_with_the_explicit_flag(self) -> None:
        provisioned = {"uid-a"}
        user_slots = {"uid-a": 5}
        for bad_counter in (0, -1, "7", True, 3.5, backfill.MAX_ACCOUNT_SLOT + 1):
            with self.subTest(bad_counter=bad_counter):
                plan = backfill.compute_plan(provisioned, user_slots, bad_counter, allow_initial_seed=True)
                self.assertTrue(plan.ok)
                self.assertEqual(plan.counter_state, "malformed")
                self.assertIsNone(plan.counter_before)
                self.assertEqual(plan.counter_after, 6)
                self.assertEqual(plan.failures, backfill.PlanFailures())

    def test_malformed_counter_without_the_seed_flag_blocks_with_zero_writes(self) -> None:
        # After activation, a malformed counter is counter loss: the slots of
        # hard-deleted accounts are unrepresented in live Users, so the live
        # scan cannot rebuild the watermark.
        provisioned = {"uid-a", "uid-b"}
        user_slots = {"uid-a": 5}
        for bad_counter in (0, -1, "7", True, 3.5, backfill.MAX_ACCOUNT_SLOT + 1):
            with self.subTest(bad_counter=bad_counter):
                plan = backfill.compute_plan(provisioned, user_slots, bad_counter)
                self.assertFalse(plan.ok)
                self.assertEqual(plan.counter_state, "malformed")
                self.assertEqual(plan.failures.counter_unseeded, 1)
                self.assertEqual(plan.assignments, {})
                self.assertIsNone(plan.counter_after)

    def test_missing_counter_without_the_seed_flag_blocks_with_zero_writes(self) -> None:
        plan = backfill.compute_plan({"uid-a", "uid-b"}, {"uid-a": 5}, None)

        self.assertFalse(plan.ok)
        self.assertEqual(plan.counter_state, "missing")
        self.assertEqual(plan.failures.counter_unseeded, 1)
        self.assertEqual(plan.assignments, {})
        self.assertIsNone(plan.counter_after)

        db = FakeDb({"uid-a": {}, "uid-b": {}}, {"uid-a": {"accountSlot": 5}}, None)
        transaction = FakeTransaction()
        with self.assertRaises(backfill.MigrationAbortedError):
            backfill._apply_within_transaction(transaction, db, plan, _FAKE_TIMESTAMP)
        self.assertEqual(transaction.writes, [])

    def test_missing_counter_with_the_seed_flag_is_derived_from_the_live_scan(self) -> None:
        plan = backfill.compute_plan({"uid-a"}, {"uid-a": 5}, None, allow_initial_seed=True)
        self.assertTrue(plan.ok)
        self.assertEqual(plan.counter_state, "missing")
        self.assertEqual(plan.counter_after, 6)

    def test_valid_counter_at_or_below_the_live_max_blocks_as_regressed(self) -> None:
        # A counter that a live slot has already reached moved backward. It
        # can no longer prove which slots were issued, and advancing it from
        # the live max would silently re-issue anything in the gap - the same
        # decision repository.next_account_slot makes at runtime.
        provisioned = {"uid-a", "uid-b", "uid-c"}
        user_slots = {"uid-a": 1, "uid-b": 2}
        for stale_counter in (1, 2):
            with self.subTest(stale_counter=stale_counter):
                plan = backfill.compute_plan(provisioned, user_slots, stale_counter)
                self.assertFalse(plan.ok)
                self.assertEqual(plan.counter_state, "valid")
                self.assertEqual(plan.counter_before, stale_counter)
                self.assertEqual(plan.failures.counter_regressed, 1)
                self.assertEqual(plan.assignments, {})
                self.assertIsNone(plan.counter_after)

    def test_regressed_counter_is_not_overridable_by_the_seed_flag(self) -> None:
        plan = backfill.compute_plan({"uid-a", "uid-b"}, {"uid-a": 5}, 5, allow_initial_seed=True)

        self.assertFalse(plan.ok)
        self.assertEqual(plan.failures.counter_regressed, 1)
        self.assertEqual(plan.assignments, {})

    # --- Finding 1/9: a valid counter is the allocation floor ------------

    def test_valid_counter_above_live_max_is_the_floor_for_a_new_assignment(self) -> None:
        # The exact ordering that let the migration re-issue a hard-deleted
        # account's slot: slots 2..9 are absent from live Users only because
        # their accounts were deleted, and the counter is the sole record of
        # them. Numbering from the live max would hand uid-b slot 2.
        plan = backfill.compute_plan({"uid-a", "uid-b"}, {"uid-a": 1}, 10)

        self.assertTrue(plan.ok)
        self.assertEqual(plan.counter_state, "valid")
        self.assertEqual(plan.counter_before, 10)
        self.assertEqual(plan.assignments, {"uid-b": 10})
        self.assertEqual(plan.counter_after, 11)

    def test_valid_counter_above_live_max_with_multiple_pending_users(self) -> None:
        plan = backfill.compute_plan({"uid-a", "uid-b", "uid-c", "uid-d"}, {"uid-a": 1}, 10)

        self.assertTrue(plan.ok)
        # Deterministic ascending-by-uid ordering, starting at the counter.
        self.assertEqual(plan.assignments, {"uid-b": 10, "uid-c": 11, "uid-d": 12})
        self.assertEqual(plan.counter_after, 13)

    def test_gap_left_by_a_deleted_account_is_never_reused(self) -> None:
        # Live max is 3; slots 4 and 5 belonged to accounts that were hard
        # deleted, so only the counter (6) still knows they were issued.
        plan = backfill.compute_plan({"uid-b", "uid-c", "uid-d"}, {"uid-b": 3}, 6)

        self.assertTrue(plan.ok)
        self.assertEqual(plan.assignments, {"uid-c": 6, "uid-d": 7})
        self.assertNotIn(4, plan.assignments.values())
        self.assertNotIn(5, plan.assignments.values())
        self.assertEqual(plan.counter_after, 8)

    def test_counter_exactly_one_above_the_live_max_is_the_healthy_boundary(self) -> None:
        # The steady state: every runtime allocation stores slot + 1. The
        # counter and the live max agree, and numbering continues from both.
        plan = backfill.compute_plan({"uid-a", "uid-b", "uid-c"}, {"uid-a": 1, "uid-b": 2}, 3)

        self.assertTrue(plan.ok)
        self.assertEqual(plan.failures, backfill.PlanFailures())
        self.assertEqual(plan.assignments, {"uid-c": 3})
        self.assertEqual(plan.counter_after, 4)

    def test_valid_counter_strictly_above_max_is_left_unchanged(self) -> None:
        plan = backfill.compute_plan({"uid-a"}, {"uid-a": 1}, 10)
        self.assertTrue(plan.ok)
        self.assertEqual(plan.counter_before, 10)
        self.assertIsNone(plan.counter_after)

    def test_duplicate_slots_across_two_uids_block_with_zero_writes(self) -> None:
        provisioned = {"uid-a", "uid-b"}
        user_slots = {"uid-a": 4, "uid-b": 4}
        plan = backfill.compute_plan(provisioned, user_slots, 5)

        self.assertFalse(plan.ok)
        self.assertEqual(plan.failures.duplicate_slot, 2)
        self.assertEqual(plan.assignments, {})
        self.assertIsNone(plan.counter_after)

        transaction = FakeTransaction()
        db = FakeDb(
            {"uid-a": {}, "uid-b": {}},
            {"uid-a": {"accountSlot": 4}, "uid-b": {"accountSlot": 4}},
            {"nextSlot": 5},
        )
        with self.assertRaises(backfill.MigrationAbortedError):
            backfill._apply_within_transaction(transaction, db, plan, _FAKE_TIMESTAMP)
        self.assertEqual(transaction.writes, [])

    def test_malformed_slot_values_block_with_zero_writes(self) -> None:
        provisioned = {"uid-a", "uid-b"}
        for bad_value in (0, -3, "7", True, 4.5, backfill.MAX_ACCOUNT_SLOT + 1):
            with self.subTest(bad_value=bad_value):
                plan = backfill.compute_plan(provisioned, {"uid-a": bad_value}, 1)
                self.assertFalse(plan.ok)
                self.assertEqual(plan.failures.malformed_slot, 1)
                self.assertEqual(plan.assignments, {})

    def test_slot_on_non_provisioned_uid_blocks(self) -> None:
        provisioned = {"uid-a"}
        user_slots = {"uid-a": 1, "uid-orphan": 2}
        plan = backfill.compute_plan(provisioned, user_slots, 3)

        self.assertFalse(plan.ok)
        self.assertEqual(plan.failures.orphaned_slot, 1)
        self.assertEqual(plan.assignments, {})

    def test_overflow_blocks_with_zero_writes(self) -> None:
        provisioned = {"uid-a", "uid-b"}
        user_slots = {"uid-a": backfill.MAX_ACCOUNT_SLOT}
        plan = backfill.compute_plan(provisioned, user_slots, None, allow_initial_seed=True)

        self.assertFalse(plan.ok)
        self.assertEqual(plan.failures.overflow, 1)
        self.assertEqual(plan.assignments, {})
        self.assertIsNone(plan.counter_after)

    def test_exhaustion_at_the_counter_floor_blocks_with_zero_writes(self) -> None:
        # The counter itself is at the last slot: one account can still be
        # assigned in principle, but the second exhausts the space, so the
        # whole plan is refused rather than partially applied.
        plan = backfill.compute_plan({"uid-a", "uid-b", "uid-c"}, {"uid-a": 1}, backfill.MAX_ACCOUNT_SLOT)

        self.assertFalse(plan.ok)
        self.assertEqual(plan.failures.overflow, 1)
        self.assertEqual(plan.assignments, {})
        self.assertIsNone(plan.counter_after)


class ApplyTransactionTests(unittest.TestCase):
    def test_transaction_retry_produces_identical_writes(self) -> None:
        provisioned = _six_provisioned_uids()
        users = {"uid-a": {"accountSlot": 3}}
        db = FakeDb(provisioned, users, {"nextSlot": 4})
        provisioned_uids, user_slots, raw_next_slot = backfill._read_state(db)
        preflight_plan = backfill.compute_plan(provisioned_uids, user_slots, raw_next_slot)

        _, transaction1 = _apply_via_fake(db, preflight_plan)
        _, transaction2 = _apply_via_fake(db, preflight_plan)

        self.assertEqual(transaction1.writes, transaction2.writes)
        self.assertTrue(transaction1.writes)

    def test_invariant_change_during_transaction_aborts_with_zero_writes(self) -> None:
        preflight_db = FakeDb(_six_provisioned_uids(), {}, {"nextSlot": 1})
        provisioned_uids, user_slots, raw_next_slot = backfill._read_state(preflight_db)
        preflight_plan = backfill.compute_plan(provisioned_uids, user_slots, raw_next_slot)

        # A concurrent allocation landed between preflight and apply: uid-a
        # already has a slot and the counter moved with it, so the
        # in-transaction recompute disagrees with the preflight plan.
        changed_db = FakeDb(_six_provisioned_uids(), {"uid-a": {"accountSlot": 1}}, {"nextSlot": 2})
        transaction = FakeTransaction()

        with self.assertRaises(backfill.MigrationAbortedError):
            backfill._apply_within_transaction(transaction, changed_db, preflight_plan, _FAKE_TIMESTAMP)

        self.assertEqual(transaction.writes, [])

    def test_counter_moving_alone_between_preflight_and_apply_aborts(self) -> None:
        # Only the counter changed underneath the run - the assignments the
        # preflight planned would now sit below the counter.
        preflight_db = FakeDb({"uid-a": {}, "uid-b": {}}, {"uid-a": {"accountSlot": 1}}, {"nextSlot": 2})
        provisioned_uids, user_slots, raw_next_slot = backfill._read_state(preflight_db)
        preflight_plan = backfill.compute_plan(provisioned_uids, user_slots, raw_next_slot)
        self.assertEqual(preflight_plan.assignments, {"uid-b": 2})

        changed_db = FakeDb({"uid-a": {}, "uid-b": {}}, {"uid-a": {"accountSlot": 1}}, {"nextSlot": 9})
        transaction = FakeTransaction()

        with self.assertRaises(backfill.MigrationAbortedError):
            backfill._apply_within_transaction(transaction, changed_db, preflight_plan, _FAKE_TIMESTAMP)

        self.assertEqual(transaction.writes, [])

    def test_apply_writes_merge_true_and_only_account_slot_field(self) -> None:
        db = FakeDb({"uid-a": {}}, {}, {"nextSlot": 1})
        provisioned_uids, user_slots, raw_next_slot = backfill._read_state(db)
        preflight_plan = backfill.compute_plan(provisioned_uids, user_slots, raw_next_slot)

        _, transaction = _apply_via_fake(db, preflight_plan)

        user_writes = [w for w in transaction.writes if w[0] == "Users"]
        self.assertEqual(len(user_writes), 1)
        _collection, doc_id, data, merge = user_writes[0]
        self.assertEqual(doc_id, "uid-a")
        self.assertEqual(data, {"accountSlot": 1})
        self.assertTrue(merge)

        counter_writes = [w for w in transaction.writes if w[0] == "Counters"]
        self.assertEqual(len(counter_writes), 1)
        _, counter_doc_id, counter_data, counter_merge = counter_writes[0]
        self.assertEqual(counter_doc_id, "accountSlots")
        self.assertEqual(counter_data, {"nextSlot": 2, "updatedAt": _FAKE_TIMESTAMP})
        self.assertTrue(counter_merge)


# --- The 400-write transaction guard ------------------------------------
#
# The guard is the mechanism that keeps this single-transaction migration
# from ever running "halfway" (README, "The 400-write guard"). The counter
# update is itself one write, and omitting it is the easy off-by-one, so the
# matrix below pins both sides of the boundary with and without it, at both
# enforcement points: _apply_within_transaction and main().


def _uids(count: int, prefix: str = "uid-fake-") -> list[str]:
    # Zero-padded so the migration's ascending-by-uid ordering is the same as
    # numeric ordering, keeping expected slot values easy to reason about.
    return [f"{prefix}{index:04d}" for index in range(count)]


def _db_needing_assignments(count: int) -> FakeDb:
    """A fleet where `count` provisioned accounts need a new slot and the
    counter is valid at 1, so the plan is exactly `count` user writes plus
    one counter write."""
    return FakeDb({uid: {"roleId": "user"} for uid in _uids(count)}, {}, {"nextSlot": 1})


def _plan_with_writes(assignment_count: int, *, counter_write: bool) -> Any:
    """A Plan carrying an exact write shape, including the counter-write-free
    shape that compute_plan cannot produce on its own (every new assignment
    advances the counter). Used to drive the guard directly."""
    assignments = {uid: index + 1 for index, uid in enumerate(_uids(assignment_count))}
    return backfill.Plan(
        ok=True,
        failures=backfill.PlanFailures(),
        provisioned_count=assignment_count,
        already_assigned_count=0,
        assignments=assignments,
        unassigned_after=0,
        counter_state="valid",
        counter_before=1,
        counter_after=assignment_count + 1 if counter_write else None,
    )


_WRITE_LIMIT_MATRIX = (
    # (assignment writes, counter write, total, allowed)
    (399, True, 400, True),
    (400, False, 400, True),
    (400, True, 401, False),
    (401, False, 401, False),
)


class TransactionWriteGuardTests(unittest.TestCase):
    def test_write_count_includes_the_counter_write(self) -> None:
        for assignments, counter_write, total, _allowed in _WRITE_LIMIT_MATRIX:
            with self.subTest(assignments=assignments, counter_write=counter_write):
                plan = _plan_with_writes(assignments, counter_write=counter_write)
                self.assertEqual(backfill.plan_write_count(plan), total)

    def test_limit_is_the_documented_safety_margin_below_the_firestore_maximum(self) -> None:
        self.assertEqual(backfill.MAX_TRANSACTION_WRITES, 400)

    def test_transaction_allows_exactly_the_limit_and_refuses_one_over(self) -> None:
        # Reachable through real state: N assignments always drag the counter
        # write along, so 399 + counter = 400 and 400 + counter = 401.
        for provisioned_count, allowed in ((399, True), (400, False)):
            with self.subTest(provisioned_count=provisioned_count):
                db = _db_needing_assignments(provisioned_count)
                provisioned_uids, user_slots, raw_next_slot = backfill._read_state(db)
                plan = backfill.compute_plan(provisioned_uids, user_slots, raw_next_slot)
                self.assertEqual(backfill.plan_write_count(plan), provisioned_count + 1)

                transaction = FakeTransaction()
                if allowed:
                    backfill._apply_within_transaction(transaction, db, plan, _FAKE_TIMESTAMP)
                    self.assertEqual(len(transaction.writes), backfill.MAX_TRANSACTION_WRITES)
                else:
                    with self.assertRaises(backfill.MigrationAbortedError):
                        backfill._apply_within_transaction(transaction, db, plan, _FAKE_TIMESTAMP)
                    self.assertEqual(transaction.writes, [])

    def test_transaction_boundary_without_a_counter_write(self) -> None:
        # The counter-write-free shape of the same boundary: 400 assignment
        # writes alone are allowed, 401 are not.
        for assignments, allowed in ((400, True), (401, False)):
            with self.subTest(assignments=assignments):
                plan = _plan_with_writes(assignments, counter_write=False)
                db = _db_needing_assignments(1)
                transaction = FakeTransaction()

                with mock.patch.object(backfill, "compute_plan", return_value=plan):
                    if allowed:
                        backfill._apply_within_transaction(transaction, db, plan, _FAKE_TIMESTAMP)
                        self.assertEqual(len(transaction.writes), assignments)
                        self.assertEqual([w for w in transaction.writes if w[0] == "Counters"], [])
                    else:
                        with self.assertRaises(backfill.MigrationAbortedError):
                            backfill._apply_within_transaction(transaction, db, plan, _FAKE_TIMESTAMP)
                        self.assertEqual(transaction.writes, [])


def _empty_row_result() -> Any:
    return backfill.RowPreflightResult(
        ok=True, failures=backfill.RowPreflightFailures(), rows_checked=0, rows_valid=0
    )


class AggregateOutputTests(unittest.TestCase):
    def test_report_never_contains_seeded_fake_identifiers(self) -> None:
        fake_uids = [f"uid-{c}" for c in "abcdef"] + ["uid-orphan"]
        fake_email = "fake-user@example.invalid"
        provisioned = set(fake_uids[:6])
        user_slots = {"uid-a": 3, "uid-orphan": 9}
        plan = backfill.compute_plan(provisioned, user_slots, "not-a-slot")

        report = backfill.format_report(plan, _empty_row_result(), mode="dry-run")

        for uid in fake_uids:
            self.assertNotIn(uid, report)
        self.assertNotIn(fake_email, report)
        self.assertNotIn("not-a-slot", report)

    def test_report_is_aggregate_counts_for_a_successful_plan(self) -> None:
        provisioned = {f"uid-{c}" for c in "abcdef"}
        plan = backfill.compute_plan(provisioned, {}, None, allow_initial_seed=True)
        report = backfill.format_report(plan, _empty_row_result(), mode="dry-run")

        self.assertIn("mode: dry-run", report)
        self.assertIn("provisioned accounts: 6", report)
        self.assertIn("newly assigned: 6", report)
        self.assertIn("counter after: 7", report)
        for uid in provisioned:
            self.assertNotIn(uid, report)

    def test_report_includes_row_preflight_counts_and_no_identifiers(self) -> None:
        provisioned = {"uid-a"}
        plan = backfill.compute_plan(provisioned, {"uid-a": 1}, 2)

        fake_owner = "uid-conflicted-fake"
        result = backfill.validate_policy_rows(
            [backfill.RawPolicyRow(owner_uid=fake_owner, address_v4=123, address_v6="fd42:42:42::2/128")],
            {fake_owner: 1},
            malformed_document_count=2,
        )

        report = backfill.format_report(plan, result, mode="apply")

        self.assertIn("policy row preflight: blocked", report)
        self.assertIn("policy rows checked: 3", report)
        self.assertIn("policy rows valid: 0", report)
        self.assertIn("policy row failures - malformed document: 2", report)
        self.assertIn("policy row failures - invalid address: 1", report)
        self.assertNotIn(fake_owner, report)


# --- Wave 2: fleet-wide policy-row preflight fixtures ---

_GOOD_V4_A = "10.0.0.2/32"
_GOOD_V4_B = "10.0.0.3/32"
_GOOD_V6_A = "fd42:42:42::2/128"
_GOOD_V6_B = "fd42:42:42::3/128"


def _row(owner_uid: Any, address_v4: Any, address_v6: Any) -> Any:
    return backfill.RawPolicyRow(owner_uid=owner_uid, address_v4=address_v4, address_v6=address_v6)


class BuildEffectiveSlotMapTests(unittest.TestCase):
    def test_valid_existing_slots_and_assignments_are_unioned(self) -> None:
        user_slots = {"uid-a": 3, "uid-b": "not-a-slot", "uid-c": True}
        assignments = {"uid-d": 4}

        effective = backfill.build_effective_slot_map(user_slots, assignments)

        self.assertEqual(effective, {"uid-a": 3, "uid-d": 4})


class ValidatePolicyRowsTests(unittest.TestCase):
    def test_clean_fleet_passes(self) -> None:
        rows = [_row("uid-a", _GOOD_V4_A, _GOOD_V6_A)]
        result = backfill.validate_policy_rows(rows, {"uid-a": 1})

        self.assertTrue(result.ok)
        self.assertEqual(result.rows_checked, 1)
        self.assertEqual(result.rows_valid, 1)
        self.assertEqual(result.failures, backfill.RowPreflightFailures())

    def test_malformed_or_unhashable_owner_uid_is_invalid_owner(self) -> None:
        for bad_owner in (None, 123, 4.5, True, "", ["unhashable"], {"nested": "dict"}):
            with self.subTest(bad_owner=bad_owner):
                rows = [_row(bad_owner, _GOOD_V4_A, _GOOD_V6_A)]
                result = backfill.validate_policy_rows(rows, {})

                self.assertFalse(result.ok)
                self.assertEqual(result.failures.invalid_owner, 1)
                self.assertEqual(result.rows_valid, 0)

    def test_owner_with_no_effective_slot_is_invalid_slot(self) -> None:
        rows = [_row("uid-unassigned", _GOOD_V4_A, _GOOD_V6_A)]
        result = backfill.validate_policy_rows(rows, {"uid-other": 1})

        self.assertFalse(result.ok)
        self.assertEqual(result.failures.invalid_slot, 1)

    def test_non_string_unparseable_and_wrong_family_addresses_are_invalid(self) -> None:
        bad_addresses = [
            123,  # non-string
            "not-an-ip",  # unparseable
            _GOOD_V6_A,  # wrong family for the v4 slot
        ]
        for bad_v4 in bad_addresses:
            with self.subTest(bad_v4=bad_v4):
                rows = [_row("uid-a", bad_v4, _GOOD_V6_A)]
                result = backfill.validate_policy_rows(rows, {"uid-a": 1})

                self.assertFalse(result.ok)
                self.assertEqual(result.failures.invalid_address, 1)

        # Same set of failure modes on the v6 side.
        for bad_v6 in (123, "not-an-ip", _GOOD_V4_A):
            with self.subTest(bad_v6=bad_v6):
                rows = [_row("uid-a", _GOOD_V4_A, bad_v6)]
                result = backfill.validate_policy_rows(rows, {"uid-a": 1})

                self.assertFalse(result.ok)
                self.assertEqual(result.failures.invalid_address, 1)

    def test_wrong_prefix_addresses_are_invalid(self) -> None:
        for bad_v4 in ("10.0.0.0/24", "10.0.0.2/31"):
            with self.subTest(bad_v4=bad_v4):
                rows = [_row("uid-a", bad_v4, _GOOD_V6_A)]
                result = backfill.validate_policy_rows(rows, {"uid-a": 1})
                self.assertEqual(result.failures.invalid_address, 1)

        for bad_v6 in ("fd42:42:42::/64", "fd42:42:42::2/127"):
            with self.subTest(bad_v6=bad_v6):
                rows = [_row("uid-a", _GOOD_V4_A, bad_v6)]
                result = backfill.validate_policy_rows(rows, {"uid-a": 1})
                self.assertEqual(result.failures.invalid_address, 1)

    def test_bare_address_with_no_explicit_prefix_is_valid(self) -> None:
        # ipaddress.ip_interface defaults an unqualified address to a host
        # prefix (/32, /128) - the same parse policy_sync.bare_tunnel_address
        # relies on - so a bare address is not a failure here either.
        rows = [_row("uid-a", "10.0.0.2", "fd42:42:42::2")]
        result = backfill.validate_policy_rows(rows, {"uid-a": 1})

        self.assertTrue(result.ok)
        self.assertEqual(result.rows_valid, 1)

    def test_addresses_outside_aggregate_are_invalid(self) -> None:
        rows = [_row("uid-a", "192.168.1.2/32", _GOOD_V6_A)]
        result = backfill.validate_policy_rows(rows, {"uid-a": 1})
        self.assertEqual(result.failures.invalid_address, 1)

        rows = [_row("uid-a", _GOOD_V4_A, "fd00::2/128")]
        result = backfill.validate_policy_rows(rows, {"uid-a": 1})
        self.assertEqual(result.failures.invalid_address, 1)

    def test_duplicate_v4_address_excludes_both_rows_either_collection_order(self) -> None:
        rows = [
            _row("uid-a", _GOOD_V4_A, _GOOD_V6_A),
            _row("uid-b", _GOOD_V4_A, _GOOD_V6_B),
        ]
        for ordered_rows in (rows, list(reversed(rows))):
            with self.subTest(order=[r.owner_uid for r in ordered_rows]):
                result = backfill.validate_policy_rows(ordered_rows, {"uid-a": 1, "uid-b": 2})

                self.assertFalse(result.ok)
                self.assertEqual(result.failures.duplicate_address, 2)
                self.assertEqual(result.rows_valid, 0)

    def test_duplicate_v6_address_excludes_both_rows_either_collection_order(self) -> None:
        rows = [
            _row("uid-a", _GOOD_V4_A, _GOOD_V6_A),
            _row("uid-b", _GOOD_V4_B, _GOOD_V6_A),
        ]
        for ordered_rows in (rows, list(reversed(rows))):
            with self.subTest(order=[r.owner_uid for r in ordered_rows]):
                result = backfill.validate_policy_rows(ordered_rows, {"uid-a": 1, "uid-b": 2})

                self.assertFalse(result.ok)
                self.assertEqual(result.failures.duplicate_address, 2)

    def test_duplicate_slot_across_two_uids_excludes_both(self) -> None:
        rows = [
            _row("uid-a", _GOOD_V4_A, _GOOD_V6_A),
            _row("uid-b", _GOOD_V4_B, _GOOD_V6_B),
        ]
        result = backfill.validate_policy_rows(rows, {"uid-a": 9, "uid-b": 9})

        self.assertFalse(result.ok)
        self.assertEqual(result.failures.duplicate_slot, 2)
        self.assertEqual(result.rows_valid, 0)

    def test_duplicate_slot_excludes_rows_even_when_the_other_owner_has_no_row(self) -> None:
        # The colliding account has no active client, so it contributes no row
        # of its own - desired_policy() still excludes every uid sharing the
        # slot, and the preflight must agree or it would pass data that the
        # runtime silently drops.
        rows = [_row("uid-a", _GOOD_V4_A, _GOOD_V6_A)]
        result = backfill.validate_policy_rows(rows, {"uid-a": 9, "uid-clientless": 9})

        self.assertFalse(result.ok)
        self.assertEqual(result.failures.duplicate_slot, 1)
        self.assertEqual(result.rows_valid, 0)

    def test_several_clients_of_one_uid_sharing_one_slot_is_valid(self) -> None:
        rows = [
            _row("uid-a", _GOOD_V4_A, _GOOD_V6_A),
            _row("uid-a", _GOOD_V4_B, _GOOD_V6_B),
        ]
        result = backfill.validate_policy_rows(rows, {"uid-a": 1})

        self.assertTrue(result.ok)
        self.assertEqual(result.rows_valid, 2)
        self.assertEqual(result.failures.duplicate_slot, 0)

    def test_owner_whose_slot_only_exists_via_this_migrations_plan_is_valid(self) -> None:
        effective_slots = backfill.build_effective_slot_map({}, {"uid-a": 7})
        rows = [_row("uid-a", _GOOD_V4_A, _GOOD_V6_A)]
        result = backfill.validate_policy_rows(rows, effective_slots)

        self.assertTrue(result.ok)
        self.assertEqual(result.rows_valid, 1)

    def test_mixed_valid_invalid_snapshot_exact_counts(self) -> None:
        rows = [
            _row("uid-a", _GOOD_V4_A, _GOOD_V6_A),  # valid
            _row(None, _GOOD_V4_B, _GOOD_V6_B),  # invalid owner
            _row("uid-unassigned", "10.0.0.9/32", "fd42:42:42::9/128"),  # invalid slot
            _row("uid-b", "not-an-ip", _GOOD_V6_B),  # invalid address
            _row("uid-c", "10.0.0.10/32", "fd42:42:42::10/128"),  # duplicate w/ uid-d
            _row("uid-d", "10.0.0.10/32", "fd42:42:42::11/128"),  # duplicate w/ uid-c
            _row("uid-e", "10.0.0.11/32", "fd42:42:42::12/128"),  # duplicate slot w/ uid-f
            _row("uid-f", "10.0.0.12/32", "fd42:42:42::13/128"),  # duplicate slot w/ uid-e
        ]
        effective_slots = {"uid-a": 1, "uid-b": 2, "uid-c": 3, "uid-d": 4, "uid-e": 5, "uid-f": 5}
        result = backfill.validate_policy_rows(rows, effective_slots, malformed_document_count=1)

        self.assertFalse(result.ok)
        self.assertEqual(result.rows_checked, len(rows) + 1)
        self.assertEqual(result.failures.malformed_document, 1)
        self.assertEqual(result.failures.invalid_owner, 1)
        self.assertEqual(result.failures.invalid_slot, 1)
        self.assertEqual(result.failures.invalid_address, 1)
        self.assertEqual(result.failures.duplicate_address, 2)
        self.assertEqual(result.failures.duplicate_slot, 2)
        self.assertEqual(result.rows_valid, 1)


class ReadPolicyRowsTests(unittest.TestCase):
    def test_active_keyed_clients_are_read(self) -> None:
        db = FakeDb(
            {},
            {},
            None,
            instances=[
                (
                    "inst-1",
                    {
                        "status": "active",
                        "clientPublicKey": "fake-key",
                        "ownerUid": "uid-a",
                        "assignedTunnelIpv4": _GOOD_V4_A,
                        "assignedTunnelIpv6": _GOOD_V6_A,
                    },
                )
            ],
        )
        rows, malformed_document_count = backfill._read_policy_rows(db)

        self.assertEqual(malformed_document_count, 0)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].owner_uid, "uid-a")

    def test_non_active_and_unkeyed_clients_are_excluded_not_counted(self) -> None:
        db = FakeDb(
            {},
            {},
            None,
            instances=[
                ("inst-creating", {"status": "creating", "clientPublicKey": "fake-key"}),
                ("inst-removed", {"status": "removed", "clientPublicKey": "fake-key"}),
                ("inst-unkeyed", {"status": "active", "clientPublicKey": ""}),
                ("inst-unkeyed-2", {"status": "active", "clientPublicKey": None}),
            ],
        )
        rows, malformed_document_count = backfill._read_policy_rows(db)

        self.assertEqual(rows, [])
        self.assertEqual(malformed_document_count, 0)

    def test_non_dict_document_data_is_malformed_not_an_exception(self) -> None:
        db = FakeDb({}, {}, None, instances=[("inst-1", "not-a-dict")])
        rows, malformed_document_count = backfill._read_policy_rows(db)

        self.assertEqual(rows, [])
        self.assertEqual(malformed_document_count, 1)

    def test_document_missing_status_or_client_public_key_is_excluded(self) -> None:
        # Mirrors firebase.py _client_from_data: an absent field reads as ""
        # there, so such a document is simply not active/keyed - not part of
        # the policy fleet, and not a migration blocker.
        db = FakeDb(
            {},
            {},
            None,
            instances=[
                ("inst-missing-status", {"clientPublicKey": "fake-key"}),
                ("inst-missing-key", {"status": "active"}),
            ],
        )
        rows, malformed_document_count = backfill._read_policy_rows(db)

        self.assertEqual(rows, [])
        self.assertEqual(malformed_document_count, 0)


def _run_main(db: Any, extra_args: list[str]) -> tuple[int, str, str]:
    """main() against a FakeDb, capturing (exit code, stdout, stderr)."""
    stdout, stderr = io.StringIO(), io.StringIO()
    with mock.patch.object(backfill, "_get_firestore_client", return_value=db):
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = backfill.main(["--credentials", "/tmp/fake-creds.json", *extra_args])
    return code, stdout.getvalue(), stderr.getvalue()


class MainGatingTests(unittest.TestCase):
    def _bad_row_db(self) -> Any:
        return FakeDb(
            _six_provisioned_uids(),
            {},
            {"nextSlot": 1},
            instances=[
                (
                    "inst-1",
                    {
                        "status": "active",
                        "clientPublicKey": "fake-key",
                        "ownerUid": 12345,  # invalid owner
                        "assignedTunnelIpv4": _GOOD_V4_A,
                        "assignedTunnelIpv6": _GOOD_V6_A,
                    },
                )
            ],
        )

    def test_row_preflight_failure_blocks_dry_run_with_exit_code_1(self) -> None:
        code, stdout, stderr = _run_main(self._bad_row_db(), [])

        self.assertEqual(code, 1)
        self.assertIn("policy row failures - invalid owner: 1", stdout)
        self.assertIn("README", stderr)

    def test_row_preflight_failure_blocks_apply_with_exit_code_1(self) -> None:
        with mock.patch.object(backfill, "_run_apply") as run_apply:
            code, stdout, stderr = _run_main(self._bad_row_db(), ["--apply"])

        self.assertEqual(code, 1)
        self.assertIn("policy row failures - invalid owner: 1", stdout)
        self.assertIn("README", stderr)
        run_apply.assert_not_called()

    def test_clean_fleet_dry_run_succeeds(self) -> None:
        db = FakeDb(
            {"uid-a": {}},
            {"uid-a": {"accountSlot": 1}},
            {"nextSlot": 2},
            instances=[
                (
                    "inst-1",
                    {
                        "status": "active",
                        "clientPublicKey": "fake-key",
                        "ownerUid": "uid-a",
                        "assignedTunnelIpv4": _GOOD_V4_A,
                        "assignedTunnelIpv6": _GOOD_V6_A,
                    },
                )
            ],
        )
        code, stdout, _stderr = _run_main(db, [])

        self.assertEqual(code, 0)
        self.assertIn("policy row preflight: ok", stdout)
        self.assertIn("policy rows checked: 1", stdout)
        self.assertIn("policy rows valid: 1", stdout)

    def test_missing_counter_blocks_the_dry_run_without_the_seed_flag(self) -> None:
        db = FakeDb({"uid-a": {}}, {"uid-a": {"accountSlot": 4}}, None)

        code, stdout, stderr = _run_main(db, [])

        self.assertEqual(code, 1)
        self.assertIn("validation failures - counter unseeded: 1", stdout)
        self.assertIn("newly assigned: 0", stdout)
        self.assertIn("counter after: (unchanged)", stdout)
        self.assertIn("README", stderr)
        self.assertEqual(db.transactions, [])

    def test_seed_initial_counter_flag_allows_the_one_time_seed(self) -> None:
        db = FakeDb({"uid-a": {}}, {"uid-a": {"accountSlot": 4}}, None)

        code, stdout, _stderr = _run_main(db, ["--seed-initial-counter"])

        self.assertEqual(code, 0)
        self.assertIn("validation failures - counter unseeded: 0", stdout)
        self.assertIn("counter after: 5", stdout)

    def test_regressed_counter_blocks_apply_even_with_the_seed_flag(self) -> None:
        db = FakeDb({"uid-a": {}, "uid-b": {}}, {"uid-a": {"accountSlot": 4}}, {"nextSlot": 4})

        with mock.patch.object(backfill, "_run_apply") as run_apply:
            code, stdout, stderr = _run_main(db, ["--apply", "--seed-initial-counter"])

        self.assertEqual(code, 1)
        self.assertIn("validation failures - counter regressed: 1", stdout)
        self.assertIn("README", stderr)
        run_apply.assert_not_called()
        self.assertEqual(db.transactions, [])


class MainWriteGuardTests(unittest.TestCase):
    """main()'s pre-check must refuse the same boundary the in-transaction
    check does, before any Firestore transaction is opened."""

    def _assert_refused(self, db: Any, run_apply: Any, code: int, stdout: str, stderr: str) -> None:
        self.assertEqual(code, 1)
        run_apply.assert_not_called()
        self.assertEqual(db.transactions, [])
        self.assertIn("safety margin", stderr)
        output = stdout + stderr
        for uid in _uids(3) + ["uid-a", "uid-b"]:
            self.assertNotIn(uid, output)

    def test_pre_check_allows_exactly_the_limit_and_refuses_one_over(self) -> None:
        for provisioned_count, allowed in ((399, True), (400, False)):
            with self.subTest(provisioned_count=provisioned_count):
                db = _db_needing_assignments(provisioned_count)
                with mock.patch.object(backfill, "_run_apply") as run_apply:
                    run_apply.side_effect = lambda _db, plan, **_kwargs: plan
                    code, stdout, stderr = _run_main(db, ["--apply"])

                if allowed:
                    self.assertEqual(code, 0)
                    run_apply.assert_called_once()
                    self.assertIn(f"newly assigned: {provisioned_count}", stdout)
                else:
                    self._assert_refused(db, run_apply, code, stdout, stderr)
                    self.assertIn("401 writes", stderr)

    def test_pre_check_boundary_without_a_counter_write(self) -> None:
        for assignments, allowed in ((400, True), (401, False)):
            with self.subTest(assignments=assignments):
                plan = _plan_with_writes(assignments, counter_write=False)
                db = _db_needing_assignments(1)
                with mock.patch.object(backfill, "compute_plan", return_value=plan):
                    with mock.patch.object(backfill, "_run_apply") as run_apply:
                        run_apply.side_effect = lambda _db, plan, **_kwargs: plan
                        code, stdout, stderr = _run_main(db, ["--apply"])

                if allowed:
                    self.assertEqual(code, 0)
                    run_apply.assert_called_once()
                else:
                    self._assert_refused(db, run_apply, code, stdout, stderr)
                    self.assertIn("401 writes", stderr)

    def test_pre_check_refuses_before_any_transaction_in_dry_run_too(self) -> None:
        db = _db_needing_assignments(400)

        with mock.patch.object(backfill, "_run_apply") as run_apply:
            code, _stdout, stderr = _run_main(db, [])

        self.assertEqual(code, 1)
        run_apply.assert_not_called()
        self.assertEqual(db.transactions, [])
        self.assertIn("safety margin", stderr)


class MirroredConstantsTests(unittest.TestCase):
    """Asserts the standalone-duplicated constants in
    backfill_account_slots.py agree with their Backend/API source of truth
    (see the module docstring's "duplicates constants" list)."""

    def test_constants_match_backend_api_source_of_truth(self) -> None:
        repo_root = Path(__file__).resolve().parents[2]
        api_root = str(repo_root / "Backend" / "API")
        inserted = api_root not in sys.path
        if inserted:
            sys.path.insert(0, api_root)
        try:
            from src.enums import ClientStatus  # type: ignore[import-not-found]
            from src.repository import MAX_ACCOUNT_SLOT as api_max_slot  # type: ignore[import-not-found]
            from src.repository import MIN_ACCOUNT_SLOT as api_min_slot  # type: ignore[import-not-found]
            from src.wireguard import MESH_AGGREGATE_V4 as api_v4  # type: ignore[import-not-found]
            from src.wireguard import MESH_AGGREGATE_V6 as api_v6  # type: ignore[import-not-found]
        finally:
            if inserted:
                sys.path.remove(api_root)

        self.assertEqual(backfill.MIN_ACCOUNT_SLOT, api_min_slot)
        self.assertEqual(backfill.MAX_ACCOUNT_SLOT, api_max_slot)
        self.assertEqual(backfill.MESH_AGGREGATE_V4, api_v4)
        self.assertEqual(backfill.MESH_AGGREGATE_V6, api_v6)
        self.assertEqual(backfill._CLIENT_STATUS_ACTIVE, ClientStatus.ACTIVE.value)


class CredentialResolutionTests(unittest.TestCase):
    def test_explicit_credentials_argument_wins(self) -> None:
        self.assertEqual(
            backfill._resolve_credentials_path("/tmp/explicit.json"),
            "/tmp/explicit.json",
        )

    def test_falls_back_to_environment_variable(self) -> None:
        import os

        old = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
        try:
            os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = "/tmp/env.json"
            self.assertEqual(backfill._resolve_credentials_path(None), "/tmp/env.json")
        finally:
            if old is None:
                os.environ.pop("GOOGLE_APPLICATION_CREDENTIALS", None)
            else:
                os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = old

    def test_no_credentials_returns_none(self) -> None:
        import os

        old = os.environ.pop("GOOGLE_APPLICATION_CREDENTIALS", None)
        try:
            self.assertIsNone(backfill._resolve_credentials_path(None))
        finally:
            if old is not None:
                os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = old


if __name__ == "__main__":
    unittest.main()
