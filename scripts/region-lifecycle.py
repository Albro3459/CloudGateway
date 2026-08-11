#!/usr/bin/env python3
"""Prepare and verify safe CloudGateway regional replacement or destroy operations."""

from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence


REPO_ROOT = Path(__file__).resolve().parents[1]
CREDENTIALS_PATH = REPO_ROOT / "Backend" / "Firebase" / "Secrets" / "firebase-credentials.json"
INSTANCE_ADDRESS = "oci_core_instance.generated_oci_core_instance"


class LifecycleError(RuntimeError):
    """A lifecycle operation cannot be proven safe."""


@dataclass(frozen=True)
class RegionSnapshot:
    region_id: str
    enabled: object
    mesh_enabled: object
    drain_requested_at: object
    public_key: object
    tunnel_network_v4: object
    tunnel_network_v6: object

    @classmethod
    def from_data(cls, region_id: str, data: Mapping[str, object]) -> RegionSnapshot:
        return cls(
            region_id=region_id,
            enabled=data.get("enabled"),
            mesh_enabled=data.get("meshEnabled"),
            drain_requested_at=data.get("drainRequestedAt"),
            public_key=data.get("wireguardPublicKey"),
            tunnel_network_v4=data.get("tunnelNetworkV4"),
            tunnel_network_v6=data.get("tunnelNetworkV6"),
        )


@dataclass(frozen=True)
class PlanInspection:
    instance_actions: tuple[str, ...]

    @property
    def requires_drain(self) -> bool:
        return "delete" in self.instance_actions

    @property
    def is_replacement(self) -> bool:
        return "delete" in self.instance_actions and "create" in self.instance_actions


def _utc_timestamp(value: object) -> dt.datetime | None:
    if not isinstance(value, dt.datetime) or value.tzinfo is None or value.utcoffset() is None:
        return None
    return value.astimezone(dt.timezone.utc)


def _timestamp_is_newer(updated_at: object, drain_requested_at: object) -> bool:
    updated = _utc_timestamp(updated_at)
    drain = _utc_timestamp(drain_requested_at)
    return updated is not None and drain is not None and updated > drain


def _known_public_key(value: object) -> str | None:
    return value if isinstance(value, str) and value else None


def verify_drain_state(
    target_region_id: str,
    target_data: Mapping[str, object] | None,
    region_data: Mapping[str, Mapping[str, object]],
    mesh_data: Mapping[str, Mapping[str, object] | None],
) -> list[str]:
    """Return every reason the Firestore state is not proven drained.

    This function performs no I/O. Missing, malformed, or ambiguous state fails closed.
    """
    errors: list[str] = []
    if target_data is None:
        return [f"{target_region_id}: Regions document is missing."]

    target = RegionSnapshot.from_data(target_region_id, target_data)
    if target.enabled is not False:
        errors.append(f"{target_region_id}: region must remain disabled (enabled=false).")
    if target.mesh_enabled is not False:
        errors.append(f"{target_region_id}: region must remain mesh-disabled (meshEnabled=false).")
    if _utc_timestamp(target.drain_requested_at) is None:
        errors.append(f"{target_region_id}: drainRequestedAt is missing or is not an unambiguous timestamp.")

    target_key = _known_public_key(target.public_key)
    for region_id, raw_region in sorted(region_data.items()):
        if not isinstance(raw_region, Mapping):
            errors.append(f"{target_region_id}: Regions/{region_id} document is malformed.")
            continue
        enabled = raw_region.get("enabled")
        if not isinstance(enabled, bool):
            errors.append(f"{target_region_id}: Regions/{region_id}.enabled is missing or malformed.")
            continue
        if region_id == target_region_id or enabled is not True:
            continue
        mesh = mesh_data.get(region_id)
        if mesh is None:
            errors.append(f"{target_region_id}: Mesh/{region_id} is missing for an enabled region.")
            continue
        updated_at = mesh.get("updatedAt")
        if not _timestamp_is_newer(updated_at, target.drain_requested_at):
            errors.append(
                f"{target_region_id}: Mesh/{region_id}.updatedAt must be strictly newer than drainRequestedAt."
            )
        peers = mesh.get("peers")
        if not isinstance(peers, dict) or not all(isinstance(peer_id, str) for peer_id in peers):
            errors.append(f"{target_region_id}: Mesh/{region_id}.peers is missing or malformed.")
            continue
        if target_region_id in peers:
            errors.append(f"{target_region_id}: Mesh/{region_id}.peers still contains the target region ID.")
        if any(not isinstance(peer_data, Mapping) for peer_data in peers.values()):
            errors.append(f"{target_region_id}: Mesh/{region_id}.peers contains malformed peer metadata.")
            continue
        if target_key is not None:
            for peer_data in peers.values():
                if isinstance(peer_data, Mapping) and peer_data.get("publicKey") == target_key:
                    errors.append(f"{target_region_id}: Mesh/{region_id}.peers still contains the target public key.")
                    break
    return errors


def _canonical_network(value: object, label: str, family: int | None = None) -> str:
    if not isinstance(value, str) or not value:
        raise LifecycleError(f"{label} is missing or is not a CIDR string.")
    try:
        import ipaddress

        network = ipaddress.ip_network(value, strict=True)
    except ValueError as exc:
        raise LifecycleError(f"{label} is not a canonical network: {value!r}.") from exc
    if family == 4 and network.version != 4:
        raise LifecycleError(f"{label} must be an IPv4 network.")
    if family == 6 and network.version != 6:
        raise LifecycleError(f"{label} must be an IPv6 network.")
    if str(network) != value:
        raise LifecycleError(f"{label} is not canonical: {value!r}; use {network}.")
    return str(network)


def verify_replacement_state(
    target_region_id: str,
    target_data: Mapping[str, object] | None,
    selected_network_v4: object,
    selected_network_v6: object,
    instance_statuses: Sequence[object],
) -> list[str]:
    """Verify replacement subnet safety without performing I/O."""
    if target_data is None:
        return [f"{target_region_id}: cannot verify replacement because the Regions document is missing."]

    errors: list[str] = []
    try:
        selected_v4 = _canonical_network(selected_network_v4, "selected wg_network_v4", 4)
    except LifecycleError as exc:
        errors.append(str(exc))
        selected_v4 = None
    try:
        selected_v6 = _canonical_network(selected_network_v6, "selected wg_network_v6", 6)
    except LifecycleError as exc:
        errors.append(str(exc))
        selected_v6 = None

    try:
        current_v4 = _canonical_network(target_data.get("tunnelNetworkV4"), "current tunnelNetworkV4", 4)
    except LifecycleError as exc:
        errors.append(f"{target_region_id}: {exc}")
        current_v4 = None
    try:
        current_v6 = _canonical_network(target_data.get("tunnelNetworkV6"), "current tunnelNetworkV6", 6)
    except LifecycleError as exc:
        errors.append(f"{target_region_id}: {exc}")
        current_v6 = None

    changed_v4 = selected_v4 is not None and current_v4 is not None and selected_v4 != current_v4
    changed_v6 = selected_v6 is not None and current_v6 is not None and selected_v6 != current_v6

    known_statuses = {"creating", "active", "failed", "removed"}
    invalid_statuses = sorted(
        repr(status) for status in instance_statuses if not isinstance(status, str) or status not in known_statuses
    )
    if invalid_statuses:
        errors.append(f"{target_region_id}: client reservation status is missing or invalid ({invalid_statuses!r}).")

    if changed_v4 or changed_v6:
        blocked_statuses = sorted(
            [status for status in instance_statuses if isinstance(status, str) and status in {"active", "creating"}]
        )
        if blocked_statuses:
            errors.append(
                f"{target_region_id}: subnet-changing replacement is blocked by active/creating client reservations "
                f"({', '.join(blocked_statuses)})."
            )
    return errors


def inspect_plan(payload: object) -> PlanInspection:
    if not isinstance(payload, Mapping):
        raise LifecycleError("Terraform plan JSON must be an object.")
    resource_changes = payload.get("resource_changes", [])
    if not isinstance(resource_changes, list):
        raise LifecycleError("Terraform plan JSON resource_changes must be a list.")
    actions: tuple[str, ...] = ()
    for change in resource_changes:
        if not isinstance(change, Mapping) or change.get("address") != INSTANCE_ADDRESS:
            continue
        raw_change = change.get("change")
        if not isinstance(raw_change, Mapping):
            raise LifecycleError("Terraform instance plan change is malformed.")
        raw_actions = raw_change.get("actions")
        if not isinstance(raw_actions, list) or not all(isinstance(action, str) for action in raw_actions):
            raise LifecycleError("Terraform instance plan actions are malformed.")
        actions = tuple(raw_actions)
        break
    return PlanInspection(actions)


def load_plan(path: Path) -> PlanInspection:
    try:
        payload = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise LifecycleError(f"cannot read Terraform plan JSON {path}: {exc}") from exc
    return inspect_plan(payload)


def plan_warning(region_id: str, inspection: PlanInspection) -> str | None:
    if not inspection.requires_drain:
        return None
    return (
        f"WARNING: Terraform plan for {region_id} includes OCI instance action "
        f"{list(inspection.instance_actions)!r}. Before apply/destroy, run prepare-drain {region_id}, "
        "dashboard Sync All across remaining enabled regions, then verify-drain; "
        "subnet-changing replacements also require no active/creating client reservations."
    )


def _preflight_read_tfvars(path: Path) -> Mapping[str, str]:
    preflight_path = Path(__file__).with_name("terraform-preflight.py")
    spec = importlib.util.spec_from_file_location("cloudgateway_terraform_preflight", preflight_path)
    if spec is None or spec.loader is None:
        raise LifecycleError("cannot load the Terraform preflight parser.")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.read_tfvars(path)


def _get_firestore_client(credentials_path: Path = CREDENTIALS_PATH) -> Any:
    import firebase_admin
    from firebase_admin import credentials, firestore

    if not firebase_admin._apps:
        firebase_admin.initialize_app(credentials.Certificate(str(credentials_path)))
    return firestore.client()


def _server_timestamp() -> object:
    from google.cloud.firestore_v1 import SERVER_TIMESTAMP

    return SERVER_TIMESTAMP


def _transactional():
    from google.cloud.firestore_v1 import transactional

    return transactional


def prepare_drain(db: Any, region_id: str) -> None:
    ref = db.collection("Regions").document(region_id)
    transactional = _transactional()

    @transactional
    def update(transaction: Any) -> None:
        snapshot = transaction.get(ref)
        if not getattr(snapshot, "exists", False):
            raise LifecycleError(f"{region_id}: Regions document is missing.")
        transaction.update(
            ref,
            {
                "enabled": False,
                "meshEnabled": False,
                "drainRequestedAt": _server_timestamp(),
            },
        )

    update(db.transaction())


def _read_region_data(db: Any) -> dict[str, dict[str, object]]:
    output: dict[str, dict[str, object]] = {}
    for snapshot in db.collection("Regions").stream():
        if not getattr(snapshot, "exists", False):
            continue
        data = snapshot.to_dict()
        if not isinstance(data, dict):
            raise LifecycleError(f"Regions/{snapshot.id}: document data is malformed.")
        output[str(snapshot.id)] = data
    return output


def _read_mesh_data(db: Any, region_ids: Sequence[str]) -> dict[str, Mapping[str, object] | None]:
    output: dict[str, Mapping[str, object] | None] = {}
    for region_id in region_ids:
        snapshot = db.collection("Mesh").document(region_id).get()
        if not getattr(snapshot, "exists", False):
            output[region_id] = None
            continue
        data = snapshot.to_dict()
        if not isinstance(data, dict):
            raise LifecycleError(f"Mesh/{region_id}: document data is malformed.")
        output[region_id] = data
    return output


def _read_instance_statuses(db: Any, region_id: str) -> list[object]:
    statuses: list[object] = []
    for snapshot in db.collection("Regions").document(region_id).collection("Instances").stream():
        data = snapshot.to_dict()
        if not isinstance(data, dict):
            raise LifecycleError(f"Regions/{region_id}/Instances/{snapshot.id}: document data is malformed.")
        statuses.append(data.get("status"))
    return statuses


def verify_drain(db: Any, region_id: str) -> None:
    try:
        regions = _read_region_data(db)
        target = regions.get(region_id)
        remaining_ids = [
            current_id for current_id, data in regions.items() if current_id != region_id and data.get("enabled") is True
        ]
        meshes = _read_mesh_data(db, remaining_ids)
    except LifecycleError:
        raise
    except Exception as exc:
        raise LifecycleError(f"{region_id}: Firestore read failed; drain cannot be proven: {exc}") from exc
    errors = verify_drain_state(region_id, target, regions, meshes)
    if errors:
        raise LifecycleError("\n".join(errors))


def verify_replacement(db: Any, region_id: str, varfile: Path) -> None:
    try:
        values = _preflight_read_tfvars(varfile)
        regions = _read_region_data(db)
        statuses = _read_instance_statuses(db, region_id)
    except LifecycleError:
        raise
    except Exception as exc:
        raise LifecycleError(f"{region_id}: Firestore or tfvars read failed; replacement cannot be proven: {exc}") from exc
    errors = verify_replacement_state(
        region_id,
        regions.get(region_id),
        values.get("wg_network_v4"),
        values.get("wg_network_v6"),
        statuses,
    )
    if errors:
        raise LifecycleError("\n".join(errors))


def verify_plan(db: Any, region_id: str, varfile: Path, plan_path: Path) -> PlanInspection:
    inspection = load_plan(plan_path)
    if not inspection.requires_drain:
        return inspection
    verify_drain(db, region_id)
    if inspection.is_replacement:
        verify_replacement(db, region_id, varfile)
    return inspection


def _command_prepare(args: argparse.Namespace) -> int:
    prepare_drain(_get_firestore_client(), args.region_id)
    print(f"Prepared drain for {args.region_id}: enabled=false and meshEnabled=false.")
    print(f"Next: run dashboard Sync All across remaining enabled regions, then verify-drain {args.region_id}.")
    return 0


def _command_verify_drain(args: argparse.Namespace) -> int:
    verify_drain(_get_firestore_client(), args.region_id)
    print(f"Drain verified for {args.region_id}; safe to continue the planned Terraform operation.")
    return 0


def _command_plan_check(args: argparse.Namespace) -> int:
    inspection = load_plan(args.plan_json)
    warning = plan_warning(args.region_id, inspection)
    if warning:
        print(warning)
    else:
        print(f"Plan for {args.region_id} has no OCI instance deletion; drain verification is not required.")
    return 0


def _command_verify_replacement(args: argparse.Namespace) -> int:
    verify_replacement(_get_firestore_client(), args.region_id, args.var_file)
    print(f"Replacement subnet and client reservation checks verified for {args.region_id}.")
    return 0


def _command_verify_plan(args: argparse.Namespace) -> int:
    db = _get_firestore_client()
    inspection = verify_plan(db, args.region_id, args.var_file, args.plan_json)
    if inspection.requires_drain:
        print(f"Drain and replacement checks verified for {args.region_id}.")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare = subparsers.add_parser("prepare-drain")
    prepare.add_argument("region_id")
    prepare.set_defaults(handler=_command_prepare)

    verify = subparsers.add_parser("verify-drain")
    verify.add_argument("region_id")
    verify.set_defaults(handler=_command_verify_drain)

    plan_check = subparsers.add_parser("plan-check")
    plan_check.add_argument("region_id")
    plan_check.add_argument("--plan-json", required=True, type=Path)
    plan_check.set_defaults(handler=_command_plan_check)

    verify_replacement_parser = subparsers.add_parser("verify-replacement")
    verify_replacement_parser.add_argument("region_id")
    verify_replacement_parser.add_argument("--var-file", required=True, type=Path)
    verify_replacement_parser.set_defaults(handler=_command_verify_replacement)

    verify_plan_parser = subparsers.add_parser("verify-plan")
    verify_plan_parser.add_argument("region_id")
    verify_plan_parser.add_argument("--var-file", required=True, type=Path)
    verify_plan_parser.add_argument("--plan-json", required=True, type=Path)
    verify_plan_parser.set_defaults(handler=_command_verify_plan)

    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except LifecycleError as exc:
        print(f"Lifecycle check failed: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"Lifecycle check failed closed due to Firestore or adapter error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
