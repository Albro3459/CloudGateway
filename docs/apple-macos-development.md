# macOS development

The menu app and packet-tunnel system extension target macOS 26 on Apple
silicon. Build and test from the repository root:

```sh
./scripts/test.sh macos
./scripts/test.sh macos --signed
./scripts/test.sh ios
./scripts/test.sh apple
```

The `ios` and `macos` targets select each platform. `apple` runs both, and the
default suite runs every target. Shared package tests and repeated targets run
once per invocation. Automated checks do not activate extensions,
install VPN profiles, or change the running VPN. Unsigned builds prove
compilation and packaging. Signed builds also inspect signatures, embedded
profiles, and entitlements. Neither proves activation, authenticated IPC,
System Keychain access, or networking on a real machine.

## Validation checkpoint (2026-10-02)

The final no-argument `./scripts/test.sh` run exited successfully with
`All checks passed.` It covered API, web, infrastructure, Firebase emulator,
iOS, and macOS gates, including:

* 260 shared Kit/AppCore tests, 31 Firebase adapter tests, and 73 macOS
  core/IPC tests, plus packaging-verifier tests
* All five strict Apple Periphery scans
* Unsigned iOS device and macOS arm64 app/extension builds
* macOS bundle packaging inspection and test-runner routing/failure checks

An earlier run reproduced macOS dead-code findings from a Periphery cache
containing both iOS and macOS indexes. Periphery derives its cache identity from
the project basename and scheme set, without the project's full path; see its
[cache implementation](https://github.com/peripheryapp/periphery/blob/3.7.4/Sources/XcodeSupport/Xcodebuild.swift).
The macOS scan now uses both `CloudGateway` and `CloudGatewayTunnel` schemes,
keeping its cache separate from iOS. A regression check protects that distinction.

Signed macOS builds remain blocked by missing
matching Mac development profiles and a registered development Mac. Activation,
real System Keychain/XPC behavior, native browser session persistence, and live
VPN/network checks are deferred for local approval. No validation activated the
extension, installed a live VPN profile, or changed the running VPN.

The implementation received at most two review passes per chunk and an
integrated auth/menu review. Local commits are stable WIP checkpoints while
those signed runtime gates remain pending.

## Signing and installation

Both targets use the same development team. Register these identifiers and
include the macOS App Group in both provisioning profiles:

| Purpose | Identifier |
|---|---|
| Menu app | `com.gocloudlaunch.gateway.macos` |
| Packet tunnel | `com.gocloudlaunch.gateway.tunnel.macos` |
| App Group | `group.com.gocloudlaunch.gateway.macos` |
| Mach service | `group.com.gocloudlaunch.gateway.macos.tunnel` |

Development profiles authorize `packet-tunnel-provider`. Developer ID profiles
authorize `packet-tunnel-provider-systemextension`. The app also needs System
Extension installation and Firebase Keychain Sharing. The extension uses App
Sandbox and network access. It has no Firebase configuration or session access
group. See [Apple packaging guidance](https://developer.apple.com/forums/thread/800887)
and [TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).

Run the signed app from `/Applications/CloudGateway.app`. Keep SIP enabled.
Choose Setup VPN explicitly and handle macOS approval in System Settings.
The app reports pending approval, failure, and a required reboot. A preferences
save is not evidence that the provider started.

The extension belongs at
`Contents/Library/SystemExtensions/com.gocloudlaunch.gateway.tunnel.macos.systemextension`.
Its `NetworkExtension` dictionary declares the packet provider and exact Mach
service name. It starts through `NEProvider.startSystemExtensionMode()`.
Package dependencies must be statically linked or embedded inside the extension.
The installed system extension cannot depend on the original build directory or
the containing app's Frameworks directory.

Before runtime checks, inspect the built products with the validation script.
Confirm the bundle IDs, team, development entitlement value, App Group, extension
sandbox/network entitlements, profiles, arm64 executable, and framework runpaths.
Move the signed app out of its build directory before checking activation.

If automatic provisioning reports no registered devices or matching Mac App
Development profiles, register the development Mac with the team and generate
profiles for both IDs with their required capabilities and App Group membership.
The Apple Development certificate alone does not supply those profiles. Retry
the signed build before treating the app as ready for activation.

## Firebase and browser sign-in

The native Firebase app is registered in `cloud-launch-gateway` with bundle ID
`com.gocloudlaunch.gateway.macos`. Its `GoogleService-Info.plist` lives in
`Frontend/Apple/macOS/CloudGateway/` and belongs to the menu app only. The app
checks the configuration before starting Firebase. Keep the existing SDK pin
and the web API key's restrictions. No dashboard Referer is sent by the app.
See [Firebase Apple setup](https://firebase.google.com/docs/ios/setup).

The browser approves the deployed device-auth request. The menu displays its
six-digit code, including leading zeros, with Open Browser and Cancel actions.
The app validates the complete approval URL against the configured HTTPS
dashboard origin. Device secrets and custom tokens stay in memory. Polling
honors the server interval, fixed lifetime, and `Retry-After`.

Firebase persists the accepted native session in the user's Keychain. A canceled
SDK exchange is fenced and cleaned up even if its completion arrives after
sign-out. A metadata-only unsettled-exchange marker causes local cleanup on
relaunch after an interrupted exchange. Failed cleanup keeps the session hidden
until local sign-out succeeds. Product-access checks precede menu inventory.

Firestore uses memory-only SDK caching and explicit server reads. The app keeps
a separate metadata-only installed cache and last selection per Firebase UID.
Known access denial prevents offline fallback. Successful refresh prunes
removed clients and outdated config hashes. No cache file contains a full
config, private key, Firebase session, or pending device secret.

## Secret storage and IPC

The extension stores configs in the file-based System Keychain. The user app's
Data Protection Keychain and App Group container are not shared with a root
system extension. Both XPC peers require the other target's signed identity.
The app connects to the privileged Mach service. The listener derives the
macOS user from the connection's operating-system identity.

Installation creates a provisional opaque reference. Save and reload the VPN
profile, then commit the reference. Rollback is allowed only for provisional
references when preference inspection proves no profile uses them. A failed
commit, ambiguous preferences result, or metadata persistence failure retains
the secret for recovery. Replacing a profile retains its prior committed secret.
Sign-out, quit, and XPC disconnection never delete committed secrets.

A signed app obtains a short-lived, single-use start grant bound to its macOS
user, config, and opaque reference. The provider consumes that grant before
reading the secret. The grant remains in memory and is passed as a start option.
It is never saved in preferences. An asserted owner ID in a profile is not an
authorization source. Start VPNs through the menu app. Starts from System
Settings without a grant fail closed. System Settings can still stop a retained
VPN and display its status.

Use an isolated fixture to check persistence across app relaunch and extension
replacement. Verify unsigned/wrong-target callers and another macOS user cannot
read, commit, roll back, or start with the first user's reference. No XPC method
returns a full config to the menu app.

## Runtime checklist

Record build version, macOS version, architecture, and pass/fail outcomes.
Use an isolated test config and account. Do not record its keys, config, tokens,
addresses, approval code, traffic, DNS queries, or connection history.

1. Check activation from `/Applications`, pending/denied approval, retry,
   replacement, and any reboot result. Confirm the installed version after a
   rebuild. Repeat with the original build directory unavailable.
2. Explicitly connect the fixture. Verify provider startup and Apple's status,
   then TCP/IP, DNS, and UDP connectivity through a controlled destination.
3. Repeat connect/stop in the same extension process. Check sleep/wake and
   network changes. A stop timeout must prevent the next tunnel from starting.
4. Quit and relaunch the menu app while connected. The VPN must remain running.
   Sign-out must retain the VPN while hiding inventory and all VPN controls.
5. Verify offline connection only for the current account's previously
   authorized installed cache. A permission denial must clear presentation
   rather than reveal cached clients. Another account must not inherit it.
6. Check browser approval, native custom-token exchange, session restoration,
   cancellation, expiry, denial, consumed requests, and local sign-out.
7. Change VPN status through macOS controls and reopen the menu. Check optional
   Launch at Login, including required approval. Launching never connects.

Only sanitized activation/setup errors are suitable diagnostics. Discard raw
WireGuard log payloads. OS crashes should be reported with sanitized context.
Do not add traffic probes, runtime-counter polling, or automatic recovery.

Developer ID export, notarization, ZIP installation, and release hosting remain
separate release work.
