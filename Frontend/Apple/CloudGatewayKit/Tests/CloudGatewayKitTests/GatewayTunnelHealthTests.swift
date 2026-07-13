import Foundation
import Testing
@testable import CloudGatewayKit

// MARK: - Runtime stats parsing

@Test func parsesSinglePeerRuntimeStats() {
    let uapi = """
    private_key=aa
    listen_port=51820
    public_key=bb
    endpoint=1.2.3.4:51820
    last_handshake_time_sec=1700000000
    last_handshake_time_nsec=0
    tx_bytes=1500
    rx_bytes=2500
    persistent_keepalive_interval=25
    allowed_ip=0.0.0.0/0
    errno=0
    """
    let stats = GatewayTunnelRuntimeStats.parse(uapi)
    #expect(stats == GatewayTunnelRuntimeStats(latestHandshakeEpochSeconds: 1700000000, rxBytes: 2500, txBytes: 1500))
}

@Test func aggregatesMultiplePeers() {
    let uapi = """
    private_key=aa
    public_key=bb
    last_handshake_time_sec=1700000000
    tx_bytes=100
    rx_bytes=200
    public_key=cc
    last_handshake_time_sec=1700000500
    tx_bytes=50
    rx_bytes=25
    """
    let stats = GatewayTunnelRuntimeStats.parse(uapi)
    // Newest handshake, summed counters.
    #expect(stats == GatewayTunnelRuntimeStats(latestHandshakeEpochSeconds: 1700000500, rxBytes: 225, txBytes: 150))
}

@Test func neverHandshakedParsesAsZero() {
    let uapi = """
    private_key=aa
    public_key=bb
    last_handshake_time_sec=0
    tx_bytes=0
    rx_bytes=0
    """
    let stats = GatewayTunnelRuntimeStats.parse(uapi)
    #expect(stats?.latestHandshakeEpochSeconds == 0)
    #expect(stats?.rxBytes == 0)
}

@Test func interfaceOnlyConfigReturnsNil() {
    let uapi = """
    private_key=aa
    listen_port=51820
    errno=0
    """
    #expect(GatewayTunnelRuntimeStats.parse(uapi) == nil)
}

@Test func parserIgnoresMalformedLines() {
    let uapi = """
    public_key=bb
    garbage-without-separator
    last_handshake_time_sec=notanumber
    rx_bytes=10
    tx_bytes=
    """
    let stats = GatewayTunnelRuntimeStats.parse(uapi)
    #expect(stats == GatewayTunnelRuntimeStats(latestHandshakeEpochSeconds: 0, rxBytes: 10, txBytes: 0))
}

// MARK: - Health evaluation

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func stats(handshakeSecondsAgo: Double?, rx: UInt64, tx: UInt64, relativeTo reference: Date = now) -> GatewayTunnelRuntimeStats {
    let epoch: Int
    if let handshakeSecondsAgo {
        epoch = Int(reference.timeIntervalSince1970 - handshakeSecondsAgo)
    } else {
        epoch = 0
    }
    return GatewayTunnelRuntimeStats(latestHandshakeEpochSeconds: epoch, rxBytes: rx, txBytes: tx)
}

@Test func neverHandshakedIsUnknownWithinGraceThenDead() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    #expect(evaluator.evaluateEvidence(stats(handshakeSecondsAgo: nil, rx: 0, tx: 0), at: now.addingTimeInterval(9)) == .warmingUp)
    #expect(evaluator.evaluateEvidence(stats(handshakeSecondsAgo: nil, rx: 0, tx: 0), at: now.addingTimeInterval(10)) == .failed(.neverHandshaked))
}

@Test func freshHandshakeWithReceiveActivityIsHealthy() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    let sample = stats(handshakeSecondsAgo: 5, rx: 1000, tx: 1000, relativeTo: now.addingTimeInterval(1))
    #expect(evaluator.evaluate(sample, at: now.addingTimeInterval(1)) == .passingTraffic)
}

@Test func staleHandshakeIsDead() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    let sample = stats(handshakeSecondsAgo: 200, rx: 1000, tx: 1000, relativeTo: now.addingTimeInterval(5))
    #expect(evaluator.evaluate(sample, at: now.addingTimeInterval(5)) == .notPassingTraffic)
}

@Test func oneWayDeadWhenReceiveFlatAndSendGrows() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    _ = evaluator.evaluate(stats(handshakeSecondsAgo: 5, rx: 1000, tx: 1000), at: now)
    _ = evaluator.evaluate(stats(handshakeSecondsAgo: 6, rx: 1000, tx: 6000, relativeTo: now.addingTimeInterval(1)), at: now.addingTimeInterval(1))
    let sample = stats(handshakeSecondsAgo: 16, rx: 1000, tx: 6000, relativeTo: now.addingTimeInterval(11))
    #expect(evaluator.evaluateEvidence(sample, at: now.addingTimeInterval(11)) == .failed(.oneWayTraffic))
}

@Test func longIdleThenBurstWaitsFullWindow() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    _ = evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 5, rx: 1000, tx: 1000), at: now)
    _ = evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 105, rx: 1000, tx: 1000, relativeTo: now.addingTimeInterval(100)), at: now.addingTimeInterval(100))
    #expect(evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 106, rx: 1000, tx: 6000, relativeTo: now.addingTimeInterval(101)), at: now.addingTimeInterval(101)) == .healthy)
    #expect(evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 115, rx: 1000, tx: 6000, relativeTo: now.addingTimeInterval(110)), at: now.addingTimeInterval(110)) == .healthy)
    #expect(evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 116, rx: 1000, tx: 6000, relativeTo: now.addingTimeInterval(111)), at: now.addingTimeInterval(111)) == .failed(.oneWayTraffic))
}

@Test func subthresholdWindowsDoNotAccumulate() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    _ = evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 5, rx: 1, tx: 0), at: now)
    _ = evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 6, rx: 1, tx: 100, relativeTo: now.addingTimeInterval(1)), at: now.addingTimeInterval(1))
    #expect(evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 16, rx: 1, tx: 200, relativeTo: now.addingTimeInterval(11)), at: now.addingTimeInterval(11)) == .healthy)
    _ = evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 17, rx: 1, tx: 300, relativeTo: now.addingTimeInterval(12)), at: now.addingTimeInterval(12))
    #expect(evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 27, rx: 1, tx: 400, relativeTo: now.addingTimeInterval(22)), at: now.addingTimeInterval(22)) == .healthy)
}

@Test func counterAndClockRollbackRestartWarmup() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    _ = evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 5, rx: 100, tx: 100), at: now.addingTimeInterval(20))
    #expect(evaluator.evaluateEvidence(stats(handshakeSecondsAgo: nil, rx: 0, tx: 0), at: now.addingTimeInterval(21)) == .warmingUp)
    #expect(evaluator.evaluateEvidence(stats(handshakeSecondsAgo: nil, rx: 0, tx: 0), at: now.addingTimeInterval(19)) == .warmingUp)

    var staleEvaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    _ = staleEvaluator.evaluateEvidence(stats(handshakeSecondsAgo: 5, rx: 100, tx: 100), at: now.addingTimeInterval(20))
    #expect(staleEvaluator.evaluateEvidence(stats(handshakeSecondsAgo: 200, rx: 0, tx: 0, relativeTo: now.addingTimeInterval(21)), at: now.addingTimeInterval(21)) == .warmingUp)
}

@Test func explicitSessionResetRestartsHandshakeWarmupWithoutPriorSample() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    _ = evaluator.evaluateEvidence(
        stats(handshakeSecondsAgo: 200, rx: 100, tx: 100, relativeTo: now.addingTimeInterval(20)),
        at: now.addingTimeInterval(20)
    )

    evaluator.resetSession(at: now.addingTimeInterval(21))

    let freshBackend = GatewayTunnelRuntimeStats(
        latestHandshakeEpochSeconds: 0,
        rxBytes: 0,
        txBytes: 0
    )
    #expect(evaluator.evaluateEvidence(freshBackend, at: now.addingTimeInterval(21)) == .warmingUp)
    #expect(evaluator.evaluateEvidence(freshBackend, at: now.addingTimeInterval(30)) == .warmingUp)
    #expect(evaluator.evaluateEvidence(freshBackend, at: now.addingTimeInterval(31)) == .failed(.neverHandshaked))
}

// MARK: - Recovery policy

@Test func pathSettlingCapsContinuousChurnAndRearmsAfterQuiet() {
    var pathPolicy = GatewayTunnelPathPolicy()
    #expect(pathPolicy.availability(at: now) == .unavailable)

    pathPolicy.recordPathChange(isSatisfied: true, at: now)
    #expect(pathPolicy.availability(at: now) == .settling)

    for seconds in stride(from: 5, through: 35, by: 5) {
        pathPolicy.recordPathChange(
            isSatisfied: true,
            at: now.addingTimeInterval(TimeInterval(seconds))
        )
    }

    #expect(pathPolicy.policyGeneration == 6)
    #expect(pathPolicy.recoveryRouteGeneration == 8)
    #expect(pathPolicy.availability(at: now.addingTimeInterval(35)) == .satisfied)

    // Churn after the aggregate cap still invalidates stale callbacks, but it
    // cannot keep resetting the health policy or re-arm another settle window.
    pathPolicy.recordPathChange(isSatisfied: true, at: now.addingTimeInterval(40))
    #expect(pathPolicy.policyGeneration == 6)
    #expect(pathPolicy.recoveryRouteGeneration == 9)
    #expect(pathPolicy.availability(at: now.addingTimeInterval(40)) == .satisfied)

    // Ten quiet seconds close the episode; a later meaningful change gets a
    // fresh settle window and policy generation.
    #expect(pathPolicy.availability(at: now.addingTimeInterval(50)) == .satisfied)
    pathPolicy.recordPathChange(isSatisfied: true, at: now.addingTimeInterval(51))
    #expect(pathPolicy.policyGeneration == 7)
    #expect(pathPolicy.recoveryRouteGeneration == 10)
    #expect(pathPolicy.availability(at: now.addingTimeInterval(51)) == .settling)
}

@Test func unsatisfiedPathIsUnavailableAndStartsNewSettleEpisode() {
    var pathPolicy = GatewayTunnelPathPolicy()
    pathPolicy.recordPathChange(isSatisfied: true, at: now)
    #expect(pathPolicy.availability(at: now.addingTimeInterval(10)) == .satisfied)

    pathPolicy.recordPathChange(isSatisfied: false, at: now.addingTimeInterval(11))
    #expect(pathPolicy.availability(at: now.addingTimeInterval(11)) == .unavailable)

    pathPolicy.recordPathChange(isSatisfied: true, at: now.addingTimeInterval(12))
    #expect(pathPolicy.availability(at: now.addingTimeInterval(12)) == .settling)
}

@Test func pathEventRearmsAfterUnobservedQuietInterval() {
    var pathPolicy = GatewayTunnelPathPolicy()
    pathPolicy.recordPathChange(isSatisfied: true, at: now)

    for seconds in stride(from: 5, through: 35, by: 5) {
        pathPolicy.recordPathChange(
            isSatisfied: true,
            at: now.addingTimeInterval(TimeInterval(seconds))
        )
    }
    #expect(pathPolicy.policyGeneration == 6)

    // No availability poll observes the quiet interval. The next event must
    // still close the capped episode and start a fresh settle window.
    pathPolicy.recordPathChange(isSatisfied: true, at: now.addingTimeInterval(46))
    #expect(pathPolicy.policyGeneration == 7)
    #expect(pathPolicy.availability(at: now.addingTimeInterval(46)) == .settling)
}

@Test func recoveryRequiresTwoFreshFailedAttempts() {
    var policy = GatewayTunnelRecoveryPolicy()
    let initial = stats(handshakeSecondsAgo: 200, rx: 10, tx: 10)
    var action = policy.update(stats: initial, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now)
    #expect(action == GatewayTunnelRecoveryAction(health: .unknown, recoveryRequest: .bindingRefresh))
    policy.recoveryAttemptCompleted(accepted: true, at: now)
    _ = policy.update(stats: initial, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(1))
    action = policy.update(stats: initial, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(10))
    #expect(action == GatewayTunnelRecoveryAction(health: .unknown))

    let second = stats(handshakeSecondsAgo: 210, rx: 10, tx: 20, relativeTo: now.addingTimeInterval(10))
    action = policy.update(stats: second, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(10))
    #expect(action.recoveryRequest == .backendRestart)
    policy.recoveryAttemptCompleted(accepted: true, at: now.addingTimeInterval(10))
    let restartBaseline = stats(handshakeSecondsAgo: nil, rx: 0, tx: 0)
    _ = policy.update(stats: restartBaseline, evidence: .warmingUp, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(11))
    let failedAfterRestart = stats(handshakeSecondsAgo: nil, rx: 0, tx: 30)
    action = policy.update(stats: failedAfterRestart, evidence: .failed(.neverHandshaked), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(20))
    #expect(action.health == .notPassingTraffic)
}

@Test func recoveryEscalatesFromBindingRefreshToOneBackendRestart() {
    var policy = GatewayTunnelRecoveryPolicy()
    let initial = stats(handshakeSecondsAgo: 200, rx: 10, tx: 10)

    var action = policy.update(
        stats: initial,
        evidence: .failed(.staleHandshake),
        path: .satisfied,
        routeGeneration: 1,
        at: now
    )
    #expect(action.recoveryRequest == .bindingRefresh)
    policy.recoveryAttemptCompleted(accepted: true, at: now)

    _ = policy.update(
        stats: initial,
        evidence: .failed(.staleHandshake),
        path: .satisfied,
        routeGeneration: 1,
        at: now.addingTimeInterval(1)
    )
    let failedAfterRefresh = stats(
        handshakeSecondsAgo: 210,
        rx: 10,
        tx: 5_000,
        relativeTo: now.addingTimeInterval(10)
    )
    action = policy.update(
        stats: failedAfterRefresh,
        evidence: .failed(.staleHandshake),
        path: .satisfied,
        routeGeneration: 1,
        at: now.addingTimeInterval(10)
    )
    #expect(action.recoveryRequest == .backendRestart)

    // Polls while the restart is in flight cannot request it again.
    action = policy.update(
        stats: failedAfterRefresh,
        evidence: .failed(.staleHandshake),
        path: .satisfied,
        routeGeneration: 1,
        at: now.addingTimeInterval(15)
    )
    #expect(action.recoveryRequest == nil)
}

@Test func postRestartCounterResetRequiresFreshFailureEvidence() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    var policy = GatewayTunnelRecoveryPolicy()
    let oldSample = stats(handshakeSecondsAgo: 200, rx: 100, tx: 100)

    var evidence = evaluator.evaluateEvidence(oldSample, at: now)
    var action = policy.update(
        stats: oldSample,
        evidence: evidence,
        path: .satisfied,
        routeGeneration: 1,
        at: now
    )
    #expect(action.recoveryRequest == .bindingRefresh)
    policy.recoveryAttemptCompleted(accepted: true, at: now)
    evaluator.resetTrafficEvidence(baseline: oldSample, at: now)

    let refreshBaseline = stats(
        handshakeSecondsAgo: 201,
        rx: 100,
        tx: 100,
        relativeTo: now.addingTimeInterval(1)
    )
    evidence = evaluator.evaluateEvidence(refreshBaseline, at: now.addingTimeInterval(1))
    _ = policy.update(
        stats: refreshBaseline,
        evidence: evidence,
        path: .satisfied,
        routeGeneration: 1,
        at: now.addingTimeInterval(1)
    )
    let failedAfterRefresh = stats(
        handshakeSecondsAgo: 210,
        rx: 100,
        tx: 5_000,
        relativeTo: now.addingTimeInterval(10)
    )
    evidence = evaluator.evaluateEvidence(failedAfterRefresh, at: now.addingTimeInterval(10))
    action = policy.update(
        stats: failedAfterRefresh,
        evidence: evidence,
        path: .satisfied,
        routeGeneration: 1,
        at: now.addingTimeInterval(10)
    )
    #expect(action.recoveryRequest == .backendRestart)
    policy.recoveryAttemptCompleted(accepted: true, at: now.addingTimeInterval(10))
    evaluator.resetSession(at: now.addingTimeInterval(10))

    // The fresh backend's lower counters establish a new session and baseline;
    // they are not recovery and cannot prove failure on their own.
    let restartBaseline = GatewayTunnelRuntimeStats(
        latestHandshakeEpochSeconds: 0,
        rxBytes: 0,
        txBytes: 0
    )
    evidence = evaluator.evaluateEvidence(restartBaseline, at: now.addingTimeInterval(11))
    action = policy.update(
        stats: restartBaseline,
        evidence: evidence,
        path: .satisfied,
        routeGeneration: 1,
        at: now.addingTimeInterval(11)
    )
    #expect(action.health == .unknown)
    #expect(action.recoveryRequest == nil)

    let staticCounters = GatewayTunnelRuntimeStats(
        latestHandshakeEpochSeconds: 0,
        rxBytes: 0,
        txBytes: 0
    )
    evidence = evaluator.evaluateEvidence(staticCounters, at: now.addingTimeInterval(21))
    action = policy.update(
        stats: staticCounters,
        evidence: evidence,
        path: .satisfied,
        routeGeneration: 1,
        at: now.addingTimeInterval(21)
    )
    #expect(action.health == .unknown)

    let freshFailedTraffic = GatewayTunnelRuntimeStats(
        latestHandshakeEpochSeconds: 0,
        rxBytes: 0,
        txBytes: 5_000
    )
    evidence = evaluator.evaluateEvidence(freshFailedTraffic, at: now.addingTimeInterval(26))
    action = policy.update(
        stats: freshFailedTraffic,
        evidence: evidence,
        path: .satisfied,
        routeGeneration: 1,
        at: now.addingTimeInterval(26)
    )
    #expect(action.health == .notPassingTraffic)
    #expect(action.recoveryRequest == nil)
}

@Test func bindingRefreshWithoutCurrentRouteBaselineClearsLatchedEvidence() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    var policy = GatewayTunnelRecoveryPolicy()
    let handshakeEpoch = Int(now.timeIntervalSince1970) - 5

    let initial = GatewayTunnelRuntimeStats(
        latestHandshakeEpochSeconds: handshakeEpoch,
        rxBytes: 100,
        txBytes: 100
    )
    #expect(evaluator.evaluateEvidence(initial, at: now) == .healthy)

    let candidate = GatewayTunnelRuntimeStats(
        latestHandshakeEpochSeconds: handshakeEpoch,
        rxBytes: 100,
        txBytes: 500
    )
    #expect(evaluator.evaluateEvidence(candidate, at: now.addingTimeInterval(1)) == .healthy)

    let latched = GatewayTunnelRuntimeStats(
        latestHandshakeEpochSeconds: handshakeEpoch,
        rxBytes: 100,
        txBytes: 5_000
    )
    let failedEvidence = evaluator.evaluateEvidence(latched, at: now.addingTimeInterval(11))
    #expect(failedEvidence == .failed(.oneWayTraffic))
    #expect(policy.update(stats: latched, evidence: failedEvidence, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(11)).recoveryRequest == .bindingRefresh)
    policy.recoveryAttemptCompleted(accepted: true, at: now.addingTimeInterval(11))

    // A same-episode callback from an old route clears the latch without
    // seeding the new route from the captured pre-route sample.
    evaluator.resetTrafficEvidence(baseline: nil, at: now.addingTimeInterval(11))
    let newRouteBaseline = GatewayTunnelRuntimeStats(
        latestHandshakeEpochSeconds: handshakeEpoch,
        rxBytes: 100,
        txBytes: 10_000
    )
    let baselineEvidence = evaluator.evaluateEvidence(newRouteBaseline, at: now.addingTimeInterval(12))
    _ = policy.update(stats: newRouteBaseline, evidence: baselineEvidence, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(12))

    let subthresholdTraffic = GatewayTunnelRuntimeStats(
        latestHandshakeEpochSeconds: handshakeEpoch,
        rxBytes: 100,
        txBytes: 10_001
    )
    let subthresholdEvidence = evaluator.evaluateEvidence(subthresholdTraffic, at: now.addingTimeInterval(22))
    #expect(subthresholdEvidence == .healthy)
    let action = policy.update(stats: subthresholdTraffic, evidence: subthresholdEvidence, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(22))
    #expect(action.health == .unknown)
    #expect(action.recoveryRequest == nil)
}

@Test func firstPostRestartHandshakeRecoversThroughProbation() {
    var policy = GatewayTunnelRecoveryPolicy()
    let stale = stats(handshakeSecondsAgo: 200, rx: 10, tx: 10)
    _ = policy.update(stats: stale, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now)
    policy.recoveryAttemptCompleted(accepted: true, at: now)
    _ = policy.update(stats: stale, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(1))
    let failedAfterRefresh = stats(handshakeSecondsAgo: 210, rx: 10, tx: 5_000, relativeTo: now.addingTimeInterval(10))
    #expect(policy.update(stats: failedAfterRefresh, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(10)).recoveryRequest == .backendRestart)
    policy.recoveryAttemptCompleted(accepted: true, at: now.addingTimeInterval(10))

    // A handshake already present in the first post-restart sample is real
    // inbound progress from the new backend, not merely a baseline.
    let handshaked = stats(handshakeSecondsAgo: 1, rx: 0, tx: 500, relativeTo: now.addingTimeInterval(11))
    #expect(policy.update(stats: handshaked, evidence: .healthy, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(11)).health == .unknown)
    #expect(policy.update(stats: handshaked, evidence: .healthy, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(15)).health == .passingTraffic)
}

@Test func firstPostRestartReceiveProgressRecoversThroughProbation() {
    var policy = GatewayTunnelRecoveryPolicy()
    let stale = stats(handshakeSecondsAgo: 200, rx: 10, tx: 10)
    _ = policy.update(stats: stale, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now)
    policy.recoveryAttemptCompleted(accepted: true, at: now)
    _ = policy.update(stats: stale, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(1))
    let failedAfterRefresh = stats(handshakeSecondsAgo: 210, rx: 10, tx: 5_000, relativeTo: now.addingTimeInterval(10))
    #expect(policy.update(stats: failedAfterRefresh, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(10)).recoveryRequest == .backendRestart)
    policy.recoveryAttemptCompleted(accepted: true, at: now.addingTimeInterval(10))

    let received = GatewayTunnelRuntimeStats(latestHandshakeEpochSeconds: 0, rxBytes: 100, txBytes: 0)
    #expect(policy.update(stats: received, evidence: .warmingUp, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(11)).health == .unknown)
    let handshaked = stats(handshakeSecondsAgo: 1, rx: 100, tx: 500, relativeTo: now.addingTimeInterval(15))
    #expect(policy.update(stats: handshaked, evidence: .healthy, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(15)).health == .passingTraffic)
}

@Test func failedProbationAfterBindingRefreshEscalatesDirectlyToRestart() {
    var policy = GatewayTunnelRecoveryPolicy()
    let stale = stats(handshakeSecondsAgo: 200, rx: 10, tx: 10)
    #expect(policy.update(stats: stale, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now).recoveryRequest == .bindingRefresh)
    policy.recoveryAttemptCompleted(accepted: true, at: now)
    _ = policy.update(stats: stale, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(1))

    let progressed = stats(handshakeSecondsAgo: 1, rx: 20, tx: 20, relativeTo: now.addingTimeInterval(5))
    #expect(policy.update(stats: progressed, evidence: .healthy, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(5)).health == .unknown)

    let failedAgain = stats(handshakeSecondsAgo: 200, rx: 20, tx: 5_000, relativeTo: now.addingTimeInterval(15))
    var action = policy.update(stats: failedAgain, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(15))
    #expect(action.health == .unknown)
    #expect(action.recoveryRequest == nil)
    action = policy.update(stats: failedAgain, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(20))
    #expect(action.health == .unknown)
    #expect(action.recoveryRequest == .backendRestart)
}

@Test func failedProbationAfterBackendRestartConfirmsWithoutAnotherRestart() {
    var policy = GatewayTunnelRecoveryPolicy()
    let stale = stats(handshakeSecondsAgo: 200, rx: 10, tx: 10)
    _ = policy.update(stats: stale, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now)
    policy.recoveryAttemptCompleted(accepted: true, at: now)
    _ = policy.update(stats: stale, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(1))
    let failedAfterRefresh = stats(handshakeSecondsAgo: 210, rx: 10, tx: 5_000, relativeTo: now.addingTimeInterval(10))
    #expect(policy.update(stats: failedAfterRefresh, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(10)).recoveryRequest == .backendRestart)
    policy.recoveryAttemptCompleted(accepted: true, at: now.addingTimeInterval(10))

    let handshaked = stats(handshakeSecondsAgo: 1, rx: 0, tx: 500, relativeTo: now.addingTimeInterval(11))
    #expect(policy.update(stats: handshaked, evidence: .healthy, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(11)).health == .unknown)

    let resetAgain = GatewayTunnelRuntimeStats(latestHandshakeEpochSeconds: 0, rxBytes: 0, txBytes: 0)
    var action = policy.update(stats: resetAgain, evidence: .warmingUp, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(16))
    #expect(action.health == .unknown)
    #expect(action.recoveryRequest == nil)

    let failedAgain = stats(handshakeSecondsAgo: 200, rx: 0, tx: 5_000, relativeTo: now.addingTimeInterval(21))
    action = policy.update(stats: failedAgain, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(21))
    #expect(action.health == .notPassingTraffic)
    #expect(action.recoveryRequest == nil)
    action = policy.update(stats: failedAgain, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(26))
    #expect(action.health == .notPassingTraffic)
    #expect(action.recoveryRequest == nil)
}

@Test func routeChangeInvalidatesPendingRecoveryCompletion() {
    var policy = GatewayTunnelRecoveryPolicy()
    let stale = stats(handshakeSecondsAgo: 200, rx: 10, tx: 10)
    #expect(policy.update(stats: stale, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now).recoveryRequest == .bindingRefresh)

    policy.invalidatePendingRecoveryAttempt()
    policy.recoveryAttemptCompleted(accepted: true, at: now.addingTimeInterval(1))

    let action = policy.update(stats: stale, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 2, at: now.addingTimeInterval(5))
    #expect(action.recoveryRequest == .bindingRefresh)
}

@Test func failedBackendRestartConfirmsOnlyAfterRuntimeRemainsUnavailable() {
    var policy = GatewayTunnelRecoveryPolicy()
    let stale = stats(handshakeSecondsAgo: 200, rx: 10, tx: 10)
    _ = policy.update(stats: stale, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now)
    policy.recoveryAttemptCompleted(accepted: true, at: now)
    _ = policy.update(stats: stale, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(1))
    let failedAfterRefresh = stats(handshakeSecondsAgo: 210, rx: 10, tx: 5_000, relativeTo: now.addingTimeInterval(10))
    #expect(policy.update(stats: failedAfterRefresh, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(10)).recoveryRequest == .backendRestart)

    policy.recoveryAttemptCompleted(accepted: false, at: now.addingTimeInterval(10))
    #expect(policy.update(stats: nil, evidence: nil, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(29)).health == .unknown)
    #expect(policy.update(stats: nil, evidence: nil, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(30)).health == .notPassingTraffic)
}

@Test func failedBackendRestartThatResumesCannotRequestAnotherRestart() {
    var policy = GatewayTunnelRecoveryPolicy()
    let stale = stats(handshakeSecondsAgo: 200, rx: 10, tx: 10)
    _ = policy.update(stats: stale, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now)
    policy.recoveryAttemptCompleted(accepted: true, at: now)
    _ = policy.update(stats: stale, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(1))
    let failedAfterRefresh = stats(handshakeSecondsAgo: 210, rx: 10, tx: 5_000, relativeTo: now.addingTimeInterval(10))
    #expect(policy.update(stats: failedAfterRefresh, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(10)).recoveryRequest == .backendRestart)

    policy.recoveryAttemptCompleted(accepted: false, at: now.addingTimeInterval(10))
    let resumedBaseline = stats(handshakeSecondsAgo: nil, rx: 0, tx: 0)
    #expect(policy.update(stats: resumedBaseline, evidence: .warmingUp, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(11)).health == .unknown)

    let failedAfterResume = stats(handshakeSecondsAgo: nil, rx: 0, tx: 5_000)
    let action = policy.update(stats: failedAfterResume, evidence: .failed(.neverHandshaked), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(21))
    #expect(action.health == .notPassingTraffic)
    #expect(action.recoveryRequest == nil)
}

@Test func recoveryProgressAndPathLossSuppressConfirmation() {
    var policy = GatewayTunnelRecoveryPolicy()
    let initial = stats(handshakeSecondsAgo: 200, rx: 10, tx: 10)
    _ = policy.update(stats: initial, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now)
    policy.recoveryAttemptCompleted(accepted: true, at: now)
    // First post-refresh sample only establishes the verification baseline.
    let baseline = stats(handshakeSecondsAgo: 1, rx: 20, tx: 20, relativeTo: now.addingTimeInterval(5))
    #expect(policy.update(stats: baseline, evidence: .healthy, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(5)).health == .unknown)
    // Advancing RX is real inbound progress -> enters probation, still not healthy yet.
    let progressing = stats(handshakeSecondsAgo: 1, rx: 40, tx: 20, relativeTo: now.addingTimeInterval(10))
    #expect(policy.update(stats: progressing, evidence: .healthy, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(10)).health == .unknown)
    // A second healthy poll ends probation and publishes recovery.
    let progressingAgain = stats(handshakeSecondsAgo: 1, rx: 60, tx: 20, relativeTo: now.addingTimeInterval(15))
    #expect(policy.update(stats: progressingAgain, evidence: .healthy, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(15)).health == .passingTraffic)

    #expect(policy.update(stats: nil, evidence: nil, path: .unavailable, routeGeneration: 2, at: now.addingTimeInterval(20)).health == .unknown)
}

// Drives the evaluator and policy together exactly as PacketTunnelProvider does:
// evaluate raw evidence, feed the policy, and on an accepted refresh reset the
// traffic window with the current sample as the new baseline.
private func driveRecovery(
    handshakeEpoch: (Date) -> Int,
    rx: (Int) -> UInt64,
    tx: (Int) -> UInt64,
    polls: Int
) -> (confirmed: Bool, passedAfterRefresh: Bool) {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    var policy = GatewayTunnelRecoveryPolicy()
    var confirmed = false
    var passedAfterRefresh = false
    var sawRecoveryRequest = false
    var restartPoll: Int?

    for i in 0..<polls {
        let t = now.addingTimeInterval(Double(i) * 5)
        let sample: GatewayTunnelRuntimeStats
        if let restartPoll, i > restartPoll {
            let postRestartPoll = i - restartPoll - 1
            sample = GatewayTunnelRuntimeStats(
                latestHandshakeEpochSeconds: 0,
                rxBytes: rx(postRestartPoll) - rx(0),
                txBytes: tx(postRestartPoll) - tx(0)
            )
        } else {
            sample = GatewayTunnelRuntimeStats(
                latestHandshakeEpochSeconds: handshakeEpoch(t),
                rxBytes: rx(i),
                txBytes: tx(i)
            )
        }
        let evidence = evaluator.evaluateEvidence(sample, at: t)
        let action = policy.update(stats: sample, evidence: evidence, path: .satisfied, routeGeneration: 1, at: t)
        if action.health == .notPassingTraffic { confirmed = true }
        if action.health == .passingTraffic, sawRecoveryRequest { passedAfterRefresh = true }
        if let request = action.recoveryRequest {
            sawRecoveryRequest = true
            policy.recoveryAttemptCompleted(accepted: true, at: t)
            switch request {
            case .bindingRefresh:
                evaluator.resetTrafficEvidence(baseline: sample, at: t)
            case .backendRestart:
                restartPoll = i
                evaluator.resetSession(at: t)
            }
        }
    }
    return (confirmed, passedAfterRefresh)
}

@Test func restartedPersistentBlackholeConfirmsOnceFromFreshCounters() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    var policy = GatewayTunnelRecoveryPolicy()
    var requests: [GatewayTunnelRecoveryRequest] = []
    var restartPoll: Int?
    var previousHealth: GatewayTunnelHealth?
    var confirmationTransitions = 0
    var confirmedAt: TimeInterval?
    var passedAfterRecoveryRequest = false
    let fixedHandshake = Int(now.timeIntervalSince1970) - 5

    for i in 0..<30 {
        let t = now.addingTimeInterval(Double(i) * 5)
        let sample: GatewayTunnelRuntimeStats
        if let restartPoll, i > restartPoll {
            let postRestartPoll = i - restartPoll - 1
            sample = GatewayTunnelRuntimeStats(
                latestHandshakeEpochSeconds: 0,
                rxBytes: 0,
                txBytes: UInt64(postRestartPoll) * 8_000
            )
        } else {
            sample = GatewayTunnelRuntimeStats(
                latestHandshakeEpochSeconds: fixedHandshake,
                rxBytes: 1_000,
                txBytes: 1_000 + UInt64(i) * 8_000
            )
        }

        let evidence = evaluator.evaluateEvidence(sample, at: t)
        let action = policy.update(
            stats: sample,
            evidence: evidence,
            path: .satisfied,
            routeGeneration: 1,
            at: t
        )
        if action.health == .notPassingTraffic,
           previousHealth != .notPassingTraffic {
            confirmationTransitions += 1
            confirmedAt = t.timeIntervalSince(now)
        }
        if action.health == .passingTraffic, !requests.isEmpty {
            passedAfterRecoveryRequest = true
        }
        previousHealth = action.health

        if let request = action.recoveryRequest {
            requests.append(request)
            policy.recoveryAttemptCompleted(accepted: true, at: t)
            switch request {
            case .bindingRefresh:
                evaluator.resetTrafficEvidence(baseline: sample, at: t)
            case .backendRestart:
                restartPoll = i
                evaluator.resetSession(at: t)
            }
        }
    }

    #expect(requests == [.bindingRefresh, .backendRestart])
    #expect(confirmationTransitions == 1)
    #expect(confirmedAt == 40)
    #expect(!passedAfterRecoveryRequest)
}

@Test func persistentOneWayBlackholeConfirmsAndNeverFalselyPasses() {
    // Fresh handshake that stays fixed (UDP blackholed, so no new handshake
    // completes), RX flat, TX climbing hard. This is the deployment-outage case
    // the notification exists for; it must escalate, not report recovery.
    let fixedHandshake = Int(now.timeIntervalSince1970) - 5
    let result = driveRecovery(
        handshakeEpoch: { _ in fixedHandshake },
        rx: { _ in 1000 },
        tx: { i in 1000 &+ UInt64(i) &* 8000 },
        polls: 24
    )
    #expect(result.confirmed)
    #expect(!result.passedAfterRefresh)
}

@Test func persistentNeverHandshakedConfirmsAndNeverFalselyPasses() {
    // Never-handshaked tunnel with continuing outbound activity must escalate.
    let result = driveRecovery(
        handshakeEpoch: { _ in 0 },
        rx: { _ in 0 },
        tx: { i in 1000 &+ UInt64(i) &* 8000 },
        polls: 24
    )
    #expect(result.confirmed)
    #expect(!result.passedAfterRefresh)
}

@Test func rejectedRefreshReturnsToObservationWhenRuntimeReturns() {
    var policy = GatewayTunnelRecoveryPolicy()
    let failed = stats(handshakeSecondsAgo: 200, rx: 10, tx: 10)
    _ = policy.update(stats: failed, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now)
    policy.recoveryAttemptCompleted(accepted: false, at: now)

    let healthy = stats(handshakeSecondsAgo: 1, rx: 20, tx: 20, relativeTo: now.addingTimeInterval(5))
    #expect(policy.update(stats: healthy, evidence: .healthy, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(5)).health == .unknown)
    #expect(policy.update(stats: healthy, evidence: .healthy, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(10)).health == .passingTraffic)
}

@Test func refreshVerificationBaselineStartsAfterAcceptance() {
    var policy = GatewayTunnelRecoveryPolicy()
    let beforeRequest = stats(handshakeSecondsAgo: 200, rx: 10, tx: 10)
    _ = policy.update(stats: beforeRequest, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now)
    policy.recoveryAttemptCompleted(accepted: true, at: now.addingTimeInterval(5))

    let acceptanceSample = stats(handshakeSecondsAgo: 205, rx: 10, tx: 5_000, relativeTo: now.addingTimeInterval(5))
    #expect(policy.update(stats: acceptanceSample, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(5)).health == .unknown)
    #expect(policy.update(stats: acceptanceSample, evidence: .failed(.staleHandshake), path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(15)).recoveryRequest == nil)
}

@Test func runtimeUnavailableConfirmsOnlyOnSatisfiedPath() {
    var policy = GatewayTunnelRecoveryPolicy()
    #expect(policy.update(stats: nil, evidence: nil, path: .unavailable, routeGeneration: 1, at: now).health == .unknown)
    #expect(policy.update(stats: nil, evidence: nil, path: .satisfied, routeGeneration: 2, at: now).health == .unknown)
    #expect(policy.update(stats: nil, evidence: nil, path: .satisfied, routeGeneration: 2, at: now.addingTimeInterval(20)).health == .notPassingTraffic)
}

@Test func confirmedEpisodeSurvivesPathLossAndNeedsTwoHealthyPolls() {
    var policy = GatewayTunnelRecoveryPolicy(thresholds: .init(runtimeUnavailableDuration: 20))
    _ = policy.update(stats: nil, evidence: nil, path: .satisfied, routeGeneration: 1, at: now)
    #expect(policy.update(stats: nil, evidence: nil, path: .satisfied, routeGeneration: 1, at: now.addingTimeInterval(20)).health == .notPassingTraffic)
    #expect(policy.update(stats: nil, evidence: nil, path: .unavailable, routeGeneration: 2, at: now.addingTimeInterval(25)).health == .notPassingTraffic)

    let healthy = stats(handshakeSecondsAgo: 1, rx: 10, tx: 10, relativeTo: now.addingTimeInterval(30))
    #expect(policy.update(stats: healthy, evidence: .healthy, path: .satisfied, routeGeneration: 3, at: now.addingTimeInterval(30)).health == .notPassingTraffic)
    #expect(policy.update(stats: healthy, evidence: .healthy, path: .satisfied, routeGeneration: 3, at: now.addingTimeInterval(35)).health == .passingTraffic)
}

@Test func oneWayFailureStaysLatchedUntilReceiveResumes() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    _ = evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 5, rx: 1000, tx: 1000), at: now)
    _ = evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 6, rx: 1000, tx: 6000, relativeTo: now.addingTimeInterval(1)), at: now.addingTimeInterval(1))
    #expect(evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 16, rx: 1000, tx: 12000, relativeTo: now.addingTimeInterval(11)), at: now.addingTimeInterval(11)) == .failed(.oneWayTraffic))
    // Continuing flat-RX polls stay failed instead of blinking healthy between windows.
    #expect(evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 21, rx: 1000, tx: 20000, relativeTo: now.addingTimeInterval(16)), at: now.addingTimeInterval(16)) == .failed(.oneWayTraffic))
    #expect(evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 26, rx: 1000, tx: 28000, relativeTo: now.addingTimeInterval(21)), at: now.addingTimeInterval(21)) == .failed(.oneWayTraffic))
    // Real inbound progress clears the latch.
    #expect(evaluator.evaluateEvidence(stats(handshakeSecondsAgo: 31, rx: 2000, tx: 36000, relativeTo: now.addingTimeInterval(26)), at: now.addingTimeInterval(26)) == .healthy)
}

@Test func idleTunnelIsNotFlaggedOneWayDead() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    _ = evaluator.evaluate(stats(handshakeSecondsAgo: 5, rx: 1000, tx: 1000), at: now)
    // rx flat but only tiny tx growth (keepalive noise, < 4096) -> still healthy.
    let sample = stats(handshakeSecondsAgo: 16, rx: 1000, tx: 1100, relativeTo: now.addingTimeInterval(11))
    #expect(evaluator.evaluate(sample, at: now.addingTimeInterval(11)) == .passingTraffic)
}

@Test func resumedReceiveResetsFlatnessClock() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    _ = evaluator.evaluate(stats(handshakeSecondsAgo: 5, rx: 1000, tx: 1000), at: now)
    // rx advances at +6s, resetting the flat baseline.
    _ = evaluator.evaluate(stats(handshakeSecondsAgo: 11, rx: 1500, tx: 6000, relativeTo: now.addingTimeInterval(6)), at: now.addingTimeInterval(6))
    // At +11s only 5s of flatness since the advance -> still healthy despite big tx growth.
    let sample = stats(handshakeSecondsAgo: 16, rx: 1500, tx: 11000, relativeTo: now.addingTimeInterval(11))
    #expect(evaluator.evaluate(sample, at: now.addingTimeInterval(11)) == .passingTraffic)
}

// MARK: - Health store

@Test func healthStoreRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = GatewayTunnelHealthStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(try store.read() == nil)

    let snapshot = GatewayTunnelHealthSnapshot(
        tunnelIdentifier: "client-1",
        health: .notPassingTraffic,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try store.write(snapshot)
    #expect(try store.read() == snapshot)

    try store.clear()
    #expect(try store.read() == nil)
}

@Test func healthSnapshotExpiresAfterExtensionStopsUpdatingIt() {
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = GatewayTunnelHealthSnapshot(
        tunnelIdentifier: "client-1",
        health: .notPassingTraffic,
        updatedAt: updatedAt
    )

    #expect(snapshot.isFresh(at: updatedAt.addingTimeInterval(30)))
    #expect(!snapshot.isFresh(at: updatedAt.addingTimeInterval(31)))
}

@Test func healthPersistencePolicyRetriesAfterUnrecordedWrite() {
    var policy = GatewayTunnelHealthPersistencePolicy(heartbeatInterval: 15)
    let first = now
    #expect(policy.shouldPersist(.passingTraffic, at: first))
    // A failed write does not record the attempt, so the next poll remains due.
    #expect(policy.shouldPersist(.passingTraffic, at: first.addingTimeInterval(5)))
    policy.recordPersisted(.passingTraffic, at: first.addingTimeInterval(5))
    #expect(!policy.shouldPersist(.passingTraffic, at: first.addingTimeInterval(10)))
    #expect(policy.shouldPersist(.passingTraffic, at: first.addingTimeInterval(21)))
}
