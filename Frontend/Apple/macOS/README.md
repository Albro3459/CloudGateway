# CloudGateway macOS

Native menu bar app and packet-tunnel system extension. See the
[development runbook](../../../docs/apple-macos-development.md) for controller
architecture, signing, installation, storage boundaries, and runtime checks.
The [Apple docs index](../README.md) links the platform and shared guides.

Capture a clean menu image with `swift scripts/macos-menu-screenshot.swift`
from the repository root. See the
[screenshot instructions](../../../docs/apple-screenshots.md#macos-menu) for setup.

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
Remove Client appears immediately below Add Client. Select a region, then a
config, and choose Delete to remove the cloud client and its local VPN profile.
Deletion cannot be undone. Disconnect the selected config and wait for it to
stop first. Connecting, connected, reconnecting, and disconnecting configs
cannot be deleted. A different active config can stay connected. Remove Client
does not connect a config or change the last-used selection.

Delete stays disabled when VPN status is unavailable. The dialog closes if the
account or controller changes. A failed or uncertain deletion tells you to
Refresh before trying again. If cloud deletion succeeds but local cleanup or
inventory refresh fails, the app reports that warning without retrying deletion.
Account and admin management stay on the site or mobile app. There is no native
provider login UI.

The menu uses authenticated, versioned XPC to reach a separate controller mode
of the same bundled executable. The controller acquires per-user ownership
before initializing Firebase. It owns accepted commands after the menu closes.
Shared Kit/AppCore, the Firebase adapter, and iOS remain unchanged. The CLI uses
the same controller. The user confirmed signed runtime acceptance, including
pre-desktop SSH/Keychain access, passed on 2026-10-24. See the
[acceptance record](../../../docs/apple-macos-release.md#runtime-acceptance-2026-10-24).

Controller startup requires `/Applications/CloudGateway.app`. See the
[controller runbook](../../../docs/apple-macos-development.md#controller-and-frontends)
for launchd registration, inventory scheduling, idle exit, and update handoff.

The tunnel links Kit, the existing WireGuard fork/Go bridge, and necessary Apple
frameworks. It has no AppCore, Firebase, Google Sign-In, AppKit, SwiftUI, UIKit,
or User Notifications dependency. No blackout monitor, traffic probes, health
IPC, automatic blackout recovery, or notifications run on macOS.

## Controller Client Removal Contract

Client removal is available through `cloudgateway remove` and the app's
**Remove Client…** action under Add Client. Both frontends use the controller,
production adapters, and IPC, and require the target config to be inactive.

`CloudGatewayMacController.removeClient(identifier:onCompletion:) -> Bool` uses
the existing accepted-task contract. A synchronous rejection returns `false`
and completes with a typed failure. Accepted work returns `true`, belongs to
the controller, and completes independently of the calling frontend's lifetime.

An authenticated current-build IPC caller submits `.removeClient` with a request
UUID and exactly one canonical `accountId/regionId/clientId` identifier. Schema
and protocol versions are 2, control version is 1. `regionId`, `clientName`,
`contextId`, `loginOrigin`, and `allowDisconnect` must be absent on that request.
The controller never infers the target from selection. The account component is
the signed-in account's local namespace, including when an admin removes another
owner's client. The controller derives the API owner from one exact fresh cloud
record, checks the current role, and sends the existing regional DELETE once.
Cached inventory cannot authorize removal. Disabled regions, absent profiles,
and missing usable configs do not prevent removal of an authorized known client.

The ordinary mutation handoff reserves an operation without destructive effects.
Only `.confirmOperation` with the operation UUID as `contextId` starts work.
Unconfirmed reservations expire after 30 seconds. A changed action or identifier
with the same request UUID is rejected. Confirmation, operation polling, and
frontend detach use the existing controller contract. New mutations are refused
during startup reconciliation, activation, managed update, draining, or other
mutation work. Removal requires the matching signed build; compatible status and
signed-out global stop retain their existing behavior.
Poll `.operation` with the operation UUID as `contextId` to read its state and
typed outcome. These are independent of the currently observed tunnel status.

Before HTTP dispatch, the controller durably evicts the target's cached config,
authorized hash, and selection if selected. It removes that target from the
current presentation and rechecks session and profile state after token loading.
An active target, including connecting, reasserting, or disconnecting, fails with
`clientActive`. The caller must disconnect it explicitly and wait. Verified
success requires the captured owner, region, client, and `removed` response.
Cleanup removes only the exact inactive owned profile, reloads preferences to
verify absence, and refreshes inventory. Removal never chooses a replacement,
installs a config, starts a tunnel, or submits a stop. Other clients and their
selection stay intact. Committed system Keychain secrets remain retained under
the existing policy; cloud removal revokes the peer and local eligibility.

Verified cloud success completes even if local cleanup or refresh fails.
`localCleanupIncomplete` takes precedence over `inventoryNotRefreshed`. Active
or unobservable profiles stay untouched; recovery requires an explicit Disconnect
or System Settings stop before local cleanup, then Refresh. Success and warnings
belong to the original session and are redacted after logout or account change.
The original session excludes a confirmed removed target even if a later cloud
read returns an older copy. Local profile existence alone never restores eligibility.

A timeout, cancellation, malformed/mismatched reply, or lost response after
dispatch produces `unknown`, since the backend may already have removed the
client. A definite HTTP 401/403 remains `accessDenied` and invalidates account
access. Never retry DELETE automatically. Retain the eviction and use operation
lookup and Refresh to recover. Only fresh authoritative inventory can make a
still-active cloud client eligible after an uncertain attempt.

Persisted request receipts prevent replay for 600 seconds from acceptance.
Creation and ordinary commands have separate in-memory result slots. Each terminal
result stays available for 600 seconds from completion; running results do not
expire while running. A new acceptance replaces its own slot, and process exit
loses both slots. These clocks are independent. Restart loses
the result but unexpired receipts yield `unknown` without redispatch. Expired
receipts are discarded at startup, so an old UUID can be admitted again after
that window. This is bounded replay protection, with no automatic resend even
after expiry. Restart while offline cannot restore the evicted config or
selection. A crash or failed cleanup can leave an orphan profile and retained
secrets; startup does not delete profiles or stop tunnels on removal's behalf.

## Storage And Lifecycle

The root system extension owns full configs in the System Keychain. The user
app transfers installation material through authenticated XPC and retains
opaque references. App Group containers and user Keychain items do not cross
the root/user boundary. The synchronous iOS secret adapter is not the Mac
adapter. See
[secret storage and IPC](../../../docs/apple-macos-development.md#secret-storage-and-ipc)
for ownership boundaries.

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
first checks the app's current PATH and reads common PATH assignments in startup
order: `~/.zprofile`, then `~/.zshrc`. Existing entries leave shell files unchanged
when later assignments preserve or explicitly restore the local bin directory.
If `~/.zshrc` removes that entry or uses an unsupported PATH assignment without
explicitly restoring local bin afterward, automatic setup requires a manual edit
and leaves both files untouched, including when `~/.zprofile` does not exist yet.
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
cloudgateway version               # Also available as -v
cloudgateway help auth login
cloudgateway auth login --no-qr
cloudgateway auth status --json
cloudgateway status                # VPN details, routing mode, and auth
cloudgateway mode status           # Routing mode only; bare mode is shorthand
cloudgateway mode mesh             # Mesh only, with ordinary internet outside the VPN
cloudgateway mode full             # Internet and mesh through the VPN (default)
cloudgateway list --region us-east-1
cloudgateway list --refresh --json
cloudgateway ls -l                 # VPN id, tunnel IP, connection URL, owner email
cloudgateway up '<client-uuid>'
cloudgateway up sanjose 1          # Also accepts us-sanjose-1 or California
cloudgateway add sanjose "Mac mini"
cloudgateway add us-sanjose-1 "Work Mac" --json
cloudgateway up                    # This account's last selection
cloudgateway status --operation '<operation-id>' --json
cloudgateway refresh
cloudgateway auth logout
cloudgateway down
cloudgateway down chicago 2        # Stop only this config
cloudgateway remove '<client-uuid>' --yes
cloudgateway remove sanjose 1 --yes
cloudgateway remove '<client-uuid>' --yes --json --non-interactive
cloudgateway doctor --json
cloudgateway update                # Update the extension from the installed app
cloudgateway update --allow-disconnect --json
```

### Routing modes and status

The menu's **Mode** submenu and `cloudgateway mode full|mesh` share one
preference per account on this Mac. **Full** is the default and keeps regional
VPN DNS and internet egress. **Mesh only** carries CloudGateway tunnel addresses
through the selected region while ordinary internet traffic and DNS use the
Mac's normal connection. Ordinary DNS no longer receives CloudGateway's AdGuard
filtering in Mesh only. Both modes retain the same mesh access permissions.

Changing mode while disconnected saves it for the next connection. Changing
mode while connected briefly stops and restarts the same client. This can
interrupt mesh sessions and change the public IP used by internet sessions.
The controller owns confirmed work even if the menu closes or CLI detaches.
Mode changes do not create a new client, rotate keys, or change server mesh
membership. Cross-region access still requires the existing mesh and account
ACLs. Mesh only uses `10.0.0.0/16` and `fd42:42:42::/48`; overlapping local LAN
routes can affect reachability. This is a routing preference, with no added
kill switch or server-enforced ban on internet egress.

`status` retains its VPN, observation, config, operation, and update details,
and adds mode and auth. `status --operation` retains its existing lookup
behavior and includes the current observed state. `mode status` (or `mode`)
shows mode only. `auth status` keeps the focused auth details. Selected mode
and active mode can differ during a switch or failed start. Unknown or
unavailable mode is reported explicitly. A signed-out account can still have
a connected VPN, and retained credentials alone do not prove verified access.
Compatible status from a different build keeps coarse VPN information when
mode or auth information is unavailable.

### Client commands

`add <region> <name>` creates a client for the signed-in account. Both arguments
are required. Names are trimmed, must contain 1–80 characters without control
characters, and need quotes when they contain spaces. Regions accept the full ID,
display name, or city alias, for example `us-sanjose-1`, `California`, or `sanjose`.
The controller loads enabled creation regions, including regions where this
account has no clients. Unknown or ambiguous regions fail with available IDs.
A region with full or unverified capacity cannot be used.

Creation uses the same acceptance/confirmation and operation lookup as VPN
mutations. JSON results include `data.command = "add"` and
`data.creation = {"regionId": "us-sanjose-1", "name": "Mac mini"}`. A successful
creation leaves the VPN unchanged. Run `cloudgateway ls` to get the new client's
UUID. If the inventory refresh fails after creation, success includes the
`inventory_not_refreshed` warning. After a timeout or lost confirmation, look up
the operation before retrying, since another add could create a duplicate client.
Ordinary HTTP creation failures, including quota/capacity and server errors,
report `operation_unknown` (exit 10) because the current API error does not prove
whether the request changed cloud state. Inspect inventory before another add.
Actual HTTP 401/403 still invalidate account access.

Local Disconnect and `down` remain available while add is reserved or awaiting
cloud work. Stopping does not cancel add. Each command keeps its own operation
ID and result for lookup, including when they finish in either order. The menu
keeps Disconnect available while connect, refresh, and another add remain blocked.

`ls` aliases `list`. Rows show a region-local index starting at 1, client name
and owner email, client UUID, and any connection/selection/unavailable state.
`list --long` and `ls -l` show the iOS-style details without repeating the region.
Connection URL prefers the server hostname, then IPv4. Saved configs without
owner metadata show `Unknown` offline. Installation labels stay hidden.

`up`, targeted `down`, and `remove` accept either a client UUID or a region plus index.
Regions accept full IDs, display names (quote names containing spaces), or city
aliases such as `sanjose`. Ambiguous aliases require a full region ID. Unknown
regions return usage errors, including in `list --region`. Indices follow the
current inventory and can change after refresh or offline fallback. Rerun `ls`
after inventory changes and use UUIDs in scripts. An unavailable config keeps
its index. A targeted `down` never stops a different active config and requires
authorized inventory, including existing offline authorization.

`remove` permanently deletes the cloud client and revokes its WireGuard peer.
Every invocation requires an explicit selector and `--yes`, including JSON and
noninteractive use. `--yes` acknowledges permanent deletion, with no terminal
prompt. Missing consent or a selector fails locally before controller connection.
Removal never infers the last selection. `--yes` is only valid for `remove`, and
value forms such as `--yes=false` are rejected. Help needs neither consent nor
controller access.

Removal resolves the selector once from settled account inventory and sends that
exact target to the controller. Cached rows can identify it, but deletion always
requires fresh online authorization. Disabled regions, missing configs, and clients
never installed on this Mac remain valid removal targets. An active target,
including connecting, reasserting, or disconnecting, fails with `client_active`
(exit 4). Disconnect that client explicitly and wait for it to stop before removing
it. Consent never authorizes a disconnect, and unrelated VPNs stay running.

A visible completed result prints `Client removed`. Verified cloud deletion with
`local_cleanup_incomplete` or `inventory_not_refreshed` still succeeds (exit 0)
and reports the warning. Stop an active leftover profile explicitly before local
cleanup, then refresh inventory. The operation does not delete retained System
Keychain secrets. After logout or an account change, account-bound outcomes and
warnings are hidden. A redacted success prints `Command completed`, with null
result, target, and warning fields in JSON.

The CLI flushes the accepted operation ID before confirming removal. An output
failure leaves the reservation unconfirmed. Once confirmed, caller timeout,
Ctrl-C, lost replies, or SSH detach stop observation while controller work can
continue. Keep the ID and run `cloudgateway status --operation '<operation-id>'`.
An unknown result (exit 10) never triggers an automatic resend. If lookup remains
unknown, run `cloudgateway refresh` online, then `cloudgateway ls` and inspect the
original client UUID before another manual removal attempt. Indices can change
during recovery, so use the original UUID instead of repeating a region/index.

Unconfirmed reservations expire after 30 seconds. Persisted receipts prevent
replay for 600 seconds from acceptance. The removal result lasts 600 seconds from
completion unless a new ordinary command is accepted or the process exits.
Creation uses a separate result slot and does not replace the removal result.
These clocks are independent. Restart can return unknown without redispatch while
the receipt is retained. Expiry never proves whether deletion occurred, and a
fresh CLI invocation creates a new request rather than extending replay protection.

`up` uses the controller's authorized inventory/cache policy, installs or replaces
an eligible stored config when needed, and reports
**VPN start requested** once macOS accepts the start. A later observed connected
state is separate. An unchanged active config reports already active. Offline
use is limited to this account's previously authorized saved configs.

`refresh` and `list --refresh` await their own online authorization/inventory
result without reconnecting. `auth logout` ends the controller session and hides
account data while retaining the VPN, profiles, secrets, and caches. A cleanup
failure is reported explicitly. Bare `down` works while signed out and succeeds
only after a confirmed local stop, including an already-stopped state. Quit only
detaches the menu.

Network failures print `Waiting for network… Try again soon.` and exit with code 6
without retrying. Ordinary mutations omit extra failure details. Diagnostic
reports, explicit operation lookups, cached inventory, and update details remain
visible. JSON keeps the structured error and operation details.

Common options are `-h`/`--help`, `--json`, `--non-interactive`, and
`--timeout <positive-finite-seconds>`. Reads and mutations default to 30 seconds,
and `update` defaults to 300 seconds to cover stop, activation, readiness, and reconnect.
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
automatically. For ordinary VPN commands, only the active/latest result is retained in memory for ten
minutes. A newer result, app replacement, crash, or reboot can end recovery
earlier. Unknown/expired results do not establish whether a VPN action ran.
Operation lookup reports the current observed tunnel with the same config ID,
observation time, and freshness as ordinary `status` when using the current
controller build. The tunnel may differ from the operation's target. Compatible
older/different builds retain coarse status without account details.
Login cancellation/deadline cleanup targets only that attempt. Unexpected
frontend loss leaves controller polling bounded by the approval expiry.

`doctor` reads setup and supported diagnostic evidence without approving an
extension, signing in, refreshing inventory, writing preferences, or changing
the VPN. Checks cover installed resources and identity, link/PATH, controller,
extension, preferences, credentials/access, network path, DNS, dashboard HTTPS,
and optional known-region health. Unsupported or uninitialized evidence stays
unknown. Required setup failure takes exit precedence over required online
failure; a caller deadline returns partial results.

### Update from the CLI or SSH

`cloudgateway update` installs/activates the VPN extension bundled in the signed
app already installed at `/Applications/CloudGateway.app`. It does not download
a release or build/install the app. Initial desktop setup remains in the GUI,
and `doctor` never starts an update.

```sh
cloudgateway doctor
cloudgateway update
# If connected, explicitly allow the update to stop and restore the VPN:
cloudgateway update --allow-disconnect
# After reconnecting SSH, inspect the operation ID printed before execution:
cloudgateway status --operation '<operation-id>' --json
```

An already matching extension is a no-op and leaves the VPN running. Otherwise,
an active VPN requires `--allow-disconnect`. The controller saves the current
client's stable identifier, confirms the local stop, updates the extension,
checks its authenticated identity, and requests a start of the same client.
Normal authorization/config revision rules apply. It does not use a later last
selection, switch to another client, or stop a different VPN that became active.
If the VPN was disconnected when the update was reserved, it stays disconnected.

The controller saves update intent before effects and owns the OS request. The
CLI flushes the accepted operation ID before confirming execution. A lost SSH
connection, caller timeout, or Ctrl-C after confirmation detaches observation and
leaves the update running. **If SSH uses this VPN, accepting disconnection can
drop the SSH session.** The controller continues the stop/update/reconnect flow.
An accepted reservation that was never confirmed expires without changes.

One private, bounded update record survives controller restart. Recovery on the
next controller start checks actual extension/profile state before continuing;
an initially off update never starts a tunnel. Pending updates remain observable,
and a terminal update result is retained for ten minutes. The journal stores no
WireGuard config, key, or auth token. A newer `down`, scoped stop of the captured
client, logout, or account change suppresses automatic reconnect. If persistence
fails, local stop remains available and reports any suppression durability warning.

Apple may require approval or a restart. The CLI returns exit 4 with that specific
pending state and operation ID while the durable workflow remains pending. Use
the GUI/System Settings or restart only when that outcome is reported. A successful
activation callback still needs authenticated readiness before reconnect. An
update failure leaves the VPN off; reconnect success means start submitted or
already active, not a claim that traffic connectivity was verified.

JSON stdout is NDJSON schema version 1. Each line is a complete object with
`schemaVersion`, `type`, `command`, `operationId`, `data`, and `error`. Reads emit
one result. Login first emits `login_required`; VPN mutations first emit
`accepted`, then a final result/error when available. Client creation and removal
use the same records. Removal results have `data.command = "remove"`, with the
typed operation outcome and warning separate from the observed tunnel state.
Errors have stable `code`, sanitized `message`, and nullable `suggestion`.
Unavailable fields are explicit
nulls; observation timestamps are UTC. Requested action, command outcome, and
observed tunnel state are separate. Additive fields retain version 1 field
types. Human diagnostics use stderr; JSON has no progress text or ANSI escapes.
Inventory records add `clientId`, region-local `index`, and nullable
`connectionUrl`. Existing `configId` fields keep their compound
`FirebaseUID/regionId/clientId` value. `--long` changes human formatting only,
so JSON returns the same complete metadata with or without it. Version aliases
also support `--json` and never connect to the controller.
Update/status records add an `update` object when relevant, with the durable
phase, target identity, reconnect decision, and account-filtered config ID.
Old records without update work retain their existing shape.
Combined status adds nullable `mode` and `auth` objects. Mode contains
`selectedMode`, `activeMode`, tunnel state, observation freshness, and observation
time. Serialized mode values are `full` and `mesh`. A missing active mode is
interpreted with tunnel state and freshness, so a stopped tunnel differs from
unknown applied mode. Focused `mode status` returns that mode object directly.
Auth uses the same state and access evidence as `auth status`. Different-build
compatible status leaves both new objects null when unavailable.

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

Run `./scripts/test.sh macos` for host-free tests, strict Periphery scans,
unsigned arm64 builds, packaging checks, and static CLI checks in temporary homes.
Add `--signed` for signing/profile/entitlement inspection; use `apple` for both
platforms with shared tests once. Automated checks leave the installed app,
shell files, extension, and VPN untouched.

For a signed build and local install without the test suite, use
[Quick Deployment](../../../docs/quick-deployment.md#install-macos-app-for-local-testing).
It bumps the synchronized app/extension build, verifies the bundle, and replaces
`/Applications/CloudGateway.app`. Follow it with `cloudgateway update`; use
`--allow-disconnect` when explicitly allowing stop/update/reconnect. Initial
setup and Apple approvals still require the GUI.

See the [development runbook](../../../docs/apple-macos-development.md) for
controller handoff, signing, storage, and the runtime checklist. The reviewed
stack passed user-reported signed runtime checks on 2026-10-24, including
pre-desktop SSH/Keychain access; see the
[acceptance record](../../../docs/apple-macos-release.md#runtime-acceptance-2026-10-24).
Future runtime changes require relevant manual checks.

For notarized DMGs, version/baseline rules, resumption, and publication, use the
[release guide](../../../docs/apple-macos-release.md).
