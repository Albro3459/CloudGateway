# Apple Tunnel Health Detection And Outage Notification

The iOS packet tunnel extension detects a dead VPN tunnel and raises one local
notification plus an in-app warning so the user can act. This document
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
* A persistent failure produces exactly one local notification and one in-app
  banner per episode: "VPN not responding — CloudGateway couldn't restore the
  VPN connection. Disconnect to try using this network without the VPN."
* Users are normally notified about 30–55 seconds after meaningful traffic
  starts failing (measured 50–55 seconds on device for a full blackhole with
  continuing traffic). Episodes that begin during a network transition can
  take up to ~30 seconds longer while the new path settles.
* The warning withdraws automatically once traffic verifiably resumes or the
  tunnel is stopped. There is no separate "recovered" notification.
* The copy is causal-neutral on purpose: transport evidence cannot prove
  "server down" versus "network blocks UDP," so the message never claims the
  server is offline.

A deployment that changes the server's public IP is still warned about, but
recovery may require the user to toggle the VPN off and on after the new
server is up; the lightweight refresh does not re-resolve the endpoint
hostname.

## How Detection Works

Everything runs inside the packet tunnel extension so it keeps working when
the app is backgrounded, closed, or signed out. The extension polls WireGuard
runtime stats every 5 seconds and feeds two pure, unit-tested types in
`CloudGatewayKit`:

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
  a socket re-bind alone cannot; real-device validation remains required.
* After each attempt it waits at least 10 seconds and requires **fresh
  post-attempt failure evidence** (new outbound traffic with no handshake or
  RX progress) before escalating. Static counters or an idle tunnel can never
  prove failure; an idle tunnel stays `unknown` indefinitely.
* Missing runtime state for 20 seconds on a stable, satisfied network also
  confirms a failure, so a backend that never resumed cannot blackhole
  forever without warning.

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
  advance an outage; airplane mode, no service, or captive-portal states stay
  silent. Every meaningful path change (status, interface types, gateways,
  IP/DNS capability) starts a 10-second settling window; link-quality and
  expensive/constrained chatter are excluded from the fingerprint so poor
  Wi-Fi cannot restart settling forever. Settling suppression is capped at 30
  seconds so a real outage during churn is still bounded.
* **Fresh evidence for every escalation.** Each recovery attempt resets its
  evidence window; escalation requires new outbound traffic that gets no
  answer. The backend restart also starts a new handshake warmup and counter
  baseline. A tunnel that goes idle mid-recovery parks at `unknown` instead
  of confirming.
* **Hysteresis on both edges.** Confirmation requires the full
  evidence-refresh-verify sequence; withdrawal requires two consecutive
  healthy polls. A confirmed episode survives transient path loss or missing
  stats without withdrawing and reposting, so one outage is one notification.

The deliberate cost of these gates is latency: roughly 30–55 seconds to
notify instead of seconds. That trade is intentional — a warning that fires
during ordinary network transitions trains users to ignore it, and a user who
disconnects because of a false alarm exposes traffic outside the VPN for no
reason. Detection constants may be tightened only with device evidence
recorded in the TODO plan.

## Boundaries And Privacy

* The app and UI consume only the outward health snapshot (tunnel identifier,
  health enum, update time) from the app group store. Raw counters, recovery
  state, and path fingerprints never leave the extension and are never
  persisted or logged.
* There is no external reachability probe: probing from the tunnel would
  expose the user's real IP and timing to the probe endpoint. Attribution
  stays imperfect by choice.
* Notification and banner share one copy source
  (`GatewayTunnelHealthNotification`); posting is edge-triggered on the
  transition into `notPassingTraffic` and replaces any prior notification by
  stable identifier.

## Related Documents

* Design and state machine: `TODO/apple-tunnel-recovery-before-notification-plan.md`
* Backend restart escalation: `TODO/apple-tunnel-backend-restart-recovery-plan.md`
* Fork API: `wireguard-apple` `TODO/cloudgateway-backend-restart-plan.md`
* Tests: `Frontend/Apple/CloudGatewayKit/Tests/CloudGatewayKitTests/GatewayTunnelHealthTests.swift`
* Real-device validation of the backend-restart recovery stage remains required.
