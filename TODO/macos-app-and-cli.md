# macOS App And CLI Plan

Status: planning. No implementation yet.

Delivers a native macOS GUI and a `cloudgateway` command line tool that share
`CloudGatewayKit` and `CloudGatewayAppCore`, replacing the WireGuard app for
daily use.

## Decisions

| Decision | Choice |
|---|---|
| Distribution | Developer ID, notarized, DMG. Not Mac App Store. |
| Extension packaging | System extension (confirm against TN3134) |
| CLI name | `cloudgateway`. No `cg` alias. |
| CLI shipping | Same binary as the GUI, inside the app bundle |
| GUI shape | Normal window app plus a simple `NSMenu` status item. No popover. |
| Auth | Browser device flow against the CloudGateway React site |
| Auth SDKs on macOS | None. No Firebase SDK, no GoogleSignIn, no Sign in with Apple. |
| Admin panel | Not on macOS. Web dashboard keeps it. |

Mac App Store is ruled out because a sandboxed app cannot install the CLI
symlink, and system extensions need Developer ID distribution.

## One Binary, Two Modes

An app bundle is a directory whose main executable need not call
`NSApplicationMain`.

```
/Applications/CloudGateway.app
├─ Contents/MacOS/CloudGateway          the one signed, entitled binary
├─ Contents/embedded.provisionprofile   authorizes the NE entitlement
└─ Contents/Library/SystemExtensions/
   └─ …CloudGatewayTunnel.systemextension

/usr/local/bin/cloudgateway → /Applications/CloudGateway.app/Contents/MacOS/CloudGateway
```

`main.swift` dispatches on argument count: arguments present runs CLI mode and
exits, none runs the GUI.

This matters because executing `Contents/MacOS/CloudGateway` directly still
resolves `Bundle.main` to the app bundle. Bundle identifier, provider bundle ID
lookup, keychain access group, and app group container behave identically in
both modes. The CLI does not borrow the app's identity; it is the app, invoked
differently.

Consequences:

* the CLI carries `com.apple.developer.networking.networkextension` because it
  is the same signed Mach-O;
* configs saved by the GUI are visible and removable from the CLI, because
  `NETunnelProviderManager` scopes configurations to the creating app's signing
  identity and both modes share one;
* there is no IPC protocol, no daemon, and one implementation of every command.

A separate CLI binary would fail on all three. A standalone Mach-O has nowhere
to carry a provisioning profile, so it cannot hold a restricted entitlement, and
it would have a different identity that cannot see the GUI's configurations.

## GUI Is Required Only For Bootstrap

The tunnel runs in the system extension, which the system launches on
`startVPNTunnel()`. Configurations live in system VPN preferences. A process
that starts a tunnel and exits leaves the VPN running. No daemon is needed, and
the GUI does not need to be open for the CLI or the VPN to work.

Three things still require a GUI session, once per machine:

1. system extension activation, which prompts in System Settings;
2. the first `saveToPreferences()`, which prompts to add VPN configurations;
3. notification authorization for the dead-tunnel notification.

The CLI must detect each un-bootstrapped state and tell the user to launch
CloudGateway once, rather than failing obscurely.

## System Extensions Framework Is GUI Only

Per Apple DTS (developer.apple.com/forums/thread/776759), the System Extensions
framework is meant to be called from a GUI application. `OSSystemExtensionRequest`
holds its delegate weakly, so a command line tool without a run loop and a strong
reference never receives `didFinishWithResult` or `didFailWithError`.

| API | GUI | CLI |
|---|---|---|
| `OSSystemExtensionManager.submitRequest` | yes, delegate held in a static | never |
| `NETunnelProviderManager.loadAllFromPreferences` | yes | yes |
| `saveToPreferences` / `removeFromPreferences` | yes | yes |
| `connection.startVPNTunnel` / `stopVPNTunnel` / `.status` | yes | yes |

Only the first row is the System Extensions framework. The rest are
NetworkExtension configuration and session APIs and carry no GUI requirement.

Extension target gotchas, from the same threads:

* the container app must live in `/Applications` for sysex activation;
* `NEMachServiceName` in the extension `Info.plist` must be prefixed with the
  app group identifier. A mismatch leaves the extension stuck in
  `validating by category` and can crash `sysextd` and `nesessionmanager`;
* debug with `systemextensionctl`, and `lsregister` / `pluginkit` for appex.

## Layout

```
CloudGatewayKit/                        existing, unchanged
  CloudGatewayKit                       VPN, config, cache, tunnel health
  CloudGatewayAppCore                   facade, control plane, view models
    + CloudGatewayTunnelCoordinator     extracted sequencing, both modes
    + CloudGatewayClientSelector        name/index resolution, pure
    + CloudGatewayStateLock             cross-process flock

CloudGatewayRESTAdapter/                new package
    CloudGatewayIdentityToolkitAuth     → CloudGatewayAuthServicing
    CloudGatewayFirestoreRESTRepository → CloudGatewayClientRepository
    CloudGatewayDeviceAuthClient        browser device flow
    CloudGatewayTokenStore              Keychain

CloudGatewayCLI/                        new package
    CloudGatewayCLICore                 library: commands, resolution, output

macOS/CloudGateway.xcodeproj
    CloudGateway         main.swift dispatch, window UI, NSStatusItem menu
    CloudGatewayTunnel   sysex; links CloudGatewayKit and WireGuardKit only
```

`CloudGatewayCLICore` is a library so the whole CLI is `swift test`-able with no
Xcode, no signing, and no device, matching how `./scripts/test.sh apple` already
avoids `xcodebuild` for unit tests. Only the thin dispatch lives in the app
target.

## Shared Core Changes

`CloudGatewayKit` needs no changes. One file moves in `CloudGatewayAppCore`.

`CloudGatewayViewModel` accumulated tunnel sequencing that a non-UI consumer
also needs:

* `activeTunnelClient` (line 917) is pure derivation enforcing single-tunnel
  semantics, deliberately counting `.connecting` as active;
* `switchTunnel` (line 936) owns stop-then-start ordering, mixed with
  `togglingClientId`;
* `pullFreshAndInstall` (line 890) owns auth-generation fencing, mixed with
  `selectedClientId` and `apply()`.

Extract `CloudGatewayTunnelCoordinator` holding the rules. The view model keeps
UI state and delegates. Roughly 100-150 lines move.

This is not a correction of a bad design. The core was built for one consumer
shape and its protocol boundaries are why this plan is cheap. It simply never
had a consumer without a UI.

Doing this before either client exists is the point. Two callers reimplementing
the ordering independently is how you end up with two tunnels up, or a stale
install applied under a new session.

## Concurrency

The GUI and any number of CLI invocations are peers running the same core. The
mutating surface is already isolated in `CloudGatewayConfigManager`: `install`,
`startTunnel`, `stopTunnel`, `removeTunnel`, `removeInstalledConfigIfMatches`.

`CloudGatewayStateLock` wraps an exclusive `flock` on a file in the app group
container. Every mutation takes it. Use `LOCK_EX | LOCK_NB` in a retry loop with
a roughly ten second deadline so the CLI fails fast with "another CloudGateway
operation is in progress" instead of hanging.

The lock is advisory, so it only works if every writer takes it. Route all
mutations through the coordinator so that is structurally true.

The extension does not take this lock. It only writes the health snapshot, which
is already FIFO-guarded by `CloudGatewayTunnelHealthStoreAdapter`.

## Keeping The GUI Synced

`NEVPNStatusDidChange` is system-posted to any process holding a loaded manager,
so a CLI-initiated start updates the GUI's status item with no polling. That
covers the only thing that must update while the window is closed.

Client list and install state only matter when the UI is visible, so refresh on
window appear and on menu open. No file watcher in v1. If the status item later
needs to reflect CLI-driven config changes, a `DispatchSource` `.vnode` watcher
on the app group cache file is about thirty lines.

## Auth

Firebase has no device-code grant, so the control plane brokers one. The React
site already implements Apple, Google, and email/password, so one flow covers
all three and macOS needs no auth SDKs.

1. CLI or GUI calls `POST /api/device/code`, receives `device_code`, `user_code`,
   `verification_uri`, `expires_in` 300, `interval` 5.
2. It displays the URL and code and begins polling.
3. The user signs in on any device at the React site and confirms the code
   matches.
4. The page calls `POST /api/device/approve` with its Firebase ID token and the
   user code. The API verifies the token and records the approval.
5. Polling returns a Firebase custom token from `auth.create_custom_token(uid)`.
6. The client exchanges it via Identity Toolkit `signInWithCustomToken` for an
   ID token and a refresh token.

Step 5 to 6 is load bearing. A raw ID token would strand the client with a one
hour session; the custom token exchange is the only way to give a non-SDK client
a durable, self-refreshing session.

Backend work: device code endpoints on the apex API, not regional, since this is
account level. Pending codes in Firestore with a TTL. Needs `user_code` entropy,
single-use codes, poll rate limiting returning `slow_down`, and binding
`device_code` to `user_code`.

Anti-phishing: the approval page must display the code and require the user to
verify it matches their terminal. Never accept a prefilled link that
auto-approves. This is the known weakness of device flows and the whole reason
cross-device sign-in is safe.

Wire `cloudgateway auth logout` to `auth.revoke_refresh_tokens(uid)`, already
used at `Backend/API/src/firebase.py:357`.

Store the ID token alongside the refresh token so the common invocation skips a
refresh round trip.

## CLI Surface

Three distinct operations share the word install. Keep the vocabulary separate:

* activate: the system extension, GUI only, once per machine;
* install: a client's VPN config into system preferences, `cloudgateway install`;
* install the command line tool: the symlink, from the GUI.

```
cloudgateway auth login | logout | status
cloudgateway status                      auth state plus VPN state
cloudgateway list                        grouped by region, numbered per region
cloudgateway list california
cloudgateway list -l [region] [name|index]
cloudgateway install <region> <name|index>
cloudgateway uninstall <region> <name|index>
cloudgateway start <region> <name|index>
cloudgateway start <name>                prompts if ambiguous
cloudgateway stop                        stops whatever is active
cloudgateway stop <region> <name|index>
cloudgateway add <region> <name>         creates a client
cloudgateway remove <region> <name|index>
```

`start` on an uninstalled client prompts to install first, then starts. With
`--yes` or no TTY it installs without prompting; use `--no-install` to fail
instead.

`CloudGatewayClientSelector` resolves `(region?, nameOrIndex?)` to one client or
a typed ambiguity error:

* ordering is deterministic, region `displayOrder` then client name, so indices
  stay stable between `list` and `start` without persisting state;
* name matching is exact, then case-insensitive, then unique prefix;
* ambiguity prompts on a TTY and exits non-zero listing candidates otherwise.

Indices shift when clients are added or deleted. They are a human affordance.
`--json` emits stable `clientId`s and agents should key on those.

`list` answers from the app group cache plus local installed statuses with no
network round trip, using the existing offline and `staleTexts` handling.
`--refresh` forces a fetch.

Every command takes `--json`. Stable exit codes. No interactive prompt unless
stdin is a TTY.

Never print private keys, full configs, endpoints, DNS queries, or peer
metadata, in any mode.

## GUI Scope

Normal window app, not a popover. Popovers cost more in focus, dismissal, and
keyboard handling than they are worth here.

* window: sign-in, client table grouped by region, per-client toggle, detail
  disclosure, delete, add-client field;
* `NSStatusItem` with a plain `NSMenu`: current status, quick connect and
  disconnect, open window, quit;
* status item icon: template outline off, template filled on, plus connecting
  and unhealthy states from the shared health snapshot;
* a button to install the command line tool;
* sign-in uses the same device flow as the CLI, so there is one auth
  implementation and no auth SDKs.

Keep the offline and stale handling. It is free from `CloudGatewayConfigManager`
and it is what makes `cloudgateway list` fast.

No admin panel. The web dashboard keeps Server Health.

## Installing The Command Line Tool

On a clean macOS `/usr/local/bin` is root-owned and often absent, so an
unsandboxed Developer ID app still cannot write there without privileges.

1. try `~/.local/bin/cloudgateway`, no privileges needed;
2. detect whether it is on `PATH` and offer to append to the shell rc;
3. offer `/usr/local/bin` as a secondary option with a copyable `sudo ln -s`
   one-liner.

No privileged helper. `SMJobBless` or `SMAppService.daemon` is a large amount of
machinery and another signing surface for one symlink.

## Open Risks

1. **Spike first.** Verify that `Contents/MacOS/CloudGateway`, executed directly
   from a shell, retains its NE entitlements and resolves `Bundle.main` to the
   app bundle. Sign a trivial bundle, exec the binary from Terminal, call
   `loadAllFromPreferences()`, and confirm configs come back with no entitlement
   error. The whole design rests on this. It is an afternoon.
2. Whether `NETunnelProviderManager` works with no Aqua session. Terminal.app is
   in the GUI login session so local use, including local agents, should be
   fine. SSH is unverified. Test explicitly.
3. Developer ID Network Extension entitlement approval from Apple.
4. WireGuardKitGo building for macOS arm64. The fork's bridge is device-only
   today.
5. Backend restart is iOS-only in the fork, so macOS recovery reports
   `unsupported` initially. Accepted, per `Frontend/Apple/macOS/README.md`.
6. Confirm the appex versus sysex rule against TN3134 before creating the target.

## Fallback If The Spike Fails

Two options, in order of preference:

1. GUI owns all VPN mutation, CLI delegates over a Unix socket in the app group
   container, verifying the peer's code signature against the team ID. Costs a
   wire protocol and makes the CLI useless when the GUI is not running.
2. A separate `wg-quick` wrapper, unrelated to CloudGateway.

Option 2 is a last resort, not a plan. `wg-quick` uses root plus `utun` plus
wireguard-go and no NetworkExtension at all, so it means two VPN implementations
with divergent state, sudo on every command, no shared tunnel-health monitoring,
and GUI tunnels and CLI tunnels mutually invisible. That is the exact divergence
the shared core exists to prevent.

## Phases

| Phase | Work |
|---|---|
| 0 | Entitlement spike. Blocks everything. |
| 1 | Extract `CloudGatewayTunnelCoordinator`, add `CloudGatewayClientSelector` and `CloudGatewayStateLock`, all `swift test` covered |
| 2 | `CloudGatewayRESTAdapter`, device flow endpoints on the apex API, `/device` page on the React site |
| 3 | `CloudGatewayCLICore` against the REST adapter. `auth`, `status`, `list` work before any Xcode target exists |
| 4 | macOS app target, `main.swift` dispatch, sysex, WireGuardKitGo macOS build, entitlements, signing |
| 5 | GUI window, status item menu, CLI installer button |
| 6 | `./scripts/test.sh macos`, Periphery config, notarization and DMG release script mirroring `scripts/ios-release.sh`, docs |

Phases 1 through 3 are ordinary Swift with no Apple signing risk and carry most
of the logic. Phase 4 carries nearly all the risk.

## Validation

Beyond `./scripts/test.sh`, on a signed Mac verify:

* entitlements and `Bundle.main` in directly-executed CLI mode;
* sysex activation from `/Applications`, and `NEMachServiceName` app group
  prefixing;
* GUI-installed config removed from the CLI and the reverse;
* `flock` serialization with a GUI toggle and a CLI toggle racing;
* `NEVPNStatusDidChange` reaching the GUI from a CLI-initiated start;
* device flow across two machines, code expiry, and replay of a used code;
* the bootstrap prompts, and the CLI's messaging when un-bootstrapped.
