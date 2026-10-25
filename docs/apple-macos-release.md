# macOS releases

CloudGateway distributes as a Developer ID-signed, notarized DMG for Apple
silicon on macOS 26 or later. Run from the repository root:

```sh
python3 scripts/macos-release.py --bump-build
./scripts/test.sh macos
./scripts/macos-release.sh \
  --previous-distributed-app /absolute/path/to/latest-distributed/CloudGateway.app --publish
```

Omit `--publish` to retain a local release. For development-signed testing
installs, use [Quick Deployment](quick-deployment.md#install-macos-app-for-local-testing).

## Version and artifact policy

The app, CLI, controller, and extension share one `major.minor.patch` version and
integer build. CLI/controller are entry points of the app executable. Before
every new local install or release preparation, bump both targets together:

```sh
python3 scripts/macos-release.py --bump-build
python3 scripts/macos-release.py --bump-build --version 1.1.1
```

Choose one command. `--bump-build` advances past both targets and synchronizes
Debug, Release, and DeveloperID. Without `--version`, it keeps the higher existing
marketing version. Add `--build <higher-number>` to advance past an installed or
distributed build. Never reset builds after a marketing-version change. Only
this bump command edits the project; it does not build, sign, contact Apple,
stage, or commit. Review/commit the project edit separately.

Every new release preparation requires the exact signed app most recently
distributed to users as `--previous-distributed-app`, including distributions
outside GitHub. Extract it from the retained DMG if needed. Local signature
verification cannot establish which release users received. Preparation checks
the baseline's Developer ID signature, team, profiles, and dependencies before
reading the extension version/build and artifact digest.

The new build must strictly exceed the baseline extension build, and its
marketing version cannot decrease. This applies to app-only releases: export
may change extension signature bytes even without source changes. The build is
also part of the extension Mach service name. macOS
[uses both version fields for replacement](https://developer.apple.com/documentation/systemextensions/ossystemextensionrequestdelegate/request(_:actionforreplacingextension:withextension:)).

New preparations reject unsynchronized project versions before signing/network
calls. Optional release `--version`/`--build` overrides affect both archived
bundles without editing source, but prefer bumping tracked settings first.
Use `--initial-distribution` only when no extension has ever been distributed;
it records that declaration and cannot substitute for an existing baseline.

Preparation records the full exported extension tree's SHA-256 manifest,
including signature bytes, resources, modes, and symlinks. Notarization and
publication recheck it and the baseline policy. Re-signing at unchanged versions
is rejected even if the CodeDirectory digest matches. Reuse exact artifacts by
resuming their preparation; there is no extension-transplant command.

## Signing prerequisites

The login Keychain needs an accessible Developer ID Application certificate and
private key for team `CRQWDQ7QQR`. The script selects one matching identity and
uses its fingerprint for archive, export, and DMG. Retain it for resumptions.

| Product | Bundle ID | Developer ID profile |
|---|---|---|
| App | `com.gocloudlaunch.gateway.macos` | `CloudGateway MacOS` |
| Extension | `com.gocloudlaunch.gateway.tunnel.macos` | `CloudGateway-Tunnel MacOS` |

Both profiles need `packet-tunnel-provider-systemextension` and App Group
`group.com.gocloudlaunch.gateway.macos`. The app also needs System Extension
installation and its Firebase Keychain group. Override renamed profiles with
`CLOUDGATEWAY_APP_PROFILE` and `CLOUDGATEWAY_TUNNEL_PROFILE`.

Store notarization credentials outside the repository:

```sh
xcrun notarytool store-credentials CloudGateway-notary \
  --key "$HOME/.ssh/Apple_API_KEY/AuthKey_YDM2P5LSK8.p8" \
  --key-id YDM2P5LSK8 \
  --issuer 9157d52e-3841-40de-8e45-fc74f01dfd2f
```

Override the saved name with `--keychain-profile <name>` or
`CLOUDGATEWAY_NOTARY_PROFILE` during preparation. It is recorded for resumption.
Keep private keys out of Git/logs. Unlock and validate signing-key access in the
session running the build; see [known issues](apple-known-issues.md).

## Preparation and notarization

The script archives with DeveloperID and manual profiles. Before upload it checks
both bundles' identity, secure timestamps, Hardened Runtime, entitlements,
profiles, versions/builds, architecture, dependencies, build-specific Mach name,
and controller Firebase resource. Bounded CLI help/version/invalid-usage checks
cover direct and symlink entry points, JSON schema, and version reporting in
temporary homes. They do not install the CLI or exercise auth/controller/VPN.
Older signed pre-CLI/fixed-Mach-name releases remain valid baselines.

It notarizes an app ZIP, staples the app, builds/signs/notarizes/staples a DMG,
and checks both with Gatekeeper. Signing or notarization failure stops the release.
Review app and DMG notary logs even after acceptance.

To inspect artifacts before submission:

```sh
python3 scripts/macos-release.py --bump-build
./scripts/macos-release.sh --prepare-only \
  --previous-distributed-app /absolute/path/to/latest-distributed/CloudGateway.app
```

Continue using the directory printed by preparation:

```sh
./scripts/macos-release.sh --notarize '/absolute/path/to/prepared-release'
```

Each wait is bounded to 20 minutes. If still In Progress, rerun the same command;
it reuses submission IDs and refuses changed artifacts. Partial work is retained.

Outputs live under `Frontend/Apple/macOS/.build/releases/`. Keep the directory
intact: archive, exported app, logs, notarization records, `release.json`, final
`CloudGateway-<version>-<build>-arm64.dmg`, and `SHA256SUMS`. The script prints the
DMG path and checksum. Retain the distributed DMG as the next baseline.

`release.json` records source commit/dirty state, app `version`/`build`,
`extensionVersion`/`extensionBuild`, `extensionBaseline`, and `extensionArtifact`.
Resumption uses saved versions even after project settings change. Legacy metadata
without both extension version fields expects the app's versions; partial or
malformed fields fail. Preparations lacking the baseline/artifact manifests cannot
resume or publish. Prepare fresh builds against the latest distributed app;
never manufacture manifests for old output. Baseline options apply only to new
preparations. Archive/notarization/publication do not edit source or Git staging.

If upload ends before a submission ID is saved, automatic re-upload is refused.
Match the artifact/time in `notary-<app|dmg>-attempt.json` against Apple's history:

```sh
xcrun notarytool history --keychain-profile CloudGateway-notary
./scripts/macos-release.sh --notarize '/absolute/path/to/prepared-release' \
  --recover-submission app=<confirmed-submission-id>
```

Use `dmg=<confirmed-submission-id>` for DMG recovery. Verify the match first.

## Installation checks

Test a browser-downloaded final DMG, preferably on another Mac, using the
[development runtime checklist](apple-macos-development.md#runtime-checklist).
Cover Gatekeeper, approvals with SIP enabled, connectivity, extension replacement,
CLI/PATH installation, account/offline boundaries, and operation recovery. Include
reboot/pre-desktop SSH, credential access, concurrent startup, and caller loss
with another access path available. Signing/Gatekeeper checks alone do not prove
these runtime behaviors.

Install at `/Applications/CloudGateway.app`. Keep the signed bundle intact;
the CLI installer creates only a user-local symlink. The first controller lifecycle
migration needs a one-time old-controller restart after accepted work finishes.
Later verified app replacements drain work without stopping the VPN. Automatic
extension replacement waits for every owned tunnel to be idle and preserves
Apple approval/reboot requirements. For explicit stop/update/reconnect, see
[CLI update](../Frontend/Apple/macOS/README.md#update-from-the-cli-or-ssh).

### Runtime acceptance (2026-10-24)

The user reported the signed controller/CLI/client-removal runtime matrix passed,
including live VPN, reboot before desktop login, pre-desktop SSH/Keychain access,
final SSH disconnect, locked credentials, concurrent startup, command recovery,
and active-VPN replacement. This acceptance covers the reviewed stack; repeat
relevant checks for future changes.

The agent also recorded a successful `./scripts/test.sh apple --signed` run:
shared tests, 780 macOS host-free tests, all five strict Periphery scans, signed
iOS/macOS Release builds, signature/entitlement/profile verification, and 88
packaged CLI checks. These are historical results, not current test counts.

## GitHub publication

Add `--publish` to new preparation or resumed notarization, or publish an already
finished release after installation checks:

```sh
./scripts/macos-release.sh --publish-existing '/absolute/path/to/finished-release'
```

`--publish-existing` verifies bundles, signed DMG, accepted submissions, staples,
Gatekeeper, and exact checksums without rebuilding/submitting/stapling. It cannot
be combined with build, preparation, notarization, or `--publish` options.

Publication needs authenticated GitHub CLI release access to
`Albro3459/CloudGateway`. The recorded `sourceCommit` must already be on GitHub;
the script never pushes or substitutes another commit. Notes retain the recorded
working-tree state.

It creates a draft tagged `macos-v<version>-build.<build>`, uploads only the DMG
and `SHA256SUMS`, checks GitHub SHA-256 digests, then publishes as Latest. The
Caddy release uses `--latest=false`. Retries reuse matching releases/assets and
stop on conflicting tags, targets, or digests without overwriting. If draft
visibility is delayed, rerun the same command. Artifacts and remote drafts survive
failures.

`publication.json` and command output contain release/DMG URLs. Update version,
build, and exact DMG URL in `Frontend/Web/src/helpers/macAppRelease.ts`, then
deploy the web dashboard to advertise the release.
