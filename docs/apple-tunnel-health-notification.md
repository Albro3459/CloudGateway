# Apple Tunnel Health Detection And Outage Notification

The iOS packet tunnel extension detects a dead VPN tunnel and, when notification
permission is available, raises one local notification plus an in-app warning
so the user can act. This document
describes why the feature exists, how detection and recovery work, and the
guardrails that keep it from producing false alarms.

## Why This Exists

During a server deployment, the VPN host can go down while the Network
Extension stays "Connected." Because CloudGateway is a fail-closed full
tunnel, every packet the device sends is routed into a tunnel that no longer
answers. The user still has working Wi-Fi or cellular underneath, but nothing
loads and iOS gives no indication why.

That state is the black hole this feature targets: **the device has Internet,
but the VPN is dead, so all traffic disappears into a stuck tunnel.**
Disconnecting the VPN is the only immediate way for the user to get back
online, and without a notification they have no way to know that.

The tunnel intentionally stays fail-closed throughout. CloudGateway never
auto-disconnects or routes traffic outside the VPN; it only tells the user so
*they* can choose to disconnect.

## User Experience

* A likely-dead tunnel is first repaired silently (see recovery below). A
  transient problem that recovers produces nothing.
* A persistent failure produces one stable-ID local notification per continuous
  episode when notification permission is available, plus one in-app banner:
  "VPN connection interrupted - Your internet connection may be weak, or the VPN server may be down for maintenance for a few minutes. You can wait, or disconnect to use this network without the VPN." Denied authorization is terminal for that tunnel session, but the app can still consume the shared snapshot and show the banner.
* Users are expected to be notified about 30-55 seconds after meaningful traffic
  starts failing. Historical, pre-coordinator device evidence measured 50-55
  seconds for a full blackhole with continuing traffic; the shared-monitor
  cutover still requires real-device verification. Episodes that begin during a network transition can
  take up to ~30 seconds longer while the new path settles.
* The in-app banner's action is "Disconnect & Reload": it stops the tunnel and
  waits up to 30 seconds for iOS to report the tunnel fully disconnected, then
  reloads app state over the now-direct Internet connection, so the user lands
  on an up-to-date dashboard instead of sending the reload through a route that
  is still tearing down. The 30-second deadline covers the stop request and
  status reads, so a stalled system API cannot hold the app indefinitely. Normal
  VPN toggles remain optimistic and do not wait.
* The warning withdraws automatically once traffic verifiably resumes or the
  tunnel is stopped. There is no separate "recovered" notification.
* The copy is causal-neutral on purpose: transport evidence cannot prove
  "server down" versus "weak network," so the message offers both as hedged
  possibilities and never claims the server is offline.

A deployment that changes the server's public IP is still warned about, but
recovery may require the user to toggle the VPN off and on after the new
server is up; the lightweight refresh does not re-resolve the endpoint
hostname.

## How Detection Works

Everything runs inside the packet tunnel extension so it keeps working when
the app is backgrounded, closed, or signed out. The extension's platform
adapters feed a shared `GatewayTunnelHealthMonitor` in `CloudGatewayKit`. The
monitor owns one cancellable wake, reads WireGuard runtime stats every 5
seconds, and sends plain events through the pure
`GatewayTunnelHealthCoordinator`. The coordinator composes these unit-tested
policies:

This composition runs in the iOS packet-extension process today. The shared
types build for macOS, but no macOS app or packet-extension target exists yet.

1. `GatewayTunnelHealthEvaluator` turns raw counters into evidence. Failure
   evidence is one of:
   * **Never handshaked**: no handshake 10 seconds after tunnel start.
   * **Stale handshake**: newest handshake older than 180 seconds.
   * **One-way traffic**: RX flat while TX grows by at least 4096 bytes over
     a bounded 10-second window that starts only when new outbound traffic
     appears. Once concluded, one-way failure stays latched until RX actually
     advances, so a continuous blackhole cannot blink healthy between windows.
2. `GatewayTunnelRecoveryPolicy` converts that evidence into the outward
   health verdict (`unknown` / `passingTraffic` / `notPassingTraffic`) and
   drives recovery. Only entry into `notPassingTraffic` posts the
   notification.

Before any warning, the policy attempts recovery:

* Attempt one requests a **lightweight WireGuard binding refresh**
  (`refreshNetworkBinding` on the pinned `wireguard-apple` fork), the same UDP
  re-bind Apple-driven path changes use. This silently repairs stale NAT/UDP
  bindings.
* If fresh failure evidence persists, attempt two performs an **in-place
  backend restart** (`restartBackend`): it stops wireguard-go, reapplies the
  tunnel network settings, and starts a fresh backend while the VPN remains
  fail-closed. This is intended to repair dead cellular route/flow state that
  a socket re-bind alone cannot. If the deep restart fails after stopping the
  old backend, the fork makes one fallback start against the still-active
  prior network settings before giving up in temporary shutdown. Runtime
  absence can also request this restart from temporary shutdown using its
  saved settings, rather than counting a rejected operation as recovery.
  Runtime traffic still verifies any start; real-device validation remains
  required.
* After each attempt it waits at least 10 seconds and requires **fresh
  post-attempt failure evidence** (new outbound traffic with no handshake or
  RX progress) before escalating. Static counters or an idle tunnel can never
  prove failure; an idle tunnel stays `unknown` indefinitely.
* Missing runtime state follows the same recovery ladder. After 20 seconds on
  a stable, satisfied path it requests a binding refresh, after another 20
  seconds it requests the backend restart, and only 20 seconds of continued
  unavailability after that confirms a failure. A missing runtime sample can
  never bypass recovery and notify immediately.
* A runtime read that does not return is handled separately from a `nil` runtime
  result. After a 20-second read deadline on a satisfied path, the extension
  confirms the outage directly and keeps its health heartbeat fresh without
  queuing more reads or recovery work behind the stalled WireGuard adapter
  queue. If the original read eventually returns, the normal two-poll healthy
  probation is required before the warning withdraws.

Runtime reads and recovery operations remain callback-driven and are never
awaited by the monitor. Each operation has a bounded logical deadline and a
session-qualified token. A missing callback therefore cannot stop path,
heartbeat, notification, or recovery deadlines, and a late or duplicate
callback cannot mutate a replacement tunnel session. The monitor also rejects
out-of-order path route generations before they reach the coordinator.

Snapshot writes and notification operations run through a serialized artifact
reconciler. It tracks desired state separately from completed state, retries
failed snapshot writes, and checks both pending and delivered notifications
before retrying an ambiguous add. Notification denial is terminal for the
session; transient failures and missing callbacks use bounded retry and
reconciliation deadlines. Late work from a stopped session repairs toward the
newest session's desired snapshot and stable notification instead of clearing
newer state.

All elapsed deadlines use injected monotonic time. Wall-clock `Date` is limited
to WireGuard handshake epochs and snapshot `updatedAt`; app-side freshness also
bounds future-dated snapshots so a clock correction cannot keep them fresh
indefinitely.

## How False Positives Are Prevented

The original detector notified on the first raw failure sample, which flagged
weak Wi-Fi and network switches as outages. The current design adds these
gates, in order of importance:

* **Bounded one-way windows.** The failed-traffic window starts with new TX
  activity, never with accumulated idle time, so a single burst after a long
  idle period cannot instantly look like a blackhole. Sub-threshold keepalive
  noise is discarded per window and cannot accumulate.
* **Recovery before accusation.** A binding refresh followed, only when
  necessary, by one backend restart gives Apple, WireGuard, and the active
  network path a chance to self-heal. A recovered tunnel produces no warning.
* **Path awareness.** A second `NWPathMonitor` (policy-only, separate from
  WireGuardKit's) gates confirmation. Only a continuously satisfied path can
  advance an outage; airplane mode and no service stay silent. A captive or
  upstream-less network can still report a satisfied path, so recovery and
  causal-neutral copy remain necessary. Every meaningful path change (status,
  interface types, gateways, IP/DNS capability) starts a 10-second settling
  window; link-quality and expensive/constrained chatter are excluded from the
  fingerprint so poor Wi-Fi cannot restart settling forever. Settling
  suppression is capped at 30 seconds so a real outage during churn is still
  bounded.
* **Fresh evidence for every escalation.** Each recovery attempt resets its
  evidence window; escalation requires new outbound traffic that gets no
  answer. The backend restart also starts a new handshake warmup and counter
  baseline. A tunnel that goes idle mid-recovery parks at `unknown` instead
  of confirming.
* **Hysteresis on both edges.** Confirmation requires the full
  evidence-refresh-verify sequence; withdrawal requires two consecutive
  healthy polls. A confirmed episode survives transient path loss or missing
  stats without withdrawing and reposting, so one outage is one notification.
* **A network change re-arms a confirmed outage.** Confirmation is not
  terminal: a materially new path (Wi-Fi to cellular, an airplane-mode cycle,
  a new Wi-Fi) re-arms the full recovery ladder from scratch - binding refresh
  first, backend restart second - because the failure may have been specific
  to the old path (stale NAT/UDP binding, black-holed socket). Throughout the
  retry an outage latch keeps outward health pinned at `notPassingTraffic`, so
  the edge-triggered notification is neither withdrawn nor reposted while the
  re-armed ladder runs; the latch clears only when two consecutive healthy
  polls prove `passingTraffic`, and a failed re-armed ladder silently
  re-confirms. On the same unchanged network there is no periodic re-probe: an
  idle dead tunnel stays parked by design.

The deliberate cost of these gates is latency: roughly 30-55 seconds to
notify instead of seconds. That trade is intentional - a warning that fires
during ordinary network transitions trains users to ignore it, and a user who
disconnects because of a false alarm exposes traffic outside the VPN for no
reason. Detection constants may be tightened only with device evidence
recorded in the TODO plan.

## Boundaries And Privacy

* The app and UI consume only the outward health snapshot (tunnel identifier,
  health enum, update time) from the app group store. Raw counters enter shared
  in-process code but never leave the packet-extension process. Recovery state
  and counters are never persisted or logged. Fingerprint details stay in the
  iOS path adapter; only path satisfaction and an opaque route generation reach
  the shared monitor.
* While the app is running, a fresh dead-tunnel snapshot triggers one silent
  local VPN-status reconciliation for that snapshot update. This lets the
  banner reflect VPN changes made in Settings or Control Center without a
  loading overlay, network request, persistent background subscription, or any
  dependency on the app process for detection and notification.
* There is no external reachability probe: probing from the tunnel would
  expose the user's real IP and timing to the probe endpoint. Attribution
  stays imperfect by choice.
* Notification and banner share one copy source
  (`GatewayTunnelHealthNotification`); posting is edge-triggered on the
  transition into `notPassingTraffic`. Registration and ambiguous-add
  reconciliation use one stable identifier across pending and delivered
  notifications.
* Tunnel shutdown synchronously closes the current session's effect gate. The
  normal path waits for artifact reconciliation and WireGuard shutdown; a
  five-second outer fallback performs idempotent best-effort clear/withdraw and
  completes without claiming durable cleanup succeeded.

## Related Documents

* Shared orchestration: `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayKit/GatewayTunnelHealthCoordinator.swift`, `GatewayTunnelHealthMonitor.swift`, and `GatewayTunnelHealthArtifactDriver.swift`.
* Health evidence and policies: `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayKit/GatewayTunnelHealth.swift`, `GatewayTunnelRecoveryPolicy.swift`, `GatewayTunnelPathPolicy.swift`, and `GatewayTunnelHealthPersistencePolicy.swift`.
* Extension orchestration: `Frontend/Apple/iOS/CloudGatewayTunnel/PacketTunnelProvider.swift`.
* Fork recovery APIs: `wireguard-apple` `WireGuardAdapter.refreshNetworkBinding` / `restartBackend`.
* Tests: `Frontend/Apple/CloudGatewayKit/Tests/CloudGatewayKitTests/GatewayTunnelHealthCoordinatorTests.swift` and `GatewayTunnelHealthMonitorTests.swift`.

The staged extraction and remaining device-validation matrix are recorded in
`TODO/apple-tunnel-health-coordinator-plan.md`.
