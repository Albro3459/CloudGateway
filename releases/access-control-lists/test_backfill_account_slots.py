"""Unit tests for the legacy account-slot backfill migration.

Run with: python3 -m unittest releases/access-control-lists/test_backfill_account_slots.py

All test data below is obviously fake (uid-a, uid-b, ...); none of it is a
real uid, email, or address.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from typing import Any

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
    def __init__(self, doc_id: str, data: dict[str, Any] | None) -> None:
        self.id = doc_id
        self.exists = data is not None
        self._data = data

    def to_dict(self) -> dict[str, Any] | None:
        return dict(self._data) if self._data is not None else None


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


class FakeDb:
    def __init__(
        self,
        user_roles: dict[str, dict[str, Any]],
        users: dict[str, dict[str, Any]],
        counter: dict[str, Any] | None,
    ) -> None:
        counters_docs = {"accountSlots": counter} if counter is not None else {}
        self._collections = {
            "UserRoles": FakeCollectionRef("UserRoles", user_roles),
            "Users": FakeCollectionRef("Users", users),
            "Counters": FakeCollectionRef("Counters", counters_docs),
        }

    def collection(self, name: str) -> FakeCollectionRef:
        return self._collections[name]


class FakeTransaction:
    def __init__(self) -> None:
        self.writes: list[tuple[str, str, dict[str, Any], bool]] = []

    def set(self, ref: FakeDocumentRef, data: dict[str, Any], merge: bool = False) -> None:
        self.writes.append((ref.collection_name, ref.id, dict(data), merge))


_FAKE_TIMESTAMP = "FAKE_SERVER_TIMESTAMP"


def _six_provisioned_uids() -> dict[str, dict[str, Any]]:
    return {f"uid-{c}": {"uid": f"uid-{c}", "roleId": "user"} for c in "abcdef"}


def _apply_via_fake(db: FakeDb, preflight_plan: Any) -> tuple[Any, FakeTransaction]:
    transaction = FakeTransaction()
    applied_plan = backfill._apply_within_transaction(transaction, db, preflight_plan, _FAKE_TIMESTAMP)
    return applied_plan, transaction


class ComputePlanTests(unittest.TestCase):
    def test_first_migration_from_zero_slots_and_no_counter(self) -> None:
        provisioned = {f"uid-{c}" for c in "abcdef"}
        plan = backfill.compute_plan(provisioned, {}, None)

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
        plan = backfill.compute_plan(provisioned, user_slots, None)

        self.assertTrue(plan.ok)
        self.assertEqual(plan.already_assigned_count, 2)
        # uid-c, uid-d, uid-e, uid-f get 4, 5, 6, 7 (sorted ascending by uid).
        self.assertEqual(plan.assignments, {"uid-c": 4, "uid-d": 5, "uid-e": 6, "uid-f": 7})
        self.assertEqual(plan.counter_after, 8)

    def test_counter_corruption_variants_are_superseded_not_blocking(self) -> None:
        provisioned = {"uid-a"}
        user_slots = {"uid-a": 5}
        for bad_counter in (0, -1, "7", True, 3.5, backfill.MAX_ACCOUNT_SLOT + 1):
            with self.subTest(bad_counter=bad_counter):
                plan = backfill.compute_plan(provisioned, user_slots, bad_counter)
                self.assertTrue(plan.ok)
                self.assertEqual(plan.counter_state, "malformed")
                self.assertIsNone(plan.counter_before)
                self.assertEqual(plan.counter_after, 6)
                self.assertEqual(plan.failures, backfill.PlanFailures())

    def test_missing_counter_is_superseded_not_blocking(self) -> None:
        plan = backfill.compute_plan({"uid-a"}, {"uid-a": 5}, None)
        self.assertTrue(plan.ok)
        self.assertEqual(plan.counter_state, "missing")
        self.assertEqual(plan.counter_after, 6)

    def test_valid_counter_at_or_below_max_is_advanced_never_reused(self) -> None:
        provisioned = {"uid-a", "uid-b"}
        user_slots = {"uid-a": 1, "uid-b": 2}
        for stale_counter in (1, 2):
            with self.subTest(stale_counter=stale_counter):
                plan = backfill.compute_plan(provisioned, user_slots, stale_counter)
                self.assertTrue(plan.ok)
                self.assertEqual(plan.counter_state, "valid")
                self.assertEqual(plan.counter_before, stale_counter)
                self.assertEqual(plan.counter_after, 3)

    def test_valid_counter_strictly_above_max_is_left_unchanged(self) -> None:
        plan = backfill.compute_plan({"uid-a"}, {"uid-a": 1}, 10)
        self.assertTrue(plan.ok)
        self.assertEqual(plan.counter_before, 10)
        self.assertIsNone(plan.counter_after)

    def test_duplicate_slots_across_two_uids_block_with_zero_writes(self) -> None:
        provisioned = {"uid-a", "uid-b"}
        user_slots = {"uid-a": 4, "uid-b": 4}
        plan = backfill.compute_plan(provisioned, user_slots, None)

        self.assertFalse(plan.ok)
        self.assertEqual(plan.failures.duplicate_slot, 2)
        self.assertEqual(plan.assignments, {})
        self.assertIsNone(plan.counter_after)

        transaction = FakeTransaction()
        db = FakeDb(
            {"uid-a": {}, "uid-b": {}},
            {"uid-a": {"accountSlot": 4}, "uid-b": {"accountSlot": 4}},
            None,
        )
        with self.assertRaises(backfill.MigrationAbortedError):
            backfill._apply_within_transaction(transaction, db, plan, _FAKE_TIMESTAMP)
        self.assertEqual(transaction.writes, [])

    def test_malformed_slot_values_block_with_zero_writes(self) -> None:
        provisioned = {"uid-a", "uid-b"}
        for bad_value in (0, -3, "7", True, 4.5, backfill.MAX_ACCOUNT_SLOT + 1):
            with self.subTest(bad_value=bad_value):
                plan = backfill.compute_plan(provisioned, {"uid-a": bad_value}, None)
                self.assertFalse(plan.ok)
                self.assertEqual(plan.failures.malformed_slot, 1)
                self.assertEqual(plan.assignments, {})

    def test_slot_on_non_provisioned_uid_blocks(self) -> None:
        provisioned = {"uid-a"}
        user_slots = {"uid-a": 1, "uid-orphan": 2}
        plan = backfill.compute_plan(provisioned, user_slots, None)

        self.assertFalse(plan.ok)
        self.assertEqual(plan.failures.orphaned_slot, 1)
        self.assertEqual(plan.assignments, {})

    def test_overflow_blocks_with_zero_writes(self) -> None:
        provisioned = {"uid-a", "uid-b"}
        user_slots = {"uid-a": backfill.MAX_ACCOUNT_SLOT}
        plan = backfill.compute_plan(provisioned, user_slots, None)

        self.assertFalse(plan.ok)
        self.assertEqual(plan.failures.overflow, 1)
        self.assertEqual(plan.assignments, {})
        self.assertIsNone(plan.counter_after)


class ApplyTransactionTests(unittest.TestCase):
    def test_transaction_retry_produces_identical_writes(self) -> None:
        provisioned = _six_provisioned_uids()
        users = {"uid-a": {"accountSlot": 3}}
        db = FakeDb(provisioned, users, None)
        provisioned_uids, user_slots, raw_next_slot = backfill._read_state(db)
        preflight_plan = backfill.compute_plan(provisioned_uids, user_slots, raw_next_slot)

        _, transaction1 = _apply_via_fake(db, preflight_plan)
        _, transaction2 = _apply_via_fake(db, preflight_plan)

        self.assertEqual(transaction1.writes, transaction2.writes)
        self.assertTrue(transaction1.writes)

    def test_invariant_change_during_transaction_aborts_with_zero_writes(self) -> None:
        preflight_db = FakeDb(_six_provisioned_uids(), {}, None)
        provisioned_uids, user_slots, raw_next_slot = backfill._read_state(preflight_db)
        preflight_plan = backfill.compute_plan(provisioned_uids, user_slots, raw_next_slot)

        # A concurrent write landed between preflight and apply: uid-a already
        # has a slot now, so the in-transaction recompute disagrees with the
        # preflight plan.
        changed_db = FakeDb(_six_provisioned_uids(), {"uid-a": {"accountSlot": 1}}, None)
        transaction = FakeTransaction()

        with self.assertRaises(backfill.MigrationAbortedError):
            backfill._apply_within_transaction(transaction, changed_db, preflight_plan, _FAKE_TIMESTAMP)

        self.assertEqual(transaction.writes, [])

    def test_apply_writes_merge_true_and_only_account_slot_field(self) -> None:
        db = FakeDb({"uid-a": {}}, {}, None)
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


class AggregateOutputTests(unittest.TestCase):
    def test_report_never_contains_seeded_fake_identifiers(self) -> None:
        fake_uids = [f"uid-{c}" for c in "abcdef"] + ["uid-orphan"]
        fake_email = "fake-user@example.invalid"
        provisioned = set(fake_uids[:6])
        user_slots = {"uid-a": 3, "uid-orphan": 9}
        plan = backfill.compute_plan(provisioned, user_slots, "not-a-slot")

        report = backfill.format_report(plan, mode="dry-run")

        for uid in fake_uids:
            self.assertNotIn(uid, report)
        self.assertNotIn(fake_email, report)
        self.assertNotIn("not-a-slot", report)

    def test_report_is_aggregate_counts_for_a_successful_plan(self) -> None:
        provisioned = {f"uid-{c}" for c in "abcdef"}
        plan = backfill.compute_plan(provisioned, {}, None)
        report = backfill.format_report(plan, mode="dry-run")

        self.assertIn("mode: dry-run", report)
        self.assertIn("provisioned accounts: 6", report)
        self.assertIn("newly assigned: 6", report)
        self.assertIn("counter after: 7", report)
        for uid in provisioned:
            self.assertNotIn(uid, report)


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
