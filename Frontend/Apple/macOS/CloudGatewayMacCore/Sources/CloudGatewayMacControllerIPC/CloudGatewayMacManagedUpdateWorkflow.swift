import CloudGatewayMacCore
import CloudGatewayMacIPC
import Foundation

@MainActor
public final class CloudGatewayMacManagedUpdateWorkflow {
    struct Journal: Codable, Equatable {
        var version = 1
        let id: UUID
        let target: CloudGatewayMacBuildIdentity
        var appIdentity: CloudGatewayMacBuildIdentity? = nil
        let allowDisconnect: Bool?
        let accountId: String?
        let identifier: String?
        var reconnect: Bool
        var phase: CloudGatewayMacManagedUpdateStatus.Phase
        var confirmed: Bool
        let created: Date
        var deadline: Date
        var expires: Date?
        var error: CloudGatewayMacManagedUpdateFailure?
        var warning: CloudGatewayMacManagedUpdateFailure?
    }

    private struct PendingActivationEvent {
        let id: UUID
        let event: CloudGatewayMacExtensionActivationEvent
        let received: Date
        var gatePersisted = false
    }

    private struct Revocation: Codable {
        var version = 1
        let id: UUID
    }

    var setupStateChanged: ((CloudGatewayMacSetupState) -> Void)?
    private(set) var journal: Journal?
    private var durableJournal: Journal?
    private(set) var isBlocked = false
    private var revoked: UUID?
    private let persist: (Data) throws -> Void
    private let persistRevocation: (Data) throws -> Void
    private var effects: CloudGatewayMacControllerEffects?
    private var gate: CloudGatewayMacExtensionUpdateOrchestrator?
    private var ownerIdentity: CloudGatewayMacBuildIdentity?
    private var task: Task<Void, Never>?
    private var now: () -> Date = Date.init
    private var storageFailed = false
    private var submittedHere = false
    private var reconnectSubmitted = false
    private var pendingTermination: CloudGatewayMacManagedUpdateFailure?
    private var reconnectDrainTask: Task<Void, Never>?
    private var pendingActivationEvent: PendingActivationEvent?

    public convenience init(directory: URL) {
        self.init(load: { try CloudGatewayMacControllerUpdateStorage.load(directory: directory, record: .managedUpdate) },
                  persist: { try CloudGatewayMacControllerUpdateStorage.save($0, directory: directory, record: .managedUpdate) },
                  loadRevocation: { try CloudGatewayMacControllerUpdateStorage.load(directory: directory, record: .managedUpdateRevocation) },
                  persistRevocation: { try CloudGatewayMacControllerUpdateStorage.save($0, directory: directory, record: .managedUpdateRevocation) })
    }

    init(load: () throws -> Data?, persist: @escaping (Data) throws -> Void,
         loadRevocation: () throws -> Data? = { nil }, persistRevocation: @escaping (Data) throws -> Void = { _ in }) {
        self.persist = persist
        self.persistRevocation = persistRevocation
        do {
            if let data = try load() {
                guard data.count <= 64 * 1024 else { throw CloudGatewayMacControllerFailure.invalidRequest }
                let value = try JSONDecoder().decode(Journal.self, from: data)
                try Self.validate(value)
                journal = value
                durableJournal = value
            }
            if let data = try loadRevocation() {
                guard data.count <= 1024 else { throw CloudGatewayMacControllerFailure.invalidRequest }
                let marker = try JSONDecoder().decode(Revocation.self, from: data)
                guard marker.version == 1 else { throw CloudGatewayMacControllerFailure.invalidRequest }
                revoked = marker.id
                if journal?.id == marker.id { journal?.reconnect = false }
            }
        } catch { isBlocked = true }
    }

    func configure(effects: CloudGatewayMacControllerEffects, gate: CloudGatewayMacExtensionUpdateOrchestrator,
                   ownerIdentity: CloudGatewayMacBuildIdentity? = nil) {
        self.effects = effects
        self.gate = gate
        self.ownerIdentity = ownerIdentity
        now = effects.now
        if let durableJournal { acknowledgeRecordedOutcome(durableJournal) }
    }

    var isActionable: Bool {
        pendingTermination != nil || pendingActivationEvent != nil || journal.map { !$0.phase.isTerminal } == true
    }
    var isRunning: Bool { isActionable && journal?.confirmed == true }
    var operation: CloudGatewayMacControllerOperation? { status(accountId: nil)?.operation }

    func status(accountId: String?) -> CloudGatewayMacManagedUpdateStatus? {
        guard let value = journal, value.expires.map({ $0 > now() }) ?? true else { return nil }
        let visible = value.accountId == nil || value.accountId == accountId
        return .init(id: value.id, phase: value.phase, target: value.target,
                     identifier: visible ? value.identifier : nil, reconnect: visible && value.reconnect,
                     error: visible ? value.error : value.phase == .superseded ? .superseded : nil,
                     warning: visible ? value.warning : nil)
    }

    func owns(_ id: UUID) -> Bool { status(accountId: nil)?.id == id }

    func reserve(_ request: CloudGatewayMacControllerRequest, fallbackTarget: CloudGatewayMacBuildIdentity) async -> CloudGatewayMacManagedUpdateStatus {
        if let old = journal, old.id == request.id, status(accountId: nil) != nil {
            guard old.allowDisconnect == request.allowDisconnect else {
                return rejected(request.id, target: old.target, reason: .busy)
            }
            return status(accountId: effects?.session()?.accountId)!
        }
        guard let effects, let gate, !isBlocked, !storageFailed else {
            return rejected(request.id, target: fallbackTarget, reason: .storageUnavailable)
        }
        guard !isActionable, !gate.hasPendingAttempt, !effects.activationIsPending() else {
            return rejected(request.id, target: fallbackTarget, reason: .busy)
        }
        let target: CloudGatewayMacBuildIdentity
        do { target = try effects.extensionIdentity() }
        catch { return rejected(request.id, target: fallbackTarget, reason: .invalidBundle) }
        do {
            // A matching authenticated endpoint needs neither consent nor account authorization
            try await requireInstalledOwner()
            let ready = try await authenticated(target)
            guard try effects.extensionIdentity() == target else { throw CloudGatewayMacManagedUpdateFailure.targetChanged }
            if ready {
                let value = Journal(id: request.id, target: target, appIdentity: ownerIdentity, allowDisconnect: request.allowDisconnect,
                                    accountId: nil, identifier: nil, reconnect: false, phase: .completed, confirmed: true,
                                    created: now(), deadline: now(), expires: now().addingTimeInterval(600))
                try save(value)
                setSetupState(.ready)
                return status(accountId: nil)!
            }
            guard !effects.hasPendingWork() else { throw CloudGatewayMacManagedUpdateFailure.busy }
            let registration = await effects.registrationReadiness()
            if registration == .required { throw CloudGatewayMacManagedUpdateFailure.initialSetupRequired }
            if registration == .invalidBundle || registration == .unavailable { throw CloudGatewayMacManagedUpdateFailure.invalidBundle }
            var observation = try await effects.managedUpdateObservation()
            // A disconnect already underway decides its own outcome before reservation captures intent
            if observation.profiles.contains(where: { $0.status == .disconnecting }) {
                let deadline = now().addingTimeInterval(15)
                for _ in 0..<30 {
                    if !observation.profiles.contains(where: { $0.status == .disconnecting }) { break }
                    guard now() < deadline else { throw CloudGatewayMacManagedUpdateFailure.stopTimedOut }
                    try await effects.installationTimer(.milliseconds(500))
                    observation = try await effects.managedUpdateObservation()
                }
                guard !observation.profiles.contains(where: { $0.status == .disconnecting }) else {
                    throw CloudGatewayMacManagedUpdateFailure.stopTimedOut
                }
            }
            let active = observation.profiles.filter(\.needsStop)
            if !active.isEmpty, request.allowDisconnect != true { throw CloudGatewayMacManagedUpdateFailure.disconnectRequired }
            let identifier: String?
            if active.isEmpty { identifier = nil }
            else {
                guard active.count == 1, let account = observation.accountId,
                      observation.accessAuthorized, !observation.isRestoringSession else {
                    throw CloudGatewayMacManagedUpdateFailure.signInRequired
                }
                guard observation.authorizedIdentifiers.filter({ $0 == active[0].identifier }).count == 1,
                      CloudGatewayMacControllerState.belongs(active[0].identifier, to: account) else {
                    throw CloudGatewayMacManagedUpdateFailure.configUnavailable
                }
                identifier = active[0].identifier
            }
            guard try effects.extensionIdentity() == target else { throw CloudGatewayMacManagedUpdateFailure.targetChanged }
            let value = Journal(id: request.id, target: target, appIdentity: ownerIdentity, allowDisconnect: request.allowDisconnect,
                                accountId: identifier == nil ? nil : observation.accountId, identifier: identifier,
                                reconnect: identifier != nil, phase: .prepared, confirmed: false,
                                created: now(), deadline: now().addingTimeInterval(30))
            try save(value)
            return status(accountId: observation.accountId)!
        } catch {
            return rejected(request.id, target: target, reason: failure(error))
        }
    }

    func confirm(_ id: UUID) async {
        guard var value = journal, value.id == id, value.phase == .prepared, !isBlocked, !storageFailed,
              let effects else { return }
        do {
            guard value.deadline > now() else { throw CloudGatewayMacManagedUpdateFailure.confirmationExpired }
            try await requireInstalledOwner(for: value)
            guard try effects.extensionIdentity() == value.target else { throw CloudGatewayMacManagedUpdateFailure.superseded }
            let observation = try await effects.managedUpdateObservation()
            guard journal == value else { return }
            let active = observation.profiles.filter(\.needsStop)
            if let identifier = value.identifier {
                try requireAuthorization(value, observation: observation)
                guard active.count == 1, active[0].identifier == identifier, active[0].status != .disconnecting else {
                    throw CloudGatewayMacManagedUpdateFailure.configUnavailable
                }
            } else if !active.isEmpty { throw CloudGatewayMacManagedUpdateFailure.disconnectRequired }
            value.confirmed = true
            value.phase = value.identifier == nil ? .activating : .stopping
            value.deadline = now().addingTimeInterval(30)
            try save(value)
            resume()
        } catch { finish(failure(error)) }
    }

    func expirePrepared() {
        if let value = journal, value.phase == .prepared, value.deadline <= now() { finish(.confirmationExpired) }
    }

    func retryPendingActivationEvent() {
        retryActivationEvent()
    }

    func resume() {
        if pendingActivationEvent != nil {
            retryActivationEvent()
            if pendingActivationEvent != nil { return }
        }
        guard pendingTermination == nil, task == nil, !isBlocked, !storageFailed else { return }
        if let value = journal, value.phase == .prepared, value.deadline <= now() { finish(.confirmationExpired) }
        guard isRunning else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            await advance()
        }
    }

    func suppressReconnect() {
        guard var value = journal, value.identifier != nil else { return }
        let durableReconnect = durableJournal.map {
            $0.id == value.id && !$0.phase.isTerminal && $0.reconnect && revoked != $0.id
        } ?? false
        guard !value.phase.isTerminal || durableReconnect else { return }
        value.reconnect = false
        value.warning = .reconnectSuppressed
        journal = value
        do { try save(value) }
        catch {
            do {
                try persistRevocation(JSONEncoder().encode(Revocation(id: value.id)))
                revoked = value.id
            } catch {
                journal?.warning = .storageUnavailable
            }
        }
    }

    func supersede() -> Bool {
        if reconnectSubmitted || reconnectDrainTask != nil {
            terminateAfterReconnectDrain(.superseded)
            return false
        }
        guard var value = journal, !value.phase.isTerminal else { return pendingActivationEvent == nil }
        suppressReconnect()
        value = journal ?? value
        value.reconnect = false
        value.phase = .superseded
        value.error = .superseded
        value.expires = now().addingTimeInterval(600)
        do { try save(value); return true }
        catch { return false }
    }

    private func advance() async {
        guard let effects, let gate, var value = journal, value.confirmed, !value.phase.isTerminal else { return }
        do {
            try await requireInstalledOwner(for: value)
            guard try effects.extensionIdentity() == value.target else { _ = supersede(); return }
            if revoked == value.id { suppressReconnect() }
            if case .rebootRequired(let attempt) = gate.state, attempt.id == value.id, attempt.target == value.target {
                if value.phase != .restartRequired { try transition(.restartRequired) }
                return
            }
            if gate.stored.receipts.contains(where: { $0.id == value.id && $0.outcome == .failed }) {
                throw CloudGatewayMacManagedUpdateFailure.activationFailed
            }
            if value.phase != .checkingReadiness, value.phase != .reconnecting,
               let receipt = gate.stored.receipts.first(where: {
                   $0.id == value.id && ($0.outcome == .activationFinished || $0.outcome == .ready)
               }) {
                try transition(.checkingReadiness, deadline: receipt.expires.addingTimeInterval(-480))
                value = journal!
            }
            if value.phase == .checkingReadiness, value.deadline <= now() {
                throw CloudGatewayMacManagedUpdateFailure.readinessFailed
            }
            if value.phase == .reconnecting, reconnectSubmitted {
                if value.deadline <= now() { throw CloudGatewayMacManagedUpdateFailure.timeout }
                return
            }
            var observation = try await effects.managedUpdateObservation()
            guard current(value.id) else { return }
            if try waitingForStoppingRestoration(value, observation: observation) { return }
            // Reconcile authenticated readiness before replaying any effect after restart
            if try await authenticatedThroughGate(value.target) {
                if journal?.phase == .reconnecting, reconnectSubmitted { return }
                try await reconnectOrComplete(observation: observation)
                return
            }
            guard current(value.id), let latest = journal else { return }
            value = latest
            if value.phase == .reconnecting { throw CloudGatewayMacManagedUpdateFailure.readinessFailed }
            if value.phase == .checkingReadiness {
                guard value.deadline > now() else { throw CloudGatewayMacManagedUpdateFailure.readinessFailed }
                return
            }
            if value.phase == .stopping {
                observation = try await effects.managedUpdateObservation()
                guard current(value.id), try effects.extensionIdentity() == value.target else { _ = supersede(); return }
                if try waitingForStoppingRestoration(value, observation: observation) { return }
                let active = observation.profiles.filter(\.needsStop)
                if !active.isEmpty {
                    guard let identifier = value.identifier, active.count == 1, active[0].identifier == identifier else {
                        throw CloudGatewayMacManagedUpdateFailure.reconnectSuppressed
                    }
                    if journal?.reconnect == true { try requireAuthorization(value, observation: observation) }
                    // Re-save the intent immediately before the confirmed-stop effect
                    try save(journal!)
                    let outcome = await performStop(effects, identifier: identifier)
                    guard current(value.id) else { return }
                    switch outcome {
                    case .completed: break
                    case .failed(.stopTimedOut), .unknown, .expired: throw CloudGatewayMacManagedUpdateFailure.stopTimedOut
                    default: throw CloudGatewayMacManagedUpdateFailure.vpnFailed
                    }
                    observation = try await effects.managedUpdateObservation()
                    guard current(value.id) else { return }
                }
                guard !observation.profiles.contains(where: \.needsStop), try await !effects.hasAnyActiveTunnel() else {
                    throw CloudGatewayMacManagedUpdateFailure.stopTimedOut
                }
                try transition(.activating)
            }
            guard current(value.id), let saved = journal else { return }
            value = saved
            if value.phase == .approvalRequired || value.phase == .restartRequired {
                if effects.activationIsPending() { return }
                if case .rebootRequired = gate.state { return }
            }
            if submittedHere || effects.activationIsPending() { return }
            guard !observation.profiles.contains(where: \.needsStop), try await !effects.hasAnyActiveTunnel() else {
                throw CloudGatewayMacManagedUpdateFailure.reconnectSuppressed
            }
            guard current(value.id), try effects.extensionIdentity() == value.target else { _ = supersede(); return }
            observation = try await effects.managedUpdateObservation()
            guard current(value.id), !observation.profiles.contains(where: \.needsStop) else {
                throw CloudGatewayMacManagedUpdateFailure.reconnectSuppressed
            }
            try transition(.activating)
            do {
                try gate.prepareManaged(attemptId: value.id, target: value.target)
                try gate.handle(.started, attemptId: value.id, installedTarget: value.target)
            } catch {
                if error as? CloudGatewayMacControllerFailure == .busy { throw CloudGatewayMacManagedUpdateFailure.busy }
                throw CloudGatewayMacManagedUpdateFailure.storageUnavailable
            }
            guard current(value.id), try effects.extensionIdentity() == value.target else { _ = supersede(); return }
            // Both records now authorize this exact attempt, independently of the requesting frontend
            submittedHere = true
            let accepted = effects.activateExtension(value.id, value.target) { [weak self] event in
                self?.activationEvent(event, id: value.id)
            }
            if !accepted { activationEvent(.failed(-1), id: value.id) }
        } catch { finish(failure(error)) }
    }

    private func reconnectOrComplete(observation: CloudGatewayMacManagedUpdateObservation) async throws {
        guard let effects, var value = journal else { return }
        setSetupState(.ready)
        guard value.reconnect, revoked != value.id, let identifier = value.identifier else {
            try complete()
            return
        }
        if observation.isRestoringSession {
            if value.phase != .reconnecting {
                try transition(.reconnecting, deadline: now().addingTimeInterval(30))
            } else if value.deadline <= now() { throw CloudGatewayMacManagedUpdateFailure.signInRequired }
            return
        }
        try requireAuthorization(value, observation: observation)
        guard !observation.profiles.contains(where: { $0.needsStop && $0.identifier != identifier }) else {
            suppressReconnect()
            throw CloudGatewayMacManagedUpdateFailure.reconnectSuppressed
        }
        try await requireInstalledOwner(for: value)
        guard current(value.id), try effects.extensionIdentity() == value.target else { _ = supersede(); return }
        value = journal!
        guard value.reconnect else { try complete(); return }
        try transition(.reconnecting, deadline: now().addingTimeInterval(30))
        guard journal?.reconnect == true, revoked != value.id else { try complete(); return }
        reconnectSubmitted = true
        let id = value.id
        let accepted = effects.reconnectClient(identifier) { [weak self] outcome in
            guard let self, pendingTermination == nil, current(id), journal?.phase == .reconnecting else { return }
            reconnectSubmitted = false
            switch outcome {
            case .startRequested(let actual, _), .alreadyActive(let actual, _):
                if actual == identifier { do { try complete() } catch { finish(.storageUnavailable) } }
                else { finish(.configUnavailable) }
            case .failed(let reason): finish(Self.failure(reason))
            default: finish(.vpnFailed)
            }
        }
        if !accepted, current(id), journal?.phase == .reconnecting { finish(.vpnFailed) }
    }

    private func activationEvent(_ event: CloudGatewayMacExtensionActivationEvent, id: UUID) {
        guard journal?.id == id else { return }
        if let pending = pendingActivationEvent {
            switch pending.event {
            case .completed, .failed, .restartRequired: return
            case .approvalRequired: break
            }
        }
        pendingActivationEvent = .init(id: id, event: event, received: now())
        retryActivationEvent()
    }

    private func retryActivationEvent() {
        guard var pending = pendingActivationEvent, let gate, let value = journal, value.id == pending.id else { return }
        // Keep the live fence until both records retain the callback outcome
        let gateEvent: CloudGatewayMacExtensionUpdateOrchestrator.Event
        switch pending.event {
        case .approvalRequired: gateEvent = .approval
        case .restartRequired: gateEvent = .rebootRequired
        case .completed: gateEvent = .finished
        case .failed: gateEvent = .failed
        }
        do {
            if !pending.gatePersisted {
                try gate.handle(gateEvent, attemptId: pending.id, installedTarget: value.target)
                pending.gatePersisted = true
                pendingActivationEvent = pending
            }
            if !value.phase.isTerminal {
                switch pending.event {
                case .approvalRequired: try transition(.approvalRequired)
                case .restartRequired: try transition(.restartRequired)
                case .completed:
                    try transition(.checkingReadiness, deadline: pending.received.addingTimeInterval(120))
                case .failed(let code):
                    var next = value
                    next.reconnect = false
                    next.phase = .failed
                    next.error = .activationFailed
                    next.expires = now().addingTimeInterval(600)
                    try save(next)
                    setSetupState(.failed(code: code))
                }
            }
            if pending.event != .approvalRequired { submittedHere = false }
            pendingActivationEvent = nil
        } catch {
            journal?.warning = .storageUnavailable
        }
    }

    private func performStop(_ effects: CloudGatewayMacControllerEffects, identifier: String) async -> CloudGatewayMacCommandOutcome {
        await withCheckedContinuation { continuation in
            var finished = false
            let completion: @MainActor (CloudGatewayMacCommandOutcome) -> Void = { result in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: result)
            }
            if !effects.perform(.init(action: .disconnectClient, identifier: identifier), completion), !finished { completion(.failed(.busy)) }
        }
    }

    private func requireInstalledOwner(for value: Journal? = nil) async throws {
        guard let effects, let ownerIdentity else { return }
        if let value, value.appIdentity != ownerIdentity { throw CloudGatewayMacManagedUpdateFailure.superseded }
        guard let installed = await effects.installedIdentity() else { throw CloudGatewayMacManagedUpdateFailure.invalidBundle }
        guard installed == ownerIdentity else { throw CloudGatewayMacManagedUpdateFailure.superseded }
    }

    private func authenticated(_ target: CloudGatewayMacBuildIdentity) async throws -> Bool {
        guard let effects else { return false }
        guard let version = try? await effects.ping(target) else { return false }
        return version.bundleShortVersion == target.version && version.bundleVersion == target.build && version.codeHash == target.codeHash
    }

    private func authenticatedThroughGate(_ target: CloudGatewayMacBuildIdentity) async throws -> Bool {
        guard let gate, let effects else { return false }
        let token: CloudGatewayMacExtensionUpdateOrchestrator.ReadinessToken
        do {
            guard let prepared = try gate.prepareReadiness(target: target) else { return false }
            token = prepared
        } catch { throw CloudGatewayMacManagedUpdateFailure.storageUnavailable }
        let ready = try await authenticated(target)
        let installed = try effects.extensionIdentity()
        guard installed == target else { throw CloudGatewayMacManagedUpdateFailure.superseded }
        do {
            return try gate.reconcileReadiness(token, installedTarget: installed,
                                               authenticatedTarget: ready ? target : nil) == .ready
        } catch { throw CloudGatewayMacManagedUpdateFailure.storageUnavailable }
    }

    private func waitingForStoppingRestoration(
        _ value: Journal, observation: CloudGatewayMacManagedUpdateObservation
    ) throws -> Bool {
        guard value.phase == .stopping, observation.isRestoringSession else { return false }
        guard value.deadline > now() else { throw CloudGatewayMacManagedUpdateFailure.signInRequired }
        return true
    }

    private func requireAuthorization(_ value: Journal, observation: CloudGatewayMacManagedUpdateObservation) throws {
        guard let accountId = value.accountId, observation.accountId == accountId, !observation.isRestoringSession else {
            throw CloudGatewayMacManagedUpdateFailure.signInRequired
        }
        guard observation.accessAuthorized else { throw CloudGatewayMacManagedUpdateFailure.accessDenied }
        guard let identifier = value.identifier,
              observation.authorizedIdentifiers.filter({ $0 == identifier }).count == 1 else {
            throw CloudGatewayMacManagedUpdateFailure.configUnavailable
        }
    }

    private func current(_ id: UUID) -> Bool {
        journal?.id == id && journal?.phase.isTerminal == false && pendingTermination == nil
            && pendingActivationEvent == nil && !storageFailed && !isBlocked
    }

    private func transition(_ phase: CloudGatewayMacManagedUpdateStatus.Phase, deadline: Date? = nil) throws {
        guard var value = journal else { throw CloudGatewayMacManagedUpdateFailure.storageUnavailable }
        value.phase = phase
        if let deadline { value.deadline = deadline }
        try save(value)
        switch phase {
        case .activating: setSetupState(.activating)
        case .approvalRequired: setSetupState(.awaitingApproval)
        case .restartRequired: setSetupState(.awaitingRestart)
        case .checkingReadiness: setSetupState(.checkingConnection)
        default: break
        }
    }

    private func complete() throws {
        guard var value = journal else { return }
        value.phase = .completed
        value.expires = now().addingTimeInterval(600)
        try save(value)
    }

    private func terminateAfterReconnectDrain(_ reason: CloudGatewayMacManagedUpdateFailure) {
        if pendingTermination == nil || reason == .superseded { pendingTermination = reason }
        suppressReconnect()
        guard reconnectDrainTask == nil, let effects, let identifier = journal?.identifier else { return }
        reconnectDrainTask = Task { [weak self] in
            await effects.cancelManagedReconnect(identifier)
            guard let self else { return }
            reconnectSubmitted = false
            reconnectDrainTask = nil
            let terminal = pendingTermination ?? reason
            pendingTermination = nil
            finish(terminal)
        }
    }

    private func finish(_ reason: CloudGatewayMacManagedUpdateFailure) {
        if reconnectSubmitted || reconnectDrainTask != nil {
            terminateAfterReconnectDrain(reason)
            return
        }
        guard var value = journal, !value.phase.isTerminal else { return }
        value.reconnect = false
        value.phase = reason == .superseded || reason == .targetChanged ? .superseded : .failed
        value.error = reason
        value.expires = now().addingTimeInterval(600)
        do { try save(value) }
        catch {
            storageFailed = true
            value.error = .storageUnavailable
            value.warning = .storageUnavailable
            journal = value
        }
    }

    private func setSetupState(_ state: CloudGatewayMacSetupState) {
        if let setupStateChanged { setupStateChanged(state) }
        else { effects?.setSetupState(state) }
    }

    private func save(_ value: Journal) throws {
        do {
            try Self.validate(value)
            try persist(JSONEncoder().encode(value))
            durableJournal = value
            journal = value
            acknowledgeRecordedOutcome(value)
        } catch { throw CloudGatewayMacManagedUpdateFailure.storageUnavailable }
    }

    private func acknowledgeRecordedOutcome(_ value: Journal) {
        if value.phase.isTerminal || value.phase == .checkingReadiness || value.phase == .reconnecting || value.phase == .restartRequired {
            try? gate?.acknowledgeManagedOutcome(attemptId: value.id)
        }
    }

    private func rejected(_ id: UUID, target: CloudGatewayMacBuildIdentity,
                          reason: CloudGatewayMacManagedUpdateFailure) -> CloudGatewayMacManagedUpdateStatus {
        .init(id: id, phase: .failed, target: target, error: reason)
    }

    private func failure(_ error: Error) -> CloudGatewayMacManagedUpdateFailure {
        if let reason = error as? CloudGatewayMacManagedUpdateFailure { return reason }
        if error as? CloudGatewayMacControllerFailure == .busy { return .busy }
        if error as? CloudGatewayMacConfigError == .cancelled { return .signInRequired }
        return .observationUnavailable
    }

    private static func failure(_ reason: CloudGatewayMacCommandFailure) -> CloudGatewayMacManagedUpdateFailure {
        switch reason {
        case .signInRequired, .credentialsUnavailable: .signInRequired
        case .accessDenied: .accessDenied
        case .configUnavailable, .selectionUnavailable: .configUnavailable
        case .networkUnavailable: .networkUnavailable
        case .busy: .reconnectSuppressed
        case .stopTimedOut: .stopTimedOut
        default: .vpnFailed
        }
    }

    private static func validate(_ value: Journal) throws {
        try value.target.validate()
        try value.appIdentity?.validate()
        guard value.version == 1, value.accountId.map(CloudGatewayMacControllerProtocol.validComponent) ?? true,
              value.identifier.map(CloudGatewayMacControllerProtocol.validIdentifier) ?? true,
              value.identifier == nil || value.accountId.map({ CloudGatewayMacControllerState.belongs(value.identifier!, to: $0) }) == true,
              !value.reconnect || (value.identifier != nil && value.accountId != nil && value.allowDisconnect == true),
              value.phase != .prepared || !value.confirmed,
              value.phase.isTerminal || value.phase == .prepared || value.confirmed,
              value.phase.isTerminal == (value.expires != nil),
              value.created.timeIntervalSinceReferenceDate.isFinite, value.deadline.timeIntervalSinceReferenceDate.isFinite,
              value.expires.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
    }
}

private extension CloudGatewayMacManagedUpdateStatus.Phase {
    var isTerminal: Bool { self == .completed || self == .failed || self == .superseded }
}
