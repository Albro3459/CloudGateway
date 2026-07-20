"""Tests for the Python embedded in scripts/ios-release.sh.

`bash -n` only checks the shell syntax and treats the two `<<'PY'` heredocs
(the App Store Connect JWT signer and the version bumper) as opaque strings, so
a Python bug in either would first surface during a real production release.
These tests extract both heredocs, syntax-check them, and exercise the version
bumper against a copy of the real project.pbxproj so a project restructure that
breaks the release parser is caught locally instead.
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RELEASE_SCRIPT = ROOT / "scripts" / "ios-release.sh"
PBXPROJ = ROOT / "Frontend/Apple/iOS/CloudGateway.xcodeproj/project.pbxproj"


def extract_heredocs(text: str, tag: str = "PY") -> list[str]:
    """Return the body of every `<<'PY' ... PY` heredoc in the script."""
    blocks: list[str] = []
    current: list[str] | None = None
    for line in text.splitlines():
        if current is None:
            if line.rstrip().endswith(f"<<'{tag}'"):
                current = []
        elif line == tag:
            blocks.append("\n".join(current) + "\n")
            current = None
        else:
            current.append(line)
    return blocks


class HeredocDiscoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.blocks = extract_heredocs(RELEASE_SCRIPT.read_text(encoding="utf-8"))

    def test_two_python_heredocs(self) -> None:
        self.assertEqual(len(self.blocks), 2, "expected the JWT and bump heredocs")

    def test_all_heredocs_compile(self) -> None:
        for index, block in enumerate(self.blocks):
            with self.subTest(block=index):
                compile(block, f"<ios-release heredoc {index}>", "exec")


def bump_program() -> str:
    blocks = extract_heredocs(RELEASE_SCRIPT.read_text(encoding="utf-8"))
    bump = [b for b in blocks if "CURRENT_PROJECT_VERSION" in b]
    assert len(bump) == 1, "expected exactly one version-bump heredoc"
    return bump[0]


class VersionBumpTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.script = Path(self.tmp.name) / "bump.py"
        self.script.write_text(bump_program(), encoding="utf-8")
        self.original = PBXPROJ.read_text(encoding="utf-8")

    def run_bump(
        self, text: str, mode: str
    ) -> tuple[subprocess.CompletedProcess[str], str]:
        target = Path(self.tmp.name) / "project.pbxproj"
        target.write_text(text, encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(self.script), str(target), mode],
            capture_output=True,
            text=True,
        )
        return result, target.read_text(encoding="utf-8")

    def builds(self, text: str) -> list[str]:
        return re.findall(r"\n\s*CURRENT_PROJECT_VERSION = (\d+);", text)

    def versions(self, text: str) -> list[str]:
        return re.findall(r"\n\s*MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+);", text)

    def test_plain_build_bump(self) -> None:
        before_builds = self.builds(self.original)
        before_versions = self.versions(self.original)
        current_build = before_builds[0]
        result, result_text = self.run_bump(self.original, "")
        self.assertEqual(result.returncode, 0, result.stderr)

        after_builds = self.builds(result_text)
        after_versions = self.versions(result_text)
        self.assertEqual(len(after_builds), len(before_builds))
        self.assertTrue(all(b == str(int(current_build) + 1) for b in after_builds))
        self.assertEqual(after_versions, before_versions, "marketing must not move")

        fields = result.stdout.split()
        self.assertEqual(fields[1], current_build)
        self.assertEqual(fields[3], str(int(current_build) + 1))
        self.assertEqual(fields[0], fields[2], "marketing unchanged without --version")

    def test_version_bump_modes(self) -> None:
        current_version = self.versions(self.original)[0]
        major, minor, patch = (int(x) for x in current_version.split("."))
        expected = {
            "major": f"{major + 1}.0.0",
            "minor": f"{major}.{minor + 1}.0",
            "patch": f"{major}.{minor}.{patch + 1}",
        }
        for mode, want in expected.items():
            with self.subTest(mode=mode):
                result, result_text = self.run_bump(self.original, mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                after = self.versions(result_text)
                self.assertTrue(all(v == want for v in after), after)

    def test_build_drift_aborts(self) -> None:
        current_build = self.builds(self.original)[0]
        drifted_build = str(int(current_build) - 1)
        drifted = self.original.replace(
            f"CURRENT_PROJECT_VERSION = {current_build};",
            f"CURRENT_PROJECT_VERSION = {drifted_build};",
            1,
        )
        self.assertNotEqual(drifted, self.original, "drift replacement matched nothing")
        result, result_text = self.run_bump(drifted, "")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result_text, drifted, "file must be untouched when aborting")

    def test_marketing_drift_aborts_on_version(self) -> None:
        current_version = self.versions(self.original)[0]
        major, minor, patch = current_version.split(".")
        drifted_version = f"{major}.{int(minor) + 2}.{patch}"
        drifted = self.original.replace(
            f"MARKETING_VERSION = {current_version};",
            f"MARKETING_VERSION = {drifted_version};",
            1,
        )
        self.assertNotEqual(drifted, self.original, "drift replacement matched nothing")
        result, _ = self.run_bump(drifted, "minor")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
