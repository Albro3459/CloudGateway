"""Archive, sign, notarize, and package CloudGateway for direct macOS distribution."""

import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Frontend/Apple/macOS/CloudGateway.xcodeproj"
RELEASE_ROOT = ROOT / "Frontend/Apple/macOS/.build/releases"
TEAM_ID = "CRQWDQ7QQR"
APP_ID = "com.gocloudlaunch.gateway.macos"
EXTENSION_ID = "com.gocloudlaunch.gateway.tunnel.macos"


def command(*args: str, log: Path | None = None, stderr_output: bool = False) -> str:
    if log is not None:
        print(f"Build log: {log}", flush=True)
        with log.open("w") as stream:
            subprocess.run(args, stdout=stream, stderr=subprocess.STDOUT, check=True)
        return ""
    result = subprocess.run(args, capture_output=True, text=True, check=True)
    return result.stderr if stderr_output else result.stdout


def write_json(path: Path, data: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def signing_identity() -> str:
    identities = command("security", "find-identity", "-v", "-p", "codesigning",
                         str(Path.home() / "Library/Keychains/login.keychain-db"))
    matches = re.findall(
        rf'([A-Fa-f0-9]{{40}}) "Developer ID Application: [^"\n]+ \({TEAM_ID}\)"', identities
    )
    if len(matches) != 1:
        raise ValueError(f"Expected one accessible Developer ID Application identity for team {TEAM_ID}; found {len(matches)}")
    return matches[0]


def release_version(build: int, version: str | None) -> str:
    project = (PROJECT / "project.pbxproj").read_text()
    builds = set(re.findall(r"\bCURRENT_PROJECT_VERSION = (\d+);", project))
    versions = set(re.findall(r"\bMARKETING_VERSION = ([0-9.]+);", project))
    if len(builds) != 1 or len(versions) != 1:
        raise ValueError("App and extension project versions must match before releasing")
    if build <= int(next(iter(builds))):
        raise ValueError("--build must exceed the project's current build number; also use a number higher than every previous release")
    selected = version or next(iter(versions))
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", selected) is None:
        raise ValueError("--version must have the form major.minor.patch")
    return selected


def verify_app(app: Path) -> None:
    command("python3", str(ROOT / "scripts/verify_macos_build.py"), str(app), "--developer-id")


def verify_release_app(app: Path, version: str, build: int) -> None:
    verify_app(app)
    for bundle in [app, app / "Contents/Library/SystemExtensions" / f"{EXTENSION_ID}.systemextension"]:
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        if str(info.get("CFBundleVersion")) != str(build) or info.get("CFBundleShortVersionString") != version:
            raise ValueError("Exported app and extension do not match the requested release version")


def prepare(build: int, version: str | None, keychain_profile: str) -> Path:
    version = release_version(build, version)
    identity = signing_identity()
    # Validate access before spending time archiving; this does not upload software
    command("xcrun", "notarytool", "history", "--keychain-profile", keychain_profile,
            "--output-format", "json")
    RELEASE_ROOT.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix=f"{version}-{build}-", dir=RELEASE_ROOT))
    app_profile = os.environ.get("CLOUDGATEWAY_APP_PROFILE", "CloudGateway MacOS")
    tunnel_profile = os.environ.get("CLOUDGATEWAY_TUNNEL_PROFILE", "CloudGateway-Tunnel MacOS")
    export_options = {
        "method": "developer-id", "signingStyle": "manual", "teamID": TEAM_ID,
        "signingCertificate": identity, "manageAppVersionAndBuildNumber": False,
        "provisioningProfiles": {APP_ID: app_profile, EXTENSION_ID: tunnel_profile},
    }
    options_path = directory / "ExportOptions.plist"
    options_path.write_bytes(plistlib.dumps(export_options))
    archive = directory / "CloudGateway.xcarchive"
    print(f"Archiving CloudGateway {version} ({build}) into {directory}", flush=True)
    command("xcodebuild", "-project", str(PROJECT), "-scheme", "CloudGateway",
            "-configuration", "DeveloperID", "-destination", "generic/platform=macOS",
            "-derivedDataPath", str(ROOT / "Frontend/Apple/macOS/.build/DeveloperID"),
            "-archivePath", str(archive), "ARCHS=arm64", f"DEVELOPMENT_TEAM={TEAM_ID}",
            "CODE_SIGN_STYLE=Manual", f"CODE_SIGN_IDENTITY={identity}",
            f"CURRENT_PROJECT_VERSION={build}", f"MARKETING_VERSION={version}",
            f"CLOUDGATEWAY_APP_PROFILE={app_profile}", f"CLOUDGATEWAY_TUNNEL_PROFILE={tunnel_profile}",
            "OTHER_CODE_SIGN_FLAGS=--timestamp", "archive", log=directory / "archive.log")
    command("xcodebuild", "-exportArchive", "-archivePath", str(archive),
            "-exportOptionsPlist", str(options_path), "-exportPath", str(directory / "export"),
            log=directory / "export.log")
    app = directory / "export/CloudGateway.app"
    verify_release_app(app, version, build)
    command("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app),
            str(directory / "CloudGateway-notary.zip"))
    write_json(directory / "release.json", {
        "version": version, "build": build, "team": TEAM_ID, "signingIdentity": identity,
        "keychainProfile": keychain_profile, "appProfile": app_profile, "tunnelProfile": tunnel_profile,
        "sourceCommit": command("git", "-C", str(ROOT), "rev-parse", "HEAD").strip(),
        "workingTreeDirty": bool(command("git", "-C", str(ROOT), "status", "--porcelain").strip()),
    })
    print(f"Signed app verified. Prepared release: {directory}", flush=True)
    return directory


def code_directory_hash(artifact: Path) -> str:
    metadata = command("codesign", "--display", "--verbose=4", str(artifact), stderr_output=True)
    match = re.search(r"^CDHash=([a-fA-F0-9]+)$", metadata, re.MULTILINE)
    if match is None:
        raise ValueError(f"Code Directory hash missing for {artifact.name}")
    return match[1]


def recover_submission(directory: Path, recovery: str) -> None:
    label, separator, submission_id = recovery.partition("=")
    if label not in {"app", "dmg"} or not separator or re.fullmatch(
        r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}", submission_id
    ) is None:
        raise ValueError("--recover-submission must be app=<submission-id> or dmg=<submission-id>")
    record_path = directory / f"notary-{label}-submission.json"
    if record_path.exists():
        raise ValueError("A submission ID is already recorded; use --notarize to resume it")
    attempt = json.loads((directory / f"notary-{label}-attempt.json").read_text())
    filename = attempt["artifact"]
    if not isinstance(filename, str) or Path(filename).name != filename:
        raise ValueError("Invalid upload attempt artifact name")
    if sha256(directory / filename) != attempt["sha256"]:
        raise ValueError("Artifact changed after the interrupted upload")
    attempt["id"] = submission_id
    write_json(record_path, attempt)


def notarize_artifact(artifact: Path, directory: Path, label: str, profile: str) -> None:
    record_path = directory / f"notary-{label}-submission.json"
    digest = sha256(artifact)
    if record_path.exists():
        record = json.loads(record_path.read_text())
        if record.get("sha256") != digest:
            if artifact.suffix != ".dmg" or record.get("cdhash") != code_directory_hash(artifact):
                raise ValueError(f"{label} changed after submission; use a new release build")
            # A validated staple can change the DMG bytes while preserving its signed code
            command("xcrun", "stapler", "validate", str(artifact))
    else:
        attempt_path = directory / f"notary-{label}-attempt.json"
        if attempt_path.exists():
            raise ValueError(f"Earlier {label} upload has no saved submission ID. Check notarytool history, then resume with --recover-submission {label}=<id>")
        attempt = {"sha256": digest, "artifact": artifact.name,
                   "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}
        if artifact.suffix == ".dmg":
            attempt["cdhash"] = code_directory_hash(artifact)
        write_json(attempt_path, attempt)
        print(f"Submitting {artifact.name} to Apple", flush=True)
        record = json.loads(command("xcrun", "notarytool", "submit", str(artifact),
                                    "--keychain-profile", profile, "--output-format", "json"))
        record.update(attempt)
        write_json(record_path, record)
    submission_id = record.get("id", "")
    if re.fullmatch(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}", submission_id) is None:
        raise ValueError(f"Invalid notarization submission ID in {record_path}")
    print(f"Waiting for {label} notarization: {submission_id}", flush=True)
    try:
        result = json.loads(command("xcrun", "notarytool", "wait", submission_id,
                                    "--keychain-profile", profile, "--timeout", "20m", "--output-format", "json"))
    except subprocess.CalledProcessError:
        result = json.loads(command("xcrun", "notarytool", "info", submission_id,
                                    "--keychain-profile", profile, "--output-format", "json"))
    write_json(directory / f"notary-{label}-status.json", result)
    status = result.get("status")
    if status in {"Accepted", "Invalid", "Rejected"}:
        log_path = directory / f"notary-{label}-log.json"
        command("xcrun", "notarytool", "log", submission_id, "--keychain-profile", profile, str(log_path))
        issues = json.loads(log_path.read_text()).get("issues") or []
        if issues:
            print(f"Notarization reported {len(issues)} issue(s); review {log_path}", flush=True)
    if status != "Accepted":
        raise ValueError(f"Apple returned {status} for {label}. Logs and submission ID are in {directory}; resume with --notarize after processing finishes")
    print(f"Apple accepted {label}", flush=True)


def finish(directory: Path) -> Path:
    metadata = json.loads((directory / "release.json").read_text())
    identity = metadata["signingIdentity"]
    if metadata.get("team") != TEAM_ID or re.fullmatch(r"[A-Fa-f0-9]{40}", identity) is None:
        raise ValueError("Release signing metadata does not match CloudGateway")
    version, build = metadata["version"], metadata["build"]
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", str(version)) is None or not isinstance(build, int) or build <= 0:
        raise ValueError("Invalid release version metadata")
    app = directory / "export/CloudGateway.app"
    profile = metadata["keychainProfile"]
    verify_release_app(app, version, build)
    app_ticket = directory / "app-stapled.json"
    if not app_ticket.exists():
        notarize_artifact(directory / "CloudGateway-notary.zip", directory, "app", profile)
        command("xcrun", "stapler", "staple", str(app))
        command("xcrun", "stapler", "validate", str(app))
        write_json(app_ticket, {"status": "stapled"})
    command("xcrun", "stapler", "validate", str(app))
    dmg = directory / f"CloudGateway-{version}-{build}-arm64.dmg"
    if not dmg.exists():
        staging = Path(tempfile.mkdtemp(prefix="dmg-", dir=directory))
        command("ditto", str(app), str(staging / "CloudGateway.app"))
        (staging / "Applications").symlink_to("/Applications")
        temporary_dmg = directory / f"{staging.name}.dmg"
        command("hdiutil", "create", "-volname", "CloudGateway", "-srcfolder", str(staging),
                "-format", "UDZO", "-fs", "HFS+", str(temporary_dmg))
        command("codesign", "--sign", identity, "--timestamp", "--identifier", f"{APP_ID}.dmg", str(temporary_dmg))
        command("codesign", "--verify", "--strict", str(temporary_dmg))
        temporary_dmg.replace(dmg)
    command("codesign", "--verify", "--strict", str(dmg))
    command("hdiutil", "verify", str(dmg))
    if not (directory / "dmg-stapled.json").exists():
        notarize_artifact(dmg, directory, "dmg", profile)
        command("xcrun", "stapler", "staple", str(dmg))
        command("xcrun", "stapler", "validate", str(dmg))
        write_json(directory / "dmg-stapled.json", {"status": "stapled"})
    command("xcrun", "stapler", "validate", str(dmg))
    command("spctl", "--assess", "--type", "execute", "--verbose=2", str(app))
    command("spctl", "--assess", "--type", "open", "--context", "context:primary-signature",
            "--verbose=2", str(dmg))
    checksum = sha256(dmg)
    (directory / "SHA256SUMS").write_text(f"{checksum}  {dmg.name}\n")
    print(f"Notarized app and DMG verified: {dmg}\nSHA-256: {checksum}", flush=True)
    return dmg


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=int, help="build number higher than the project and every previous release")
    parser.add_argument("--version", help="marketing version override, for example 1.0.1")
    parser.add_argument("--prepare-only", action="store_true", help="archive and verify without uploading to Apple")
    parser.add_argument("--notarize", type=Path, help="notarize or resume an existing prepared release directory")
    parser.add_argument("--recover-submission", help="record a confirmed app=<id> or dmg=<id> after an interrupted upload")
    parser.add_argument("--keychain-profile", default=os.environ.get("CLOUDGATEWAY_NOTARY_PROFILE", "CloudGateway-notary"))
    args = parser.parse_args()
    if args.notarize is not None and (args.build is not None or args.version or args.prepare_only):
        parser.error("--notarize cannot be combined with build/version/preparation options")
    if args.notarize is None and (args.build is None or args.build <= 0):
        parser.error("provide a positive --build number for a new release")
    if args.recover_submission and args.notarize is None:
        parser.error("--recover-submission requires --notarize")
    directory = args.notarize.resolve() if args.notarize is not None else None
    try:
        if directory is None:
            directory = prepare(args.build, args.version, args.keychain_profile)
        if args.recover_submission:
            recover_submission(directory, args.recover_submission)
        if not args.prepare_only:
            finish(directory)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f"macOS release failed: {error}", flush=True)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.strip(), flush=True)
        if directory is not None:
            print(f"Artifacts retained at {directory}\nResume: ./scripts/macos-release.sh --notarize '{directory}'", flush=True)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
