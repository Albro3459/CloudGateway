import Foundation

private final class GatewayTunnelHealthNotificationRegistrationToken: @unchecked Sendable {
    let generation: UInt64
    private let lock = NSLock()
    private var completed = false

    init(generation: UInt64) {
        self.generation = generation
    }

    func claimCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

private final class GatewayTunnelHealthDeadlineSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () async -> Void)?

    func setHandler(_ handler: @escaping @Sendable () async -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func notify() {
        lock.lock()
        let handler = handler
        lock.unlock()
        guard let handler else { return }
        Task { await handler() }
    }
}

struct GatewayTunnelHealthDesiredArtifacts: Equatable, Sendable {
    let snapshot: GatewayTunnelHealthSnapshot?
    let notificationDesired: Bool
    let notificationRegistrationAllowed: Bool
    let notificationOperationID: GatewayTunnelHealthOperationID?

    init(
        snapshot: GatewayTunnelHealthSnapshot?,
        notificationDesired: Bool,
        notificationRegistrationAllowed: Bool,
        notificationOperationID: GatewayTunnelHealthOperationID? = nil
    ) {
        self.snapshot = snapshot
        self.notificationDesired = notificationDesired
        self.notificationRegistrationAllowed = notificationRegistrationAllowed
        self.notificationOperationID = notificationOperationID
    }

    static let empty = GatewayTunnelHealthDesiredArtifacts(
        snapshot: nil,
        notificationDesired: false,
        notificationRegistrationAllowed: true,
        notificationOperationID: nil
    )
}

final class GatewayTunnelHealthArtifactIntent: @unchecked Sendable {
    struct State: Sendable {
        let generation: UInt64?
        let desired: GatewayTunnelHealthDesiredArtifacts
    }

    private let lock = NSLock()
    private var state = State(generation: nil, desired: .empty)

    func activate(
        generation: UInt64,
        desired: GatewayTunnelHealthDesiredArtifacts
    ) {
        lock.lock()
        state = State(generation: generation, desired: desired)
        lock.unlock()
    }

    func update(
        generation: UInt64,
        desired: GatewayTunnelHealthDesiredArtifacts
    ) {
        lock.lock()
        if state.generation == generation {
            state = State(generation: generation, desired: desired)
        }
        lock.unlock()
    }

    func deactivate(generation: UInt64) {
        lock.lock()
        if state.generation == generation {
            state = State(generation: nil, desired: .empty)
        }
        lock.unlock()
    }

    func withCurrentState<Result>(
        _ action: (State) -> Result
    ) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return action(state)
    }
}

actor GatewayTunnelHealthArtifactDriver {
    private enum PendingKind: Sendable {
        case persistence
        case clear
        case notification
    }

    private struct PendingKey: Hashable, Sendable {
        let generation: UInt64
        let sequence: UInt64
    }

    private struct PendingOperation: Sendable {
        let generation: UInt64
        let kind: PendingKind
        let notificationID: GatewayTunnelHealthOperationID?
        let notificationKind: NotificationOperationKind?

        init(
            generation: UInt64,
            kind: PendingKind,
            notificationID: GatewayTunnelHealthOperationID? = nil,
            notificationKind: NotificationOperationKind? = nil
        ) {
            self.generation = generation
            self.kind = kind
            self.notificationID = notificationID
            self.notificationKind = notificationKind
        }
    }

    private struct StopWaiter: Sendable {
        let generation: UInt64
        let completion: @Sendable () -> Void
    }

    private enum NotificationOperationKind: Equatable, Sendable {
        case register
        case reconcile
        case reconcileAmbiguousRegistration
    }

    private struct DeferredNotificationOperation: Sendable {
        let generation: UInt64
        let id: GatewayTunnelHealthOperationID
        let kind: NotificationOperationKind
        let completion: @Sendable (GatewayTunnelHealthEvent) async -> Void
    }

    private enum NotificationRepairPhase: Equatable, Sendable {
        case reconciling
        case registering
    }

    private struct NotificationRepairOperation: Sendable {
        let sequence: UInt64
        let deadline: Duration
        let phase: NotificationRepairPhase
    }

    private let persistence: any GatewayTunnelHealthPersistenceAdapter
    private let notifications: any GatewayTunnelHealthNotificationAdapter
    private let gate: GatewayTunnelHealthEffectGate
    private let intent: GatewayTunnelHealthArtifactIntent
    private let notificationRepairDeadline: Duration
    private let now: @Sendable () -> Duration
    private nonisolated let deadlineSignal = GatewayTunnelHealthDeadlineSignal()
    private var activeGeneration: UInt64?
    private var desired = GatewayTunnelHealthDesiredArtifacts.empty
    private var nextSequence: UInt64 = 0
    private var pending: [PendingKey: PendingOperation] = [:]
    private var physicalNotificationRegistrationCounts: [UInt64: Int] = [:]
    private var deferredNotification: DeferredNotificationOperation?
    private var stopWaiters: [StopWaiter] = []
    private var snapshotRepairSequence: UInt64 = 0
    private var snapshotRepairInFlight: UInt64?
    private var snapshotRepairDirty = false
    private var notificationRepairSequence: UInt64 = 0
    private var notificationRepairInFlight: NotificationRepairOperation?
    private var notificationRepairDirty = false
    private var currentTime: Duration = .zero

    init(
        persistence: any GatewayTunnelHealthPersistenceAdapter,
        notifications: any GatewayTunnelHealthNotificationAdapter,
        gate: GatewayTunnelHealthEffectGate,
        intent: GatewayTunnelHealthArtifactIntent = GatewayTunnelHealthArtifactIntent(),
        notificationRepairDeadline: Duration = .seconds(10),
        now: @escaping @Sendable () -> Duration = { .zero }
    ) {
        self.persistence = persistence
        self.notifications = notifications
        self.gate = gate
        self.intent = intent
        self.notificationRepairDeadline = notificationRepairDeadline
        self.now = now
    }

    nonisolated func setDeadlineChangedHandler(
        _ handler: @escaping @Sendable () async -> Void
    ) {
        deadlineSignal.setHandler(handler)
    }

    func advance(to now: Duration) {
        if now > currentTime { currentTime = now }
        expireNotificationRepairIfNeeded()
    }

    var nextNotificationRepairDeadline: Duration? {
        notificationRepairInFlight?.deadline
    }

    func activate(
        generation: UInt64,
        desired: GatewayTunnelHealthDesiredArtifacts
    ) {
        activeGeneration = generation
        self.desired = desired
        intent.activate(generation: generation, desired: desired)
        if snapshotRepairInFlight != nil { snapshotRepairDirty = true }
        if notificationRepairInFlight != nil { notificationRepairDirty = true }
    }

    func updateDesired(
        generation: UInt64,
        desired: GatewayTunnelHealthDesiredArtifacts
    ) {
        guard activeGeneration == generation else { return }
        if self.desired.snapshot != desired.snapshot,
           snapshotRepairInFlight != nil {
            snapshotRepairDirty = true
        }
        if (self.desired.notificationDesired != desired.notificationDesired ||
            self.desired.notificationRegistrationAllowed != desired.notificationRegistrationAllowed),
           notificationRepairInFlight != nil {
            notificationRepairDirty = true
        }
        self.desired = desired
        intent.update(generation: generation, desired: desired)
        if deferredNotification?.id != desired.notificationOperationID {
            deferredNotification = nil
        }
    }

    func execute(
        _ effect: GatewayTunnelHealthEffect,
        generation: UInt64,
        completion: @escaping @Sendable (GatewayTunnelHealthEvent) async -> Void
    ) {
        switch effect {
        case let .persist(id, snapshot):
            let key = nextPendingKey(generation: generation)
            gate.performIfOpen(generation: generation) {
                pending[key] = PendingOperation(
                    generation: generation,
                    kind: .persistence
                )
                persistence.write(snapshot) { [weak self] result in
                    await self?.completePersistence(
                        key: key,
                        id: id,
                        result: result,
                        completion: completion
                    )
                }
            }
        case .clearSnapshot:
            let key = nextPendingKey(generation: generation)
            gate.performIfOpen(generation: generation) {
                pending[key] = PendingOperation(
                    generation: generation,
                    kind: .clear
                )
                persistence.clear { [weak self] _ in
                    await self?.completeClear(key: key)
                }
            }
        case let .registerNotification(id):
            enqueueNotification(
                kind: .register,
                id: id,
                generation: generation,
                completion: completion
            )
        case let .reconcileNotification(id):
            enqueueNotification(
                kind: .reconcile,
                id: id,
                generation: generation,
                completion: completion
            )
        case .withdrawNotification:
            gate.performIfOpen(generation: generation) {
                notifications.withdraw()
            }
        case .readRuntime, .refreshBinding, .restartBackend:
            break
        }
    }

    func stop(
        generation: UInt64,
        completion: @escaping @Sendable () -> Void
    ) {
        retire(generation: generation)
        if deferredNotification?.generation == generation {
            deferredNotification = nil
        }
        stopWaiters.append(StopWaiter(generation: generation, completion: completion))
        requestRepair()
    }

    func requestCurrentRepair() {
        requestRepair()
    }

    var pendingNotificationOperationCount: Int {
        pending.values.filter { $0.kind == .notification }.count
    }

    var physicalNotificationRegistrationGenerationCount: Int {
        physicalNotificationRegistrationCounts.count
    }

    func abandonStop(generation: UInt64) {
        retire(generation: generation)
        physicalNotificationRegistrationCounts[generation] = nil
        pending = pending.filter { $0.value.generation != generation }
        if deferredNotification?.generation == generation {
            deferredNotification = nil
        }
        stopWaiters.removeAll { $0.generation == generation }
        drainNotificationLane()
        finishStopWaitersIfPossible()
    }

    private func retire(generation: UInt64) {
        guard activeGeneration == generation else { return }
        if snapshotRepairInFlight != nil { snapshotRepairDirty = true }
        if notificationRepairInFlight != nil { notificationRepairDirty = true }
        activeGeneration = nil
        desired = .empty
        intent.deactivate(generation: generation)
    }

    private func nextPendingKey(generation: UInt64) -> PendingKey {
        let key = PendingKey(generation: generation, sequence: nextSequence)
        nextSequence &+= 1
        return key
    }

    private func enqueueNotification(
        kind: NotificationOperationKind,
        id: GatewayTunnelHealthOperationID,
        generation: UInt64,
        completion: @escaping @Sendable (GatewayTunnelHealthEvent) async -> Void
    ) {
        gate.performIfOpen(generation: generation) {
            guard desired.notificationOperationID == id else { return }
            let operation = DeferredNotificationOperation(
                generation: generation,
                id: id,
                kind: kind,
                completion: completion
            )
            if notificationRepairInFlight != nil {
                deferredNotification = operation
            } else {
                var operationToStart = operation
                if let entry = pending.first(where: {
                    $0.value.kind == .notification
                }) {
                    guard entry.value.notificationID != id else { return }
                    pending.removeValue(forKey: entry.key)
                    if entry.value.notificationKind == .register,
                       kind == .register {
                        operationToStart = DeferredNotificationOperation(
                            generation: generation,
                            id: id,
                            kind: .reconcileAmbiguousRegistration,
                            completion: completion
                        )
                    }
                }
                startNotification(operationToStart)
            }
        }
    }

    private var notificationPhysicalBusy: Bool {
        notificationRepairInFlight != nil || pending.values.contains {
            $0.kind == .notification
        }
    }

    private func startNotification(_ operation: DeferredNotificationOperation) {
        let key = nextPendingKey(generation: operation.generation)
        pending[key] = PendingOperation(
            generation: operation.generation,
            kind: .notification,
            notificationID: operation.id,
            notificationKind: operation.kind
        )
        let physicalRegistration: GatewayTunnelHealthNotificationRegistrationToken?
        if operation.kind == .register {
            physicalRegistration = beginPhysicalNotificationRegistration(
                generation: operation.generation
            )
        } else {
            physicalRegistration = nil
        }
        let callback: @Sendable (GatewayTunnelNotificationResult) async -> Void = {
            [weak self] result in
            let reportedResult: GatewayTunnelNotificationResult
            if operation.kind == .reconcileAmbiguousRegistration,
               result == .retryableFailure || result == .failed {
                reportedResult = .unknown
            } else {
                reportedResult = result
            }
            await self?.completeNotification(
                key: key,
                id: operation.id,
                result: reportedResult,
                physicalRegistration: physicalRegistration,
                completion: operation.completion
            )
        }
        switch operation.kind {
        case .register:
            notifications.register(completion: callback)
        case .reconcile, .reconcileAmbiguousRegistration:
            notifications.reconcile(completion: callback)
        }
    }

    private func completePersistence(
        key: PendingKey,
        id: GatewayTunnelHealthOperationID,
        result: GatewayTunnelEffectResult,
        completion: @escaping @Sendable (GatewayTunnelHealthEvent) async -> Void
    ) async {
        guard pending.removeValue(forKey: key) != nil else {
            requestRepair()
            finishStopWaitersIfPossible()
            return
        }
        if activeGeneration == key.generation,
           gate.isCurrentAndOpen(generation: key.generation) {
            await completion(.persistenceCompleted(id, result))
        } else {
            requestRepair()
        }
        finishStopWaitersIfPossible()
    }

    private func completeClear(key: PendingKey) {
        guard pending.removeValue(forKey: key) != nil else {
            requestRepair()
            finishStopWaitersIfPossible()
            return
        }
        if activeGeneration != key.generation || desired.snapshot != nil {
            requestRepair()
        }
        finishStopWaitersIfPossible()
    }

    private func completeNotification(
        key: PendingKey,
        id: GatewayTunnelHealthOperationID,
        result: GatewayTunnelNotificationResult,
        physicalRegistration: GatewayTunnelHealthNotificationRegistrationToken?,
        completion: @escaping @Sendable (GatewayTunnelHealthEvent) async -> Void
    ) async {
        if let physicalRegistration,
           !finishPhysicalNotificationRegistration(physicalRegistration) {
            return
        }
        guard pending.removeValue(forKey: key) != nil else {
            requestRepair()
            drainNotificationLane()
            finishStopWaitersIfPossible()
            return
        }
        if activeGeneration == key.generation,
           gate.isCurrentAndOpen(generation: key.generation) {
            await completion(.notificationCompleted(id, result))
        } else {
            requestRepair()
        }
        drainNotificationLane()
        finishStopWaitersIfPossible()
    }

    private func requestRepair() {
        snapshotRepairDirty = true
        notificationRepairDirty = true
        startSnapshotRepairIfNeeded()
        drainNotificationLane()
    }

    private func startSnapshotRepairIfNeeded() {
        guard snapshotRepairInFlight == nil, snapshotRepairDirty else { return }
        snapshotRepairDirty = false
        snapshotRepairSequence &+= 1
        let sequence = snapshotRepairSequence
        snapshotRepairInFlight = sequence
        let callback: @Sendable (GatewayTunnelEffectResult) async -> Void = {
            [weak self] result in
            await self?.snapshotRepairCompleted(result, sequence: sequence)
        }
        if let snapshot = desired.snapshot {
            guard let generation = activeGeneration,
                  gate.performIfOpen(generation: generation, {
                      persistence.write(snapshot, completion: callback)
                  }) else {
                snapshotRepairInFlight = nil
                snapshotRepairDirty = true
                finishStopWaitersIfPossible()
                return
            }
        } else {
            if let generation = activeGeneration {
                guard gate.performIfOpen(generation: generation, {
                    persistence.clear(completion: callback)
                }) else {
                    snapshotRepairInFlight = nil
                    snapshotRepairDirty = true
                    finishStopWaitersIfPossible()
                    return
                }
            } else {
                persistence.clear(completion: callback)
            }
        }
    }

    private func snapshotRepairCompleted(
        _ result: GatewayTunnelEffectResult,
        sequence: UInt64
    ) {
        guard snapshotRepairInFlight == sequence else { return }
        snapshotRepairInFlight = nil
        if result == .success {
            startSnapshotRepairIfNeeded()
        } else {
            snapshotRepairDirty = true
        }
        finishStopWaitersIfPossible()
    }

    private func drainNotificationLane() {
        guard !notificationPhysicalBusy else { return }
        if let operation = deferredNotification {
            deferredNotification = nil
            guard desired.notificationOperationID == operation.id else {
                startNotificationRepairIfNeeded()
                return
            }
            let started = gate.performIfOpen(generation: operation.generation) {
                startNotification(operation)
            }
            if started { return }
            notificationRepairDirty = true
        }
        startNotificationRepairIfNeeded()
    }

    private func startNotificationRepairIfNeeded() {
        guard notificationRepairInFlight == nil,
              notificationRepairDirty,
              !pending.values.contains(where: {
                  $0.kind == .notification
              }) else {
            return
        }
        notificationRepairDirty = false
        notificationRepairSequence &+= 1
        let sequence = notificationRepairSequence
        notificationRepairInFlight = NotificationRepairOperation(
            sequence: sequence,
            deadline: now() + notificationRepairDeadline,
            phase: .reconciling
        )
        notifyDeadlineChanged()
        guard desired.notificationDesired else {
            if let generation = activeGeneration {
                guard gate.performIfOpen(generation: generation, {
                    notifications.withdraw()
                }) else {
                    notificationRepairInFlight = nil
                    notificationRepairDirty = true
                    notifyDeadlineChanged()
                    finishStopWaitersIfPossible()
                    return
                }
            } else {
                notifications.withdraw()
            }
            notificationRepairInFlight = nil
            notifyDeadlineChanged()
            if notificationRepairDirty { drainNotificationLane() }
            finishStopWaitersIfPossible()
            return
        }
        let registrationAllowed = desired.notificationRegistrationAllowed
        guard let generation = activeGeneration,
              gate.performIfOpen(generation: generation, {
                  notifications.reconcile { [weak self] result in
                      await self?.notificationRepairReconciled(
                          result,
                          registrationAllowed: registrationAllowed,
                          sequence: sequence
                      )
                  }
              }) else {
            notificationRepairInFlight = nil
            notificationRepairDirty = true
            notifyDeadlineChanged()
            finishStopWaitersIfPossible()
            return
        }
    }

    private func notificationRepairReconciled(
        _ result: GatewayTunnelNotificationResult,
        registrationAllowed: Bool,
        sequence: UInt64
    ) async {
        guard notificationRepairInFlight?.sequence == sequence else { return }
        switch result {
        case .registered:
            await satisfyDeferredNotification(with: .registered)
            finishNotificationRepair(sequence: sequence, succeeded: true)
        case .absent where registrationAllowed:
            guard desired.notificationDesired,
                  desired.notificationRegistrationAllowed,
                  desired.notificationOperationID == nil,
                  let generation = activeGeneration else {
                finishNotificationRepair(sequence: sequence, succeeded: true)
                return
            }
            let started = gate.performIfOpen(generation: generation) {
                notificationRepairInFlight = NotificationRepairOperation(
                    sequence: sequence,
                    deadline: now() + notificationRepairDeadline,
                    phase: .registering
                )
                notifyDeadlineChanged()
                let physicalRegistration = beginPhysicalNotificationRegistration(
                    generation: generation
                )
                notifications.register { [weak self] result in
                    await self?.notificationRepairRegistered(
                        result,
                        sequence: sequence,
                        physicalRegistration: physicalRegistration
                    )
                }
            }
            if !started {
                finishNotificationRepair(sequence: sequence, succeeded: true)
            }
        case .absent, .terminalFailure:
            if result == .terminalFailure {
                await satisfyDeferredNotification(with: .terminalFailure)
            }
            finishNotificationRepair(sequence: sequence, succeeded: true)
        case .retryableFailure, .unknown, .failed:
            finishNotificationRepair(sequence: sequence, succeeded: false)
        }
    }

    private func notificationRepairRegistered(
        _ result: GatewayTunnelNotificationResult,
        sequence: UInt64,
        physicalRegistration: GatewayTunnelHealthNotificationRegistrationToken
    ) async {
        guard finishPhysicalNotificationRegistration(physicalRegistration) else { return }
        guard notificationRepairInFlight?.sequence == sequence else {
            requestRepair()
            finishStopWaitersIfPossible()
            return
        }
        switch result {
        case .registered:
            await satisfyDeferredNotification(with: .registered)
            finishNotificationRepair(sequence: sequence, succeeded: true)
        case .terminalFailure:
            await satisfyDeferredNotification(with: .terminalFailure)
            finishNotificationRepair(sequence: sequence, succeeded: true)
        case .absent, .retryableFailure, .unknown, .failed:
            finishNotificationRepair(sequence: sequence, succeeded: false)
        }
    }

    private func satisfyDeferredNotification(
        with result: GatewayTunnelNotificationResult
    ) async {
        guard let operation = deferredNotification,
              activeGeneration == operation.generation,
              desired.notificationOperationID == operation.id,
              gate.isCurrentAndOpen(generation: operation.generation) else {
            return
        }
        deferredNotification = nil
        await operation.completion(.notificationCompleted(operation.id, result))
    }

    private func finishNotificationRepair(
        sequence: UInt64,
        succeeded: Bool
    ) {
        guard notificationRepairInFlight?.sequence == sequence else { return }
        notificationRepairInFlight = nil
        notifyDeadlineChanged()
        if !succeeded { notificationRepairDirty = true }
        if succeeded || deferredNotification != nil || !desired.notificationDesired {
            drainNotificationLane()
        }
        finishStopWaitersIfPossible()
    }

    private func expireNotificationRepairIfNeeded() {
        guard let repair = notificationRepairInFlight,
              currentTime >= repair.deadline else {
            return
        }
        notificationRepairInFlight = nil
        notifyDeadlineChanged()
        notificationRepairDirty = true
        if var operation = deferredNotification {
            deferredNotification = nil
            if repair.phase == .registering,
               operation.kind == .register {
                operation = DeferredNotificationOperation(
                    generation: operation.generation,
                    id: operation.id,
                    kind: .reconcileAmbiguousRegistration,
                    completion: operation.completion
                )
            }
            let started = gate.performIfOpen(generation: operation.generation) {
                startNotification(operation)
            }
            if started { return }
        }
        startNotificationRepairIfNeeded()
        finishStopWaitersIfPossible()
    }

    private func notifyDeadlineChanged() {
        deadlineSignal.notify()
    }

    private func beginPhysicalNotificationRegistration(
        generation: UInt64
    ) -> GatewayTunnelHealthNotificationRegistrationToken {
        physicalNotificationRegistrationCounts[generation, default: 0] += 1
        return GatewayTunnelHealthNotificationRegistrationToken(generation: generation)
    }

    private func finishPhysicalNotificationRegistration(
        _ registration: GatewayTunnelHealthNotificationRegistrationToken
    ) -> Bool {
        guard registration.claimCompletion() else { return false }
        if let count = physicalNotificationRegistrationCounts[registration.generation] {
            if count > 1 {
                physicalNotificationRegistrationCounts[registration.generation] = count - 1
            } else {
                physicalNotificationRegistrationCounts[registration.generation] = nil
            }
        }
        return true
    }

    private func finishStopWaitersIfPossible() {
        guard snapshotRepairInFlight == nil,
              !snapshotRepairDirty,
              notificationRepairInFlight == nil,
              !notificationRepairDirty,
              deferredNotification == nil else {
            return
        }
        var remaining: [StopWaiter] = []
        for waiter in stopWaiters {
            if pending.values.contains(where: { $0.generation == waiter.generation }) ||
                physicalNotificationRegistrationCounts[waiter.generation] != nil {
                remaining.append(waiter)
            } else {
                waiter.completion()
            }
        }
        stopWaiters = remaining
    }
}
