"""Exercise test target routing and failure reporting without external tools."""

from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent / "test.sh"


class TestRunnerTests(unittest.TestCase):
    def run_targets(
        self, *arguments: str, failing: str | None = None, recorded_failure: str | None = None
    ) -> subprocess.CompletedProcess[str]:
        text = SCRIPT.read_text()
        start = text.index("run_step() {")
        runner = text[start:]
        stubs = []
        for target in ("api", "web", "infra", "firebase", "ios", "macos"):
            outcome = "return 1" if target == failing else "return 0"
            if target == recorded_failure:
                outcome = f'FAILURES+=("{target} check"); return 0'
            stubs.append(
                f'test_{target}() {{ echo "CALLED: {target} signed=$APPLE_SIGNED"; {outcome}; }}'
            )
        harness = "\n".join(["set -uo pipefail", "FAILURES=()", "APPLE_SIGNED=0", *stubs, runner])
        return subprocess.run(
            ["/bin/bash", "-c", harness, "test.sh", *arguments],
            capture_output=True,
            text=True,
            check=False,
        )

    def called(self, result: subprocess.CompletedProcess[str]) -> list[str]:
        return [line.split()[1] for line in result.stdout.splitlines() if line.startswith("CALLED:")]

    def test_default_runs_every_suite_once(self):
        result = self.run_targets()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.called(result), ["api", "web", "infra", "firebase", "ios", "macos"])
        self.assertIn("All checks passed.", result.stdout)

    def test_apple_runs_both_platforms(self):
        result = self.run_targets("apple")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.called(result), ["ios", "macos"])

    def test_platform_targets_run_independently(self):
        for target in ("ios", "macos"):
            with self.subTest(target=target):
                result = self.run_targets(target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.called(result), [target])

    def test_overlapping_targets_and_aliases_run_once(self):
        result = self.run_targets("ios", "apple", "macos", "apple", "web", "app")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.called(result), ["ios", "macos", "web"])

    def test_signed_flag_applies_to_both_platforms(self):
        result = self.run_targets("apple", "--signed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CALLED: ios signed=1", result.stdout)
        self.assertIn("CALLED: macos signed=1", result.stdout)

    def test_platform_failure_does_not_skip_other_platform_or_later_suites(self):
        result = self.run_targets("apple", "api", failing="ios")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.called(result), ["ios", "macos", "api"])
        self.assertNotIn("All checks passed.", result.stdout)
        self.assertIn("FAILED:", result.stdout)

    def test_recorded_check_failure_is_not_hidden_by_successful_target_return(self):
        result = self.run_targets("apple", recorded_failure="ios")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.called(result), ["ios", "macos"])
        self.assertIn("FAILED: ios check", result.stdout)
        self.assertNotIn("All checks passed.", result.stdout)

    def test_unknown_target_fails(self):
        result = self.run_targets("api", "unknown")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.called(result), [])
        self.assertIn("Unknown target: unknown", result.stderr)

    def test_default_continues_after_any_suite_fails(self):
        targets = ["api", "web", "infra", "firebase", "ios", "macos"]
        for target in targets:
            with self.subTest(target=target):
                result = self.run_targets(failing=target)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(self.called(result), targets)
                self.assertNotIn("All checks passed.", result.stdout)

    def run_shared_packages(self, fail_kit: bool) -> subprocess.CompletedProcess[str]:
        text = SCRIPT.read_text()
        start = text.index("test_apple_shared_packages() {")
        helper = text[start:text.index("\n}\n", start) + 3]
        harness = "\n".join([
            "set -uo pipefail",
            "ROOT=/",
            "APPLE_SHARED_TEST_STATUS=-1",
            f"FAIL_KIT={int(fail_kit)}",
            'run_check() { echo "CHECK: $1"; if [[ "$FAIL_KIT" -eq 1 && "$1" == *Kit* ]]; then return 1; fi; }',
            helper,
            'for iteration in 1 2; do status=0; test_apple_shared_packages || status=$?; echo "RESULT: $status"; done',
        ])
        return subprocess.run(
            ["/bin/bash", "-c", harness], capture_output=True, text=True, check=False
        )

    def test_shared_packages_run_once_for_both_platforms(self):
        result = self.run_shared_packages(fail_kit=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("CHECK:"), 2)
        self.assertEqual(result.stdout.count("RESULT: 0"), 2)

    def test_shared_failure_is_cached_without_skipping_other_package(self):
        result = self.run_shared_packages(fail_kit=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("CHECK:"), 2)
        self.assertIn("CHECK: Apple Firebase auth adapter tests", result.stdout)
        self.assertEqual(result.stdout.count("RESULT: 1"), 2)

    def test_platform_scans_use_separate_periphery_cache_keys(self):
        text = SCRIPT.read_text()
        keys = []
        for name in ("scan_apple_dead_code", "scan_macos_dead_code"):
            start = text.index(f"{name}() {{")
            function = text[start:text.index("\n}\n", start)]
            project = re.search(r'--project "([^"]+)"', function)
            self.assertIsNotNone(project)
            assert project is not None
            path = Path(project[1].replace("$ROOT", str(SCRIPT.parent.parent)))
            schemes = re.findall(r"--schemes ([\w-]+)", function)
            self.assertTrue(schemes)
            for scheme in schemes:
                self.assertTrue((path / "xcshareddata/xcschemes" / f"{scheme}.xcscheme").is_file())
            keys.append((path.stem, tuple(schemes)))
        self.assertNotEqual(keys[0], keys[1])


if __name__ == "__main__":
    unittest.main()
