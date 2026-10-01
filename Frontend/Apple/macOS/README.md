# CloudGateway macOS

Future native macOS menu bar app and packet-tunnel system extension.

No macOS app or packet-tunnel targets exist yet. The implementation plan is
[TODO/macos-app.md](../../../TODO/macos-app.md).

The containing app is an `LSUIElement` menu bar agent using `NSStatusItem` and
`NSMenu`, with no dashboard window. React owns provider sign-in and account
management, and the Python API owns the device-auth exchange. Admin dashboards
stay on the site or mobile app. Small device-code and permission dialogs are
allowed.

Import `CloudGatewayAppCore` for suitable Firebase-free workflows and
`CloudGatewayKit` for VPN/config contracts. Supply native lifecycle, menu,
session/inventory, IPC, notification, and identifier adapters. Do not compile
iOS app sources or assume the entire iOS view model is needed unchanged.

The macOS packet-tunnel system extension imports `CloudGatewayKit`, not AppCore.
It should instantiate
`CloudGatewayTunnelHealthMonitor`, which encapsulates the shared coordinator,
artifact driver, and effect-submission arbiter. The extension also reuses the
notification-registration fence, `CloudGatewayTunnelHealthTiming`, snapshot
types, and shared notification contract through macOS adapters without forking
the iOS detector or adding another health timer. Storage and notification
delivery must respect the root/user boundary below.

## Menu App Dependency Boundary

| Workflow | Reusable product | Native macOS composition |
|---|---|---|
| Auth session | AppCore auth contracts and `CloudGatewayFirebaseAuthAdapter` | Browser device flow, custom-token session adapter, and cancellation. No native Apple/Google provider UI. |
| Client inventory | AppCore repository contracts and document mappers where needed | A containing-app repository limited to menu workflows. No native admin panel. |
| Apex and regional APIs | `CloudGatewayControlPlaneClient`, DTOs, URL validation, error mapping, and bounded session from `CloudGatewayAppCore` | Inject the origin host; no platform HTTP client rewrite |
| App state and commands | AppCore selection and workflow contracts where they fit | Minimal menu state and composition. Reuse the iOS view model only where its dependencies fit. |
| VPN/config and offline install state | Kit config manager, VPN manager, models, parser, and storage protocols | User inventory cache and extension-owned VPN secrets through authenticated IPC. |
| Health presentation | AppCore health-reader contract and Kit snapshot types | Read safe health state through IPC. The user app owns notification permission and delivery. |

Menu behavior, onboarding dialogs, app lifecycle, and launch-at-login policy
remain native. Account/client management opens the site.

## System Extension Storage Boundary

Use separate macOS identifiers and one macOS App Group claimed by both targets.
The group is also the exact prefix of `NEMachServiceName`; do not prepend a Team
ID to a `group.` identifier. Provision both targets for the group. See the plan's
capability matrix and [Apple's App Group guidance](https://developer.apple.com/documentation/xcode/accessing-app-group-containers).

The extension's root context changes storage, IPC, process lifetime, and
dependency packaging. The plan's [storage and IPC section](../../../TODO/macos-app.md#macos-storage-and-ipc)
defines ownership and its [trap checklist](../../../TODO/macos-app.md#system-extension-traps-and-prevention)
defines validation. In particular, matching groups do not provide a shared
root/user directory or shared user Keychain. Full VPN configs remain in
extension-owned System Keychain storage and move through authenticated IPC only
for installation. Firebase sessions remain in the user app.

Do not pass the concrete iOS Keychain store or App Group health file reader to
macOS composition unchanged. Add adapters behind the existing contracts and
validate them on signed hardware before claiming parity.

## Packet-Tunnel Dependency Boundary

The macOS packet-tunnel target should link only `CloudGatewayKit`, WireGuardKit,
and needed Apple networking, IPC, Security, and logging frameworks. It must not
link `CloudGatewayAppCore`, Firebase, Google Sign-In,
SwiftUI, UIKit, or AppKit.

The current iOS provider is the behavior reference, not a source directory for
the macOS target. Reuse happens through named shared modules; the macOS target
must not compile files from `Frontend/Apple/iOS/`.

| Boundary | Reuse on macOS | Initial macOS ownership |
|---|---|---|
| Detection and recovery | Instantiate the public `CloudGatewayTunnelHealthMonitor`. It encapsulates the coordinator, evaluator/recovery/path/persistence policies, artifact driver, and effect arbiter; inject shared scheduling and timing APIs only when production defaults are unsuitable. | No second detector, policy graph, or health timer. |
| Runtime | Reuse `CloudGatewayTunnelHealthRuntimeAdapter`, recovery result/capability types, and `CloudGatewayTunnelRuntimeStats.parse`. | A small WireGuardKit adapter maps runtime reads and binding refresh callbacks. Backend restart reports `unsupported` until the fork exposes and device-tests a public macOS entry point. |
| Persistence | Reuse outward snapshot types and FIFO/generation contracts. Use `CloudGatewayTunnelHealthStore` only with an appropriate extension-owned location. | An IPC reader exposes safe state to the user app. No direct root/user App Group file sharing. |
| Notifications | Reuse `CloudGatewayTunnelHealthNotification`, the adapter contract, and `CloudGatewayTunnelHealthNotificationRegistrationFence`. | Bridge safe notification effects to the user app through IPC, preserving epochs and reconciliation. Verify user-session delivery on signed hardware. |
| Start and stop | Reuse `CloudGatewayTunnelPendingStartBarrier`, `CloudGatewayTunnelStartStopJoin`, `CloudGatewayTunnelStopSubmission`, `CloudGatewayTunnelStopCompletion`, and monitor stop tokens. | The `NEPacketTunnelProvider` subclass owns callbacks, provider lifecycle, adapter stop submission, the five-second physical-stop deadline, and target-specific capabilities. |
| Path changes | Reuse `CloudGatewayTunnelPathDescriptor` and shared path policy. | A macOS `NWPathMonitor` source deduplicates meaningful fingerprints and emits monotonically increasing route generations. |
| Configuration | Reuse safe provider-configuration metadata, secret-reference contracts, raw WireGuard models, and the parser. | Resolve user-bound secret handles in an extension-owned System Keychain adapter. Full configs never enter App Group files or VPN preference dictionaries. |

## Code That Remains Platform-Owned

The following iOS-private implementations in
`CloudGatewayTunnel/PacketTunnelProvider.swift` describe adapter roles, not
types to copy into a shared target:

* `PacketTunnelProvider` owns the iOS Network Extension entry points,
  WireGuard adapter construction, provider-configuration access, OS logging,
  queues, and stop deadline;
* `IOSTunnelHealthRuntimeAdapter` is the iOS WireGuardKit callback bridge;
* `IOSTunnelHealthNotificationAdapter` and
  `IOSTunnelHealthNotificationReconciliation` are the iOS User Notifications
  bridge;
* iOS target Info.plist, entitlements, app/provider identifiers, provisioning,
  and WireGuard Go linkage remain iOS-only.

The macOS target supplies corresponding native implementations with macOS
identifiers, entitlements, signing, and capabilities. It does not reuse iOS
production identifiers.

## Extraction Candidates After A Second Consumer Exists

Do not extract these merely to shorten the iOS provider. First implement and
device-test the macOS equivalent, then share only the proven common contract:

* `IOSTunnelHealthLifecycle`, which currently combines start identity,
  monitor/path ownership, and joined stop behavior with concrete iOS adapters;
* `IOSTunnelHealthStopDeadline`, if macOS proves the identical callback-loss and
  five-second stop contract;
* `IOSTunnelHealthPathSession` and `HealthPathFingerprint`, after macOS
  sleep/wake and interface behavior verifies the same status, interface,
  gateway, IPv4, IPv6, and DNS fingerprint;
* parsed-config-to-WireGuardKit mapping, in a support module that may depend on
  WireGuardKit but never makes WireGuardKit a `CloudGatewayKit` dependency.

## Required Ordering And Safety Invariants

The macOS implementation is not equivalent until it preserves all of these:

1. Every start attempt has an identity. Stop synchronously prevents a pending
   start or monitor from installing, every completion path closes the pending
   start, and joined stop waits for both pending start and monitor cleanup.
2. Runtime, recovery, persistence, and notification operations remain
   callback-driven and logically bounded. Missing callbacks cannot block the
   monitor; late or duplicate callbacks are session-qualified and harmless.
3. Start identity, monitor generation, path route generation, artifact
   generation, effect admission, and notification epoch all reject stale work.
   An old clear or withdrawal cannot erase replacement-session state.
4. Normal stop closes effect admission, cancels the path source, drains already
   admitted FIFO effects, and then submits adapter stop. The five-second
   deadline cancels queued effects, reaches adapter stop, performs idempotent
   best-effort cleanup, and completes exactly once even when callbacks vanish.
5. Detection never automatically disconnects the VPN or introduces a traffic
   probe/fallback. Do not log raw runtime counters, keys, endpoints, configs,
   tokens, DNS queries, packet metadata, or destination metadata.
6. Exactly one shared `CloudGatewayTunnelHealthMonitor` owns detection for the
   active tunnel. No macOS-specific detector or polling timer is allowed.

The menu app requests notification authorization and consumes health state over
IPC. Detection remains in the system extension while a tunnel is active,
independently of menu presentation. Planned Sign Out and Disconnect and Quit
request a bounded stop. Notification delivery requires the user-session app;
do not promise delivery when it is absent. Bundle, provider, group, service,
and storage configuration remain injected.

WireGuardKit stays outside `CloudGatewayKit`. The pinned fork exposes binding
refresh on macOS, but its public backend-restart entry point is currently
iOS-only. The initial macOS runtime adapter should report backend restart as
unsupported; the shared bounded recovery policy will still confirm and notify.
Exposing macOS backend restart in the fork is a separate implementation and
device-validation task.

## Validation Before Claiming macOS Parity

On a signed Mac and extension, verify:

* the pinned WireGuard fork and Go bridge link for the target architecture, and
  runtime-read and binding-refresh callbacks complete correctly;
* `NWPath` fingerprints and route generations across sleep/wake, Wi-Fi,
  Ethernet, DNS/gateway changes, and interface churn;
* user-session notification delivery, authorization, and reconciliation;
* authenticated IPC, user/config-bound secret handles, System Keychain access,
  and root/user isolation under real entitlements;
* activation/replacement from `/Applications`, embedded profiles, Mach service
  prefixing, relocated dependencies, and repeated sessions in one process;
* start/stop ordering, callback loss, stale sessions, and the bounded stop
  deadline with deliberately late or missing callbacks.

Simulator behavior is not evidence for these extension, entitlement, sleep,
WireGuard, notification, or deadline contracts.

Remaining macOS work includes app and extension targets, entitlements, signing,
menu/browser-auth composition, macOS storage/IPC adapters, and the signed
hardware matrix. None of that work is implemented or verified yet.
