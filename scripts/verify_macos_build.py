"""Inspect built macOS products without activating extensions or changing VPN state."""

import argparse
import datetime
import json
import os
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path

APP_ID = "com.gocloudlaunch.gateway.macos"
EXTENSION_ID = "com.gocloudlaunch.gateway.tunnel.macos"
APP_GROUP = "group.com.gocloudlaunch.gateway.macos"
TEAM_ID = "CRQWDQ7QQR"
SYSTEM_LIBRARY_ROOTS = ("/System/Library/", "/usr/lib/")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def command(*args: str) -> subprocess.CompletedProcess:
    result = subprocess.run(args, capture_output=True, check=False)
    require(result.returncode == 0, f"{Path(args[0]).name} validation failed")
    return result


def read_plist(path: Path) -> dict:
    with path.open("rb") as stream:
        return plistlib.load(stream)


def is_system_library(path: str) -> bool:
    return path.startswith(SYSTEM_LIBRARY_ROOTS)


def parse_rpaths(output: str) -> list[str]:
    return re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)", output)


def parse_dependencies(output: str) -> list[str]:
    return [line.strip().split(" (", 1)[0] for line in output.splitlines()[1:] if line.strip()]


def expand_local_path(value: str, binary: Path, executable: Path) -> Path | None:
    for token, base in [("@executable_path", executable.parent), ("@loader_path", binary.parent)]:
        if value == token or value.startswith(token + "/"):
            return (base / value[len(token):].lstrip("/")).resolve()
    return None


def verify_dynamic_paths(
    binary: Path, bundle: Path, executable: Path, dependencies: list[str], rpaths: list[str]
) -> list[Path]:
    bundle = bundle.resolve()
    search_paths: list[Path] = []
    for value in rpaths:
        is_build_path = "DerivedData" in value or "/.build/" in value
        is_unused_package_path = (
            is_build_path
            and re.search(r"/Build/Products/(Debug|Release|DeveloperID)/PackageFrameworks$", value) is not None
            and all(is_system_library(dependency) for dependency in dependencies)
        )
        if is_unused_package_path:
            print("Unused Xcode PackageFrameworks search path has no dynamic-library consumers")
            continue
        require(not is_build_path, "A runtime search path references a build directory")
        if is_system_library(value):
            search_paths.append(Path(value))
            continue
        resolved = expand_local_path(value, binary, executable)
        require(resolved is not None and resolved.is_relative_to(bundle),
                "A runtime search path leaves its own bundle")
        search_paths.append(resolved)

    bundled_dependencies: list[Path] = []
    for value in dependencies:
        if is_system_library(value):
            continue
        require("DerivedData" not in value and "/.build/" not in value,
                "A dynamic library references a build directory")
        if value.startswith("@rpath/"):
            candidates = [directory / value[len("@rpath/"):] for directory in search_paths]
        else:
            resolved = expand_local_path(value, binary, executable)
            require(resolved is not None, "A non-system dynamic library uses an absolute or unsupported path")
            candidates = [resolved]
        found = next((path.resolve() for path in candidates if path.is_file()), None)
        require(found is not None and found.is_relative_to(bundle),
                "A dynamic library is missing from its own bundle")
        bundled_dependencies.append(found)
    return bundled_dependencies


def verify_dynamic_libraries(executable: Path, bundle: Path) -> None:
    pending = [executable]
    checked: set[Path] = set()
    while pending:
        binary = pending.pop().resolve()
        if binary in checked:
            continue
        checked.add(binary)
        dependencies = parse_dependencies(command("/usr/bin/otool", "-L", str(binary)).stdout.decode())
        rpaths = parse_rpaths(command("/usr/bin/otool", "-l", str(binary)).stdout.decode())
        pending.extend(verify_dynamic_paths(binary, bundle, executable, dependencies, rpaths))


def verify_entitlements(entitlements: dict, is_extension: bool, developer_id: bool = False) -> None:
    require(entitlements.get("com.apple.developer.team-identifier") == TEAM_ID, "Signing team mismatch")
    require(entitlements.get("com.apple.security.application-groups") == [APP_GROUP], "App Group mismatch")
    tunnel_capability = "packet-tunnel-provider-systemextension" if developer_id else "packet-tunnel-provider"
    require(entitlements.get("com.apple.developer.networking.networkextension") == [tunnel_capability],
            "Network Extension entitlement does not match the distribution channel")
    if developer_id:
        require(not entitlements.get("com.apple.security.get-task-allow") and not entitlements.get("get-task-allow"),
                "Developer ID signature must not allow debugging")
    require(entitlements.get("com.apple.security.app-sandbox", False) == is_extension,
            "App/extension sandbox boundary mismatch")
    if is_extension:
        require(entitlements.get("com.apple.security.network.client") is True,
                "Extension client networking entitlement missing")
        require(entitlements.get("com.apple.security.network.server") is True,
                "Extension server networking entitlement missing")
        require("keychain-access-groups" not in entitlements, "Extension must not share user Keychain")
    else:
        require(entitlements.get("com.apple.developer.system-extension.install") is True,
                "System Extension installation entitlement missing")
        require(entitlements.get("keychain-access-groups") == [f"{TEAM_ID}.{APP_ID}"],
                "Firebase session Keychain access group mismatch")


def verify_profile(
    profile: dict, bundle_id: str, is_extension: bool, now: datetime.datetime, developer_id: bool = False
) -> None:
    expiration = profile.get("ExpirationDate")
    require(isinstance(expiration, datetime.datetime), "Profile expiration missing")
    require(expiration.replace(tzinfo=datetime.timezone.utc) > now, "Provisioning profile has expired")
    entitlements = profile.get("Entitlements", {})
    require(entitlements.get("com.apple.developer.team-identifier") == TEAM_ID,
            "Profile signing team mismatch")
    require(entitlements.get("com.apple.application-identifier") == f"{TEAM_ID}.{bundle_id}",
            "Profile app identifier mismatch")
    require(APP_GROUP in entitlements.get("com.apple.security.application-groups", []),
            "Profile lacks registered macOS App Group")
    tunnel_capability = "packet-tunnel-provider-systemextension" if developer_id else "packet-tunnel-provider"
    require(tunnel_capability in entitlements.get(
        "com.apple.developer.networking.networkextension", []), "Profile lacks the distribution channel's tunnel capability")
    if developer_id:
        require(profile.get("ProvisionsAllDevices") is True, "Developer ID profile must provision all devices")
        require(not entitlements.get("com.apple.security.get-task-allow") and not entitlements.get("get-task-allow"),
                "Developer ID profile must not allow debugging")
    if not is_extension:
        require(entitlements.get("com.apple.developer.system-extension.install") is True,
                "Profile lacks System Extension installation capability")
        groups = entitlements.get("keychain-access-groups", [])
        require(f"{TEAM_ID}.{APP_ID}" in groups or f"{TEAM_ID}.*" in groups,
                "Profile does not authorize the session Keychain group")


def verify_signature(bundle: Path, bundle_id: str, is_extension: bool, developer_id: bool = False) -> None:
    verification_args = ["/usr/bin/codesign", "--verify", "--strict"]
    if developer_id:
        verification_args.extend([
            "--test-requirement",
            '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists '
            f'and certificate leaf[subject.OU] = "{TEAM_ID}"',
        ])
    command(*verification_args, str(bundle))
    metadata = command("/usr/bin/codesign", "--display", "--verbose=4", str(bundle)).stderr.decode()
    require(re.search(r"flags=0x[0-9a-f]+\([^)]*runtime", metadata) is not None,
            "Hardened Runtime signature flag missing")
    if developer_id:
        authorities = re.findall(r"^Authority=(.+)$", metadata, re.MULTILINE)
        require(bool(authorities) and re.fullmatch(
            rf"Developer ID Application: .+ \({TEAM_ID}\)", authorities[0]
        ) is not None, "Developer ID Application signing authority mismatch")
        require(re.search(rf"^TeamIdentifier={TEAM_ID}$", metadata, re.MULTILINE) is not None,
                "Developer ID signing team mismatch")
        require(re.search(rf"^Identifier={re.escape(bundle_id)}$", metadata, re.MULTILINE) is not None,
                "Developer ID signed identifier mismatch")
        require(re.search(r"^Timestamp=\S.+$", metadata, re.MULTILINE) is not None,
                "Developer ID secure timestamp missing")
    entitlements = plistlib.loads(command(
        "/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(bundle)
    ).stdout)
    verify_entitlements(entitlements, is_extension, developer_id)
    profile_path = bundle / "Contents" / "embedded.provisionprofile"
    require(profile_path.is_file(), "Embedded provisioning profile missing")
    profile = plistlib.loads(command("/usr/bin/security", "cms", "-D", "-i", str(profile_path)).stdout)
    verify_profile(profile, bundle_id, is_extension, datetime.datetime.now(datetime.timezone.utc), developer_id)


def verify_bundle(app: Path, signed: bool, developer_id: bool = False) -> None:
    signed = signed or developer_id
    extension = app / "Contents" / "Library" / "SystemExtensions" / f"{EXTENSION_ID}.systemextension"
    require(list(app.glob("**/*.systemextension")) == [extension], "Unexpected or duplicate system extension embedding")
    app_info = read_plist(app / "Contents" / "Info.plist")
    extension_info = read_plist(extension / "Contents" / "Info.plist")
    require(app_info.get("CFBundleIdentifier") == APP_ID, "App identifier mismatch")
    require(app_info.get("LSUIElement") is True, "Menu app must be an LSUIElement agent")
    require(extension_info.get("CFBundleIdentifier") == EXTENSION_ID, "Extension identifier mismatch")
    require("NSExtension" not in extension_info, "System extension has app-extension metadata")
    usage_description = extension_info.get("NSSystemExtensionUsageDescription")
    require(isinstance(usage_description, str) and bool(usage_description.strip()),
            "System extension usage description missing or invalid")
    network = extension_info.get("NetworkExtension", {})
    build = extension_info.get("CFBundleVersion")
    require(isinstance(build, str) and len(build) <= 64 and re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", build),
            "Extension build missing or invalid")
    require(network.get("NEMachServiceName") == f"{APP_GROUP}.tunnel.{build}", "Mach service mismatch")
    require(network.get("NEProviderClasses") == {
        "com.apple.networkextension.packet-tunnel": "CloudGatewayTunnel.PacketTunnelProvider"
    }, "Packet provider class mapping mismatch")
    for bundle, info in [(app, app_info), (extension, extension_info)]:
        require(info.get("LSMinimumSystemVersion") == "26.0", "macOS deployment floor mismatch")
        require(info.get("CloudGatewayTeamIdentifier") == TEAM_ID, "Built peer identity team metadata mismatch")
        binary = bundle / "Contents" / "MacOS" / info["CFBundleExecutable"]
        archs = command("/usr/bin/lipo", "-archs", str(binary)).stdout.decode().split()
        require(archs == ["arm64"], "Built product must contain only arm64")
        verify_dynamic_libraries(binary, bundle)
    if signed:
        verify_signature(app, APP_ID, False, developer_id)
        verify_signature(extension, EXTENSION_ID, True, developer_id)
    print("macOS packaging verified; dynamic dependencies resolve inside each bundle or the OS")
    if signed:
        print("Signed entitlements, profiles, and Hardened Runtime verified")


def verify_cli(app: Path) -> None:
    info = read_plist(app / "Contents/Info.plist")
    require(info.get("CFBundleExecutable") == "CloudGateway", "CLI requires the bundled CloudGateway executable")
    executable = (app / "Contents/MacOS/CloudGateway").absolute()
    require(executable.is_file() and os.access(executable, os.X_OK), "CLI executable missing or not executable")
    resources = app / "Contents/Resources"
    require((resources / "GoogleService-Info.plist").is_file(), "Controller Firebase resource missing")
    require(isinstance(read_plist(resources / "GoogleService-Info.plist"), dict), "Controller Firebase resource invalid")
    cases = [
        ([], 0, "help", False),
        (["--help"], 0, "help", False),
        (["help", "auth", "login"], 0, "help", False),
        (["--version"], 0, "version", False),
        (["--json"], 0, "help", True),
        (["help", "doctor", "--json"], 0, "help", True),
        (["--version", "--json"], 0, "version", True),
        (["--unknown-option"], 2, None, False),
        (["auth", "login", "--timeout", "0", "--json"], 2, "auth login", True),
        (["status", "--unexpected", "--json"], 2, "status", True),
    ]
    with tempfile.TemporaryDirectory(prefix="cloudgateway-cli-smoke-") as directory:
        root = Path(directory)
        home = root / "home"
        home.mkdir()
        link = root / "cloudgateway"
        link.symlink_to(executable)
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home),
                       "CFFIXED_USER_HOME": str(home), "TMPDIR": str(root), "TERM": "dumb", "NO_COLOR": "1"}
        for invocation in ([str(executable), "--cli"], [str(link)]):
            for arguments, expected_exit, expected_command, is_json in cases:
                try:
                    result = subprocess.run(invocation + arguments, capture_output=True, check=False,
                                            timeout=5, env=environment, cwd=root, stdin=subprocess.DEVNULL)
                except subprocess.TimeoutExpired:
                    raise ValueError("Packaged CLI static command exceeded its five-second deadline") from None
                require(result.returncode == expected_exit, "Packaged CLI static command returned an unexpected exit")
                require(b"\x1b" not in result.stdout + result.stderr, "Redirected CLI output contains terminal escapes")
                if is_json:
                    require(result.stderr == b"", "Packaged CLI JSON command wrote unexpected diagnostics")
                    require(result.stdout.endswith(b"\n") and len(result.stdout.splitlines()) == 1,
                            "Packaged CLI JSON must be one complete newline-terminated record")
                    try:
                        record = json.loads(result.stdout)
                    except (ValueError, UnicodeDecodeError):
                        raise ValueError("Packaged CLI JSON is invalid") from None
                    require(isinstance(record, dict) and record.get("schemaVersion") == 1,
                            "Packaged CLI JSON schema mismatch")
                    require(record.get("command") == expected_command, "Packaged CLI command mismatch")
                    require(record.get("type") == ("result" if expected_exit == 0 else "error"),
                            "Packaged CLI result type mismatch")
                    require(record.get("operationId") is None, "Static CLI output must not accept an operation")
                    if expected_exit:
                        require(isinstance(record.get("error"), dict) and record["error"].get("code") == "usage",
                                "Packaged CLI usage code mismatch")
                    elif expected_command == "version":
                        require(record.get("data") == {"version": info.get("CFBundleShortVersionString"),
                                                      "build": info.get("CFBundleVersion")},
                                "CLI version does not match its bundle, including through a symlink")
                    else:
                        require(isinstance(record.get("data"), dict) and "usage" in record["data"],
                                "Packaged CLI help is missing")
                elif expected_exit == 0:
                    require(bool(result.stdout) and result.stderr == b"", "Packaged CLI static output missing")
                else:
                    require(result.stdout == b"" and bool(result.stderr), "CLI usage diagnostics must use stderr")
        require(not list(home.iterdir()), "Static CLI commands wrote user state")
    print("20 bounded packaged CLI direct/symlink help, version, and usage checks passed")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--signed", action="store_true")
    parser.add_argument("--developer-id", action="store_true", help="Verify Developer ID release signing (implies --signed)")
    parser.add_argument("--cli-smoke", action="store_true", help="Check current CLI resources and run bounded static commands")
    args = parser.parse_args()
    try:
        verify_bundle(args.app, args.signed, args.developer_id)
        if args.cli_smoke:
            verify_cli(args.app)
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        raise SystemExit(f"macOS verification failed: {error}") from None


if __name__ == "__main__":
    main()
