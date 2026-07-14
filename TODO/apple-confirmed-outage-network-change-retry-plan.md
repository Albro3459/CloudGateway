# Apple Confirmed Outage Network-Change Retry Plan

Research and implementation plan only. No production behavior is changed by
this document.

## Goal

Once a dead tunnel has been confirmed and the "VPN connection interrupted"
notification is up, a genuinely new network path should re-arm the recovery
ladder (binding refresh, then backend restart) instead of leaving the tunnel
waiting for evidence to organically turn healthy.

The intended user experience:

1. The outage warning stays up, stable, with no duplicate notifications while
   CloudGateway retries in the background.
2. Moving to a different network (Wi-Fi to cellular, airplane-mode cycle, new
   Wi-Fi) triggers a fresh recovery attempt after the existing settle backoff,
   because the failure may have been specific to the old path (stale NAT/UDP
   binding, black-holed socket).
3. If the retry restores inbound traffic, the warning withdraws exactly as it
   does today (two healthy polls). If it fails, the outage silently
   re-confirms with no additional notification.

The tunnel remains fail-closed throughout. Nothing in this plan disconnects
the tunnel or changes what traffic is routed.

## Scope and repositories

CloudGateway only. No `wireguard-apple` fork changes: both adapter operations
the re-armed ladder uses already exist and are already pinned
(`refreshNetworkBinding`, `restartBackend`, fork commit `d03db4a`).

Touched code:

* `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayKit/GatewayTunnelRecoveryPolicy.swift`
* `Frontend/Apple/CloudGatewayKit/Tests/CloudGatewayKitTests/GatewayTunnelHealthTests.swift`
* `docs/apple-tunnel-health-notification.md` (state machine description)

Explicitly untouched (verified against current sources, see "No changes
needed" below): `GatewayTunnelPathPolicy`, `GatewayTunnelHealthEvaluator`,
`GatewayTunnelHealthNotification`, `GatewayTunnelHealthPersistencePolicy`,
`PacketTunnelProvider`, and the fork.

## Product requirement

The confirmed-outage warning exists for a persistent failure on an otherwise
usable path. Today, once confirmed, the only path back to healthy is the
evaluator organically reporting `.healthy` for two polls - the tunnel has to
repair itself without any fresh recovery action. If the root cause was a
socket or NAT binding tied to the old network, a user who walks out of Wi-Fi
range onto cellular keeps seeing "VPN connection interrupted" indefinitely on
a network where a binding refresh would have fixed it.

Requirements agreed with the owner:

* A network change during or after confirmation restarts recovery detection
  with the existing ~30-second settle backoff used when connecting, so
  networking stabilizes before any action.
* No notification flapping: the warning must not withdraw-then-repost or post
  twice during a retry. Health must never blip through `.unknown` or
  `.passingTraffic` while the outage is still unresolved.
* Recovery still requires the same proof as today: inbound progress, then two
  consecutive healthy polls.

## Current behavior and root cause

`GatewayTunnelRecoveryPolicy.update` resets the ladder on a route-generation
change only while not confirmed
(`GatewayTunnelRecoveryPolicy.swift:78-84`):

```swift
let generationChanged = self.routeGeneration != routeGeneration
self.routeGeneration = routeGeneration

if generationChanged, !isConfirmed {
    state = .observing
    runtimeUnavailableSince = nil
}
```

Once `state == .confirmed` (or `.probation(confirmed: true, ...)`), a
generation change is ignored. `.confirmed` only exits through healthy
evidence (`:182-192`), so no `bindingRefresh`/`backendRestart` is ever
requested again for that episode.

Supporting facts that shape the design:

* The generation the policy sees is `GatewayTunnelPathPolicy.policyGeneration`
  (`PacketTunnelProvider.swift:176`), the settle-aware counter: it bumps on
  every unsatisfied change and on satisfied changes inside the 30-second
  settle window, but suppresses steady churn on an established network
  (`GatewayTunnelPathPolicy.swift:15-39`). A real interface swap or an
  airplane-mode cycle always bumps it.
* After any path change, `availability(at:)` reports `.settling` for up to 30
  seconds (or until 10 quiet seconds pass), and `update` holds all ladder
  action while `path != .satisfied` (`GatewayTunnelRecoveryPolicy.swift:86-92`).
  This is the settle backoff the requirement asks for - it already exists and
  gates the re-armed ladder for free.
* `GatewayTunnelHealthNotification.shouldWithdraw` requires a direct
  `.notPassingTraffic -> .passingTraffic` transition
  (`GatewayTunnelHealthNotification.swift:21-23`). If any state in the retry
  path reported `.unknown`, a later recovery would never withdraw the
  notification. Keeping the outward health pinned at `.notPassingTraffic`
  during the retry is therefore required for correctness, not just to avoid
  flapping. `shouldNotify` fires only on the transition into
  `.notPassingTraffic` (`:16-18`), so a health value that never leaves
  `.notPassingTraffic` can never double-notify.

## Locked decisions

1. Re-arm on `policyGeneration` change, nothing else. No timers, no periodic
   re-probe of a confirmed outage on an unchanged network (that trade-off was
   reviewed separately and accepted: an idle dead tunnel on the same network
   stays parked by design).
2. The attempt budget resets fully on re-arm: binding refresh first, backend
   restart second, exactly like a fresh episode. A failed re-armed ladder
   re-confirms silently.
3. Outward health reports `.notPassingTraffic` continuously from first
   confirmation until a genuine `.passingTraffic` recovery. No intermediate
   `.unknown`.
4. Recovery through the re-armed ladder uses the existing probation rules
   (`healthyPollsToRecover = 2`); healthy evidence alone, without probation,
   must not withdraw the warning while the outage latch is set.
5. All changes stay inside the pure policy type. The extension, path policy,
   evaluator, notification gate, and persistence policy are consumed as-is.

## Design

All edits are in `GatewayTunnelRecoveryPolicy.swift`.

### 1. Outage latch with a health floor

Add one instance variable alongside `routeGeneration` and
`runtimeUnavailableSince`:

```swift
private var confirmedOutageLatched = false
```

Semantics:

* Set to `true` at every `state = .confirmed` assignment. There are three:
  verifying-exhaustion (`:179`), failed confirmed-probation (`:203`), and the
  runtime-unavailable default arm (`:290`).
* Cleared only when the policy reports `.passingTraffic`.
* While latched, any action that would report `.unknown` reports
  `.notPassingTraffic` instead (the "floor").

Route every `return GatewayTunnelRecoveryAction(...)` in `update` and
`handleRuntimeUnavailable` through one private mutating helper so the floor
and the clear cannot be missed at an individual return site:

```swift
private mutating func emit(
    _ health: GatewayTunnelHealth,
    recoveryRequest: GatewayTunnelRecoveryRequest? = nil
) -> GatewayTunnelRecoveryAction {
    if health == .passingTraffic {
        confirmedOutageLatched = false
        return GatewayTunnelRecoveryAction(health: health, recoveryRequest: recoveryRequest)
    }
    let floored = confirmedOutageLatched && health == .unknown ? .notPassingTraffic : health
    return GatewayTunnelRecoveryAction(health: floored, recoveryRequest: recoveryRequest)
}
```

With the floor in place, the explicit `isConfirmed ? .notPassingTraffic :
.unknown` ternary in the path guard (`:91`) can stay or become
`emit(.unknown)`; keep whichever reads better after the mechanical rewrite,
they are equivalent because `.confirmed` implies the latch is set.

### 2. Unconditional ladder reset on generation change

Drop the `!isConfirmed` condition at `:81`:

```swift
if generationChanged {
    state = .observing
    runtimeUnavailableSince = nil
}
```

The latch keeps outward health at `.notPassingTraffic`, so this is now safe
for the confirmed states too. From `.observing` the existing machinery does
the rest with zero further changes:

* `.failed` evidence -> `recoveryPending(attempt: 1)` + `.bindingRefresh`
  (`:124-129`), then the normal verify/escalate/confirm ladder.
* Runtime unavailable -> `handleRuntimeUnavailable` walks the same ladder
  after `runtimeUnavailableDuration` (`:251-293`).
* A second generation change mid-retry resets to `.observing` again (same
  line), restoring the full attempt budget for the newest network.
* If the re-armed ladder exhausts attempt 2, `state = .confirmed` re-latches
  (already latched) and health was `.notPassingTraffic` the whole time, so
  `shouldNotify` never fires again.

This also intentionally covers `.probation(confirmed: true, ...)`: a network
change during a confirmed-episode probation abandons the probation and
re-arms the ladder. Evidence gathered across an interface swap is not
trustworthy proof of recovery, and the latch keeps reporting stable.

### 3. Healthy evidence while latched requires probation

`.observing + .healthy` currently returns `.passingTraffic` immediately
(`:122-123`). While latched, that would withdraw the warning off a single
healthy poll, violating locked decision 4. Change the `.observing` healthy
arm to:

```swift
case .healthy:
    guard confirmedOutageLatched else {
        return emit(.passingTraffic)
    }
    state = .probation(
        confirmed: false,
        attempt: nil,
        healthyPolls: 1,
        failureSince: nil,
        failureBaseline: nil
    )
    return emit(.unknown)   // floored to .notPassingTraffic
```

Using `confirmed: false` (not `true`) is deliberate: if this probation fails,
the existing arm at `:212-214` falls back to `.observing`, keeping the
re-armed ladder available for the next `.failed` evidence, instead of
snapping back to `.confirmed` and closing the ladder again. Outward health is
unaffected by the choice - the latch floors it either way. The pre-existing
`.confirmed + .healthy -> .probation(confirmed: true, ...)` path (`:182-192`)
is untouched and continues to serve an unchanged-network recovery.

On the second consecutive healthy poll, the existing probation success arm
(`:217-220`) reports `.passingTraffic`; `emit` clears the latch, and the
direct `.notPassingTraffic -> .passingTraffic` transition drives
`shouldWithdraw` in the extension exactly as today.

### 4. What deliberately does not change

* `isConfirmed` stays state-based (`:309-322`) and keeps its two remaining
  jobs: the path-loss guard behavior at `:86-92` and `currentAttempt`
  bookkeeping. The latch is a reporting concern layered on top; do not merge
  the two, or the runtime-unavailable ladder would stop walking during a
  re-armed retry (`handleRuntimeUnavailable` short-circuits on `isConfirmed`
  at `:254-256`, which must keep meaning "state-confirmed", not "latched").
* `recoveryAttemptCompleted` and `invalidatePendingRecoveryAttempt`
  (`:233-249`) are unchanged; the in-flight guard in
  `PacketTunnelProvider.pollTunnelHealth` (`:180-194`) and the
  route/policy-generation match checks in `requestRecovery` (`:233-246`)
  already handle requests racing a path change.
* The evaluator's one-way latch reset on an accepted binding refresh
  (`PacketTunnelProvider.swift:234-242`) already prevents a stale
  `.failed(.oneWayTraffic)` latch from surviving the first re-armed refresh.
* Persistence: health stays `.notPassingTraffic` throughout the retry, so
  `GatewayTunnelHealthPersistencePolicy` sees no new transitions and the
  app-group store keeps showing the in-app warning - intended.

## Scenario walkthroughs

Poll cadence ~5s; thresholds at defaults.

1. **Wi-Fi to cellular while confirmed.** Path change bumps
   `policyGeneration` -> `update` resets to `.observing`, latch stays set,
   health `.notPassingTraffic`. Availability reads `.settling` (up to 30s /
   10s quiet) -> ladder holds. On `.satisfied`, `.failed` evidence requests
   `.bindingRefresh`. Refresh restores inbound -> verifying sees rx progress
   -> probation -> two healthy polls -> `.passingTraffic`, latch clears,
   notification withdraws. Total: one notification for the whole episode.
2. **New network, server still down.** Same start; binding refresh accepted
   but no inbound progress with tx growth -> attempt 2 `.backendRestart` ->
   still nothing -> `.confirmed` again. Health never left
   `.notPassingTraffic`; no second notification.
3. **Airplane-mode cycle on the same network.** Unsatisfied change bumps
   generation (reset while latched), satisfied change bumps again -> fresh
   ladder on re-join, covering the stale-socket case after radio cycling.
4. **Network change during confirmed probation.** Probation abandoned,
   ladder re-armed (Design 2). Warning stays up until a full probation
   passes on the new network.
5. **Tunnel heals on its own on the unchanged network.** `.confirmed +
   .healthy` -> `probation(confirmed: true)` -> two polls -> withdraw.
   Identical to today.

## Implementation stages

### Stage 1: policy change and unit tests

* Add the latch, the `emit` helper, the unconditional generation reset, and
  the latched-observing probation entry.
* Mechanically route all return sites in `update` /
  `handleRuntimeUnavailable` through `emit`.
* Add the test matrix below to `GatewayTunnelHealthTests.swift`.
* Validate: `./scripts/test.sh apple`.

### Stage 2: docs

* Update `docs/apple-tunnel-health-notification.md`: the confirmed state is
  no longer terminal on network change; describe the latch and the re-armed
  ladder. Manual review is enough for the doc-only part.

### Stage 3: real-device validation

See matrix below; requires a controllable server (the deployment blackhole
scenario the detector was originally built for).

## Automated test matrix

New policy tests (drive `update` directly, following the existing style of
`confirmedEpisodeSurvivesPathLossAndNeedsTwoHealthyPolls`):

1. Confirmed + generation change + `.failed` evidence after settle ->
   requests `.bindingRefresh`; health `.notPassingTraffic` on that same
   action (not `.unknown`).
2. Health never leaves `.notPassingTraffic` across the entire re-armed
   ladder: assert every intermediate action (pending, awaiting baseline,
   verifying, escalation to `.backendRestart`, re-confirmation).
3. Re-armed ladder recovery: accepted refresh -> baseline -> inbound
   progress -> probation -> second healthy poll reports `.passingTraffic`.
   Then drive fresh `.failed` evidence and assert the next episode reports
   `.unknown` while pending (proves the latch cleared).
4. Latched `.observing + .healthy` needs two polls: first healthy reports
   `.notPassingTraffic`, second reports `.passingTraffic`; a `.failed` poll
   in between returns to `.observing` still reporting `.notPassingTraffic`
   and a later `.failed` still requests `.bindingRefresh` (probation failure
   does not close the re-armed ladder).
5. Second generation change mid-retry resets the attempt budget: after
   attempt 1 completes on generation N, a change to N+1 with `.failed`
   evidence requests `.bindingRefresh` again (not `.backendRestart`).
6. Runtime-unavailable variant: confirmed -> generation change -> stats/
   evidence stay `nil` -> after `runtimeUnavailableDuration` requests
   `.bindingRefresh`, then `.backendRestart`, then re-confirms, health
   `.notPassingTraffic` throughout.
7. Path not satisfied during a re-armed retry reports `.notPassingTraffic`
   with no recovery request.

Existing tests that must stay green unchanged, re-traced against the design:

* `confirmedEpisodeSurvivesPathLossAndNeedsTwoHealthyPolls` (`:796`) - the
  generation-3 healthy recovery now flows through latched `.observing` ->
  `probation(confirmed: false)` instead of `.confirmed` ->
  `probation(confirmed: true)`, but the observable sequence
  (`.notPassingTraffic`, then `.passingTraffic` on the second healthy poll)
  is identical.
* `rejectedUnavailableRecoveriesStillCompleteTheLadder` (`:781`) - constant
  generation, untouched paths.
* All pre-confirmation ladder and evaluator tests - the latch is `false`
  until first confirmation, and `emit` is the identity while unlatched.

Notification gate (existing coverage in
`GatewayTunnelHealthNotificationTests` already pins both edges; no new tests
needed there, but re-verify):

* `shouldNotify(previous: .notPassingTraffic, current: .notPassingTraffic)`
  is false (no duplicate during retry).
* `shouldWithdraw(previous: .notPassingTraffic, current: .passingTraffic)`
  is true (recovery withdraws).

## Real-device validation

1. Connect on Wi-Fi, blackhole the server (or firewall the WG port), wait
   for the notification. Switch to cellular: warning stays up, no second
   notification; adapter log shows one binding refresh (and a backend
   restart only if the refresh fails); tunnel recovers only if the server is
   reachable from cellular.
2. Same, but unblock the server before switching networks: after the switch
   and settle window, the refresh restores traffic and the warning withdraws
   within ~2 poll intervals of first inbound progress.
3. Confirmed outage, then airplane mode on/off on the same network: one
   retry ladder runs after re-join; no duplicate notification.
4. Regression: ordinary Wi-Fi/cellular handoffs on a healthy tunnel produce
   no notification and no user-visible status churn (pre-confirmation
   behavior is untouched).

## Acceptance criteria

* A confirmed outage followed by a network change runs at most one binding
  refresh and one backend restart per generation change, after the settle
  window.
* Exactly one notification per outage episode, withdrawn only on a genuine
  `.notPassingTraffic -> .passingTraffic` recovery.
* Outward health, once `.notPassingTraffic`, never reports `.unknown` again
  before `.passingTraffic`.
* `./scripts/test.sh apple` passes; no changes outside
  `GatewayTunnelRecoveryPolicy.swift`, its tests, and docs.

## Explicit non-goals

* No periodic re-probe of a confirmed outage on an unchanged network (idle
  dead tunnel stays parked; accepted separately).
* No changes to thresholds, poll cadence, notification copy, or persistence.
* No fork (`wireguard-apple`) changes; no new adapter APIs.
* No endpoint re-resolution - `restartBackend` intentionally reuses resolved
  endpoints (fork design, documented there).

## Privacy and logging

No new logging. The policy is pure and logs nothing; the extension's
existing logs around recovery requests are unchanged. Nothing in this plan
touches traffic contents, destinations, DNS, keys, or per-user history.
