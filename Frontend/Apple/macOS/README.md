# CloudGateway macOS

Planned minimal menu bar app and packet-tunnel system extension. Native targets
do not exist yet. See [TODO/macos-app.md](../../../TODO/macos-app.md) for the
implementation checkpoints, identifiers, and signed validation gates.

The initial app targets macOS 26 on Apple silicon. Shared Kit/AppCore floors
stay unchanged. It uses `NSStatusItem` and `NSMenu` as an `LSUIElement` agent,
with small setup/device-code dialogs and no dashboard. The
[device-auth flow](../../../docs/device-auth.md) is deployed and its live
approval/sign-in path has been verified.

## Shared Core And Native Composition

Reuse Kit configuration parsing/models, selection, snapshots, VPN preferences,
and suitable lifecycle helpers. Reuse AppCore HTTP/document mapping and session
contracts where useful. Keep macOS menu state separate from the full iOS view
model. Neither target compiles iOS sources. Preserve iOS contracts and behavior.

The app owns browser auth, Firebase session, authorized inventory, account-scoped
offline metadata, activation, VPN commands, XPC client, status observation,
and optional launch at login. Add native Firebase configuration and its
Keychain Sharing capability. Account/client/admin management stays on the site
or mobile app, with no native provider login UI.

The tunnel links Kit, the existing WireGuard fork/Go bridge, and necessary Apple
frameworks. It has no AppCore, Firebase, Google Sign-In, AppKit, SwiftUI, UIKit,
or User Notifications dependency. No blackout monitor, traffic probes, health
IPC, automatic blackout recovery, or notifications run on macOS.

## Storage And Lifecycle

The root system extension owns full configs in the System Keychain. The user
app transfers installation material through authenticated XPC and retains
opaque references. App Group containers and user Keychain items do not cross
the root/user boundary. The synchronous iOS secret adapter is not the Mac
adapter. See the plan's
[storage boundary](../../../TODO/macos-app.md#storage-and-account-boundaries).

Use memory-only Firestore SDK caching and persist metadata-only offline
inventory/selection per Firebase UID. Keep raw `wireGuardConfig` documents and
keys out of files. Another account's cache and retained system profiles never
become the current inventory. Admin visibility follows backend authorization.

Selection explicitly connects or switches. Turn Off retains configs/secrets
and cloud clients. Sign Out hides inventory and ends the local Firebase session,
retaining VPN, profiles, secrets, and account caches. Quit exits only the menu
app. Signed-out menus expose no configs or VPN controls. Retained profiles
remain controllable through macOS settings.

Refresh Apple preferences/status asynchronously on launch, menu opening,
preference changes, and commands. Observe status events for app-owned managers.
The icon may indicate a hidden active tunnel without exposing client details.
Launch at Login starts the menu app without connecting.

## Implementation And Validation

Build the thin app and extension together. Prove signed activation, authenticated
IPC, System Keychain storage, and a tunnel before adding auth and daily-use
inventory. Add tests/docs with each logical checkpoint and review completed work.

Add `./scripts/test.sh macos` when targets land, covering host-free tests,
Periphery, unsigned arm64 builds, and optional signed builds. Keep `apple`
as the iOS/shared regression gate. Automated checks do not activate extensions
or change the running VPN.

Signed checks cover activation/replacement, root/user isolation, repeated
sessions, sleep/wake, network changes, offline use, account switching, status
changes through macOS controls, retained VPN after sign-out/quit, and launch
at login. See the plan's
[Apple trap checklist](../../../TODO/macos-app.md#apple-traps-and-prevention).
Run the containing app from `/Applications` with SIP enabled.

Direct ZIP distribution is planned. Developer ID export, notarization, clean
release installation, and hosting remain separate release work.
