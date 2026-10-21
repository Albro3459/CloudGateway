# CloudGateway macOS

Native menu bar app and packet-tunnel system extension. See
[controller plan](../../../TODO/macos-cli.md) for the implementation checkpoints
and [development runbook](../../../docs/apple-macos-development.md) for signing,
installation, storage boundaries, and runtime checks.

Capture a clean menu image with `swift scripts/macos-menu-screenshot.swift`
from the repository root. See the
[screenshot instructions](../../../docs/apple-macos-screenshots.md) for setup.

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

`CloudGatewayMacController` owns device auth, session restoration, authorized
inventory, account-scoped offline metadata, VPN commands, and status observation.
It lives in the Foundation-only macOS core with injected services. Its snapshots
contain presentation data and exclude full configs, tokens, and secret references.
The app's composition layer initializes Firebase, memory-only Firestore caching,
the preferences adapter, and the existing extension XPC client.

The menu consumes those snapshots and submits commands. It owns AppKit,
browser opening, Add Client dialogs, extension activation, Settings navigation,
and optional launch at login. A dialog captures its account/session context
before loading regions, so an old dialog cannot create a client after sign-out
or an account change. The menu target includes native Firebase configuration
and Keychain Sharing. Add Client is available in the macOS menu.
Its dialog opens before region and capacity requests finish, so you can enter a
name while availability loads. Create becomes available once a region has room.
Account and admin management stay on the site or mobile app. There is no native
provider login UI.

The menu uses authenticated, versioned XPC to reach a separate controller mode
of the same bundled executable. The controller acquires per-user ownership
before initializing Firebase. It owns accepted commands after the menu closes.
Shared Kit/AppCore, the Firebase adapter, and iOS remain unchanged. The CLI
surface and signed launch/Keychain runtime proof remain pending.

Controller startup requires `/Applications/CloudGateway.app`. The menu registers
an on-demand launchd job in `user/<uid>`, with its private plist and ownership
locks under `~/Library/Application Support/CloudGateway/macOS`. Development and
mounted DMG copies cannot register themselves under the production service name.
The job sets `LimitLoadToSessionType = Background` for the user domain;
`ProcessType = Background` controls resource limits and does not select the session.
The controller exits after 60 seconds without requests or pending work. Menu
polling keeps it available while the frontend is open. Reopening the menu starts
it again without replaying a VPN command. An app/build mismatch requires closing
the menu, allowing pending work and the idle grace period to finish, then
reopening the installed app. Never run the old in-process owner alongside it.

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
[ownership boundaries](../../../TODO/macos-cli.md#ownership-and-boundaries).

Use memory-only Firestore SDK caching and persist metadata-only offline
inventory/selection per Firebase UID. Keep raw `wireGuardConfig` documents and
keys out of files. Another account's cache and retained system profiles never
become the current inventory. Admin visibility follows backend authorization.
The cache records its authorization role. A confirmed admin-to-user change
invalidates the admin cache and clears the menu inventory and last-used selection
before further requests. Failed client creation or refresh keeps connections
unavailable until a full online refresh rebuilds the permitted inventory.
Role-less caches require that refresh too.
Authorization rejections from client creation or regional capacity checks clear
the inventory, invalidate cached access, and sign out. Capacity limits and
validation errors keep the account signed in.
Removed client history does not count toward the live inventory limit.
Temporary Firebase verification outages retain the native session and cache,
while fresh online inventory stays unavailable until access can be checked.

Selection explicitly connects or switches. The top status row toggles the VPN,
with a native checkmark reflecting the observed connection state. Clicking
VPN connected disconnects, and VPN off reconnects the last-used usable client.
Connecting and disconnecting disable the toggle. Without a usable last-used
client, the row says Choose a client to connect. Disconnecting retains
configs/secrets and cloud clients. Sign Out hides inventory and ends the local Firebase session,
retaining VPN, profiles, secrets, and account caches. Quit exits only the menu
app. Signed-out menus expose no configs or VPN controls. Sign Out remains
available when a retained Firebase session cannot restore. System Settings can
stop retained profiles and display their status. Starting requires the
authenticated menu app, which supplies a single-use start grant.

Refresh Apple preferences/status asynchronously on launch, menu opening,
preference changes, and commands. Observe status events for app-owned managers.
The icon may indicate a hidden active tunnel without exposing client details.
Failed preference reads retain the last observed status and the existing error
until a successful read. Inventory refresh does not disable the local disconnect
action. Account switching waits for cancelled commands and required installation
cleanup before enabling another command.
Launch at Login starts the menu app without connecting.
Setup instructions appear once. Setup and update actions appear only when
activation can proceed. The approval prompt opens Login Items & Extensions
in System Settings.
Readiness requires the running extension's build and marketing versions to
match the embedded copy. A mismatch exposes Update VPN Extension and disables
new connections until explicit replacement and verification succeed. Increase
the build number when releasing extension changes.

## Implementation And Validation

The menu, browser auth, account-scoped inventory, packet provider, and
authenticated IPC are implemented. Automated validation covers host-free
workflows, race handling, dead code, compilation, and bundle packaging.
The new background controller still needs signed runtime checks for activation,
live Keychain/XPC access, VPN networking, and pre-desktop SSH use.

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

For a faster local install, quit CloudGateway from its menu, then paste this
command from the repository root. It builds the signed Release app and extension,
checks packaging and signing, and copies the app to `/Applications`. It skips
tests and dead-code scans. If an app is already installed, it moves that copy
to Trash first so removed build files cannot remain in
the new bundle. It uses the same development signing setup as `macos --signed`.

```sh
(
  set -e
  xcodebuild -project Frontend/Apple/macOS/CloudGateway.xcodeproj \
    -scheme CloudGateway -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath Frontend/Apple/macOS/.build/Xcode \
    ARCHS=arm64 -allowProvisioningUpdates build
  python3 scripts/verify_macos_build.py \
    Frontend/Apple/macOS/.build/Xcode/Build/Products/Release/CloudGateway.app --signed
  if [ -e /Applications/CloudGateway.app ]; then
    trash /Applications/CloudGateway.app
    echo "Trashed previous app"
  fi
  ditto Frontend/Apple/macOS/.build/Xcode/Build/Products/Release/CloudGateway.app \
    /Applications/CloudGateway.app
)
```

Open `/Applications/CloudGateway.app` after the command succeeds.

Signed checks cover activation/replacement, root/user isolation, repeated
sessions, sleep/wake, network changes, offline use, account switching, status
changes through macOS controls, retained VPN after sign-out/quit, and launch
at login. See the plan's
[runtime proof](../../../TODO/macos-cli.md#1-signed-runtime-proof-before-the-full-command-surface).
Run the containing app from `/Applications` with SIP enabled.

Build and publish a notarized Developer ID DMG with
`./scripts/macos-release.sh --build <next-build-number> --publish`. Omit
`--publish` to keep the release local. See
[macOS release deployment](../../../docs/apple-macos-release.md) for signing
setup, prepared artifacts, notarization retries, publishing existing builds,
and installation checks.
