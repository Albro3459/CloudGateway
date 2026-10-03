# macOS release deployment

CloudGateway distributes directly as a Developer ID-signed, notarized DMG for
Apple silicon on macOS 26 or later. Run the release command from the repository
root after the required validation passes:

```sh
./scripts/test.sh macos
./scripts/macos-release.sh --build 2
```

Choose a build number higher than the project and every previous distributed
release. `--build` applies to both the app and extension. The marketing version
comes from the project unless supplied explicitly:

```sh
./scripts/macos-release.sh --build 3 --version 1.0.1
```

Build and version overrides apply to the archive. Project versions and Git
staging stay unchanged. Release metadata records the source commit and whether
the working tree had changes. Commit the reviewed release work separately.

## Signing prerequisites

The Mac's login Keychain must contain an accessible Developer ID Application
certificate and its private key for team `CRQWDQ7QQR`. The script requires one
matching signing identity, then uses its fingerprint for the archive, export,
and DMG. Keep that identity available when resuming a release.

Install these Developer ID provisioning profiles, including Network Extensions
and App Group `group.com.gocloudlaunch.gateway.macos`:

| Product | Bundle ID | Profile name |
|---|---|---|
| Menu app | `com.gocloudlaunch.gateway.macos` | `CloudGateway MacOS` |
| VPN extension | `com.gocloudlaunch.gateway.tunnel.macos` | `CloudGateway-Tunnel MacOS` |

The app profile also authorizes System Extension installation and the Firebase
session Keychain group. Both profiles must authorize
`packet-tunnel-provider-systemextension`. The script defaults to those profile
names; set `CLOUDGATEWAY_APP_PROFILE` and `CLOUDGATEWAY_TUNNEL_PROFILE` if renamed.

The existing App Store Connect API key also supports notarization. Store its
credentials once, outside the repository:

```sh
xcrun notarytool store-credentials CloudGateway-notary \
  --key "$HOME/.ssh/Apple_API_KEY/AuthKey_YDM2P5LSK8.p8" \
  --key-id YDM2P5LSK8 \
  --issuer 9157d52e-3841-40de-8e45-fc74f01dfd2f
```

Use `--keychain-profile <name>` or `CLOUDGATEWAY_NOTARY_PROFILE` for a different
saved credential profile when preparing a release. The chosen name is recorded
for resumptions. Keep the `.p8` file and private signing key out of Git and logs.

## Release artifacts and checks

The script archives with the DeveloperID configuration, exports with manual
distribution profiles, and validates both bundles before any software upload.
Checks cover the signing team and Developer ID Application certificate,
Hardened Runtime, secure timestamps, release entitlements, embedded profiles,
matching app/extension versions, architecture, and packaged dependencies.

It submits an app ZIP to Apple, saves the submission ID and log, and staples the
accepted ticket to the app. It then builds a signed DMG containing the app and
an Applications shortcut, notarizes and staples that DMG, and checks both
artifacts with Gatekeeper. The release stops on signing or notarization failure.
Review both notary logs even after acceptance.

Artifacts live in a unique directory under
`Frontend/Apple/macOS/.build/releases/`. The script prints the final
`CloudGateway-<version>-<build>-arm64.dmg` path and SHA-256 checksum. Each
directory retains its archive, exported app, build/export logs, release
metadata, notarization submission records, notary logs, and `SHA256SUMS`.

To build and inspect artifacts before submitting software:

```sh
./scripts/macos-release.sh --prepare-only --build 2
```

Continue with the directory printed by that command:

```sh
./scripts/macos-release.sh --notarize '/absolute/path/to/prepared-release'
```

Each wait lasts at most 20 minutes. If Apple still reports In Progress, use the
same `--notarize` command later. Existing submission IDs are reused; changed
artifacts cannot reuse an earlier submission. Partial work remains available
for diagnosis and retry.

If an upload is interrupted before its submission ID is saved, the script
refuses to upload it again automatically. Match the artifact and attempt time
in `notary-<app|dmg>-attempt.json` against Apple's history:

```sh
xcrun notarytool history --keychain-profile CloudGateway-notary
./scripts/macos-release.sh --notarize '/absolute/path/to/prepared-release' \
  --recover-submission app=<confirmed-submission-id>
```

Use `dmg=<confirmed-submission-id>` for an interrupted DMG upload. Confirm the
correct submission in Apple's history before recording it.

## Installation and distribution

Test the final DMG from a browser download, preferably on a separate Mac. Quit
the previous menu app, drag CloudGateway into Applications, and run
`/Applications/CloudGateway.app`. Confirm Gatekeeper accepts it, sign-in works,
and Setup VPN opens the normal extension/VPN approval flow with SIP enabled.
Check real VPN connectivity and extension replacement using a later build.
Automated signing and Gatekeeper checks do not establish those runtime results.

Distribute the final stapled DMG and its checksum after installation checks.
Hosting is a separate deployment step. See the
[macOS development runbook](apple-macos-development.md) for runtime checks,
[Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
and [Apple's packaging guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).
