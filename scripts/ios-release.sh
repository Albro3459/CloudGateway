#!/usr/bin/env bash

# Bump, archive, export, and upload the production iOS app.
#
# Usage:
#   ./scripts/ios-release.sh
#   ./scripts/ios-release.sh --version patch|minor|major

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Frontend/Apple/iOS/CloudGateway.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"
RESOLVED="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
KEY_ID="YDM2P5LSK8"
ISSUER_ID="9157d52e-3841-40de-8e45-fc74f01dfd2f"
KEY_PATH="${HOME}/.ssh/Apple_API_KEY/AuthKey_${KEY_ID}.p8"
ARCHIVE_ROOT="/private/tmp/CloudGatewayArchives"
SOURCE_DERIVED_DATA="$ARCHIVE_ROOT/SourceFirestoreDerivedData"
SOURCE_PACKAGES="$ARCHIVE_ROOT/SourceFirestorePackages"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TEAM_ID="CRQWDQ7QQR"
VERSION_MODE=""
BACKUP=""
RESOLVED_BACKUP=""
COMMITTED=0
RELEASE_METADATA=""
AUTH_HOME=""

usage() {
  echo "usage: $0 [--version major|minor|patch]" >&2
}

if [[ $# -gt 0 ]]; then
  if [[ $# -ne 2 || "$1" != "--version" || ! "$2" =~ ^(major|minor|patch)$ ]]; then
    usage
    exit 2
  fi
  VERSION_MODE="$2"
fi

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "Working tree is not clean. Commit or stash changes before releasing." >&2
  git -C "$ROOT" status --short >&2
  exit 1
fi

if [[ ! -r "$KEY_PATH" ]]; then
  echo "Missing App Store Connect API key: $KEY_PATH" >&2
  exit 1
fi

if [[ "$(stat -f '%Lp' "$KEY_PATH")" != "600" ]]; then
  echo "App Store Connect API key must have mode 600: $KEY_PATH" >&2
  exit 1
fi

TRANSPORTER="$(xcrun --find iTMSTransporter 2>/dev/null || true)"
if [[ -z "$TRANSPORTER" && -x "/Applications/Transporter.app/Contents/itms/bin/iTMSTransporter" ]]; then
  TRANSPORTER="/Applications/Transporter.app/Contents/itms/bin/iTMSTransporter"
fi
if [[ -z "$TRANSPORTER" ]]; then
  echo "Unable to locate iTMSTransporter. Install Apple's Transporter app or expose it through xcrun." >&2
  exit 1
fi

restore_project() {
  if [[ "$COMMITTED" -eq 0 && -n "$BACKUP" && -f "$BACKUP" ]]; then
    cp "$BACKUP" "$PBXPROJ"
  fi
}

# The committed Package.resolved is only ever stashed for the source-Firestore
# archive (see below) and must always come back untouched, so unlike the
# project restore this is not gated on COMMITTED.
restore_resolved() {
  if [[ -n "$RESOLVED_BACKUP" && -f "$RESOLVED_BACKUP" ]]; then
    cp "$RESOLVED_BACKUP" "$RESOLVED"
  fi
}

cleanup() {
  restore_project
  restore_resolved
  if [[ -n "$AUTH_HOME" && -d "$AUTH_HOME" ]]; then
    trash "$AUTH_HOME" >/dev/null 2>&1 || true
  fi
  if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
    trash "$BACKUP" >/dev/null 2>&1 || true
  fi
  if [[ -n "$RESOLVED_BACKUP" && -f "$RESOLVED_BACKUP" ]]; then
    trash "$RESOLVED_BACKUP" >/dev/null 2>&1 || true
  fi
  if [[ -n "$RELEASE_METADATA" && -f "$RELEASE_METADATA" ]]; then
    trash "$RELEASE_METADATA" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

ensure_login_keychain_unlocked() {
  if security show-keychain-info "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
    return 0
  fi
  echo "==> Login keychain is locked; unlocking for code signing"
  # No -p flag: security prompts for the password interactively, so it is
  # never passed on the command line or left in shell history.
  if ! security unlock-keychain "$LOGIN_KEYCHAIN"; then
    echo "Failed to unlock the login keychain: $LOGIN_KEYCHAIN" >&2
    exit 1
  fi
}

check_distribution_identity() {
  # App Store export needs an Apple Distribution signing identity for the release
  # team in the login keychain. Probing here fails in seconds instead of after
  # the full archive build, which is the only later step that needs it.
  if security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" |
      grep -Eq "\"(Apple|iPhone) Distribution: .*\($TEAM_ID\)\""; then
    return 0
  fi
  echo "No Apple Distribution signing identity for team $TEAM_ID was found in the login keychain." >&2
  echo "Create one in Xcode: Settings > Accounts > Manage Certificates > + > Apple Distribution (team $TEAM_ID), then re-run." >&2
  echo "List what is installed with:" >&2
  echo "  security find-identity -v -p codesigning" >&2
  exit 1
}

JWT="$(python3 - "$KEY_PATH" "$KEY_ID" "$ISSUER_ID" <<'PY'
import base64
import json
import os
import subprocess
import sys
import tempfile
import time

key_path, key_id, issuer_id = sys.argv[1:]

def encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")

header = encode(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
now = int(time.time())
payload = encode(json.dumps({
    "iss": issuer_id,
    "iat": now,
    "exp": now + 1200,
    "aud": "appstoreconnect-v1",
}, separators=(",", ":")).encode())
signing_input = f"{header}.{payload}".encode()

with tempfile.TemporaryDirectory(prefix="cloudgateway-asc-") as directory:
    input_path = os.path.join(directory, "input")
    signature_path = os.path.join(directory, "signature.der")
    with open(input_path, "wb") as handle:
        handle.write(signing_input)
    subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path, "-out", signature_path, input_path],
        check=True,
    )
    signature = open(signature_path, "rb").read()

def der_length(data, offset):
    length = data[offset]
    offset += 1
    if length & 0x80:
        count = length & 0x7f
        length = int.from_bytes(data[offset:offset + count], "big")
        offset += count
    return length, offset

if signature[0] != 0x30:
    raise SystemExit("unexpected ECDSA signature format")
_, offset = der_length(signature, 1)
if signature[offset] != 0x02:
    raise SystemExit("missing ECDSA r value")
r_length, offset = der_length(signature, offset + 1)
r = signature[offset:offset + r_length]
offset += r_length
if signature[offset] != 0x02:
    raise SystemExit("missing ECDSA s value")
s_length, offset = der_length(signature, offset + 1)
s = signature[offset:offset + s_length]
r = r.lstrip(b"\0").rjust(32, b"\0")
s = s.lstrip(b"\0").rjust(32, b"\0")
if len(r) != 32 or len(s) != 32:
    raise SystemExit("unexpected ECDSA signature length")
print(f"{header}.{payload}.{encode(r + s)}")
PY
)"

echo "==> Validating App Store Connect API key"
curl --fail --silent --show-error --output /dev/null \
  -H "Authorization: Bearer $JWT" \
  "https://api.appstoreconnect.apple.com/v1/apps?filter%5BbundleId%5D=com.gocloudlaunch.gateway"

echo "==> Ensuring login keychain is unlocked for code signing"
ensure_login_keychain_unlocked

echo "==> Checking for an App Store distribution certificate"
check_distribution_identity

mkdir -p "$ARCHIVE_ROOT" "$SOURCE_DERIVED_DATA" "$SOURCE_PACKAGES"
BACKUP="$(mktemp /private/tmp/CloudGatewayProject.XXXXXX)"
RELEASE_METADATA="$(mktemp /private/tmp/CloudGatewayRelease.XXXXXX)"
cp "$PBXPROJ" "$BACKUP"

if ! python3 - "$PBXPROJ" "$VERSION_MODE" > "$RELEASE_METADATA" <<'PY'
import re
import sys

path, mode = sys.argv[1:]
text = open(path, encoding="utf-8").read()

config_pattern = re.compile(
    r"(\n\t\t[0-9A-F]+ /\* [^\n]+ = \{\n\t\t\tisa = XCBuildConfiguration;.*?\n\t\t\};)",
    re.DOTALL,
)
configs = list(config_pattern.finditer(text))
app_configs = [match for match in configs if "PRODUCT_BUNDLE_IDENTIFIER = com.gocloudlaunch.gateway;" in match.group(1)]
if len(app_configs) != 2:
    raise SystemExit("expected exactly two CloudGateway app build configurations")

app_builds = re.findall(r"\n\s*CURRENT_PROJECT_VERSION = (\d+);", "".join(match.group(1) for match in app_configs))
app_versions = re.findall(r"\n\s*MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+);", "".join(match.group(1) for match in app_configs))
if len(app_builds) != 2 or len(set(app_builds)) != 1:
    raise SystemExit("expected matching app build settings")
if len(app_versions) != 2 or len(set(app_versions)) != 1:
    raise SystemExit("expected matching app marketing versions")
current_build = int(app_builds[0])
current_version = app_versions[0]
major, minor, patch = map(int, current_version.split("."))
if mode == "major":
    major, minor, patch = major + 1, 0, 0
elif mode == "minor":
    minor, patch = minor + 1, 0
elif mode == "patch":
    patch += 1
new_version = f"{major}.{minor}.{patch}" if mode else current_version
new_build = current_build + 1

# Bump every target that declares a version (app, packet-tunnel extension, and
# screenshots) in lockstep. App Store Connect rejects an upload whose embedded
# binaries carry a different CFBundleVersion than the containing app, so the
# build number must move on all of them together. The marketing version only
# moves when --version was passed.
all_builds = re.findall(r"\n\s*CURRENT_PROJECT_VERSION = (\d+);", text)
if len(set(all_builds)) != 1 or all_builds[0] != str(current_build):
    raise SystemExit(
        "target build numbers are out of sync; align every "
        "CURRENT_PROJECT_VERSION before releasing"
    )
text = re.sub(
    r"(\n\s*CURRENT_PROJECT_VERSION = )\d+(;)",
    rf"\g<1>{new_build}\g<2>",
    text,
)
if mode:
    all_versions = re.findall(r"\n\s*MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+);", text)
    if (
        len(all_versions) != len(all_builds)
        or len(set(all_versions)) != 1
        or all_versions[0] != current_version
    ):
        raise SystemExit(
            "target marketing versions are out of sync; align every "
            "MARKETING_VERSION before releasing"
        )
    text = re.sub(
        r"(\n\s*MARKETING_VERSION = )[0-9]+\.[0-9]+\.[0-9]+(;)",
        rf"\g<1>{new_version}\g<2>",
        text,
    )
open(path, "w", encoding="utf-8").write(text)
print(current_version, current_build, new_version, new_build)
PY
then
  exit 1
fi
read -r CURRENT_VERSION CURRENT_BUILD NEW_VERSION NEW_BUILD < "$RELEASE_METADATA"

ARCHIVE_PATH="$ARCHIVE_ROOT/CloudGateway-${NEW_VERSION}-${NEW_BUILD}.xcarchive"
EXPORT_PATH="$ARCHIVE_ROOT/CloudGateway-${NEW_VERSION}-${NEW_BUILD}"
EXPORT_OPTIONS="$ARCHIVE_ROOT/ExportOptions-${NEW_VERSION}-${NEW_BUILD}.plist"

cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
  <key>signingCertificate</key>
  <string>Apple Distribution</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>com.gocloudlaunch.gateway</key>
    <string>CloudGateway AppStore</string>
    <key>com.gocloudlaunch.gateway.tunnel</key>
    <string>CloudGateway Tunnel AppStore</string>
  </dict>
</dict>
</plist>
EOF

echo "==> Bumping iOS version ${CURRENT_VERSION} (${CURRENT_BUILD}) to ${NEW_VERSION} (${NEW_BUILD})"
echo "==> Archiving with source Firestore"
# The committed Package.resolved pins Firestore's default *binary* gRPC
# distribution (grpc-binary). A source-Firestore archive resolves a different
# graph (grpc-ios and its abseil/BoringSSL/nanopb source deps); Xcode's IDE
# package-graph loader crashes reconciling the binary pins against that source
# graph (`-[NSMutableArray insertObjects:atIndexes:]` count mismatch, seen on
# Xcode 26.5). Stash the committed resolution so the archive resolves its own
# consistent source graph, and restore it before the upload guard inspects the
# tree. The cleanup trap restores it too if the archive aborts.
RESOLVED_BACKUP="$(mktemp /private/tmp/CloudGatewayResolved.XXXXXX)"
mv "$RESOLVED" "$RESOLVED_BACKUP"
FIREBASE_SOURCE_FIRESTORE=1 CLOUDGATEWAY_SOURCE_PACKAGES_DIR="$SOURCE_PACKAGES" \
  xcodebuild \
    -project "$PROJECT" \
    -scheme CloudGateway \
    -destination generic/platform=iOS \
    -configuration Release \
    -derivedDataPath "$SOURCE_DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    -archivePath "$ARCHIVE_PATH" \
    archive
restore_resolved

echo "==> Exporting IPA"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_PATH"

IPA_PATH="$EXPORT_PATH/CloudGateway.ipa"
if [[ ! -f "$IPA_PATH" ]]; then
  echo "Expected exported IPA was not created: $IPA_PATH" >&2
  exit 1
fi

if [[ "$(git -C "$ROOT" status --porcelain)" != " M Frontend/Apple/iOS/CloudGateway.xcodeproj/project.pbxproj" ]]; then
  echo "Archive changed files other than the intended project build settings; refusing to upload." >&2
  git -C "$ROOT" status --short >&2
  exit 1
fi

echo "==> Uploading IPA"
# Transporter discovers API keys from a private_keys directory under its
# working directory. Run from a temp copy so the user's normal Transporter
# credentials are untouched.
AUTH_HOME="$(mktemp -d /private/tmp/CloudGatewayTransporter.XXXXXX)"
mkdir -p "$AUTH_HOME/private_keys"
cp "$KEY_PATH" "$AUTH_HOME/private_keys/AuthKey_${KEY_ID}.p8"
chmod 600 "$AUTH_HOME/private_keys/AuthKey_${KEY_ID}.p8"
UPLOAD_LOG="$ARCHIVE_ROOT/upload-${NEW_VERSION}-${NEW_BUILD}.log"
set +e
(
  cd "$AUTH_HOME"
  "$TRANSPORTER" -m upload \
    -apiIssuer "$ISSUER_ID" \
    -apiKey "$KEY_ID" \
    -assetFile "$IPA_PATH"
) 2>&1 | tee "$UPLOAD_LOG"
UPLOAD_STATUS=${PIPESTATUS[0]}
set -e

if [[ "$UPLOAD_STATUS" -ne 0 ]]; then
  echo "Upload failed: iTMSTransporter exited $UPLOAD_STATUS. Nothing committed. See $UPLOAD_LOG" >&2
  exit 1
fi
# iTMSTransporter can exit 0 while still reporting a server-side validation or
# delivery failure, so scan the captured output before trusting the upload.
# Real rejections carry an ITMS code or an explicit failure summary.
if grep -qE 'ITMS-[0-9]+|VALIDATION_ERROR|Validation failed|The upload failed|packages? (was|were) not uploaded' "$UPLOAD_LOG"; then
  echo "Upload reported a delivery or validation failure. Nothing committed. See $UPLOAD_LOG" >&2
  exit 1
fi
# Require Transporter's package summary and its explicit success sentinel so a
# truncated/hung run cannot pass as delivered.
if ! grep -qE '[0-9]+ packages? (was|were) uploaded successfully' "$UPLOAD_LOG"; then
  echo "Upload did not report a delivered package. Nothing committed. See $UPLOAD_LOG" >&2
  exit 1
fi
if ! grep -qE 'Returning 0' "$UPLOAD_LOG"; then
  echo "Upload did not report a success sentinel. Nothing committed. See $UPLOAD_LOG" >&2
  exit 1
fi
# Transporter prints that summary only after the reservation is committed, and
# its upload workers can throw afterwards on a delivered package (the known
# "eTags cannot be empty" race). Those lines are worth seeing but no longer
# condemn a delivery the server already accepted.
if grep -qE 'ERROR:' "$UPLOAD_LOG"; then
  echo "Note: Transporter logged errors after committing the delivery; see $UPLOAD_LOG" >&2
  grep -E 'ERROR:' "$UPLOAD_LOG" >&2
fi

git -C "$ROOT" add "$PBXPROJ"
git -C "$ROOT" commit -m "Deploy iOS v${NEW_VERSION} (build ${NEW_BUILD})"
COMMITTED=1

echo "Published iOS v${NEW_VERSION} (build ${NEW_BUILD})"
echo "Archive: $ARCHIVE_PATH"
echo "IPA: $IPA_PATH"
