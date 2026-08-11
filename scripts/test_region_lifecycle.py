"""Pure tests for regional drain and replacement lifecycle guards."""

from __future__ import annotations

import datetime as dt
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


_SPEC = importlib.util.spec_from_file_location(
    "region_lifecycle", Path(__file__).with_name("region-lifecycle.py")
)
assert _SPEC and _SPEC.loader
lifecycle = importlib.util.module_from_spec(_SPEC)
sys.modules[lifecycle.__name__] = lifecycle
_SPEC.loader.exec_module(lifecycle)

STAMP = dt.datetime(2026, 8, 10, 12, 0, tzinfo=dt.timezone.utc)
NEWER = STAMP + dt.timedelta(seconds=1)
KEY = "server-public-key"


def region(*, enabled: object = False, mesh_enabled: object = False, key: object = KEY, drain: object = STAMP, v4: object = "10.0.0.0/24", v6: object = "fd42:42:42::/64") -> dict[str, object]:
    return {
        "enabled": enabled,
        "meshEnabled": mesh_enabled,
        "wireguardPublicKey": key,
        "drainRequestedAt": drain,
        "tunnelNetworkV4": v4,
        "tunnelNetworkV6": v6,
    }


def mesh(*, updated_at=NEWER, peers=None):
    return {"updatedAt": updated_at, "peers": peers or {}}


def plan(actions):
    return {
        "resource_changes": [
            {
                "address": lifecycle.INSTANCE_ADDRESS,
                "change": {"actions": actions},
            }
        ]
    }


class DrainVerificationTests(unittest.TestCase):
    def verify(self, target=None, regions=None, meshes=None):
        region_map = regions if regions is not None else {"us-chicago-1": target or region()}
        target_data = target if target is not None else region_map.get("us-chicago-1")
        return lifecycle.verify_drain_state(
            "us-chicago-1",
            target_data,
            region_map,
            meshes or {},
        )

    def test_missing_target_fails(self):
        self.assertIn("missing", self.verify(target=None, regions={})[0])

    def test_enabled_target_fails(self):
        errors = self.verify(target=region(enabled=True))
        self.assertTrue(any("enabled=false" in error for error in errors))

    def test_mesh_enabled_target_fails(self):
        errors = self.verify(target=region(mesh_enabled=True))
        self.assertTrue(any("meshEnabled=false" in error for error in errors))

    def test_missing_drain_timestamp_fails(self):
        errors = self.verify(target=region(drain=None))
        self.assertTrue(any("drainRequestedAt" in error for error in errors))

    def test_invalid_drain_timestamp_fails(self):
        errors = self.verify(target=region(drain="2026-08-10T12:00:00Z"))
        self.assertTrue(any("timestamp" in error for error in errors))

    def test_no_remaining_enabled_regions_passes(self):
        self.assertEqual(self.verify(), [])

    def test_missing_mesh_fails(self):
        regions = {"us-chicago-1": region(), "us-sanjose-1": region(enabled=True)}
        errors = self.verify(regions=regions, meshes={})
        self.assertTrue(any("Mesh/us-sanjose-1" in error for error in errors))

    def test_stale_mesh_fails(self):
        regions = {"us-chicago-1": region(), "us-sanjose-1": region(enabled=True)}
        meshes = {"us-sanjose-1": mesh(updated_at=STAMP - dt.timedelta(seconds=1))}
        errors = self.verify(regions=regions, meshes=meshes)
        self.assertTrue(any("strictly newer" in error for error in errors))

    def test_equal_mesh_timestamp_fails(self):
        regions = {"us-chicago-1": region(), "us-sanjose-1": region(enabled=True)}
        errors = self.verify(regions=regions, meshes={"us-sanjose-1": mesh(updated_at=STAMP)})
        self.assertTrue(any("strictly newer" in error for error in errors))

    def test_newer_mesh_timestamp_passes(self):
        regions = {"us-chicago-1": region(), "us-sanjose-1": region(enabled=True)}
        self.assertEqual(self.verify(regions=regions, meshes={"us-sanjose-1": mesh()}), [])

    def test_target_id_in_peers_fails(self):
        regions = {"us-chicago-1": region(), "us-sanjose-1": region(enabled=True)}
        meshes = {"us-sanjose-1": mesh(peers={"us-chicago-1": {}})}
        errors = self.verify(regions=regions, meshes=meshes)
        self.assertTrue(any("region ID" in error for error in errors))

    def test_target_key_in_peers_fails(self):
        regions = {"us-chicago-1": region(), "us-sanjose-1": region(enabled=True)}
        meshes = {"us-sanjose-1": mesh(peers={"other": {"publicKey": KEY}})}
        errors = self.verify(regions=regions, meshes=meshes)
        self.assertTrue(any("public key" in error for error in errors))

    def test_unrelated_peer_passes(self):
        regions = {"us-chicago-1": region(), "us-sanjose-1": region(enabled=True)}
        meshes = {"us-sanjose-1": mesh(peers={"other": {"publicKey": "unrelated"}})}
        self.assertEqual(self.verify(regions=regions, meshes=meshes), [])

    def test_malformed_mesh_fails_closed(self):
        regions = {"us-chicago-1": region(), "us-sanjose-1": region(enabled=True)}
        errors = self.verify(regions=regions, meshes={"us-sanjose-1": {"updatedAt": NEWER}})
        self.assertTrue(any("peers" in error for error in errors))


class ReplacementVerificationTests(unittest.TestCase):
    def test_same_subnet_allows_active_clients(self):
        self.assertEqual(
            lifecycle.verify_replacement_state(
                "us-sanjose-1", region(), "10.0.0.0/24", "fd42:42:42::/64", ["active"]
            ),
            [],
        )

    def test_changed_subnet_blocks_active_clients(self):
        errors = lifecycle.verify_replacement_state(
            "us-sanjose-1", region(), "10.0.1.0/24", "fd42:42:42:1::/64", ["active"]
        )
        self.assertTrue(any("active/creating" in error for error in errors))

    def test_changed_subnet_blocks_creating_clients(self):
        errors = lifecycle.verify_replacement_state(
            "us-sanjose-1", region(), "10.0.1.0/24", "fd42:42:42:1::/64", ["creating"]
        )
        self.assertTrue(any("active/creating" in error for error in errors))

    def test_deleted_and_removed_clients_do_not_block(self):
        errors = lifecycle.verify_replacement_state(
            "us-sanjose-1", region(), "10.0.1.0/24", "fd42:42:42:1::/64", ["failed", "removed"]
        )
        self.assertEqual(errors, [])

    def test_missing_target_fails(self):
        errors = lifecycle.verify_replacement_state(
            "us-sanjose-1", None, "10.0.0.0/24", "fd42:42:42::/64", []
        )
        self.assertTrue(any("missing" in error for error in errors))

    def test_invalid_reservation_status_fails_closed(self):
        errors = lifecycle.verify_replacement_state(
            "us-sanjose-1", region(), "10.0.0.0/24", "fd42:42:42::/64", [None]
        )
        self.assertTrue(any("status" in error for error in errors))

    def test_invalid_selected_network_fails(self):
        errors = lifecycle.verify_replacement_state(
            "us-sanjose-1", region(), "10.0.0.1/24", "fd42:42:42::/64", []
        )
        self.assertTrue(any("canonical" in error for error in errors))


class PlanInspectionTests(unittest.TestCase):
    def test_create_does_not_require_drain(self):
        inspection = lifecycle.inspect_plan(plan(["create"]))
        self.assertFalse(inspection.requires_drain)
        self.assertIsNone(lifecycle.plan_warning("us-x-1", inspection))

    def test_update_does_not_require_drain(self):
        self.assertFalse(lifecycle.inspect_plan(plan(["update"])).requires_drain)

    def test_delete_requires_drain(self):
        inspection = lifecycle.inspect_plan(plan(["delete"]))
        self.assertTrue(inspection.requires_drain)
        self.assertIn("prepare-drain", lifecycle.plan_warning("us-x-1", inspection) or "")

    def test_replacement_requires_drain(self):
        inspection = lifecycle.inspect_plan(plan(["delete", "create"]))
        self.assertTrue(inspection.requires_drain)
        self.assertIn("verify-drain", lifecycle.plan_warning("us-x-1", inspection) or "")

    def test_noop_without_instance_change_does_not_require_drain(self):
        self.assertFalse(lifecycle.inspect_plan({"resource_changes": []}).requires_drain)

    def test_malformed_plan_fails_closed(self):
        with self.assertRaises(lifecycle.LifecycleError):
            lifecycle.inspect_plan({"resource_changes": {}})


class FirestoreAdapterTests(unittest.TestCase):
    def test_firestore_read_error_fails_closed(self):
        class Db:
            def collection(self, _name):
                raise RuntimeError("offline")

        with self.assertRaises(lifecycle.LifecycleError):
            lifecycle.verify_drain(Db(), "us-x-1")


class PrepareDrainAdapterTests(unittest.TestCase):
    def test_prepare_missing_target_fails_before_update(self):
        class Snapshot:
            exists = False

        class Transaction:
            def get(self, _ref):
                return Snapshot()

            def update(self, *_args):
                raise AssertionError("must not update missing region")

        class Db:
            def transaction(self):
                return Transaction()

            def collection(self, _name):
                return self

            def document(self, _region_id):
                return self

        with patch.object(lifecycle, "_transactional", return_value=lambda fn: fn):
            with self.assertRaises(lifecycle.LifecycleError):
                lifecycle.prepare_drain(Db(), "us-x-1")

    def test_prepare_writes_required_fields(self):
        updates = []

        class Snapshot:
            exists = True

        class Transaction:
            def get(self, _ref):
                return Snapshot()

            def update(self, _ref, data):
                updates.append(data)

        class Db:
            def transaction(self):
                return Transaction()

            def collection(self, _name):
                return self

            def document(self, _region_id):
                return self

        with patch.object(lifecycle, "_transactional", return_value=lambda fn: fn):
            with patch.object(lifecycle, "_server_timestamp", return_value="SERVER_TIMESTAMP"):
                lifecycle.prepare_drain(Db(), "us-x-1")
        self.assertEqual(updates, [{"enabled": False, "meshEnabled": False, "drainRequestedAt": "SERVER_TIMESTAMP"}])


class PlanFileTests(unittest.TestCase):
    def test_load_plan_reads_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plan.json"
            path.write_text(json.dumps(plan(["delete", "create"])))
            self.assertTrue(lifecycle.load_plan(path).requires_drain)


class TerraformWrapperOrderingTests(unittest.TestCase):
    def test_apply_verifies_all_targets_before_deploy_tag(self):
        wrapper = Path(__file__).with_name("terraform.sh").read_text()
        self.assertLess(wrapper.index('verify_apply_lifecycle "${REGION_IDS'), wrapper.index("create_deploy_tag --confirmed"))

    def test_destroy_verifies_all_targets_before_destroy(self):
        wrapper = Path(__file__).with_name("terraform.sh").read_text()
        self.assertLess(wrapper.index("verify_destroy_lifecycle"), wrapper.index("terraform destroy"))

    def test_plan_path_uses_lifecycle_warning_adapter(self):
        wrapper = Path(__file__).with_name("terraform.sh").read_text()
        self.assertIn('python3 "$LIFECYCLE" plan-check', wrapper)


if __name__ == "__main__":
    unittest.main()
