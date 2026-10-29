"""Exercise test routing, build reuse, and failure reporting with stub tools."""

from __future__ import annotations

import json
import re
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent / "test.sh"


def shell_function(name: str) -> str:
    text = SCRIPT.read_text()
    start = text.index(f"{name}() {{")
    return text[start:text.index("\n}\n", start) + 3]


def run_shell(
    functions: tuple[str, ...], body: str, *, setup: str = "", root: Path = SCRIPT.parent.parent
) -> subprocess.CompletedProcess[str]:
    text = SCRIPT.read_text()
    globals_start = text.index("FAILURES=()")
    globals_end = text.index("\n# Run a named command", globals_start)
    harness = "\n".join([
        "set -uo pipefail",
        f"ROOT={shlex.quote(str(root))}",
        text[globals_start:globals_end],
        'trace() { printf "CALL"; printf "\\t%s" "$@"; printf "\\n"; }',
        *(shell_function(name) for name in functions),
        setup,
        body,
        'if [[ ${#FAILURES[@]} -gt 0 ]]; then '
        'for failure in "${FAILURES[@]}"; do printf "FAILURE\\t%s\\n" "$failure"; done; fi',
    ])
    return subprocess.run(
        ["/bin/bash", "-c", harness], cwd=root, capture_output=True, text=True, check=False
    )


def tool_calls(result: subprocess.CompletedProcess[str], tool: str) -> list[list[str]]:
    return [
        line.split("\t")[2:]
        for line in result.stdout.splitlines()
        if line.startswith(f"CALL\t{tool}\t")
    ]


def failures(result: subprocess.CompletedProcess[str]) -> list[str]:
    return [
        line.split("\t", 1)[1]
        for line in result.stdout.splitlines()
        if line.startswith("FAILURE\t")
    ]


class TestRunnerTests(unittest.TestCase):
    def run_targets(
        self, *arguments: str, failing: str | None = None, recorded_failure: str | None = None
    ) -> subprocess.CompletedProcess[str]:
        text = SCRIPT.read_text()
        start = text.index("run_step() {")
        runner = text[start:]
        runner = runner.replace('PARALLEL_PROGRESS="$TEST_PARALLEL"', 'PARALLEL_PROGRESS=0')
        stubs = []
        for target in ("api", "web", "infra", "firebase", "linux", "ios", "macos"):
            outcome = "return 1" if target == failing else "return 0"
            if target == recorded_failure:
                outcome = f'FAILURES+=("{target} check"); return 0'
            stubs.append(
                f'test_{target}() {{ echo "CALLED: {target} signed=$APPLE_SIGNED"; {outcome}; }}'
            )
        with tempfile.TemporaryDirectory() as directory:
            harness = "\n".join([
                "set -uo pipefail", "FAILURES=()", "APPLE_SIGNED=0", "TEST_PARALLEL=1",
                f"ROOT={shlex.quote(directory)}",
                'ensure_api_python_tools() { echo "SETUP: python"; return 0; }',
                "apple_wireguard_tests() { return 0; }",
                "apple_kit_tests() { return 0; }",
                "apple_firebase_tests() { return 0; }",
                "apple_macos_core_tests() { return 0; }",
                *stubs, runner,
            ])
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
        self.assertEqual(self.called(result), ["api", "web", "infra", "firebase", "linux", "ios", "macos"])
        self.assertIn("All checks passed.", result.stdout)

    def test_apple_runs_both_platforms(self):
        result = self.run_targets("apple")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.called(result), ["ios", "macos"])

    def test_shared_python_setup_finishes_once_before_workers_start(self):
        result = self.run_targets("api", "infra", "firebase")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("SETUP: python"), 1)
        self.assertLess(result.stdout.index("SETUP: python"), result.stdout.index("Starting:"))
        self.assertNotIn("SETUP: python", self.run_targets("apple").stdout)

    def test_firebase_waits_for_short_checks_even_when_requested_first(self):
        result = self.run_targets("firebase", "api", "web", "infra")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.called(result), ["api", "web", "infra", "firebase"])

    def test_platform_targets_run_independently(self):
        for target in ("ios", "macos", "linux"):
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
        targets = ["api", "web", "infra", "firebase", "linux", "ios", "macos"]
        for target in targets:
            with self.subTest(target=target):
                result = self.run_targets(failing=target)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(self.called(result), targets)
                self.assertNotIn("All checks passed.", result.stdout)

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


class ParallelRunnerTests(unittest.TestCase):
    def run_workers(self, setup: str, *, serial: bool = False) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            return run_shell(
                ("run_check", "run_step", "run_parallel"),
                'run_parallel first second; echo "RESULT: $?"',
                setup=f'TEST_RUN_DIR="$ROOT"\nTEST_PARALLEL={int(not serial)}\n' + setup,
                root=Path(directory),
            )

    def test_workers_overlap_with_separate_working_directories(self):
        result = self.run_workers(textwrap.dedent('''\
            rendezvous() {
              mkdir -p "$ROOT/$1"
              cd "$ROOT/$1" || return 1
              touch "$ROOT/$1.started"
              python3 -c 'import pathlib,sys,time
            marker = pathlib.Path(sys.argv[1])
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            sys.exit(0 if marker.exists() else 1)' "$ROOT/$2.started" || return 1
              echo "CWD: $PWD"
            }
            first() { rendezvous one two; }
            second() { rendezvous two one; }
        '''))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RESULT: 0", result.stdout)
        self.assertRegex(result.stdout, r"CWD: .*/one")
        self.assertRegex(result.stdout, r"CWD: .*/two")
        self.assertEqual(failures(result), [])

    def test_worker_failure_is_collected_even_when_callback_returns_success(self):
        result = self.run_workers('''
            first() { run_check "early failure" false; run_check "later check" true; }
            second() { run_check "sibling check" true; }
        ''')
        self.assertIn("RESULT: 1", result.stdout)
        self.assertIn("OK: later check", result.stdout)
        self.assertIn("OK: sibling check", result.stdout)
        self.assertEqual(failures(result), ["early failure"])

    def test_abrupt_worker_exit_still_waits_for_sibling_and_fails(self):
        result = self.run_workers('''
            first() { exit 23; }
            second() { run_check "sibling check" true; }
        ''')
        self.assertIn("RESULT: 1", result.stdout)
        self.assertIn("OK: sibling check", result.stdout)
        self.assertEqual(failures(result), ["first"])

    def test_serial_mode_preserves_failures_and_runs_later_workers(self):
        result = self.run_workers('''
            first() { run_check "early failure" false; return 0; }
            second() { run_check "sibling check" true; }
        ''', serial=True)
        self.assertIn("RESULT: 1", result.stdout)
        self.assertIn("OK: sibling check", result.stdout)
        self.assertEqual(failures(result), ["early failure"])

    def test_serial_workers_start_from_the_same_directory(self):
        result = self.run_workers('''
            first() { mkdir "$ROOT/one"; cd "$ROOT/one"; }
            second() { run_check "initial directory" test "$PWD" -ef "$ROOT"; }
        ''', serial=True)
        self.assertIn("RESULT: 0", result.stdout)
        self.assertEqual(failures(result), [])


class AppleRunnerTests(unittest.TestCase):
    def run_apple(
        self,
        body: str = 'status=0; test_apple_targets || status=$?; echo "RESULT: $status"',
        *,
        targets: tuple[str, ...] = ("ios", "macos"),
        periphery_failure: str = "",
        swift_failure: str = "",
        missing_periphery: bool = False,
        fail_wireguard: bool = False,
        signed: bool = False,
        signing_failure: str = "",
        xcode_failure: str = "",
        serial: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        setup = "\n".join([
            f"APPLE_TARGETS=({' '.join(shlex.quote(target) for target in targets)})",
            f"APPLE_SIGNED={int(signed)}",
            f"TEST_PARALLEL={int(not serial)}",
            f"PERIPHERY_FAILURE={shlex.quote(periphery_failure)}",
            f"SWIFT_FAILURE={shlex.quote(swift_failure)}",
            f"MISSING_PERIPHERY={int(missing_periphery)}",
            f"FAIL_WIREGUARD={int(fail_wireguard)}",
            f"SIGNING_FAILURE={shlex.quote(signing_failure)}",
            f"XCODE_FAILURE={shlex.quote(xcode_failure)}",
            textwrap.dedent('''\
                command() {
                  if [[ "$*" == '-v periphery' && "$MISSING_PERIPHERY" -eq 1 ]]; then
                    return 1
                  fi
                  builtin command "$@"
                }
                periphery() {
                  trace periphery "$@"
                  if [[ -n "$PERIPHERY_FAILURE" && "$*" == *"$PERIPHERY_FAILURE"* ]]; then
                    return 1
                  fi
                  local previous="" argument
                  for argument in "$@"; do
                    if [[ "$previous" == --project-root ]]; then
                      touch "$TEST_RUN_DIR/${argument##*/}.scanned"
                    fi
                    previous="$argument"
                  done
                }
                swift() {
                  trace swift "$@"
                  if [[ "$*" == *--skip-build* ]]; then
                    [[ -f "$TEST_RUN_DIR/${3##*/}.scanned" ]] || return 99
                  fi
                  if [[ -n "$SWIFT_FAILURE" && "$*" == *"$SWIFT_FAILURE"* ]]; then
                    return 1
                  fi
                }
                make() { trace make "$@"; return "$FAIL_WIREGUARD"; }
                bash() { trace bash "$@"; }
                python3() { trace python3 "$@"; }
                xcodebuild() {
                  trace xcodebuild "$@"
                  if [[ -n "$XCODE_FAILURE" && "$*" == *"$XCODE_FAILURE"* && "$*" == *' build' ]]; then
                    return 1
                  fi
                }
                check_apple_signing_prerequisites() {
                  trace signing ios
                  [[ "$SIGNING_FAILURE" != ios ]]
                }
                check_macos_signing_prerequisites() {
                  trace signing macos
                  [[ "$SIGNING_FAILURE" != macos ]]
                }
            '''),
        ])
        with tempfile.TemporaryDirectory() as directory:
            return run_shell(
                (
                    "run_check", "run_step", "run_parallel", "scan_apple_dead_code",
                    "scan_macos_dead_code", "run_apple_package_tests", "test_apple_package",
                    "apple_wireguard_tests", "apple_kit_tests", "apple_firebase_tests",
                    "apple_macos_core_tests", "test_ios", "test_macos",
                    "test_apple_projects", "test_apple_targets",
                ),
                body,
                setup=f"TEST_RUN_DIR={shlex.quote(directory)}\n" + setup,
            )

    def assert_package_tests(
        self, result: subprocess.CompletedProcess[str], skipped: tuple[bool, ...]
    ) -> None:
        packages = (
            "Frontend/Apple/CloudGatewayKit",
            "Frontend/Apple/CloudGatewayFirebaseAdapter",
            "Frontend/Apple/macOS/CloudGatewayMacCore",
        )
        expected = []
        for package, skip_build in zip(packages, skipped):
            args = ["test", "--package-path", package, "--build-system", "native"]
            if package.endswith("CloudGatewayMacCore"):
                args.extend(["--experimental-maximum-parallelization-width", "8"])
            if skip_build:
                args.append("--skip-build")
            expected.append(args)
        self.assertCountEqual(tool_calls(result, "swift"), expected)

    def test_successful_scans_supply_only_the_matching_package_builds(self):
        result = self.run_apple()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_package_tests(result, (True, True, True))
        self.assertEqual(len(tool_calls(result, "make")), 1)
        self.assertEqual(failures(result), [])
        self.assertIn("RESULT: 0", result.stdout)

    def test_macos_alone_builds_shared_packages_and_reuses_its_own_scan(self):
        result = self.run_apple(targets=("macos",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_package_tests(result, (False, False, True))
        self.assertEqual(len(tool_calls(result, "periphery")), 2)
        self.assertTrue(all(
            "--project-root" not in scan or "CloudGatewayMacCore" in " ".join(scan)
            for scan in tool_calls(result, "periphery")
        ))
        self.assertTrue(all("/iOS/" not in " ".join(call) for call in tool_calls(result, "xcodebuild")))
        self.assertEqual(failures(result), [])
        self.assertIn("RESULT: 0", result.stdout)

    def test_ios_alone_omits_macos_core_and_project(self):
        result = self.run_apple(targets=("ios",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_package_tests(result, (True, True))
        self.assertEqual(len(tool_calls(result, "periphery")), 3)
        self.assertTrue(all("/macOS/" not in " ".join(call) for call in tool_calls(result, "xcodebuild")))
        self.assertEqual(failures(result), [])
        self.assertIn("RESULT: 0", result.stdout)

    def test_failed_package_scan_builds_that_package_and_runs_all_other_tests(self):
        scans = (
            ("CloudGatewayKit", "Apple dead code: Kit tests", (False, True, True)),
            ("CloudGatewayFirebaseAdapter", "Apple dead code: Firebase adapter tests", (True, False, True)),
            ("CloudGatewayMacCore", "macOS dead code: host-free tests", (True, True, False)),
        )
        for package, name, skipped in scans:
            with self.subTest(package=package):
                result = self.run_apple(periphery_failure=package)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_package_tests(result, skipped)
                self.assertEqual(len(tool_calls(result, "periphery")), 5)
                self.assertEqual(failures(result), [name])
                self.assertIn("RESULT: 1", result.stdout)
                self.assertEqual(len([call for call in tool_calls(result, "xcodebuild") if call[-1] == "build"]), 2)

    def test_missing_periphery_builds_and_runs_all_packages(self):
        result = self.run_apple(missing_periphery=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_package_tests(result, (False, False, False))
        self.assertEqual(tool_calls(result, "periphery"), [])
        self.assertIn("skipping Apple dead-code scans", result.stdout)
        self.assertIn("skipping macOS dead-code scans", result.stdout)
        self.assertEqual(failures(result), [])
        self.assertIn("RESULT: 0", result.stdout)

    def test_all_failed_scans_still_build_and_run_every_package(self):
        result = self.run_apple(periphery_failure="--strict")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_package_tests(result, (False, False, False))
        self.assertEqual(len(tool_calls(result, "periphery")), 5)
        self.assertCountEqual(failures(result), [
            "Apple dead code: app project", "Apple dead code: Kit tests",
            "Apple dead code: Firebase adapter tests", "macOS dead code: app and extension",
            "macOS dead code: host-free tests",
        ])
        self.assertIn("RESULT: 1", result.stdout)
        self.assertEqual(len([call for call in tool_calls(result, "xcodebuild") if call[-1] == "build"]), 2)

    def test_strict_scan_and_swift_failures_remain_recorded(self):
        result = self.run_apple(
            periphery_failure="/iOS/CloudGateway.xcodeproj", swift_failure="CloudGatewayKit"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_package_tests(result, (True, True, True))
        self.assertCountEqual(failures(result), [
            "Apple dead code: app project", "Apple Kit and AppCore package tests",
        ])
        self.assertIn("RESULT: 1", result.stdout)
        self.assertEqual(len([call for call in tool_calls(result, "xcodebuild") if call[-1] == "build"]), 2)

    def test_production_scan_arguments_and_configs_are_unchanged(self):
        result = self.run_apple()
        self.assertEqual(result.returncode, 0, result.stderr)
        scans = tool_calls(result, "periphery")
        root = SCRIPT.parent.parent
        self.assertEqual(len(scans), 5)
        expected = [[
            "scan", "--quiet", "--strict",
            "--config", str(root / "Frontend/Apple/.periphery.yml"),
            "--project", str(root / "Frontend/Apple/iOS/CloudGateway.xcodeproj"),
            "--schemes", "CloudGateway", "--schemes", "CloudGatewayScreenshots",
            "--report-exclude", "**/wireguard-apple/**",
        ], [
            "scan", "--quiet", "--strict",
            "--config", str(root / "Frontend/Apple/macOS/.periphery.yml"),
            "--project", str(root / "Frontend/Apple/macOS/CloudGateway.xcodeproj"),
            "--schemes", "CloudGateway", "--schemes", "CloudGatewayTunnel",
            "--report-include", "**/macOS/**",
            "--report-include", "**/CloudGatewayDeviceAuthClient.swift",
            "--report-include", "**/CloudGatewayCustomTokenAuthServicing.swift",
            "--report-include", "**/CloudGatewayFirebaseCustomTokenSession.swift",
        ]]
        for package, config in (
            ("Frontend/Apple/CloudGatewayKit", "Frontend/Apple/.periphery.yml"),
            ("Frontend/Apple/CloudGatewayFirebaseAdapter", "Frontend/Apple/.periphery.yml"),
            ("Frontend/Apple/macOS/CloudGatewayMacCore", "Frontend/Apple/macOS/.periphery.yml"),
        ):
            expected.append([
                "scan", "--quiet", "--strict", "--config", str(root / config),
                "--project-root", str(root / package), "--report-include", "**/Tests/**",
                "--", "--build-system", "native",
            ])
        self.assertCountEqual(scans, expected)

    def test_package_scans_precede_their_matching_tests(self):
        for serial in (False, True):
            for periphery_failure in ("", "--strict"):
                with self.subTest(serial=serial, periphery_failure=periphery_failure):
                    result = self.run_apple(serial=serial, periphery_failure=periphery_failure)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assert_package_tests(result, (not periphery_failure,) * 3)
                    self.assertEqual(len(failures(result)), 5 if periphery_failure else 0)
                    calls = [
                        line.split("\t")[1:]
                        for line in result.stdout.splitlines() if line.startswith("CALL\t")
                    ]
                    for package in (
                        "Frontend/Apple/CloudGatewayKit",
                        "Frontend/Apple/CloudGatewayFirebaseAdapter",
                        "Frontend/Apple/macOS/CloudGatewayMacCore",
                    ):
                        scan = next(
                            index for index, call in enumerate(calls)
                            if call[0] == "periphery" and str(SCRIPT.parent.parent / package) in call
                        )
                        test = next(
                            index for index, call in enumerate(calls)
                            if call[0] == "swift" and package in call
                        )
                        self.assertLess(scan, test, package)

    def test_shared_packages_run_once_for_both_platforms(self):
        for targets in (("ios", "macos"), ("macos", "ios")):
            for serial in (False, True):
                with self.subTest(targets=targets, serial=serial):
                    result = self.run_apple(targets=targets, serial=serial)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(tool_calls(result, "make"), [["-C", "Frontend/Apple/wireguard-apple", "test"]])
                    self.assert_package_tests(result, (True, True, True))
                    self.assertEqual(len(tool_calls(result, "periphery")), 5)
                    self.assertEqual(failures(result), [])
                    self.assertIn("RESULT: 0", result.stdout)

    def test_shared_failure_does_not_skip_other_packages_or_platforms(self):
        result = self.run_apple(swift_failure="CloudGatewayKit")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(tool_calls(result, "make")), 1)
        self.assert_package_tests(result, (True, True, True))
        self.assertEqual(len([call for call in tool_calls(result, "xcodebuild") if call[-1] == "build"]), 2)
        self.assertIn("RESULT: 1", result.stdout)
        self.assertEqual(failures(result), ["Apple Kit and AppCore package tests"])

    def test_wireguard_failure_does_not_skip_packages_or_platforms(self):
        result = self.run_apple(fail_wireguard=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(tool_calls(result, "make")), 1)
        self.assert_package_tests(result, (True, True, True))
        self.assertEqual(len([call for call in tool_calls(result, "xcodebuild") if call[-1] == "build"]), 2)
        self.assertIn("RESULT: 1", result.stdout)
        self.assertEqual(failures(result), ["Apple WireGuard startup regressions"])

    def test_each_platform_scan_precedes_its_project_build(self):
        result = self.run_apple()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [
            line.split("\t")[1:]
            for line in result.stdout.splitlines() if line.startswith("CALL\t")
        ]
        for project in (
            "Frontend/Apple/iOS/CloudGateway.xcodeproj",
            "Frontend/Apple/macOS/CloudGateway.xcodeproj",
        ):
            with self.subTest(project=project):
                scan = next(
                    index for index, call in enumerate(calls)
                    if call[0] == "periphery" and str(SCRIPT.parent.parent / project) in call
                )
                build = next(
                    index for index, call in enumerate(calls)
                    if call[0] == "xcodebuild" and project in call and call[-1] == "build"
                )
                self.assertLess(scan, build)

    def test_signed_and_unsigned_builds_keep_platform_signing_options(self):
        for signed in (False, True):
            with self.subTest(signed=signed):
                result = self.run_apple(signed=signed)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(failures(result), [])
                self.assertIn("RESULT: 0", result.stdout)
                builds = [call for call in tool_calls(result, "xcodebuild") if call[-1] == "build"]
                configuration = "Release" if signed else "Debug"
                signing = ["-allowProvisioningUpdates"] if signed else ["CODE_SIGNING_ALLOWED=NO"]
                derived_data = SCRIPT.parent.parent / "Frontend/Apple/macOS/.build/Xcode"
                self.assertCountEqual(builds, [
                    [
                        "-project", "Frontend/Apple/iOS/CloudGateway.xcodeproj",
                        "-scheme", "CloudGateway", "-configuration", configuration,
                        "-destination", "generic/platform=iOS", *signing, "build",
                    ],
                    [
                        "-project", "Frontend/Apple/macOS/CloudGateway.xcodeproj",
                        "-scheme", "CloudGateway", "-configuration", configuration,
                        "-destination", "platform=macOS,arch=arm64" if signed else "generic/platform=macOS",
                        "-derivedDataPath", str(derived_data), "ARCHS=arm64", *signing, "build",
                    ],
                ])
                self.assertCountEqual(tool_calls(result, "signing"), [["ios"], ["macos"]] if signed else [])
                verifications = [call for call in tool_calls(result, "python3")
                                 if call[0] == "scripts/verify_macos_build.py"]
                self.assertEqual(verifications, [[
                    "scripts/verify_macos_build.py",
                    str(derived_data / f"Build/Products/{configuration}/CloudGateway.app"),
                    *(["--signed"] if signed else []), "--cli-smoke",
                ]])

    def test_signing_failure_skips_only_that_platform_build(self):
        for platform, name in (
            ("ios", "Apple signing prerequisites"),
            ("macos", "macOS signing prerequisites"),
        ):
            with self.subTest(platform=platform):
                result = self.run_apple(signed=True, signing_failure=platform)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(failures(result), [name])
                self.assert_package_tests(result, (True, True, True))
                builds = [call for call in tool_calls(result, "xcodebuild") if call[-1] == "build"]
                other = "macOS" if platform == "ios" else "iOS"
                self.assertEqual(len(builds), 1)
                self.assertIn(f"Frontend/Apple/{other}/CloudGateway.xcodeproj", builds[0])
                self.assertIn("RESULT: 1", result.stdout)

    def test_project_build_failure_does_not_skip_other_platform(self):
        for platform, name in (
            ("iOS", "Apple unsigned no-device iOS build"),
            ("macOS", "macOS Debug arm64 app and system extension build"),
        ):
            with self.subTest(platform=platform):
                result = self.run_apple(xcode_failure=f"/{platform}/")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(failures(result), [name])
                self.assert_package_tests(result, (True, True, True))
                self.assertEqual(len([call for call in tool_calls(result, "xcodebuild") if call[-1] == "build"]), 2)
                self.assertIn("RESULT: 1", result.stdout)
                verifications = [call for call in tool_calls(result, "python3")
                                 if call[0] == "scripts/verify_macos_build.py"]
                self.assertEqual(len(verifications), int(platform == "iOS"))


class APIPythonToolsTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.api = self.root / "Backend/API"
        self.venv = self.api / ".venv"
        (self.venv / "bin").mkdir(parents=True)
        (self.api / "src").mkdir()
        (self.api / "pyproject.toml").write_text('[project]\nname = "cloudgateway-api"\n')
        (self.venv / "pyvenv.cfg").write_text("home = /stub/python\n")
        self.state = self.venv / "state.json"
        self.state.write_text(json.dumps({
            "version": "stub Python 3.13",
            "packages": [{"name": "pip", "version": "1", "direct_url": ""}],
        }))
        self.stamp = self.venv / ".test-tools-fingerprint"
        self.sync_log = self.venv / "sync.log"
        python = self.venv / "bin/python"
        python.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
            import importlib.metadata
            import json
            import sys
            from pathlib import Path
            from types import SimpleNamespace

            state_file = Path('.venv/state.json')
            state = json.loads(state_file.read_text())
            sync_log = Path('.venv/sync.log')
            if sys.argv[1:] == ['-']:
                if state.get('fail_fingerprint') or (
                    state.get('fail_after_sync') and sync_log.exists()
                ):
                    raise SystemExit(9)
                # Run the real fingerprint body against a controlled venv
                sys.prefix = str(Path('.venv').resolve())
                sys.executable = str(Path(__file__).resolve())
                sys.version = state['version']
                installed_packages = state['packages']
                importlib.metadata.distributions = lambda: [
                    SimpleNamespace(
                        metadata={'Name': package['name']},
                        version=package['version'],
                        read_text=lambda name, package=package: package['direct_url'],
                    )
                    for package in installed_packages
                ]
                exec(compile(sys.stdin.read(), '<api fingerprint>', 'exec'))
            elif sys.argv[1:] == ['-m', 'pip', 'install', '--quiet', '-e', '.[dev]']:
                with sync_log.open('a') as log:
                    log.write('sync\\n')
                if Path('.venv/fail-sync').exists():
                    raise SystemExit(1)
                for tool in ('pyright', 'vulture'):
                    path = Path('.venv/bin') / tool
                    path.write_text('#!/bin/bash\\nexit 0\\n')
                    path.chmod(0o755)
                if not any(package['name'] == 'test-tools' for package in state['packages']):
                    state['packages'].append({
                        'name': 'test-tools', 'version': '1', 'direct_url': '',
                    })
                    state_file.write_text(json.dumps(state))
            else:
                raise SystemExit('Unexpected Python arguments: ' + repr(sys.argv[1:]))
        '''))
        python.chmod(0o755)

    def ensure_tools(self, *, twice: bool = False) -> subprocess.CompletedProcess[str]:
        body = 'status=0; ensure_api_python_tools || status=$?; echo "RESULT: $status READY: $API_PYTHON_TOOLS_READY"'
        if twice:
            body += '\nensure_api_python_tools || echo "SECOND FAILED"'
        return run_shell(
            ("run_check", "api_python_tools_fingerprint", "ensure_api_python_tools"),
            body,
            root=self.root,
        )

    def sync_count(self) -> int:
        return len(self.sync_log.read_text().splitlines()) if self.sync_log.exists() else 0

    def assert_ready(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RESULT: 0 READY: 1", result.stdout)
        self.assertEqual(failures(result), [])

    def test_successful_fingerprint_is_reused_in_fresh_shells(self):
        self.assert_ready(self.ensure_tools(twice=True))
        self.assertEqual(self.sync_count(), 1)
        stamp = self.stamp.read_text()
        self.assertRegex(stamp, r"^[0-9a-f]{64}\n$")
        self.assert_ready(self.ensure_tools())
        self.assertEqual(self.sync_count(), 1)
        self.assertEqual(self.stamp.read_text(), stamp)

    def test_dependency_and_environment_changes_force_sync(self):
        self.assert_ready(self.ensure_tools())
        for change in ("pyproject", "venv config", "Python version", "package version", "direct URL"):
            with self.subTest(change=change):
                before = self.sync_count()
                old_stamp = self.stamp.read_text()
                if change == "pyproject":
                    with (self.api / "pyproject.toml").open("a") as project:
                        project.write('requires-python = ">=3.13"\n')
                elif change == "venv config":
                    (self.venv / "pyvenv.cfg").write_text("home = /other/python\n")
                else:
                    state = json.loads(self.state.read_text())
                    if change == "Python version":
                        state["version"] = "stub Python 3.14"
                    elif change == "package version":
                        state["packages"][0]["version"] = "2"
                    else:
                        state["packages"][0]["direct_url"] = '{"url": "file:///changed"}'
                    self.state.write_text(json.dumps(state))
                self.assert_ready(self.ensure_tools())
                self.assertEqual(self.sync_count(), before + 1)
                self.assertNotEqual(self.stamp.read_text(), old_stamp)
                self.assert_ready(self.ensure_tools())
                self.assertEqual(self.sync_count(), before + 1)

    def test_missing_or_nonexecutable_tools_force_sync(self):
        self.assert_ready(self.ensure_tools())
        for tool in ("pyright", "vulture"):
            for missing in (True, False):
                with self.subTest(tool=tool, missing=missing):
                    before = self.sync_count()
                    path = self.venv / "bin" / tool
                    if missing:
                        path.rename(path.with_suffix(".disabled"))
                    else:
                        path.chmod(0o644)
                    self.assert_ready(self.ensure_tools())
                    self.assertEqual(self.sync_count(), before + 1)
                    self.assert_ready(self.ensure_tools())
                    self.assertEqual(self.sync_count(), before + 1)

    def test_source_edits_do_not_sync_dependencies(self):
        self.assert_ready(self.ensure_tools())
        stamp = self.stamp.read_text()
        (self.api / "src/main.py").write_text('print("source change")\n')
        self.assert_ready(self.ensure_tools())
        self.assertEqual(self.sync_count(), 1)
        self.assertEqual(self.stamp.read_text(), stamp)

    def test_failed_sync_invalidates_old_stamp_and_later_retries(self):
        self.assert_ready(self.ensure_tools())
        project = self.api / "pyproject.toml"
        original = project.read_text()
        project.write_text(original + 'requires-python = ">=3.13"\n')
        marker = self.venv / "fail-sync"
        marker.touch()
        result = self.ensure_tools()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RESULT: 1 READY: 0", result.stdout)
        self.assertEqual(failures(result), ["API dependency sync"])
        self.assertEqual(self.stamp.read_text().strip(), "")
        self.assertEqual(self.sync_count(), 2)
        project.write_text(original)
        marker.rename(marker.with_suffix(".disabled"))
        self.assert_ready(self.ensure_tools())
        self.assertEqual(self.sync_count(), 3)
        self.assert_ready(self.ensure_tools())
        self.assertEqual(self.sync_count(), 3)

    def test_fingerprint_failure_records_failure_without_readiness(self):
        for after_sync in (False, True):
            with self.subTest(after_sync=after_sync):
                state = json.loads(self.state.read_text())
                state["fail_fingerprint"] = not after_sync
                state["fail_after_sync"] = after_sync
                self.state.write_text(json.dumps(state))
                result = self.ensure_tools()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("RESULT: 1 READY: 0", result.stdout)
                label = "API dependency cache" if after_sync else "API dependency state"
                self.assertEqual(failures(result), [label])
                self.assertEqual(self.sync_count(), int(after_sync))
                if after_sync:
                    self.assertEqual(self.stamp.read_text().strip(), "")
                else:
                    self.assertFalse(self.stamp.exists())
        state["fail_after_sync"] = False
        self.state.write_text(json.dumps(state))
        self.assert_ready(self.ensure_tools())
        self.assertEqual(self.sync_count(), 2)


class InfraRunnerTests(unittest.TestCase):
    def test_grouped_pyright_checks_all_six_inputs_and_failure_preserves_other_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            terraform = root / "Infrastructure/OCI/terraform"
            (terraform / ".terraform").mkdir(parents=True)
            (terraform / ".terraform.lock.hcl").touch()
            (terraform / "fixture.tftpl").touch()
            host = root / "Infrastructure/OCI/host"
            host.mkdir()
            (host / "fixture.sh").touch()
            (root / "scripts").mkdir()
            (root / "scripts/fixture.sh").touch()
            pyright = root / "Backend/API/.venv/bin/pyright"
            pyright.parent.mkdir(parents=True)
            pyright.write_text(
                '#!/bin/bash\nprintf "CALL\\tpyright"\nprintf "\\t%s" "$@"\nprintf "\\n"\nexit 1\n'
            )
            pyright.chmod(0o755)
            result = run_shell(
                ("run_check", "run_pyright", "infra_validation", "test_infra", "run_step", "run_parallel"),
                'status=0; run_step "Infra validation" test_infra || status=$?; echo "RESULT: $status"',
                setup=textwrap.dedent('''\
                    TEST_RUN_DIR="$ROOT"
                    ensure_api_python_tools() { return 0; }
                    python3() { trace python3 "$@"; }
                    terraform() { trace terraform "$@"; }
                    bash() { trace bash "$@"; }
                    grep() { trace grep "$@"; }
                    sh() { trace sh "$@"; }
                '''),
                root=root,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(tool_calls(result, "pyright"), [[
            "--project", "pyrightconfig.json",
            "scripts/terraform-preflight.py", "scripts/test_terraform_preflight.py",
            "scripts/test_terraform_wrapper.py", "scripts/backup_firestore.py",
            "scripts/test_backup_firestore.py", "scripts/test_ios_release.py",
        ]])
        self.assertEqual(failures(result), ["Infra tools pyright"])
        self.assertIn("RESULT: 1", result.stdout)
        self.assertEqual(tool_calls(result, "terraform"), [
            ["-chdir=Infrastructure/OCI/terraform", "fmt", "-check"],
            ["-chdir=Infrastructure/OCI/terraform", "validate"],
        ])
        self.assertEqual(tool_calls(result, "bash"), [
            ["-n", "Infrastructure/OCI/host/fixture.sh"],
            ["-n", "scripts/fixture.sh"],
            ["-n", "Infrastructure/OCI/terraform/fixture.tftpl"],
        ])
        self.assertEqual(tool_calls(result, "python3"), [
            ["-m", "unittest", "scripts/test_test_runner.py"],
            ["-m", "py_compile", "scripts/terraform-preflight.py"],
            ["-m", "unittest", "scripts/test_terraform_preflight.py"],
            ["-m", "py_compile", "scripts/test_terraform_wrapper.py"],
            ["-m", "unittest", "scripts/test_terraform_wrapper.py"],
            ["-m", "py_compile", "scripts/backup_firestore.py", "scripts/test_backup_firestore.py"],
            ["-m", "unittest", "scripts/test_backup_firestore.py"],
            ["-m", "py_compile", "scripts/test_ios_release.py"],
            ["-m", "unittest", "scripts/test_ios_release.py"],
        ])


if __name__ == "__main__":
    unittest.main()
