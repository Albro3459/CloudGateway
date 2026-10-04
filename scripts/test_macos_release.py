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


class PublicationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.source = "a" * 40
        self.tag = "macos-v1.0.0-build.2"
        self.title = "CloudGateway for Mac 1.0.0 (build 2)"
        self.dmg = self.directory / "CloudGateway-1.0.0-2-arm64.dmg"
        self.dmg.write_bytes(b"stapled disk image")
        self.zip = self.directory / "CloudGateway-notary.zip"
        self.zip.write_bytes(b"signed app archive")
        (self.directory / "SHA256SUMS").write_text(f"{release.sha256(self.dmg)}  {self.dmg.name}\n")
        release.write_json(self.directory / "release.json", {
            "version": "1.0.0", "build": 2, "team": release.TEAM_ID,
            "signingIdentity": "A" * 40, "sourceCommit": self.source,
            "workingTreeDirty": True,
        })
        for label, artifact in [("app", self.zip), ("dmg", self.dmg)]:
            release.write_json(self.directory / f"notary-{label}-submission.json", {
                "id": SUBMISSION_ID, "sha256": release.sha256(artifact),
                "artifact": artifact.name, "cdhash": "b" * 40,
            })
            release.write_json(self.directory / f"notary-{label}-status.json", {
                "id": SUBMISSION_ID, "status": "Accepted",
            })
            release.write_json(self.directory / f"{label}-stapled.json", {"status": "stapled"})
        self.remote = None
        self.remote_target = None
        self.assets = []
        self.calls = []
        self.private = False
        self.commit_exists = True
        self.fail_upload_once = False
        self.hidden_draft_reads = 0
        patcher = mock.patch.object(release, "verify_release_app")
        self.verify_app = patcher.start()
        self.addCleanup(patcher.stop)
        patcher = mock.patch.object(release, "command", side_effect=self.command)
        patcher.start()
        self.addCleanup(patcher.stop)

    def mutations(self) -> list[tuple]:
        return [args for args in self.calls if args[:2] == ("gh", "release")]

    def add_asset(self, artifact: Path) -> None:
        self.assets.append({"name": artifact.name, "state": "uploaded",
                            "size": artifact.stat().st_size, "digest": f"sha256:{release.sha256(artifact)}"})

    def existing_release(self, *, draft: bool = True) -> None:
        self.remote = {"id": 1, "tag_name": self.tag, "name": self.title,
                       "draft": draft, "prerelease": False, "target_commitish": self.source}
        if not draft:
            self.remote_target = self.source

    def command(self, *args: str, **kwargs: object) -> str:
        self.calls.append(args)
        if args[:2] == ("codesign", "--display"):
            return (f"TeamIdentifier={release.TEAM_ID}\nIdentifier={release.APP_ID}.dmg\n"
                    f"Authority=Developer ID Application: CloudGateway ({release.TEAM_ID})\nCDHash={'b' * 40}\n")
        if args[0] != "gh":
            self.assertNotEqual(args[:3], ("xcrun", "notarytool", "submit"))
            return ""
        if args[1] == "repo":
            return json.dumps({"isPrivate": self.private})
        if args[1] == "api":
            endpoint = args[2].removeprefix(f"repos/{release.GITHUB_REPOSITORY}/")
            if endpoint.startswith("commits/"):
                if not self.commit_exists:
                    raise subprocess.CalledProcessError(1, args, stderr="gh: Not Found (HTTP 404)")
                return json.dumps({"sha": self.source})
            if endpoint.startswith("git/ref/tags/"):
                if self.remote_target is None:
                    raise subprocess.CalledProcessError(1, args, stderr="gh: Not Found (HTTP 404)")
                return json.dumps({"object": {"type": "commit", "sha": self.remote_target}})
            if endpoint == "releases?per_page=100":
                if self.remote is not None and self.hidden_draft_reads > 0:
                    self.hidden_draft_reads -= 1
                    return json.dumps([[]])
                return json.dumps([[self.remote] if self.remote else []])
            if endpoint == "releases/1/assets?per_page=100":
                return json.dumps([self.assets])
            self.fail(f"Unexpected GitHub endpoint: {endpoint}")
        if args[1:3] == ("release", "create"):
            self.assertIn("--draft", args)
            self.assertIn("--latest=false", args)
            self.assertEqual(args[args.index("--target") + 1], self.source)
            self.existing_release()
            return ""
        if args[1:3] == ("release", "upload"):
            self.assertNotIn("--clobber", args)
            for path in args[4:args.index("--repo")]:
                self.add_asset(Path(path))
                if self.fail_upload_once:
                    self.fail_upload_once = False
                    raise subprocess.CalledProcessError(1, args, stderr="connection interrupted")
            return ""
        if args[1:3] == ("release", "edit"):
            self.assertIn("--draft=false", args)
            self.assertIn("--latest=true", args)
            self.remote["draft"] = False
            self.remote_target = self.source
            return ""
        self.fail(f"Unexpected command: {args}")

    def test_cli_rejects_incompatible_publication_options(self) -> None:
        options = [
            ["--publish-existing", "release", "--build", "3"],
            ["--publish-existing", "release", "--version", "1.0.0"],
            ["--publish-existing", "release", "--notarize", "release"],
            ["--publish-existing", "release", "--prepare-only"],
            ["--publish-existing", "release", "--publish"],
            ["--publish-existing", "release", "--recover-submission", f"app={SUBMISSION_ID}"],
            ["--build", "3", "--prepare-only", "--publish"],
            ["--publish"],
        ]
        for args in options:
            with self.subTest(args=args), mock.patch("sys.argv", [str(SCRIPT), *args]), \
                    mock.patch("sys.stderr"), mock.patch.object(release, "prepare") as prepare:
                with self.assertRaises(SystemExit) as error:
                    release.main()
                self.assertEqual(error.exception.code, 2)
                prepare.assert_not_called()
        self.assertEqual(self.calls, [])

    def test_publish_existing_never_prepares_or_finishes(self) -> None:
        with mock.patch("sys.argv", [str(SCRIPT), "--publish-existing", str(self.directory)]), \
                mock.patch.object(release, "prepare") as prepare, \
                mock.patch.object(release, "finish") as finish:
            release.main()
        prepare.assert_not_called()
        finish.assert_not_called()
        publication = json.loads((self.directory / "publication.json").read_text())
        self.assertEqual(publication["sourceCommit"], self.source)
        self.assertTrue(publication["assetURL"].endswith(f"/{self.tag}/{self.dmg.name}"))
        notes = (self.directory / "github-release-notes.md").read_text()
        self.assertIn("local changes when archived: true", notes)
        self.assertEqual([asset["name"] for asset in self.assets], [self.dmg.name, "SHA256SUMS"])

    def test_new_build_publishes_only_after_finish(self) -> None:
        with mock.patch("sys.argv", [str(SCRIPT), "--build", "3", "--publish"]), \
                mock.patch.object(release, "prepare", return_value=self.directory), \
                mock.patch.object(release, "finish", side_effect=ValueError("notarization failed")), \
                mock.patch.object(release, "publish") as publish:
            with self.assertRaises(SystemExit) as error:
                release.main()
            self.assertEqual(error.exception.code, 1)
            publish.assert_not_called()

    def test_invalid_checksum_stops_before_github_and_is_not_rewritten(self) -> None:
        checksum = self.directory / "SHA256SUMS"
        checksum.write_text("wrong digest\n")
        with self.assertRaisesRegex(ValueError, "SHA256SUMS"):
            release.publish(self.directory)
        self.assertEqual(checksum.read_text(), "wrong digest\n")
        self.assertEqual(self.calls, [])

    def test_finish_cannot_rewrite_a_mismatched_existing_checksum(self) -> None:
        metadata_path = self.directory / "release.json"
        metadata = json.loads(metadata_path.read_text())
        metadata["keychainProfile"] = "profile"
        release.write_json(metadata_path, metadata)
        checksum = self.directory / "SHA256SUMS"
        checksum.write_text("wrong digest\n")
        with mock.patch.object(release, "notarize_artifact") as notarize:
            with self.assertRaisesRegex(ValueError, "SHA256SUMS"):
                release.finish(self.directory)
            notarize.assert_not_called()
        self.assertEqual(checksum.read_text(), "wrong digest\n")
        self.assertEqual(self.mutations(), [])

    def test_bad_signature_stops_before_github(self) -> None:
        self.verify_app.side_effect = ValueError("bad app signature")
        with self.assertRaisesRegex(ValueError, "signature"):
            release.publish(self.directory)
        self.assertFalse(any(args[0] == "gh" for args in self.calls))

    def test_unaccepted_notarization_stops_before_github(self) -> None:
        release.write_json(self.directory / "notary-dmg-status.json", {"id": SUBMISSION_ID, "status": "Invalid"})
        with self.assertRaisesRegex(ValueError, "accepted and stapled"):
            release.publish(self.directory)
        self.assertFalse(any(args[0] == "gh" for args in self.calls))

    def test_changed_notarized_artifact_stops_before_github(self) -> None:
        self.zip.write_bytes(b"different archive")
        with self.assertRaisesRegex(ValueError, "changed after notarization"):
            release.publish(self.directory)
        self.assertFalse(any(args[0] == "gh" for args in self.calls))

    def test_missing_remote_source_commit_stops_mutations(self) -> None:
        self.commit_exists = False
        with self.assertRaisesRegex(ValueError, "absent from GitHub"):
            release.publish(self.directory)
        self.assertEqual(self.mutations(), [])

    def test_private_repository_stops_mutations(self) -> None:
        self.private = True
        with self.assertRaisesRegex(ValueError, "must be public"):
            release.publish(self.directory)
        self.assertEqual(self.mutations(), [])

    def test_conflicting_tag_or_draft_target_stops_mutations(self) -> None:
        self.remote_target = "c" * 40
        with self.assertRaisesRegex(ValueError, "different source commit"):
            release.publish(self.directory)
        self.assertEqual(self.mutations(), [])
        self.remote_target = None
        self.existing_release()
        self.remote["target_commitish"] = "main"
        with self.assertRaisesRegex(ValueError, "source commit"):
            release.publish(self.directory)
        self.assertEqual(self.mutations(), [])

    def test_retry_skips_matching_assets_and_preserves_published_release(self) -> None:
        self.existing_release()
        self.add_asset(self.dmg)
        release.publish(self.directory)
        uploads = [args for args in self.mutations() if args[2] == "upload"]
        self.assertEqual(len(uploads), 1)
        self.assertEqual(uploads[0][4:uploads[0].index("--repo")], (str(self.directory / "SHA256SUMS"),))
        self.calls = []
        release.publish(self.directory)
        self.assertEqual(self.mutations(), [])
        self.assertEqual(len(self.assets), 2)

    def test_interrupted_upload_keeps_draft_and_retry_uploads_only_missing_asset(self) -> None:
        self.fail_upload_once = True
        with self.assertRaises(subprocess.CalledProcessError):
            release.publish(self.directory)
        self.assertTrue(self.remote["draft"])
        self.assertEqual(len(self.assets), 1)
        self.assertFalse((self.directory / "publication.json").exists())
        self.calls = []
        release.publish(self.directory)
        self.assertFalse(any(args[2] == "create" for args in self.mutations()))
        upload = next(args for args in self.mutations() if args[2] == "upload")
        self.assertEqual(upload[4:upload.index("--repo")], (str(self.directory / "SHA256SUMS"),))

    def test_delayed_draft_visibility_does_not_create_a_second_release(self) -> None:
        self.hidden_draft_reads = 2
        with mock.patch.object(release.time, "sleep"):
            release.publish(self.directory)
        self.assertEqual(sum(args[2] == "create" for args in self.mutations()), 1)
        self.assertEqual(sum(args[2] == "upload" for args in self.mutations()), 1)
        self.assertFalse(self.remote["draft"])
        self.assertEqual(len(self.assets), 2)
        self.assertTrue((self.directory / "publication.json").exists())

    def test_draft_visibility_timeout_retains_draft_for_safe_resume(self) -> None:
        self.hidden_draft_reads = 4
        with mock.patch.object(release.time, "sleep") as sleep:
            with self.assertRaisesRegex(ValueError, "not visible yet"):
                release.publish(self.directory)
        self.assertEqual(sleep.call_count, 3)
        self.assertEqual([args[2] for args in self.mutations()], ["create"])
        self.assertTrue(self.remote["draft"])
        self.assertEqual(self.assets, [])
        self.assertFalse((self.directory / "publication.json").exists())

        self.calls = []
        release.publish(self.directory)
        self.assertFalse(any(args[2] == "create" for args in self.mutations()))
        self.assertFalse(self.remote["draft"])
        self.assertEqual(len(self.assets), 2)

    def test_conflicting_asset_is_never_overwritten(self) -> None:
        self.existing_release()
        self.add_asset(self.dmg)
        self.assets[0]["digest"] = "sha256:" + "c" * 64
        with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
            release.publish(self.directory)
        self.assertEqual(self.mutations(), [])


if __name__ == "__main__":
    unittest.main()
