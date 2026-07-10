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
KEY_ID="YDM2P5LSK8"
ISSUER_ID="9157d52e-3841-40de-8e45-fc74f01dfd2f"
KEY_PATH="${HOME}/.ssh/Apple_API_KEY/AuthKey_${KEY_ID}.p8"
ARCHIVE_ROOT="/private/tmp/CloudGatewayArchives"
SOURCE_DERIVED_DATA="$ARCHIVE_ROOT/SourceFirestoreDerivedData"
SOURCE_PACKAGES="$ARCHIVE_ROOT/SourceFirestorePackages"
VERSION_MODE=""
BACKUP=""
COMMITTED=0
RELEASE_METADATA=""

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

# Transporter discovers API keys from this standard directory. Use an isolated
# HOME so the release does not alter the user's normal Transporter credentials.
restore_project() {
  if [[ "$COMMITTED" -eq 0 && -n "$BACKUP" && -f "$BACKUP" ]]; then
    cp "$BACKUP" "$PBXPROJ"
  fi
}

cleanup() {
  restore_project
  if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
    trash "$BACKUP" >/dev/null 2>&1 || true
  fi
  if [[ -n "$RELEASE_METADATA" && -f "$RELEASE_METADATA" ]]; then
    trash "$RELEASE_METADATA" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

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

for match in reversed(app_configs):
    block = match.group(1)
    block = re.sub(
        r"(\n\s*CURRENT_PROJECT_VERSION = )\d+(;)",
        rf"\g<1>{new_build}\g<2>",
        block,
        count=1,
    )
    if mode:
        block = re.sub(
            r"(\n\s*MARKETING_VERSION = )[0-9]+\.[0-9]+\.[0-9]+(;)",
            rf"\g<1>{new_version}\g<2>",
            block,
            count=1,
        )
    text = text[:match.start()] + block + text[match.end():]
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
  <string>automatic</string>
  <key>teamID</key>
  <string>CRQWDQ7QQR</string>
</dict>
</plist>
EOF

echo "==> Bumping iOS version ${CURRENT_VERSION} (${CURRENT_BUILD}) to ${NEW_VERSION} (${NEW_BUILD})"
echo "==> Archiving with source Firestore"
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
"$TRANSPORTER" -m upload -jwt "$JWT" -assetFile "$IPA_PATH"

git -C "$ROOT" add "$PBXPROJ"
git -C "$ROOT" commit -m "Deploy iOS v${NEW_VERSION} (build ${NEW_BUILD})"
COMMITTED=1

echo "Published iOS v${NEW_VERSION} (build ${NEW_BUILD})"
echo "Archive: $ARCHIVE_PATH"
echo "IPA: $IPA_PATH"
