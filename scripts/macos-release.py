"""Bump synchronized macOS versions, archive, notarize, and publish CloudGateway."""

import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Frontend/Apple/macOS/CloudGateway.xcodeproj"
RELEASE_ROOT = ROOT / "Frontend/Apple/macOS/.build/releases"
TEAM_ID = "CRQWDQ7QQR"
APP_ID = "com.gocloudlaunch.gateway.macos"
EXTENSION_ID = "com.gocloudlaunch.gateway.tunnel.macos"
GITHUB_REPOSITORY = "Albro3459/CloudGateway"


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


def project_versions(bundle_id: str, build_setting: str, version_setting: str) -> tuple[str, int]:
    project = (PROJECT / "project.pbxproj").read_text()
    configurations = [settings for settings in re.findall(r"\bbuildSettings\s*=\s*\{([^{}]*)\}", project)
                      if re.search(rf"\bPRODUCT_BUNDLE_IDENTIFIER\s*=\s*{re.escape(bundle_id)};", settings)]
    if len(configurations) != 3:
        raise ValueError(f"{bundle_id} requires Debug, Release, and DeveloperID configurations")
    values = set()
    for settings in configurations:
        build = re.search(rf"\b{build_setting}\s*=\s*([0-9]+);", settings)
        version = re.search(rf"\b{version_setting}\s*=\s*([0-9]+\.[0-9]+\.[0-9]+);", settings)
        if build is None or version is None or int(build[1]) <= 0:
            raise ValueError(f"{bundle_id} requires explicit {build_setting} and {version_setting} in every configuration")
        values.add((version[1], int(build[1])))
    if len(values) != 1:
        raise ValueError(f"{bundle_id} project versions must be consistent across configurations")
    return next(iter(values))


def bump_project_versions(build: int | None, version: str | None) -> tuple[str, int]:
    app_version, app_build = project_versions(APP_ID, "CLOUDGATEWAY_APP_BUILD", "CLOUDGATEWAY_APP_VERSION")
    extension_version, extension_build = project_versions(EXTENSION_ID, "CURRENT_PROJECT_VERSION", "MARKETING_VERSION")
    current_version = max(app_version, extension_version, key=lambda value: tuple(map(int, value.split("."))))
    selected_version = version or current_version
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", selected_version) is None:
        raise ValueError("--version must have the form major.minor.patch")
    if tuple(map(int, selected_version.split("."))) < tuple(map(int, current_version.split("."))):
        raise ValueError("The marketing version must not decrease")
    selected_build = max(app_build, extension_build) + 1 if build is None else build
    if selected_build <= max(app_build, extension_build):
        raise ValueError("--build must exceed both current project build numbers")
    path = PROJECT / "project.pbxproj"
    replacements = {
        APP_ID: {"CLOUDGATEWAY_APP_BUILD": str(selected_build), "CLOUDGATEWAY_APP_VERSION": selected_version,
                 "CURRENT_PROJECT_VERSION": '"$(CLOUDGATEWAY_APP_BUILD)"', "MARKETING_VERSION": '"$(CLOUDGATEWAY_APP_VERSION)"'},
        EXTENSION_ID: {"CURRENT_PROJECT_VERSION": str(selected_build), "MARKETING_VERSION": selected_version},
    }

    def update(match: re.Match[str]) -> str:
        settings = match[2]
        for bundle_id, values in replacements.items():
            if re.search(rf"\bPRODUCT_BUNDLE_IDENTIFIER\s*=\s*{re.escape(bundle_id)};", settings):
                for key, value in values.items():
                    settings, count = re.subn(rf"(\b{key}\s*=\s*)[^;]+;", lambda item: item[1] + value + ";", settings)
                    if count != 1:
                        raise ValueError(f"Expected one {key} setting per {bundle_id} configuration")
        return match[1] + settings + match[3]

    updated = re.sub(r"(\bbuildSettings\s*=\s*\{)([^{}]*)(\})", update, path.read_text())
    temporary = path.with_suffix(".pbxproj.tmp")
    temporary.write_text(updated)
    temporary.replace(path)
    return selected_version, selected_build


def release_version(build: int, version: str | None) -> str:
    project_version, project_build = project_versions(APP_ID, "CLOUDGATEWAY_APP_BUILD", "CLOUDGATEWAY_APP_VERSION")
    if project_versions(EXTENSION_ID, "CURRENT_PROJECT_VERSION", "MARKETING_VERSION") != (project_version, project_build):
        raise ValueError("App and extension versions differ; run python3 scripts/macos-release.py --bump-build first")
    if build < project_build:
        raise ValueError("--build must not be lower than the synchronized project build number")
    selected = version or project_version
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", selected) is None:
        raise ValueError("--version must have the form major.minor.patch")
    if tuple(map(int, selected.split("."))) < tuple(map(int, project_version.split("."))):
        raise ValueError("The marketing version must not decrease")
    return selected


def verify_app(app: Path, *, cli: bool = False, historical_baseline: bool = False) -> None:
    options = ["--developer-id"] + (["--cli-smoke"] if cli else [])
    if historical_baseline:
        options.append("--historical-baseline")
    command("python3", str(ROOT / "scripts/verify_macos_build.py"), str(app), *options)


def release_versions(metadata: dict) -> tuple[str, int, str, int]:
    version, build = metadata.get("version"), metadata.get("build")
    if not isinstance(version, str) or re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is None or type(build) is not int or build <= 0:
        raise ValueError("Invalid release version metadata")
    if "extensionVersion" not in metadata and "extensionBuild" not in metadata:
        return version, build, version, build
    extension_version, extension_build = metadata.get("extensionVersion"), metadata.get("extensionBuild")
    if not isinstance(extension_version, str) or re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", extension_version) is None or type(extension_build) is not int or extension_build <= 0:
        raise ValueError("Invalid release extension version metadata")
    return version, build, extension_version, extension_build


def verify_release_app(app: Path, version: str, build: int, extension_version: str, extension_build: int) -> None:
    verify_app(app, cli=True)
    extension = app / "Contents/Library/SystemExtensions" / f"{EXTENSION_ID}.systemextension"
    for bundle, expected_version, expected_build in [(app, version, build), (extension, extension_version, extension_build)]:
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        if str(info.get("CFBundleVersion")) != str(expected_build) or info.get("CFBundleShortVersionString") != expected_version:
            raise ValueError(f"Exported {bundle.name} does not match the requested release version {expected_version} ({expected_build})")


def extension_bundle(app: Path) -> Path:
    return app / "Contents/Library/SystemExtensions" / f"{EXTENSION_ID}.systemextension"


def extension_artifact(app: Path) -> dict:
    extension = extension_bundle(app)
    info = plistlib.loads((extension / "Contents/Info.plist").read_bytes())
    version, build = info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")
    if not isinstance(build, str) or re.fullmatch(r"[0-9]+", build) is None:
        raise ValueError("Invalid extension artifact build")
    release_versions({"version": version, "build": int(build)})
    # Include the whole executable signature (including CMS), resources, and symlink targets
    entries = []
    for path in sorted(extension.rglob("*")):
        relative = path.relative_to(extension).as_posix()
        if path.is_symlink():
            entries.append([relative, "symlink", os.readlink(path)])
        elif path.is_file():
            entries.append([relative, "file", path.stat().st_mode & 0o777, sha256(path)])
        elif path.is_dir():
            entries.append([relative, "directory"])
        else:
            raise ValueError("Unsupported file in extension artifact")
    digest = hashlib.sha256(json.dumps(entries, separators=(",", ":")).encode()).hexdigest()
    return {"version": version, "build": int(build), "sha256": digest}


def extension_baseline(previous_distributed_app: Path | None, initial_distribution: bool) -> dict:
    if (previous_distributed_app is not None) == initial_distribution:
        raise ValueError("Choose --previous-distributed-app or --initial-distribution for a new release")
    if initial_distribution:
        return {"initialDistribution": True}
    app = previous_distributed_app.resolve()
    verify_app(app, historical_baseline=True)
    return extension_artifact(app)


def require_fresh_extension(version: str, build: int, baseline: dict) -> None:
    if len(baseline) == 1 and baseline.get("initialDistribution") is True:
        return
    previous_version, previous_build = baseline.get("version"), baseline.get("build")
    release_versions({"version": previous_version, "build": previous_build})
    if re.fullmatch(r"[a-f0-9]{64}", str(baseline.get("sha256", ""))) is None:
        raise ValueError("Invalid previous distributed extension artifact digest")
    if build <= previous_build:
        raise ValueError("Newly signed extension build must exceed the previous distributed extension build")
    if tuple(map(int, version.split("."))) < tuple(map(int, previous_version.split("."))):
        raise ValueError("Extension marketing version must not decrease from the previous distributed release")


def verify_extension_policy(app: Path, metadata: dict) -> None:
    baseline = metadata.get("extensionBaseline")
    expected = metadata.get("extensionArtifact")
    if not isinstance(baseline, dict) or not isinstance(expected, dict):
        raise ValueError("Release lacks an extension artifact baseline; prepare a new release with --previous-distributed-app")
    artifact = extension_artifact(app)
    if artifact != expected:
        raise ValueError("Signed extension artifact changed after preparation; use a new extension build")
    require_fresh_extension(artifact["version"], artifact["build"], baseline)


def prepare(
    build: int | None, version: str | None, keychain_profile: str,
    previous_distributed_app: Path | None = None, initial_distribution: bool = False,
) -> Path:
    if build is None:
        _, build = project_versions(APP_ID, "CLOUDGATEWAY_APP_BUILD", "CLOUDGATEWAY_APP_VERSION")
    version = release_version(build, version)
    extension_version, extension_build = version, build
    baseline = extension_baseline(previous_distributed_app, initial_distribution)
    require_fresh_extension(extension_version, extension_build, baseline)
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
            f"CLOUDGATEWAY_APP_BUILD={build}", f"CLOUDGATEWAY_APP_VERSION={version}",
            f"CURRENT_PROJECT_VERSION={build}", f"MARKETING_VERSION={version}",
            f"CLOUDGATEWAY_APP_PROFILE={app_profile}", f"CLOUDGATEWAY_TUNNEL_PROFILE={tunnel_profile}",
            "OTHER_CODE_SIGN_FLAGS=--timestamp", "archive", log=directory / "archive.log")
    command("xcodebuild", "-exportArchive", "-archivePath", str(archive),
            "-exportOptionsPlist", str(options_path), "-exportPath", str(directory / "export"),
            log=directory / "export.log")
    app = directory / "export/CloudGateway.app"
    verify_release_app(app, version, build, extension_version, extension_build)
    artifact = extension_artifact(app)
    command("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app),
            str(directory / "CloudGateway-notary.zip"))
    write_json(directory / "release.json", {
        "version": version, "build": build, "team": TEAM_ID, "signingIdentity": identity,
        "extensionVersion": extension_version, "extensionBuild": extension_build,
        "extensionBaseline": baseline, "extensionArtifact": artifact,
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
    version, build, extension_version, extension_build = release_versions(metadata)
    app = directory / "export/CloudGateway.app"
    profile = metadata["keychainProfile"]
    verify_release_app(app, version, build, extension_version, extension_build)
    verify_extension_policy(app, metadata)
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
    checksum_file = directory / "SHA256SUMS"
    expected_checksum = f"{checksum}  {dmg.name}\n"
    if checksum_file.exists():
        if checksum_file.read_text() != expected_checksum:
            raise ValueError("SHA256SUMS does not match the finished DMG; use a new release build")
    else:
        checksum_file.write_text(expected_checksum)
    print(f"Notarized app and DMG verified: {dmg}\nSHA-256: {checksum}", flush=True)
    return dmg


def verify_publication(directory: Path) -> tuple[dict, Path]:
    metadata = json.loads((directory / "release.json").read_text())
    version, build, extension_version, extension_build = release_versions(metadata)
    if metadata.get("team") != TEAM_ID or re.fullmatch(
        r"[A-Fa-f0-9]{40}", str(metadata.get("signingIdentity", ""))
    ) is None:
        raise ValueError("Release signing metadata does not match CloudGateway")
    if re.fullmatch(r"[a-f0-9]{40}", str(metadata.get("sourceCommit", ""))) is None:
        raise ValueError("Release metadata must record the exact source commit")
    app = directory / "export/CloudGateway.app"
    dmg = directory / f"CloudGateway-{version}-{build}-arm64.dmg"
    checksum = directory / "SHA256SUMS"
    if checksum.read_text() != f"{sha256(dmg)}  {dmg.name}\n":
        raise ValueError("SHA256SUMS does not match the finished DMG; publication will not rewrite it")
    verify_release_app(app, version, build, extension_version, extension_build)
    verify_extension_policy(app, metadata)
    command("codesign", "--verify", "--strict", str(dmg))
    signature = command("codesign", "--display", "--verbose=4", str(dmg), stderr_output=True)
    for expected in [f"TeamIdentifier={TEAM_ID}", f"Identifier={APP_ID}.dmg"]:
        if expected not in signature.splitlines():
            raise ValueError("DMG signing metadata does not match CloudGateway")
    if re.search(rf"^Authority=Developer ID Application: .+ \({TEAM_ID}\)$", signature, re.MULTILINE) is None:
        raise ValueError("DMG must have a Developer ID Application signature")
    command("hdiutil", "verify", str(dmg))
    for label, artifact in [("app", directory / "CloudGateway-notary.zip"), ("dmg", dmg)]:
        record = json.loads((directory / f"notary-{label}-submission.json").read_text())
        status = json.loads((directory / f"notary-{label}-status.json").read_text())
        ticket = json.loads((directory / f"{label}-stapled.json").read_text())
        submission_id = record.get("id", "")
        if re.fullmatch(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}", submission_id) is None:
            raise ValueError(f"Invalid {label} notarization submission ID")
        if status.get("status") != "Accepted" or status.get("id") != submission_id or ticket.get("status") != "stapled":
            raise ValueError(f"Release has no matching accepted and stapled {label} notarization")
        if record.get("artifact") != artifact.name:
            raise ValueError(f"{label} notarization record names a different artifact")
        if record.get("sha256") != sha256(artifact):
            if label != "dmg" or not record.get("cdhash") or record["cdhash"] != code_directory_hash(dmg):
                raise ValueError(f"{label} changed after notarization")
        command("xcrun", "stapler", "validate", str(app if label == "app" else dmg))
    command("spctl", "--assess", "--type", "execute", "--verbose=2", str(app))
    command("spctl", "--assess", "--type", "open", "--context", "context:primary-signature",
            "--verbose=2", str(dmg))
    return metadata, dmg


def github_api(endpoint: str, *, optional: bool = False, paginate: bool = False):
    args = ["gh", "api", f"repos/{GITHUB_REPOSITORY}/{endpoint}"]
    if paginate:
        args.extend(["--paginate", "--slurp"])
    try:
        return json.loads(command(*args))
    except subprocess.CalledProcessError as error:
        if optional and "(HTTP 404)" in (error.stderr or ""):
            return None
        raise


def github_tag_commit(tag: str) -> str | None:
    reference = github_api(f"git/ref/tags/{tag}", optional=True)
    if reference is None:
        return None
    target = reference["object"]
    for _ in range(5):
        if target["type"] == "commit":
            return target["sha"]
        if target["type"] != "tag":
            break
        target = github_api(f"git/tags/{target['sha']}")["object"]
    raise ValueError("Release tag does not resolve to a commit")


def github_release(tag: str) -> dict | None:
    pages = github_api("releases?per_page=100", paginate=True)
    matches = [item for page in pages for item in page if item["tag_name"] == tag]
    if len(matches) > 1:
        raise ValueError("More than one GitHub release has the requested tag")
    return matches[0] if matches else None


def publication_assets(record: dict, artifacts: list[Path]) -> list[Path]:
    pages = github_api(f"releases/{record['id']}/assets?per_page=100", paginate=True)
    assets = [asset for page in pages for asset in page]
    expected = {artifact.name: artifact for artifact in artifacts}
    names = [asset["name"] for asset in assets]
    if len(set(names)) != len(names) or set(names) - expected.keys():
        raise ValueError("Existing GitHub release has unexpected or duplicate assets")
    for asset in assets:
        artifact = expected[asset["name"]]
        if asset.get("state") != "uploaded" or asset.get("size") != artifact.stat().st_size or asset.get("digest") != f"sha256:{sha256(artifact)}":
            raise ValueError(f"Existing GitHub asset differs from the local artifact: {artifact.name}; refusing to overwrite")
    return [artifact for artifact in artifacts if artifact.name not in names]


def publish(directory: Path) -> None:
    metadata, dmg = verify_publication(directory)
    version, build, source = metadata["version"], metadata["build"], metadata["sourceCommit"]
    tag = f"macos-v{version}-build.{build}"
    title = f"CloudGateway for Mac {version} (build {build})"
    repository = json.loads(command("gh", "repo", "view", GITHUB_REPOSITORY, "--json", "isPrivate"))
    if repository.get("isPrivate") is not False:
        raise ValueError("GitHub repository must be public for the website's Mac download")
    remote_commit = github_api(f"commits/{source}", optional=True)
    if remote_commit is None or remote_commit.get("sha") != source:
        raise ValueError(f"Source commit {source} is absent from GitHub; publish it separately before retrying")
    target = github_tag_commit(tag)
    if target is not None and target != source:
        raise ValueError("Existing release tag points to a different source commit")
    record = github_release(tag)
    artifacts = [dmg, directory / "SHA256SUMS"]
    if record is not None:
        if record.get("name") != title or record.get("prerelease") or (
            target is None and (not record.get("draft") or record.get("target_commitish") != source)
        ):
            raise ValueError("Existing GitHub release does not match this release's title and source commit")
        missing = publication_assets(record, artifacts)
        if missing and not record.get("draft"):
            raise ValueError("Published GitHub release has missing assets; refusing to modify it")
    else:
        notes = directory / "github-release-notes.md"
        notes.write_text(
            f"CloudGateway {version} (build {build}) for Apple silicon, macOS 26 or later.\n\n"
            "Developer ID signed, notarized, and stapled. Drag CloudGateway into Applications to install.\n\n"
            f"Source commit: `{source}`\n"
            f"Working tree had local changes when archived: {str(bool(metadata.get('workingTreeDirty'))).lower()}.\n\n"
            "Verify the DMG against the attached SHA256SUMS file.\n"
        )
        command("gh", "release", "create", tag, "--repo", GITHUB_REPOSITORY,
                "--target", source, "--title", title, "--notes-file", str(notes), "--draft", "--latest=false")
        for attempt in range(4):
            record = github_release(tag)
            if record is not None:
                break
            if attempt < 3:
                time.sleep(1)
        if record is None:
            raise ValueError("Created GitHub draft is not visible yet; retry --publish-existing to resume it")
        if not record.get("draft") or record.get("target_commitish") != source:
            raise ValueError("Created GitHub draft does not match the source commit")
        missing = publication_assets(record, artifacts)
    if missing:
        command("gh", "release", "upload", tag, *(str(artifact) for artifact in missing), "--repo", GITHUB_REPOSITORY)
    if publication_assets(record, artifacts):
        raise ValueError("GitHub draft is missing release assets")
    if record.get("draft"):
        target = github_tag_commit(tag)
        if target is not None and target != source:
            raise ValueError("Release tag changed before publication")
        command("gh", "release", "edit", tag, "--repo", GITHUB_REPOSITORY, "--draft=false", "--latest=true")
    published = github_release(tag)
    if published is None or published.get("draft") or github_tag_commit(tag) != source:
        raise ValueError("GitHub publication could not be verified")
    if publication_assets(published, artifacts):
        raise ValueError("Published GitHub release is missing assets")
    url = f"https://github.com/{GITHUB_REPOSITORY}/releases/tag/{tag}"
    asset_url = f"https://github.com/{GITHUB_REPOSITORY}/releases/download/{tag}/{dmg.name}"
    write_json(directory / "publication.json", {
        "repository": GITHUB_REPOSITORY, "tag": tag, "sourceCommit": source,
        "releaseURL": url, "assetURL": asset_url, "sha256": sha256(dmg),
    })
    print(f"Published macOS release: {url}\nDMG download: {asset_url}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bump-build", action="store_true", help="increment and synchronize project versions without building or releasing")
    parser.add_argument("--build", type=int, help="shared build number override; defaults to the synchronized project build")
    parser.add_argument("--version", help="shared marketing version override, for example 1.1.1")
    parser.add_argument("--prepare-only", action="store_true", help="archive and verify without uploading to Apple")
    parser.add_argument("--notarize", type=Path, help="notarize or resume an existing prepared release directory")
    parser.add_argument("--recover-submission", help="record a confirmed app=<id> or dmg=<id> after an interrupted upload")
    parser.add_argument("--publish", action="store_true", help="publish the finished release to GitHub after notarizing")
    parser.add_argument("--publish-existing", type=Path, help="verify and publish an existing finished release without building or notarizing")
    parser.add_argument("--keychain-profile", default=os.environ.get("CLOUDGATEWAY_NOTARY_PROFILE", "CloudGateway-notary"))
    baseline_options = parser.add_mutually_exclusive_group()
    baseline_options.add_argument("--previous-distributed-app", type=Path,
                                  help="exact signed app from the latest distributed release, used as the extension baseline")
    baseline_options.add_argument("--initial-distribution", action="store_true",
                                  help="explicitly attest that no extension has been distributed before")
    args = parser.parse_args()
    if args.bump_build:
        if args.prepare_only or args.notarize or args.recover_submission or args.publish or args.publish_existing \
                or args.previous_distributed_app or args.initial_distribution:
            parser.error("--bump-build only accepts --build and --version")
        try:
            version, build = bump_project_versions(args.build, args.version)
        except (ValueError, OSError) as error:
            parser.error(str(error))
        print(f"App, CLI, controller, and extension: {version} ({build})")
        return
    if args.publish_existing is not None and (
        args.build is not None or args.version or args.prepare_only or args.notarize is not None
        or args.recover_submission or args.publish
    ):
        parser.error("--publish-existing cannot be combined with build/version/preparation/notarization options or --publish")
    if args.publish and args.prepare_only:
        parser.error("--publish cannot be combined with --prepare-only")
    if args.notarize is not None and (args.build is not None or args.version or args.prepare_only):
        parser.error("--notarize cannot be combined with build/version/preparation options")
    if args.build is not None and args.build <= 0:
        parser.error("provide a positive --build number")
    if args.recover_submission and args.notarize is None:
        parser.error("--recover-submission requires --notarize")
    if args.previous_distributed_app is not None or args.initial_distribution:
        if args.notarize is not None or args.publish_existing is not None:
            parser.error("extension baseline options apply only to new releases")
    elif args.notarize is None and args.publish_existing is None:
        parser.error("a new release requires --previous-distributed-app or --initial-distribution")
    existing = args.publish_existing or args.notarize
    directory = existing.resolve() if existing is not None else None
    try:
        if args.publish_existing is not None:
            publish(directory)
            return
        if directory is None:
            directory = prepare(args.build, args.version, args.keychain_profile,
                                args.previous_distributed_app, args.initial_distribution)
        if args.recover_submission:
            recover_submission(directory, args.recover_submission)
        if not args.prepare_only:
            finish(directory)
        if args.publish:
            publish(directory)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f"macOS release failed: {error}", flush=True)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.strip(), flush=True)
        if directory is not None:
            resume = "--publish-existing" if args.publish_existing is not None else "--notarize"
            publish_option = " --publish" if args.publish else ""
            print(f"Artifacts retained at {directory}\nResume: ./scripts/macos-release.sh {resume} '{directory}'{publish_option}", flush=True)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
