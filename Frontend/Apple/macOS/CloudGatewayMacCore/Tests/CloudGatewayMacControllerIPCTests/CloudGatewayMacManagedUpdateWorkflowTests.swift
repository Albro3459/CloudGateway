import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation
import Testing
@testable import CloudGatewayMacCore
@testable import CloudGatewayMacControllerIPC

private let managedWorkflowTarget = CloudGatewayMacBuildIdentity(
    version: "1.2", build: "7", codeHash: String(repeating: "c", count: 64)
)
private let managedWorkflowReplacement = CloudGatewayMacBuildIdentity(
    version: "1.2", build: "8", codeHash: String(repeating: "d", count: 64)
)
private let managedWorkflowConfig = "account/region/original"
private let managedWorkflowOtherConfig = "account/region/other"

@MainActor
private final class ManagedWorkflowHarness {
    enum Failure: Error { case disk, observation }

    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var boot = "boot-one"
    var target = managedWorkflowTarget
    var accountId: String? = "account"
    var authorized = [managedWorkflowConfig, managedWorkflowOtherConfig]
    var accessAuthorized = true
    var restoring = false
    var profiles: [CloudGatewayMacManagedUpdateObservation.Profile] = []
    var observedProfiles: [[CloudGatewayMacManagedUpdateObservation.Profile]] = []
    var registration = CloudGatewayMacSetupState.updateRequired
    var authenticated = false
    var pingTarget: CloudGatewayMacBuildIdentity?
    var observationUnavailable = false
    var pendingActivation = false
    var holdsStop = false
    var stopResult = CloudGatewayMacCommandOutcome.completed(warning: nil)
    var reconnectResult: CloudGatewayMacCommandOutcome?
    var holdsReconnect = false
    var holdsReconnectDrain = false
    var reconnectRequests: [String] = []
    var cancellationRequests: [String] = []
    var cancelledReconnects = Set<String>()
    var pendingReconnectIdentifier: String?
    var reconnectCompletion: (@MainActor (CloudGatewayMacCommandOutcome) -> Void)?
    var reconnectDrain: CheckedContinuation<Void, Never>?
    var setup = CloudGatewayMacSetupState.updateRequired
    var journalData: Data?
    var revocationData: Data?
    var gateStored = CloudGatewayMacExtensionUpdateOrchestrator.StoredState()
    var failJournal: ((CloudGatewayMacManagedUpdateWorkflow.Journal) -> Bool)?
    var failGate: ((CloudGatewayMacExtensionUpdateOrchestrator.StoredState) -> Bool)?
    var failRevocation = false
    var observations = 0
    var pings = 0
    var stopRequests = 0
    var activations: [(UUID, CloudGatewayMacBuildIdentity)] = []
    var starts: [String] = []
    var events: [String] = []
    var stopCompletion: (@MainActor (CloudGatewayMacCommandOutcome) -> Void)?
    var activationCompletion: (@MainActor (CloudGatewayMacExtensionActivationEvent) -> Void)?
    var beforeObservation: (() -> Void)?
    var beforePing: (() -> Void)?

    func make() throws -> (CloudGatewayMacManagedUpdateWorkflow, CloudGatewayMacExtensionUpdateOrchestrator) {
        let gate = try CloudGatewayMacExtensionUpdateOrchestrator(
            stored: gateStored, now: { self.now }, bootSession: { self.boot }, persist: { next in
                if self.failGate?(next) == true { throw Failure.disk }
                self.gateStored = next
                self.events.append("gate saved")
            }
        )
        let workflow = CloudGatewayMacManagedUpdateWorkflow(load: { self.journalData }, persist: { data in
            let journal = try JSONDecoder().decode(CloudGatewayMacManagedUpdateWorkflow.Journal.self, from: data)
            if self.failJournal?(journal) == true { throw Failure.disk }
            self.journalData = data
            self.events.append("journal \(journal.phase.rawValue)")
        }, loadRevocation: { self.revocationData }, persistRevocation: { data in
            if self.failRevocation { throw Failure.disk }
            self.revocationData = data
        })
        let effects = CloudGatewayMacControllerEffects(
            snapshot: { _, _ in controllerBoundaryState() }, hasPendingWork: { false },
            perform: { request, completion in
                #expect(request.action == .disconnectClient)
                #expect(request.identifier == managedWorkflowConfig)
                self.stopRequests += 1
                self.events.append("stop")
                self.stopCompletion = completion
                if !self.holdsStop { self.finishStop(self.stopResult) }
                return true
            },
            session: {
                var fence = CloudGatewayMacSessionFence()
                fence.changeAccount(to: self.accountId)
                return fence.currentToken
            },
            refresh: { .refreshed }, prepareClient: { throw CloudGatewayMacControllerFailure.invalidRequest },
            setSetupState: { self.setup = $0 }, hasAnyActiveTunnel: { self.profiles.contains(where: \.needsStop) },
            installedIdentity: { self.target }, installationTimer: { delay in
                let parts = delay.components
                self.now.addTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
            }, extensionIdentity: { self.target }, ping: { requested in
                self.pings += 1
                self.beforePing?()
                #expect(requested == self.target)
                guard self.authenticated else { return nil }
                let identity = self.pingTarget ?? self.target
                return CloudGatewayMacExtensionVersion(infoDictionary: [
                    "CFBundleVersion": identity.build, "CFBundleShortVersionString": identity.version
                ], codeHash: identity.codeHash)
            }, registrationReadiness: { self.registration }, now: { self.now },
            managedUpdateObservation: {
                self.observations += 1
                self.beforeObservation?()
                if self.observationUnavailable { throw Failure.observation }
                if !self.observedProfiles.isEmpty { self.profiles = self.observedProfiles.removeFirst() }
                return .init(accountId: self.accountId, profiles: self.profiles, authorizedIdentifiers: self.authorized,
                             isRestoringSession: self.restoring, accessAuthorized: self.accessAuthorized)
            }, reconnectClient: { identifier, completion in
                let journal = try? self.savedJournal()
                #expect(journal?.confirmed == true)
                #expect(journal?.phase == .reconnecting)
                #expect(journal?.identifier == identifier)
                #expect(journal?.reconnect == true)
                #expect(self.authenticated)
                #expect(self.setup == .ready)
                #expect(!self.profiles.contains { $0.needsStop && $0.identifier != identifier })
                self.reconnectRequests.append(identifier)
                if self.holdsReconnect {
                    self.pendingReconnectIdentifier = identifier
                    self.reconnectCompletion = completion
                    return true
                }
                self.starts.append(identifier)
                self.events.append("start \(identifier)")
                completion(self.reconnectResult ?? .startRequested(identifier: identifier, warning: nil))
                return true
            }, cancelManagedReconnect: { identifier in
                self.cancelledReconnects.insert(identifier)
                self.cancellationRequests.append(identifier)
                if self.holdsReconnectDrain { await withCheckedContinuation { self.reconnectDrain = $0 } }
                self.finishHeldReconnect()
            }, activateExtension: { id, identity, completion in
                let journal = try? self.savedJournal()
                #expect(journal?.confirmed == true)
                #expect(journal?.phase == .activating)
                #expect(journal?.id == id)
                #expect(gate.state.attempt?.id == id)
                #expect(gate.state.attempt?.target == identity)
                #expect(!self.profiles.contains(where: { $0.needsStop }))
                self.activations.append((id, identity))
                self.events.append("activate")
                self.pendingActivation = true
                self.activationCompletion = completion
                return true
            },
            activationIsPending: { self.pendingActivation }
        )
        workflow.configure(effects: effects, gate: gate)
        return (workflow, gate)
    }

    func finishStop(_ outcome: CloudGatewayMacCommandOutcome = .completed(warning: nil)) {
        if case .completed = outcome { profiles.removeAll { $0.identifier == managedWorkflowConfig } }
        let completion = stopCompletion
        stopCompletion = nil
        completion?(outcome)
    }

    func emit(_ event: CloudGatewayMacExtensionActivationEvent) {
        switch event {
        case .completed, .failed, .restartRequired: pendingActivation = false
        case .approvalRequired: break
        }
        activationCompletion?(event)
    }

    func finishHeldReconnect() {
        guard let identifier = pendingReconnectIdentifier, let completion = reconnectCompletion else { return }
        pendingReconnectIdentifier = nil
        reconnectCompletion = nil
        if cancelledReconnects.contains(identifier) { completion(.failed(.busy)) }
        else {
            starts.append(identifier)
            completion(reconnectResult ?? .startRequested(identifier: identifier, warning: nil))
        }
    }

    func acknowledgeReconnectDrain() {
        let continuation = reconnectDrain
        reconnectDrain = nil
        continuation?.resume()
    }

    func savedJournal() throws -> CloudGatewayMacManagedUpdateWorkflow.Journal {
        try JSONDecoder().decode(CloudGatewayMacManagedUpdateWorkflow.Journal.self, from: #require(journalData))
    }

    func seed(_ phase: CloudGatewayMacManagedUpdateStatus.Phase, id: UUID = UUID(), reconnect: Bool = true,
              deadline: TimeInterval = 120) throws -> UUID {
        let terminal = phase == .completed || phase == .failed || phase == .superseded
        journalData = try JSONEncoder().encode(CloudGatewayMacManagedUpdateWorkflow.Journal(
            id: id, target: target, allowDisconnect: reconnect, accountId: reconnect ? accountId : nil,
            identifier: reconnect ? managedWorkflowConfig : nil, reconnect: reconnect, phase: phase,
            confirmed: phase != .prepared, created: now, deadline: now.addingTimeInterval(deadline),
            expires: terminal ? now.addingTimeInterval(600) : nil
        ))
        return id
    }

    func reserve(_ workflow: CloudGatewayMacManagedUpdateWorkflow, id: UUID = UUID(), consent: Bool? = true) async -> CloudGatewayMacManagedUpdateStatus {
        await workflow.reserve(.init(action: .update, id: id, allowDisconnect: consent), fallbackTarget: target)
    }
}

@MainActor
private func managedWorkflowDrive(_ workflow: CloudGatewayMacManagedUpdateWorkflow,
                                  until condition: () -> Bool) async -> Bool {
    for _ in 0..<1_000 {
        if condition() { return true }
        workflow.resume()
        await Task.yield()
    }
    return condition()
}

@MainActor
@Test func managedUpdateDisconnectedReservationNeedsConfirmationAndNeverStartsVPN() async throws {
    for consent in [false, true] {
        let harness = ManagedWorkflowHarness()
        harness.accountId = nil
        let (workflow, _) = try harness.make()
        let accepted = await harness.reserve(workflow, consent: consent)
        #expect(accepted.phase == .prepared)
        #expect(!accepted.reconnect)
        #expect(accepted.identifier == nil)
        #expect(harness.stopRequests == 0)
        #expect(harness.activations.isEmpty)
        workflow.resume()
        await Task.yield()
        #expect(harness.activations.isEmpty)
        await workflow.confirm(accepted.id)
        try #require(await managedWorkflowDrive(workflow) { harness.activations.count == 1 })
        harness.emit(.completed)
        harness.authenticated = true
        try #require(await managedWorkflowDrive(workflow) { workflow.status(accountId: nil)?.phase == .completed })
        #expect(harness.stopRequests == 0)
        #expect(harness.starts.isEmpty)
        #expect(try harness.savedJournal().reconnect == false)
    }
}

@MainActor
@Test func managedUpdateConsentAndAuthenticatedNoOpPrecedeDisruptionAndAccountChecks() async throws {
    let harness = ManagedWorkflowHarness()
    harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connecting)]
    let (workflow, _) = try harness.make()
    let rejected = await harness.reserve(workflow, consent: false)
    #expect(rejected.error == .disconnectRequired)
    #expect(harness.journalData == nil)
    #expect(harness.stopRequests == 0)
    #expect(harness.activations.isEmpty)
    harness.authenticated = true
    harness.accountId = nil
    harness.authorized = []
    harness.accessAuthorized = false
    harness.registration = .required
    let observations = harness.observations
    let noOp = await harness.reserve(workflow, consent: false)
    #expect(noOp.phase == .completed)
    #expect(!noOp.reconnect)
    #expect(harness.observations == observations)
    #expect(harness.stopRequests == 0)
    #expect(harness.activations.isEmpty)
    #expect(harness.starts.isEmpty)
}

@MainActor
@Test func managedUpdateCapturesObservedConfigAndContinuesAfterConfirmationCallerReturns() async throws {
    let harness = ManagedWorkflowHarness()
    harness.profiles = [.init(identifier: managedWorkflowConfig, status: .reasserting)]
    harness.holdsStop = true
    let (workflow, gate) = try harness.make()
    let reservation = await harness.reserve(workflow)
    #expect(reservation.identifier == managedWorkflowConfig)
    #expect(reservation.reconnect)
    let caller = Task { await workflow.confirm(reservation.id) }
    await caller.value
    caller.cancel()
    try #require(await managedWorkflowDrive(workflow) { harness.stopRequests == 1 })
    #expect(harness.activations.isEmpty)
    #expect(try harness.savedJournal().phase == .stopping)
    harness.finishStop()
    try #require(await managedWorkflowDrive(workflow) { harness.activations.count == 1 })
    #expect(harness.activations.first?.0 == reservation.id)
    #expect(gate.state.attempt?.id == reservation.id)
    #expect(harness.starts.isEmpty)
    harness.authenticated = true
    workflow.resume()
    await Task.yield()
    #expect(harness.starts.isEmpty)
    harness.emit(.completed)
    try #require(await managedWorkflowDrive(workflow) { workflow.status(accountId: harness.accountId)?.phase == .completed })
    #expect(harness.starts == [managedWorkflowConfig])
    #expect(harness.events.filter { $0 == "stop" || $0 == "activate" || $0.hasPrefix("start ") }
        == ["stop", "activate", "start \(managedWorkflowConfig)"])
}

@MainActor
@Test func managedUpdateConfirmationRejectsChangedProfileOrNewActiveProfileWithoutRecapture() async throws {
    for initiallyActive in [false, true] {
        let harness = ManagedWorkflowHarness()
        if initiallyActive { harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)] }
        let (workflow, _) = try harness.make()
        let reservation = await harness.reserve(workflow)
        harness.profiles = [.init(identifier: managedWorkflowOtherConfig, status: .connected)]
        await workflow.confirm(reservation.id)
        #expect(workflow.status(accountId: harness.accountId)?.error == (initiallyActive ? .configUnavailable : .disconnectRequired))
        #expect(workflow.journal?.identifier == (initiallyActive ? managedWorkflowConfig : nil))
        #expect(harness.stopRequests == 0)
        #expect(harness.activations.isEmpty)
        #expect(harness.starts.isEmpty)
        #expect(harness.profiles.first?.identifier == managedWorkflowOtherConfig)
    }
}

@MainActor
@Test func managedUpdateWaitsForExistingDisconnectBeforeChoosingReconnectIntent() async throws {
    let harness = ManagedWorkflowHarness()
    harness.observedProfiles = [[.init(identifier: managedWorkflowConfig, status: .disconnecting)], []]
    let (workflow, _) = try harness.make()
    let reservation = await harness.reserve(workflow, consent: false)
    #expect(reservation.phase == .prepared)
    #expect(!reservation.reconnect)
    #expect(reservation.identifier == nil)
    #expect(harness.observations == 2)
    #expect(harness.stopRequests == 0)
}

@MainActor
@Test func managedUpdateIdempotencyKeepsReservationAndRejectsDifferentConsentOrOperation() async throws {
    let harness = ManagedWorkflowHarness()
    harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
    let (workflow, _) = try harness.make()
    let accepted = await harness.reserve(workflow)
    let saved = harness.journalData
    let observations = harness.observations
    #expect(await harness.reserve(workflow, id: accepted.id) == accepted)
    #expect(harness.observations == observations)
    #expect(await harness.reserve(workflow, id: accepted.id, consent: false).error == .busy)
    #expect(await harness.reserve(workflow).error == .busy)
    #expect(harness.journalData == saved)
    #expect(harness.stopRequests == 0)
    #expect(harness.activations.isEmpty)
}

@MainActor
@Test func managedUpdateRestoredUnconfirmedAndExpiredReservationsNeverRunEffects() async throws {
    for expired in [false, true] {
        let harness = ManagedWorkflowHarness()
        let id = try harness.seed(.prepared, deadline: expired ? -1 : 30)
        let (workflow, _) = try harness.make()
        workflow.resume()
        await Task.yield()
        #expect(workflow.status(accountId: harness.accountId)?.phase == (expired ? .failed : .prepared))
        if expired { #expect(workflow.status(accountId: harness.accountId)?.error == .confirmationExpired) }
        #expect(workflow.owns(id))
        #expect(harness.stopRequests == 0)
        #expect(harness.activations.isEmpty)
        #expect(harness.starts.isEmpty)
    }
}

@MainActor
@Test func managedUpdateRestartReconcilesAuthenticatedTargetBeforeReplayingEachSavedEffect() async throws {
    for phase in [CloudGatewayMacManagedUpdateStatus.Phase.stopping, .activating, .approvalRequired,
                  .restartRequired, .checkingReadiness, .reconnecting] {
        let harness = ManagedWorkflowHarness()
        let id = try harness.seed(phase)
        harness.authenticated = true
        let (workflow, _) = try harness.make()
        try #require(await managedWorkflowDrive(workflow) { workflow.status(accountId: harness.accountId)?.phase == .completed })
        #expect(workflow.owns(id))
        #expect(harness.starts == [managedWorkflowConfig])
        #expect(harness.stopRequests == 0)
        #expect(harness.activations.isEmpty)
    }
}

@MainActor
@Test func managedUpdateDiskFailurePreventsStopActivationAndReconnectAtTheirBoundaries() async throws {
    for boundary in ["stop", "activate", "start"] {
        let harness = ManagedWorkflowHarness()
        harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
        let (workflow, _) = try harness.make()
        let reservation = await harness.reserve(workflow)
        if boundary == "stop" { harness.failJournal = { $0.phase == .stopping } }
        if boundary == "activate" { harness.failJournal = { $0.phase == .activating } }
        await workflow.confirm(reservation.id)
        if boundary == "start" {
            try #require(await managedWorkflowDrive(workflow) { harness.activations.count == 1 })
            harness.emit(.completed)
            harness.failJournal = { $0.phase == .reconnecting }
            harness.authenticated = true
        }
        try #require(await managedWorkflowDrive(workflow) { workflow.status(accountId: harness.accountId)?.phase == .failed })
        #expect(workflow.status(accountId: harness.accountId)?.error == .storageUnavailable)
        #expect(harness.stopRequests == (boundary == "stop" ? 0 : 1))
        #expect(harness.activations.count == (boundary == "start" ? 1 : 0))
        #expect(harness.starts.isEmpty)
    }
}

@MainActor
@Test func managedUpdateFailedStopCannotSubmitReplacement() async throws {
    let harness = ManagedWorkflowHarness()
    harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
    harness.stopResult = .failed(.stopTimedOut)
    let (workflow, _) = try harness.make()
    let reservation = await harness.reserve(workflow)
    await workflow.confirm(reservation.id)
    try #require(await managedWorkflowDrive(workflow) { workflow.status(accountId: harness.accountId)?.phase == .failed })
    #expect(workflow.status(accountId: harness.accountId)?.error == .stopTimedOut)
    #expect(harness.profiles.first?.identifier == managedWorkflowConfig)
    #expect(harness.activations.isEmpty)
    #expect(harness.starts.isEmpty)
}

@MainActor
@Test func managedUpdateScopedStopPreservesAnotherProfileThatAppearsBeforeStopCompletes() async throws {
    let harness = ManagedWorkflowHarness()
    harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
    harness.holdsStop = true
    let (workflow, _) = try harness.make()
    let reservation = await harness.reserve(workflow)
    await workflow.confirm(reservation.id)
    try #require(await managedWorkflowDrive(workflow) { harness.stopRequests == 1 })
    harness.profiles.append(.init(identifier: managedWorkflowOtherConfig, status: .connected))
    harness.finishStop()
    try #require(await managedWorkflowDrive(workflow) { workflow.journal?.phase == .failed })
    #expect(harness.profiles.map(\.identifier) == [managedWorkflowOtherConfig])
    #expect(harness.stopRequests == 1)
    #expect(harness.activations.isEmpty)
    #expect(harness.starts.isEmpty)
}

@MainActor
@Test func managedUpdateApprovalAndRestartRemainRunningWithoutReconnectOrDuplicateSubmission() async throws {
    for event in [CloudGatewayMacExtensionActivationEvent.approvalRequired, .restartRequired] {
        let harness = ManagedWorkflowHarness()
        let (workflow, _) = try harness.make()
        let reservation = await harness.reserve(workflow)
        await workflow.confirm(reservation.id)
        try #require(await managedWorkflowDrive(workflow) { harness.activations.count == 1 })
        harness.emit(event)
        let expected: CloudGatewayMacManagedUpdateStatus.Phase = event == .approvalRequired ? .approvalRequired : .restartRequired
        #expect(workflow.status(accountId: nil)?.phase == expected)
        #expect(workflow.operation?.state == .running)
        #expect(workflow.isRunning)
        harness.authenticated = true
        for _ in 0..<5 { workflow.resume(); await Task.yield() }
        #expect(workflow.status(accountId: nil)?.phase == expected)
        #expect(harness.activations.count == 1)
        #expect(harness.starts.isEmpty)
        harness.pendingActivation = false
        harness.boot = "boot-two"
        let (restored, _) = try harness.make()
        try #require(await managedWorkflowDrive(restored) { restored.status(accountId: nil)?.phase == .completed })
        #expect(harness.activations.count == 1)
        #expect(harness.starts.isEmpty)
    }
}

@MainActor
@Test func managedUpdateOSCompletionStillRequiresAuthenticatedTargetAndHasReadinessDeadline() async throws {
    let harness = ManagedWorkflowHarness()
    harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
    let (workflow, _) = try harness.make()
    let reservation = await harness.reserve(workflow)
    await workflow.confirm(reservation.id)
    try #require(await managedWorkflowDrive(workflow) { harness.activations.count == 1 })
    harness.emit(.completed)
    let deadline = try harness.savedJournal().deadline
    #expect(deadline == harness.now.addingTimeInterval(120))
    harness.authenticated = true
    harness.pingTarget = managedWorkflowReplacement
    harness.now = deadline.addingTimeInterval(-1)
    for _ in 0..<5 { workflow.resume(); await Task.yield() }
    #expect(workflow.status(accountId: harness.accountId)?.phase == .checkingReadiness)
    #expect(harness.starts.isEmpty)
    harness.now = deadline
    try #require(await managedWorkflowDrive(workflow) { workflow.status(accountId: harness.accountId)?.phase == .failed })
    #expect(workflow.status(accountId: harness.accountId)?.error == .readinessFailed)
    #expect(harness.pings > 1)
    #expect(harness.starts.isEmpty)
    #expect(harness.profiles.isEmpty)
}

@MainActor
@Test func managedUpdateNewProfileAndAuthorizationChangesPreventCapturedReconnect() async throws {
    for changed in ["profile", "account", "access", "inventory"] {
        let harness = ManagedWorkflowHarness()
        harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
        let (workflow, _) = try harness.make()
        let reservation = await harness.reserve(workflow)
        await workflow.confirm(reservation.id)
        try #require(await managedWorkflowDrive(workflow) { harness.activations.count == 1 })
        switch changed {
        case "profile": harness.profiles = [.init(identifier: managedWorkflowOtherConfig, status: .connected)]
        case "account": harness.accountId = "other-account"
        case "access": harness.accessAuthorized = false
        default: harness.authorized = []
        }
        harness.emit(.completed)
        harness.authenticated = true
        try #require(await managedWorkflowDrive(workflow) { workflow.journal?.phase == .failed })
        #expect(harness.starts.isEmpty)
        #expect(harness.stopRequests == 1)
        if changed == "profile" { #expect(harness.profiles.first?.identifier == managedWorkflowOtherConfig) }
    }
}

@MainActor
@Test func managedUpdateRevocationMarkerSuppressesReconnectAfterFailedJournalWriteAndRestart() async throws {
    let harness = ManagedWorkflowHarness()
    _ = try harness.seed(.activating)
    let (workflow, _) = try harness.make()
    harness.failJournal = { !$0.reconnect }
    workflow.suppressReconnect()
    #expect(workflow.journal?.reconnect == false)
    #expect(harness.revocationData != nil)
    #expect(try harness.savedJournal().reconnect)
    harness.failJournal = nil
    harness.authenticated = true
    let (restored, _) = try harness.make()
    try #require(await managedWorkflowDrive(restored) { restored.status(accountId: harness.accountId)?.phase == .completed })
    #expect(restored.journal?.reconnect == false)
    #expect(harness.starts.isEmpty)
    #expect(harness.stopRequests == 0)
}

@MainActor
@Test func managedUpdateFailedSuppressionWritesKeepLocalIntentOffAndExposeDurabilityWarning() async throws {
    let harness = ManagedWorkflowHarness()
    _ = try harness.seed(.activating)
    let (workflow, _) = try harness.make()
    harness.failJournal = { _ in true }
    harness.failRevocation = true
    workflow.suppressReconnect()
    #expect(workflow.status(accountId: harness.accountId)?.reconnect == false)
    #expect(workflow.status(accountId: harness.accountId)?.warning == .storageUnavailable)
    #expect(harness.revocationData == nil)
    #expect(harness.starts.isEmpty)
}

@MainActor
@Test func managedUpdateTargetChangeSupersedesConfirmedWorkWithoutStartingNewArtifact() async throws {
    let harness = ManagedWorkflowHarness()
    let id = try harness.seed(.activating)
    harness.target = managedWorkflowReplacement
    let (workflow, _) = try harness.make()
    try #require(await managedWorkflowDrive(workflow) { workflow.status(accountId: harness.accountId)?.phase == .superseded })
    #expect(workflow.owns(id))
    #expect(workflow.status(accountId: harness.accountId)?.target == managedWorkflowTarget)
    #expect(workflow.journal?.reconnect == false)
    #expect(harness.stopRequests == 0)
    #expect(harness.activations.isEmpty)
    #expect(harness.starts.isEmpty)
}

@MainActor
@Test func managedUpdatePartialAttemptPersistenceNeverAuthorizesOSSubmission() async throws {
    for failureAtSubmission in [false, true] {
        let harness = ManagedWorkflowHarness()
        harness.failGate = { stored in
            if failureAtSubmission, case .submitted = stored.state { return true }
            if !failureAtSubmission, case .prepared = stored.state { return true }
            return false
        }
        let (workflow, _) = try harness.make()
        let reservation = await harness.reserve(workflow)
        await workflow.confirm(reservation.id)
        try #require(await managedWorkflowDrive(workflow) { workflow.status(accountId: nil)?.phase == .failed })
        #expect(harness.activations.isEmpty)
        #expect(harness.starts.isEmpty)
        #expect(workflow.status(accountId: nil)?.error == .storageUnavailable)
    }
}

@MainActor
@Test func managedUpdateRestoresPartialTwoRecordStateWithSharedAttemptID() async throws {
    for submitted in [false, true] {
        let harness = ManagedWorkflowHarness()
        let id = try harness.seed(.activating, reconnect: false)
        let attempt = CloudGatewayMacExtensionUpdateOrchestrator.Attempt(id: id, target: harness.target, bootSession: harness.boot)
        harness.gateStored.state = submitted ? .submitted(attempt, deadline: harness.now.addingTimeInterval(120))
            : .prepared(attempt, deadline: harness.now.addingTimeInterval(30))
        let (workflow, gate) = try harness.make()
        try #require(await managedWorkflowDrive(workflow) { harness.activations.count == 1 })
        #expect(harness.activations.first?.0 == id)
        #expect(gate.state.attempt?.id == id)
        harness.emit(.completed)
        harness.authenticated = true
        try #require(await managedWorkflowDrive(workflow) { workflow.status(accountId: nil)?.phase == .completed })
        #expect(harness.starts.isEmpty)
        #expect(harness.stopRequests == 0)
    }
}

@MainActor
@Test func managedUpdateOrphanAttemptAndCorruptJournalBlockAutomaticWork() async throws {
    let orphan = ManagedWorkflowHarness()
    let attempt = CloudGatewayMacExtensionUpdateOrchestrator.Attempt(id: UUID(), target: orphan.target, bootSession: orphan.boot)
    orphan.gateStored.state = .approvalPending(attempt)
    let (workflow, _) = try orphan.make()
    #expect(await orphan.reserve(workflow).error == .busy)
    workflow.resume()
    await Task.yield()
    #expect(orphan.starts.isEmpty)
    #expect(orphan.activations.isEmpty)

    for invalid in [Data("corrupt".utf8), Data(repeating: 32, count: 65 * 1024)] {
        let harness = ManagedWorkflowHarness()
        harness.journalData = invalid
        let (blocked, _) = try harness.make()
        #expect(blocked.isBlocked)
        #expect(await harness.reserve(blocked).error == .storageUnavailable)
        blocked.resume()
        await Task.yield()
        #expect(harness.stopRequests == 0)
        #expect(harness.starts.isEmpty)
        #expect(harness.activations.isEmpty)
    }
}

@MainActor
@Test func managedUpdateUnknownVersionAndExpiredTerminalDoNotBecomeWorkAgain() async throws {
    let corrupt = ManagedWorkflowHarness()
    _ = try corrupt.seed(.activating)
    let corruptData = try #require(corrupt.journalData)
    var record = try #require(try JSONSerialization.jsonObject(with: corruptData) as? [String: Any])
    record["version"] = 999
    corrupt.journalData = try JSONSerialization.data(withJSONObject: record)
    let (blocked, _) = try corrupt.make()
    #expect(blocked.isBlocked)
    #expect(await corrupt.reserve(blocked).error == .storageUnavailable)

    let expired = ManagedWorkflowHarness()
    let id = try expired.seed(.completed)
    expired.now.addTimeInterval(601)
    let (terminal, _) = try expired.make()
    terminal.resume()
    await Task.yield()
    #expect(!terminal.owns(id))
    #expect(terminal.status(accountId: expired.accountId) == nil)
    #expect(expired.stopRequests == 0)
    #expect(expired.activations.isEmpty)
    #expect(expired.starts.isEmpty)
}

@MainActor
@Test func managedUpdatePreflightFailsClosedForSetupObservationAndChangedSignedTarget() async throws {
    for missing in ["setup", "observation", "target"] {
        let harness = ManagedWorkflowHarness()
        let (workflow, _) = try harness.make()
        let expected: CloudGatewayMacManagedUpdateFailure
        switch missing {
        case "setup":
            harness.registration = .required
            expected = .initialSetupRequired
        case "observation":
            harness.observationUnavailable = true
            expected = .observationUnavailable
        default:
            harness.beforeObservation = { harness.target = managedWorkflowReplacement }
            expected = .targetChanged
        }
        let rejected = await harness.reserve(workflow)
        #expect(rejected.error == expected)
        #expect(harness.journalData == nil)
        #expect(harness.stopRequests == 0)
        #expect(harness.activations.isEmpty)
        #expect(harness.starts.isEmpty)
    }
}

@MainActor
@Test func managedUpdateWrongReconnectResultIsFailureAndOtherSessionsCannotReadCapturedOutcome() async throws {
    let harness = ManagedWorkflowHarness()
    _ = try harness.seed(.reconnecting)
    harness.authenticated = true
    harness.reconnectResult = .startRequested(identifier: managedWorkflowOtherConfig, warning: nil)
    let (workflow, _) = try harness.make()
    try #require(await managedWorkflowDrive(workflow) { workflow.status(accountId: harness.accountId)?.phase == .failed })
    #expect(harness.starts == [managedWorkflowConfig])
    #expect(workflow.status(accountId: harness.accountId)?.error == .configUnavailable)
    #expect(workflow.status(accountId: harness.accountId)?.identifier == managedWorkflowConfig)
    for account in [Optional<String>.none, "someone-else"] {
        let redacted = try #require(workflow.status(accountId: account))
        #expect(redacted.identifier == nil)
        #expect(redacted.error == nil)
        #expect(redacted.warning == nil)
        #expect(!redacted.reconnect)
        #expect(redacted.phase == .failed)
    }
}

@MainActor
@Test func managedUpdateNewStopRevokesPersistedReconnectAfterUnsavedTerminalFailure() async throws {
    let harness = ManagedWorkflowHarness()
    let id = try harness.seed(.activating)
    var failedWrites: [CloudGatewayMacManagedUpdateStatus.Phase] = []
    harness.failJournal = { journal in
        failedWrites.append(journal.phase)
        return true
    }
    let (workflow, _) = try harness.make()
    try #require(await managedWorkflowDrive(workflow) { workflow.journal?.phase == .failed })
    #expect(failedWrites == [.activating, .failed])
    #expect(!workflow.isActionable)
    #expect(workflow.journal?.reconnect == false)
    #expect(try harness.savedJournal().phase == .activating)
    #expect(try harness.savedJournal().reconnect)

    workflow.suppressReconnect()
    let markerData = try #require(harness.revocationData)
    let marker = try #require(try JSONSerialization.jsonObject(with: markerData) as? [String: Any])
    #expect((marker["id"] as? String).flatMap(UUID.init(uuidString:)) == id)
    #expect(try harness.savedJournal().reconnect)
    #expect(harness.starts.isEmpty)

    harness.failJournal = nil
    harness.authenticated = true
    let (restored, _) = try harness.make()
    try #require(await managedWorkflowDrive(restored) { restored.journal?.phase == .completed })
    #expect(restored.journal?.id == id)
    #expect(restored.journal?.reconnect == false)
    #expect(harness.starts.isEmpty)
    #expect(harness.activations.isEmpty)
    #expect(harness.stopRequests == 0)
}

@MainActor
@Test func managedUpdateRestoredStopWaitsForAuthRestorationThenResumesCapturedConnection() async throws {
    let harness = ManagedWorkflowHarness()
    let id = try harness.seed(.stopping, deadline: 30)
    let deadline = try harness.savedJournal().deadline
    harness.accountId = nil
    harness.restoring = true
    harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
    let (workflow, _) = try harness.make()
    for _ in 0..<20 { workflow.resume(); await Task.yield() }
    #expect(workflow.isRunning)
    #expect(workflow.journal?.phase == .stopping)
    #expect(workflow.journal?.deadline == deadline)
    #expect(workflow.journal?.error == nil)
    #expect(harness.observations > 0)
    #expect(harness.stopRequests == 0)
    #expect(harness.activations.isEmpty)
    #expect(harness.starts.isEmpty)

    harness.now = deadline.addingTimeInterval(-1)
    harness.accountId = "account"
    harness.restoring = false
    try #require(await managedWorkflowDrive(workflow) { harness.activations.count == 1 })
    #expect(harness.stopRequests == 1)
    #expect(harness.activations.first?.0 == id)
    harness.emit(.completed)
    harness.authenticated = true
    try #require(await managedWorkflowDrive(workflow) { workflow.journal?.phase == .completed })
    #expect(harness.starts == [managedWorkflowConfig])
}

@MainActor
@Test func managedUpdateRestoredStopAuthWaitExpiresAtSavedDeadlineWithoutEffects() async throws {
    let harness = ManagedWorkflowHarness()
    _ = try harness.seed(.stopping, deadline: 30)
    let deadline = try harness.savedJournal().deadline
    harness.accountId = nil
    harness.restoring = true
    harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
    let (workflow, _) = try harness.make()
    for _ in 0..<20 { workflow.resume(); await Task.yield() }
    #expect(workflow.isRunning)
    #expect(workflow.journal?.deadline == deadline)
    harness.now = deadline
    try #require(await managedWorkflowDrive(workflow) { workflow.journal?.phase == .failed })
    #expect(workflow.journal?.error == .signInRequired)
    #expect(workflow.journal?.reconnect == false)
    #expect(harness.stopRequests == 0)
    #expect(harness.activations.isEmpty)
    #expect(harness.starts.isEmpty)
    #expect(harness.profiles.first?.identifier == managedWorkflowConfig)
}

@MainActor
@Test func managedUpdateSubmittedReconnectDrainsBeforeTimeoutOrSupersessionReleasesOwnership() async throws {
    for superseded in [false, true] {
        let harness = ManagedWorkflowHarness()
        harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
        harness.holdsReconnect = true
        harness.holdsReconnectDrain = true
        let (workflow, _) = try harness.make()
        let reservation = await harness.reserve(workflow)
        await workflow.confirm(reservation.id)
        try #require(await managedWorkflowDrive(workflow) { harness.activations.count == 1 })
        harness.emit(.completed)
        harness.authenticated = true
        try #require(await managedWorkflowDrive(workflow) { harness.reconnectRequests.count == 1 })
        let oldCompletion = try #require(harness.reconnectCompletion)
        #expect(workflow.journal?.phase == .reconnecting)
        #expect(harness.starts.isEmpty)

        if superseded { #expect(!workflow.supersede()) }
        else { harness.now = try harness.savedJournal().deadline }
        try #require(await managedWorkflowDrive(workflow) { !harness.cancellationRequests.isEmpty })
        #expect(harness.cancellationRequests == [managedWorkflowConfig])
        #expect(workflow.isActionable)
        #expect(workflow.isRunning)
        #expect(try harness.savedJournal().reconnect == false)
        #expect(await harness.reserve(workflow).error == .busy)
        oldCompletion(.startRequested(identifier: managedWorkflowConfig, warning: nil))
        #expect(workflow.journal?.phase != .completed)
        #expect(workflow.isActionable)
        #expect(harness.starts.isEmpty)

        harness.acknowledgeReconnectDrain()
        try #require(await managedWorkflowDrive(workflow) { !workflow.isActionable })
        #expect(workflow.journal?.phase == (superseded ? .superseded : .failed))
        #expect(workflow.journal?.error == (superseded ? .superseded : .timeout))
        #expect(harness.reconnectRequests == [managedWorkflowConfig])
        #expect(harness.cancellationRequests == [managedWorkflowConfig])
        #expect(harness.starts.isEmpty)
        #expect(harness.pendingReconnectIdentifier == nil)
        #expect(harness.stopRequests == 1)
        #expect(harness.activations.count == 1)
        oldCompletion(.alreadyActive(identifier: managedWorkflowConfig, warning: nil))
        #expect(workflow.journal?.phase == (superseded ? .superseded : .failed))
    }
}

@MainActor
@Test func managedUpdateTerminalActivationEventRetriesGatePersistenceBeforeReadinessOrRelease() async throws {
    for event in [CloudGatewayMacExtensionActivationEvent.completed, .failed(42), .restartRequired] {
        let harness = ManagedWorkflowHarness()
        harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
        let (workflow, gate) = try harness.make()
        let reservation = await harness.reserve(workflow)
        await workflow.confirm(reservation.id)
        try #require(await managedWorkflowDrive(workflow) { harness.activations.count == 1 })
        var failedGateWrites = 0
        harness.failGate = { _ in failedGateWrites += 1; return true }
        let pings = harness.pings
        harness.emit(event)
        #expect(!harness.pendingActivation)
        harness.authenticated = true
        try #require(await managedWorkflowDrive(workflow) { failedGateWrites >= 2 })
        #expect(workflow.isActionable)
        #expect(gate.hasPendingAttempt)
        #expect(harness.pings == pings)
        #expect(harness.starts.isEmpty)
        #expect(harness.activations.count == 1)
        #expect(await harness.reserve(workflow).error == .busy)

        harness.authenticated = false
        harness.failGate = nil
        switch event {
        case .completed:
            try #require(await managedWorkflowDrive(workflow) { workflow.journal?.phase == .checkingReadiness })
            #expect(!gate.hasPendingAttempt)
            #expect(try gate.prepareReadiness(target: harness.target) != nil)
            #expect(harness.starts.isEmpty)
            harness.authenticated = true
            try #require(await managedWorkflowDrive(workflow) { workflow.journal?.phase == .completed })
            #expect(harness.starts == [managedWorkflowConfig])
        case .failed:
            try #require(await managedWorkflowDrive(workflow) { workflow.journal?.phase == .failed && !workflow.isActionable })
            #expect(workflow.journal?.error == .activationFailed)
            #expect(!gate.hasPendingAttempt)
            #expect(try gate.prepareReadiness(target: harness.target) != nil)
            #expect(harness.starts.isEmpty)
            #expect(await harness.reserve(workflow).phase == .prepared)
        case .restartRequired:
            try #require(await managedWorkflowDrive(workflow) { workflow.journal?.phase == .restartRequired })
            #expect(try gate.prepareReadiness(target: harness.target) == nil)
            harness.authenticated = true
            for _ in 0..<10 { workflow.resume(); await Task.yield() }
            #expect(workflow.journal?.phase == .restartRequired)
            #expect(harness.starts.isEmpty)
            harness.boot = "boot-after-retry"
            let (restored, _) = try harness.make()
            try #require(await managedWorkflowDrive(restored) { restored.journal?.phase == .completed })
            #expect(harness.starts == [managedWorkflowConfig])
        case .approvalRequired:
            Issue.record("Expected a terminal OS activation callback")
        }
        #expect(harness.activations.count == 1)
        #expect(harness.stopRequests == 1)
    }
}

@MainActor
@Test(arguments: [CloudGatewayMacExtensionActivationEvent.completed, .failed(42)])
func managedUpdateRetriesItsJournalAfterTheGateReceiptExpires(event: CloudGatewayMacExtensionActivationEvent) async throws {
    let harness = ManagedWorkflowHarness()
    let (workflow, gate) = try harness.make()
    let reservation = await harness.reserve(workflow, consent: false)
    await workflow.confirm(reservation.id)
    try #require(await managedWorkflowDrive(workflow) { harness.activations.count == 1 })
    harness.failJournal = { _ in true }
    harness.emit(event)
    #expect(!gate.hasPendingAttempt)
    #expect(workflow.isActionable)
    harness.now.addTimeInterval(601)
    harness.failJournal = nil
    try #require(await managedWorkflowDrive(workflow) { !workflow.isActionable })
    #expect(workflow.journal?.phase == .failed)
    #expect(workflow.journal?.error == (event == .completed ? .readinessFailed : .activationFailed))
    #expect(harness.activations.count == 1)
    #expect(harness.starts.isEmpty)
}

@MainActor
@Test(arguments: [CloudGatewayMacExtensionActivationEvent.completed, .failed(42), .restartRequired])
func managedUpdateRestoresTheGateOutcomeWhenItsJournalWriteWasInterrupted(event: CloudGatewayMacExtensionActivationEvent) async throws {
    let harness = ManagedWorkflowHarness()
    harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
    let (original, _) = try harness.make()
    let reservation = await harness.reserve(original)
    await original.confirm(reservation.id)
    try #require(await managedWorkflowDrive(original) { harness.activations.count == 1 })
    harness.failJournal = { _ in true }
    harness.emit(event)
    #expect(try harness.savedJournal().phase == .activating)
    harness.failJournal = nil
    let (restored, _) = try harness.make()
    switch event {
    case .restartRequired:
        try #require(await managedWorkflowDrive(restored) { restored.journal?.phase == .restartRequired })
        #expect(restored.journal?.reconnect == true)
        #expect(harness.starts.isEmpty)
        harness.boot = "next-boot"
        harness.authenticated = true
        let (afterRestart, _) = try harness.make()
        try #require(await managedWorkflowDrive(afterRestart) { afterRestart.journal?.phase == .completed })
        #expect(harness.starts == [managedWorkflowConfig])
    case .failed:
        try #require(await managedWorkflowDrive(restored) { restored.journal?.phase == .failed })
        #expect(restored.journal?.error == .activationFailed)
        #expect(harness.starts.isEmpty)
    case .completed:
        try #require(await managedWorkflowDrive(restored) { restored.journal?.phase == .checkingReadiness })
        harness.authenticated = true
        try #require(await managedWorkflowDrive(restored) { restored.journal?.phase == .completed })
        #expect(harness.starts == [managedWorkflowConfig])
    case .approvalRequired:
        Issue.record("Expected a terminal activation outcome")
    }
    #expect(harness.activations.count == 1)
    #expect(harness.stopRequests == 1)
}

@MainActor
@Test(arguments: [CloudGatewayMacExtensionActivationEvent.approvalRequired, .restartRequired])
func managedUpdateResubmitsAfterRebootWhenItsFirstReadinessProbeIsUnavailable(event: CloudGatewayMacExtensionActivationEvent) async throws {
    let harness = ManagedWorkflowHarness()
    harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
    let (original, _) = try harness.make()
    let reservation = await harness.reserve(original)
    await original.confirm(reservation.id)
    try #require(await managedWorkflowDrive(original) { harness.activations.count == 1 })
    harness.emit(event)
    harness.pendingActivation = false
    harness.boot = "recovery-boot"
    let (restored, gate) = try harness.make()
    try #require(await managedWorkflowDrive(restored) { harness.activations.count == 2 })
    #expect(restored.journal?.phase == .activating)
    #expect(restored.journal?.reconnect == true)
    #expect(gate.state.attempt?.bootSession == "recovery-boot")
    #expect(harness.activations.map(\.0) == [reservation.id, reservation.id])
    #expect(harness.stopRequests == 1)
    #expect(harness.starts.isEmpty)
    harness.emit(.completed)
    harness.authenticated = true
    try #require(await managedWorkflowDrive(restored) { restored.journal?.phase == .completed })
    #expect(harness.starts == [managedWorkflowConfig])
    #expect(harness.stopRequests == 1)
}

@MainActor
@Test(arguments: [121.0, 601.0])
func managedUpdateRestoresUnacknowledgedOutcomesBeforeReadinessEvenAfterReceiptRetention(delay: TimeInterval) async throws {
    for event in [CloudGatewayMacExtensionActivationEvent.completed, .failed(42)] {
        let harness = ManagedWorkflowHarness()
        harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
        let (original, _) = try harness.make()
        let reservation = await harness.reserve(original)
        await original.confirm(reservation.id)
        try #require(await managedWorkflowDrive(original) { harness.activations.count == 1 })
        harness.failJournal = { _ in true }
        harness.emit(event)
        #expect(try harness.savedJournal().phase == .activating)
        #expect(harness.gateStored.managedAttemptId == reservation.id)
        harness.now.addTimeInterval(delay)
        harness.failJournal = nil
        harness.authenticated = true
        let (restored, gate) = try harness.make()
        #expect(gate.stored.receipts.contains { $0.id == reservation.id })
        let pings = harness.pings
        try #require(await managedWorkflowDrive(restored) { restored.journal?.phase == .failed })
        #expect(restored.journal?.error == (event == .completed ? .readinessFailed : .activationFailed))
        #expect(harness.pings == pings)
        #expect(harness.activations.count == 1)
        #expect(harness.starts.isEmpty)
        #expect(harness.stopRequests == 1)
        #expect(gate.stored.managedAttemptId == nil)
    }
}

@MainActor
@Test func managedUpdateRecoveredReadyReceiptReconnectsAfterOriginalReadinessWindow() async throws {
    let harness = ManagedWorkflowHarness()
    let id = try harness.seed(.restartRequired)
    let receipt = CloudGatewayMacExtensionUpdateOrchestrator.TerminalReceipt(
        id: id, outcome: .ready, expires: harness.now.addingTimeInterval(400)
    )
    harness.gateStored = .init(state: .terminal(receipt), receipts: [receipt])
    harness.authenticated = true
    let (workflow, _) = try harness.make()
    try #require(await managedWorkflowDrive(workflow) { !workflow.isActionable })
    #expect(workflow.status(accountId: harness.accountId)?.phase == .completed)
    #expect(workflow.status(accountId: harness.accountId)?.error == nil)
    #expect(harness.starts == [managedWorkflowConfig])
    #expect(harness.stopRequests == 0)
    #expect(harness.activations.isEmpty)
}

@MainActor
@Test func managedUpdateSupersededDuringReadinessPingStaysSuperseded() async throws {
    let harness = ManagedWorkflowHarness()
    _ = try harness.seed(.checkingReadiness)
    harness.authenticated = true
    let (workflow, _) = try harness.make()
    harness.beforePing = {
        harness.beforePing = nil
        _ = workflow.supersede()
    }
    try #require(await managedWorkflowDrive(workflow) { !workflow.isActionable })
    #expect(workflow.journal?.phase == .superseded)
    #expect(workflow.journal?.error == .superseded)
    #expect(try harness.savedJournal().phase == .superseded)
    #expect(harness.starts.isEmpty)
}

@MainActor
@Test func managedUpdateFailedSupersedeWriteFencesInFlightStop() async throws {
    let harness = ManagedWorkflowHarness()
    _ = try harness.seed(.stopping)
    harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
    let (workflow, _) = try harness.make()
    harness.beforeObservation = {
        harness.beforeObservation = nil
        harness.failJournal = { $0.phase == .superseded }
        _ = workflow.supersede()
    }
    for _ in 0..<50 {
        workflow.resume()
        await Task.yield()
    }
    #expect(!workflow.isActionable)
    #expect(workflow.journal?.phase == .superseded)
    #expect(harness.stopRequests == 0)
    #expect(try harness.savedJournal().phase == .stopping)
    #expect(try harness.savedJournal().reconnect == false)
}

@MainActor
@Test func managedUpdateRetriedActivationWriteLeavesNoSuppressionWarning() async throws {
    let harness = ManagedWorkflowHarness()
    harness.accountId = nil
    let (workflow, _) = try harness.make()
    let accepted = await harness.reserve(workflow)
    await workflow.confirm(accepted.id)
    try #require(await managedWorkflowDrive(workflow) { harness.activations.count == 1 })
    harness.failJournal = { $0.phase == .checkingReadiness }
    harness.emit(.completed)
    #expect(workflow.isActionable)
    #expect(workflow.status(accountId: nil)?.warning == nil)
    harness.failJournal = nil
    workflow.retryPendingActivationEvent()
    harness.authenticated = true
    try #require(await managedWorkflowDrive(workflow) { workflow.status(accountId: nil)?.phase == .completed })
    #expect(workflow.status(accountId: nil)?.warning == nil)
    #expect(try harness.savedJournal().warning == nil)
}

@MainActor
@Test func managedUpdateUnreadableRevocationMarkerCompletesWithReconnectOff() async throws {
    let harness = ManagedWorkflowHarness()
    _ = try harness.seed(.activating)
    harness.revocationData = Data("corrupt".utf8)
    harness.authenticated = true
    let (workflow, _) = try harness.make()
    #expect(!workflow.isBlocked)
    #expect(workflow.journal?.reconnect == false)
    try #require(await managedWorkflowDrive(workflow) { workflow.status(accountId: harness.accountId)?.phase == .completed })
    #expect(workflow.status(accountId: harness.accountId)?.warning == .reconnectSuppressed)
    #expect(try harness.savedJournal().reconnect == false)
    #expect(harness.starts.isEmpty)
    #expect(harness.stopRequests == 0)
    #expect(harness.activations.isEmpty)
}

@MainActor
@Test func managedUpdateRetainedRebootAttemptReportsRestartRequired() async throws {
    let harness = ManagedWorkflowHarness()
    let attempt = CloudGatewayMacExtensionUpdateOrchestrator.Attempt(id: UUID(), target: harness.target, bootSession: harness.boot)
    harness.gateStored.state = .rebootRequired(attempt)
    let (workflow, _) = try harness.make()
    #expect(await harness.reserve(workflow).error == .restartRequired)
    #expect(harness.journalData == nil)
    #expect(harness.stopRequests == 0)
    #expect(harness.activations.isEmpty)
}

@MainActor
@Test func managedUpdateSuppressionWarningSettlesOnceReconnectOffIsSaved() async throws {
    let harness = ManagedWorkflowHarness()
    _ = try harness.seed(.approvalRequired)
    let (workflow, _) = try harness.make()
    harness.failJournal = { _ in true }
    harness.failRevocation = true
    workflow.suppressReconnect()
    #expect(workflow.status(accountId: harness.accountId)?.warning == .storageUnavailable)
    harness.failJournal = nil
    harness.failRevocation = false
    harness.authenticated = true
    try #require(await managedWorkflowDrive(workflow) { workflow.status(accountId: harness.accountId)?.phase == .completed })
    #expect(workflow.status(accountId: harness.accountId)?.warning == .reconnectSuppressed)
    #expect(try harness.savedJournal().warning == .reconnectSuppressed)
    #expect(try harness.savedJournal().reconnect == false)
    #expect(harness.starts.isEmpty)

    let repeated = ManagedWorkflowHarness()
    _ = try repeated.seed(.activating)
    let (again, _) = try repeated.make()
    again.suppressReconnect()
    #expect(try repeated.savedJournal().reconnect == false)
    repeated.failJournal = { _ in true }
    repeated.failRevocation = true
    again.suppressReconnect()
    #expect(again.status(accountId: repeated.accountId)?.warning == .reconnectSuppressed)
}

@MainActor
@Test func managedUpdateUnreadableRevocationMarkerNeverStopsUnrestorableTunnel() async throws {
    let harness = ManagedWorkflowHarness()
    _ = try harness.seed(.stopping)
    harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
    harness.revocationData = Data("corrupt".utf8)
    let (workflow, _) = try harness.make()
    try #require(await managedWorkflowDrive(workflow) { !workflow.isActionable })
    #expect(workflow.status(accountId: harness.accountId)?.phase == .failed)
    #expect(workflow.status(accountId: harness.accountId)?.error == .storageUnavailable)
    #expect(harness.stopRequests == 0)
    #expect(harness.activations.isEmpty)
    #expect(harness.profiles.contains { $0.needsStop })
}

@MainActor
@Test func managedUpdateReservationReplacesUnreadableRevocationMarker() async throws {
    let failing = ManagedWorkflowHarness()
    failing.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
    failing.revocationData = Data("corrupt".utf8)
    failing.failRevocation = true
    let (blocked, _) = try failing.make()
    #expect(await failing.reserve(blocked).error == .storageUnavailable)
    #expect(failing.journalData == nil)

    let harness = ManagedWorkflowHarness()
    harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
    harness.revocationData = Data("corrupt".utf8)
    let (workflow, _) = try harness.make()
    let accepted = await harness.reserve(workflow)
    #expect(accepted.phase == .prepared)
    #expect(accepted.reconnect)
    let markerData = try #require(harness.revocationData)
    let marker = try #require(try JSONSerialization.jsonObject(with: markerData) as? [String: Any])
    #expect((marker["id"] as? String).flatMap(UUID.init(uuidString:)) != accepted.id)
    let (restored, _) = try harness.make()
    #expect(restored.journal?.reconnect == true)
    #expect(restored.status(accountId: harness.accountId)?.warning == nil)
}

@MainActor
@Test func managedUpdateRestartAfterCompletedStopProceedsWhileSessionRestores() async throws {
    let harness = ManagedWorkflowHarness()
    let id = try harness.seed(.stopping, deadline: 30)
    harness.now.addTimeInterval(120)
    harness.restoring = true
    let (workflow, _) = try harness.make()
    try #require(await managedWorkflowDrive(workflow) { harness.activations.count == 1 })
    #expect(harness.activations.first?.0 == id)
    #expect(workflow.journal?.error == nil)
    #expect(harness.stopRequests == 0)
    harness.emit(.completed)
    harness.authenticated = true
    harness.restoring = false
    try #require(await managedWorkflowDrive(workflow) { workflow.journal?.phase == .completed })
    #expect(harness.starts == [managedWorkflowConfig])
}

@MainActor
@Test func managedUpdateRestartGrantsFreshRestorationWaitBeforeCapturedStop() async throws {
    for restores in [true, false] {
        let harness = ManagedWorkflowHarness()
        _ = try harness.seed(.stopping, deadline: 30)
        harness.now.addTimeInterval(120)
        harness.accountId = nil
        harness.restoring = true
        harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
        let (workflow, _) = try harness.make()
        for _ in 0..<20 { workflow.resume(); await Task.yield() }
        #expect(workflow.isRunning)
        #expect(workflow.journal?.error == nil)
        #expect(try harness.savedJournal().deadline == harness.now.addingTimeInterval(30))
        #expect(harness.stopRequests == 0)
        if restores {
            harness.accountId = "account"
            harness.restoring = false
            try #require(await managedWorkflowDrive(workflow) { harness.activations.count == 1 })
            #expect(harness.stopRequests == 1)
        } else {
            harness.now.addTimeInterval(30)
            try #require(await managedWorkflowDrive(workflow) { workflow.journal?.phase == .failed })
            #expect(workflow.journal?.error == .signInRequired)
            #expect(harness.stopRequests == 0)
            #expect(harness.profiles.first?.identifier == managedWorkflowConfig)
        }
    }
}

@MainActor
@Test func managedUpdateUnrestorableStopFenceSurvivesRestartDuringSessionRestoration() async throws {
    let harness = ManagedWorkflowHarness()
    _ = try harness.seed(.stopping, deadline: 30)
    harness.now.addTimeInterval(120)
    harness.restoring = true
    harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
    harness.revocationData = Data("corrupt".utf8)
    harness.failJournal = { $0.phase == .failed }
    let (first, _) = try harness.make()
    for _ in 0..<20 { first.resume(); await Task.yield() }
    #expect(try harness.savedJournal().phase == .stopping)
    #expect(try harness.savedJournal().reconnect)
    #expect(harness.stopRequests == 0)

    harness.failJournal = nil
    harness.restoring = false
    let (second, _) = try harness.make()
    try #require(await managedWorkflowDrive(second) { !second.isActionable })
    #expect(second.status(accountId: harness.accountId)?.error == .storageUnavailable)
    #expect(harness.stopRequests == 0)
    #expect(harness.activations.isEmpty)
    #expect(harness.profiles.contains { $0.needsStop })
}

@MainActor
@Test func managedUpdateUnrestorablePreparedReservationRefusesConfirmation() async throws {
    let harness = ManagedWorkflowHarness()
    let id = try harness.seed(.prepared)
    harness.profiles = [.init(identifier: managedWorkflowConfig, status: .connected)]
    harness.revocationData = Data("corrupt".utf8)
    let (workflow, _) = try harness.make()
    await workflow.confirm(id)
    #expect(workflow.status(accountId: harness.accountId)?.phase == .failed)
    #expect(workflow.status(accountId: harness.accountId)?.error == .storageUnavailable)
    #expect(try harness.savedJournal().phase == .failed)
    #expect(harness.stopRequests == 0)
    #expect(harness.activations.isEmpty)
}
