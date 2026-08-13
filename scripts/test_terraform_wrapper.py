"""Regression tests for the safe ordering in the Terraform wrapper."""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[0] / "terraform.sh"
TEST_SCRIPT = Path(__file__).resolve().parents[0] / "test.sh"


class TerraformWrapperTests(unittest.TestCase):
    def setUp(self) -> None:
        self.text = SCRIPT.read_text()

    def _action_block(self, action: str, next_action: str) -> str:
        start = self.text.index(f"  {action})\n")
        end = self.text.index(f"  {next_action})\n", start)
        return self.text[start:end]

    def test_duplicate_expanded_region_arguments_are_rejected_before_external_checks(self):
        result = subprocess.run(
            ["bash", str(SCRIPT), "chicago", "us-chicago-1"],
            capture_output=True,
            check=False,
            text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("Duplicate region argument: us-chicago-1", result.stderr)

    def test_apply_prepares_every_plan_and_preflight_before_mutation(self):
        block = self._action_block("apply", "destroy")
        plan = block.index("      save_apply_plan")
        deploy_tag = block.index("      create_deploy_tag")
        source_ref = block.index("      set_source_ref")
        apply = block.index("      terraform apply")
        self.assertLess(plan, deploy_tag)
        self.assertLess(plan, source_ref)
        self.assertLess(plan, apply)
        self.assertNotIn("region-lifecycle", block)
        self.assertNotIn("verify-drain", block)

    def test_destroy_validates_and_prepares_every_plan_before_destroy(self):
        block = self._action_block("destroy", "*")
        preflight = block.index("      preflight_region")
        plan = block.index("      save_destroy_plan")
        destroy = block.index("      terraform destroy")
        self.assertLess(preflight, destroy)
        self.assertLess(plan, destroy)
        self.assertNotIn("region-lifecycle", block)
        self.assertNotIn("verify-drain", block)

    def test_test_wrapper_reports_direct_target_failure(self):
        test_text = TEST_SCRIPT.read_text()
        start = test_text.index("run_step() {")
        end = test_text.index("\n}\n\ntargets=()", start) + 3
        function = test_text[start:end]
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "runner.sh"
            script.write_text(
                "#!/usr/bin/env bash\n"
                "set -uo pipefail\n"
                "FAILURES=()\n"
                f"{function}\n"
                "run_step direct-failure false || { printf 'failures=%s\\n' \"${#FAILURES[@]}\"; exit 1; }\n"
            )
            result = subprocess.run(["bash", str(script)], capture_output=True, text=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAILED: direct-failure", result.stderr)
        self.assertIn("failures=1", result.stdout)


if __name__ == "__main__":
    unittest.main()
