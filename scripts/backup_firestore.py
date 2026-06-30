#!/usr/bin/env python3
"""Create a recursive Firestore JSON backup for CloudGateway."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
CREDENTIALS_PATH = REPO_ROOT / "Firebase" / "Secrets" / "firebase-credentials.json"
BACKUP_DIR = REPO_ROOT / "Firebase" / "backups"


def get_firestore_client() -> Any:
    import firebase_admin
    from firebase_admin import credentials, firestore

    if not firebase_admin._apps:
        credential = credentials.Certificate(str(CREDENTIALS_PATH))
        firebase_admin.initialize_app(credential)
    return firestore.client()


def _serialize_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: _serialize_value(child) for key, child in value.items()}
    if isinstance(value, (list, tuple)):
        return [_serialize_value(child) for child in value]
    if isinstance(value, dt.datetime):
        timestamp = value if value.tzinfo else value.replace(tzinfo=dt.timezone.utc)
        return {"__type__": "timestamp", "value": timestamp.isoformat()}
    if isinstance(value, dt.date):
        return {"__type__": "date", "value": value.isoformat()}
    if isinstance(value, bytes):
        return {"__type__": "bytes", "value": base64.b64encode(value).decode("ascii")}
    if hasattr(value, "path") and value.__class__.__name__.endswith("Reference"):
        return {"__type__": "reference", "path": value.path}
    if hasattr(value, "latitude") and hasattr(value, "longitude"):
        return {
            "__type__": "geopoint",
            "latitude": value.latitude,
            "longitude": value.longitude,
        }

    try:
        json.dumps(value)
    except TypeError:
        return {"__type__": value.__class__.__name__, "value": str(value)}
    return value


def _collect_collection(
    collection_ref: Any,
    documents: list[dict[str, Any]],
    seen_paths: set[str],
) -> None:
    for document_ref in collection_ref.list_documents():
        _collect_document(document_ref, documents, seen_paths)


def _collect_document(
    document_ref: Any,
    documents: list[dict[str, Any]],
    seen_paths: set[str],
) -> None:
    snapshot = document_ref.get()
    if snapshot.exists and snapshot.reference.path not in seen_paths:
        _add_snapshot(snapshot, documents)
        seen_paths.add(snapshot.reference.path)

    for subcollection_ref in document_ref.collections():
        _collect_collection(subcollection_ref, documents, seen_paths)


def _add_snapshot(snapshot: Any, documents: list[dict[str, Any]]) -> None:
    documents.append(
        {
            "path": snapshot.reference.path,
            "data": _serialize_value(snapshot.to_dict() or {}),
        }
    )


def _collect_known_collection_groups(client: Any, documents: list[dict[str, Any]]) -> None:
    seen_paths = {document["path"] for document in documents}
    for snapshot in client.collection_group("Instances").stream():
        if snapshot.reference.path in seen_paths:
            continue
        _add_snapshot(snapshot, documents)
        seen_paths.add(snapshot.reference.path)


def _default_backup_path(now: dt.datetime | None = None) -> Path:
    timestamp = (now or dt.datetime.now(dt.timezone.utc)).strftime("%Y%m%dT%H%M%SZ")
    return BACKUP_DIR / f"backup-{timestamp}.json"


def create_backup(
    db: Any | None = None,
    backup_path: Path | None = None,
    now: dt.datetime | None = None,
) -> Path:
    client = db or get_firestore_client()
    destination = backup_path or _default_backup_path(now)
    destination.parent.mkdir(parents=True, exist_ok=True)

    documents: list[dict[str, Any]] = []
    seen_paths: set[str] = set()
    for collection_ref in client.collections():
        _collect_collection(collection_ref, documents, seen_paths)
    _collect_known_collection_groups(client, documents)
    documents.sort(key=lambda document: document["path"])

    payload = {
        "generatedAt": (now or dt.datetime.now(dt.timezone.utc)).isoformat(),
        "credentialsPath": "Backend/Firebase/Secrets/firebase-credentials.json",
        "documentCount": len(documents),
        "documents": documents,
    }
    destination.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description="Back up all Firestore documents to JSON.")
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Optional backup path. Defaults to Backend/Firebase/backups/backup-<timestamp>.json.",
    )
    args = parser.parse_args()

    backup_path = create_backup(backup_path=args.output)
    print(f"Wrote Firestore backup to {backup_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
