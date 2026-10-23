# macOS release deployment

CloudGateway distributes directly as a Developer ID-signed, notarized DMG for
Apple silicon on macOS 26 or later. Run the release command from the repository
root after the required validation passes:

```sh
./scripts/test.sh macos
./scripts/macos-release.sh --build 7 \
  --previous-distributed-app /absolute/path/to/latest-distributed/CloudGateway.app --publish
```

Choose an app build number higher than `CLOUDGATEWAY_APP_BUILD` in the project
and every previous distributed app release. `--build` overrides only
`CLOUDGATEWAY_APP_BUILD`. The app marketing version comes from
`CLOUDGATEWAY_APP_VERSION` unless `--version` overrides it:

```sh
./scripts/macos-release.sh --build 8 --version 1.1.1 \
  --previous-distributed-app /absolute/path/to/latest-distributed/CloudGateway.app --publish
```

App build and version overrides apply to the archive. The VPN extension keeps
its explicit `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION` from the project.
Keep each target's versions consistent across Debug, Release, and DeveloperID.
Every new preparation requires `--previous-distributed-app` pointing to the exact
signed app from the latest release actually distributed to users. Extract it
from the retained distributed DMG if needed. The script verifies its Developer
ID signature, team, profiles, and packaged dependencies before reading its
extension version, build, and artifact digest. It never selects an untracked
local archive or export as the baseline automatically. The operator must identify
the latest distributed app correctly, including a release distributed outside
GitHub. Local signature checks cannot establish distribution history.

Before signing or contacting Apple, preparation requires the extension's
`CURRENT_PROJECT_VERSION` to strictly exceed the baseline build. Its marketing
version must not decrease. Bump the extension build in all project configurations
for every new preparation, including app-only releases. Archive/export can change
the CMS signature even when extension code has not changed. The Mach service
name includes the extension build, so increasing it also avoids stale endpoint
registration during replacement.

The script records a SHA-256 manifest of the full exported extension tree,
including executable signature bytes, resources, file modes, and symlink targets.
Notarization resumption and publication check that manifest and the baseline
policy again. A re-signed extension at an unchanged version/build is rejected,
even if its CodeDirectory remains the same. Existing signer and authenticated
runtime identity checks remain required.

Exact reuse is supported by resuming the same prepared release. New preparation
always signs/exports again and therefore requires a fresh extension build. There
is no command to transplant a previously signed extension into a new app.
Use `--initial-distribution` instead of `--previous-distributed-app` only when no
extension has ever been distributed. This explicit first-release declaration is
recorded in the manifest. It must not be used to bypass an existing baseline.

Project versions and Git staging stay unchanged. Release metadata records both
targets' versions, the source commit, and whether the working tree had changes.
Commit the reviewed release work separately.

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
each bundle's expected version and build, architecture, and packaged dependencies.
Current release products also require the bundled CLI executable and controller
Firebase resource, then pass 20 bounded help/version/invalid-usage checks through
direct `--cli` and a temporary `cloudgateway` symlink. Each invocation uses a
temporary home, redirected stdin, and a five-second deadline. JSON checks verify
schema version 1, line completeness, usage errors, and the bundle's version/build
through both entry points. No real CLI installation, service registration,
auth restoration, or VPN operation is part of these static checks. The verified
previous-distribution baseline keeps historical packaging checks, so an older
release that predates the CLI remains a valid baseline.

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
./scripts/macos-release.sh --prepare-only --build 6 \
  --previous-distributed-app /absolute/path/to/latest-distributed/CloudGateway.app
```

Continue with the directory printed by that command:

```sh
./scripts/macos-release.sh --notarize '/absolute/path/to/prepared-release'
```

Each wait lasts at most 20 minutes. If Apple still reports In Progress, use the
same `--notarize` command later. Existing submission IDs are reused; changed
artifacts cannot reuse an earlier submission. Partial work remains available
for diagnosis and retry.

Preparation saves the app's `version` and `build`, the extension's
`extensionVersion` and `extensionBuild`, and the `extensionBaseline` and
`extensionArtifact` manifests in `release.json`. Keep this directory intact for
resumption and retain the distributed DMG for the next release baseline. Both
`--notarize` and `--publish-existing` check the exported bundles against those saved versions,
even if the project versions have since changed. Older metadata without either
extension version field expects the extension to match the app's version and
build. Partially present or malformed extension fields stop the release. Releases
prepared before the artifact policy was added cannot resume or publish through
this script, because they lack a trustworthy recorded baseline and artifact
manifest. Prepare a new release against the latest distributed app with fresh
app and extension builds. Do not add manifests retroactively to old outputs.
Baseline options apply only to new preparation. Resumed releases use their saved
policy.

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

Use **Install Command Line Tool…** while signed out and verify the user-local
link targets the executable inside `/Applications/CloudGateway.app`. Repeat
installation, conflict/broken-link handling, and the separate zsh PATH offer.
Test `~/.local/bin/cloudgateway --version` and `help` from Terminal and
noninteractive SSH without relying on `.zprofile`. Verify setup recognizes the
app's existing PATH and common entries in `~/.zshrc` or `~/.zprofile` without
changing files. Unrecognized custom configuration, linked startup files, and
unsupported shells must receive manual guidance before any edit. App replacement
at the same path keeps the link valid; app
movement/removal leaves it broken without replacing another user's file.

Complete one-time desktop extension/VPN approval, then run the planned signed
CLI matrix with an isolated account/config and another access path. Cover login
approval/expiry/cancellation, JSON output/exits, offline access, refresh without
reconnect, successful start submission versus observed connection, confirmed
stop, signed-out disconnect, and logout retaining VPN/profiles/secrets/cache.
Check `status --operation <uuid>` after caller/SSH loss and an unknown result
after replacement/restart. Never replay uncertain work automatically. Verify
doctor changes no session, inventory, preferences, or VPN state and reports
unsupported credential/approval evidence as unknown. Include reboot before
desktop login, final SSH disconnect, locked credentials, concurrent menu/SSH
startup, and active-VPN replacement. These remain manual release gates.
See the [CLI guide](../Frontend/Apple/macOS/README.md#command-line-tool) for
commands, common options, NDJSON schema/exits, and recovery semantics.

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

The app also carries headless controller and CLI entry points. They use the same
executable, resources, signing identity, and provisioning profile. There is no
separate controller or CLI binary to sign or copy out of the bundle. Keep the
signed app unchanged after installation; the installer creates only a user-local
symlink. The CLI's static help/version/usage paths work without the controller.
Operational commands retain the ordinary authenticated version/signature checks.

Install at `/Applications/CloudGateway.app`, the controller's fixed launch path.
For the first controller migration, quit the old menu before launching the new
app so two Firebase owners cannot overlap. The first installation of the
synchronized lifecycle also needs a one-time controller restart. Later updates
verify the fixed installed bundle, drain accepted work, and reconnect to the
replacement controller automatically. Active VPNs stay connected. Extension
replacement waits until all owned tunnels are idle and preserves Apple's
approval or reboot requirement. See the local install command in the macOS
README and validate the signed live update matrix before distributing it.
Build/signature checks alone do not prove background launch or pre-desktop SSH
Keychain access. Run those checks in the planned runtime session.

The release directory saves `publication.json` with the release and DMG URLs.
The command prints both URLs. To make a later build available on the website,
update the version, build, and exact DMG URL in
`Frontend/Web/src/helpers/macAppRelease.ts`, then deploy the web dashboard.

See the
[macOS development runbook](apple-macos-development.md) for runtime checks,
[Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
and [Apple's packaging guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).
