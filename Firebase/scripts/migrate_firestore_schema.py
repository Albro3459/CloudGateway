#!/usr/bin/env python3
"""Migrate CloudGateway Firestore data to the regional client schema."""

from __future__ import annotations

import argparse
import datetime as dt
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

try:
    from .backup_firestore import create_backup, get_firestore_client
except ImportError:
    from backup_firestore import create_backup, get_firestore_client


DEFAULT_ROLE_LIMITS = {
    "user": 3,
    "admin": 10,
}
VALID_ROLE_IDS = set(DEFAULT_ROLE_LIMITS)
BATCH_LIMIT = 450
DELETE_FIELD_FALLBACK = object()


class MigrationConflict(RuntimeError):
    pass


@dataclass(frozen=True)
class PlannedClientMigration:
    source_path: str
    target_path: str
    source_ref: Any
    target_ref: Any
    data: dict[str, Any]


@dataclass(frozen=True)
class PlannedUserRole:
    uid: str
    source_ref: Any
    target_path: str
    target_ref: Any
    data: dict[str, Any]


def _server_timestamp() -> Any:
    from firebase_admin import firestore

    return firestore.SERVER_TIMESTAMP


def _delete_field() -> Any:
    try:
        from firebase_admin import firestore
    except ModuleNotFoundError:
        return DELETE_FIELD_FALLBACK

    return firestore.DELETE_FIELD


def _copy_data(data: dict[str, Any]) -> dict[str, Any]:
    return dict(data)


def _is_same_role_default(existing: dict[str, Any], role_id: str, limit: int) -> bool:
    return (
        existing.get("roleId") == role_id
        and existing.get("defaultPerRegionClientLimit") == limit
    )


def _is_same_user_role(existing: dict[str, Any], planned: dict[str, Any]) -> bool:
    if existing.get("uid") != planned["uid"] or existing.get("roleId") != planned["roleId"]:
        return False
    return existing.get("perRegionClientLimit") is None


def _format_conflicts(conflicts: list[str]) -> str:
    return "Firestore migration target conflicts:\n" + "\n".join(f"- {conflict}" for conflict in conflicts)


def collect_user_role_migrations(db: Any, updated_at: Any) -> list[PlannedUserRole]:
    migrations: list[PlannedUserRole] = []

    for snapshot in db.collection("Roles").stream():
        data = snapshot.to_dict() or {}
        if "role" not in data:
            continue

        role_id = data["role"]
        if role_id not in VALID_ROLE_IDS:
            raise MigrationConflict(f"Roles/{snapshot.id}.role has unsupported role {role_id!r}")

        target_ref = db.collection("UserRoles").document(snapshot.id)
        migrations.append(
            PlannedUserRole(
                uid=snapshot.id,
                source_ref=snapshot.reference,
                target_path=target_ref.path,
                target_ref=target_ref,
                data={
                    "uid": snapshot.id,
                    "roleId": role_id,
                    "updatedAt": updated_at,
                },
            )
        )

    return migrations


def collect_region_field_cleanup_migrations(db: Any, delete_field: Any) -> list[tuple[Any, dict[str, Any]]]:
    migrations: list[tuple[Any, dict[str, Any]]] = []

    for snapshot in db.collection("Regions").stream():
        data = snapshot.to_dict() or {}
        updates: dict[str, Any] = {}
        if "activeClientCount" in data:
            updates["activeClientCount"] = delete_field
        if "userClientLimit" in data:
            updates["userClientLimit"] = delete_field
        if updates:
            migrations.append((snapshot.reference, updates))

    return migrations


def collect_client_migrations(db: Any) -> list[PlannedClientMigration]:
    migrations: list[PlannedClientMigration] = []
    seen_targets: dict[str, PlannedClientMigration] = {}
    conflicts: list[str] = []

    for client_snapshot in db.collection_group("Instances").stream():
        path_parts = client_snapshot.reference.path.split("/")
        if (
            len(path_parts) != 6
            or path_parts[0] != "Users"
            or path_parts[2] != "Regions"
            or path_parts[4] != "Instances"
        ):
            continue

        uid = path_parts[1]
        region_id = path_parts[3]
        client_id = path_parts[5]
        target_ref = (
            db.collection("Regions")
            .document(region_id)
            .collection("Instances")
            .document(client_id)
        )
        data = _copy_data(client_snapshot.to_dict() or {})
        data["ownerUid"] = uid
        data["regionId"] = region_id
        data["clientId"] = client_id

        migration = PlannedClientMigration(
            source_path=client_snapshot.reference.path,
            target_path=target_ref.path,
            source_ref=client_snapshot.reference,
            target_ref=target_ref,
            data=data,
        )
        existing_plan = seen_targets.get(target_ref.path)
        if existing_plan and existing_plan.data != data:
            conflicts.append(
                f"{client_snapshot.reference.path} and {existing_plan.source_path} both target {target_ref.path}"
            )
        else:
            seen_targets[target_ref.path] = migration
        migrations.append(migration)

    if conflicts:
        raise MigrationConflict(_format_conflicts(conflicts))
    return migrations


def collect_legacy_user_region_refs(db: Any) -> list[Any]:
    refs_by_path: dict[str, Any] = {}
    for snapshot in db.collection_group("Regions").stream():
        path_parts = snapshot.reference.path.split("/")
        if len(path_parts) == 4 and path_parts[0] == "Users" and path_parts[2] == "Regions":
            refs_by_path[snapshot.reference.path] = snapshot.reference
    return [refs_by_path[path] for path in sorted(refs_by_path)]


def find_target_conflicts(
    db: Any,
    user_role_migrations: list[PlannedUserRole],
    client_migrations: list[PlannedClientMigration],
) -> list[str]:
    conflicts: list[str] = []

    for role_id, limit in DEFAULT_ROLE_LIMITS.items():
        snapshot = db.collection("Roles").document(role_id).get()
        if snapshot.exists and not _is_same_role_default(snapshot.to_dict() or {}, role_id, limit):
            conflicts.append(f"Roles/{role_id} already exists with different defaults")

    for migration in user_role_migrations:
        snapshot = migration.target_ref.get()
        if snapshot.exists and not _is_same_user_role(snapshot.to_dict() or {}, migration.data):
            conflicts.append(f"{migration.target_path} already exists with different role data")

    checked_client_targets: set[str] = set()
    for migration in client_migrations:
        if migration.target_path in checked_client_targets:
            continue
        checked_client_targets.add(migration.target_path)

        snapshot = migration.target_ref.get()
        if snapshot.exists and (snapshot.to_dict() or {}) != migration.data:
            conflicts.append(f"{migration.target_path} already exists with different client data")

    return conflicts


def _commit_batches(db: Any, operations: list[tuple[str, Any, dict[str, Any] | None]]) -> None:
    for start in range(0, len(operations), BATCH_LIMIT):
        batch = db.batch()
        for operation, ref, data in operations[start : start + BATCH_LIMIT]:
            if operation == "set":
                batch.set(ref, data)
            elif operation == "set_merge":
                batch.set(ref, data, merge=True)
            elif operation == "update":
                batch.update(ref, data)
            elif operation == "delete":
                batch.delete(ref)
            else:
                raise ValueError(f"Unsupported batch operation {operation!r}")
        batch.commit()


def run_migration(
    db: Any | None = None,
    backup_func: Callable[..., Path] = create_backup,
    updated_at: Any | None = None,
) -> dict[str, Any]:
    client = db or get_firestore_client()
    migration_time = updated_at if updated_at is not None else _server_timestamp()
    field_delete = _delete_field()

    backup_path = backup_func(db=client)

    user_role_migrations = collect_user_role_migrations(client, migration_time)
    client_migrations = collect_client_migrations(client)
    legacy_user_region_refs = collect_legacy_user_region_refs(client)
    region_field_cleanup_migrations = collect_region_field_cleanup_migrations(client, field_delete)
    conflicts = find_target_conflicts(client, user_role_migrations, client_migrations)
    if conflicts:
        raise MigrationConflict(_format_conflicts(conflicts))

    write_operations: list[tuple[str, Any, dict[str, Any] | None]] = []
    for role_id, limit in DEFAULT_ROLE_LIMITS.items():
        write_operations.append(
            (
                "set_merge",
                client.collection("Roles").document(role_id),
                {
                    "roleId": role_id,
                    "defaultPerRegionClientLimit": limit,
                    "updatedAt": migration_time,
                },
            )
        )
    for migration in user_role_migrations:
        write_operations.append(("set_merge", migration.target_ref, migration.data))
    for migration in client_migrations:
        write_operations.append(("set", migration.target_ref, migration.data))
    for region_ref, updates in region_field_cleanup_migrations:
        write_operations.append(("update", region_ref, updates))

    _commit_batches(client, write_operations)

    delete_operations: list[tuple[str, Any, dict[str, Any] | None]] = []
    delete_operations.extend(("delete", migration.source_ref, None) for migration in client_migrations)
    delete_operations.extend(("delete", ref, None) for ref in legacy_user_region_refs)
    delete_operations.extend(("delete", migration.source_ref, None) for migration in user_role_migrations)
    _commit_batches(client, delete_operations)

    return {
        "backupPath": str(backup_path),
        "roleDefaultsWritten": len(DEFAULT_ROLE_LIMITS),
        "userRolesWritten": len(user_role_migrations),
        "clientsCopied": len(client_migrations),
        "regionDocsCleaned": len(region_field_cleanup_migrations),
        "oldClientDocsDeleted": len(client_migrations),
        "oldUserRegionDocsDeleted": len(legacy_user_region_refs),
        "oldRoleDocsDeleted": len(user_role_migrations),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Back up Firestore, migrate role assignments, and move client docs under Regions.",
    )
    parser.parse_args()

    try:
        result = run_migration()
    except MigrationConflict as exc:
        print(str(exc))
        return 1

    print(f"Backup: {result['backupPath']}")
    print(f"Role defaults written: {result['roleDefaultsWritten']}")
    print(f"User roles written: {result['userRolesWritten']}")
    print(f"Clients copied: {result['clientsCopied']}")
    print(f"Region docs cleaned: {result['regionDocsCleaned']}")
    print(f"Old nested client docs deleted: {result['oldClientDocsDeleted']}")
    print(f"Old user-region docs deleted: {result['oldUserRegionDocsDeleted']}")
    print(f"Old role docs deleted: {result['oldRoleDocsDeleted']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
