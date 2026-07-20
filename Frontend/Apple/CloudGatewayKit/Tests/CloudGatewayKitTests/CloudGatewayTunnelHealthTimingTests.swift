import Foundation
import Testing
@testable import CloudGatewayKit

private let timingWall = Date(timeIntervalSince1970: 1_700_000_000)

private func timingMoment(_ monotonic: Int, wallOffset: TimeInterval) -> CloudGatewayTunnelHealthMoment {
    CloudGatewayTunnelHealthMoment(
        monotonic: .seconds(monotonic),
        wall: timingWall.addingTimeInterval(wallOffset)
    )
}

@Test func productionTunnelHealthTimingRetainsTheFrozenContract() {
    let timing = CloudGatewayTunnelHealthTiming.production

    #expect(timing.runtimePollInterval == .seconds(5))
    #expect(timing.runtimeReadDeadline == .seconds(20))
    #expect(timing.neverHandshakeGrace == .seconds(10))
    #expect(timing.staleHandshake == .seconds(180))
    #expect(timing.oneWayFlatDuration == .seconds(10))
    #expect(timing.runtimeUnavailableDuration == .seconds(20))
    #expect(timing.pathQuietPeriod == .seconds(10))
    #expect(timing.pathSettlingCap == .seconds(30))
    #expect(timing.recoveryVerificationDuration == .seconds(10))
    #expect(timing.recoveryOperationDeadline == .seconds(20))
    #expect(timing.healthyPollsToRecover == 2)
    #expect(timing.persistenceHeartbeat == .seconds(15))
    #expect(timing.snapshotFreshness == .seconds(30))
    #expect(timing.snapshotFutureTolerance == .seconds(5))
    #expect(timing.notificationOperationDeadline == .seconds(10))
    #expect(timing.notificationInitialRetryDelay == .seconds(5))
    #expect(timing.notificationMaximumRetryDelay == .seconds(60))
    #expect(timing.persistenceHeartbeat < timing.snapshotFreshness)
}

@Test func evaluatorElapsedDeadlinesIgnoreWallClockJumps() {
    var evaluator = CloudGatewayTunnelHealthEvaluator(
        startedAt: timingMoment(0, wallOffset: 0)
    )
    let neverHandshaked = CloudGatewayTunnelRuntimeStats(
        latestHandshakeEpochSeconds: 0,
        rxBytes: 0,
        txBytes: 0
    )

    #expect(evaluator.evaluateEvidence(
        neverHandshaked,
        at: timingMoment(9, wallOffset: 10_000)
    ) == .warmingUp)
    #expect(evaluator.evaluateEvidence(
        neverHandshaked,
        at: timingMoment(10, wallOffset: -10_000)
    ) == .failed(.neverHandshaked))
}

@Test func oneWayWindowUsesMonotonicTimeWhileHandshakeAgeUsesWallTime() {
    var evaluator = CloudGatewayTunnelHealthEvaluator(
        startedAt: timingMoment(0, wallOffset: 0)
    )
    let handshakeEpoch = Int(timingWall.timeIntervalSince1970) - 5

    _ = evaluator.evaluateEvidence(
        .init(latestHandshakeEpochSeconds: handshakeEpoch, rxBytes: 1, txBytes: 1),
        at: timingMoment(0, wallOffset: 0)
    )
    _ = evaluator.evaluateEvidence(
        .init(latestHandshakeEpochSeconds: handshakeEpoch, rxBytes: 1, txBytes: 5_000),
        at: timingMoment(1, wallOffset: 100)
    )
    #expect(evaluator.evaluateEvidence(
        .init(latestHandshakeEpochSeconds: handshakeEpoch, rxBytes: 1, txBytes: 10_000),
        at: timingMoment(10, wallOffset: -100)
    ) == .healthy)
    #expect(evaluator.evaluateEvidence(
        .init(latestHandshakeEpochSeconds: handshakeEpoch, rxBytes: 1, txBytes: 15_000),
        at: timingMoment(11, wallOffset: 0)
    ) == .failed(.oneWayTraffic))

    var staleEvaluator = CloudGatewayTunnelHealthEvaluator(
        startedAt: timingMoment(0, wallOffset: 0)
    )
    #expect(staleEvaluator.evaluateEvidence(
        .init(latestHandshakeEpochSeconds: handshakeEpoch, rxBytes: 1, txBytes: 1),
        at: timingMoment(1, wallOffset: 181)
    ) == .failed(.staleHandshake))
}

@Test func recoveryPathAndPersistenceDeadlinesUseMonotonicTime() {
    var recovery = CloudGatewayTunnelRecoveryPolicy()
    _ = recovery.update(
        stats: nil,
        evidence: nil,
        path: .satisfied,
        routeGeneration: 1,
        at: .zero
    )
    #expect(recovery.update(
        stats: nil,
        evidence: nil,
        path: .satisfied,
        routeGeneration: 1,
        at: .seconds(19)
    ).recoveryRequest == nil)
    #expect(recovery.update(
        stats: nil,
        evidence: nil,
        path: .satisfied,
        routeGeneration: 1,
        at: .seconds(20)
    ).recoveryRequest == .bindingRefresh)

    var path = CloudGatewayTunnelPathPolicy()
    path.recordPathChange(isSatisfied: true, at: .zero)
    #expect(path.availability(at: .seconds(9)) == .settling)
    #expect(path.availability(at: .seconds(10)) == .satisfied)

    var persistence = CloudGatewayTunnelHealthPersistencePolicy()
    persistence.recordPersisted(.passingTraffic, at: .zero)
    #expect(!persistence.shouldPersist(.passingTraffic, at: .seconds(14)))
    #expect(persistence.shouldPersist(.passingTraffic, at: .seconds(15)))
}

@Test func snapshotFreshnessBoundsFutureDatesAndAcceptsCorrectingHeartbeat() {
    let snapshot = CloudGatewayTunnelHealthSnapshot(
        tunnelIdentifier: "client-1",
        health: .notPassingTraffic,
        updatedAt: timingWall
    )

    #expect(snapshot.isFresh(at: timingWall.addingTimeInterval(30)))
    #expect(!snapshot.isFresh(at: timingWall.addingTimeInterval(30.001)))
    #expect(snapshot.isFresh(at: timingWall.addingTimeInterval(-5)))
    #expect(!snapshot.isFresh(at: timingWall.addingTimeInterval(-5.001)))
    #expect(!snapshot.isFresh(at: timingWall.addingTimeInterval(-100)))

    let corrected = CloudGatewayTunnelHealthSnapshot(
        tunnelIdentifier: "client-1",
        health: .notPassingTraffic,
        updatedAt: timingWall.addingTimeInterval(-100)
    )
    #expect(corrected.isFresh(at: corrected.updatedAt))
}
