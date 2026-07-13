# Apple Tunnel Backend Restart Recovery Plan

Research and implementation plan only. No production behavior is changed by
this document.

## Goal

Escalate automatic recovery so the blackhole class observed on weak cellular
(2026-07-12, Costco incident) heals without user action, while keeping the
notification timeline, false-positive guardrails, and fail-closed guarantees
of the shipped detection stage unchanged.

The recovery ladder becomes:

1. Attempt 1: lightweight UDP binding refresh (today's behavior) - repairs
   stale NAT/UDP bindings cheaply.
2. Attempt 2: full in-place backend restart via a new fork API - rebuilds
   network settings and the wireguard-go device, the same repair a Control
   Center toggle performs minus hostname re-resolution.
3. Only then confirm the outage and notify, on the same ~50 second timeline.

No stage is added, so no notification latency is added; attempt 2 simply
becomes more powerful.

## Repositories

* CloudGateway: recovery policy escalation, evaluator interplay with counter
  resets, orchestration, tests, dependency pin.
* `wireguard-apple`: one public `restartBackend(completionHandler:)` adapter
  operation.

Companion fork plan:

```text
/Users/alexbrodsky/GitHub/wireguard-apple/TODO/cloudgateway-backend-restart-plan.md
```

Prior stage (shipped in iOS v1.0.0 build 10):

```text
TODO/apple-tunnel-recovery-before-notification-plan.md
docs/apple-tunnel-health-notification.md
```

## Device evidence and mechanism

2026-07-12, iOS v1.0.0 (build 10), weak indoor cellular: tunnel blackholed
while `NWPath` stayed `.satisfied`. Both binding refreshes ran and did not
recover; the policy correctly confirmed and notified (~50s). A manual VPN
toggle recovered immediately. This is a true positive with insufficient
recovery depth, and it satisfies the prior plan's follow-up #2 evidence bar.

Mechanism (community-evidenced, not Apple-confirmed): on marginal signal the
carrier-side PDP context / CGNAT mapping dies while iOS keeps the path
satisfied. `wgBumpSockets` recreates the socket but iOS reattaches it to the
same stale route state. Re-applying `NEPacketTunnelNetworkSettings` and
starting a fresh wireguard-go backend forces iOS to rebuild the flow/route
state; the fork's `.temporaryShutdown` resume path already performs exactly
this sequence but is only reachable when iOS reports the path unsatisfied.

## Locked decisions

* Keep every shipped detection constant unchanged: 5s poll, 10s
  no-handshake grace, 180s stale threshold, 10s/4096-byte one-way window,
  10s verification, 20s runtime-unavailable, two-poll recovery, path
  settling and 30s cap.
* Two recovery attempts per episode, unchanged - but attempt 2 is now the
  backend restart instead of a second binding refresh.
* The notification still fires only after attempt 2 fails with fresh
  post-attempt evidence; expected time-to-notify stays ~40-55s.
* A restart is requested at most once per episode. No restart loops, no
  post-confirmation restarts in this stage.
* A restart that reports failure (adapter lands in `.temporaryShutdown`) is
  not retried by policy. If runtime returns after the fork's path observer
  resumes it, fresh attempt-2 verification continues; otherwise the
  missing-runtime path confirms after 20 seconds on a settled satisfied path.
* Deployment-IP behavior is unchanged: still warns, may still require the
  user toggle. The restart uses the endpoints stored for the adapter's current
  configuration and does not re-resolve the original hostname.
* No auto-disconnect, no fail-open, no external probe, no server-side
  changes, no new persistence or logging.

## Policy design

### Action contract

Replace the boolean on `GatewayTunnelRecoveryAction` with an optional request
kind:

```swift
public enum GatewayTunnelRecoveryRequest: Equatable, Sendable {
    case bindingRefresh   // attempt 1
    case backendRestart   // attempt 2
}
```

`update(...)` returns `.bindingRefresh` on entering attempt 1 and
`.backendRestart` on entering attempt 2. `bindingRefreshCompleted` becomes
`recoveryAttemptCompleted(accepted:at:)`, shared by both attempt kinds; the
`accepted == false` path continues to mean "adapter could not perform the
request" and routes into the runtime-unavailable flow.

The existing `recoveryPending`, `awaitingBaseline`, `verifying`, `confirmed`,
and `probation` stages remain. Probation retains its attempt and fresh-failure
baseline so a brief apparent recovery cannot bypass the remaining verification
window; attempt 2 changes the requested side effect to a backend restart.

### Evaluator interplay: the restart resets counters

A successful restart creates a new wireguard-go device: RX/TX restart at zero
and the handshake epoch is 0 until a new handshake completes. Consequences to
design for explicitly:

* The provider must explicitly reset the evaluator session when the restart
  succeeds. Clearing only the traffic baseline would also remove the sample
  needed to detect counter rollback while preserving the old handshake age.
  A session reset gives the new backend its normal `neverHandshakeGrace`.
* The first near-zero post-restart sample becomes the verification baseline.
  `hasInboundProgress` then reads naturally: any handshake epoch > 0 or RX > 0
  is inbound progress.
* Fresh failure evidence after the restart is new TX with `.failed` evidence,
  same rule as today. The post-restart path to `.failed(.neverHandshaked)`
  takes the 10s grace plus continuing TX, which keeps total time-to-notify in
  the ~40-55s band.
* The policy must not interpret the deliberate counter reset as recovery.
  Only handshake/RX progress is recovery; `warmingUp` evidence during
  post-restart grace publishes `.unknown` as usual.

### Restart failure handling

If `restartBackend` completes with an error, the adapter is in
`.temporaryShutdown`: `getRuntimeConfiguration` returns nil, so the existing
missing-runtime machinery takes over - `.unknown` immediately, confirmed
causal-neutral failure after 20s on a settled satisfied path, silence on a
non-satisfied path. No new policy states are required. The fork's own path
observer resumes the backend on the next real path transition; two healthy
polls then withdraw any warning normally.

## Orchestration (PacketTunnelProvider)

* Map `.bindingRefresh` to `adapter.refreshNetworkBinding` and
  `.backendRestart` to `adapter.restartBackend`, both redispatched to the
  health queue with the existing session/route generation guards.
* Keep stale-callback route generation separate from the health-policy
  generation. A callback from a superseded policy episode is discarded. If
  route churn has reached the aggregate 30-second cap without starting a new
  policy episode, its completion still consumes that attempt so the restart
  ceiling cannot reset, but an old-route binding baseline is never applied.
  A fresh episode rearms only after 10 quiet seconds.
* On restart success, explicitly reset the evaluator session: the next poll's
  near-zero sample becomes the baseline naturally and receives the normal
  handshake warmup. Do not carry any pre-restart baseline or session age
  across the restart.
* The restart can block the adapter work queue for up to ~5 seconds
  (`setNetworkSettings` timeout workaround); the health queue must not treat
  a slow completion as a missed poll. The existing single-in-flight guard
  already covers this.
* Stop/start invalidation, snapshot persistence, and notification behavior
  are unchanged.

## Implementation stages

- [x] Stage 1: fork `restartBackend` API (see fork plan). Committed and
  published at `f9a56d96d1a7163d17bfbfd9712612aa5e8f0b4f` with explicit user
  authorization; no force push.
- [x] Stage 2: advance the three CloudGateway pin references together
  (submodule, Xcode package revision, `Package.resolved`). Fold in the
  pending fork TODO-doc cleanup so one revision carries both.
- [x] Stage 3: policy escalation - request kind enum, shared
  `recoveryAttemptCompleted`, attempt-2 restart semantics, counter-reset
  interplay, deterministic tests.
- [x] Stage 4: provider orchestration and `./scripts/test.sh apple` (115
  CloudGatewayKit tests, iOS view-model tests, and unsigned no-device iOS
  build).
- [ ] Stage 5: device validation (matrix below) recorded in this TODO before
  any constant changes.

## Automated test matrix

* Attempt 1 requests `.bindingRefresh`; attempt 2 requests `.backendRestart`;
  never a second restart in one episode.
* Combined evaluator+policy driver (extend the existing `driveRecovery`
  harness): persistent blackhole where the restart "succeeds" but counters
  reset to zero and never progress confirms once, in the expected poll
  budget, with no spurious `.passingTraffic` after the reset.
* Post-restart counter reset is not treated as inbound progress; a
  post-restart handshake or RX advance is, and withdraws through probation
  normally.
* Restart completion failure routes to the runtime-unavailable flow and
  confirms after 20s on a settled path; runtime returning (path-observer
  resume) re-enters warmup and can reach two healthy polls.
* Late callbacks from an old session or superseded policy episode are
  ignored; a same-episode callback after capped route churn consumes its
  attempt without applying an old-route binding baseline.
* All existing tests continue passing unchanged - detection constants and
  notification edge-triggering are untouched.

## Real-device validation matrix

* Weak-cellular blackhole (the Costco scenario): recovery now succeeds at
  attempt 2 without user action and without any notification. This is the
  headline acceptance test.
* Weak Wi-Fi stale NAT binding: still recovers at attempt 1 (no regression).
* Same-IP server restart: recovers automatically once the server returns;
  warning (if already posted) withdraws.
* Server stopped for several minutes: restart does not create a false
  recovery; exactly one causal-neutral warning; fail-closed routing holds.
* OCI replacement with a new endpoint IP: still warns; still requires the
  expected toggle.
* Mid-restart user disconnect and rapid stop/start: no stale callback,
  snapshot, banner, or notification.
* Wi-Fi/cellular transitions and flaky-network soak: still no false
  positives (re-run the original sensitivity scenarios against this build).

## Acceptance criteria

* The weak-cellular blackhole class recovers automatically with no
  notification and no user action.
* No change to detection sensitivity, notification timeline, single-episode
  semantics, or fail-closed routing.
* A failed restart degrades to today's behavior (causal-neutral warning,
  manual disconnect available), never to a worse state.
* All pure tests and `./scripts/test.sh apple` pass; the fork pin moves as
  one revision across all three references.

## Non-goals and follow-ups

* No original-hostname re-resolution or deployment-IP migration (unchanged
  prior decision; DNS cannot be trusted through a dead tunnel).
* No post-confirmation restart retries; consider only with device evidence
  that late restarts recover real episodes.
* No `am/default-path` adoption; evaluate separately if path-update delivery
  itself proves to be a gap.
* No external probe, APNs, or server-side involvement.

## Privacy and logging

Unchanged from the prior stage: no persistence or logging of counters,
endpoints, path state, restart episodes, or any per-user connection history.
