# Apple Tunnel Recovery Before Outage Notification Plan

Research and implementation plan only. No production behavior is changed by
this document.

## Goal

Keep the existing fail-closed warning for a genuinely unreachable VPN while
preventing ordinary weak-network transitions from immediately being presented
as a server outage.

The intended user experience is:

1. Apple and WireGuard keep handling normal path changes automatically.
2. If CloudGateway observes a likely blackhole that Apple did not repair, it
   requests a lightweight WireGuard UDP binding refresh.
3. CloudGateway verifies whether inbound WireGuard progress resumes.
4. A recovered transient path produces no notification.
5. A persistent failure on an otherwise usable path produces one notification
   and one in-app warning with a user-controlled Disconnect action.

The tunnel must remain fail-closed throughout. CloudGateway must never silently
disconnect and expose traffic outside the VPN.

## Repositories

This change spans two repositories:

* CloudGateway: health evidence, recovery policy, notification gating, UI state,
  dependency pinning, and tests.
* `wireguard-apple`: one small public adapter operation that requests the same
  UDP binding refresh currently used for an Apple-reported path change.

Companion fork plan:

```text
/Users/alexbrodsky/GitHub/wireguard-apple/TODO/cloudgateway-network-binding-refresh-plan.md
```

CloudGateway currently consumes the fork in three places that must move to the
same eventual fork commit:

* `Frontend/Apple/wireguard-apple` submodule pointer.
* `Frontend/Apple/iOS/CloudGateway.xcodeproj/project.pbxproj` Swift Package
  revision.
* `Frontend/Apple/iOS/CloudGateway.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Product requirement

The original detector was added for a full-tunnel failure during server
deployment. During that outage, the Network Extension can remain connected
while every device packet is blackholed. Users need to know that disconnecting
is the only immediate way to restore direct Internet access.

That behavior must remain. The change is not permission to hide or indefinitely
delay a persistent outage. It adds a recovery-and-verification gate before the
existing warning.

At the same time, a Wi-Fi/cellular transition or stale NAT/UDP binding should not
be described as a server failure if a lightweight refresh restores traffic.

## Current behavior and root cause

### Raw health immediately becomes a user-facing outage

`GatewayTunnelHealthEvaluator` returns `.notPassingTraffic` when any of these is
true:

* A new tunnel has not handshaked after 15 seconds.
* The newest handshake is more than 180 seconds old.
* RX is flat for at least 10 seconds while TX has grown by at least 4096 bytes.

`PacketTunnelProvider` polls every five seconds and immediately persists and
notifies on the first `.notPassingTraffic` result. There is no recovery attempt,
verification interval, or distinction between raw suspicion and confirmed
unavailability.

Relevant files:

* `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayKit/GatewayTunnelHealth.swift`
* `Frontend/Apple/iOS/CloudGatewayTunnel/PacketTunnelProvider.swift`
* `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayKit/GatewayTunnelHealthNotification.swift`

### The one-way window includes old idle time

The current one-way baseline begins at the last RX change. If the tunnel is idle
for a long time, the ten-second duration is already satisfied before a user
opens Safari. A single outbound burst over 4096 bytes can therefore report a
blackhole on the next five-second poll instead of observing ten seconds of
failed traffic.

This is likely a major contributor to the reported weak-network notifications.
The one-way window must begin with new TX activity, not with unrelated idle time.

### Apple/WireGuard recovery already exists, but only when Apple reports a path update

The fork's `WireGuardAdapter` owns an `NWPathMonitor`. On a satisfiable iOS path
update it:

1. Reapplies endpoint-only UAPI configuration.
2. Reapplies the broken-mobile-roaming workaround.
3. Calls `wgBumpSockets`.

When the path becomes unsatisfied it stops the backend temporarily and resumes
it after the path becomes satisfiable again.

This normally handles Wi-Fi/cellular changes. It does not cover a network that
remains reported as satisfied while its UDP/NAT path is stale or broken.
Apple documents `NWPathMonitor` as a path-change observer and a satisfied path
as available for connection attempts; it is not proof that Internet or UDP
traffic is succeeding.

Primary references:

* <https://developer.apple.com/documentation/network/nwpathmonitor>
* <https://developer.apple.com/documentation/network/nwpath>
* <https://git.zx2c4.com/wireguard-apple/tree/Sources/WireGuardKit/WireGuardAdapter.swift>

### A binding refresh is intentionally lighter than a Settings toggle

`wgBumpSockets` asks wireguard-go to close and reopen its UDP binding, retrying
up to ten times with 500 ms delays. After a successful bind update it sends
keepalives for peers that still have a current keypair.

It does not recreate the utun interface, Network Extension settings, backend
handle, keys, or saved configuration. Its Swift call is fire-and-forget, so a
completion handler can mean only "refresh accepted," not "traffic recovered."
Runtime handshake/RX progress must verify recovery.

Primary reference:

* <https://git.zx2c4.com/wireguard-go/tree/device/device.go>

### Existing path refresh does not learn a deployment's new IPv4

`PacketTunnelSettingsGenerator.endpointUapiConfiguration()` operates on the
initially resolved endpoint IP. Its later `withReresolvedIP()` call primarily
performs DNS64/NAT64 mapping of that stored IP; it does not resolve the original
`wg.<region>...` hostname again.

Therefore the lightweight recovery in this plan intentionally does not promise
to follow a changed deployment A record. A server replacement with a new IP
remains a persistent failure, still produces the warning, and may still require
a user toggle. Automatic deployment-IP recovery is a separate follow-up because
resolving and safely applying a new endpoint while a full tunnel is blackholed
has materially different lifecycle and DNS concerns.

## What can and cannot be distinguished

Without an independent out-of-tunnel probe, WireGuard stats plus `NWPath` cannot
perfectly distinguish:

* A stopped/rebuilding VPN server.
* Wi-Fi that appears connected but has no upstream Internet.
* A network that works for HTTPS but blocks or loses UDP.
* A stale local UDP/NAT binding.

The recovery gate eliminates the last case when a binding refresh works and
gives normal Apple path handling time to settle. Residual false attribution is
still possible on a persistently broken network.

Do not add an external reachability probe in this stage. A probe from the packet
tunnel provider can expose the user's real public IP and connection timing to
the probe endpoint and creates a new privacy, availability, and policy
dependency. Exact attribution does not justify that change without a separate
explicit product/privacy decision.

Notification copy must therefore be causal-neutral. It should say that
CloudGateway could not restore the VPN connection, not claim that the server is
definitively offline.

## Locked decisions for the first implementation

* Keep the five-second health poll.
* Reduce the no-handshake grace to 10 seconds initially. The recovery gate and
  post-refresh evidence provide the protection that the older 15-second grace
  was carrying by itself.
* Keep the 180-second stale-handshake threshold initially.
* Add an extension-owned `NWPathMonitor` for policy evidence. Only a continuously
  `.satisfied` path may advance outage confirmation. This is evidence that a
  connection attempt is possible, not proof of working Internet.
* Give every meaningful path change a 10-second settling window before starting
  or continuing recovery confirmation.
* Define path identity with a coarse in-memory fingerprint: normalized status,
  active interface types, gateways, and IPv4/IPv6/DNS capability. Exclude link
  quality, expensive/constrained flags, and other quality-only changes.
* Cap settling suppression at 30 seconds while status remains continuously
  `.satisfied`, even if the coarse route fingerprint continues changing. A true
  non-satisfied status resets that cap and remains silent.
* Keep the ten-second / 4096-byte one-way criteria, but make the observation
  window start with new TX activity and prevent old idle/keepalive accumulation.
* Try a maximum of two lightweight binding refreshes before confirming an
  outage.
* Require 10 seconds of verification after each refresh before escalation. This
  exceeds wireguard-go's roughly five-second bind retry period and permits two
  WireGuard polls. Without fresh success
  or failure evidence, remain `.unknown` beyond that minimum.
* Publish `.unknown` while suspicion and recovery are in progress. Only
  persistent failure becomes `.notPassingTraffic`.
* Require two consecutive healthy polls before ending a confirmed outage and
  withdrawing its warning.
* On a stable `.satisfied` path, treat 20 seconds of continuously unavailable
  WireGuard runtime state as a persistent VPN failure. On an unsatisfied or
  requires-connection path, remain silent indefinitely.
* Do not auto-disconnect.
* Do not restart the WireGuard backend automatically in this stage.
* Do not add original-hostname refresh or automatic deployment-IP migration in
  this stage.
* Do not add backend, Firebase, Cloudflare, OCI, APNs, or server-side changes.
* Do not persist or log raw counters, endpoints, interface names, path history,
  client identifiers, DNS queries, or traffic metadata.

## Proposed outward health contract

Keep `GatewayTunnelHealth` and the app-group snapshot schema stable:

* `.passingTraffic`: recovery is not active and healthy evidence is stable.
* `.unknown`: warmup, missing runtime state, path/backend transition, raw
  suspicion, binding refresh, or recovery verification.
* `.notPassingTraffic`: two binding refresh attempts received fresh
  post-refresh failure evidence while the path stayed satisfied, or runtime
  state remained unavailable for 30 seconds on that stable path.

Once an outage is confirmed, preserve `.notPassingTraffic` through transient
missing runtime samples or later path unavailability. Withdraw it only after
two healthy samples or tunnel stop. This prevents path flaps from removing and
reposting the same episode.

The app and notification layer should continue consuming only this outward
contract. Raw evidence and recovery state stay inside the extension/shared
policy code.

## Proposed internal state machine

| State | Entry | Behavior and exit |
| --- | --- | --- |
| `warmingUp` | Monitoring starts or runtime counters reset | Publish `.unknown`. Preserve the initial handshake grace. One healthy sample enters `healthy`; persistent raw failure on a settled satisfied path enters `suspected`. |
| `pathUnavailable` | Path is unsatisfied, requires connection, or not yet known before any confirmed outage | Publish `.unknown`, suspend recovery, and reset pre-confirmation evidence. Do not notify. |
| `pathSettling` | A path becomes satisfied or its coarse route fingerprint changes | Publish `.unknown` for 10 seconds, reset old-path evidence, and let Apple/WireGuard perform normal automatic recovery. A further meaningful change restarts the 10-second quiet window, but total suppression is capped at 30 seconds while status remains continuously satisfied. Quality-only changes do not restart it. |
| `healthy` | A healthy sample arrives outside recovery | Publish `.passingTraffic`. A raw failure on the same settled satisfied path enters `suspected`. |
| `runtimeUnavailable` | Runtime configuration is missing or refresh reports `.invalidState` before confirmation | Publish `.unknown`. If the path ceases to be satisfied, enter `pathUnavailable`. If runtime returns, restart warmup. If it remains missing for 20 seconds on the same settled satisfied path, enter `confirmedUnavailable`. |
| `suspected` | Bounded one-way failure, never-handshaked timeout, or stale handshake on a settled path | Publish `.unknown`, capture handshake/RX/TX baselines, and request binding refresh attempt one. |
| `verifyingAttemptOne` | First refresh accepted | Wait at least 10 seconds. A newer handshake or advancing RX enters pre-confirmation `recoveryProbation`. Attempt two requires fresh post-refresh TX activity without a newer handshake/RX: a bounded 4096-byte window for one-way evidence, or any new TX activity while the peer remains never-handshaked/stale. Static counters/handshake age alone do not. |
| `verifyingAttemptTwo` | Second refresh accepted after fresh failure evidence | Wait at least another 10 seconds. Inbound progress enters pre-confirmation `recoveryProbation`. Confirmation requires another fresh post-attempt TX-without-handshake/RX observation under the same reason-specific rule. Static counters/handshake age alone do not. |
| `confirmedUnavailable` | Two verified recovery attempts fail, or runtime stays missing for 20 seconds on a settled path | Publish `.notPassingTraffic`, post one notification for the episode, preserve fail-closed routing, and continue passive monitoring. Later path loss or missing stats suspends verification but preserves this outward state and does not repost. |
| `recoveryProbation` | Inbound progress appears during recovery or a confirmed episode | Before confirmation, publish `.unknown`; after confirmation, preserve `.notPassingTraffic`. Two consecutive healthy polls enter `healthy`, clear the episode, and withdraw any warning. Failure before two polls returns to `suspected` if unconfirmed or `confirmedUnavailable` if already confirmed. |

Expected time-to-notify with the initial constants:

* One-way blackhole with continuing failed traffic: a real ten-second failed-TX
  window plus about 20 seconds of recovery verification, normally about 30
  seconds total after meaningful traffic begins failing. If traffic stops, the
  policy remains `.unknown` until new post-refresh TX activity supplies failure
  evidence. A handshake becoming stale changes the failure reason but never
  waives the post-refresh activity requirement.
* New tunnel that never handshakes while outbound activity continues: about 10
  seconds of initial grace plus about 20 seconds of recovery verification,
  normally about 30 seconds total.
* Stale established handshake with continuing outbound activity: about 40
  seconds after the 180-second stale threshold is crossed.

Add up to 30 seconds when the episode begins during continuously satisfied path
settling/churn. These timings intentionally suppress normal transitions while
still bounding suppression during a multi-minute deployment outage. They are
estimates, not hard deadlines, because escalation requires continuing
post-refresh activity without handshake/RX progress.

## CloudGateway design

### 1. Make raw evidence explicit and bounded

Update `GatewayTunnelHealthEvaluator` or introduce a neighboring pure evidence
type in `CloudGatewayKit`.

Required behavior:

* Track the previous sample independently from the one-way candidate.
* Start a one-way candidate only when TX first advances while RX is unchanged.
* Capture the previous sample's TX value when the first advancing sample opens
  the candidate. Capturing the already-advanced current value would discard the
  first outbound burst.
* Require the full configured duration after candidate start before evaluating
  the configured TX growth.
* If growth is below threshold at the end of the bounded window, discard/reset
  that candidate so tiny keepalives cannot accumulate indefinitely.
* Clear the candidate when RX advances.
* Treat RX/TX counter rollback as a backend/session reset, not receive activity;
  reset warmup and evidence baselines.
* Handle clock rollback defensively by resetting time-based evidence.
* Preserve distinct evidence reasons for no handshake, stale handshake, and
  one-way traffic so tests and policy do not infer cause from a single enum.
* After each binding refresh, clear pre-refresh TX evidence. Require a new
  bounded TX-without-RX window for one-way evidence. Never-handshaked and stale
  handshake reasons require new post-refresh TX activity without a newer
  handshake/RX before escalation; unchanged handshake age alone is not enough.

The pure evaluator must not post notifications or call WireGuardKit.

### 2. Add a pure recovery policy

Add a shared-first type such as:

```text
Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayKit/GatewayTunnelRecoveryPolicy.swift
```

The policy should be deterministic and free of Network Extension and
UserNotifications dependencies.

Suggested inputs:

* Current time.
* Optional runtime stats sample.
* Raw health evidence.
* Coarse path status/fingerprint, a monotonically increasing route generation,
  and continuous-satisfied settling age.
* Result that a binding refresh was accepted or unavailable.
* Session generation.

Suggested actions:

* Publish outward health.
* Request binding refresh.
* Persist/notify only after confirmation.
* Reset an episode.

Use a session generation token so a late adapter callback after stop/restart
cannot mutate the new monitoring session. Permit at most one health read and one
recovery request in flight.

The policy must not infer refresh failure from a scheduling callback, static
counters, or unchanged handshake age. Every escalation requires fresh
post-refresh TX activity without a newer handshake/RX; one-way evidence also
requires the full bounded byte/window threshold. If the tunnel becomes idle
after a refresh, stay `.unknown` until new traffic makes a decision possible.

### 3. Orchestrate actions in the packet tunnel extension

Update:

```text
Frontend/Apple/iOS/CloudGatewayTunnel/PacketTunnelProvider.swift
```

Responsibilities:

* Continue polling runtime configuration on the existing serial health queue.
* Own a second `NWPathMonitor` for CloudGateway policy only, deliver its updates
  on the health queue, and increment a path generation for every meaningful
  change. The fork keeps its own path monitor for transport behavior.
* Convert `NWPath` into an in-memory fingerprint containing normalized status,
  active interface types, gateways, and IPv4/IPv6/DNS capability. Treat the
  first fingerprint as a new generation. Increment only when that fingerprint
  changes. Do not include link quality, expensive/constrained flags, or other
  quality-only properties, and never persist or log the fingerprint.
* Treat only a continuously `.satisfied` path as eligible for confirmation.
  `.unsatisfied`, `.requiresConnection`, unknown status, or a new generation
  suppresses confirmation and begins/continues path settling.
* Track when continuous satisfied settling began. New satisfied fingerprints
  may restart the 10-second quiet window but may not suppress recovery for more
  than 30 seconds total. A non-satisfied status resets this timer and remains
  ineligible for confirmation.
* A new route generation always invalidates late callbacks and sample baselines.
  Before the 30-second cap it also resets the pre-confirmation attempt sequence.
  After the cap it must not reset continuous-satisfied episode age or the number
  of already requested attempts; the next fresh failure evidence continues the
  bounded episode against the newest generation.
* Feed samples and missing-runtime events into the pure evaluator/policy.
* Call the fork's `refreshNetworkBinding` only when requested by policy.
* Treat the adapter callback as "accepted," never as proof of recovery.
* Verify recovery from a newer handshake and/or advancing RX.
* Keep persistence and local-notification side effects centralized on outward
  health transitions.
* Clear monitoring state and invalidate generations synchronously on stop.

Before an outage is confirmed, unavailable runtime on a non-satisfied path must
publish `.unknown` and remain silent. Unavailable runtime that persists for 20
seconds on the same settled satisfied path must become a causal-neutral
confirmed VPN failure so a backend that never resumed cannot blackhole forever
without warning. After an outage is already confirmed, transient missing stats
or path loss preserves the episode/warning until two healthy samples or stop.

### 4. Preserve the app-group privacy boundary

Keep `GatewayTunnelHealthSnapshot` backward compatible. Persist only:

* Tunnel identifier.
* Outward health enum.
* Update time.

Do not persist internal recovery state or raw WireGuard values. Existing atomic
protected writes, transition writes, 15-second heartbeats, and 30-second
freshness behavior can remain.

### 5. Gate notification and in-app copy on confirmed state

Only entry into outward `.notPassingTraffic` may post the notification. Repeated
polls and later retry activity must not repost it.

Recommended shared copy:

```text
Title: VPN not responding
Body: CloudGateway couldn't restore the VPN connection. Disconnect to try using this network without the VPN.
```

Use the same body for the in-app banner instead of maintaining a second literal
in `CloudGatewayViewModel`.

Continue withdrawing the warning after confirmed stable recovery or tunnel
stop. Do not add a separate "recovered" notification.

## Fork dependency design

The fork should expose:

```swift
public func refreshNetworkBinding(
    completionHandler: @escaping (WireGuardAdapterError?) -> Void
)
```

Contract:

* `.started`: reuse the existing satisfiable-path endpoint mapping, roaming
  workaround, and `wgBumpSockets` sequence; completion `nil` means scheduled.
* `.temporaryShutdown` or `.stopped`: return `.invalidState`; do not restart the
  backend.
* Completion does not indicate that the Go binding update or tunnel recovery
  succeeded.

CloudGateway owns attempts, timing, verification, and notification policy. The
generic fork must not contain CloudGateway thresholds or user-facing behavior.

## Implementation stages

## Implementation status

- [x] Stage 1: fork API implemented, documented, reviewed, and committed.
- [x] Stage 2: submodule, Xcode package requirement, and `Package.resolved`
  pinned locally to `4ff7fcd282cb64830f7febd5b9d1131653f2cc78`.
- [x] Stage 3: bounded health evidence and deterministic tests implemented.
- [x] Stage 4: pure recovery policy and packet-tunnel orchestration implemented.
- [x] Stage 5: notification and in-app copy share the confirmed-state message.
- [ ] Stage 6: 97 CloudGatewayKit tests pass. The complete Xcode build remains
  blocked until the pinned fork revision is published to GitHub; real-device
  transition and controlled outage checks also remain required.

### Stage 1: fork API

Repository: `/Users/alexbrodsky/GitHub/wireguard-apple`

* Extract the existing satisfiable-path binding refresh into one private helper.
* Add `refreshNetworkBinding(completionHandler:)` on the adapter work queue.
* Preserve existing path-monitor behavior by routing it through the helper.
* Document fire-and-forget completion semantics and invalid-state behavior.
* Keep the patch Swift-only; do not change the Go/C bridge.
* User reviews, commits, and publishes the fork revision. Codex must not push.

### Stage 2: dependency pin

Repository: CloudGateway

After the fork revision exists remotely:

* Advance the submodule pointer.
* Update the Xcode Swift Package revision.
* Update `Package.resolved` to the identical revision.
* Confirm no URL or branch drift.
* Compile the published fork through CloudGateway's Apple dependency
  integration.

### Stage 3: bounded health evidence

Repository: CloudGateway

* Fix the long-idle one-way baseline.
* Add explicit failure reasons and reset semantics.
* Add deterministic threshold, idle, keepalive, counter-reset, and clock-reset
  tests.

### Stage 4: recovery policy and extension orchestration

Repository: CloudGateway

* Add the pure state machine.
* Integrate the two binding attempts and verification windows.
* Add in-flight guards and session generations.
* Map internal recovery states to outward health.
* Keep the notification suppressed until confirmation.

### Stage 5: notification/UI consistency

Repository: CloudGateway

* Update causal-neutral copy.
* Share the copy between local notification and in-app banner.
* Preserve logged-in, logged-out, timeout fast-path, stale-snapshot, and correct
  tunnel matching behavior.

### Stage 6: validation and tuning

* Run `./scripts/test.sh apple` from CloudGateway.
* Perform real-device transition and outage tests before tuning thresholds.
* Change the initial constants only with device evidence recorded in this TODO.

## Automated test matrix

### Raw evaluator

* Long idle followed by one TX burst waits a full one-way window.
* RX-flat/TX-growing reaches suspicion only at the exact duration and byte
  thresholds.
* Sub-threshold TX does not accumulate across expired windows.
* Persistent-keepalive-sized changes do not become a false outage.
* RX advancement clears one-way evidence.
* Counter rollback resets the evaluator and warmup.
* Clock rollback resets time-based evidence.
* Never-handshaked and stale-handshake boundaries remain deterministic.

### Recovery policy

* Raw suspicion requests attempt one and publishes `.unknown`.
* Repeated samples cannot overlap attempt one.
* RX or handshake progress during attempt one suppresses notification.
* Static counters after attempt one do not prove failure.
* Fresh post-refresh one-way evidence requests attempt two only after 10 seconds.
* Never-handshaked/stale-handshake evidence requests attempt two only after the
  same minimum window and fresh post-refresh TX activity without a newer
  handshake/RX.
* Recovery during attempt two suppresses notification.
* Static counters after attempt two do not confirm an outage.
* Fresh failure evidence after attempt two publishes `.notPassingTraffic` once.
* Unsatisfied/requires-connection paths remain silent.
* Every meaningful satisfied path change enters a 10-second settling state and
  invalidates pre-confirmation evidence.
* Link-quality/expensive/constrained-only changes do not create a new route
  generation.
* Repeated satisfied route changes cannot extend settling beyond 30 seconds.
* Missing runtime state on a non-satisfied path remains silent.
* Missing runtime state for 20 seconds on one settled satisfied path confirms a
  causal-neutral failure.
* Late callbacks from an old session are ignored.
* Two healthy polls are required to end a confirmed episode.
* Failure during recovery probation does not create notification churn.
* A confirmed episode survives transient path loss/missing stats without being
  reposted.

### Notification, persistence, and app

* Suspected/recovering `.unknown` does not post or show a banner.
* Confirmed unavailability emits one notification-post action.
* Repeated confirmed samples do not repost.
* Stable recovery emits one withdrawal action and hides the banner.
* Stop emits clear/withdraw actions.
* Signed-in and signed-out banners remain supported.
* A stale or mismatched snapshot remains hidden.
* Disconnect still stops the matching active tunnel.
* A request timeout during recovery stays generic; confirmed unavailability uses
  the VPN-specific warning.

Policy-action, transition, persistence, and app-banner behavior should be
automated. `PacketTunnelProvider` currently calls `UNUserNotificationCenter`
directly, so actual OS delivery/removal remains in the real-device matrix unless
implementation adds a small notification-center seam.

## Real-device validation matrix

* Healthy startup on good Wi-Fi: no warning.
* Wi-Fi to cellular, cellular to Wi-Fi, and Wi-Fi network A to B: no warning
  when automatic/binding recovery succeeds.
* Airplane mode or no service before confirmation: no new VPN-unreachable
  warning. If an episode was already confirmed, path loss does not withdraw and
  repost that existing warning.
* A satisfied-path change begins a full settling window before any recovery
  confirmation.
* Link-quality chatter on poor Wi-Fi does not continuously restart settling.
* Repeated real route changes while status stays satisfied stop suppressing
  recovery after the 30-second cap.
* Weak Wi-Fi with stale UDP/NAT state: binding refresh restores RX without a
  warning.
* Captive or UDP-blocking Wi-Fi: one causal-neutral warning may remain because
  server versus network cannot be proven.
* Same-IP server restart on good Wi-Fi/cellular: warn after confirmation and
  withdraw automatically when handshakes resume.
* Server stopped for several minutes: warn once and preserve fail-closed routing.
* OCI replacement with a new endpoint IP: warn once; confirm that this stage
  still requires the expected user toggle after the new server is ready.
* Stop AdGuard/Unbound while WireGuard remains reachable: record whether the
  transport-only signal can misclassify a payload/DNS failure; do not add an
  external probe as an unreviewed workaround.
* Extension kill/relaunch and rapid user stop/start: no stale callback, snapshot,
  banner, or notification.

## Acceptance criteria

* A stale local binding that recovers within the two verification windows never
  produces the outage notification or in-app banner.
* A genuine persistent server outage with continuing failure evidence on a
  stable satisfied path produces exactly one warning in roughly 30 seconds,
  plus any path-settling delay.
* With notification authorization granted, the warning remains available while
  signed out and while the app is closed. With authorization denied, the fresh
  app-group state still drives the in-app warning when the app is opened.
* CloudGateway never auto-disconnects or changes full-tunnel routing.
* No new external reachability service or privacy-sensitive telemetry exists.
* Existing deployment-IP behavior is not falsely advertised as self-healing.
* All pure policy/evaluator tests and `./scripts/test.sh apple` pass.
* Real-device Wi-Fi/cellular and controlled server-outage validation is complete.

## Explicit non-goals and follow-ups

### Not in this stage

* Full WireGuard backend restart.
* Recreating Network Extension settings or utun.
* Original-hostname refresh while the active tunnel is blackholed.
* Automatically following a deployment's changed A record.
* External Internet probes.
* Server-side health push or APNs.
* Automatic disconnect/fail-open behavior.
* Adopting the unmerged upstream `am/default-path` KVO branch.

### Follow up only if device evidence requires it

1. Evaluate upstream commit `3149c50` (`NEProvider.defaultPath` KVO) separately
   from recovery policy. It may improve path-change delivery but does not solve a
   degraded path that remains satisfied.
2. If binding refresh does not recover cases that a manual toggle does, design a
   separately reviewed internal backend restart with explicit rollback and
   failure semantics.
3. If automatic deployment-IP recovery becomes a product requirement, design
   safe original-hostname resolution, last-known-endpoint fallback, DNS TTL
   behavior, and endpoint application as a separate stage.
4. If exact server-versus-network attribution becomes mandatory, make an
   explicit privacy decision before designing an owned out-of-tunnel probe.

## Privacy and logging

Keep this feature log-free in production. Even categorical recovery timestamps
can become per-user connection history. Use deterministic tests and explicit
device-test observation instead of recording recovery episodes.

Never log endpoints, resolved IPs, runtime counters, path generations,
interface names, client or user identifiers, DNS queries, requested
destinations, packet metadata, keys, full configurations, or per-user
connection/recovery history.
