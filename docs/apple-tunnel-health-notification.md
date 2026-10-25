# Tunnel health and outage notifications

The iOS packet extension detects a tunnel that appears connected but no longer
passes traffic, attempts recovery, and warns the user. Detection continues while
the app is closed, backgrounded, or signed out. Shared policies compile for
macOS, but the macOS extension does not enable this monitor or notifications.

The tunnel stays fail-closed. Recovery never disconnects it or routes traffic
outside the VPN; the user decides whether to disconnect. No external reachability
probes, traffic logs, or persisted runtime counters are used.

## User behavior

* Transient failures that recover silently produce no warning.
* A persistent failure creates one stable-ID notification per continuous episode
  when authorized, plus an in-app banner. Denied notification authorization is
  terminal for that session; the banner can still use the shared snapshot.
* The warning says the connection may be weak or the server may be under
  maintenance. Transport evidence cannot establish the cause.
* **Disconnect & Reload** waits up to 30 seconds for confirmed disconnection
  before reloading. The deadline includes the stop request and status reads.
  Ordinary VPN toggles remain optimistic.
* Two consecutive healthy polls withdraw the warning. Stop clears it. There is
  no separate recovery notification.

Expected detection is roughly 30–55 seconds after meaningful traffic fails;
path settling can add up to 30 seconds. Earlier device evidence measured 50–55
seconds before the shared-monitor cutover. Those measurements do not establish
timing for every current device/path. Do not tighten constants without signed
device evidence. A changed server IP may require a user toggle because binding
refresh does not re-resolve the endpoint hostname.

## Detection and recovery

`CloudGatewayTunnelHealthMonitor` owns one cancellable wake, reads WireGuard
stats every five seconds, and feeds the pure `CloudGatewayTunnelHealthCoordinator`.
`CloudGatewayTunnelHealthEvaluator` recognizes:

* No handshake ten seconds after startup.
* A newest handshake older than 180 seconds.
* Flat RX with at least 4096 bytes of new TX in a bounded ten-second window.
  The window starts with outbound activity, discards sub-threshold noise, and
  latches failure until RX advances.

`CloudGatewayTunnelRecoveryPolicy` maps evidence to `unknown`, `passingTraffic`,
or `notPassingTraffic`. Before confirming a normal traffic failure it requests:

1. `refreshNetworkBinding`, a lightweight UDP/NAT binding refresh.
2. If fresh failure persists, `restartBackend`, an in-place wireguard-go restart
   that reapplies network settings while preserving fail-closed routing.
3. Confirmation only after the post-attempt verification period.

Each attempt needs at least ten seconds and fresh post-attempt failure evidence.
Restart resets handshake warmup and counters. Idle/static counters cannot prove
failure; an idle recovery stays `unknown`. A failed restart after stopping the
old backend attempts one fallback using prior settings. Runtime absence can also
request restart from temporary shutdown using retained settings. Traffic must
verify success; a successful callback alone is insufficient.

Missing runtime follows a separate ladder on a stable satisfied path: 20 seconds
to binding refresh, another 20 to backend restart, then 20 more before confirmation.
A runtime read whose callback never returns instead confirms after its 20-second
deadline on a satisfied path. The monitor keeps its heartbeat fresh and avoids
queuing work behind the stalled adapter. A later callback requires the usual
two healthy polls before withdrawal.

## Path and episode rules

Only a continuously satisfied network path advances an outage. Airplane mode
and no service stay silent; a satisfied captive/upstream-less network is still
possible. A meaningful path change starts ten seconds of settling, capped at
30 seconds across churn. Fingerprints include status, interface types, gateways,
and IP/DNS capability, excluding quality and expensive/constrained chatter.
Only satisfaction and an opaque route generation leave the platform adapter.

A confirmed episode stays latched through transient path loss and missing stats.
A materially new path re-arms binding refresh and backend restart while keeping
outward health at `notPassingTraffic`, so the notification is neither withdrawn
nor reposted. Two healthy polls clear the latch. On an unchanged path there is
no periodic re-probe; an idle dead tunnel stays parked.

## Callback and artifact ordering

Runtime/recovery operations are callback-driven, with logical deadlines and
session-qualified tokens. The monitor never awaits WireGuard callbacks. Late,
duplicate, or prior-session completions cannot mutate the current session;
out-of-order route generations are rejected.

A serialized artifact reconciler tracks desired versus completed snapshot and
notification state. It retries failed writes/clears, including startup clear,
and checks pending/delivered notifications before retrying an ambiguous add.
The app-group store uses one FIFO lane so clear cannot overtake an earlier write.

A generation-aware effect arbiter makes admission and queue insertion atomic.
Normal stop rejects new effects but submits admitted effects before adapter
stop. At the five-second stop deadline, still-queued effects are cancelled and
stop is submitted after the bounded submission point. Best-effort cleanup then
completes without waiting for physical callbacks or claiming durable success.
Already-started effects can finish later and repair toward current desired state.

Notification registration has an epoch fence checked after authorization and
immediately before `UNUserNotificationCenter.add`. Withdrawal, stop, and session
replacement invalidate it, preventing stale callbacks from affecting the newer
stable notification. Denial is terminal; transient failures/missing callbacks
use bounded retry deadlines.

Elapsed deadlines use injected monotonic time. Wall time is limited to handshake
epochs and snapshot `updatedAt`; app freshness bounds future-dated snapshots.

## App boundary and privacy

Only tunnel ID, health enum, and update time reach the shared snapshot. Raw
counters, recovery state, and path fingerprint details stay in the extension and
are never persisted or logged. Notification/banner copy shares
`CloudGatewayTunnelHealthNotification`.

While running, the app silently reconciles local VPN status once per fresh
dead-tunnel snapshot update, including Settings/Control Center changes. This
needs no network request, loading overlay, or persistent background subscription.
The app is not required for detection or notification.

## Device validation

Deterministic tests cover policies, ordering, restart races, and app consumption.
Signed real-device checks remain necessary for platform behavior and timing:

* Healthy traffic, full blackhole, never-handshake, runtime loss, and stalled reads.
* Recovery before/after notification, idle traffic, and two-poll withdrawal.
* Airplane mode, Wi-Fi/cellular switches, churn, and clock correction.
* App background/termination, signed-out installs, and every permission state.
* Stop with outstanding callbacks, extension restart, and late old-session work.

Check silent settling, one stable notification per outage, snapshot cleanup,
bounded shutdown, current-session repair, fail-closed routing, and absence of
private logs. Shared code availability does not establish macOS adapter parity.

Implementation lives in Kit's `CloudGatewayTunnelHealthMonitor`, coordinator,
evaluator/recovery/path/persistence policies, artifact driver, effect arbiter,
and notification fence. The iOS `PacketTunnelProvider` owns platform composition.
See the [shared package](../Frontend/Apple/CloudGatewayKit/README.md) and
[iOS architecture](apple-ios-app.md) for those boundaries.
