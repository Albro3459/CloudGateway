from __future__ import annotations

import copy
import datetime as dt
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any

from Firebase.scripts.backup_firestore import create_backup
from Firebase.scripts.migrate_firestore_schema import MigrationConflict, run_migration


class FakeSnapshot:
    def __init__(self, ref: "FakeDocumentRef", data: dict[str, Any] | None) -> None:
        self.reference = ref
        self.id = ref.id
        self.exists = data is not None
        self._data = copy.deepcopy(data) if data is not None else None

    def to_dict(self) -> dict[str, Any] | None:
        return copy.deepcopy(self._data)


class FakeDocumentRef:
    def __init__(self, db: "FakeDb", path: str) -> None:
        self._db = db
        self.path = path
        self.id = path.rsplit("/", 1)[-1]

    def collection(self, collection_id: str) -> "FakeCollectionRef":
        return FakeCollectionRef(self._db, f"{self.path}/{collection_id}")

    @property
    def parent(self) -> "FakeCollectionRef":
        return FakeCollectionRef(self._db, self.path.rsplit("/", 1)[0])

    def collections(self) -> list["FakeCollectionRef"]:
        prefix = f"{self.path}/"
        collection_paths = set()
        for path in self._db.docs:
            if not path.startswith(prefix):
                continue
            rest = path[len(prefix) :].split("/")
            if len(rest) >= 2:
                collection_paths.add(f"{prefix}{rest[0]}")
        return [FakeCollectionRef(self._db, path) for path in sorted(collection_paths)]

    def get(self) -> FakeSnapshot:
        return FakeSnapshot(self, self._db.docs.get(self.path))


class FakeCollectionRef:
    def __init__(self, db: "FakeDb", path: str) -> None:
        self._db = db
        self.path = path
        self.id = path.rsplit("/", 1)[-1]

    def document(self, document_id: str) -> FakeDocumentRef:
        return FakeDocumentRef(self._db, f"{self.path}/{document_id}")

    @property
    def parent(self) -> FakeDocumentRef | None:
        if "/" not in self.path:
            return None
        return FakeDocumentRef(self._db, self.path.rsplit("/", 1)[0])

    def list_documents(self) -> list[FakeDocumentRef]:
        prefix = f"{self.path}/"
        document_paths = set()
        for path in self._db.docs:
            if not path.startswith(prefix):
                continue
            rest = path[len(prefix) :].split("/")
            if rest:
                document_paths.add(f"{prefix}{rest[0]}")
        return [FakeDocumentRef(self._db, path) for path in sorted(document_paths)]

    def stream(self) -> list[FakeSnapshot]:
        prefix = f"{self.path}/"
        snapshots = []
        for path, data in sorted(self._db.docs.items()):
            if not path.startswith(prefix):
                continue
            rest = path[len(prefix) :].split("/")
            if len(rest) == 1:
                snapshots.append(FakeSnapshot(FakeDocumentRef(self._db, path), data))
        return snapshots


class FakeCollectionGroupRef:
    def __init__(self, db: "FakeDb", collection_id: str) -> None:
        self._db = db
        self.id = collection_id

    def stream(self) -> list[FakeSnapshot]:
        snapshots = []
        for path, data in sorted(self._db.docs.items()):
            parts = path.split("/")
            if len(parts) >= 2 and len(parts) % 2 == 0 and parts[-2] == self.id:
                snapshots.append(FakeSnapshot(FakeDocumentRef(self._db, path), data))
        return snapshots


class FakeBatch:
    def __init__(self, db: "FakeDb") -> None:
        self._db = db
        self._operations: list[tuple[str, FakeDocumentRef, dict[str, Any] | None]] = []

    def set(self, ref: FakeDocumentRef, data: dict[str, Any], merge: bool = False) -> None:
        self._operations.append(("set_merge" if merge else "set", ref, copy.deepcopy(data)))

    def update(self, ref: FakeDocumentRef, data: dict[str, Any]) -> None:
        self._operations.append(("update", ref, copy.deepcopy(data)))

    def delete(self, ref: FakeDocumentRef) -> None:
        self._operations.append(("delete", ref, None))

    def commit(self) -> None:
        for operation, ref, data in self._operations:
            self._db.events.append(f"{operation}:{ref.path}")
            if operation == "set":
                self._db.docs[ref.path] = copy.deepcopy(data)
            elif operation == "set_merge":
                existing = copy.deepcopy(self._db.docs.get(ref.path, {}))
                existing.update(copy.deepcopy(data) or {})
                self._db.docs[ref.path] = existing
            elif operation == "update":
                existing = self._db.docs.setdefault(ref.path, {})
                for key in data or {}:
                    existing.pop(key, None)
            elif operation == "delete":
                self._db.docs.pop(ref.path, None)


class FakeDb:
    def __init__(self, docs: dict[str, dict[str, Any]]) -> None:
        self.docs = copy.deepcopy(docs)
        self.events: list[str] = []

    def collection(self, collection_id: str) -> FakeCollectionRef:
        return FakeCollectionRef(self, collection_id)

    def collections(self) -> list[FakeCollectionRef]:
        roots = {path.split("/", 1)[0] for path in self.docs}
        return [FakeCollectionRef(self, root) for root in sorted(roots)]

    def collection_group(self, collection_id: str) -> FakeCollectionGroupRef:
        return FakeCollectionGroupRef(self, collection_id)

    def batch(self) -> FakeBatch:
        return FakeBatch(self)


class FirestoreMigrationTests(unittest.TestCase):
    def test_backup_includes_legacy_instances_when_parent_region_doc_is_missing(self) -> None:
        db = FakeDb(
            {
                "Users/u1": {"email": "user@example.com"},
                "Users/u1/Regions/us-test-1/Instances/client-a": {"clientName": "Laptop"},
            }
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            backup_path = Path(temp_dir) / "backup-test.json"
            create_backup(
                db=db,
                backup_path=backup_path,
                now=dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc),
            )
            payload = json.loads(backup_path.read_text(encoding="utf-8"))

        self.assertEqual(payload["documentCount"], 2)
        self.assertEqual(
            [document["path"] for document in payload["documents"]],
            [
                "Users/u1",
                "Users/u1/Regions/us-test-1/Instances/client-a",
            ],
        )

    def test_migration_copies_clients_and_deletes_sources_after_writes(self) -> None:
        db = FakeDb(
            {
                "Roles/u1": {"role": "admin"},
                "Regions/us-test-1": {
                    "regionId": "us-test-1",
                    "activeClientCount": 7,
                    "userClientLimit": 2,
                    "enabled": True,
                },
                "Users/u1": {"email": "admin@example.com"},
                "Users/u1/Regions/empty-region": {"name": "empty legacy region shadow"},
                "Users/u1/Regions/us-test-1": {"name": "legacy region shadow"},
                "Users/u1/Regions/us-test-1/Instances/client-a": {
                    "clientName": "Laptop",
                    "ownerUid": "wrong-owner",
                    "regionId": "wrong-region",
                    "clientId": "wrong-client",
                },
            }
        )

        def backup_func(db: FakeDb) -> Path:
            db.events.append("backup")
            return Path("Firebase/backups/backup-test.json")

        result = run_migration(db=db, backup_func=backup_func, updated_at="now")

        self.assertEqual(result["clientsCopied"], 1)
        self.assertEqual(result["regionDocsCleaned"], 1)
        self.assertEqual(result["oldClientDocsDeleted"], 1)
        self.assertEqual(result["oldUserRegionDocsDeleted"], 2)
        self.assertEqual(result["oldRoleDocsDeleted"], 1)
        self.assertEqual(db.docs["Roles/user"]["defaultPerRegionClientLimit"], 2)
        self.assertEqual(db.docs["Roles/admin"]["defaultPerRegionClientLimit"], 10)
        self.assertNotIn("Roles/u1", db.docs)
        self.assertEqual(
            db.docs["UserRoles/u1"],
            {"uid": "u1", "roleId": "admin", "updatedAt": "now"},
        )
        self.assertNotIn("perRegionClientLimit", db.docs["UserRoles/u1"])
        self.assertEqual(
            db.docs["Regions/us-test-1/Instances/client-a"],
            {
                "clientName": "Laptop",
                "ownerUid": "u1",
                "regionId": "us-test-1",
                "clientId": "client-a",
            },
        )
        self.assertEqual(
            db.docs["Regions/us-test-1"],
            {
                "regionId": "us-test-1",
                "enabled": True,
            },
        )
        self.assertNotIn("Users/u1/Regions/us-test-1/Instances/client-a", db.docs)
        self.assertNotIn("Users/u1/Regions/us-test-1", db.docs)
        self.assertNotIn("Users/u1/Regions/empty-region", db.docs)
        self.assertEqual(db.events[0], "backup")
        copy_index = db.events.index("set:Regions/us-test-1/Instances/client-a")
        delete_index = db.events.index("delete:Users/u1/Regions/us-test-1/Instances/client-a")
        self.assertLess(copy_index, delete_index)

    def test_existing_target_client_conflict_fails_before_writes_or_deletes(self) -> None:
        db = FakeDb(
            {
                "Roles/u1": {"role": "user"},
                "Users/u1": {"email": "user@example.com"},
                "Users/u1/Regions/us-test-1/Instances/client-a": {"clientName": "Laptop"},
                "Regions/us-test-1/Instances/client-a": {
                    "clientName": "Different",
                    "ownerUid": "u1",
                    "regionId": "us-test-1",
                    "clientId": "client-a",
                },
            }
        )

        def backup_func(db: FakeDb) -> Path:
            db.events.append("backup")
            return Path("Firebase/backups/backup-test.json")

        with self.assertRaises(MigrationConflict):
            run_migration(db=db, backup_func=backup_func, updated_at="now")

        self.assertEqual(db.events, ["backup"])
        self.assertIn("Users/u1/Regions/us-test-1/Instances/client-a", db.docs)
        self.assertNotIn("UserRoles/u1", db.docs)

    def test_duplicate_legacy_clients_for_same_region_target_fail(self) -> None:
        db = FakeDb(
            {
                "Roles/u1": {"role": "user"},
                "Roles/u2": {"role": "user"},
                "Users/u1": {"email": "one@example.com"},
                "Users/u2": {"email": "two@example.com"},
                "Users/u1/Regions/us-test-1/Instances/client-a": {"clientName": "One"},
                "Users/u2/Regions/us-test-1/Instances/client-a": {"clientName": "Two"},
            }
        )

        def backup_func(db: FakeDb) -> Path:
            db.events.append("backup")
            return Path("Firebase/backups/backup-test.json")

        with self.assertRaises(MigrationConflict):
            run_migration(db=db, backup_func=backup_func, updated_at="now")

        self.assertEqual(db.events, ["backup"])
        self.assertIn("Users/u1/Regions/us-test-1/Instances/client-a", db.docs)
        self.assertIn("Users/u2/Regions/us-test-1/Instances/client-a", db.docs)

    def test_migration_does_not_provision_users_missing_legacy_role(self) -> None:
        db = FakeDb(
            {
                "Regions/us-test-1": {"regionId": "us-test-1"},
                "Users/u1": {"email": "user@example.com"},
            }
        )

        def backup_func(db: FakeDb) -> Path:
            db.events.append("backup")
            return Path("Firebase/backups/backup-test.json")

        result = run_migration(db=db, backup_func=backup_func, updated_at="now")

        self.assertEqual(result["userRolesWritten"], 0)
        self.assertEqual(db.docs["Roles/user"]["defaultPerRegionClientLimit"], 3)
        self.assertEqual(db.docs["Roles/admin"]["defaultPerRegionClientLimit"], 10)
        self.assertNotIn("UserRoles/u1", db.docs)

    def test_migration_retry_preserves_existing_user_default_when_legacy_fields_are_gone(self) -> None:
        db = FakeDb(
            {
                "Roles/user": {
                    "roleId": "user",
                    "defaultPerRegionClientLimit": 2,
                    "updatedAt": "previous",
                },
                "Roles/admin": {
                    "roleId": "admin",
                    "defaultPerRegionClientLimit": 10,
                    "updatedAt": "previous",
                },
                "Regions/us-test-1": {"regionId": "us-test-1"},
            }
        )

        def backup_func(db: FakeDb) -> Path:
            db.events.append("backup")
            return Path("Firebase/backups/backup-test.json")

        result = run_migration(db=db, backup_func=backup_func, updated_at="now")

        self.assertEqual(result["roleDefaultsWritten"], 2)
        self.assertEqual(db.docs["Roles/user"]["defaultPerRegionClientLimit"], 2)
        self.assertEqual(db.docs["Roles/admin"]["defaultPerRegionClientLimit"], 10)

    def test_migration_fails_when_legacy_region_user_limits_conflict(self) -> None:
        db = FakeDb(
            {
                "Regions/us-one-1": {"regionId": "us-one-1", "userClientLimit": 2},
                "Regions/us-two-1": {"regionId": "us-two-1", "userClientLimit": 3},
                "Users/u1": {"email": "user@example.com"},
            }
        )

        def backup_func(db: FakeDb) -> Path:
            db.events.append("backup")
            return Path("Firebase/backups/backup-test.json")

        with self.assertRaisesRegex(MigrationConflict, "Conflicting legacy userClientLimit values"):
            run_migration(db=db, backup_func=backup_func, updated_at="now")

        self.assertEqual(db.events, ["backup"])
        self.assertNotIn("Roles/user", db.docs)
        self.assertNotIn("UserRoles/u1", db.docs)

    def test_migration_fails_when_legacy_role_is_invalid(self) -> None:
        db = FakeDb(
            {
                "Roles/u1": {"role": "owner"},
                "Users/u1": {"email": "user@example.com"},
            }
        )

        def backup_func(db: FakeDb) -> Path:
            db.events.append("backup")
            return Path("Firebase/backups/backup-test.json")

        with self.assertRaisesRegex(MigrationConflict, "unsupported role"):
            run_migration(db=db, backup_func=backup_func, updated_at="now")

        self.assertEqual(db.events, ["backup"])
        self.assertNotIn("Roles/user", db.docs)
        self.assertNotIn("UserRoles/u1", db.docs)


if __name__ == "__main__":
    unittest.main()
