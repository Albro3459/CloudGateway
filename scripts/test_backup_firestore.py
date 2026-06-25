"""Unit tests for the Firestore backup script."""

from __future__ import annotations

import datetime as dt
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any

_SPEC = importlib.util.spec_from_file_location(
    "backup_firestore", Path(__file__).with_name("backup_firestore.py")
)
assert _SPEC and _SPEC.loader
backup = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(backup)


class FakeSnapshot:
    def __init__(self, ref: "FakeDocumentRef", data: dict[str, Any] | None) -> None:
        self.reference = ref
        self.exists = data is not None
        self._data = data

    def to_dict(self) -> dict[str, Any] | None:
        return self._data


class FakeDocumentRef:
    def __init__(self, db: "FakeDb", path: str) -> None:
        self._db = db
        self.path = path
        self.id = path.rsplit("/", 1)[-1]

    def get(self) -> FakeSnapshot:
        return FakeSnapshot(self, self._db.docs.get(self.path))

    def collections(self) -> list["FakeCollectionRef"]:
        if not self._db.expose_missing_parent_collections and self.path not in self._db.docs:
            return []
        prefix = f"{self.path}/"
        collection_paths = set()
        for path in self._db.docs:
            if not path.startswith(prefix):
                continue
            rest = path[len(prefix) :].split("/")
            if len(rest) >= 2:
                collection_paths.add(f"{prefix}{rest[0]}")
        return [FakeCollectionRef(self._db, path) for path in sorted(collection_paths)]


class FakeCollectionRef:
    def __init__(self, db: "FakeDb", path: str) -> None:
        self._db = db
        self.path = path
        self.id = path.rsplit("/", 1)[-1]

    def list_documents(self) -> list[FakeDocumentRef]:
        prefix = f"{self.path}/"
        document_paths = set()
        for path in self._db.docs:
            if not path.startswith(prefix):
                continue
            rest = path[len(prefix) :].split("/")
            if rest:
                document_path = f"{prefix}{rest[0]}"
                if self._db.expose_missing_parent_documents or document_path in self._db.docs:
                    document_paths.add(document_path)
        return [FakeDocumentRef(self._db, path) for path in sorted(document_paths)]


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


class FakeDb:
    def __init__(
        self,
        docs: dict[str, dict[str, Any]],
        *,
        expose_missing_parent_documents: bool = True,
        expose_missing_parent_collections: bool = True,
    ) -> None:
        self.docs = docs
        self.expose_missing_parent_documents = expose_missing_parent_documents
        self.expose_missing_parent_collections = expose_missing_parent_collections

    def collections(self) -> list[FakeCollectionRef]:
        roots = {path.split("/", 1)[0] for path in self.docs}
        return [FakeCollectionRef(self, root) for root in sorted(roots)]

    def collection_group(self, collection_id: str) -> FakeCollectionGroupRef:
        return FakeCollectionGroupRef(self, collection_id)


class FakeReference:
    def __init__(self, path: str) -> None:
        self.path = path


class FakeGeoPoint:
    def __init__(self, latitude: float, longitude: float) -> None:
        self.latitude = latitude
        self.longitude = longitude


class StrangeValue:
    def __str__(self) -> str:
        return "strange"


class FirestoreBackupTests(unittest.TestCase):
    def _create_backup(self, db: FakeDb, now: dt.datetime) -> dict[str, Any]:
        with tempfile.TemporaryDirectory() as temp_dir:
            backup_path = Path(temp_dir) / "backup.json"
            backup.create_backup(db=db, backup_path=backup_path, now=now)
            return json.loads(backup_path.read_text(encoding="utf-8"))

    def test_backup_recursively_collects_documents_once_in_sorted_order(self) -> None:
        now = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
        db = FakeDb(
            {
                "Users/u1": {"email": "user@example.com"},
                "Regions/us-test-1": {"regionId": "us-test-1"},
                "Regions/us-test-1/Instances/client-a": {"clientId": "client-a"},
            }
        )

        payload = self._create_backup(db, now)

        self.assertEqual(payload["generatedAt"], "2026-01-01T00:00:00+00:00")
        self.assertEqual(payload["documentCount"], 3)
        self.assertEqual(
            [document["path"] for document in payload["documents"]],
            [
                "Regions/us-test-1",
                "Regions/us-test-1/Instances/client-a",
                "Users/u1",
            ],
        )

    def test_collection_group_fallback_collects_instances_under_missing_parent_docs(self) -> None:
        now = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
        db = FakeDb(
            {
                "Users/u1/Regions/us-test-1/Instances/client-a": {"clientId": "client-a"},
            },
            expose_missing_parent_documents=False,
            expose_missing_parent_collections=False,
        )

        payload = self._create_backup(db, now)

        self.assertEqual(payload["documentCount"], 1)
        self.assertEqual(
            payload["documents"],
            [
                {
                    "path": "Users/u1/Regions/us-test-1/Instances/client-a",
                    "data": {"clientId": "client-a"},
                }
            ],
        )

    def test_default_backup_path_stays_under_firebase_backups(self) -> None:
        path = backup._default_backup_path(dt.datetime(2026, 1, 2, 3, 4, 5, tzinfo=dt.timezone.utc))

        self.assertEqual(path.parent, backup.BACKUP_DIR)
        self.assertEqual(path.name, "backup-20260102T030405Z.json")
        self.assertEqual(path.parent.name, "backups")
        self.assertEqual(path.parent.parent.name, "Firebase")

    def test_serializer_preserves_firestore_like_values(self) -> None:
        now = dt.datetime(2026, 1, 1, 12, 30, 45)
        payload = self._create_backup(
            FakeDb(
                {
                    "Users/u1": {
                        "timestamp": now,
                        "date": dt.date(2026, 1, 2),
                        "bytes": b"\x01\x02",
                        "reference": FakeReference("Users/u2"),
                        "geopoint": FakeGeoPoint(41.88, -87.63),
                        "nested": [("a", b"b")],
                        "unknown": StrangeValue(),
                    }
                }
            ),
            now.replace(tzinfo=dt.timezone.utc),
        )

        data = payload["documents"][0]["data"]
        self.assertEqual(data["timestamp"], {"__type__": "timestamp", "value": "2026-01-01T12:30:45+00:00"})
        self.assertEqual(data["date"], {"__type__": "date", "value": "2026-01-02"})
        self.assertEqual(data["bytes"], {"__type__": "bytes", "value": "AQI="})
        self.assertEqual(data["reference"], {"__type__": "reference", "path": "Users/u2"})
        self.assertEqual(data["geopoint"], {"__type__": "geopoint", "latitude": 41.88, "longitude": -87.63})
        self.assertEqual(data["nested"], [["a", {"__type__": "bytes", "value": "Yg=="}]])
        self.assertEqual(data["unknown"], {"__type__": "StrangeValue", "value": "strange"})


if __name__ == "__main__":
    unittest.main()
