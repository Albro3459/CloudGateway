# Apple known issues and workarounds

Permanent records of Apple platform failures and integration constraints found
while building CloudGateway. Keep these after implementation TODOs are complete.
Each entry records the observed symptoms, evidence, mitigation, and validation
limits. An Apple bug ID is included when an upstream report is available.

| Issue | Classification | Mitigation |
|---|---|---|
| [Extension replacement loses its endpoint](#extension-replacement-loses-its-mach-endpoint-fb17032197) | Confirmed local collision, related Apple report `FB17032197` | Use a distinct Mach service for each extension build |
| [Retained secrets reject a changed signing identity](#retained-secrets-reject-a-changed-signing-identity) | Keychain access-control constraint | Keep signing consistent and reinstall authorized configs when retained secrets are unreadable |
| [Controller bootstrap fails in the user domain](#controller-bootstrap-fails-in-the-user-domain) | launchd session configuration | Set `LimitLoadToSessionType = Background` |
| [System extension activation fails with error 9](#system-extension-activation-fails-with-error-9) | Required bundle metadata | Include `NSSystemExtensionUsageDescription` |
| [Signing fails after a Keychain unlock in another session](#signing-fails-after-a-keychain-unlock-in-another-session) | Keychain security-session constraint | Unlock and validate private-key access in the signing session |

## Extension replacement loses its Mach endpoint (FB17032197)

Observed on Apple silicon with macOS 26 on 2026-10-21 while replacing extension
1.0.0 (2) with 1.0.0 (3). The menu remained at VPN setup required. Repeating
Set Up reached macOS successfully, but the controller could not reach the
extension. macOS activation state alone did not establish readiness.

The sanitized diagnostic sequence was:

- At 20:46:36.811, launchd reported that build 3's Mach endpoint already belonged
  to build 2. Both builds declared `group.com.gocloudlaunch.gateway.macos.tunnel`.
- At 20:46:36.815, launchd removed build 2's job.
- At 20:46:36.869, the controller's bootstrap lookup failed with No such process.
- Build 3's launchd job remained registered with its NetworkExtension provider
  trigger, but no Mach endpoint. It had zero runs and had never exited.
- Subsequent activation requests returned `activated_enabled` / `alreadyActive`.
  No extension startup crash was found, and build 3 had never launched.

Apple DTS tracks upgrade-related extension XPC failures as `FB17032197` and
[suggests changing the Mach service name on every update](https://developer.apple.com/forums/thread/779395).
Our endpoint collision is consistent with that reported issue. The public
discussion does not establish that every upgrade failure has the same cause.

Starting with app build 6 and extension build 4, CloudGateway declares
`group.com.gocloudlaunch.gateway.macos.tunnel.$(CURRENT_PROJECT_VERSION)` in the
extension's signed `NEMachServiceName`. Both controller clients derive the name
from the bundled extension build. The listener checks the declared name against
its captured signed build, and packaging verification rejects a stale suffix.
Increment the extension build whenever its code, dependencies, or signing
changes. Rebuilding different artifacts under one build number reuses the
endpoint and defeats this workaround.

The extension also calls `NEProvider.startSystemExtensionMode()` before creating
its additional XPC listener, following
[Apple's startup-order guidance](https://developer.apple.com/forums/thread/728063).
That ordering change is separate from the observed collision: build 3 never
started, so its listener initialization could not explain this capture.

When the expected endpoint is unreachable, the controller queries macOS
extension properties to distinguish an installed extension needing an update
from first setup or pending approval. Properties do not prove the running
artifact's identity. A matching authenticated ping is still required for ready.
Replacement waits for all owned VPNs to become idle and preserves disconnect.

For this failure, install the newer signed app and allow its extension update
while the VPN is off. Repeating activation of the affected build did not repair
the endpoint. The workaround passed automated validation; later user-reported
signed runtime checks passed. See the
[runtime acceptance record](apple-macos-release.md#runtime-acceptance-2026-10-24).

## Retained secrets reject a changed signing identity

On 2026-10-21, switching to a config whose VPN profile was missing failed during
retained-secret restoration. System Keychain authorization rejected access.
Read-only Security.framework checks confirmed the running extension was signed
with Developer ID Application while the retained item's ACL required Apple
Development. Both extension copies reported 1.0.0 (2), so version-only readiness
could not distinguish them. The capture did not establish a VPN preferences
failure.

Keep deployment signing identities consistent and increment the extension build
when its signed artifact changes. Readiness now compares captured signed code
identity as well as versions. If an availability read finds a missing or
unreadable retained secret, restoration and connection can attempt one reinstall
from the current account's authorized online config. Offline or unauthorized
requests cannot replace it. Other storage, transport, timeout, and cancellation
failures retain their existing handling. ACLs remain restricted and old secrets
remain retained.

Automated validation covered recovery; the original diagnosis did not include
signed reinstall/live switching. See
[secret storage and IPC](apple-macos-development.md#secret-storage-and-ipc) for
ownership and recovery rules.

## Controller bootstrap fails in the user domain

On macOS 26, the menu could not reach its controller because its launchd job was
absent. Bootstrapping the generated plist in `user/<uid>` returned error 5.
Adding `LimitLoadToSessionType = Background` made that same bootstrap succeed,
and the user confirmed the menu recovered through authenticated XPC.

The generated plist now includes that session setting. `ProcessType = Background`
controls resource limits and does not select the launch session. Preserve the
fixed installed executable path and per-user ownership lock when changing the
launcher. A regression checks the plist setting. Later user-reported runtime
checks covered pre-desktop SSH/Keychain behavior. See the
[runtime acceptance record](apple-macos-release.md#runtime-acceptance-2026-10-24)
and [controller runbook](apple-macos-development.md) for launch details.

## System extension activation fails with error 9

The first live setup attempt failed category validation because the extension's
Info.plist omitted `NSSystemExtensionUsageDescription`. macOS rejected activation
before the approval step.

Include a nonempty description of the VPN's purpose in the system extension's
Info.plist. Both signed and unsigned packaging verification reject a missing or
invalid description. Error 9 alone is not enough to identify this omission in a
new report. Check the activation diagnostics and packaged metadata.
See [signing and installation](apple-macos-development.md#signing-and-installation).

## Signing fails after a Keychain unlock in another session

During validation on 2026-10-21, signing surfaced `errSecInternalComponent`.
The underlying logs showed `errSecInteractionNotAllowed`, and the agent's remote
security session still reported the login Keychain locked. The user passed the
signed macOS validation gate over SSH after unlocking the login Keychain in
that same session; the resulting Release bundle was independently verified.

Treat unlock state and private-key access as dependent on the executing security
session. Discovering a certificate does not prove that signing can use its
private key. Validate access in the session performing the build. This result
does not prove Firebase Data Protection Keychain access from a background
controller. Other causes can also surface as `errSecInternalComponent`.
See the [validation guide](apple-macos-development.md#validation).
