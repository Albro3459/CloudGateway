# Apple Tunnel Health Coordinator Plan

Research and implementation plan only. No production behavior is changed by
this document.

## Goal

Replace the callback and timer state machine embedded in the iOS packet-tunnel
provider with one deterministic, shared tunnel-health coordinator and one
shared runtime monitor in `CloudGatewayKit`.

The result must:

* preserve the current fail-closed detection and recovery behavior on iOS;
* close the known missing-callback, path-timing, notification-delivery, and
  wall-clock gaps;
* let a future macOS packet-tunnel extension reuse the same detection,
  recovery, scheduling, persistence, and notification state machine;
* leave each platform's packet-tunnel provider responsible only for lifecycle,
  WireGuardKit mapping, `NWPath` mapping, and execution of coordinator effects;
* make complete asynchronous event traces testable without real timers,
  Network Extension, WireGuardKit, or `UNUserNotificationCenter`.

The macOS GUI app will not perform tunnel detection. Detection belongs in its
packet-tunnel extension so it continues while the GUI is backgrounded, closed,
or signed out. The GUI requests notification authorization and consumes the
shared health snapshot, matching iOS.

## Scope

Primary implementation scope:

* `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayKit/`
* `Frontend/Apple/CloudGatewayKit/Tests/CloudGatewayKitTests/`
* `Frontend/Apple/iOS/CloudGatewayTunnel/PacketTunnelProvider.swift`
* the minimum iOS composition changes required to preserve snapshot and
  notification behavior;
* durable Apple architecture and tunnel-health documentation.

Future macOS adoption scope:

* a macOS app target and packet-tunnel extension do not exist yet;
* this work establishes and tests their shared coordinator, monitor, and
  adapter contracts;
* actual macOS target creation, entitlements, signing, UI, and Firebase wiring
  remain a separate implementation effort.

No backend, Firebase, Cloudflare, API, or WireGuard protocol changes are
required.

## Implementation Progress

- [x] Stage 0: freeze the observable contract and select bounded timing values.
- [x] Stage 1: add the unused pure coordinator and characterization traces.
  - [x] Add session-qualified event, effect, wake, and operation primitives.
  - [x] Compose the existing evaluator, recovery, path, and persistence policies.
  - [x] Characterize lifecycle, recovery, path, persistence, notification, and stale-completion traces.
  - [x] Pass the Apple test and unsigned-build target.
  - [x] Complete the Stage 1 reviewer loop.
- [ ] Stage 2: centralize timing and move elapsed-time decisions to monotonic time.
- [ ] Stage 3: close callback, path, notification, and persistence gaps.
- [ ] Stage 4: add the shared runtime monitor and adapters.
- [ ] Stage 5: cut the iOS packet-tunnel provider over to the shared monitor.
- [ ] Stage 6: update durable architecture and tunnel-health documentation.
- [ ] Final implementation review: GPT-5.6 Sol review loop and full Apple validation.

## Current Architecture And Root Cause

The existing pure components are suitable for reuse:

* `GatewayTunnelHealthEvaluator` converts WireGuard runtime counters into
  health evidence;
* `GatewayTunnelRecoveryPolicy` owns the binding-refresh/backend-restart
  ladder, confirmation latch, and recovery probation;
* `GatewayTunnelPathPolicy` owns path settling and route generations;
* `GatewayTunnelHealthPersistencePolicy` controls snapshot transitions and
  heartbeats;
* `GatewayTunnelHealthNotification` owns stable copy, identifier, and health
  edge rules;
* `GatewayTunnelHealthStore` provides shared app-group persistence.

The fragile state machine is in `PacketTunnelProvider`. It currently owns:

* a repeating health timer;
* a serial dispatch queue;
* runtime-read in-flight, start-time, and timeout flags;
* recovery in-flight state;
* session generations;
* path monitoring, fingerprinting, and two path generations;
* evaluator reset ordering around recovery callbacks;
* persistence success bookkeeping;
* notification request and withdrawal races.

The closest integration-style test manually calls the expected evaluator reset
and recovery-completion methods. It proves the intended ideal sequence but does
not execute production callback ordering, timeout handling, session invalidation,
persistence completion, or notification completion. No behavioral test
instantiates the provider orchestration.

This leaves concrete gaps even while all policy tests pass:

1. A WireGuard recovery callback can be lost. `recoveryRequestInFlight` then
   remains set and the recovery policy remains pending indefinitely, so the
   tunnel can stay `unknown` without ever notifying the user.
2. A stalled runtime read continues accumulating age while the path is
   unavailable or settling. It can confirm immediately after a new path settles
   instead of receiving a fresh stable-path deadline.
3. A failed notification add consumes the health edge. The extension does not
   distinguish desired notification state from a successfully registered
   request, so the notification is not retried.
4. Elapsed-time decisions mix `ContinuousClock` and wall-clock `Date`.
   Wall-clock corrections can distort recovery, settling, and persistence;
   future-dated snapshots can remain fresh incorrectly.
5. The orchestration is iOS target code. Reusing it for macOS would require
   copying its timer and callback state machine, recreating the same risks.

## Locked Decisions

1. **Preserve the detector algorithms.** Do not rewrite or retune the evaluator,
   recovery ladder, path policy, health copy, notification identifier, sample
   cadence, or snapshot schema during the behavior-preserving extraction.
2. **Shared first.** The coordinator and runtime monitor live in
   `CloudGatewayKit`, which already targets iOS 17 and macOS 14.
3. **Pure coordinator.** The coordinator imports no SwiftUI, Firebase,
   `Network`, Network Extension, User Notifications, or WireGuardKit types.
4. **One scheduler.** The runtime monitor owns one cancellable wake task. Polls,
   settling, adapter deadlines, persistence heartbeats, and notification retry
   share its single next-deadline calculation. Do not add one timer per concern.
5. **Never await a possibly stuck WireGuard callback.** WireGuard operations
   remain callback-driven. The monitor must continue processing deadlines while
   an adapter operation is outstanding.
6. **One physical WireGuard operation at a time.** Runtime reads, binding
   refreshes, and backend restarts share adapter work-queue constraints. Never
   enqueue recovery behind an operation whose callback is missing.
7. **Explicit identity and lifecycle.** Every session, wake, runtime read,
   recovery request, persistence write, and notification operation carries a
   token with an explicit lifecycle: active, logically timed out but still
   physically outstanding, or completed. Unknown, duplicate, superseded,
   stopped-session, and prior-session completions are harmless no-ops. A
   completion for the current physically outstanding timed-out token may free
   the physical slot and perform narrowly defined post-timeout reconciliation,
   but it cannot erase the logical timeout or directly restore healthy state.
8. **Monotonic durations.** All elapsed-time decisions use an injected monotonic
   time domain. Wall `Date` is used only for WireGuard handshake epochs and the
   cross-process snapshot `updatedAt` value.
9. **Fail closed and notify only.** Detection and recovery never disconnect the
   tunnel, bypass the VPN, or route traffic outside it. Only the user can choose
   to disconnect.
10. **No sensitive telemetry.** Do not log runtime counters, handshakes, traffic,
    DNS, destinations, keys, configs, user connection history, or operation
    traces. Tests use synthetic values only.
11. **Extraction before behavior fixes.** First characterize and reproduce the
    intended current contract in the coordinator. Fix known defects only after
    each has a failing coordinator trace.
12. **No duplicate orchestrators.** Once iOS cuts over, remove the old timer,
    flags, and callback state. Do not leave a legacy and new state machine active
    together.
13. **Bounded stop from the first instruction.** At `stopTunnel` entry,
    synchronously close a session-generation effect gate before bridging to the
    actor, then arm the stop fallback and start monitor cleanup and adapter stop
    in parallel. No new persistence or notification effect may start through a
    closed gate. Normal completion waits for in-flight persistence/notification
    reconciliation, final clear/withdraw, and the adapter callback. Deadline
    completion performs idempotent best-effort synchronous clear/withdraw and
    completes without claiming durable cleanup succeeded. Monitor shutdown never
    waits for a WireGuard callback; all waiting remains bounded by the outer stop
    fallback.

## Target Architecture

### 1. `GatewayTunnelHealthCoordinator`

Add a value-type reducer in `CloudGatewayKit`. It owns all deterministic health
state and converts one event into effects plus the next required wake time.

Suggested shape:

```swift
public struct GatewayTunnelHealthMoment: Equatable, Sendable {
    public let monotonic: Duration
    public let wall: Date
}

public struct GatewayTunnelHealthCoordinator: Sendable {
    public mutating func start(
        session: GatewayTunnelHealthSessionID,
        tunnelIdentifier: String,
        at moment: GatewayTunnelHealthMoment
    ) -> GatewayTunnelHealthTransition

    public mutating func handle(
        _ event: GatewayTunnelHealthEvent,
        at moment: GatewayTunnelHealthMoment
    ) -> GatewayTunnelHealthTransition
}
```

The exact public access level should be the minimum needed by the shared monitor
and tests. Keep internal policy details hidden.

Coordinator-owned state:

* active session and tunnel identifier;
* evaluator, recovery policy, path policy, and persistence policy;
* last successfully published health;
* desired notification state and successfully registered request state;
* current physical WireGuard operation and its token;
* logical deadline state for a timed-out operation that may still complete;
* pending persistence and notification operation tokens;
* next poll, settle, operation, heartbeat, and retry deadlines;
* backend-restart capability for the current runtime adapter.

### 2. Events

Events contain plain, `Sendable` values only:

```swift
public enum GatewayTunnelHealthEvent: Sendable {
    case wake(GatewayTunnelHealthWakeID)
    case pathChanged(GatewayTunnelPathDescriptor)
    case runtimeReadCompleted(
        GatewayTunnelHealthOperationID,
        GatewayTunnelRuntimeStats?
    )
    case recoveryCompleted(
        GatewayTunnelHealthOperationID,
        GatewayTunnelRecoveryResult
    )
    case persistenceCompleted(
        GatewayTunnelHealthOperationID,
        GatewayTunnelEffectResult
    )
    case notificationCompleted(
        GatewayTunnelHealthOperationID,
        GatewayTunnelNotificationResult
    )
    case stop
}
```

`GatewayTunnelPathDescriptor` must not expose `NWPath` or its gateway/interface/
DNS details. The platform adapter keeps the existing fingerprint private and
emits only satisfaction plus a route-change identity or generation after it has
deduplicated meaningful changes.

### 3. Effects

The coordinator requests side effects but never executes them:

```swift
public enum GatewayTunnelHealthEffect: Sendable {
    case readRuntime(GatewayTunnelHealthOperationID)
    case refreshBinding(GatewayTunnelHealthOperationID)
    case restartBackend(GatewayTunnelHealthOperationID)
    case persist(
        GatewayTunnelHealthOperationID,
        GatewayTunnelHealthSnapshot
    )
    case clearSnapshot
    case registerNotification(GatewayTunnelHealthOperationID)
    case reconcileNotification(GatewayTunnelHealthOperationID)
    case withdrawNotification
}

public struct GatewayTunnelHealthTransition: Sendable {
    public let effects: [GatewayTunnelHealthEffect]
    public let nextWake: GatewayTunnelHealthWake?
}
```

`nextWake` is the earliest pending deadline. A wake carries its own identifier;
when a transition reschedules it, a late old wake is ignored.

### 4. `GatewayTunnelHealthMonitor`

Add a shared actor/driver in `CloudGatewayKit`. It:

* serializes all coordinator events;
* owns exactly one cancellable wake task;
* obtains monotonic and wall time through an injected time source;
* executes effects through small injected protocols;
* returns effect completions to the coordinator with the original tokens;
* starts callback-based WireGuard work without awaiting it;
* guarantees that stop invalidates the session and wake before callbacks can
  mutate new state;
* coordinates in-flight persistence/notification completion and final
  clear/withdraw before reporting a normal-path stop.

Required dependency boundaries:

* runtime reader and recovery executor;
* snapshot persistence;
* notification registration/reconciliation;
* clock and sleeper/scheduler.

Production adapters wrap WireGuardKit, `GatewayTunnelHealthStore`, and
`UNUserNotificationCenter`. Test adapters are deterministic and never sleep.
CloudGatewayKit adapter protocols expose only `Sendable` values and `@Sendable`
completion closures. The platform target owns the concrete WireGuardKit object
on a narrowly scoped serial executor; the monitor never imports, stores, or
captures `WireGuardAdapter` directly. If an `@unchecked Sendable` wrapper is
unavoidable, document and test its queue-confinement invariant at that wrapper.
The platform effect wrapper also owns a synchronously closable session-generation
gate. A persistence or notification completion that discovers its generation is
closed reports a possible stale-artifact write to a shared, serialized artifact
reconciler rather than directly clearing or withdrawing anything. The reconciler
consults the newest session's desired snapshot and notification state:

* with no newer active session, it clears/withdraws;
* with a newer active session, it rewrites that session's desired snapshot or
  clears it if none is desired;
* with a newer confirmed outage, it preserves/reconciles the stable notification
  request instead of withdrawing it;
* with a newer healthy session, it withdraws the notification.

An old generation never directly mutates a shared artifact after consulting only
its own stale state. Operation identifiers include session generation so the
reconciler can distinguish contamination from a current completion.

### 5. Thin Platform Extensions

The iOS and future macOS packet-tunnel providers retain:

* `NEPacketTunnelProvider` lifecycle methods;
* provider-configuration and Keychain lookup;
* parsed-config to WireGuardKit mapping;
* WireGuard adapter start and stop;
* `NWPathMonitor` and path fingerprint mapping;
* effect adapters for WireGuardKit and User Notifications;
* platform-specific stop-completion protection.

They do not own evaluator/recovery state, polling flags, operation deadlines,
notification edges, persistence heartbeats, or multiple health timers.

### 6. Capability Contract For macOS

The pinned WireGuard fork currently exposes `refreshNetworkBinding` on iOS and
macOS, but its public `restartBackend` entry point is iOS-only even though the
lower-level restart implementation is portable.

Model backend restart as a runtime capability:

* iOS reports it supported and executes the existing API;
* macOS initially reports it unsupported;
* unsupported completion follows a bounded recovery-policy path to confirmation
  and notification rather than remaining pending;
* exposing and validating macOS backend restart in the fork is a separate,
  reviewable task before or during macOS target implementation.

Do not add WireGuardKit as a `CloudGatewayKit` dependency to solve this. The
coordinator deals only in effects and capability results.

## Timing Contract

Create one `GatewayTunnelHealthTiming` configuration containing every duration:

* runtime poll interval;
* runtime-read deadline;
* runtime-unavailable duration;
* path quiet period and settling cap;
* recovery verification duration;
* recovery-operation deadline;
* healthy polls required for recovery;
* persistence heartbeat;
* snapshot freshness;
* notification retry delays and maximum retry delay.

Retain current production values during extraction. The selected new values are:

* 20-second recovery-operation deadline;
* 10-second notification callback/reconciliation deadline;
* retryable notification failures start at 5 seconds and double to a 60-second
  maximum delay;
* 5-second future-timestamp tolerance for snapshot freshness.

Notification authorization denial is terminal for the session. Callback loss,
transient notification-center failures, and an unknown reconciliation result are
retryable within the bounded policy. These values remain plan constants until
Stage 2 introduces `GatewayTunnelHealthTiming.production`; they must not be
introduced as independent production literals. Neither operation deadlines nor
retry delays may be infinite.

Initialization or tests must enforce:

* persistence heartbeat is shorter than snapshot freshness;
* all durations are nonnegative;
* recovery probation requires at least one poll;
* retry delays are bounded.

`GatewayTunnelHealthTiming.production` is the single shared production default.
The extension producer and app-side snapshot consumer must both use its
heartbeat/freshness values. If `GatewayTunnelHealthSnapshot.isFresh` accepts an
override for tests, production call sites pass the shared production freshness
explicitly rather than relying on a second literal or default.

Move duration comparisons in the evaluator, recovery policy, path policy, and
persistence policy to monotonic time. Preserve wall time only for:

* comparing WireGuard's handshake epoch with current wall time;
* writing `GatewayTunnelHealthSnapshot.updatedAt` for another process.

Harden snapshot freshness so a future timestamp is not fresh indefinitely.
A large backward wall-clock correction should temporarily suppress the app
banner until the extension's next heartbeat rewrites the snapshot, not preserve
an old warning forever.

## State Invariants

Coordinator and monitor tests must enforce these invariants over complete
traces:

1. At most one physical WireGuard operation is outstanding.
2. At most one wake task is current.
3. Missing callbacks never stop deadline processing.
4. A stale callback cannot mutate policy state, acknowledge a newer write, or
   alter desired or registered notification state.
5. Stop makes every prior token invalid. The normal path clears durable
   user-visible state before completion; the deadline path performs the same
   idempotent cleanup best-effort before completing.
6. Closing the synchronous effect gate prevents new persistence or notification
   work immediately, even before the actor processes `.stop`. Late completions
   from a closed generation trigger generation-aware artifact reconciliation;
   they can neither clear nor overwrite a newer session's desired state.
7. A new session cannot inherit health, retries, deadlines, or callbacks from a
   prior session.
8. Recovery and confirmation policy cannot advance while the path is
   unavailable or settling. The evaluator may continue deriving raw evidence,
   matching current behavior, but that evidence cannot trigger recovery or
   confirmation until the path policy is satisfied.
9. Unavailable/settling time does not consume a fresh stable-path deadline.
10. A confirmed outage remains `notPassingTraffic` until the existing healthy
   probation proves recovery.
11. One continuous confirmed episode produces at most one successfully
    registered notification request. Startup, stop, recovery, and late-request
    reconciliation may issue repeated, bounded, idempotent withdrawals.
12. Notification and persistence failures are not recorded as successes.
13. Pending effect and retry counts remain bounded.
14. Idle traffic cannot prove a dead tunnel.
15. No coordinator effect contains raw configuration, keys, packet data, DNS,
    destinations, or runtime counters beyond the in-memory synthetic/runtime
    stats required by the evaluator.

## Implementation Stages

### Stage 0 - Freeze The Observable Contract

Before production extraction, record the current intended behavior in test
names and plan assertions:

* 5-second runtime sampling;
* current evidence and recovery thresholds;
* binding refresh followed by backend restart;
* path settling and confirmed-outage re-arm behavior;
* two-poll healthy probation;
* one notification per continuous outage;
* 15-second snapshot heartbeat and 30-second freshness;
* start/stop snapshot and notification cleanup;
* no auto-disconnect.

The behavior-preserving extraction is pinned to this production contract:

| Concern | Observable contract |
| --- | --- |
| Sampling | Read runtime every 5 seconds; a runtime read becomes logically unavailable after 20 seconds. |
| Never handshaked | Allow 10 seconds after evaluator/session reset before treating a missing handshake as failed evidence. |
| Stale handshake | A handshake older than 180 seconds is failed evidence. |
| One-way traffic | Require a 10-second evidence window and at least 4,096 bytes of transmit growth without receive growth; idle traffic is not failure evidence. |
| Recovery | Attempt binding refresh, verify for 10 seconds, then attempt backend restart and verify for 10 seconds before confirmation. |
| Runtime unavailable | Begin recovery after 20 seconds of unavailable runtime, then use the same two-step ladder. |
| Path changes | Wait for 10 seconds of quiet, capped at 30 seconds of continuous churn; re-arm recovery without clearing a confirmed outage. |
| Recovery probation | Require two consecutive healthy polls before changing a confirmed outage to passing traffic. |
| Persistence | Persist health transitions and an unchanged-health heartbeat every 15 seconds. |
| Snapshot consumption | Treat snapshots as fresh for 30 seconds, subject to the selected 5-second future tolerance. |
| Notification | Register once per continuous confirmed outage and withdraw on startup, recovery, and stop. |
| Safety | Notify only. Never auto-disconnect or bypass the fail-closed tunnel. |

Decide and document:

* the recovery-operation deadline;
* notification failure classification and bounded retry delays;
* the acceptable future-timestamp tolerance for snapshot freshness.

Acceptance:

* the behavior table is reviewable without reading provider code;
* new values are centralized rather than introduced as literals;
* no production behavior changes.

### Stage 1 - Add Coordinator Characterization Tests

Add:

* `GatewayTunnelHealthCoordinator.swift`;
* `GatewayTunnelHealthCoordinatorTests.swift`;
* the minimum event/effect, moment, session, wake, operation-token, and
  effect-completion primitives required by the coordinator contract;
* a compact trace harness using fixed moments, events, expected effects, health,
  and next wakes.

Compose existing policies. Do not duplicate their algorithms or remove their
unit tests. Initially keep the coordinator unused by production.

Characterize:

* healthy startup and persistence heartbeat;
* never-handshaked, stale-handshake, and one-way blackholes;
* accepted and rejected binding refresh;
* accepted and rejected backend restart;
* evaluator resets after each recovery type;
* runtime-unavailable ladder;
* confirmed-outage path-change re-arm;
* healthy probation and notification withdrawal;
* start and stop cleanup;
* unchanged health and stable notification behavior;
* persistence failure remaining due.

Acceptance:

* tests express full input/output traces without directly resetting evaluator or
  recovery-policy internals;
* the coordinator depends only on plain shared types;
* existing policy tests remain intact;
* no production provider changes.

### Stage 2 - Centralize Time, Tokens, And Deadlines

Centralize and complete:

* `GatewayTunnelHealthTiming`;
* explicit runtime-read and recovery deadlines;
* desired-versus-completed persistence state;
* desired notification state versus successfully registered request state.

Convert elapsed-time policy internals to monotonic inputs while retaining wall
time for handshake epoch and persisted timestamps.

Add tests proving:

* wall time moving backward or forward cannot accelerate or stall monotonic
  detection/recovery deadlines;
* a future-dated snapshot is bounded and corrected by a later heartbeat;
* normal-time traces retain their current timing;
* old wake and operation tokens are ignored.

Acceptance:

* all health durations have one configuration owner;
* no coordinator duration depends on wall-clock subtraction;
* snapshot schema remains compatible;
* producer heartbeat and consumer freshness use the same shared production
  timing configuration.

### Stage 3 - Close Known Orchestration Gaps Behind Failing Traces

Add one failing trace before each behavior change.

#### Missing runtime-read callback

* deadline processing continues independently of the adapter queue;
* confirmation requires a stably satisfied path;
* no recovery operation is queued behind the stuck read;
* an eventual completion for the current timed-out token frees the physical
  operation slot and enters the existing healthy probation or retains the
  confirmed outage as appropriate; it cannot directly clear the logical
  timeout.

#### Missing recovery callback

* recovery cannot remain pending indefinitely;
* its deadline moves to the documented bounded confirmation path;
* the physical operation remains marked outstanding so no second WireGuard
  operation is queued behind it;
* a late completion for the current timed-out token may apply only the evaluator
  reset justified by the operation that physically occurred and free the slot;
  it cannot undo newer logical state or withdraw the outage without probation.

#### Path change during an outstanding read

* unavailable and settling time do not consume the read-failure deadline;
* stable satisfaction starts a fresh full deadline;
* the original physical read remains the only adapter operation.

#### Path change during recovery

* stale route completions cannot advance the new route's ladder;
* evaluator reset occurs only when justified by the operation that actually
  completed;
* the confirmed outage latch remains stable across re-arm.

#### Notification failure or missing callback

* desired notification state is tracked separately from successful request
  registration;
* retryable errors use bounded backoff;
* denied/terminal authorization state does not spin;
* recovery and stop cancel pending post retries;
* a late successful post after recovery triggers idempotent withdrawal;
* when an add callback is missing, query both pending and delivered requests for
  the stable identifier before deciding whether to retry;
* an ambiguous submission is never blindly re-added, because replacing or
  redelivering the stable identifier could alert twice.

#### Persistence failure

* persistence policy records success only after successful write completion;
* the current snapshot remains due after failure;
* an old write completion cannot acknowledge a newer snapshot.

Acceptance:

* every listed trace passes;
* stale completions emit no effects;
* pending effects and retries remain bounded;
* no real sleep or dispatch timer is used in tests.

### Stage 4 - Add The Shared Runtime Monitor

Add `GatewayTunnelHealthMonitor` and injected adapter protocols.

Driver tests use a manual scheduler and controllable callbacks to prove:

* only one wake task is active;
* rescheduling invalidates the old wake identifier;
* missing callbacks do not block wake processing;
* duplicate and out-of-order completions are harmless;
* stop followed by restart rejects all prior-session callbacks;
* no effect starts after shutdown;
* the synchronous effect gate closes before the actor receives `.stop`;
* the normal path reconciles in-flight persistence/notification work, performs
  final clear/withdraw, and only then reports stopped;
* a late persistence or notification completion on a closed generation invokes
  generation-aware artifact reconciliation;
* an old snapshot completion arriving after a new session rewrites or preserves
  the new session's desired snapshot rather than clearing it;
* an old notification completion arriving during a new confirmed outage
  preserves/reconciles the new session's stable notification, while the same
  completion during a new healthy session withdraws it;
* the deadline path completes after best-effort cleanup without asserting that
  durable cleanup succeeded;
* unsupported backend restart follows the bounded policy path.

Do not use continuations that require WireGuard callbacks to resume the monitor.

Acceptance:

* monitor tests are deterministic and use no real delays;
* coordinator and monitor are compiled for both package platforms;
* Network Extension, WireGuardKit, and User Notifications remain adapter-only;
* the shared monitor never directly imports or stores a WireGuardKit object;
* any platform `@unchecked Sendable` wrapper has documented and tested serial
  executor confinement.

### Stage 5 - Cut iOS Over In One Isolated Change

Replace the provider-owned health state with:

* one `GatewayTunnelHealthMonitor`;
* one `NWPathMonitor` adapter;
* WireGuard runtime/recovery effect adapters;
* snapshot and notification effect adapters;
* start/stop lifecycle bridging.

Remove after cutover:

* `healthTimer`;
* provider-owned evaluator, recovery, path, and persistence policies;
* runtime-read/recovery flags and timestamps;
* provider-owned health session generation;
* provider-owned notification edge bookkeeping.

Preserve:

* WireGuard starts before health monitoring;
* normal-path health cleanup finishes before stop completion;
* bounded stop-completion protection, extending `GatewayTunnelStopCompletion`
  if needed so normal completion waits for both cleanup and adapter stop;
* current app-group path, snapshot schema, notification identifier, and copy;
* no sensitive logging;
* app-side signed-in, guest, and signed-out warning behavior.

The stop fallback is armed at `stopTunnel` entry. Monitor cleanup and adapter
stop begin independently so a stalled actor or adapter cannot prevent the other
from starting. Before either begins, the platform wrapper synchronously closes
the current session-generation effect gate. On the normal path, let in-flight
persistence and notification registration/reconciliation finish, perform final
snapshot clear and pending/delivered notification removal, then open the shared
completion gate after the adapter callback also arrives. User Notifications
provides no confirmation callback for removal, so issuing both removal calls is
the normal-path completion boundary. On the deadline path, invoke the same
cleanup synchronously and best-effort from the platform shutdown adapter, then
open the gate without asserting durable cleanup succeeded. Cleanup is
idempotent. Any late persistence or notification completion that still runs in
the closed generation reports possible artifact contamination to the serialized
reconciler and does not forward success into the stopped monitor. The reconciler
uses the newest active generation's desired state, so old cleanup cannot erase a
new session's valid snapshot or notification.

Acceptance:

* `PacketTunnelProvider` contains lifecycle and adapter translation, not health
  policy state;
* `./scripts/test.sh apple` passes;
* `git diff --check` passes;
* the unsigned generic iOS extension build passes Swift 6 concurrency checks.

### Stage 6 - iOS Device Validation And Documentation

Run the real-device matrix below. Fix orchestration defects behind coordinator
or monitor traces before patching platform-provider behavior directly.

Update:

* `docs/apple-tunnel-health-notification.md`;
* `docs/apple-ios-app.md`;
* `Frontend/Apple/CloudGatewayKit/README.md`.

Update `Frontend/Apple/macOS/README.md` only to document the established shared
adapter/capability contract. Do not claim the macOS targets exist.

Acceptance:

* automated and device gates pass;
* durable docs describe the coordinator and shared Apple boundary;
* this plan can be removed after the completed behavior is documented.

### Stage 7 - Future macOS Adoption

When creating the macOS targets:

1. Add the macOS app and packet-tunnel extension with their own bundle IDs,
   app group, Keychain access group, Network Extension entitlements, and signing.
2. Reuse `GatewayTunnelHealthCoordinator`, `GatewayTunnelHealthMonitor`, timing,
   store, notification contract, and trace suite without forking them.
3. Implement only the macOS WireGuardKit, `NWPathMonitor`, snapshot,
   notification, and provider lifecycle adapters.
4. Request notification authorization and configure foreground presentation in
   the macOS app lifecycle.
5. Initially report backend restart unsupported, or land a separate fork change
   that exposes and validates the existing restart primitive on macOS.
6. Add macOS adapter compile tests and run the same device scenario matrix.

Acceptance:

* macOS contains no independent polling/recovery state machine;
* macOS contains no duplicate health timers;
* unsupported deep restart still reaches bounded detection and notification;
* iOS and macOS produce the same coordinator traces for the same inputs.

## Automated Trace Matrix

### Normal operation

* healthy startup, stable polling, and heartbeat persistence;
* idle tunnel remains nonfailed;
* never-handshaked tunnel;
* stale handshake;
* one-way TX progress with flat RX;
* inbound progress clearing one-way evidence;
* counter reset and new evaluator session.

### Recovery

* binding refresh accepted, rejected, unsupported, late, duplicated, and lost;
* backend restart accepted, rejected, unsupported, late, duplicated, and lost;
* runtime absence through the full ladder;
* probation success and failure after each recovery type;
* no second adapter operation behind a stuck operation.

### Path sequencing

* unavailable at startup;
* settling then satisfied;
* path churn below and beyond the settle cap;
* Wi-Fi/cellular-style generation change during read;
* path loss during each recovery stage;
* confirmed outage re-arm without notification flapping;
* fresh stable-path deadline after a long unavailable period.

### Session and callback ordering

* stop during runtime read;
* stop during binding refresh;
* stop during backend restart;
* stop followed by a new session before old callbacks arrive;
* callbacks arriving late, twice, and out of order;
* old wake firing after reschedule;
* persistence/notification completion after stop.
* old persistence completion after a new session has published healthy state;
* old persistence completion after a new session has published a dead snapshot;
* old notification completion after a new healthy session starts;
* old notification completion while a new session legitimately needs the stable
  outage notification.

### Persistence and notification

* transition write and heartbeat write;
* store failure and bounded retry;
* older write completing after a newer write;
* one notification per continuous outage;
* notification add failure and retry;
* notification add callback lost, followed by pending/delivered reconciliation;
* denied/terminal authorization result without retry loop;
* recovery before notification add completion;
* stop before notification add completion;
* bounded withdrawal idempotence, including repeated startup/stop/late-request
  reconciliation removals without a second registration.

### Time

* monotonic deadlines with wall clock moving backward;
* monotonic deadlines with wall clock moving forward;
* future-dated persisted snapshot;
* persistence heartbeat remains shorter than freshness;
* exact deadline boundary behavior.

## Real-Device Validation Matrix

Run on iOS after the isolated cutover and before merge or release, and on macOS
when its packet-tunnel target exists. The previous implementation remains only
as a revertable Git commit, never as an active or compiled fallback path:

1. Healthy tunnel through normal foreground/background use.
2. Server-side blackhole with continuing traffic.
3. Server recovery before confirmation.
4. Server recovery after notification.
5. Peer deletion or never-handshaked connection.
6. Airplane mode off/on.
7. Wi-Fi to cellular and cellular to Wi-Fi.
8. Repeated path churn during recovery.
9. App backgrounded and force-closed.
10. User signed out with an installed active tunnel.
11. Notification permission granted, denied, and previously decided.
12. Disconnect during an outstanding runtime read or recovery request.
13. Extension stop/restart while old callbacks are delayed.
14. Device wall-clock correction while the tunnel is active.

Verify:

* ordinary path settling produces no warning;
* a persistent blackhole produces one notification and one current snapshot;
* recovery withdraws the warning only after the required probation;
* no continuous episode posts twice;
* normal stop removes the snapshot and notification before completion;
* deadline stop closes the effect gate and issues best-effort cleanup, while
  late completions reconcile against the newest active generation;
* traffic remains fail-closed until the user disconnects;
* no private tunnel data appears in logs or persisted health state.

## Validation Commands

For each Apple implementation stage:

```sh
./scripts/test.sh apple
```

Use the signed gate when provisioning, entitlements, or signed extension changes
are involved:

```sh
./scripts/test.sh apple --signed
```

Do not use the raw `CloudGateway` scheme for unit tests. The repository Apple
gate owns the host-less view-model tests and unsigned extension build.

This plan-only change requires manual review and no test run.

## Suggested Reviewable Checkpoints

1. Contract, timing configuration, and coordinator characterization tests.
2. Pure coordinator with monotonic time and operation tokens.
3. Known-gap failing traces and fixes.
4. Shared monitor and deterministic driver tests.
5. iOS provider cutover.
6. iOS signed/device validation and durable docs.
7. macOS adapter and optional WireGuard fork restart support later.

Keep these checkpoints independently reviewable. Do not combine evaluator
threshold tuning, WireGuardKit macOS restart exposure, snapshot schema changes,
UI redesign, or macOS target creation with the iOS orchestration extraction.

## Non-Goals

* No detector threshold tuning without new device evidence.
* No auto-disconnect or split-tunnel escape route.
* No backend reachability probe.
* No API/Firebase/Cloudflare health signal.
* No traffic, DNS, endpoint, packet, or per-user connection telemetry.
* No WireGuard private key or full-config movement into app-group storage.
* No Firebase, SwiftUI, or app lifecycle dependency in `CloudGatewayKit`.
* No macOS GUI or target implementation in the iOS cutover.
* No requirement to replace the app's snapshot-consumer refresh mechanism in
  this extraction. If both GUIs later need a richer live observer, add one
  shared snapshot-observation abstraction as a separate presentation task.

## Completion Criteria

The rearchitecture is complete when:

* the shared coordinator owns all health transitions, operation identity,
  deadlines, persistence intent, and notification intent;
* the shared monitor owns one scheduler and executes effects through adapters;
* iOS provider code contains no duplicate health state machine;
* all listed automated invariants and known-gap traces pass;
* the full Apple gate and required signed/device checks pass;
* iOS behavior remains fail-closed and produces one notification per outage;
* the macOS capability/adapter seam is documented and compile-safe;
* durable docs are updated and this temporary plan is removed.
