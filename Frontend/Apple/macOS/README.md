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
After an inventory transport failure, Add Client remains available once pending
work finishes so the dialog can retry region/capacity requests. Submission still
requires a fresh access check; cached inventory does not authorize cloud creation.
Account and admin management stay on the site or mobile app. There is no native
provider login UI.

The menu uses authenticated, versioned XPC to reach a separate controller mode
of the same bundled executable. The controller acquires per-user ownership
before initializing Firebase. It owns accepted commands after the menu closes.
Shared Kit/AppCore, the Firebase adapter, and iOS remain unchanged. The CLI uses
the same controller. Signed launch/Keychain runtime proof remains a release gate.

Controller startup requires `/Applications/CloudGateway.app`. The menu registers
an on-demand launchd job in `user/<uid>`, with its private plist and ownership
locks under `~/Library/Application Support/CloudGateway/macOS`. Development and
mounted DMG copies cannot register themselves under the production service name.
The job sets `LimitLoadToSessionType = Background` for the user domain;
`ProcessType = Background` controls resource limits and does not select the session.
The controller exits after 60 seconds without requests, pending work, or a
retained command result. The latest result keeps it alive for ten minutes. Menu
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
client, VPN off is disabled, and the region/client submenus select a connection.
The status follows Apple VPN preferences even while a cloud refresh or command
is pending. The Refresh row shows Refreshing clients while inventory is loading.
Cloud request failures do not label the internet connection offline.
Disconnecting retains configs/secrets and cloud clients. Sign Out hides inventory
and ends the local Firebase session,
retaining VPN, profiles, secrets, and account caches. Quit exits only the menu
app. Signed-out menus hide configs and retain local status/disconnect. Sign Out remains
available when a retained Firebase session cannot restore. System Settings can
stop retained profiles and display their status. Starting requires the
authenticated controller, which supplies a single-use start grant.

Refresh Apple preferences/status asynchronously on launch, menu opening,
preference changes, and commands. Observe status events for app-owned managers.
The icon may indicate a hidden active tunnel without exposing client details.
Failed preference reads retain the last observed status and the existing error
until a successful read. Inventory refresh does not disable the local disconnect
action or connections from already authorized inventory. Connecting cancels a
competing refresh and ignores its late result. Cached metadata can recreate a
missing Apple profile using its existing committed system secret, after checking
the account's cached authorization. Configs already fetched into memory can also
be installed during refresh. No raw configs or keys are added to the disk cache.
If a retained secret is missing or unreadable, an authorized in-memory cloud
config can reinstall it once, including when its Apple profile is missing.
Recovery retains the old secret and prepares the replacement before stopping
another active VPN. Without a usable cloud config, the existing VPN stays on.
Access checks and server inventory reads each have a 10-second deadline. Region
and client queries run together, ignore Firestore cache-only snapshots, and
detach their listeners on completion, cancellation, or timeout. Menu opening
refreshes cloud inventory at most once per 30 seconds; explicit Refresh bypasses
that interval. Account switching waits for cancelled commands and required installation
cleanup before enabling another command.
Launch at Login starts the menu app without connecting.
Setup instructions appear once. Setup and update actions appear only when
activation can proceed. The approval prompt opens Login Items & Extensions
in System Settings.
Readiness requires the running extension's build and marketing versions to
match the embedded copy. A mismatch exposes Update VPN Extension and disables
new connections until explicit replacement and verification succeed. Increase
the build number when releasing extension changes.

## Command Line Tool

Install and open the signed app at `/Applications/CloudGateway.app`. Complete
one-time desktop VPN extension and profile approval before using headless VPN
commands. The menu's **Install Command Line Tool…** is available while signed
out. It creates `~/.local/bin/cloudgateway`, a symlink to the app's existing
executable, without administrator access or changes to the signed bundle.
Development, mounted DMG, and translocated app copies cannot be link targets.

An existing correct link is accepted. Conflicting files, directories, links,
and broken links are reported and left untouched. Review and move the conflict
yourself before retrying. Replacing the app at its fixed path updates the link
automatically. Moving or removing the app breaks the link. Restore the signed app
at that location rather than copying its entitled executable out of the bundle.

The separate **Add to Zsh PATH…** action appends
`export PATH="$HOME/.local/bin:$PATH"` to an ordinary `~/.zprofile` once. It
first checks the app's current PATH and reads common PATH assignments in
`~/.zshrc` and `~/.zprofile`. Existing entries leave shell files unchanged.
Startup-file inspection does not execute shell code. The app reports which file
contains an entry, or that its current PATH already contains the local bin
directory. Terminal and SSH may have different environments, so check with
`which cloudgateway` in the shell you use.

Automatic editing preserves existing contents and mode and requires `/bin/zsh`,
no `ZDOTDIR` or `~/.zshenv`, a regular user-owned startup file containing only
comments and simple exports, and no existing PATH customization.
Linked/shared files are inspected without editing. Unsupported shells and
unrecognized custom startup configuration receive manual guidance when the app's
PATH does not already include the local bin directory. Open a new login shell after an edit.
The menu's environment does not establish Terminal or SSH's PATH.

Noninteractive SSH may skip login startup files. Use the explicit path:

```sh
~/.local/bin/cloudgateway status
~/.local/bin/cloudgateway auth status --json
~/.local/bin/cloudgateway down --non-interactive
```

Use the same non-root macOS user that completed desktop setup. Firebase uses
that user's existing credential context, and matching UID or unlocking a login
Keychain alone does not prove its availability in every security session.
Pre-desktop SSH, final SSH disconnect, locked credentials, and reboot behavior
still require the separate signed runtime matrix. FileVault unlock/boot access
is outside this feature.

```sh
cloudgateway                       # Help without controller or sign-in
cloudgateway --version
cloudgateway help auth login
cloudgateway auth login --no-qr
cloudgateway auth status --json
cloudgateway list --region us-east-1
cloudgateway list --refresh --json
cloudgateway up '<FirebaseUID>/<regionId>/<clientId>'
cloudgateway up                    # This account's last selection
cloudgateway status --operation '<operation-id>' --json
cloudgateway refresh
cloudgateway auth logout
cloudgateway down
cloudgateway doctor --json
```

IDs are canonical `FirebaseUID/regionId/clientId` values printed by `list`.
Names are display labels. `up` uses the controller's authorized inventory/cache
policy, installs or replaces an eligible stored config when needed, and reports
**VPN start requested** once macOS accepts the start. A later observed connected
state is separate. An unchanged active config reports already active. Offline
use is limited to this account's previously authorized installed configs.

`refresh` and `list --refresh` await their own online authorization/inventory
result without reconnecting. `auth logout` ends the controller session and hides
account data while retaining the VPN, profiles, secrets, and caches. A cleanup
failure is reported explicitly. `down` works while signed out and succeeds only
after a confirmed local stop, including an already-stopped state. Quit only
detaches the menu.

Common options are `-h`/`--help`, `--json`, `--non-interactive`, and
`--timeout <positive-finite-seconds>`. Reads and mutations default to 30 seconds.
Login startup is bounded separately, then approval waiting follows the server's
remaining code expiry. An explicit timeout bounds the whole login invocation
and can only shorten waiting. `auth login --no-qr` suppresses QR output. The
approval URL/code remain usable on another device. Suitable interactive
terminals offer copy/open/cancel shortcuts while polling continues. Redirected,
JSON, and noninteractive output suppress those shortcuts and prompts.

VPN commands flush an operation ID before confirming execution. A timeout,
Ctrl-C, broken pipe, or lost SSH connection detaches the caller after confirmation
and leaves controller-owned VPN work running. Reconnect and use
`cloudgateway status --operation '<operation-id>'`. Never replay uncertain work
automatically. Only the active/latest result is retained in memory for ten
minutes. A newer result, app replacement, crash, or reboot can end recovery
earlier. Unknown/expired results do not establish whether a VPN action ran.
Login cancellation/deadline cleanup targets only that attempt. Unexpected
frontend loss leaves controller polling bounded by the approval expiry.

`doctor` reads setup and supported diagnostic evidence without approving an
extension, signing in, refreshing inventory, writing preferences, or changing
the VPN. Checks cover installed resources and identity, link/PATH, controller,
extension, preferences, credentials/access, network path, DNS, dashboard HTTPS,
and optional known-region health. Unsupported or uninitialized evidence stays
unknown. Required setup failure takes exit precedence over required online
failure; a caller deadline returns partial results.

JSON stdout is NDJSON schema version 1. Each line is a complete object with
`schemaVersion`, `type`, `command`, `operationId`, `data`, and `error`. Reads emit
one result. Login first emits `login_required`; VPN mutations first emit
`accepted`, then a final result/error when available. Errors have stable `code`,
sanitized `message`, and nullable `suggestion`. Unavailable fields are explicit
nulls; observation timestamps are UTC. Requested action, command outcome, and
observed tunnel state are separate. Additive fields retain version 1 field
types. Human diagnostics use stderr; JSON has no progress text or ANSI escapes.

| Exit | Meaning |
| --- | --- |
| 0 | Command succeeded; status can still show disconnected or signed out |
| 1 | Unexpected internal failure |
| 2 | Invalid usage or arguments |
| 3 | Sign-in required, access denied, or approval denied |
| 4 | Setup, permissions, credentials, or version compatibility blocks use |
| 5 | Config or selection unavailable/unusable |
| 6 | Required fresh online result unavailable |
| 7 | Conflicting mutation or login is busy |
| 8 | Caller/operation deadline or login expiry |
| 9 | VPN/config operation failed |
| 10 | Requested operation result unknown/expired |
| 130 | Caller interrupted |

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
and packaging checks, including 20 bounded packaged direct/symlink static CLI
checks in temporary homes. Installer tests use temporary filesystems and do not
edit your shell or installed app. Use `./scripts/test.sh macos --signed` for signed builds and
profile/entitlement inspection. Use `ios` for the iOS regression gate and
`apple` for both platforms. The default suite runs every target. Shared package
tests run once per invocation. Automated checks do not activate extensions
or change the running VPN.

For a faster local install, use the command below. It builds and verifies the
signed Release app and extension, then replaces `/Applications/CloudGateway.app`.
It skips tests and dead-code scans and uses Apple Development signing.

Before rebuilding a changed or newly signed VPN extension, increment the tunnel
target's `CURRENT_PROJECT_VERSION` in every project configuration. macOS uses
the extension's version numbers to decide whether to offer replacement. Reusing
them for a different signed artifact can leave **Update VPN Extension** repeating:
macOS reports the old copy as already active, while doctor detects the different
signed identity. The app build number does not replace the extension build number.

The first installation of the synchronized lifecycle needs a one-time controller
restart because an older controller cannot perform the new handshake. Quit the
old menu and wait for pending work and any ten-minute result retention, or restart
the job explicitly after accepted work finishes. Subsequent replacements are
detected automatically, including local app rebuilds with reused version numbers.
Extension replacement still requires the extension build increment described above.

```sh
(
  set -e
  xcodebuild -project Frontend/Apple/macOS/CloudGateway.xcodeproj \
    -scheme CloudGateway -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath Frontend/Apple/macOS/.build/Xcode \
    ARCHS=arm64 -allowProvisioningUpdates build
  python3 scripts/verify_macos_build.py \
    Frontend/Apple/macOS/.build/Xcode/Build/Products/Release/CloudGateway.app --signed --cli-smoke
  if [ -e /Applications/CloudGateway.app ]; then
    trash /Applications/CloudGateway.app
    echo "Trashed previous app"
  fi
  ditto Frontend/Apple/macOS/.build/Xcode/Build/Products/Release/CloudGateway.app \
    /Applications/CloudGateway.app
)
```

Open `/Applications/CloudGateway.app` after the command succeeds.

The controller checks the fixed installed bundle's signature and fingerprint
every five seconds. A verified replacement closes admission to new mutations,
finishes accepted work, and exits without stopping the VPN. launchd starts the
installed controller on the next request. Stale menus reopen the verified app;
clients never choose the replacement executable. Partial or invalid copies do
not authorize a handoff. Recent request UUIDs and request digests survive the
handoff for ten minutes, with a maximum of 64 live receipts. The controller first
returns an operation ID and reserves the command. The frontend confirms receipt
before execution can change routes. Unconfirmed reservations expire after 30
seconds. Accepted, running, completed, failed, and unknown outcomes are separate
from observed tunnel status. Only the active/latest result stays in memory,
without a connection history. Results become unknown after controller restart,
and uncertain work is never replayed automatically.

Status and idempotent local disconnect use a small authenticated compatibility
contract while a replaced controller drains. The menu labels retained observations
when reconnecting and disables new starts until it reaches the current controller.
Disconnect works while signed out and does not depend on receipt capacity or disk
writes. Add Client preparation has a 20-second aggregate budget and four concurrent
capacity reads. Unresolved capacities remain unknown, and closing its frontend
cancels the preparation without cancelling confirmed VPN work.

A changed VPN extension blocks new connections while status and disconnect stay
available. Its update waits until every owned tunnel is idle, including profiles
outside the signed-in account. The menu then attempts Apple's activation flow
once automatically; Set Up/Update remains available for an explicit retry.
Approval and reboot requirements persist across relaunch. An interrupted
activation becomes outcome unknown. An authenticated probe of the exact target
can recover it without a reboot. Only an OS-confirmed reboot requirement remains
blocked until a later boot. Readiness and activation completion share durable
terminal receipts, so delayed callbacks cannot reopen an old update. Updates
never disconnect a tunnel automatically.

Every distributed app build must increase. Every new release preparation also
requires a fresh extension build and a verified baseline from the latest
distributed signed app.
Archive/export may change signature bytes even when extension source is unchanged.
Resuming a preparation requires the exact recorded extension artifact, and drift
is rejected before publication. Keep development and Developer ID installations
separate to avoid Keychain identity mismatches.


Signed checks cover activation/replacement, root/user isolation, repeated
sessions, sleep/wake, network changes, offline use, account switching, status
changes through macOS controls, retained VPN after sign-out/quit, and launch
at login. See the plan's
[runtime proof](../../../TODO/macos-cli.md#1-signed-runtime-proof-before-the-full-command-surface).
Run the containing app from `/Applications` with SIP enabled.

Build and publish a notarized Developer ID DMG with
`./scripts/macos-release.sh --build <next-build-number> --previous-distributed-app <latest-signed-app> --publish`. Omit
`--publish` to keep the release local. See
[macOS release deployment](../../../docs/apple-macos-release.md) for signing
setup, prepared artifacts, notarization retries, publishing existing builds,
and installation checks.
