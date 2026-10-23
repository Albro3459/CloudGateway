import copy
import datetime
import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import call, patch

from scripts import verify_macos_build as verifier


class MacOSCLIVerificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "CloudGateway.app"
        self.binary = self.app / "Contents/MacOS/CloudGateway"
        self.binary.parent.mkdir(parents=True)
        self.binary.touch(mode=0o755)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "CloudGateway", "CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "7",
        }))
        resources = self.app / "Contents/Resources"
        resources.mkdir()
        (resources / "GoogleService-Info.plist").write_bytes(plistlib.dumps({"fixture": True}))
        self.homes = set()

    def static_result(self, arguments: list[str], **options) -> subprocess.CompletedProcess:
        self.assertEqual(options["timeout"], 5)
        self.assertEqual(options["stdin"], subprocess.DEVNULL)
        self.assertFalse(options["check"])
        self.assertTrue(options["capture_output"])
        home = Path(options["env"]["HOME"])
        self.homes.add(home)
        self.assertTrue(home.is_dir())
        self.assertEqual(options["env"]["CFFIXED_USER_HOME"], str(home))
        self.assertEqual(options["env"]["TERM"], "dumb")
        invocation = Path(arguments[0])
        if invocation.name == "cloudgateway":
            self.assertTrue(invocation.is_symlink())
            self.assertEqual(invocation.resolve(), self.binary.resolve())
            flags = arguments[1:]
        else:
            self.assertEqual(invocation.resolve(), self.binary.resolve())
            self.assertEqual(arguments[1], "--cli")
            flags = arguments[2:]
        self.assertNotIn("--controller", flags)
        self.assertFalse(any(flag in flags for flag in ["up", "down", "refresh", "logout"]))
        invalid = any(flag in flags for flag in ["--unknown-option", "--unexpected", "0"])
        command = "auth login" if flags[:2] == ["auth", "login"] else "status" if flags[:1] == ["status"] else "version" if "--version" in flags else "help"
        if "--json" in flags:
            data = {"version": "1.2.0", "build": "7"} if command == "version" else {"usage": "cloudgateway help"}
            record = {"schemaVersion": 1, "type": "error" if invalid else "result", "command": command,
                      "operationId": None, "data": None if invalid else data,
                      "error": {"code": "usage"} if invalid else None}
            output, diagnostics = json.dumps(record).encode() + b"\n", b""
        else:
            output, diagnostics = (b"", b"Usage error\n") if invalid else (b"CloudGateway help/version\n", b"")
        return subprocess.CompletedProcess(arguments, 2 if invalid else 0, stdout=output, stderr=diagnostics)

    def test_static_direct_and_symlink_commands_use_temporary_homes_and_bounded_calls(self) -> None:
        with patch.object(verifier.subprocess, "run", side_effect=self.static_result) as run:
            verifier.verify_cli(self.app)
        self.assertEqual(run.call_count, 20)
        self.assertEqual(len(self.homes), 1)
        self.assertTrue(all(not home.exists() for home in self.homes))

    def test_resources_and_executable_are_required_before_launching(self) -> None:
        resource = self.app / "Contents/Resources/GoogleService-Info.plist"
        resource.rename(resource.with_suffix(".missing"))
        with patch.object(verifier.subprocess, "run") as run, self.assertRaisesRegex(ValueError, "resource missing"):
            verifier.verify_cli(self.app)
        run.assert_not_called()
        self.binary.chmod(0o644)
        with patch.object(verifier.subprocess, "run") as run, self.assertRaisesRegex(ValueError, "not executable"):
            verifier.verify_cli(self.app)
        run.assert_not_called()

    def test_timeout_is_reported_without_command_output(self) -> None:
        error = subprocess.TimeoutExpired("private subprocess details", 5, output=b"private output")
        with patch.object(verifier.subprocess, "run", side_effect=error), self.assertRaisesRegex(ValueError, "five-second deadline") as raised:
            verifier.verify_cli(self.app)
        self.assertNotIn("private", str(raised.exception))

    def test_invalid_json_version_and_terminal_output_are_rejected(self) -> None:
        for failure in ("json", "version", "escape", "newline", "usage", "operation"):
            def result(arguments: list[str], **options) -> subprocess.CompletedProcess:
                response = self.static_result(arguments, **options)
                if failure == "escape":
                    response.stdout += b"\x1b[31m"
                elif "--json" in arguments:
                    record = json.loads(response.stdout)
                    if failure == "json":
                        response.stdout = b"invalid\n"
                    elif failure == "newline":
                        response.stdout = response.stdout.rstrip(b"\n")
                    elif failure == "version" and record["command"] == "version":
                        record["data"]["build"] = "8"
                        response.stdout = json.dumps(record).encode() + b"\n"
                    elif failure == "usage" and response.returncode == 2:
                        record["error"] = None
                        response.stdout = json.dumps(record).encode() + b"\n"
                    elif failure == "operation":
                        record["operationId"] = "unexpected"
                        response.stdout = json.dumps(record).encode() + b"\n"
                return response

            with self.subTest(failure=failure), patch.object(verifier.subprocess, "run", side_effect=result), self.assertRaises(ValueError):
                verifier.verify_cli(self.app)

    def test_static_command_must_not_write_user_state(self) -> None:
        def result(arguments: list[str], **options) -> subprocess.CompletedProcess:
            response = self.static_result(arguments, **options)
            (Path(options["env"]["HOME"]) / "unexpected-state").touch()
            return response

        with patch.object(verifier.subprocess, "run", side_effect=result), self.assertRaisesRegex(ValueError, "user state"):
            verifier.verify_cli(self.app)

    def test_cli_flag_runs_static_checks_after_bundle_verification(self) -> None:
        with patch("sys.argv", ["verify_macos_build.py", str(self.app), "--cli-smoke"]), \
                patch.object(verifier, "verify_bundle") as bundle, patch.object(verifier, "verify_cli") as cli:
            verifier.main()
        bundle.assert_called_once_with(self.app, False, False)
        cli.assert_called_once_with(self.app)


class MacOSBuildVerificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.bundle = Path(self.temporary.name) / "Tunnel.systemextension"
        self.binary = self.bundle / "Contents" / "MacOS" / "Tunnel"
        self.binary.parent.mkdir(parents=True)
        self.binary.touch()
        self.now = datetime.datetime(2026, 10, 2, tzinfo=datetime.timezone.utc)
        self.profile = {
            "ExpirationDate": datetime.datetime(2027, 1, 1),
            "Entitlements": {
                "com.apple.developer.team-identifier": verifier.TEAM_ID,
                "com.apple.application-identifier": f"{verifier.TEAM_ID}.{verifier.APP_ID}",
                "com.apple.security.application-groups": [verifier.APP_GROUP],
                "com.apple.developer.networking.networkextension": ["packet-tunnel-provider"],
                "com.apple.developer.system-extension.install": True,
                "keychain-access-groups": [f"{verifier.TEAM_ID}.*"],
            },
        }

    def test_load_commands_and_dependency_header_parse(self) -> None:
        commands = "cmd LC_RPATH\ncmdsize 48\npath @executable_path/../Frameworks (offset 12)\n"
        self.assertEqual(verifier.parse_rpaths(commands), ["@executable_path/../Frameworks"])
        output = "/build/.build/Tunnel:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n"
        self.assertEqual(verifier.parse_dependencies(output), ["/usr/lib/libSystem.B.dylib"])

    def test_bundled_library_resolves_without_build_directory(self) -> None:
        framework = self.bundle / "Contents" / "Frameworks" / "Support.dylib"
        framework.parent.mkdir()
        framework.touch()
        actual = verifier.verify_dynamic_paths(
            self.binary, self.bundle, self.binary,
            ["@rpath/Support.dylib", "/usr/lib/libSystem.B.dylib"],
            ["@executable_path/../Frameworks"],
        )
        self.assertEqual(actual, [framework.resolve()])

    def test_build_absolute_and_ancestor_app_rpaths_are_rejected(self) -> None:
        for value in [
            "/tmp/DerivedData/Build/Products/Release/PackageFrameworks",
            "/tmp/.build/PackageFrameworks", "/Applications/Other.app/Contents/Frameworks",
            "@executable_path/../../../../../../Frameworks",
        ]:
            with self.subTest(rpath=value), self.assertRaises(ValueError):
                verifier.verify_dynamic_paths(self.binary, self.bundle, self.binary, ["@rpath/Missing.dylib"], [value])

    def test_xcode_package_build_search_is_ignored_only_without_dynamic_consumers(self) -> None:
        for configuration in ("Debug", "Release", "DeveloperID"):
            rpath = f"/tmp/.build/Xcode/Build/Products/{configuration}/PackageFrameworks"
            with self.subTest(configuration=configuration):
                actual = verifier.verify_dynamic_paths(self.binary, self.bundle, self.binary,
                                                      ["/usr/lib/libSystem.B.dylib"], [rpath])
                self.assertEqual(actual, [])
                with self.assertRaises(ValueError):
                    verifier.verify_dynamic_paths(self.binary, self.bundle, self.binary,
                                                  ["@rpath/Support.dylib"], [rpath])

    def test_missing_and_absolute_non_system_dependencies_are_rejected(self) -> None:
        for dependency in ["@rpath/Missing.dylib", "/usr/local/lib/External.dylib"]:
            with self.subTest(dependency=dependency), self.assertRaises(ValueError):
                verifier.verify_dynamic_paths(self.binary, self.bundle, self.binary,
                                              [dependency], ["@executable_path/../Frameworks"])

    def test_valid_profile_allows_exact_or_team_wildcard_keychain_group(self) -> None:
        verifier.verify_profile(self.profile, verifier.APP_ID, False, self.now)
        self.profile["Entitlements"]["keychain-access-groups"] = [f"{verifier.TEAM_ID}.{verifier.APP_ID}"]
        verifier.verify_profile(self.profile, verifier.APP_ID, False, self.now)

    def test_expired_profile_and_missing_capabilities_are_rejected(self) -> None:
        expired = copy.deepcopy(self.profile)
        expired["ExpirationDate"] = datetime.datetime(2026, 1, 1)
        with self.assertRaises(ValueError):
            verifier.verify_profile(expired, verifier.APP_ID, False, self.now)
        for key in ["com.apple.developer.system-extension.install", "keychain-access-groups",
                    "com.apple.security.application-groups", "com.apple.developer.networking.networkextension"]:
            profile = copy.deepcopy(self.profile)
            profile["Entitlements"].pop(key)
            with self.subTest(capability=key), self.assertRaises(ValueError):
                verifier.verify_profile(profile, verifier.APP_ID, False, self.now)

    def test_signed_verification_requests_xml_entitlements(self) -> None:
        (self.bundle / "Contents" / "embedded.provisionprofile").touch()
        for is_extension in (False, True):
            profile = copy.deepcopy(self.profile)
            profile["ExpirationDate"] = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)
            bundle_id = verifier.EXTENSION_ID if is_extension else verifier.APP_ID
            entitlements = profile["Entitlements"]
            entitlements["com.apple.application-identifier"] = f"{verifier.TEAM_ID}.{bundle_id}"
            entitlements["keychain-access-groups"] = [f"{verifier.TEAM_ID}.{verifier.APP_ID}"]
            if is_extension:
                entitlements.pop("keychain-access-groups")
                entitlements.pop("com.apple.developer.system-extension.install")
                entitlements.update({
                    "com.apple.security.app-sandbox": True,
                    "com.apple.security.network.client": True,
                    "com.apple.security.network.server": True,
                })

            def fake_command(*args: str) -> subprocess.CompletedProcess:
                output = b""
                metadata = b""
                if "--entitlements" in args:
                    output = plistlib.dumps(entitlements) if "--xml" in args else b"[Dict]\n"
                elif "--verbose=4" in args:
                    metadata = b"flags=0x10000(runtime)\n"
                elif "cms" in args:
                    output = plistlib.dumps(profile)
                else:
                    self.assertIn("--verify", args)
                return subprocess.CompletedProcess(args, 0, stdout=output, stderr=metadata)

            with self.subTest(is_extension=is_extension), patch.object(verifier, "command", side_effect=fake_command):
                verifier.verify_signature(self.bundle, bundle_id, is_extension)

    def developer_id_profile(self, is_extension: bool = False) -> dict:
        profile = copy.deepcopy(self.profile)
        profile["ProvisionsAllDevices"] = True
        profile["ExpirationDate"] = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)
        entitlements = profile["Entitlements"]
        entitlements["com.apple.developer.networking.networkextension"] = ["packet-tunnel-provider-systemextension"]
        entitlements["keychain-access-groups"] = [f"{verifier.TEAM_ID}.{verifier.APP_ID}"]
        if is_extension:
            entitlements["com.apple.application-identifier"] = f"{verifier.TEAM_ID}.{verifier.EXTENSION_ID}"
            entitlements.pop("keychain-access-groups")
            entitlements.pop("com.apple.developer.system-extension.install")
            entitlements.update({
                "com.apple.security.app-sandbox": True,
                "com.apple.security.network.client": True,
                "com.apple.security.network.server": True,
            })
        return profile

    def verify_developer_id_signature(self, profile: dict, metadata: str, is_extension: bool = False) -> None:
        (self.bundle / "Contents" / "embedded.provisionprofile").touch()

        def fake_command(*args: str) -> subprocess.CompletedProcess:
            output = b""
            details = b""
            if "--entitlements" in args:
                self.assertIn("--xml", args)
                output = plistlib.dumps(profile["Entitlements"])
            elif "--verbose=4" in args:
                details = metadata.encode()
            elif "cms" in args:
                output = plistlib.dumps(profile)
            else:
                self.assertIn("--verify", args)
                requirement = args[args.index("--test-requirement") + 1]
                self.assertTrue(requirement.startswith("="), "codesign text requirements need the inline prefix")
                self.assertIn("anchor apple generic", requirement)
                self.assertIn("certificate leaf[field.1.2.840.113635.100.6.1.13] exists", requirement)
                self.assertIn(f'certificate leaf[subject.OU] = "{verifier.TEAM_ID}"', requirement)
            return subprocess.CompletedProcess(args, 0, stdout=output, stderr=details)

        bundle_id = verifier.EXTENSION_ID if is_extension else verifier.APP_ID
        with patch.object(verifier, "command", side_effect=fake_command):
            verifier.verify_signature(self.bundle, bundle_id, is_extension, developer_id=True)

    def developer_id_metadata(self, is_extension: bool = False) -> str:
        bundle_id = verifier.EXTENSION_ID if is_extension else verifier.APP_ID
        return (
            f"Identifier={bundle_id}\nflags=0x10000(runtime)\n"
            f"Authority=Developer ID Application: Example Developer ({verifier.TEAM_ID})\n"
            "Authority=Developer ID Certification Authority\nAuthority=Apple Root CA\n"
            f"TeamIdentifier={verifier.TEAM_ID}\nTimestamp=Oct 2, 2026 at 12:00:00 PM\n"
        )

    def test_valid_developer_id_app_and_extension_profiles_and_signatures(self) -> None:
        for is_extension in (False, True):
            with self.subTest(is_extension=is_extension):
                self.verify_developer_id_signature(self.developer_id_profile(is_extension),
                                                   self.developer_id_metadata(is_extension), is_extension)

    def test_developer_id_entitlement_rejects_wrong_distribution_channel(self) -> None:
        profile = self.developer_id_profile()
        entitlements = profile["Entitlements"]
        for capabilities in (["packet-tunnel-provider"],
                             ["packet-tunnel-provider-systemextension", "packet-tunnel-provider"]):
            entitlements["com.apple.developer.networking.networkextension"] = capabilities
            with self.subTest(capabilities=capabilities), self.assertRaisesRegex(ValueError, "distribution channel"):
                verifier.verify_entitlements(entitlements, False, developer_id=True)
        entitlements["com.apple.developer.networking.networkextension"] = ["packet-tunnel-provider-systemextension"]
        with self.assertRaisesRegex(ValueError, "distribution channel"):
            verifier.verify_entitlements(entitlements, False)

    def test_developer_id_profile_rejects_device_bound_and_debug_profiles(self) -> None:
        for provisions_all_devices in (None, False, 1):
            profile = self.developer_id_profile()
            if provisions_all_devices is None:
                profile.pop("ProvisionsAllDevices")
                profile["ProvisionedDevices"] = ["development-device"]
            else:
                profile["ProvisionsAllDevices"] = provisions_all_devices
            with self.subTest(all_devices=provisions_all_devices), self.assertRaisesRegex(ValueError, "all devices"):
                verifier.verify_profile(profile, verifier.APP_ID, False, self.now, developer_id=True)
        profile = self.developer_id_profile()
        profile["Entitlements"]["com.apple.developer.networking.networkextension"] = ["packet-tunnel-provider"]
        with self.assertRaisesRegex(ValueError, "distribution channel"):
            verifier.verify_profile(profile, verifier.APP_ID, False, self.now, developer_id=True)
        for debug_key in ("com.apple.security.get-task-allow", "get-task-allow"):
            profile = self.developer_id_profile()
            profile["Entitlements"][debug_key] = True
            with self.subTest(debug_key=debug_key), self.assertRaisesRegex(ValueError, "allow debugging"):
                verifier.verify_profile(profile, verifier.APP_ID, False, self.now, developer_id=True)

    def test_developer_id_signatures_reject_wrong_authority_team_or_identifier(self) -> None:
        metadata = self.developer_id_metadata()
        for replacement in ("Apple Development: Example Developer", "Developer ID Installer: Example Developer"):
            invalid = metadata.replace("Developer ID Application: Example Developer", replacement)
            with self.subTest(authority=replacement), self.assertRaisesRegex(ValueError, "signing authority"):
                self.verify_developer_id_signature(self.developer_id_profile(), invalid)
        for old, new, error in (
            (f"({verifier.TEAM_ID})", "(WRONGTEAM1)", "signing authority"),
            (f"TeamIdentifier={verifier.TEAM_ID}", "TeamIdentifier=WRONGTEAM1", "signing team"),
            (f"Identifier={verifier.APP_ID}", "Identifier=com.example.other", "signed identifier"),
        ):
            with self.subTest(field=old), self.assertRaisesRegex(ValueError, error):
                self.verify_developer_id_signature(self.developer_id_profile(), metadata.replace(old, new))

    def test_developer_id_signatures_require_timestamp_runtime_and_no_debugging(self) -> None:
        metadata = self.developer_id_metadata()
        for old, new, error in (
            ("Timestamp=", "Signed Time=", "secure timestamp"),
            ("flags=0x10000(runtime)", "flags=0x0(none)", "Hardened Runtime"),
        ):
            with self.subTest(field=old), self.assertRaisesRegex(ValueError, error):
                self.verify_developer_id_signature(self.developer_id_profile(), metadata.replace(old, new))
        for debug_key in ("com.apple.security.get-task-allow", "get-task-allow"):
            profile = self.developer_id_profile()
            profile["Entitlements"][debug_key] = True
            with self.subTest(debug_key=debug_key), self.assertRaisesRegex(ValueError, "signature must not allow debugging"):
                self.verify_developer_id_signature(profile, metadata)

    def test_developer_id_cli_flag_selects_release_validation(self) -> None:
        with patch("sys.argv", ["verify_macos_build.py", str(self.bundle), "--developer-id"]), \
                patch.object(verifier, "verify_bundle") as verify_bundle:
            verifier.main()
        verify_bundle.assert_called_once_with(self.bundle, False, True)

    def test_packaged_fixture_rejects_invalid_description_and_duplicate_embedding(self) -> None:
        app = Path(self.temporary.name) / "CloudGateway.app"
        extension = app / "Contents" / "Library" / "SystemExtensions" / f"{verifier.EXTENSION_ID}.systemextension"
        common = {"LSMinimumSystemVersion": "26.0", "CloudGatewayTeamIdentifier": verifier.TEAM_ID,
                  "CFBundleExecutable": "Executable"}
        for bundle, info in [
            (app, dict(common, CFBundleIdentifier=verifier.APP_ID, LSUIElement=True)),
            (extension, dict(common, CFBundleIdentifier=verifier.EXTENSION_ID, CFBundleVersion="4",
                             NSSystemExtensionUsageDescription="Connect to your configured networks", NetworkExtension={
                "NEMachServiceName": f"{verifier.APP_GROUP}.tunnel.4",
                "NEProviderClasses": {"com.apple.networkextension.packet-tunnel": "CloudGatewayTunnel.PacketTunnelProvider"},
            })),
        ]:
            (bundle / "Contents" / "MacOS").mkdir(parents=True)
            (bundle / "Contents" / "MacOS" / "Executable").touch()
            (bundle / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))

        def fake_command(*args: str) -> subprocess.CompletedProcess:
            if args[0].endswith("lipo"):
                output = b"arm64\n"
            elif args[1] == "-L":
                output = b"Executable:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n"
            else:
                output = b"cmd LC_RPATH\ncmdsize 48\npath @executable_path/../Frameworks (offset 12)\n"
            return subprocess.CompletedProcess(args, 0, stdout=output, stderr=b"")

        with patch.object(verifier, "command", side_effect=fake_command):
            verifier.verify_bundle(app, False)
            with patch.object(verifier, "verify_signature") as verify_signature:
                verifier.verify_bundle(app, False, developer_id=True)
            self.assertEqual(verify_signature.call_args_list, [
                call(app, verifier.APP_ID, False, True),
                call(extension, verifier.EXTENSION_ID, True, True),
            ])
            info_path = extension / "Contents" / "Info.plist"
            valid_info = verifier.read_plist(info_path)
            for service in (f"{verifier.APP_GROUP}.tunnel", f"{verifier.APP_GROUP}.tunnel.3", "other.tunnel.4"):
                invalid_info = dict(valid_info, NetworkExtension=dict(valid_info["NetworkExtension"], NEMachServiceName=service))
                info_path.write_bytes(plistlib.dumps(invalid_info))
                with self.subTest(service=service), self.assertRaisesRegex(ValueError, "Mach service mismatch"):
                    verifier.verify_bundle(app, False)
            for build in (None, 4, "", "4..1", "4/1", "4\n", "4" * 65):
                invalid_info = dict(valid_info, CFBundleVersion=build)
                if build is None:
                    invalid_info.pop("CFBundleVersion")
                info_path.write_bytes(plistlib.dumps(invalid_info))
                with self.subTest(build=build), self.assertRaisesRegex(ValueError, "Extension build"):
                    verifier.verify_bundle(app, False)
            for description in (None, "", "   ", 17):
                invalid_info = dict(valid_info)
                if description is None:
                    invalid_info.pop("NSSystemExtensionUsageDescription")
                else:
                    invalid_info["NSSystemExtensionUsageDescription"] = description
                info_path.write_bytes(plistlib.dumps(invalid_info))
                with self.subTest(description=description), self.assertRaisesRegex(ValueError, "usage description"):
                    verifier.verify_bundle(app, False)
            info_path.write_bytes(plistlib.dumps(valid_info))
            (app / "CloudGateway.app" / "Tunnel.systemextension").mkdir(parents=True)
            with self.assertRaises(ValueError):
                verifier.verify_bundle(app, False)


if __name__ == "__main__":
    unittest.main()
