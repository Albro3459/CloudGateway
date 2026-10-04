# macOS release deployment

CloudGateway distributes directly as a Developer ID-signed, notarized DMG for
Apple silicon on macOS 26 or later. Run the release command from the repository
root after the required validation passes:

```sh
./scripts/test.sh macos
./scripts/macos-release.sh --build 3 --publish
```

Choose a build number higher than the project and every previous distributed
release. `--build` applies to both the app and extension. The marketing version
comes from the project unless supplied explicitly:

```sh
./scripts/macos-release.sh --build 4 --version 1.0.1 --publish
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

## GitHub publication

Add `--publish` to a new build or a resumed `--notarize` command to publish after
all notarization and Gatekeeper checks pass. Without that option, the command
keeps the finished release local. To publish a finished release after manual
installation checks:

```sh
./scripts/macos-release.sh --publish-existing '/absolute/path/to/finished-release'
```

`--publish-existing` verifies the existing app, signed DMG, accepted submission
records, stapled tickets, Gatekeeper acceptance, and exact `SHA256SUMS` contents.
It does not build, submit to Apple, staple, or regenerate checksums. It cannot
be combined with build, preparation, notarization, or `--publish` options.

Publication requires an authenticated GitHub CLI with release write access to
the public `Albro3459/CloudGateway` repository. The exact `sourceCommit` recorded
in `release.json` must already exist on GitHub. The command never pushes Git
changes or falls back to another commit. Release notes retain the recorded
working-tree status, including local changes present when the archive was made.

The command creates a draft tagged `macos-v<version>-build.<build>`, titled
`CloudGateway for Mac <version> (build <build>)`, uploads only the final DMG and
`SHA256SUMS`, checks their GitHub SHA-256 digests, then publishes with
`--latest=true`. New macOS releases become the repository's Latest release;
the Caddy release script uses `--latest=false` to leave that selection unchanged.
Retries reuse a matching draft or published release, skip assets whose digests
match, and stop on a conflicting tag, target, or asset. Existing assets are
never overwritten. Failed attempts retain local artifacts and any remote draft.
After creating a draft, the command briefly retries release-list reads while
GitHub makes it visible. If visibility is still delayed, rerun the same command
to resume the existing draft.

The release directory saves `publication.json` with the release and DMG URLs.
The command prints both URLs. To make a later build available on the website,
update the version, build, and exact DMG URL in
`Frontend/Web/src/helpers/macAppRelease.ts`, then deploy the web dashboard.

See the
[macOS development runbook](apple-macos-development.md) for runtime checks,
[Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
and [Apple's packaging guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).
