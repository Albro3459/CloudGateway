"""Release failures must stop uploads, and retries must retain existing submissions."""

import importlib.util
import json
import plistlib
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).with_name("macos-release.py")
SPEC = importlib.util.spec_from_file_location("macos_release", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)

SUBMISSION_ID = "00000000-0000-0000-0000-000000000001"


class ReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.artifact = self.directory / "app.zip"
        self.artifact.write_bytes(b"signed app archive")

    def test_rejected_notarization_retains_id_and_fetches_log(self) -> None:
        def command(*args: str, **kwargs: object) -> str:
            if args[2] == "submit":
                return json.dumps({"id": SUBMISSION_ID})
            if args[2] == "wait":
                raise subprocess.CalledProcessError(1, args)
            if args[2] == "info":
                return json.dumps({"status": "Invalid"})
            if args[2] == "log":
                Path(args[-1]).write_text(json.dumps({"issues": [{"severity": "error"}]}))
                return ""
            self.fail(f"Unexpected command: {args}")

        with mock.patch.object(release, "command", side_effect=command):
            with self.assertRaisesRegex(ValueError, "Invalid"):
                release.notarize_artifact(self.artifact, self.directory, "app", "profile")
        record = json.loads((self.directory / "notary-app-submission.json").read_text())
        self.assertEqual(record["id"], SUBMISSION_ID)
        self.assertTrue((self.directory / "notary-app-log.json").exists())

    def test_retry_waits_for_existing_submission_without_uploading_again(self) -> None:
        release.write_json(self.directory / "notary-app-submission.json", {
            "id": SUBMISSION_ID, "sha256": release.sha256(self.artifact),
        })

        def command(*args: str, **kwargs: object) -> str:
            self.assertNotEqual(args[2], "submit")
            if args[2] == "wait":
                return json.dumps({"status": "Accepted"})
            if args[2] == "log":
                Path(args[-1]).write_text('{"issues": null}')
                return ""
            self.fail(f"Unexpected command: {args}")

        with mock.patch.object(release, "command", side_effect=command):
            release.notarize_artifact(self.artifact, self.directory, "app", "profile")

    def test_changed_artifact_cannot_reuse_submission(self) -> None:
        release.write_json(self.directory / "notary-app-submission.json", {
            "id": SUBMISSION_ID, "sha256": release.sha256(self.artifact),
        })
        self.artifact.write_bytes(b"different app")
        with mock.patch.object(release, "command") as command:
            with self.assertRaisesRegex(ValueError, "changed after submission"):
                release.notarize_artifact(self.artifact, self.directory, "app", "profile")
            command.assert_not_called()

    def test_interrupted_upload_stops_retry_until_id_is_reconciled(self) -> None:
        with mock.patch.object(release, "command", side_effect=OSError("connection lost")):
            with self.assertRaises(OSError):
                release.notarize_artifact(self.artifact, self.directory, "app", "profile")
        with mock.patch.object(release, "command") as command:
            with self.assertRaisesRegex(ValueError, "no saved submission ID"):
                release.notarize_artifact(self.artifact, self.directory, "app", "profile")
            command.assert_not_called()
        release.recover_submission(self.directory, f"app={SUBMISSION_ID}")
        record = json.loads((self.directory / "notary-app-submission.json").read_text())
        self.assertEqual(record["id"], SUBMISSION_ID)
        self.assertEqual(record["sha256"], release.sha256(self.artifact))

    def test_interrupted_dmg_stapling_recovers_verified_ticket_without_upload(self) -> None:
        artifact = self.directory / "app.dmg"
        artifact.write_bytes(b"signed disk image")
        release.write_json(self.directory / "notary-dmg-submission.json", {
            "id": SUBMISSION_ID, "sha256": release.sha256(artifact), "cdhash": "a" * 40,
        })
        artifact.write_bytes(b"signed disk image plus notarization ticket")

        def command(*args: str, **kwargs: object) -> str:
            self.assertNotEqual(args[:3], ("xcrun", "notarytool", "submit"))
            if args[0] == "codesign":
                return f"CDHash={'a' * 40}\n"
            if args[1:3] == ("stapler", "validate"):
                return ""
            if args[2] == "wait":
                return json.dumps({"status": "Accepted"})
            if args[2] == "log":
                Path(args[-1]).write_text('{"issues": null}')
                return ""
            self.fail(f"Unexpected command: {args}")

        with mock.patch.object(release, "command", side_effect=command):
            release.notarize_artifact(artifact, self.directory, "dmg", "profile")

    def test_invalid_signed_app_prevents_preparation_and_upload(self) -> None:
        with mock.patch.object(release, "RELEASE_ROOT", self.directory), \
                mock.patch.object(release, "release_version", return_value="1.0.0"), \
                mock.patch.object(release, "signing_identity", return_value="A" * 40), \
                mock.patch.object(release, "command", return_value="") as command, \
                mock.patch.object(release, "verify_release_app", side_effect=ValueError("bad signature")):
            with self.assertRaisesRegex(ValueError, "bad signature"):
                release.prepare(2, None, "profile")
        calls = [call.args for call in command.call_args_list]
        self.assertFalse(any(args[0] == "ditto" for args in calls))
        self.assertFalse(any(args[:3] == ("xcrun", "notarytool", "submit") for args in calls))
        self.assertFalse(list(self.directory.glob("*/release.json")))

    def test_resumed_release_with_wrong_bundle_version_stops_before_upload(self) -> None:
        release.write_json(self.directory / "release.json", {
            "version": "1.0.0", "build": 2, "team": release.TEAM_ID,
            "signingIdentity": "A" * 40, "keychainProfile": "profile",
        })
        app = self.directory / "export/CloudGateway.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0.0",
        }))
        with mock.patch.object(release, "verify_app"), mock.patch.object(release, "notarize_artifact") as submit:
            with self.assertRaisesRegex(ValueError, "requested release version"):
                release.finish(self.directory)
            submit.assert_not_called()

    def test_version_selection_rejects_existing_build_and_malformed_version(self) -> None:
        build = int(next(iter(re.findall(
            r"\bCURRENT_PROJECT_VERSION = (\d+);", (release.PROJECT / "project.pbxproj").read_text()
        ))))
        with self.assertRaisesRegex(ValueError, "must exceed"):
            release.release_version(build, None)
        with self.assertRaisesRegex(ValueError, "major.minor.patch"):
            release.release_version(build + 1, "../unexpected")
        self.assertEqual(release.release_version(build + 1, "1.2.3"), "1.2.3")


if __name__ == "__main__":
    unittest.main()
