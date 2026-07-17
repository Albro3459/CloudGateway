# CloudGateway macOS

Future native macOS app project home.

No macOS app or packet-tunnel targets exist yet.

The future macOS app should share VPN configuration through `CloudGatewayKit`.
Its packet-tunnel extension should instantiate
`CloudGatewayTunnelHealthMonitor`, which encapsulates the shared coordinator,
artifact driver, and effect-submission arbiter. The extension also reuses the
notification-registration fence, `CloudGatewayTunnelHealthTiming`,
`CloudGatewayTunnelHealthStore`, and the shared notification contract without
forking the iOS detector or adding another health timer.

## Packet-Tunnel Dependency Boundary

The macOS packet-tunnel target should link only `CloudGatewayKit`, WireGuardKit,
and the Apple `NetworkExtension`, `Network`, `UserNotifications`, and `os`
frameworks. It must not link `CloudGatewayAppCore`, Firebase, Google Sign-In,
SwiftUI, UIKit, or AppKit.

The current iOS provider is the behavior reference, not a source directory for
the macOS target. Reuse happens through named shared modules; the macOS target
must not compile files from `Frontend/Apple/iOS/`.

| Boundary | Reuse on macOS | Initial macOS ownership |
|---|---|---|
| Detection and recovery | Instantiate the public `CloudGatewayTunnelHealthMonitor`. It encapsulates the coordinator, evaluator/recovery/path/persistence policies, artifact driver, and effect arbiter; inject shared scheduling and timing APIs only when production defaults are unsuitable. | No second detector, policy graph, or health timer. |
| Runtime | Reuse `CloudGatewayTunnelHealthRuntimeAdapter`, recovery result/capability types, and `CloudGatewayTunnelRuntimeStats.parse`. | A small WireGuardKit adapter maps runtime reads and binding refresh callbacks. Backend restart reports `unsupported` until the fork exposes and device-tests a public macOS entry point. |
| Persistence | Reuse `CloudGatewayTunnelHealthStore` and its FIFO `CloudGatewayTunnelHealthStoreAdapter`. | Supply macOS app-group identifiers and matching entitlements. Persist only the outward health snapshot. |
| Notifications | Reuse `CloudGatewayTunnelHealthNotification`, the adapter contract, and `CloudGatewayTunnelHealthNotificationRegistrationFence`. | An extension adapter owns `UNUserNotificationCenter` authorization observation, request creation, pending/delivered reconciliation, and removal. The containing app owns permission requests and foreground presentation. |
| Start and stop | Reuse `CloudGatewayTunnelPendingStartBarrier`, `CloudGatewayTunnelStartStopJoin`, `CloudGatewayTunnelStopSubmission`, `CloudGatewayTunnelStopCompletion`, and monitor stop tokens. | The `NEPacketTunnelProvider` subclass owns callbacks, provider lifecycle, adapter stop submission, the five-second physical-stop deadline, and target-specific capabilities. |
| Path changes | Reuse `CloudGatewayTunnelPathDescriptor` and shared path policy. | A macOS `NWPathMonitor` source deduplicates meaningful fingerprints and emits monotonically increasing route generations. |
| Configuration | Reuse provider-configuration keys, Keychain secret references/store, raw WireGuard models, and the parser. | The provider reads its injected identifiers and maps parsed values to WireGuardKit types. Full configs remain in shared Keychain storage, never app-group files. |

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

The GUI app will request notification authorization and read the shared health
snapshot. Detection remains in the future packet extension so it continues
while the GUI is backgrounded, closed, or signed out. Bundle, provider,
app-group, and Keychain identifiers remain injected platform configuration.

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
* pending/delivered notification reconciliation plus containing-app
  authorization and foreground presentation;
* app-group snapshot and shared Keychain access under real entitlements;
* start/stop ordering, callback loss, stale sessions, and the bounded stop
  deadline with deliberately late or missing callbacks.

Simulator behavior is not evidence for these extension, entitlement, sleep,
WireGuard, notification, or deadline contracts.

Remaining macOS work includes app and extension targets, entitlements, signing,
UI/Firebase composition, adapter compile tests, and the signed real-device
matrix. None of that work was implemented or verified by this extraction.
