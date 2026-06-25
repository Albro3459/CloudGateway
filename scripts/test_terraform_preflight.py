"""Unit tests for the regional preflight decision logic."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "terraform_preflight", Path(__file__).with_name("terraform-preflight.py")
)
assert _SPEC and _SPEC.loader
pf = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(pf)

ZONE = "zone123"
API = pf.API_RECORD_ADDRESS
WG = pf.WG_RECORD_ADDRESS
INSTANCE = pf.INSTANCE_ADDRESS
API_HOST = "us-x-1.example.com"
WG_HOST = "wg.us-x-1.example.com"


def record(rid: str) -> dict:
    return {"id": rid, "name": API_HOST, "content": "1.2.3.4", "proxied": True}


def instance(iid: str) -> dict:
    return {"id": iid, "display-name": "cg", "lifecycle-state": "RUNNING"}


def evaluate(api_records=None, wg_records=None, instances=None, managed_ids=None, plan_changes=None):
    return pf.evaluate_region(
        "us-x-1",
        ZONE,
        managed_ids or {},
        api_records or [],
        wg_records or [],
        instances or [],
        API_HOST,
        WG_HOST,
        plan_changes,
    )


class EvaluateRegionTests(unittest.TestCase):
    def test_first_deploy_no_resources_is_clean(self):
        self.assertEqual(evaluate(), [])

    def test_record_in_state_is_clean(self):
        errors = evaluate(api_records=[record("rec1")], managed_ids={API: "rec1"})
        self.assertEqual(errors, [])

    def test_record_in_state_with_zone_prefixed_id_is_clean(self):
        errors = evaluate(api_records=[record("rec1")], managed_ids={API: f"{ZONE}/rec1"})
        self.assertEqual(errors, [])

    def test_unmanaged_record_is_flagged(self):
        errors = evaluate(api_records=[record("rec1")], managed_ids={})
        self.assertEqual(len(errors), 1)
        self.assertIn("not owned by Terraform state", errors[0])

    def test_record_id_mismatch_is_flagged(self):
        errors = evaluate(api_records=[record("rec1")], managed_ids={API: "other"})
        self.assertEqual(len(errors), 1)
        self.assertIn("not owned by Terraform state", errors[0])

    def test_duplicate_records_are_flagged(self):
        errors = evaluate(api_records=[record("rec1"), record("rec2")], managed_ids={API: "rec1"})
        self.assertEqual(len(errors), 1)
        self.assertIn("duplicate", errors[0])

    def test_instance_in_state_is_clean(self):
        errors = evaluate(instances=[instance("vm1")], managed_ids={INSTANCE: "vm1"})
        self.assertEqual(errors, [])

    def test_unmanaged_instance_is_flagged(self):
        errors = evaluate(instances=[instance("vm1")], managed_ids={})
        self.assertEqual(len(errors), 1)
        self.assertIn("not owned by Terraform state", errors[0])

    def test_duplicate_instances_are_flagged(self):
        errors = evaluate(instances=[instance("vm1"), instance("vm2")], managed_ids={INSTANCE: "vm1"})
        self.assertEqual(len(errors), 1)
        self.assertIn("duplicate", errors[0])

    def test_plan_guard_skipped_without_changes(self):
        # api record exists at edge but plan_changes is None (external-only run): no guard error.
        errors = evaluate(api_records=[record("rec1")], managed_ids={API: "rec1"}, plan_changes=None)
        self.assertEqual(errors, [])

    def test_plan_create_against_existing_external_is_flagged(self):
        changes = [{"address": API, "change": {"actions": ["create"]}}]
        errors = evaluate(
            api_records=[record("rec1")],
            managed_ids={API: "rec1"},
            plan_changes=changes,
        )
        self.assertEqual(len(errors), 1)
        self.assertIn("wants to create", errors[0])

    def test_plan_replace_is_not_flagged(self):
        # A rebuild plans delete+create; only a bare create should trip the guard.
        changes = [{"address": INSTANCE, "change": {"actions": ["delete", "create"]}}]
        errors = evaluate(
            instances=[instance("vm1")],
            managed_ids={INSTANCE: "vm1"},
            plan_changes=changes,
        )
        self.assertEqual(errors, [])

    def test_plan_create_with_no_external_is_clean(self):
        # First deploy: plan creates resources, nothing at the edge yet.
        changes = [
            {"address": API, "change": {"actions": ["create"]}},
            {"address": INSTANCE, "change": {"actions": ["create"]}},
        ]
        self.assertEqual(evaluate(plan_changes=changes), [])


class StateMatchesTests(unittest.TestCase):
    def test_absent_address_is_false(self):
        self.assertFalse(pf.state_matches({}, API, "rec1"))

    def test_exact_id_matches(self):
        self.assertTrue(pf.state_matches({API: "rec1"}, API, "rec1"))

    def test_zone_prefixed_id_matches(self):
        self.assertTrue(pf.state_matches({API: f"{ZONE}/rec1"}, API, "rec1", ZONE))


class ReadTfvarsTests(unittest.TestCase):
    def _write(self, body: str) -> Path:
        tmp = Path(tempfile.mkstemp(suffix=".tfvars")[1])
        tmp.write_text(body)
        self.addCleanup(tmp.unlink)
        return tmp

    def test_quoted_bare_comment_and_heredoc(self):
        values = pf.read_tfvars(
            self._write(
                'region = "us-x-1"\n'
                "# a comment\n"
                "region_display_order = 3  # trailing\n"
                "wg_server_private_key = <<EOF\n"
                "SECRETLINE\n"
                "EOF\n"
                'api_hostname = "us-x-1.example.com"\n'
            )
        )
        self.assertEqual(values["region"], "us-x-1")
        self.assertEqual(values["region_display_order"], "3")
        self.assertEqual(values["api_hostname"], "us-x-1.example.com")
        # Heredoc body is not captured as a value.
        self.assertEqual(values["wg_server_private_key"], "")


class LoadPlanChangesTests(unittest.TestCase):
    def test_none_path_returns_none(self):
        self.assertIsNone(pf.load_plan_changes(None))

    def test_missing_path_returns_empty(self):
        self.assertEqual(pf.load_plan_changes(Path("/nonexistent/plan.json")), [])

    def test_reads_resource_changes(self):
        tmp = Path(tempfile.mkstemp(suffix=".json")[1])
        tmp.write_text('{"resource_changes": [{"address": "x"}]}')
        self.addCleanup(tmp.unlink)
        self.assertEqual(pf.load_plan_changes(tmp), [{"address": "x"}])


if __name__ == "__main__":
    unittest.main()
