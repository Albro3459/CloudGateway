import Foundation
import Testing
@testable import CloudGatewayKit

private struct CoordinatorHarness {
    var session = GatewayTunnelHealthSessionID(rawValue: 1)
    let wallStart = Date(timeIntervalSince1970: 1_700_000_000)
    var coordinator = GatewayTunnelHealthCoordinator()
    var transition = GatewayTunnelHealthTransition(effects: [], health: nil, nextWake: nil)

    mutating func start(
        at seconds: Int = 0,
        session: GatewayTunnelHealthSessionID? = nil
    ) -> GatewayTunnelHealthTransition {
        if let session {
            self.session = session
        }
        transition = coordinator.start(
            session: self.session,
            tunnelIdentifier: "client-1",
            at: moment(seconds)
        )
        return transition
    }

    mutating func path(
        satisfied: Bool,
        routeID: UInt64,
        at seconds: Int
    ) -> GatewayTunnelHealthTransition {
        transition = coordinator.handle(
            .pathChanged(.init(isSatisfied: satisfied, routeID: routeID)),
            at: moment(seconds)
        )
        return transition
    }

    mutating func wake(at seconds: Int) throws -> GatewayTunnelHealthTransition {
        let wake = try #require(transition.nextWake)
        transition = coordinator.handle(.wake(wake.id), at: moment(seconds))
        return transition
    }

    mutating func completeRead(
        _ id: GatewayTunnelHealthOperationID,
        stats: GatewayTunnelRuntimeStats?,
        at seconds: Int
    ) -> GatewayTunnelHealthTransition {
        transition = coordinator.handle(
            .runtimeReadCompleted(id, stats),
            at: moment(seconds)
        )
        return transition
    }

    mutating func completeRecovery(
        _ id: GatewayTunnelHealthOperationID,
        result: GatewayTunnelRecoveryResult,
        at seconds: Int
    ) -> GatewayTunnelHealthTransition {
        transition = coordinator.handle(
            .recoveryCompleted(id, result),
            at: moment(seconds)
        )
        return transition
    }

    mutating func completePersistence(
        _ id: GatewayTunnelHealthOperationID,
        result: GatewayTunnelEffectResult,
        at seconds: Int
    ) -> GatewayTunnelHealthTransition {
        transition = coordinator.handle(
            .persistenceCompleted(id, result),
            at: moment(seconds)
        )
        return transition
    }

    mutating func completeNotification(
        _ id: GatewayTunnelHealthOperationID,
        result: GatewayTunnelNotificationResult,
        at seconds: Int
    ) -> GatewayTunnelHealthTransition {
        transition = coordinator.handle(
            .notificationCompleted(id, result),
            at: moment(seconds)
        )
        return transition
    }

    mutating func stop(at seconds: Int) -> GatewayTunnelHealthTransition {
        transition = coordinator.handle(.stop, at: moment(seconds))
        return transition
    }

    func moment(_ seconds: Int) -> GatewayTunnelHealthMoment {
        GatewayTunnelHealthMoment(
            monotonic: .seconds(seconds),
            wall: wallStart.addingTimeInterval(TimeInterval(seconds))
        )
    }

    func stats(
        at seconds: Int,
        handshakeAge: Int?,
        rx: UInt64,
        tx: UInt64
    ) -> GatewayTunnelRuntimeStats {
        GatewayTunnelRuntimeStats(
            latestHandshakeEpochSeconds: handshakeAge.map {
                Int(moment(seconds).wall.timeIntervalSince1970) - $0
            } ?? 0,
            rxBytes: rx,
            txBytes: tx
        )
    }
}

private func runtimeReadID(
    in transition: GatewayTunnelHealthTransition
) -> GatewayTunnelHealthOperationID? {
    transition.effects.lazy.compactMap { effect in
        guard case let .readRuntime(id) = effect else { return nil }
        return id
    }.first
}

private func recoveryEffect(
    in transition: GatewayTunnelHealthTransition
) -> (GatewayTunnelRecoveryRequest, GatewayTunnelHealthOperationID)? {
    transition.effects.lazy.compactMap { effect in
        switch effect {
        case let .refreshBinding(id):
            return (.bindingRefresh, id)
        case let .restartBackend(id):
            return (.backendRestart, id)
        default:
            return nil
        }
    }.first
}

private func persistenceID(
    in transition: GatewayTunnelHealthTransition
) -> GatewayTunnelHealthOperationID? {
    transition.effects.lazy.compactMap { effect in
        guard case let .persist(id, _) = effect else { return nil }
        return id
    }.first
}

private func notificationID(
    in transition: GatewayTunnelHealthTransition
) -> GatewayTunnelHealthOperationID? {
    transition.effects.lazy.compactMap { effect in
        guard case let .registerNotification(id) = effect else { return nil }
        return id
    }.first
}

private func notificationReconciliationID(
    in transition: GatewayTunnelHealthTransition
) -> GatewayTunnelHealthOperationID? {
    transition.effects.lazy.compactMap { effect in
        guard case let .reconcileNotification(id) = effect else { return nil }
        return id
    }.first
}

private func containsWithdrawal(_ transition: GatewayTunnelHealthTransition) -> Bool {
    transition.effects.contains(.withdrawNotification)
}

private func driveToNotification(
    _ harness: inout CoordinatorHarness,
    from start: Int,
    through end: Int
) throws -> GatewayTunnelHealthOperationID {
    var notification: GatewayTunnelHealthOperationID?
    for seconds in stride(from: start, through: end, by: 5) {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        let transition = harness.completeRead(
            read,
            stats: harness.stats(
                at: seconds,
                handshakeAge: nil,
                rx: 0,
                tx: UInt64(seconds) * 1_000
            ),
            at: seconds
        )
        notification = notification ?? notificationID(in: transition)
        if let recovery = recoveryEffect(in: transition) {
            _ = harness.completeRecovery(recovery.1, result: .accepted, at: seconds)
        }
        if notification != nil { break }
    }
    return try #require(notification)
}

@Test func coordinatorHealthyLifecyclePersistsAndStopsCleanly() throws {
    var harness = CoordinatorHarness()

    let started = harness.start()
    #expect(started.effects == [.withdrawNotification, .clearSnapshot])
    #expect(started.health == nil)
    #expect(started.nextWake?.deadline == .seconds(5))

    _ = harness.path(satisfied: true, routeID: 1, at: 0)
    let firstWake = try harness.wake(at: 5)
    let firstRead = try #require(runtimeReadID(in: firstWake))
    let settling = harness.completeRead(
        firstRead,
        stats: harness.stats(at: 5, handshakeAge: 1, rx: 10, tx: 10),
        at: 5
    )
    #expect(settling.health == .unknown)
    let firstWrite = try #require(persistenceID(in: settling))
    _ = harness.completePersistence(firstWrite, result: .success, at: 5)

    let secondWake = try harness.wake(at: 10)
    let secondRead = try #require(runtimeReadID(in: secondWake))
    let healthy = harness.completeRead(
        secondRead,
        stats: harness.stats(at: 10, handshakeAge: 1, rx: 20, tx: 20),
        at: 10
    )
    #expect(healthy.health == .passingTraffic)
    #expect(persistenceID(in: healthy) != nil)
    #expect(notificationID(in: healthy) == nil)

    let stopped = harness.stop(at: 11)
    #expect(stopped.effects == [.clearSnapshot, .withdrawNotification])
    #expect(stopped.health == nil)
    #expect(stopped.nextWake == nil)
}

@Test func coordinatorAcceptedRecoveryLadderConfirmsAndNotifiesOnce() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    let settlingWake = try harness.wake(at: 5)
    let settlingRead = try #require(runtimeReadID(in: settlingWake))
    _ = harness.completeRead(
        settlingRead,
        stats: harness.stats(at: 5, handshakeAge: nil, rx: 0, tx: 1_000),
        at: 5
    )

    let bindingWake = try harness.wake(at: 10)
    let bindingRead = try #require(runtimeReadID(in: bindingWake))
    let binding = harness.completeRead(
        bindingRead,
        stats: harness.stats(at: 10, handshakeAge: nil, rx: 0, tx: 5_000),
        at: 10
    )
    let bindingRecovery = try #require(recoveryEffect(in: binding))
    #expect(bindingRecovery.0 == .bindingRefresh)
    _ = harness.completeRecovery(bindingRecovery.1, result: .accepted, at: 10)

    let baselineWake = try harness.wake(at: 15)
    let baselineRead = try #require(runtimeReadID(in: baselineWake))
    _ = harness.completeRead(
        baselineRead,
        stats: harness.stats(at: 15, handshakeAge: nil, rx: 0, tx: 10_000),
        at: 15
    )

    let restartWake = try harness.wake(at: 20)
    let restartRead = try #require(runtimeReadID(in: restartWake))
    let restart = harness.completeRead(
        restartRead,
        stats: harness.stats(at: 20, handshakeAge: nil, rx: 0, tx: 15_000),
        at: 20
    )
    let restartRecovery = try #require(recoveryEffect(in: restart))
    #expect(restartRecovery.0 == .backendRestart)
    _ = harness.completeRecovery(restartRecovery.1, result: .accepted, at: 20)

    let restartedBaselineWake = try harness.wake(at: 25)
    let restartedBaselineRead = try #require(runtimeReadID(in: restartedBaselineWake))
    let restartedBaseline = harness.completeRead(
        restartedBaselineRead,
        stats: harness.stats(at: 25, handshakeAge: nil, rx: 0, tx: 5_000),
        at: 25
    )
    #expect(restartedBaseline.health == .unknown)

    let confirmationWake = try harness.wake(at: 30)
    let confirmationRead = try #require(runtimeReadID(in: confirmationWake))
    let confirmed = harness.completeRead(
        confirmationRead,
        stats: harness.stats(at: 30, handshakeAge: nil, rx: 0, tx: 10_000),
        at: 30
    )
    #expect(confirmed.health == .notPassingTraffic)
    let notification = try #require(notificationID(in: confirmed))

    _ = harness.completeNotification(notification, result: .registered, at: 30)
    let repeatedWake = try harness.wake(at: 35)
    let repeatedRead = try #require(runtimeReadID(in: repeatedWake))
    let repeated = harness.completeRead(
        repeatedRead,
        stats: harness.stats(at: 35, handshakeAge: nil, rx: 0, tx: 15_000),
        at: 35
    )
    #expect(repeated.health == .notPassingTraffic)
    #expect(notificationID(in: repeated) == nil)
}

@Test func coordinatorRejectedRecoveryReturnsThroughProbation() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    let settlingWake = try harness.wake(at: 5)
    let settlingRead = try #require(runtimeReadID(in: settlingWake))
    _ = harness.completeRead(
        settlingRead,
        stats: harness.stats(at: 5, handshakeAge: 200, rx: 10, tx: 10),
        at: 5
    )

    let failureWake = try harness.wake(at: 10)
    let failureRead = try #require(runtimeReadID(in: failureWake))
    let failed = harness.completeRead(
        failureRead,
        stats: harness.stats(at: 10, handshakeAge: 200, rx: 10, tx: 20),
        at: 10
    )
    let recovery = try #require(recoveryEffect(in: failed))
    #expect(recovery.0 == .bindingRefresh)
    _ = harness.completeRecovery(recovery.1, result: .rejected, at: 10)

    let firstHealthyWake = try harness.wake(at: 15)
    let firstHealthyRead = try #require(runtimeReadID(in: firstHealthyWake))
    let firstHealthy = harness.completeRead(
        firstHealthyRead,
        stats: harness.stats(at: 15, handshakeAge: 1, rx: 20, tx: 20),
        at: 15
    )
    #expect(firstHealthy.health == .unknown)

    let secondHealthyWake = try harness.wake(at: 20)
    let secondHealthyRead = try #require(runtimeReadID(in: secondHealthyWake))
    let recovered = harness.completeRead(
        secondHealthyRead,
        stats: harness.stats(at: 20, handshakeAge: 1, rx: 30, tx: 20),
        at: 20
    )
    #expect(recovered.health == .passingTraffic)
}

@Test func coordinatorRuntimeUnavailableUsesFullRecoveryLadder() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    var binding: GatewayTunnelHealthOperationID?
    var restart: GatewayTunnelHealthOperationID?
    var confirmed = false

    for seconds in stride(from: 5, through: 80, by: 5) {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        let transition = harness.completeRead(read, stats: nil, at: seconds)
        if let recovery = recoveryEffect(in: transition) {
            switch recovery.0 {
            case .bindingRefresh:
                binding = recovery.1
            case .backendRestart:
                restart = recovery.1
            }
            _ = harness.completeRecovery(recovery.1, result: .accepted, at: seconds)
        }
        if transition.health == .notPassingTraffic {
            confirmed = true
            break
        }
    }

    #expect(binding != nil)
    #expect(restart != nil)
    #expect(confirmed)
}

@Test func coordinatorOneWayBlackholeResetsEvidenceAcrossAcceptedRecoveryLadder() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    var requests: [GatewayTunnelRecoveryRequest] = []
    var firstRequestAt: Int?
    var restartAcceptedAt: Int?
    var confirmedAt: Int?

    for seconds in stride(from: 5, through: 60, by: 5) {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        let sample: GatewayTunnelRuntimeStats
        if let restartAcceptedAt {
            let secondsAfterRestart = seconds - restartAcceptedAt - 5
            sample = harness.stats(
                at: seconds,
                handshakeAge: nil,
                rx: 0,
                tx: UInt64(max(0, secondsAfterRestart)) * 1_600
            )
        } else {
            sample = harness.stats(
                at: seconds,
                handshakeAge: seconds + 5,
                rx: 1_000,
                tx: 1_000 + UInt64(seconds) * 1_600
            )
        }
        let transition = harness.completeRead(
            read,
            stats: sample,
            at: seconds
        )
        if let recovery = recoveryEffect(in: transition) {
            requests.append(recovery.0)
            firstRequestAt = firstRequestAt ?? seconds
            if recovery.0 == .backendRestart {
                restartAcceptedAt = seconds
            }
            _ = harness.completeRecovery(recovery.1, result: .accepted, at: seconds)
        }
        if firstRequestAt != nil {
            #expect(transition.health != .passingTraffic)
        }
        if transition.health == .notPassingTraffic {
            confirmedAt = seconds
            break
        }
    }

    #expect(requests == [.bindingRefresh, .backendRestart])
    #expect(firstRequestAt == 20)
    #expect(confirmedAt == 45)
}

@Test func coordinatorRejectedUnavailableBackendRestartStillConfirms() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    var requests: [GatewayTunnelRecoveryRequest] = []
    var confirmedAt: Int?
    for seconds in stride(from: 5, through: 80, by: 5) {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        let transition = harness.completeRead(read, stats: nil, at: seconds)
        if let recovery = recoveryEffect(in: transition) {
            requests.append(recovery.0)
            _ = harness.completeRecovery(recovery.1, result: .rejected, at: seconds)
        }
        if transition.health == .notPassingTraffic {
            confirmedAt = seconds
            break
        }
    }

    #expect(requests == [.bindingRefresh, .backendRestart])
    #expect(confirmedAt != nil)
}

@Test func coordinatorConfirmedPathChangeRearmsWithoutRenotifying() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    func driveToConfirmation(_ harness: inout CoordinatorHarness) throws {
        for seconds in stride(from: 5, through: 30, by: 5) {
            let wake = try harness.wake(at: seconds)
            let read = try #require(runtimeReadID(in: wake))
            let transition = harness.completeRead(
                read,
                stats: harness.stats(
                    at: seconds,
                    handshakeAge: nil,
                    rx: 0,
                    tx: UInt64(seconds) * 1_000
                ),
                at: seconds
            )
            if let recovery = recoveryEffect(in: transition) {
                _ = harness.completeRecovery(recovery.1, result: .accepted, at: seconds)
            }
        }
    }

    try driveToConfirmation(&harness)
    #expect(harness.transition.health == .notPassingTraffic)
    #expect(notificationID(in: harness.transition) != nil)

    _ = harness.path(satisfied: true, routeID: 2, at: 31)
    let settlingWake = try harness.wake(at: 35)
    let settlingRead = try #require(runtimeReadID(in: settlingWake))
    let settling = harness.completeRead(
        settlingRead,
        stats: harness.stats(at: 35, handshakeAge: nil, rx: 0, tx: 35_000),
        at: 35
    )
    #expect(settling.health == .notPassingTraffic)
    #expect(notificationID(in: settling) == nil)

    let rearmedWake = try harness.wake(at: 45)
    let rearmedRead = try #require(runtimeReadID(in: rearmedWake))
    let rearmed = harness.completeRead(
        rearmedRead,
        stats: harness.stats(at: 45, handshakeAge: nil, rx: 0, tx: 45_000),
        at: 45
    )
    #expect(rearmed.health == .notPassingTraffic)
    #expect(recoveryEffect(in: rearmed)?.0 == .bindingRefresh)
    #expect(notificationID(in: rearmed) == nil)
}

@Test func coordinatorConfirmedRecoveryNeedsTwoHealthyPollsAndWithdraws() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    for seconds in stride(from: 5, through: 30, by: 5) {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        let transition = harness.completeRead(
            read,
            stats: harness.stats(
                at: seconds,
                handshakeAge: nil,
                rx: 0,
                tx: UInt64(seconds) * 1_000
            ),
            at: seconds
        )
        if let recovery = recoveryEffect(in: transition) {
            _ = harness.completeRecovery(recovery.1, result: .accepted, at: seconds)
        }
    }
    #expect(harness.transition.health == .notPassingTraffic)

    let firstWake = try harness.wake(at: 35)
    let firstRead = try #require(runtimeReadID(in: firstWake))
    let firstHealthy = harness.completeRead(
        firstRead,
        stats: harness.stats(at: 35, handshakeAge: 1, rx: 100, tx: 31_000),
        at: 35
    )
    #expect(firstHealthy.health == .notPassingTraffic)
    #expect(!containsWithdrawal(firstHealthy))

    let secondWake = try harness.wake(at: 40)
    let secondRead = try #require(runtimeReadID(in: secondWake))
    let recovered = harness.completeRead(
        secondRead,
        stats: harness.stats(at: 40, handshakeAge: 1, rx: 200, tx: 31_000),
        at: 40
    )
    #expect(recovered.health == .passingTraffic)
    #expect(containsWithdrawal(recovered))
}

@Test func coordinatorPersistenceFailureRemainsDueAndHeartbeatIsBounded() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    let firstWake = try harness.wake(at: 5)
    let firstRead = try #require(runtimeReadID(in: firstWake))
    let first = harness.completeRead(
        firstRead,
        stats: harness.stats(at: 5, handshakeAge: 1, rx: 10, tx: 10),
        at: 5
    )
    let failedWrite = try #require(persistenceID(in: first))
    _ = harness.completePersistence(failedWrite, result: .failure, at: 5)

    let retryWake = try harness.wake(at: 10)
    let retryRead = try #require(runtimeReadID(in: retryWake))
    let retry = harness.completeRead(
        retryRead,
        stats: harness.stats(at: 10, handshakeAge: 1, rx: 20, tx: 20),
        at: 10
    )
    let retryWrite = try #require(persistenceID(in: retry))
    _ = harness.completePersistence(retryWrite, result: .success, at: 10)

    let earlyWake = try harness.wake(at: 15)
    let earlyRead = try #require(runtimeReadID(in: earlyWake))
    let early = harness.completeRead(
        earlyRead,
        stats: harness.stats(at: 15, handshakeAge: 1, rx: 30, tx: 30),
        at: 15
    )
    #expect(persistenceID(in: early) == nil)

    for seconds in [20, 25] {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        let transition = harness.completeRead(
            read,
            stats: harness.stats(
                at: seconds,
                handshakeAge: 1,
                rx: UInt64(seconds * 2),
                tx: UInt64(seconds * 2)
            ),
            at: seconds
        )
        if seconds == 25 {
            #expect(persistenceID(in: transition) != nil)
        }
    }
}

@Test func coordinatorPersistsSupersedingHealthAfterOlderWriteCompletes() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    let firstWake = try harness.wake(at: 5)
    let firstRead = try #require(runtimeReadID(in: firstWake))
    let first = harness.completeRead(
        firstRead,
        stats: harness.stats(at: 5, handshakeAge: 1, rx: 10, tx: 10),
        at: 5
    )
    let firstWrite = try #require(persistenceID(in: first))

    let secondWake = try harness.wake(at: 10)
    let secondRead = try #require(runtimeReadID(in: secondWake))
    let second = harness.completeRead(
        secondRead,
        stats: harness.stats(at: 10, handshakeAge: 1, rx: 20, tx: 20),
        at: 10
    )
    #expect(second.health == .passingTraffic)
    #expect(persistenceID(in: second) == nil)

    let reconciled = harness.completePersistence(firstWrite, result: .success, at: 10)
    let secondWrite = try #require(persistenceID(in: reconciled))
    #expect(secondWrite != firstWrite)
    #expect(reconciled.effects.contains { effect in
        guard case let .persist(_, snapshot) = effect else { return false }
        return snapshot.health == .passingTraffic
    })

    let stale = harness.completePersistence(firstWrite, result: .success, at: 11)
    #expect(stale.effects.isEmpty)
}

@Test func coordinatorReconcilesNotificationRegisteredAfterRecoveryOrStop() throws {
    func driveToConfirmation(
        _ harness: inout CoordinatorHarness,
        startingAt start: Int = 0
    ) throws -> GatewayTunnelHealthOperationID {
        for offset in stride(from: 5, through: 30, by: 5) {
            let seconds = start + offset
            let wake = try harness.wake(at: seconds)
            let read = try #require(runtimeReadID(in: wake))
            let transition = harness.completeRead(
                read,
                stats: harness.stats(
                    at: seconds,
                    handshakeAge: nil,
                    rx: 0,
                    tx: UInt64(seconds) * 1_000
                ),
                at: seconds
            )
            if let recovery = recoveryEffect(in: transition) {
                _ = harness.completeRecovery(recovery.1, result: .accepted, at: seconds)
            }
        }
        return try #require(notificationID(in: harness.transition))
    }

    var recoveredHarness = CoordinatorHarness()
    _ = recoveredHarness.start()
    _ = recoveredHarness.path(satisfied: true, routeID: 1, at: 0)
    let recoveredRegistration = try driveToConfirmation(&recoveredHarness)

    for seconds in [35, 40] {
        let wake = try recoveredHarness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        _ = recoveredHarness.completeRead(
            read,
            stats: recoveredHarness.stats(
                at: seconds,
                handshakeAge: 1,
                rx: UInt64(seconds) * 10,
                tx: 31_000
            ),
            at: seconds
        )
    }
    #expect(recoveredHarness.transition.health == .passingTraffic)
    let lateAfterRecovery = recoveredHarness.completeNotification(
        recoveredRegistration,
        result: .registered,
        at: 41
    )
    #expect(lateAfterRecovery.effects == [.withdrawNotification])

    var stoppedHarness = CoordinatorHarness()
    _ = stoppedHarness.start()
    _ = stoppedHarness.path(satisfied: true, routeID: 1, at: 0)
    let stoppedRegistration = try driveToConfirmation(&stoppedHarness)
    _ = stoppedHarness.stop(at: 31)
    let lateAfterStop = stoppedHarness.completeNotification(
        stoppedRegistration,
        result: .registered,
        at: 32
    )
    #expect(lateAfterStop.effects == [.withdrawNotification])
    #expect(lateAfterStop.health == nil)

    var replacementHarness = CoordinatorHarness()
    _ = replacementHarness.start()
    _ = replacementHarness.path(satisfied: true, routeID: 1, at: 0)
    let priorRegistration = try driveToConfirmation(&replacementHarness)
    _ = replacementHarness.stop(at: 31)
    _ = replacementHarness.start(
        at: 32,
        session: GatewayTunnelHealthSessionID(rawValue: 2)
    )
    _ = replacementHarness.path(satisfied: true, routeID: 2, at: 32)
    _ = try driveToConfirmation(&replacementHarness, startingAt: 32)
    #expect(replacementHarness.transition.health == .notPassingTraffic)

    let lateDuringReplacementOutage = replacementHarness.completeNotification(
        priorRegistration,
        result: .registered,
        at: 63
    )
    #expect(lateDuringReplacementOutage.effects.isEmpty)
    #expect(lateDuringReplacementOutage.health == .notPassingTraffic)
}

@Test func coordinatorIgnoresStaleWakeAndOperationCompletions() throws {
    var harness = CoordinatorHarness()
    let started = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)
    let currentWake = try #require(harness.transition.nextWake)
    let staleWake = GatewayTunnelHealthWakeID(
        session: GatewayTunnelHealthSessionID(rawValue: 99),
        sequence: currentWake.id.sequence
    )
    let ignoredWake = harness.coordinator.handle(.wake(staleWake), at: harness.moment(5))
    #expect(ignoredWake.effects.isEmpty)
    #expect(ignoredWake.nextWake == currentWake)

    harness.transition = started
    _ = harness.path(satisfied: true, routeID: 1, at: 0)
    let wake = try harness.wake(at: 5)
    let read = try #require(runtimeReadID(in: wake))
    let wrongID = GatewayTunnelHealthOperationID(
        session: GatewayTunnelHealthSessionID(rawValue: 2),
        sequence: read.sequence
    )
    let ignoredCompletion = harness.completeRead(
        wrongID,
        stats: harness.stats(at: 5, handshakeAge: 1, rx: 1, tx: 1),
        at: 5
    )
    #expect(ignoredCompletion.effects.isEmpty)

    let accepted = harness.completeRead(
        read,
        stats: harness.stats(at: 5, handshakeAge: 1, rx: 1, tx: 1),
        at: 5
    )
    #expect(accepted.health == .unknown)
    let duplicate = harness.completeRead(
        read,
        stats: harness.stats(at: 5, handshakeAge: 1, rx: 1, tx: 1),
        at: 5
    )
    #expect(duplicate.effects.isEmpty)

    _ = harness.stop(at: 6)
    let afterStop = harness.completeRead(
        read,
        stats: harness.stats(at: 6, handshakeAge: 1, rx: 1, tx: 1),
        at: 6
    )
    #expect(afterStop.effects.isEmpty)
    #expect(afterStop.health == nil)
}

@Test func coordinatorMissingRuntimeCallbackConfirmsAndLateHealthNeedsProbation() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    let wake = try harness.wake(at: 5)
    let stuckRead = try #require(runtimeReadID(in: wake))
    for seconds in [10, 15, 20, 25] {
        let transition = try harness.wake(at: seconds)
        #expect(runtimeReadID(in: transition) == nil)
        #expect(recoveryEffect(in: transition) == nil)
        #expect(transition.health != .notPassingTraffic)
    }

    let timedOut = try harness.wake(at: 30)
    #expect(timedOut.health == .notPassingTraffic)
    #expect(runtimeReadID(in: timedOut) == nil)
    #expect(recoveryEffect(in: timedOut) == nil)

    let lateHealthy = harness.completeRead(
        stuckRead,
        stats: harness.stats(at: 31, handshakeAge: 1, rx: 100, tx: 100),
        at: 31
    )
    #expect(lateHealthy.health == .notPassingTraffic)

    let probationWake = try harness.wake(at: 35)
    let probationRead = try #require(runtimeReadID(in: probationWake))
    let recovered = harness.completeRead(
        probationRead,
        stats: harness.stats(at: 35, handshakeAge: 1, rx: 200, tx: 100),
        at: 35
    )
    #expect(recovered.health == .passingTraffic)
}

@Test func coordinatorOverdueRuntimeCompletionCannotBypassTimeout() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    let firstWake = try harness.wake(at: 5)
    let read = try #require(runtimeReadID(in: firstWake))
    _ = try harness.wake(at: 10)
    let overdue = harness.completeRead(
        read,
        stats: harness.stats(at: 31, handshakeAge: 1, rx: 100, tx: 100),
        at: 31
    )

    #expect(overdue.health == .notPassingTraffic)
    #expect(notificationID(in: overdue) != nil)
}

@Test func coordinatorOverduePathChangeCannotEraseRuntimeTimeout() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    let firstWake = try harness.wake(at: 5)
    let read = try #require(runtimeReadID(in: firstWake))
    _ = try harness.wake(at: 10)
    let overduePath = harness.path(satisfied: true, routeID: 2, at: 31)
    #expect(overduePath.health == .notPassingTraffic)

    let lateHealthy = harness.completeRead(
        read,
        stats: harness.stats(at: 32, handshakeAge: 1, rx: 100, tx: 100),
        at: 32
    )
    #expect(lateHealthy.health == .notPassingTraffic)
}

@Test func coordinatorPathLossRebasesOutstandingReadToFreshStableDeadline() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    let firstWake = try harness.wake(at: 5)
    let firstRead = try #require(runtimeReadID(in: firstWake))
    _ = harness.completeRead(
        firstRead,
        stats: harness.stats(at: 5, handshakeAge: 1, rx: 1, tx: 1),
        at: 5
    )
    let secondWake = try harness.wake(at: 10)
    #expect(runtimeReadID(in: secondWake) != nil)

    _ = harness.path(satisfied: false, routeID: 2, at: 11)
    _ = try harness.wake(at: 15)
    _ = harness.path(satisfied: true, routeID: 3, at: 20)
    for seconds in [20, 25, 30, 35, 40, 45] {
        let transition = try harness.wake(at: seconds)
        #expect(transition.health != .notPassingTraffic)
        #expect(runtimeReadID(in: transition) == nil)
    }

    let timedOut = try harness.wake(at: 50)
    #expect(timedOut.health == .notPassingTraffic)
}

@Test func coordinatorMissingRecoveryCallbackConfirmsWithoutQueueingBehindIt() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    let firstWake = try harness.wake(at: 5)
    let firstRead = try #require(runtimeReadID(in: firstWake))
    _ = harness.completeRead(
        firstRead,
        stats: harness.stats(at: 5, handshakeAge: nil, rx: 0, tx: 1_000),
        at: 5
    )
    let secondWake = try harness.wake(at: 10)
    let secondRead = try #require(runtimeReadID(in: secondWake))
    let requested = harness.completeRead(
        secondRead,
        stats: harness.stats(at: 10, handshakeAge: nil, rx: 0, tx: 5_000),
        at: 10
    )
    let recovery = try #require(recoveryEffect(in: requested))

    for seconds in [15, 20, 25] {
        let transition = try harness.wake(at: seconds)
        #expect(runtimeReadID(in: transition) == nil)
        #expect(recoveryEffect(in: transition) == nil)
    }
    let timedOut = try harness.wake(at: 30)
    #expect(timedOut.health == .notPassingTraffic)
    #expect(runtimeReadID(in: timedOut) == nil)

    let late = harness.completeRecovery(
        recovery.1,
        result: .accepted,
        at: 31
    )
    #expect(late.health == .notPassingTraffic)
    #expect(late.effects.isEmpty)
}

@Test func coordinatorOverdueRecoveryCompletionCannotBypassTimeout() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    let firstWake = try harness.wake(at: 5)
    let firstRead = try #require(runtimeReadID(in: firstWake))
    _ = harness.completeRead(
        firstRead,
        stats: harness.stats(at: 5, handshakeAge: nil, rx: 0, tx: 1_000),
        at: 5
    )
    let secondWake = try harness.wake(at: 10)
    let secondRead = try #require(runtimeReadID(in: secondWake))
    let requested = harness.completeRead(
        secondRead,
        stats: harness.stats(at: 10, handshakeAge: nil, rx: 0, tx: 5_000),
        at: 10
    )
    let recovery = try #require(recoveryEffect(in: requested))

    let overdue = harness.completeRecovery(recovery.1, result: .accepted, at: 31)
    #expect(overdue.health == .notPassingTraffic)
    #expect(notificationID(in: overdue) != nil)
}

@Test func coordinatorPathChangeDuringRecoveryDoesNotAdvanceNewRouteLadder() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    let firstWake = try harness.wake(at: 5)
    let firstRead = try #require(runtimeReadID(in: firstWake))
    _ = harness.completeRead(
        firstRead,
        stats: harness.stats(at: 5, handshakeAge: nil, rx: 0, tx: 1_000),
        at: 5
    )
    let secondWake = try harness.wake(at: 10)
    let secondRead = try #require(runtimeReadID(in: secondWake))
    let requested = harness.completeRead(
        secondRead,
        stats: harness.stats(at: 10, handshakeAge: nil, rx: 0, tx: 5_000),
        at: 10
    )
    let oldRouteRecovery = try #require(recoveryEffect(in: requested))
    #expect(oldRouteRecovery.0 == .bindingRefresh)

    _ = harness.path(satisfied: true, routeID: 2, at: 11)
    let staleCompletion = harness.completeRecovery(
        oldRouteRecovery.1,
        result: .accepted,
        at: 12
    )
    #expect(staleCompletion.health == .unknown)
    #expect(staleCompletion.effects.isEmpty)

    for seconds in [15, 20] {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        let settling = harness.completeRead(
            read,
            stats: harness.stats(
                at: seconds,
                handshakeAge: nil,
                rx: 0,
                tx: UInt64(seconds) * 1_000
            ),
            at: seconds
        )
        #expect(recoveryEffect(in: settling) == nil)
    }
    _ = try harness.wake(at: 21)

    let newRouteWake = try harness.wake(at: 25)
    let newRouteRead = try #require(runtimeReadID(in: newRouteWake))
    let newRoute = harness.completeRead(
        newRouteRead,
        stats: harness.stats(at: 25, handshakeAge: nil, rx: 0, tx: 25_000),
        at: 25
    )
    #expect(recoveryEffect(in: newRoute)?.0 == .bindingRefresh)
}

@Test func coordinatorMissingNotificationCallbackReconcilesBeforeRetrying() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)
    var registration: GatewayTunnelHealthOperationID?

    for seconds in stride(from: 5, through: 30, by: 5) {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        let transition = harness.completeRead(
            read,
            stats: harness.stats(
                at: seconds,
                handshakeAge: nil,
                rx: 0,
                tx: UInt64(seconds) * 1_000
            ),
            at: seconds
        )
        registration = registration ?? notificationID(in: transition)
        if let recovery = recoveryEffect(in: transition) {
            _ = harness.completeRecovery(recovery.1, result: .accepted, at: seconds)
        }
    }
    _ = try #require(registration)

    _ = try harness.wake(at: 35)
    let reconciliation = try harness.wake(at: 40)
    let reconciliationID = try #require(notificationReconciliationID(in: reconciliation))
    #expect(notificationID(in: reconciliation) == nil)

    _ = harness.completeNotification(reconciliationID, result: .absent, at: 40)
    let retry = try harness.wake(at: 45)
    #expect(notificationID(in: retry) != nil)
}

@Test func coordinatorLateTerminalRegistrationCancelsAmbiguousRetry() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)
    let registration = try driveToNotification(&harness, from: 5, through: 35)

    _ = try harness.wake(at: 35)
    let reconciliation = try harness.wake(at: 40)
    let reconciliationID = try #require(notificationReconciliationID(in: reconciliation))
    _ = harness.completeNotification(
        registration,
        result: .terminalFailure,
        at: 41
    )
    _ = harness.completeNotification(reconciliationID, result: .absent, at: 42)

    for seconds in [45, 50, 55, 60] {
        let transition = try harness.wake(at: seconds)
        #expect(notificationID(in: transition) == nil)
        #expect(notificationReconciliationID(in: transition) == nil)
    }
}

@Test func coordinatorMissingNotificationReconciliationRetriesReconciliation() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)

    for seconds in stride(from: 5, through: 30, by: 5) {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        let transition = harness.completeRead(
            read,
            stats: harness.stats(
                at: seconds,
                handshakeAge: nil,
                rx: 0,
                tx: UInt64(seconds) * 1_000
            ),
            at: seconds
        )
        if let recovery = recoveryEffect(in: transition) {
            _ = harness.completeRecovery(recovery.1, result: .accepted, at: seconds)
        }
    }
    _ = try #require(notificationID(in: harness.transition))

    _ = try harness.wake(at: 35)
    let firstReconciliation = try harness.wake(at: 40)
    #expect(notificationReconciliationID(in: firstReconciliation) != nil)
    _ = try harness.wake(at: 45)
    _ = try harness.wake(at: 50)
    let retry = try harness.wake(at: 55)
    #expect(notificationReconciliationID(in: retry) != nil)
    #expect(notificationID(in: retry) == nil)
}

@Test func coordinatorRetryableNotificationFailureRetriesRegistration() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)
    var notification: GatewayTunnelHealthOperationID?

    for seconds in stride(from: 5, through: 30, by: 5) {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        let transition = harness.completeRead(
            read,
            stats: harness.stats(
                at: seconds,
                handshakeAge: nil,
                rx: 0,
                tx: UInt64(seconds) * 1_000
            ),
            at: seconds
        )
        notification = notification ?? notificationID(in: transition)
        if let recovery = recoveryEffect(in: transition) {
            _ = harness.completeRecovery(recovery.1, result: .accepted, at: seconds)
        }
    }
    let failed = try #require(notification)
    _ = harness.completeNotification(failed, result: .retryableFailure, at: 30)

    let retry = try harness.wake(at: 35)
    let retried = try #require(notificationID(in: retry))
    #expect(retried != failed)
}

@Test func coordinatorTerminalNotificationFailureDoesNotRetry() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)
    var notification: GatewayTunnelHealthOperationID?

    for seconds in stride(from: 5, through: 30, by: 5) {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        let transition = harness.completeRead(
            read,
            stats: harness.stats(
                at: seconds,
                handshakeAge: nil,
                rx: 0,
                tx: UInt64(seconds) * 1_000
            ),
            at: seconds
        )
        notification = notification ?? notificationID(in: transition)
        if let recovery = recoveryEffect(in: transition) {
            _ = harness.completeRecovery(recovery.1, result: .accepted, at: seconds)
        }
    }
    let id = try #require(notification)
    _ = harness.completeNotification(id, result: .terminalFailure, at: 30)
    for seconds in [35, 40, 45, 50] {
        let transition = try harness.wake(at: seconds)
        #expect(notificationID(in: transition) == nil)
        #expect(notificationReconciliationID(in: transition) == nil)
    }
}

@Test func coordinatorTerminalNotificationFailureRemainsTerminalAfterRecovery() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)
    let firstNotification = try driveToNotification(&harness, from: 5, through: 35)
    _ = harness.completeNotification(
        firstNotification,
        result: .terminalFailure,
        at: 30
    )

    for seconds in [35, 40] {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        _ = harness.completeRead(
            read,
            stats: harness.stats(
                at: seconds,
                handshakeAge: 1,
                rx: UInt64(seconds) * 10,
                tx: 31_000
            ),
            at: seconds
        )
    }
    #expect(harness.transition.health == .passingTraffic)

    for seconds in stride(from: 45, through: 80, by: 5) {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        let transition = harness.completeRead(
            read,
            stats: harness.stats(
                at: seconds,
                handshakeAge: nil,
                rx: 0,
                tx: UInt64(seconds) * 1_000
            ),
            at: seconds
        )
        #expect(notificationID(in: transition) == nil)
        #expect(notificationReconciliationID(in: transition) == nil)
        if let recovery = recoveryEffect(in: transition) {
            _ = harness.completeRecovery(recovery.1, result: .accepted, at: seconds)
        }
    }
    #expect(harness.transition.health == .notPassingTraffic)
}

@Test func coordinatorReconcilesMultipleCancelledRegistrationsOutOfOrder() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)
    let firstNotification = try driveToNotification(&harness, from: 5, through: 35)

    for seconds in [35, 40] {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        _ = harness.completeRead(
            read,
            stats: harness.stats(
                at: seconds,
                handshakeAge: 1,
                rx: UInt64(seconds) * 10,
                tx: 31_000
            ),
            at: seconds
        )
    }
    let secondNotification = try driveToNotification(&harness, from: 45, through: 80)

    for seconds in [85, 90] {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        _ = harness.completeRead(
            read,
            stats: harness.stats(
                at: seconds,
                handshakeAge: 1,
                rx: UInt64(seconds) * 10,
                tx: 81_000
            ),
            at: seconds
        )
    }
    #expect(harness.transition.health == .passingTraffic)

    let lateFirst = harness.completeNotification(
        firstNotification,
        result: .registered,
        at: 91
    )
    #expect(lateFirst.effects == [.withdrawNotification])
    let lateSecond = harness.completeNotification(
        secondNotification,
        result: .registered,
        at: 92
    )
    #expect(lateSecond.effects == [.withdrawNotification])
}

@Test func coordinatorOlderRegisteredNotificationSatisfiesNewerOutage() throws {
    var harness = CoordinatorHarness()
    _ = harness.start()
    _ = harness.path(satisfied: true, routeID: 1, at: 0)
    let firstNotification = try driveToNotification(&harness, from: 5, through: 35)

    for seconds in [35, 40] {
        let wake = try harness.wake(at: seconds)
        let read = try #require(runtimeReadID(in: wake))
        _ = harness.completeRead(
            read,
            stats: harness.stats(
                at: seconds,
                handshakeAge: 1,
                rx: UInt64(seconds) * 10,
                tx: 31_000
            ),
            at: seconds
        )
    }
    let secondNotification = try driveToNotification(
        &harness,
        from: 45,
        through: 80
    )
    #expect(harness.transition.health == .notPassingTraffic)

    let olderSuccess = harness.completeNotification(
        firstNotification,
        result: .registered,
        at: 81
    )
    #expect(olderSuccess.effects.isEmpty)
    #expect(harness.coordinator.desiredArtifacts.notificationOperationID == nil)

    let supersededSuccess = harness.completeNotification(
        secondNotification,
        result: .registered,
        at: 82
    )
    #expect(supersededSuccess.effects.isEmpty)
}
