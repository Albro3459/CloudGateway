# Quick deployment

Run from the repository root. These commands can publish artifacts, commit
version changes, or replace servers as described below. Keep the working tree
clean before release wrappers. See the [docs index](README.md) for setup and
recovery guides.

## Test

Run the full suite before deploying:

```sh
./scripts/test.sh
```

Use `web`, `api`, `firebase`, `infra`, `ios`, `macos`, or `apple` for targeted
checks during development.

## Deploy the frontend

```sh
./scripts/deploy-react.sh
```

Builds the local checkout, bumps the npm patch version, publishes to `gh-pages`,
and commits the version change locally. It does not push the source commit.
See [web deployment](../Frontend/Web/README.md#validation-and-deployment).

## Build iOS App Store archive

```sh
./scripts/ios-release.sh
```

Add `--version patch`, `minor`, or `major` to change the marketing version.
Every run bumps the build. The script archives with source Firestore, exports,
uploads through Transporter, and commits the version change without pushing.
It requires the configured API key, distribution identity/profiles, and access
to the login Keychain. See the
[iOS release guide](../Frontend/Apple/iOS/README.md#app-store-release) for setup,
profile renewal, and manual archives.

## Install macOS app for local testing

Run from the repository root. This bumps the shared app, CLI, controller, and
extension build number, builds and verifies the signed Release bundle with Apple
Development signing, and replaces `/Applications/CloudGateway.app`. It skips tests
and dead-code scans. The build bump edits the tracked project file without staging
or committing it.

For a live validation session, let pending controller/extension work finish and
quit the menu app normally before running this command. No fixed 60-second wait
is required. Quitting leaves the controller and VPN running; verify handoff and
readiness after replacement using the
[local replacement and mesh validation loop](apple-macos-development.md#local-replacement-and-mesh-validation-loop)
for update, identity checks, and routing tests.

```sh
(
  set -e
  python3 scripts/macos-release.py --bump-build
  xcodebuild -project Frontend/Apple/macOS/CloudGateway.xcodeproj \
    -scheme CloudGateway -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath Frontend/Apple/macOS/.build/Xcode \
    ARCHS=arm64 -allowProvisioningUpdates build
  python3 scripts/verify_macos_build.py \
    Frontend/Apple/macOS/.build/Xcode/Build/Products/Release/CloudGateway.app --signed --cli-smoke
  if [ -e /Applications/CloudGateway.app ]; then
    trash /Applications/CloudGateway.app
    echo "Trashed previous app"
  fi
  ditto Frontend/Apple/macOS/.build/Xcode/Build/Products/Release/CloudGateway.app \
    /Applications/CloudGateway.app
)
```

After installation, run `cloudgateway update` to reconcile the running VPN
extension with the installed bundle. If a VPN is active and replacement is needed,
use `cloudgateway update --allow-disconnect` to authorize stop/update/reconnect.
Initial setup and Apple approvals still require the GUI. Keep the printed operation
ID for lookup if SSH disconnects.

See the [macOS controller runbook](apple-macos-development.md#controller-and-frontends)
for controller handoff, and the [release guide](apple-macos-release.md#version-and-artifact-policy)
for versioning rules.

## Build and publish notarized macOS DMG

```sh
python3 scripts/macos-release.py --bump-build
./scripts/macos-release.sh \
  --previous-distributed-app /absolute/path/to/latest-distributed/CloudGateway.app --publish
```

The baseline must be the exact signed app last distributed to users. Every new
preparation needs a higher synchronized build, including app-only releases.
Omit `--publish` to retain local artifacts for installation checks.

Publish an existing finished release:

```sh
./scripts/macos-release.sh --publish-existing '/absolute/path/to/finished-release'
```

Requires Developer ID profiles/identity, saved notarization credentials, and
GitHub release access with the recorded source commit already online. Publication
verifies the existing artifacts/checksums and never pushes source or overwrites
assets. Update `Frontend/Web/src/helpers/macAppRelease.ts` with the exact new
DMG version/build/URL, then deploy the site. See the
[macOS release guide](apple-macos-release.md) for preparation, retries, and checks.

## Deploy regional servers

1. Review/commit source and make the intended ref available remotely.
2. Back up Firestore and confirm a new backup exists:

   ```sh
   Backend/API/.venv/bin/python3 scripts/backup_firestore.py
   ls -lh Backend/Firebase/backups
   ```

   Backups can contain full VPN configs/private keys. Keep them outside Git/logs.
3. If Caddy build inputs changed, run `./scripts/caddy-release.sh`. It can bump
   `Infrastructure/OCI/caddy/VERSION`, commit it, and push the current branch.
   It publishes a `caddy-v<x>` release and updates the configured gitignored
   regional tfvars pins/checksums. Otherwise keep the verified existing binary.
4. Review plans, then deploy the intended regions:

   ```sh
   ./scripts/terraform.sh chicago sanjose plan
   ./scripts/terraform.sh chicago sanjose
   ```

The wrapper accepts short names or full IDs and requires each region's
gitignored `Infrastructure/OCI/terraform/<regionId>.terraform.tfvars`. Plan does
not create a deploy tag or change infrastructure. Apply creates a version commit,
pushes the source branch and deploy tag, updates the selected tfvars, and applies
saved plans sequentially from that same tag.

**Apply replaces each selected VPN server and changes its public IPv4.** A fresh
`source_ref` changes immutable OCI user data. Keep the server private key,
subnets, and endpoint hostname unchanged; boot sync restores Firebase peers,
and clients must re-resolve the updated endpoint. A partial failure stops later
regions while retaining already-applied regions.

Host-level ACL/mesh changes require rebuilding every affected region from the
same deploy tag. API-only installation cannot install the host policy; fleet-wide
account isolation is incomplete until every region is ready. After deployment,
run **Sync All Regions** in Server Health. See the
[rollout runbook](service-operations.md) and [regional deployment guide](regional-deployment.md).

`./scripts/terraform.sh chicago destroy` tears down that region using Terraform's
confirmation. Keep its subnet registry allocation reserved.

### SSH host keys after replacement

A rebuilt host has a new SSH key. Verify its fingerprint through a trusted OCI
console/access path before removing the old hostname entry from `~/.ssh/known_hosts`:

```sh
ssh-keygen -F wg.us-sanjose-1.gocloudlaunch.com
ssh-keygen -R wg.us-sanjose-1.gocloudlaunch.com
```

Repeat for each replaced hostname. Remove only the verified stale entry.
