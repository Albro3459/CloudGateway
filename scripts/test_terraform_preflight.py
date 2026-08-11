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


def region_values(
    network_v4="10.0.0.0/24",
    address_v4="10.0.0.1/24",
    dns_v4="10.0.0.1",
    network_v6="fd42:42:42::/64",
    address_v6="fd42:42:42::1/64",
    dns_v6="fd42:42:42::1",
):
    return {
        "wg_network_v4": network_v4,
        "wg_address_v4": address_v4,
        "wg_dns_address_v4": dns_v4,
        "wg_network_v6": network_v6,
        "wg_address_v6": address_v6,
        "wg_dns_address_v6": dns_v6,
    }


class EvaluateSubnetPlanTests(unittest.TestCase):
    def test_single_region_is_clean(self):
        self.assertEqual(pf.evaluate_subnet_plan({"us-sanjose-1": region_values()}), [])

    def test_multiple_non_overlapping_regions_are_clean(self):
        regions = {
            "us-sanjose-1": region_values(),
            "us-chicago-1": region_values(
                network_v4="10.0.1.0/24",
                address_v4="10.0.1.1/24",
                dns_v4="10.0.1.1",
                network_v6="fd42:42:42:1::/64",
                address_v6="fd42:42:42:1::1/64",
                dns_v6="fd42:42:42:1::1",
            ),
            "us-next-1": region_values(
                network_v4="10.0.2.0/24",
                address_v4="10.0.2.1/24",
                dns_v4="10.0.2.1",
                network_v6="fd42:42:42:2::/64",
                address_v6="fd42:42:42:2::1/64",
                dns_v6="fd42:42:42:2::1",
            ),
        }
        self.assertEqual(pf.evaluate_subnet_plan(regions), [])

    def test_overlapping_v4_networks_are_flagged(self):
        regions = {
            "us-sanjose-1": region_values(),
            "us-chicago-1": region_values(
                network_v4="10.0.0.0/25",
                address_v4="10.0.0.1/25",
                dns_v4="10.0.0.1",
                network_v6="fd42:42:42:1::/64",
                address_v6="fd42:42:42:1::1/64",
                dns_v6="fd42:42:42:1::1",
            ),
        }
        errors = pf.evaluate_subnet_plan(regions)
        self.assertEqual(len(errors), 1)
        self.assertIn("wg_network_v4", errors[0])
        self.assertIn("overlap", errors[0])

    def test_overlapping_v6_networks_are_flagged(self):
        regions = {
            "us-sanjose-1": region_values(),
            "us-chicago-1": region_values(
                network_v4="10.0.1.0/24",
                address_v4="10.0.1.1/24",
                dns_v4="10.0.1.1",
            ),
        }
        errors = pf.evaluate_subnet_plan(regions)
        self.assertEqual(len(errors), 1)
        self.assertIn("wg_network_v6", errors[0])
        self.assertIn("overlap", errors[0])

    def test_identical_subnets_are_flagged(self):
        regions = {
            "us-sanjose-1": region_values(),
            "us-chicago-1": region_values(),
        }
        errors = pf.evaluate_subnet_plan(regions)
        self.assertEqual(len(errors), 2)
        self.assertTrue(any("wg_network_v4" in e for e in errors))
        self.assertTrue(any("wg_network_v6" in e for e in errors))

    def test_address_outside_own_network_is_flagged(self):
        regions = {"us-sanjose-1": region_values(address_v4="10.0.5.1/24")}
        errors = pf.evaluate_subnet_plan(regions)
        self.assertEqual(len(errors), 1)
        self.assertIn("wg_address_v4", errors[0])
        self.assertIn("not inside its own network", errors[0])

    def test_dns_address_outside_own_network_is_flagged(self):
        regions = {"us-sanjose-1": region_values(dns_v6="fd42:42:42:9::1")}
        errors = pf.evaluate_subnet_plan(regions)
        self.assertEqual(len(errors), 1)
        self.assertIn("wg_dns_address_v6", errors[0])
        self.assertIn("not inside its own network", errors[0])

    def test_network_outside_v4_aggregate_is_flagged(self):
        regions = {
            "us-sanjose-1": region_values(
                network_v4="10.1.0.0/24", address_v4="10.1.0.1/24", dns_v4="10.1.0.1"
            )
        }
        errors = pf.evaluate_subnet_plan(regions)
        self.assertEqual(len(errors), 1)
        self.assertIn("outside the shared aggregate", errors[0])
        self.assertIn("10.0.0.0/16", errors[0])

    def test_network_outside_v6_aggregate_is_flagged(self):
        regions = {
            "us-sanjose-1": region_values(
                network_v6="fd43:42:42::/64", address_v6="fd43:42:42::1/64", dns_v6="fd43:42:42::1"
            )
        }
        errors = pf.evaluate_subnet_plan(regions)
        self.assertEqual(len(errors), 1)
        self.assertIn("outside the shared aggregate", errors[0])
        self.assertIn("fd42:42:42::/48", errors[0])

    def test_host_bits_set_is_flagged(self):
        regions = {"us-sanjose-1": region_values(network_v4="10.0.0.5/24")}
        errors = pf.evaluate_subnet_plan(regions)
        self.assertEqual(len(errors), 1)
        self.assertIn("no host bits set", errors[0])

    def test_wrong_family_is_flagged(self):
        regions = {
            "us-sanjose-1": region_values(network_v4="fd42:42:42::/64")
        }
        errors = pf.evaluate_subnet_plan(regions)
        self.assertEqual(len(errors), 1)
        self.assertIn("must be an IPv4 network", errors[0])

    def test_incomplete_region_is_hard_failure(self):
        values = region_values()
        del values["wg_network_v6"]
        errors = pf.evaluate_subnet_plan({"us-chicago-1": values})
        self.assertEqual(len(errors), 1)
        self.assertIn("missing", errors[0])
        self.assertIn("wg_network_v6", errors[0])


class DiscoverSiblingTfvarsTests(unittest.TestCase):
    def _write(self, directory: Path, name: str, body: str) -> Path:
        path = directory / name
        path.write_text(body)
        return path

    def test_skips_malformed_and_region_id_less_siblings_and_flags_broken_sibling(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            directory = Path(tmpdir)
            self._write(
                directory,
                "us-sanjose-1.terraform.tfvars",
                'region_id = "us-sanjose-1"\n'
                'wg_network_v4 = "10.0.0.0/24"\n'
                'wg_address_v4 = "10.0.0.1/24"\n'
                'wg_dns_address_v4 = "10.0.0.1"\n'
                'wg_network_v6 = "fd42:42:42::/64"\n'
                'wg_address_v6 = "fd42:42:42::1/64"\n'
                'wg_dns_address_v6 = "fd42:42:42::1"\n',
            )
            self._write(directory, "no-region-id.terraform.tfvars", 'region = "us-x-1"\n')
            self._write(
                directory,
                "us-chicago-1.terraform.tfvars",
                'region_id = "us-chicago-1"\n',
            )

            varfile = directory / "us-sanjose-1.terraform.tfvars"
            regions, notes = pf.discover_sibling_tfvars(varfile)

            self.assertIn("us-sanjose-1", regions)
            self.assertIn("us-chicago-1", regions)
            self.assertEqual(regions["us-chicago-1"]["wg_network_v4"], "")
            self.assertEqual(len(notes), 1)
            self.assertIn("no-region-id.terraform.tfvars", notes[0])

            errors = pf.evaluate_subnet_plan(regions)
            self.assertEqual(len(errors), 1)
            self.assertIn("us-chicago-1", errors[0])
            self.assertIn("missing", errors[0])


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
