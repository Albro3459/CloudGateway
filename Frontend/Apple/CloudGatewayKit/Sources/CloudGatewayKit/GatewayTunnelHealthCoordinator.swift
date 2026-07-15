import Foundation

struct GatewayTunnelHealthSessionID: Hashable, Sendable {
    let rawValue: UInt64
}

struct GatewayTunnelHealthWakeID: Hashable, Sendable {
    let session: GatewayTunnelHealthSessionID
    let sequence: UInt64
}

struct GatewayTunnelHealthOperationID: Hashable, Sendable {
    let session: GatewayTunnelHealthSessionID
    let sequence: UInt64
}

public struct GatewayTunnelHealthMoment: Equatable, Sendable {
    public let monotonic: Duration
    public let wall: Date

    public init(monotonic: Duration, wall: Date) {
        self.monotonic = monotonic
        self.wall = wall
    }
}

struct GatewayTunnelPathDescriptor: Equatable, Sendable {
    let isSatisfied: Bool
    let routeID: UInt64
}

enum GatewayTunnelEffectResult: Equatable, Sendable {
    case success
    case failure
}

enum GatewayTunnelRecoveryResult: Equatable, Sendable {
    case accepted
    case rejected
    case unsupported
}

enum GatewayTunnelNotificationResult: Equatable, Sendable {
    case registered
    case failed
}

enum GatewayTunnelHealthEvent: Equatable, Sendable {
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

enum GatewayTunnelHealthEffect: Equatable, Sendable {
    case readRuntime(GatewayTunnelHealthOperationID)
    case refreshBinding(GatewayTunnelHealthOperationID)
    case restartBackend(GatewayTunnelHealthOperationID)
    case persist(
        GatewayTunnelHealthOperationID,
        GatewayTunnelHealthSnapshot
    )
    case clearSnapshot
    case registerNotification(GatewayTunnelHealthOperationID)
    case withdrawNotification
}

struct GatewayTunnelHealthWake: Equatable, Sendable {
    let id: GatewayTunnelHealthWakeID
    let deadline: Duration
}

struct GatewayTunnelHealthTransition: Equatable, Sendable {
    let effects: [GatewayTunnelHealthEffect]
    let health: GatewayTunnelHealth?
    let nextWake: GatewayTunnelHealthWake?
}

struct GatewayTunnelHealthCoordinator: Sendable {
    private enum PhysicalOperation: Sendable {
        case runtimeRead(
            id: GatewayTunnelHealthOperationID,
            deadline: Duration
        )
        case recovery(
            id: GatewayTunnelHealthOperationID,
            request: GatewayTunnelRecoveryRequest,
            baseline: GatewayTunnelRuntimeStats?,
            recoveryRouteGeneration: UInt64,
            policyGeneration: UInt64,
            deadline: Duration
        )

        var id: GatewayTunnelHealthOperationID {
            switch self {
            case let .runtimeRead(id, _), let .recovery(id, _, _, _, _, _):
                id
            }
        }
    }

    private struct PendingPersistence: Sendable {
        let id: GatewayTunnelHealthOperationID
        let snapshot: GatewayTunnelHealthSnapshot
        let requestedAt: Duration
    }

    private let timing: GatewayTunnelHealthTiming
    private var activeSession: GatewayTunnelHealthSessionID?
    private var tunnelIdentifier: String?
    private var nextSequence: UInt64 = 0
    private var currentWake: GatewayTunnelHealthWake?
    private var evaluator: GatewayTunnelHealthEvaluator?
    private var recoveryPolicy = GatewayTunnelRecoveryPolicy()
    private var pathPolicy = GatewayTunnelPathPolicy()
    private var persistencePolicy = GatewayTunnelHealthPersistencePolicy()
    private var lastPathDescriptor: GatewayTunnelPathDescriptor?
    private var lastPublishedHealth: GatewayTunnelHealth?
    private var desiredSnapshot: GatewayTunnelHealthSnapshot?
    private var physicalOperation: PhysicalOperation?
    private var pendingPersistence: PendingPersistence?
    private var outstandingNotificationRegistrations: Set<GatewayTunnelHealthOperationID> = []
    private var notificationDesired = false
    private var notificationRegistered = false

    init(timing: GatewayTunnelHealthTiming = .production) {
        self.timing = timing
    }

    mutating func start(
        session: GatewayTunnelHealthSessionID,
        tunnelIdentifier: String,
        at moment: GatewayTunnelHealthMoment
    ) -> GatewayTunnelHealthTransition {
        activeSession = session
        self.tunnelIdentifier = tunnelIdentifier
        nextSequence = 0
        evaluator = GatewayTunnelHealthEvaluator(startedAt: moment, timing: timing)
        recoveryPolicy = GatewayTunnelRecoveryPolicy(timing: timing)
        pathPolicy = GatewayTunnelPathPolicy(timing: timing)
        persistencePolicy = GatewayTunnelHealthPersistencePolicy(timing: timing)
        lastPathDescriptor = nil
        lastPublishedHealth = nil
        desiredSnapshot = nil
        physicalOperation = nil
        pendingPersistence = nil
        notificationDesired = false
        notificationRegistered = false
        currentWake = makeWake(deadline: moment.monotonic + timing.runtimePollInterval)
        return transition(effects: [.withdrawNotification, .clearSnapshot])
    }

    mutating func handle(
        _ event: GatewayTunnelHealthEvent,
        at moment: GatewayTunnelHealthMoment
    ) -> GatewayTunnelHealthTransition {
        if case let .notificationCompleted(id, result) = event {
            return handleNotificationCompleted(id, result: result)
        }
        guard activeSession != nil else {
            return transition()
        }

        switch event {
        case let .wake(id):
            return handleWake(id, at: moment)
        case let .pathChanged(descriptor):
            return handlePathChange(descriptor, at: moment)
        case let .runtimeReadCompleted(id, stats):
            return handleRuntimeReadCompleted(id, stats: stats, at: moment)
        case let .recoveryCompleted(id, result):
            return handleRecoveryCompleted(id, result: result, at: moment)
        case let .persistenceCompleted(id, result):
            return handlePersistenceCompleted(id, result: result, at: moment)
        case .notificationCompleted:
            return transition()
        case .stop:
            return stop()
        }
    }

    private mutating func handleWake(
        _ id: GatewayTunnelHealthWakeID,
        at moment: GatewayTunnelHealthMoment
    ) -> GatewayTunnelHealthTransition {
        guard currentWake?.id == id else {
            return transition()
        }
        currentWake = makeWake(deadline: moment.monotonic + timing.runtimePollInterval)
        guard physicalOperation == nil else {
            return transition()
        }
        let operationID = makeOperationID()
        physicalOperation = .runtimeRead(
            id: operationID,
            deadline: moment.monotonic + timing.runtimeReadDeadline
        )
        return transition(effects: [.readRuntime(operationID)])
    }

    private mutating func handlePathChange(
        _ descriptor: GatewayTunnelPathDescriptor,
        at moment: GatewayTunnelHealthMoment
    ) -> GatewayTunnelHealthTransition {
        guard descriptor != lastPathDescriptor else {
            return transition()
        }
        lastPathDescriptor = descriptor
        pathPolicy.recordPathChange(isSatisfied: descriptor.isSatisfied, at: moment.monotonic)
        return transition()
    }

    private mutating func handleRuntimeReadCompleted(
        _ id: GatewayTunnelHealthOperationID,
        stats: GatewayTunnelRuntimeStats?,
        at moment: GatewayTunnelHealthMoment
    ) -> GatewayTunnelHealthTransition {
        guard case let .runtimeRead(operationID, _) = physicalOperation,
              operationID == id else {
            return transition()
        }
        physicalOperation = nil

        var evidence: GatewayTunnelHealthEvidence?
        if let stats, var evaluator {
            evidence = evaluator.evaluateEvidence(stats, at: moment)
            self.evaluator = evaluator
        }
        let action = recoveryPolicy.update(
            stats: stats,
            evidence: evidence,
            path: pathPolicy.availability(at: moment.monotonic),
            routeGeneration: pathPolicy.policyGeneration,
            at: moment.monotonic
        )

        var effects = publish(action.health, at: moment)
        if let request = action.recoveryRequest {
            let operationID = makeOperationID()
            physicalOperation = .recovery(
                id: operationID,
                request: request,
                baseline: stats,
                recoveryRouteGeneration: pathPolicy.recoveryRouteGeneration,
                policyGeneration: pathPolicy.policyGeneration,
                deadline: moment.monotonic + timing.recoveryOperationDeadline
            )
            switch request {
            case .bindingRefresh:
                effects.append(.refreshBinding(operationID))
            case .backendRestart:
                effects.append(.restartBackend(operationID))
            }
        }
        return transition(effects: effects)
    }

    private mutating func handleRecoveryCompleted(
        _ id: GatewayTunnelHealthOperationID,
        result: GatewayTunnelRecoveryResult,
        at moment: GatewayTunnelHealthMoment
    ) -> GatewayTunnelHealthTransition {
        guard case let .recovery(
            operationID,
            request,
            baseline,
            recoveryRouteGeneration,
            policyGeneration,
            _
        ) = physicalOperation,
              operationID == id else {
            return transition()
        }
        physicalOperation = nil
        let accepted = result == .accepted
        let routeMatches = recoveryRouteGeneration == pathPolicy.recoveryRouteGeneration

        if accepted, request == .backendRestart {
            evaluator?.resetSession(at: moment)
        }
        if accepted, request == .bindingRefresh {
            evaluator?.resetTrafficEvidence(
                baseline: routeMatches ? baseline : nil,
                at: moment
            )
        }

        guard routeMatches || policyGeneration == pathPolicy.policyGeneration else {
            return transition()
        }
        recoveryPolicy.recoveryAttemptCompleted(accepted: accepted, at: moment.monotonic)
        return transition()
    }

    private mutating func handlePersistenceCompleted(
        _ id: GatewayTunnelHealthOperationID,
        result: GatewayTunnelEffectResult,
        at moment: GatewayTunnelHealthMoment
    ) -> GatewayTunnelHealthTransition {
        guard let pendingPersistence, pendingPersistence.id == id else {
            return transition()
        }
        self.pendingPersistence = nil
        if result == .success {
            persistencePolicy.recordPersisted(
                pendingPersistence.snapshot.health,
                at: pendingPersistence.requestedAt
            )
            return transition(effects: makePersistenceEffects(at: moment))
        }
        return transition()
    }

    private mutating func handleNotificationCompleted(
        _ id: GatewayTunnelHealthOperationID,
        result: GatewayTunnelNotificationResult
    ) -> GatewayTunnelHealthTransition {
        guard outstandingNotificationRegistrations.remove(id) != nil else {
            return transition()
        }
        guard result == .registered else {
            return transition()
        }
        guard !notificationDesired else {
            notificationRegistered = true
            return transition()
        }
        notificationRegistered = false
        return transition(effects: [.withdrawNotification])
    }

    private mutating func publish(
        _ health: GatewayTunnelHealth,
        at moment: GatewayTunnelHealthMoment
    ) -> [GatewayTunnelHealthEffect] {
        guard let tunnelIdentifier else { return [] }
        desiredSnapshot = GatewayTunnelHealthSnapshot(
            tunnelIdentifier: tunnelIdentifier,
            health: health,
            updatedAt: moment.wall
        )

        var effects = makePersistenceEffects(at: moment)

        let previous = lastPublishedHealth
        lastPublishedHealth = health
        if GatewayTunnelHealthNotification.shouldNotify(previous: previous, current: health) {
            notificationDesired = true
            if !notificationRegistered {
                let operationID = makeOperationID()
                outstandingNotificationRegistrations.insert(operationID)
                effects.append(.registerNotification(operationID))
            }
        } else if GatewayTunnelHealthNotification.shouldWithdraw(previous: previous, current: health) {
            notificationDesired = false
            notificationRegistered = false
            effects.append(.withdrawNotification)
        }
        return effects
    }

    private mutating func stop() -> GatewayTunnelHealthTransition {
        activeSession = nil
        tunnelIdentifier = nil
        currentWake = nil
        evaluator = nil
        recoveryPolicy = GatewayTunnelRecoveryPolicy(timing: timing)
        pathPolicy = GatewayTunnelPathPolicy(timing: timing)
        persistencePolicy = GatewayTunnelHealthPersistencePolicy(timing: timing)
        lastPathDescriptor = nil
        lastPublishedHealth = nil
        desiredSnapshot = nil
        physicalOperation = nil
        pendingPersistence = nil
        notificationDesired = false
        notificationRegistered = false
        return GatewayTunnelHealthTransition(
            effects: [.clearSnapshot, .withdrawNotification],
            health: nil,
            nextWake: nil
        )
    }

    private mutating func makeWake(deadline: Duration) -> GatewayTunnelHealthWake? {
        guard let activeSession else { return nil }
        let id = GatewayTunnelHealthWakeID(
            session: activeSession,
            sequence: takeSequence()
        )
        return GatewayTunnelHealthWake(id: id, deadline: deadline)
    }

    private mutating func makePersistenceEffects(
        at moment: GatewayTunnelHealthMoment
    ) -> [GatewayTunnelHealthEffect] {
        guard pendingPersistence == nil,
              let desiredSnapshot,
              persistencePolicy.shouldPersist(
                  desiredSnapshot.health,
                  at: moment.monotonic
              ) else {
            return []
        }
        let operationID = makeOperationID()
        pendingPersistence = PendingPersistence(
            id: operationID,
            snapshot: desiredSnapshot,
            requestedAt: moment.monotonic
        )
        return [.persist(operationID, desiredSnapshot)]
    }

    private mutating func makeOperationID() -> GatewayTunnelHealthOperationID {
        GatewayTunnelHealthOperationID(
            session: activeSession!,
            sequence: takeSequence()
        )
    }

    private mutating func takeSequence() -> UInt64 {
        defer { nextSequence &+= 1 }
        return nextSequence
    }

    private func transition(
        effects: [GatewayTunnelHealthEffect] = []
    ) -> GatewayTunnelHealthTransition {
        GatewayTunnelHealthTransition(
            effects: effects,
            health: lastPublishedHealth,
            nextWake: currentWake
        )
    }
}
