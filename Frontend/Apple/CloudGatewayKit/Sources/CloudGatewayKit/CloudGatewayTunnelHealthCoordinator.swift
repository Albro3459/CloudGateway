import Foundation

struct CloudGatewayTunnelHealthSessionID: Hashable, Sendable { let rawValue: UInt64 }

struct CloudGatewayTunnelHealthWakeID: Hashable, Sendable {
    let session: CloudGatewayTunnelHealthSessionID
    let sequence: UInt64
}

struct CloudGatewayTunnelHealthOperationID: Hashable, Sendable {
    let session: CloudGatewayTunnelHealthSessionID
    let sequence: UInt64
}

public struct CloudGatewayTunnelHealthMoment: Equatable, Sendable {
    public let monotonic: Duration
    public let wall: Date

    public init(monotonic: Duration, wall: Date) {
        self.monotonic = monotonic
        self.wall = wall
    }
}

public struct CloudGatewayTunnelPathDescriptor: Equatable, Sendable {
    public let isSatisfied: Bool
    public let routeID: UInt64

    public init(isSatisfied: Bool, routeID: UInt64) {
        self.isSatisfied = isSatisfied
        self.routeID = routeID
    }
}

public enum CloudGatewayTunnelEffectResult: Equatable, Sendable { case success, failure }
public enum CloudGatewayTunnelRecoveryResult: Equatable, Sendable { case accepted, rejected, unsupported }

public enum CloudGatewayTunnelNotificationResult: Equatable, Sendable {
    case registered
    case absent
    case retryableFailure
    case terminalFailure
    case unknown
    case failed
}

enum CloudGatewayTunnelHealthEvent: Equatable, Sendable {
    case wake(CloudGatewayTunnelHealthWakeID)
    case pathChanged(CloudGatewayTunnelPathDescriptor)
    case runtimeReadCompleted(CloudGatewayTunnelHealthOperationID, CloudGatewayTunnelRuntimeStats?)
    case recoveryCompleted(CloudGatewayTunnelHealthOperationID, CloudGatewayTunnelRecoveryResult)
    case persistenceCompleted(CloudGatewayTunnelHealthOperationID, CloudGatewayTunnelEffectResult)
    case notificationCompleted(CloudGatewayTunnelHealthOperationID, CloudGatewayTunnelNotificationResult)
    case stop
}

enum CloudGatewayTunnelHealthEffect: Equatable, Sendable {
    case readRuntime(CloudGatewayTunnelHealthOperationID)
    case refreshBinding(CloudGatewayTunnelHealthOperationID)
    case restartBackend(CloudGatewayTunnelHealthOperationID)
    case persist(CloudGatewayTunnelHealthOperationID, CloudGatewayTunnelHealthSnapshot)
    case clearSnapshot
    case registerNotification(CloudGatewayTunnelHealthOperationID)
    case reconcileNotification(CloudGatewayTunnelHealthOperationID)
    case withdrawNotification
}

struct CloudGatewayTunnelHealthWake: Equatable, Sendable {
    let id: CloudGatewayTunnelHealthWakeID
    let deadline: Duration
}

struct CloudGatewayTunnelHealthTransition: Equatable, Sendable {
    let effects: [CloudGatewayTunnelHealthEffect]
    let health: CloudGatewayTunnelHealth?
    let nextWake: CloudGatewayTunnelHealthWake?
}

struct CloudGatewayTunnelHealthCoordinator: Sendable {
    private enum OperationLifecycle: Sendable {
        case active(deadline: Duration?)
        case logicallyTimedOut
    }

    private enum PhysicalOperation: Sendable {
        case runtimeRead(id: CloudGatewayTunnelHealthOperationID, lifecycle: OperationLifecycle)
        case recovery(
            id: CloudGatewayTunnelHealthOperationID,
            request: CloudGatewayTunnelRecoveryRequest,
            baseline: CloudGatewayTunnelRuntimeStats?,
            routeGeneration: UInt64,
            lifecycle: OperationLifecycle
        )
    }

    private struct PendingPersistence: Sendable {
        let id: CloudGatewayTunnelHealthOperationID
        let snapshot: CloudGatewayTunnelHealthSnapshot
        let requestedAt: Duration
    }

    private enum NotificationOperationKind: Sendable { case register, reconcile }

    private struct PendingNotification: Sendable {
        let id: CloudGatewayTunnelHealthOperationID
        let kind: NotificationOperationKind
        let deadline: Duration
    }

    private struct NotificationRetry: Sendable {
        let kind: NotificationOperationKind
        let deadline: Duration
    }

    private let timing: CloudGatewayTunnelHealthTiming
    private var activeSession: CloudGatewayTunnelHealthSessionID?
    private var tunnelIdentifier: String?
    private var nextSequence: UInt64 = 0
    private var currentWake: CloudGatewayTunnelHealthWake?
    private var nextPollAt: Duration?
    private var evaluator: CloudGatewayTunnelHealthEvaluator?
    private var recoveryPolicy = CloudGatewayTunnelRecoveryPolicy()
    private var pathPolicy = CloudGatewayTunnelPathPolicy()
    private var pathAvailability: CloudGatewayTunnelPathAvailability = .unavailable
    private var persistencePolicy = CloudGatewayTunnelHealthPersistencePolicy()
    private var lastPathDescriptor: CloudGatewayTunnelPathDescriptor?
    private var lastPublishedHealth: CloudGatewayTunnelHealth?
    private var desiredSnapshot: CloudGatewayTunnelHealthSnapshot?
    private var physicalOperation: PhysicalOperation?
    private var pendingPersistence: PendingPersistence?
    private var notificationDesired = false
    private var notificationRegistered = false
    private var notificationTerminal = false
    private var pendingNotification: PendingNotification?
    private var notificationRetry: NotificationRetry?
    private var notificationRetryDelay: Duration
    private var ambiguousRegistration: CloudGatewayTunnelHealthOperationID?

    init(timing: CloudGatewayTunnelHealthTiming = .production) {
        self.timing = timing
        notificationRetryDelay = timing.notificationInitialRetryDelay
    }

    var desiredArtifacts: CloudGatewayTunnelHealthDesiredArtifacts {
        CloudGatewayTunnelHealthDesiredArtifacts(
            snapshot: desiredSnapshot,
            notificationDesired: notificationDesired,
            notificationRegistrationAllowed: !notificationTerminal,
            notificationOperationID: pendingNotification?.id
        )
    }

    mutating func start(
        session: CloudGatewayTunnelHealthSessionID,
        tunnelIdentifier: String,
        at moment: CloudGatewayTunnelHealthMoment
    ) -> CloudGatewayTunnelHealthTransition {
        retirePendingRegistration()
        activeSession = session
        self.tunnelIdentifier = tunnelIdentifier
        nextSequence = 0
        evaluator = CloudGatewayTunnelHealthEvaluator(startedAt: moment, timing: timing)
        recoveryPolicy = CloudGatewayTunnelRecoveryPolicy(timing: timing)
        pathPolicy = CloudGatewayTunnelPathPolicy(timing: timing)
        pathAvailability = .unavailable
        persistencePolicy = CloudGatewayTunnelHealthPersistencePolicy(timing: timing)
        lastPathDescriptor = nil
        lastPublishedHealth = nil
        desiredSnapshot = nil
        physicalOperation = nil
        pendingPersistence = nil
        notificationDesired = false
        notificationRegistered = false
        notificationTerminal = false
        pendingNotification = nil
        notificationRetry = nil
        notificationRetryDelay = timing.notificationInitialRetryDelay
        ambiguousRegistration = nil
        nextPollAt = moment.monotonic + timing.runtimePollInterval
        currentWake = nil
        return finish(effects: [.withdrawNotification, .clearSnapshot])
    }

    mutating func handle(
        _ event: CloudGatewayTunnelHealthEvent,
        at moment: CloudGatewayTunnelHealthMoment
    ) -> CloudGatewayTunnelHealthTransition {
        if case let .notificationCompleted(id, result) = event {
            return handleNotificationCompleted(id, result: result, at: moment)
        }
        guard activeSession != nil else { return finish() }
        switch event {
        case let .wake(id): return handleWake(id, at: moment)
        case let .pathChanged(path): return handlePathChange(path, at: moment)
        case let .runtimeReadCompleted(id, stats):
            return handleRuntimeReadCompleted(id, stats: stats, at: moment)
        case let .recoveryCompleted(id, result):
            return handleRecoveryCompleted(id, result: result, at: moment)
        case let .persistenceCompleted(id, result):
            return handlePersistenceCompleted(id, result: result, at: moment)
        case .notificationCompleted: return finish()
        case .stop: return stop()
        }
    }

    private mutating func handleWake(
        _ id: CloudGatewayTunnelHealthWakeID,
        at moment: CloudGatewayTunnelHealthMoment
    ) -> CloudGatewayTunnelHealthTransition {
        guard currentWake?.id == id else { return finish() }
        currentWake = nil
        var effects: [CloudGatewayTunnelHealthEffect] = []
        refreshPathAvailability(at: moment.monotonic)
        effects += processPhysicalDeadline(at: moment)
        effects += processNotificationDeadline(at: moment.monotonic)
        effects += processNotificationRetry(at: moment.monotonic)

        if let poll = nextPollAt, moment.monotonic >= poll {
            var next = poll
            repeat { next += timing.runtimePollInterval } while next <= moment.monotonic
            nextPollAt = next
            if physicalOperation == nil {
                let operationID = makeOperationID()
                let deadline = pathAvailability == .satisfied
                    ? moment.monotonic + timing.runtimeReadDeadline : nil
                physicalOperation = .runtimeRead(
                    id: operationID,
                    lifecycle: .active(deadline: deadline)
                )
                effects.append(.readRuntime(operationID))
            } else if lastPublishedHealth == .notPassingTraffic {
                effects += publish(.notPassingTraffic, at: moment)
            } else {
                effects += makePersistenceEffects(at: moment)
            }
        }
        return finish(effects: effects)
    }

    private mutating func handlePathChange(
        _ descriptor: CloudGatewayTunnelPathDescriptor,
        at moment: CloudGatewayTunnelHealthMoment
    ) -> CloudGatewayTunnelHealthTransition {
        guard descriptor != lastPathDescriptor else { return finish() }
        let effects = processPhysicalDeadline(at: moment)
        lastPathDescriptor = descriptor
        let priorRoute = pathPolicy.recoveryRouteGeneration
        pathPolicy.recordPathChange(
            isSatisfied: descriptor.isSatisfied,
            at: moment.monotonic
        )
        pathAvailability = pathPolicy.availability(at: moment.monotonic)
        if case .recovery = physicalOperation,
           priorRoute != pathPolicy.recoveryRouteGeneration {
            recoveryPolicy.invalidatePendingRecoveryAttempt()
        }
        clearActivePhysicalDeadline()
        armPhysicalDeadlineIfStable(at: moment.monotonic)
        return finish(effects: effects)
    }

    private mutating func refreshPathAvailability(at now: Duration) {
        pathAvailability = pathPolicy.availability(at: now)
        armPhysicalDeadlineIfStable(at: now)
    }

    private mutating func clearActivePhysicalDeadline() {
        switch physicalOperation {
        case let .runtimeRead(id, .active):
            physicalOperation = .runtimeRead(id: id, lifecycle: .active(deadline: nil))
        case let .recovery(id, request, baseline, route, .active):
            physicalOperation = .recovery(
                id: id, request: request, baseline: baseline,
                routeGeneration: route, lifecycle: .active(deadline: nil)
            )
        default: break
        }
    }

    private mutating func armPhysicalDeadlineIfStable(at now: Duration) {
        guard pathAvailability == .satisfied else { return }
        switch physicalOperation {
        case let .runtimeRead(id, .active(deadline: nil)):
            physicalOperation = .runtimeRead(
                id: id,
                lifecycle: .active(deadline: now + timing.runtimeReadDeadline)
            )
        case let .recovery(id, request, baseline, route, .active(deadline: nil)):
            physicalOperation = .recovery(
                id: id, request: request, baseline: baseline,
                routeGeneration: route,
                lifecycle: .active(deadline: now + timing.recoveryOperationDeadline)
            )
        default: break
        }
    }

    private mutating func processPhysicalDeadline(
        at moment: CloudGatewayTunnelHealthMoment
    ) -> [CloudGatewayTunnelHealthEffect] {
        guard pathAvailability == .satisfied else { return [] }
        switch physicalOperation {
        case let .runtimeRead(id, .active(deadline: deadline))
            where deadline.map({ moment.monotonic >= $0 }) == true:
            physicalOperation = .runtimeRead(id: id, lifecycle: .logicallyTimedOut)
            let action = recoveryPolicy.runtimeReadTimedOut(
                routeGeneration: pathPolicy.policyGeneration
            )
            return publish(action.health, at: moment)
        case let .recovery(id, request, baseline, route, .active(deadline: deadline))
            where deadline.map({ moment.monotonic >= $0 }) == true:
            physicalOperation = .recovery(
                id: id, request: request, baseline: baseline,
                routeGeneration: route, lifecycle: .logicallyTimedOut
            )
            let action = recoveryPolicy.recoveryAttemptTimedOut(
                routeGeneration: pathPolicy.policyGeneration
            )
            return publish(action.health, at: moment)
        default: return []
        }
    }

    private mutating func handleRuntimeReadCompleted(
        _ id: CloudGatewayTunnelHealthOperationID,
        stats: CloudGatewayTunnelRuntimeStats?,
        at moment: CloudGatewayTunnelHealthMoment
    ) -> CloudGatewayTunnelHealthTransition {
        guard case let .runtimeRead(operationID, _) = physicalOperation,
              operationID == id else { return finish() }
        var effects = processPhysicalDeadline(at: moment)
        physicalOperation = nil
        var evidence: CloudGatewayTunnelHealthEvidence?
        if let stats, var evaluator {
            evidence = evaluator.evaluateEvidence(stats, at: moment)
            self.evaluator = evaluator
        }
        let action = recoveryPolicy.update(
            stats: stats,
            evidence: evidence,
            path: pathAvailability,
            routeGeneration: pathPolicy.policyGeneration,
            at: moment.monotonic
        )
        effects += publish(action.health, at: moment)
        if let request = action.recoveryRequest {
            let operationID = makeOperationID()
            physicalOperation = .recovery(
                id: operationID,
                request: request,
                baseline: stats,
                routeGeneration: pathPolicy.recoveryRouteGeneration,
                lifecycle: .active(
                    deadline: pathAvailability == .satisfied
                        ? moment.monotonic + timing.recoveryOperationDeadline : nil
                )
            )
            effects.append(request == .bindingRefresh
                ? .refreshBinding(operationID) : .restartBackend(operationID))
        }
        return finish(effects: effects)
    }

    private mutating func handleRecoveryCompleted(
        _ id: CloudGatewayTunnelHealthOperationID,
        result: CloudGatewayTunnelRecoveryResult,
        at moment: CloudGatewayTunnelHealthMoment
    ) -> CloudGatewayTunnelHealthTransition {
        guard case let .recovery(operationID, _, _, _, _) = physicalOperation,
              operationID == id else { return finish() }
        let effects = processPhysicalDeadline(at: moment)
        guard case let .recovery(
            operationID, request, baseline, routeGeneration, lifecycle
        ) = physicalOperation, operationID == id else { return finish(effects: effects) }
        physicalOperation = nil
        let accepted = result == .accepted
        let routeMatches = routeGeneration == pathPolicy.recoveryRouteGeneration
        if accepted, request == .backendRestart { evaluator?.resetSession(at: moment) }
        if accepted, request == .bindingRefresh {
            evaluator?.resetTrafficEvidence(
                baseline: routeMatches ? baseline : nil,
                at: moment
            )
        }
        if case .active = lifecycle, routeMatches {
            recoveryPolicy.recoveryAttemptCompleted(
                accepted: accepted,
                at: moment.monotonic
            )
        }
        return finish(effects: effects)
    }

    private mutating func handlePersistenceCompleted(
        _ id: CloudGatewayTunnelHealthOperationID,
        result: CloudGatewayTunnelEffectResult,
        at moment: CloudGatewayTunnelHealthMoment
    ) -> CloudGatewayTunnelHealthTransition {
        guard let pendingPersistence, pendingPersistence.id == id else { return finish() }
        self.pendingPersistence = nil
        if result == .success {
            persistencePolicy.recordPersisted(
                pendingPersistence.snapshot.health,
                at: pendingPersistence.requestedAt
            )
            return finish(effects: makePersistenceEffects(at: moment))
        }
        return finish()
    }

    private mutating func startNotification(
        _ kind: NotificationOperationKind,
        at now: Duration
    ) -> [CloudGatewayTunnelHealthEffect] {
        guard pendingNotification == nil else { return [] }
        let id = makeOperationID()
        pendingNotification = PendingNotification(
            id: id,
            kind: kind,
            deadline: now + timing.notificationOperationDeadline
        )
        return [kind == .register ? .registerNotification(id) : .reconcileNotification(id)]
    }

    private mutating func handleNotificationCompleted(
        _ id: CloudGatewayTunnelHealthOperationID,
        result: CloudGatewayTunnelNotificationResult,
        at moment: CloudGatewayTunnelHealthMoment
    ) -> CloudGatewayTunnelHealthTransition {
        if result == .terminalFailure, id.session == activeSession {
            if pendingNotification?.id == id { pendingNotification = nil }
            if ambiguousRegistration == id { ambiguousRegistration = nil }
            notificationTerminal = true
            notificationRetry = nil
            return finish()
        }
        if ambiguousRegistration == id {
            ambiguousRegistration = nil
            guard result == .registered else { return finish() }
            if notificationDesired {
                notificationRegistered = true
                pendingNotification = nil
                notificationRetry = nil
                return finish()
            }
            return finish(effects: [.withdrawNotification])
        }
        guard let pending = pendingNotification, pending.id == id else {
            guard result == .registered else { return finish() }
            if notificationDesired {
                notificationRegistered = true
                pendingNotification = nil
                ambiguousRegistration = nil
                notificationRetry = nil
                return finish()
            }
            return finish(effects: [.withdrawNotification])
        }
        pendingNotification = nil
        if notificationRegistered, result != .terminalFailure {
            notificationRetry = nil
            return finish()
        }
        switch (pending.kind, result) {
        case (_, .terminalFailure):
            notificationTerminal = true
            notificationRetry = nil
            return finish()
        case (.register, .registered), (.reconcile, .registered):
            notificationRegistered = notificationDesired
            notificationRetry = nil
            notificationRetryDelay = timing.notificationInitialRetryDelay
            return finish(effects: notificationDesired ? [] : [.withdrawNotification])
        case (.reconcile, .absent):
            ambiguousRegistration = nil
            scheduleNotificationRetry(.register, at: moment.monotonic)
        case (.register, .unknown):
            ambiguousRegistration = id
            return finish(effects: startNotification(.reconcile, at: moment.monotonic))
        case (.register, .retryableFailure), (.register, .failed), (.register, .absent):
            scheduleNotificationRetry(.register, at: moment.monotonic)
        case (.reconcile, .retryableFailure), (.reconcile, .failed), (.reconcile, .unknown):
            scheduleNotificationRetry(.reconcile, at: moment.monotonic)
        }
        return finish()
    }

    private mutating func processNotificationDeadline(
        at now: Duration
    ) -> [CloudGatewayTunnelHealthEffect] {
        guard let pending = pendingNotification, now >= pending.deadline else { return [] }
        pendingNotification = nil
        if pending.kind == .register {
            ambiguousRegistration = pending.id
            return startNotification(.reconcile, at: now)
        }
        scheduleNotificationRetry(.reconcile, at: now)
        return []
    }

    private mutating func scheduleNotificationRetry(
        _ kind: NotificationOperationKind,
        at now: Duration
    ) {
        guard notificationDesired, !notificationTerminal else { return }
        notificationRetry = NotificationRetry(
            kind: kind,
            deadline: now + notificationRetryDelay
        )
        notificationRetryDelay = min(
            notificationRetryDelay + notificationRetryDelay,
            timing.notificationMaximumRetryDelay
        )
    }

    private mutating func processNotificationRetry(
        at now: Duration
    ) -> [CloudGatewayTunnelHealthEffect] {
        guard let retry = notificationRetry, now >= retry.deadline else { return [] }
        notificationRetry = nil
        guard notificationDesired, !notificationTerminal else { return [] }
        return startNotification(retry.kind, at: now)
    }

    private mutating func publish(
        _ health: CloudGatewayTunnelHealth,
        at moment: CloudGatewayTunnelHealthMoment
    ) -> [CloudGatewayTunnelHealthEffect] {
        guard let tunnelIdentifier else { return [] }
        desiredSnapshot = CloudGatewayTunnelHealthSnapshot(
            tunnelIdentifier: tunnelIdentifier,
            health: health,
            updatedAt: moment.wall
        )
        var effects = makePersistenceEffects(at: moment)
        let previous = lastPublishedHealth
        lastPublishedHealth = health
        if CloudGatewayTunnelHealthNotification.shouldNotify(previous: previous, current: health) {
            notificationDesired = true
            notificationRetryDelay = timing.notificationInitialRetryDelay
            if !notificationRegistered, !notificationTerminal {
                effects += startNotification(.register, at: moment.monotonic)
            }
        } else if CloudGatewayTunnelHealthNotification.shouldWithdraw(previous: previous, current: health) {
            notificationDesired = false
            notificationRegistered = false
            notificationRetry = nil
            retirePendingRegistration()
            effects.append(.withdrawNotification)
        }
        return effects
    }

    private mutating func makePersistenceEffects(
        at moment: CloudGatewayTunnelHealthMoment
    ) -> [CloudGatewayTunnelHealthEffect] {
        guard pendingPersistence == nil,
              let desiredSnapshot,
              persistencePolicy.shouldPersist(
                desiredSnapshot.health,
                at: moment.monotonic
              ) else { return [] }
        let id = makeOperationID()
        pendingPersistence = PendingPersistence(
            id: id,
            snapshot: desiredSnapshot,
            requestedAt: moment.monotonic
        )
        return [.persist(id, desiredSnapshot)]
    }

    private mutating func retirePendingRegistration() {
        pendingNotification = nil
        ambiguousRegistration = nil
        notificationRetry = nil
    }

    private mutating func stop() -> CloudGatewayTunnelHealthTransition {
        retirePendingRegistration()
        activeSession = nil
        tunnelIdentifier = nil
        currentWake = nil
        nextPollAt = nil
        evaluator = nil
        recoveryPolicy = CloudGatewayTunnelRecoveryPolicy(timing: timing)
        pathPolicy = CloudGatewayTunnelPathPolicy(timing: timing)
        pathAvailability = .unavailable
        persistencePolicy = CloudGatewayTunnelHealthPersistencePolicy(timing: timing)
        lastPathDescriptor = nil
        lastPublishedHealth = nil
        desiredSnapshot = nil
        physicalOperation = nil
        pendingPersistence = nil
        notificationDesired = false
        notificationRegistered = false
        notificationTerminal = false
        return CloudGatewayTunnelHealthTransition(
            effects: [.clearSnapshot, .withdrawNotification],
            health: nil,
            nextWake: nil
        )
    }

    private mutating func finish(
        effects: [CloudGatewayTunnelHealthEffect] = []
    ) -> CloudGatewayTunnelHealthTransition {
        rescheduleWake()
        return CloudGatewayTunnelHealthTransition(
            effects: effects,
            health: lastPublishedHealth,
            nextWake: currentWake
        )
    }

    private mutating func rescheduleWake() {
        guard activeSession != nil else { currentWake = nil; return }
        var deadlines: [Duration] = []
        if let nextPollAt { deadlines.append(nextPollAt) }
        if let pathDeadline = pathPolicy.nextAvailabilityDeadline {
            deadlines.append(pathDeadline)
        }
        switch physicalOperation {
        case let .runtimeRead(_, .active(deadline)),
             let .recovery(_, _, _, _, .active(deadline)):
            if let deadline { deadlines.append(deadline) }
        default: break
        }
        if let pendingNotification { deadlines.append(pendingNotification.deadline) }
        if let notificationRetry { deadlines.append(notificationRetry.deadline) }
        guard let deadline = deadlines.min() else { currentWake = nil; return }
        if currentWake?.deadline == deadline { return }
        currentWake = CloudGatewayTunnelHealthWake(
            id: CloudGatewayTunnelHealthWakeID(
                session: activeSession!,
                sequence: takeSequence()
            ),
            deadline: deadline
        )
    }

    private mutating func makeOperationID() -> CloudGatewayTunnelHealthOperationID {
        CloudGatewayTunnelHealthOperationID(
            session: activeSession!,
            sequence: takeSequence()
        )
    }

    private mutating func takeSequence() -> UInt64 {
        defer { nextSequence &+= 1 }
        return nextSequence
    }
}
