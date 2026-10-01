# macOS CLI (Deferred)

Status: **deferred, not scheduled.** Not part of the macOS v1 plan. See
`TODO/macos-app.md` for the plan of record.

The v1 app is a menu bar agent with browser auth and a packet-tunnel system
extension. Admin and account/client management stay on the site or mobile app.
The proposals below remain future research, not approved implementation. Any
CLI must preserve the plan's authenticated IPC and user/root storage boundary;
it must not assume access to the extension's group files or VPN secrets. Account
inventory and caches must preserve the menu app's Firebase UID filtering.

Kept because the research below is load bearing for any future attempt, and
because it answers "can we just bolt a CLI on later" concretely. Nothing here
should be built without re-confirming the entitlement spike in "Blocking
Unknown" first.

## Goal

A `cloudgateway` command line tool for agent and scripting use: auth, status,
list, list by region, install, toggle, details, add and remove clients.

Name is `cloudgateway`, no `cg` alias. `cg` is a plausible collision.

## Why A Separate Binary Cannot Work

Restricted entitlements such as
`com.apple.developer.networking.networkextension` must be authorized by a
provisioning profile, and on macOS that profile lives at
`Contents/embedded.provisionprofile` inside an app bundle. A standalone Mach-O
has nowhere to carry one.

A separate binary would also have a different code signing identity, and
`NETunnelProviderManager` scopes configurations to the creating app's identity.
It could not see, start, or remove configurations the GUI created.

## The Design That Would Work

One binary, two modes. An app bundle's main executable is not required to call
`NSApplicationMain`.

```
/Applications/CloudGateway.app
├─ Contents/MacOS/CloudGateway          the one signed, entitled binary
├─ Contents/embedded.provisionprofile
└─ Contents/Library/SystemExtensions/…CloudGatewayTunnel.systemextension

/usr/local/bin/cloudgateway → /Applications/CloudGateway.app/Contents/MacOS/CloudGateway
```

`main.swift` dispatches on argument count: arguments run CLI mode and exit, none
runs the GUI.

Executing `Contents/MacOS/CloudGateway` directly still resolves `Bundle.main` to
the app bundle, so bundle identifier, provider bundle ID lookup, Keychain access
group, and app group container behave identically in both modes. The CLI does
not borrow the app's identity; it is the app, invoked differently. That is what
makes GUI-installed configurations visible and removable from the CLI.

## No Additional Daemon Is Needed

The tunnel runs in the system extension, which the system launches on
`startVPNTunnel()`. Configurations live in system VPN preferences. A process
that starts a tunnel and exits leaves the VPN running.

## System Extensions Framework Is GUI Only

Per Apple DTS (developer.apple.com/forums/thread/776759), the System Extensions
framework is meant to be called from a GUI application.
`OSSystemExtensionRequest` holds its delegate weakly, so a command line tool
without a run loop and a strong reference never receives `didFinishWithResult`
or `didFailWithError`.

This constrains activation only, and activation was always GUI-only anyway.

| API | GUI | CLI |
|---|---|---|
| `OSSystemExtensionManager.submitRequest` | yes, delegate held in a static | never |
| `NETunnelProviderManager.loadAllFromPreferences` | yes | yes |
| `saveToPreferences` / `removeFromPreferences` | yes | yes |
| `connection.startVPNTunnel` / `stopVPNTunnel` / `.status` | yes | yes |

Only the first row is the System Extensions framework. The rest are
NetworkExtension configuration and session APIs and carry no GUI requirement.

## Blocking Unknown

Before building any of this, verify that `Contents/MacOS/CloudGateway`, executed
directly from a shell, retains its NE entitlements and resolves `Bundle.main` to
the app bundle. Sign a trivial bundle, exec the binary from Terminal, call
`loadAllFromPreferences()`, and confirm configurations come back with no
entitlement error. Roughly an afternoon.

Second unknown, narrower: whether `NETunnelProviderManager` works in a process
with no Aqua session. Terminal.app runs inside the GUI login session, so local
use including local agents should be fine. SSH is unverified.

## Prerequisites In The Shared Core

These were removed from the v1 plan because a single GUI consumer does not need
them and the Periphery scans would fail the build on unused code.

* **`CloudGatewayTunnelCoordinator`.** `CloudGatewayViewModel` holds tunnel
  sequencing a non-UI consumer also needs: `activeTunnelClient` (line 917), pure
  derivation enforcing single-tunnel semantics and deliberately counting
  `.connecting` as active; `switchTunnel` (line 936), stop-then-start ordering
  mixed with `togglingClientId`; `pullFreshAndInstall` (line 890),
  auth-generation fencing mixed with `selectedClientId` and `apply()`. Extract
  the rules, leave the UI state. Roughly 100-150 lines move.
  Two callers reimplementing this ordering independently is how you end up with
  two tunnels up, or a stale install applied under a new session.
* **`CloudGatewayStateLock`.** An exclusive `flock` on a file in the app group
  container, taken by every mutation. The mutating surface is already isolated
  in `CloudGatewayConfigManager`: `install`, `startTunnel`, `stopTunnel`,
  `removeTunnel`, `removeInstalledConfigIfMatches`. Use `LOCK_EX | LOCK_NB` in a
  retry loop with a roughly ten second deadline so the CLI fails fast rather
  than hanging. The lock is advisory, so route all mutations through the
  coordinator to make that structurally true. Extension-owned secret mutations
  need separate IPC serialization; a user app group file lock does not protect
  root-owned extension state. macOS v1 has no health snapshot writer.
* **`CloudGatewayClientSelector`.** Resolves `(region?, nameOrIndex?)` to one
  client or a typed ambiguity error.

## Auth

v1 uses the browser device flow and hands the resulting Firebase custom token to
the SDK via `signIn(withCustomToken:)`. A short-lived CLI process would rather
not carry the Firebase SDK, so a CLI would likely want REST implementations of
`CloudGatewayAuthServicing` and `CloudGatewayClientRepository` over Identity
Toolkit and Firestore REST v1, plus its own Keychain token store.

Because both sit behind existing protocols, that is a substitution rather than a
rewrite. Rough cost: roughly 700 lines against roughly 260 for the SDK path.

The planned device flow endpoints and React `/#/auth/code` page can support a
future CLI after its credential and authorization requirements are checked.
They are not implemented yet.

## Proposed Surface

Three distinct operations share the word install. Keep the vocabulary separate:
*activate* the system extension, GUI only; *install* a client's VPN config;
*install the command line tool*, the symlink.

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
`--yes` or no TTY it installs without prompting; `--no-install` fails instead.

Selector rules:

* ordering is deterministic, region `displayOrder` then client name, so indices
  stay stable between `list` and `start` without persisting state;
* name matching is exact, then case-insensitive, then unique prefix;
* ambiguity prompts on a TTY and exits non-zero listing candidates otherwise.

Indices shift when clients are added or deleted. They are a human affordance.
`--json` emits stable `clientId`s and agents should key on those.

`list` answers from the app group cache plus local installed statuses with no
network round trip. `--refresh` forces a fetch.

Every command takes `--json`. Stable exit codes. No interactive prompt unless
stdin is a TTY.

Never print private keys, full configs, endpoints, DNS queries, or peer
metadata, in any mode.

## Packaging

`CloudGatewayCLICore` should be a SwiftPM library so the CLI is `swift test`-able
with no Xcode, no signing, and no device, matching how `./scripts/test.sh apple`
already avoids `xcodebuild` for unit tests. Only the thin dispatch lives in the
app target.

CLI mode must never touch `NSApp`. AppKit is linked either way, which is fine,
but there is no Aqua session over SSH and `NSApplication.shared` will fail.

## Installing The Symlink

On a clean macOS `/usr/local/bin` is root-owned and often absent, so an
unsandboxed Developer ID app still cannot write there without privileges.

1. try `~/.local/bin/cloudgateway`, no privileges needed;
2. detect whether it is on `PATH` and offer to append to the shell rc;
3. offer `/usr/local/bin` as a secondary option with a copyable `sudo ln -s`
   one-liner.

No privileged helper. `SMJobBless` or `SMAppService.daemon` is a large amount of
machinery and another signing surface for one symlink.

## Rejected Alternative: A wg-quick Wrapper

`wg-quick` uses root plus `utun` plus wireguard-go and no NetworkExtension at
all. Wrapping it would mean two VPN implementations with divergent state, sudo
on every command, separate VPN preference state, and GUI tunnels and CLI
tunnels mutually invisible.

That is the exact divergence the shared core exists to prevent. It is a last
resort if the entitlement spike fails, not a plan.

The other fallback, preferred over wg-quick: the GUI owns all VPN mutation and
the CLI delegates over a Unix socket in the app group container, verifying the
peer's code signature against the team ID. Costs a wire protocol and makes the
CLI useless when the GUI is not running.
