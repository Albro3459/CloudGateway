# Quick deployment

Run from the repository root with a clean working tree. Commands below may
publish artifacts, commit versions, or replace servers.

## Test

```sh
./scripts/test.sh
```

Targets: `web`, `api`, `firebase`, `infra`, `ios`, `macos`, `apple`, `linux`.
Targets and independent checks run concurrently, including unsigned iOS/macOS
pipelines. Add `--serial` for sequential execution. Live status appears in the
terminal; full worker logs are saved under `.deps/test-runs/`, with failed output
also printed. See [local test performance](../TODO/test-performance.md).

## Deploy the frontend

```sh
./scripts/deploy-react.sh
```

Builds, bumps the npm patch version, publishes to `gh-pages`, and commits locally.
Does not push source. [Details](../Frontend/Web/README.md#validation-and-deployment).

## Build iOS App Store archive

```sh
./scripts/ios-release.sh
```

Bumps the build, archives, exports, uploads, and commits locally without pushing.
Add `--version patch`, `minor`, or `major` to bump the marketing version.
[Signing and setup](../Frontend/Apple/iOS/README.md#app-store-release).

## Install macOS app for local testing

Let pending operations finish, then quit the menu app. The VPN stays running.
This bumps the build and replaces the app with a signed Development build.
It skips tests and leaves the build-number change uncommitted.

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
  fi
  ditto Frontend/Apple/macOS/.build/Xcode/Build/Products/Release/CloudGateway.app \
    /Applications/CloudGateway.app
)
```

Run `cloudgateway update` afterward. If replacement requires disconnecting an
active VPN, use `cloudgateway update --allow-disconnect`. Initial setup requires
GUI approvals. [Validation and recovery](apple-macos-development.md#local-replacement-and-mesh-validation-loop).

## Build and publish notarized macOS DMG

Requires Developer ID signing, saved notarization credentials, GitHub access,
and the source commit available remotely. Use the exact last distributed app
as the baseline:

```sh
python3 scripts/macos-release.py --bump-build
./scripts/macos-release.sh \
  --previous-distributed-app /absolute/path/to/latest-distributed/CloudGateway.app --publish
```

Omit `--publish` to keep artifacts local. To publish a finished release:

```sh
./scripts/macos-release.sh --publish-existing '/absolute/path/to/finished-release'
```

Publication verifies artifacts and never pushes source or overwrites assets.
Update `Frontend/Web/src/helpers/macAppRelease.ts` with the DMG version/build/URL,
then deploy the site. [Release guide](apple-macos-release.md).

## Build and publish Linux release

Configure `Frontend/Linux/Secrets/release.env` and commit source first.
[Setup](../Frontend/Linux/README.md#releases).

```sh
./scripts/test.sh linux
(
  cd Frontend/Linux
  go run ./cmd/cloudgateway-release build -version 1.0.0 \
    -out "$HOME/CloudGateway-linux-builds"
)
```

Writes ARM64/AMD64 archives and an installer with their SHA-256 hashes to
`$HOME/CloudGateway-linux-builds/linux-v1.0.0/`. Nothing is uploaded or committed.
Do not publish `-allow-dirty` builds or reuse an existing version.

Once the source commit is on GitHub, run the printed `gh release create` command.
Keep `--latest=false` to preserve the Mac release as Latest. Use `--prerelease`
only for test releases.

## Install Linux client

On Ubuntu 24.04 LTS ARM64 or AMD64, using a published release:

```sh
curl --proto '=https' --tlsv1.2 -fSLO https://github.com/Albro3459/CloudGateway/releases/download/linux-v1.0.0/install.sh
less install.sh
sudo bash install.sh --operator "$USER"
```

Starts and enables the daemon. Run the CLI as the enrolled user, without sudo.
Approve sign-in in a browser:

```sh
cloudgateway auth login
cloudgateway ls -l
cloudgateway up chicago 1
cloudgateway status
cloudgateway doctor
```

Use the row under Chicago, or a client UUID. To create a client:
`cloudgateway add chicago 'Ubuntu VM'`. To disconnect: `cloudgateway down`.

**Mesh is the default. Full is experimental on cloud VMs** and may need DHCP/DNS
changes. [Mode and cloud VM guide](linux-cli-routing.md).

Upgrade with the newer release's installer. `cloudgateway update` activates an
installed release; it does not download one. [Linux guide](../Frontend/Linux/README.md).
For [disposable test VMs](../Frontend/Linux/test-vm/README.md), remove test clients
before destroying the VM.

## Deploy regional servers

1. Commit source and make the intended ref available remotely.
2. Back up Firestore and confirm a new backup:

   ```sh
   Backend/API/.venv/bin/python3 scripts/backup_firestore.py
   ls -lh Backend/Firebase/backups
   ```

   Backups contain private configs/keys. Keep them outside Git and logs.
3. If Caddy inputs changed, run `./scripts/caddy-release.sh`. It can bump,
   commit, push, publish, and update local tfvars pins.
4. Review plans, then deploy:

   ```sh
   ./scripts/terraform.sh chicago sanjose plan
   ./scripts/terraform.sh chicago sanjose
   ```

Requires each region's gitignored tfvars. Plan is read-only. Apply commits and
pushes a deploy version/tag, updates tfvars, and applies saved plans in order.

**Apply replaces each selected server and changes its public IPv4.** Preserve
server private keys, subnets, and endpoint hostnames. Boot sync restores peers;
clients must re-resolve endpoints. A failure stops later regions.

For ACL/mesh changes, rebuild every affected region from the same tag; API-only
updates do not install host policy. Run **Sync All Regions** after deployment.
[Rollout](service-operations.md) · [Regional deployment](regional-deployment.md).

Destroy a region: `./scripts/terraform.sh chicago destroy`. Keep its subnet
registry allocation reserved.

### SSH host keys after replacement

Verify the new fingerprint through the OCI console before removing a stale key:

```sh
ssh-keygen -F wg.us-sanjose-1.gocloudlaunch.com
ssh-keygen -R wg.us-sanjose-1.gocloudlaunch.com
```

Repeat for each replaced hostname. Remove only the verified stale entry.
