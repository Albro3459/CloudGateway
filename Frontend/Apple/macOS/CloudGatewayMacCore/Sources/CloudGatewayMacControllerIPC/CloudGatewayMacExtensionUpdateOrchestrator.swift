import CloudGatewayMacCore
import CloudGatewayMacIPC
import Foundation

@MainActor
public final class CloudGatewayMacExtensionUpdateOrchestrator {
    public struct Attempt: Codable, Equatable, Sendable {
        public let id: UUID
        public let target: CloudGatewayMacBuildIdentity
        public let bootSession: String

        public init(id: UUID, target: CloudGatewayMacBuildIdentity, bootSession: String) {
            self.id = id
            self.target = target
            self.bootSession = bootSession
        }
    }

    public struct TerminalReceipt: Codable, Equatable, Sendable {
        public enum Outcome: String, Codable, Sendable {
            case ready, activationFinished, failed, expired, superseded, legacyCompletion
        }

        public let id: UUID
        public let outcome: Outcome
        public let expires: Date

        public init(id: UUID, outcome: Outcome, expires: Date) {
            self.id = id
            self.outcome = outcome
            self.expires = expires
        }
    }

    public enum State: Codable, Equatable, Sendable {
        case idle
        case prepared(Attempt, deadline: Date)
        case submitted(Attempt, deadline: Date)
        case approvalPending(Attempt)
        case outcomeUnknown(Attempt)
        case rebootRequired(Attempt)
        case terminal(TerminalReceipt)

        public var attempt: Attempt? {
            switch self {
            case .prepared(let attempt, _), .submitted(let attempt, _), .approvalPending(let attempt),
                 .outcomeUnknown(let attempt), .rebootRequired(let attempt): attempt
            case .idle, .terminal: nil
            }
        }
    }

    public struct StoredState: Codable, Equatable, Sendable {
        public var state: State
        public var receipts: [TerminalReceipt]
        public var managedAttemptId: UUID? = nil

        public init(state: State = .idle, receipts: [TerminalReceipt] = []) {
            self.state = state
            self.receipts = receipts
        }

        public init(legacyAttempt: LegacyAttempt?, finishedExtensionUpdates: [UUID: Date]) throws {
            receipts = finishedExtensionUpdates.map {
                TerminalReceipt(id: $0.key, outcome: .legacyCompletion, expires: $0.value)
            }
            guard let legacyAttempt else { state = .idle; return }
            let attempt = Attempt(id: legacyAttempt.id, target: legacyAttempt.target, bootSession: legacyAttempt.bootSession)
            switch legacyAttempt.phase {
            case "prepared": state = .prepared(attempt, deadline: legacyAttempt.deadline ?? .distantPast)
            case "activating": state = .submitted(attempt, deadline: legacyAttempt.deadline ?? .distantPast)
            case "approval": state = .approvalPending(attempt)
            case "restart": state = .rebootRequired(attempt)
            default: throw CloudGatewayMacControllerFailure.invalidRequest
            }
        }
    }

    public struct LegacyAttempt: Codable, Sendable {
        public let id: UUID
        public let target: CloudGatewayMacBuildIdentity
        public let bootSession: String
        public let phase: String
        public let deadline: Date?
    }

    public enum Event: Equatable, Sendable {
        case started, approval, rebootRequired, finished, failed
    }

    public struct ReadinessToken: Equatable, Sendable {
        fileprivate let instance: UUID
        fileprivate let epoch: UInt64
        fileprivate let attemptId: UUID?
        public let target: CloudGatewayMacBuildIdentity
    }

    public enum ReadinessResult: Equatable, Sendable {
        case ignored, notReady, ready
    }

    public private(set) var stored: StoredState
    public var state: State { stored.state }
    public var hasPendingAttempt: Bool { state.attempt != nil }

    // This is update presentation only; callers keep observation and local stop independent
    public var setupState: CloudGatewayMacSetupState? {
        switch state {
        case .prepared, .submitted: .activating
        case .approvalPending: .awaitingApproval
        case .outcomeUnknown: .checkingConnection
        case .rebootRequired: .awaitingRestart
        case .idle: nil
        case .terminal(let receipt):
            switch receipt.outcome {
            case .failed, .expired, .superseded: .updateRequired
            case .ready, .activationFinished, .legacyCompletion: .checkingConnection
            }
        }
    }

    private let now: () -> Date
    private let bootSession: () -> String
    private let persist: (StoredState) throws -> Void
    private let instance = UUID()
    private var epoch: UInt64 = 0
    // A live activation stays fenced even when the target extension already answers pings
    private var liveAttemptId: UUID?
    private var restoredAttemptId: UUID?
    private var restorationNeedsPersistence = false
    private static let receiptLifetime: TimeInterval = 600
    private static let receiptLimit = 16

    public init(
        stored: StoredState = StoredState(),
        now: @escaping () -> Date = { Date() },
        bootSession: @escaping () -> String,
        persist: @escaping (StoredState) throws -> Void
    ) throws {
        self.stored = stored
        self.now = now
        self.bootSession = bootSession
        self.persist = persist
        restoredAttemptId = stored.state.attempt?.id
        if let attempt = stored.state.attempt {
            try attempt.target.validate()
            guard !attempt.bootSession.isEmpty else { throw CloudGatewayMacControllerFailure.invalidRequest }
        }
        var restored = normalized(stored)
        if let attempt = restored.state.attempt {
            switch restored.state {
            case .submitted:
                restored.state = .outcomeUnknown(attempt)
            case .prepared(let attempt, let deadline):
                if deadline <= now() || isLaterBoot(than: attempt.bootSession) {
                    restored = terminal(.expired, attempt: attempt, in: restored)
                }
            case .approvalPending, .rebootRequired:
                if isLaterBoot(than: attempt.bootSession) { restored.state = .outcomeUnknown(attempt) }
            default: break
            }
        }
        if restored != stored {
            do { try commit(restored) }
            catch {
                // Keep local stop available while update authorization stays blocked
                self.stored = restored
                restorationNeedsPersistence = true
            }
        }
    }

    var hasRestoredAttempt: Bool {
        guard let attempt = state.attempt else { return false }
        return attempt.id == restoredAttemptId
    }

    // The controller calls this only after acquiring exclusive process ownership
    func reconcileRestoredAttempt(target: CloudGatewayMacBuildIdentity, owningAttemptId: UUID?) throws {
        guard hasRestoredAttempt, !hasLiveActivation, let attempt = state.attempt else { return }
        try target.validate()
        if attempt.target == target {
            if owningAttemptId == attempt.id { return }
            if case .rebootRequired = state { return }
        }
        let outcome: TerminalReceipt.Outcome
        if case .prepared = state { outcome = .expired }
        else { outcome = .superseded }
        try commit(terminal(outcome, attempt: attempt, in: stored))
    }

    @discardableResult
    public func begin(target: CloudGatewayMacBuildIdentity, id: UUID = UUID()) throws -> Attempt {
        try advance(target: target)
        guard !hasPendingAttempt, !stored.receipts.contains(where: { $0.id == id }) else {
            throw CloudGatewayMacControllerFailure.busy
        }
        try target.validate()
        let boot = bootSession()
        guard !boot.isEmpty else { throw CloudGatewayMacControllerFailure.unavailable }
        let attempt = Attempt(id: id, target: target, bootSession: boot)
        var next = stored
        next.state = .prepared(attempt, deadline: now().addingTimeInterval(30))
        try commit(next)
        return attempt
    }

    func prepareManaged(attemptId: UUID, target: CloudGatewayMacBuildIdentity) throws {
        if restorationNeedsPersistence { try commit(stored) }
        guard !hasLiveActivation else { throw CloudGatewayMacControllerFailure.busy }
        if let attempt = state.attempt {
            guard attempt.id == attemptId, attempt.target == target else { throw CloudGatewayMacControllerFailure.busy }
            if case .prepared(_, let deadline) = state, deadline > now() {
                if stored.managedAttemptId != attemptId {
                    var next = stored
                    next.managedAttemptId = attemptId
                    try commit(next)
                }
                return
            }
            if case .rebootRequired = state { throw CloudGatewayMacControllerFailure.busy }
            let boot = bootSession()
            guard !boot.isEmpty else { throw CloudGatewayMacControllerFailure.unavailable }
            var next = stored
            next.managedAttemptId = attemptId
            next.state = .prepared(Attempt(id: attempt.id, target: attempt.target, bootSession: boot),
                                   deadline: now().addingTimeInterval(30))
            try commit(next)
        } else {
            // The durable confirmed workflow is the owner even if its prepared attempt expired during a restart
            var next = normalized(stored)
            next.managedAttemptId = attemptId
            next.receipts.removeAll { $0.id == attemptId }
            if case .terminal(let receipt) = next.state, receipt.id == attemptId { next.state = .idle }
            guard next.state.attempt == nil else { throw CloudGatewayMacControllerFailure.busy }
            let boot = bootSession()
            guard !boot.isEmpty else { throw CloudGatewayMacControllerFailure.unavailable }
            try target.validate()
            next.state = .prepared(Attempt(id: attemptId, target: target, bootSession: boot), deadline: now().addingTimeInterval(30))
            try commit(next)
        }
    }

    func acknowledgeManagedOutcome(attemptId: UUID) throws {
        guard stored.managedAttemptId == attemptId else { return }
        var next = stored
        next.managedAttemptId = nil
        try commit(normalized(next))
    }

    public func handle(
        _ event: Event, attemptId: UUID, installedTarget: CloudGatewayMacBuildIdentity,
        canSubmit: Bool = true
    ) throws {
        if restorationNeedsPersistence { try commit(stored) }
        // A started reply authorizes OS submission, so an expired reservation must never acknowledge it
        if stored.receipts.contains(where: { $0.id == attemptId && $0.expires > now() }) {
            guard event != .started else { throw CloudGatewayMacControllerFailure.rejected }
            return
        }
        guard state.attempt?.id == attemptId else { throw CloudGatewayMacControllerFailure.rejected }
        try advance(target: installedTarget)
        if event != .started, stored.receipts.contains(where: { $0.id == attemptId && $0.expires > now() }) { return }
        guard let attempt = state.attempt, attempt.id == attemptId, attempt.target == installedTarget else {
            throw CloudGatewayMacControllerFailure.rejected
        }
        if case .rebootRequired = state {
            guard event != .started else { throw CloudGatewayMacControllerFailure.rejected }
            return
        }
        var next = stored
        switch event {
        case .started:
            guard canSubmit else { throw CloudGatewayMacControllerFailure.rejected }
            if case .prepared = state {
                next.state = .submitted(attempt, deadline: now().addingTimeInterval(120))
            } else if case .submitted = state { return }
            else { throw CloudGatewayMacControllerFailure.outcomeUnknown }
        case .approval:
            guard !isPrepared else { throw CloudGatewayMacControllerFailure.rejected }
            next.state = .approvalPending(attempt)
        case .rebootRequired:
            guard !isPrepared else { throw CloudGatewayMacControllerFailure.rejected }
            next.state = .rebootRequired(attempt)
        case .finished:
            guard !isPrepared else { throw CloudGatewayMacControllerFailure.rejected }
            next = terminal(.activationFinished, attempt: attempt, in: next)
        case .failed:
            next = terminal(.failed, attempt: attempt, in: next)
        }
        if next != stored { try commit(next) }
        if event == .started || event == .approval { liveAttemptId = attempt.id }
    }

    public func prepareReadiness(target: CloudGatewayMacBuildIdentity) throws -> ReadinessToken? {
        try advance(target: target)
        guard !hasLiveActivation else { return nil }
        if let attempt = state.attempt, attempt.target != target { return nil }
        switch state {
        case .prepared, .rebootRequired: return nil
        default:
            return ReadinessToken(instance: instance, epoch: epoch, attemptId: state.attempt?.id, target: target)
        }
    }

    // authenticatedTarget must come from the authenticated extension ping, never an OS activation callback
    public func reconcileReadiness(
        _ token: ReadinessToken,
        installedTarget: CloudGatewayMacBuildIdentity,
        authenticatedTarget: CloudGatewayMacBuildIdentity?
    ) throws -> ReadinessResult {
        guard token.instance == instance, token.epoch == epoch, token.attemptId == state.attempt?.id,
              token.target == installedTarget else { return .ignored }
        try advance(target: installedTarget)
        guard token.epoch == epoch, !hasLiveActivation else { return .ignored }
        guard authenticatedTarget == token.target else { return .notReady }
        if let attempt = state.attempt {
            guard attempt.target == token.target else { return .ignored }
            switch state {
            case .prepared, .rebootRequired: return .ignored
            default: try commit(terminal(.ready, attempt: attempt, in: stored))
            }
        }
        return .ready
    }

    private var isPrepared: Bool {
        if case .prepared = state { return true }
        return false
    }

    private var hasLiveActivation: Bool {
        guard let attempt = state.attempt, attempt.id == liveAttemptId else { return false }
        return !isLaterBoot(than: attempt.bootSession)
    }

    private func advance(target: CloudGatewayMacBuildIdentity) throws {
        if restorationNeedsPersistence { try commit(stored) }
        var next = normalized(stored)
        if let attempt = next.state.attempt {
            switch next.state {
            case .prepared(_, let deadline):
                if deadline <= now() || isLaterBoot(than: attempt.bootSession) {
                    next = terminal(.expired, attempt: attempt, in: next)
                } else if attempt.target != target {
                    next = terminal(.superseded, attempt: attempt, in: next)
                }
            case .submitted(_, let deadline):
                if deadline <= now() || isLaterBoot(than: attempt.bootSession) {
                    next.state = .outcomeUnknown(attempt)
                }
            case .approvalPending, .rebootRequired:
                if isLaterBoot(than: attempt.bootSession) { next.state = .outcomeUnknown(attempt) }
            default: break
            }
            if next.state.attempt != nil, attempt.target != target, isLaterBoot(than: attempt.bootSession) {
                next = terminal(.superseded, attempt: attempt, in: next)
            }
        }
        if next != stored { try commit(next) }
    }

    private func isLaterBoot(than previous: String) -> Bool {
        let current = bootSession()
        return !current.isEmpty && current != "unknown" && !previous.isEmpty && previous != "unknown" && current != previous
    }

    private func terminal(_ outcome: TerminalReceipt.Outcome, attempt: Attempt, in state: StoredState) -> StoredState {
        var next = state
        let receipt = TerminalReceipt(id: attempt.id, outcome: outcome, expires: now().addingTimeInterval(Self.receiptLifetime))
        next.receipts.removeAll { $0.id == attempt.id }
        next.receipts.append(receipt)
        next.state = .terminal(receipt)
        return normalized(next)
    }

    private func normalized(_ state: StoredState) -> StoredState {
        var next = state
        let owned = next.receipts.first { $0.id == next.managedAttemptId }
        next.receipts = Array(next.receipts.filter { $0.expires > now() && $0.id != next.managedAttemptId }.sorted {
            if $0.expires == $1.expires { return $0.id.uuidString < $1.id.uuidString }
            return $0.expires < $1.expires
        }.suffix(Self.receiptLimit - (owned == nil ? 0 : 1)))
        if let owned { next.receipts.append(owned) }
        if case .terminal(let receipt) = next.state {
            if receipt.expires <= now(), receipt.id != next.managedAttemptId { next.state = .idle }
            else if !next.receipts.contains(where: { $0.id == receipt.id }) {
                next.receipts = Array((next.receipts + [receipt]).suffix(Self.receiptLimit))
            }
        }
        return next
    }

    private func commit(_ next: StoredState) throws {
        try persist(next)
        stored = next
        if next.state.attempt?.id != liveAttemptId { liveAttemptId = nil }
        if next.state.attempt?.id != restoredAttemptId { restoredAttemptId = nil }
        restorationNeedsPersistence = false
        epoch &+= 1
    }
}
