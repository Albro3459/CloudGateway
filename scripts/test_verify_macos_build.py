import copy
import datetime
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import call, patch

from scripts import verify_macos_build as verifier


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
            (extension, dict(common, CFBundleIdentifier=verifier.EXTENSION_ID,
                             NSSystemExtensionUsageDescription="Connect to your configured networks", NetworkExtension={
                "NEMachServiceName": f"{verifier.APP_GROUP}.tunnel",
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
