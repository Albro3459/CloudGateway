# CloudGateway macOS

Native menu bar app and packet-tunnel system extension. See
[TODO/macos-app.md](../../../TODO/macos-app.md) for the implementation checkpoints
and [development runbook](../../../docs/apple-macos-development.md) for signing,
installation, storage boundaries, and runtime checks.

The initial app targets macOS 26 on Apple silicon. Shared Kit/AppCore floors
stay unchanged. It uses `NSStatusItem` and `NSMenu` as an `LSUIElement` agent,
with setup and device-code status in the menu and no dashboard. The
[device-auth flow](../../../docs/device-auth.md) is deployed and its live
approval/sign-in path has been verified.

## Shared Core And Native Composition

Reuse Kit configuration parsing/models, selection, snapshots, VPN preferences,
and suitable lifecycle helpers. Reuse AppCore HTTP/document mapping and session
contracts where useful. Keep macOS menu state separate from the full iOS view
model. Neither target compiles iOS sources. Preserve iOS contracts and behavior.

The app owns browser auth, Firebase session, authorized inventory, account-scoped
offline metadata, activation, VPN commands, XPC client, status observation,
and optional launch at login. The menu target includes native Firebase
configuration and Keychain Sharing. Add Client is available in the macOS menu;
account and admin management stay on the site or mobile app. There is no native
provider login UI.

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
The cache records its authorization role. A confirmed admin-to-user change
invalidates the admin cache before inventory requests, and a full online refresh
rebuilds the permitted inventory. Role-less caches require that refresh too.
Removed client history does not count toward the live inventory limit.
Temporary Firebase verification outages retain the native session and cache,
while fresh online inventory stays unavailable until access can be checked.

Selection explicitly connects or switches. Turn Off retains configs/secrets
and cloud clients. Sign Out hides inventory and ends the local Firebase session,
retaining VPN, profiles, secrets, and account caches. Quit exits only the menu
app. Signed-out menus expose no configs or VPN controls. Sign Out remains
available when a retained Firebase session cannot restore. System Settings can
stop retained profiles and display their status. Starting requires the
authenticated menu app, which supplies a single-use start grant.

Refresh Apple preferences/status asynchronously on launch, menu opening,
preference changes, and commands. Observe status events for app-owned managers.
The icon may indicate a hidden active tunnel without exposing client details.
Failed preference reads retain the last observed status and the existing error
until a successful read. Inventory refresh does not hide the local Turn Off
action. Account switching waits for cancelled commands and required installation
cleanup before enabling another command.
Launch at Login starts the menu app without connecting.
Readiness requires the running extension's build and marketing versions to
match the embedded copy. A mismatch exposes Update VPN Extension and disables
new connections until explicit replacement and verification succeed. Increase
the build number when releasing extension changes.

## Implementation And Validation

The menu, browser auth, account-scoped inventory, packet provider, and
authenticated IPC are implemented. Automated validation covers host-free
workflows, race handling, dead code, compilation, and bundle packaging.
Signed activation, live Keychain/IPC, and VPN networking remain pending until
development profiles and local macOS approval are available.

Both Apple projects build the existing `../wireguard-apple` submodule. Its
startup checks fail when the backend cannot start or network settings remain
unconfirmed. A settings timeout fences that adapter against another startup.
Provider stop completion waits for actual backend shutdown, including after
the stop deadline. The app reports a stop timeout instead of starting a replacement.

Run `./scripts/test.sh macos` for host-free tests, Periphery, unsigned arm64 builds,
and packaging checks. Use `./scripts/test.sh macos --signed` for signed builds and
profile/entitlement inspection. Use `ios` for the iOS regression gate and
`apple` for both platforms. The default suite runs every target. Shared package
tests run once per invocation. Automated checks do not activate extensions
or change the running VPN.

Signed checks cover activation/replacement, root/user isolation, repeated
sessions, sleep/wake, network changes, offline use, account switching, status
changes through macOS controls, retained VPN after sign-out/quit, and launch
at login. See the plan's
[Apple trap checklist](../../../TODO/macos-app.md#apple-traps-and-prevention).
Run the containing app from `/Applications` with SIP enabled.

Direct ZIP distribution is planned. Developer ID export, notarization, clean
release installation, and hosting remain separate release work.
