import CloudGatewayMacCore
import CloudGatewayMacIPC
import Foundation
import Testing
@testable import CloudGatewayMacControllerIPC

private typealias ExtensionUpdates = CloudGatewayMacExtensionUpdateOrchestrator

private let updateTarget = CloudGatewayMacBuildIdentity(version: "1.0", build: "2", codeHash: String(repeating: "a", count: 64))
private let replacementTarget = CloudGatewayMacBuildIdentity(version: "1.0", build: "3", codeHash: String(repeating: "b", count: 64))

private enum ExtensionUpdatePhase: CaseIterable, Sendable {
    case prepared, submitted, approvalPending, rebootRequired, outcomeUnknown
}

@MainActor
private final class ExtensionUpdateEffects {
    enum Failure: Error, Equatable { case persistence }

    var now = Date(timeIntervalSince1970: 1_000)
    var boot = "boot-1"
    var failPersistence = false
    var saved = ExtensionUpdates.StoredState()
    var writes = 0

    func make(stored: ExtensionUpdates.StoredState? = nil) throws -> ExtensionUpdates {
        try ExtensionUpdates(
            stored: stored ?? saved,
            now: { self.now }, bootSession: { self.boot },
            persist: { state in
                if self.failPersistence { throw Failure.persistence }
                self.saved = state
                self.writes += 1
            }
        )
    }

    func makeAttempt(phase: ExtensionUpdatePhase) throws -> (ExtensionUpdates, ExtensionUpdates.Attempt) {
        let updates = try make()
        let attempt = try updates.begin(target: updateTarget)
        if phase == .prepared { return (updates, attempt) }
        try updates.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
        switch phase {
        case .approvalPending:
            try updates.handle(.approval, attemptId: attempt.id, installedTarget: updateTarget)
        case .rebootRequired:
            try updates.handle(.rebootRequired, attemptId: attempt.id, installedTarget: updateTarget)
        case .outcomeUnknown:
            now.addTimeInterval(120)
            _ = try updates.prepareReadiness(target: updateTarget)
        case .prepared, .submitted: break
        }
        return (updates, attempt)
    }
}

@MainActor
@Test func extensionUpdateSubmissionRequiresLivePreparation() throws {
    let effects = ExtensionUpdateEffects()
    let updates = try effects.make()
    let attempt = try updates.begin(target: updateTarget)
    #expect(updates.state == .prepared(attempt, deadline: effects.now.addingTimeInterval(30)))
    #expect(try updates.prepareReadiness(target: updateTarget) == nil)
    #expect(throws: CloudGatewayMacControllerFailure.rejected) {
        try updates.handle(.started, attemptId: attempt.id, installedTarget: updateTarget, canSubmit: false)
    }
    effects.now.addTimeInterval(30)
    #expect(throws: CloudGatewayMacControllerFailure.rejected) {
        try updates.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
    }
    #expect(!updates.hasPendingAttempt)
    #expect(effects.saved.receipts.first?.outcome == .expired)
    #expect(throws: CloudGatewayMacControllerFailure.rejected) {
        try updates.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
    }
    try updates.handle(.failed, attemptId: attempt.id, installedTarget: updateTarget)
}

@MainActor
@Test func extensionUpdateRestoresUnsubmittedReservationWithoutAssumingOSWork() throws {
    let effects = ExtensionUpdateEffects()
    let original = try effects.make()
    let attempt = try original.begin(target: updateTarget)
    let prepared = original.stored
    let restored = try effects.make()
    #expect(restored.stored == prepared)
    #expect(try restored.prepareReadiness(target: updateTarget) == nil)
    #expect(throws: CloudGatewayMacControllerFailure.rejected) {
        try restored.handle(.finished, attemptId: attempt.id, installedTarget: updateTarget)
    }
    effects.boot = "boot-2"
    let afterReboot = try effects.make()
    #expect(!afterReboot.hasPendingAttempt)
    #expect(afterReboot.stored.receipts.first?.outcome == .expired)
    #expect(throws: CloudGatewayMacControllerFailure.rejected) {
        try afterReboot.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
    }
    let replacement = try afterReboot.begin(target: replacementTarget)
    #expect(afterReboot.state.attempt?.id == replacement.id)
}

@MainActor
@Test func extensionUpdateRestoredApprovalCanReconcileButUnknownBootCannotClearReboot() throws {
    let effects = ExtensionUpdateEffects()
    let updates = try effects.make()
    let attempt = try updates.begin(target: updateTarget)
    try updates.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
    try updates.handle(.approval, attemptId: attempt.id, installedTarget: updateTarget)
    let approval = try effects.make()
    #expect(approval.state == .approvalPending(attempt))
    let probe = try #require(try approval.prepareReadiness(target: updateTarget))
    #expect(try approval.reconcileReadiness(probe, installedTarget: updateTarget, authenticatedTarget: updateTarget) == .ready)

    effects.boot = "unknown"
    let second = try approval.begin(target: updateTarget)
    try approval.handle(.started, attemptId: second.id, installedTarget: updateTarget)
    try approval.handle(.rebootRequired, attemptId: second.id, installedTarget: updateTarget)
    effects.boot = "boot-2"
    let restored = try effects.make()
    #expect(restored.state == .rebootRequired(second))
    #expect(try restored.prepareReadiness(target: updateTarget) == nil)
}

@MainActor
@Test func extensionUpdateActivationDeadlineBecomesUnknownAndRecoversByReadiness() throws {
    let effects = ExtensionUpdateEffects()
    let updates = try effects.make()
    let attempt = try updates.begin(target: updateTarget)
    try updates.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
    let oldProbe = try #require(try updates.prepareReadiness(target: updateTarget))
    effects.now.addTimeInterval(120)
    #expect(try updates.reconcileReadiness(
        oldProbe, installedTarget: updateTarget, authenticatedTarget: updateTarget
    ) == .ignored)
    #expect(updates.state == .outcomeUnknown(attempt))
    #expect(updates.setupState == .checkingConnection)
    #expect(throws: CloudGatewayMacControllerFailure.outcomeUnknown) {
        try updates.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
    }
    let probe = try #require(try updates.prepareReadiness(target: updateTarget))
    #expect(try updates.reconcileReadiness(probe, installedTarget: updateTarget, authenticatedTarget: nil) == .notReady)
    #expect(updates.hasPendingAttempt)
    #expect(try updates.reconcileReadiness(
        probe, installedTarget: updateTarget, authenticatedTarget: replacementTarget
    ) == .notReady)
    #expect(try updates.reconcileReadiness(probe, installedTarget: updateTarget, authenticatedTarget: updateTarget) == .ready)
    #expect(!updates.hasPendingAttempt)
    #expect(effects.saved.receipts.first?.outcome == .ready)
}

@MainActor
@Test func extensionUpdateRestoresSubmittedSameBootWithoutRequiringReboot() throws {
    let effects = ExtensionUpdateEffects()
    let original = try effects.make()
    let attempt = try original.begin(target: updateTarget)
    try original.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
    let restored = try effects.make()
    #expect(restored.state == .outcomeUnknown(attempt))
    #expect(restored.setupState == .checkingConnection)
    #expect(try restored.prepareReadiness(target: replacementTarget) == nil)
    #expect(throws: CloudGatewayMacControllerFailure.rejected) {
        try restored.handle(.finished, attemptId: attempt.id, installedTarget: replacementTarget)
    }
    #expect(throws: CloudGatewayMacControllerFailure.busy) { try restored.begin(target: replacementTarget) }
    let probe = try #require(try restored.prepareReadiness(target: updateTarget))
    #expect(try restored.reconcileReadiness(probe, installedTarget: updateTarget, authenticatedTarget: nil) == .notReady)
    #expect(restored.state == .outcomeUnknown(attempt))
    #expect(try restored.reconcileReadiness(
        probe, installedTarget: updateTarget, authenticatedTarget: updateTarget
    ) == .ready)
    try restored.handle(.finished, attemptId: attempt.id, installedTarget: updateTarget)
}

@MainActor
@Test func extensionUpdateGenuineRebootRequirementSurvivesSameBootAndLateCallbacks() throws {
    let effects = ExtensionUpdateEffects()
    let updates = try effects.make()
    let attempt = try updates.begin(target: updateTarget)
    try updates.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
    let probe = try #require(try updates.prepareReadiness(target: updateTarget))
    try updates.handle(.rebootRequired, attemptId: attempt.id, installedTarget: updateTarget)
    #expect(try updates.reconcileReadiness(probe, installedTarget: updateTarget, authenticatedTarget: updateTarget) == .ignored)
    let restored = try effects.make()
    #expect(restored.state == .rebootRequired(attempt))
    #expect(restored.setupState == .awaitingRestart)
    for event in [ExtensionUpdates.Event.approval, .finished, .failed] {
        try restored.handle(event, attemptId: attempt.id, installedTarget: updateTarget)
        #expect(restored.state == .rebootRequired(attempt))
    }
    #expect(try restored.prepareReadiness(target: updateTarget) == nil)
    #expect(throws: CloudGatewayMacControllerFailure.rejected) {
        try restored.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
    }
    effects.boot = "unknown"
    #expect(try restored.prepareReadiness(target: updateTarget) == nil)
    effects.boot = "boot-2"
    let afterReboot = try effects.make()
    #expect(afterReboot.state == .outcomeUnknown(attempt))
    let afterRebootProbe = try #require(try afterReboot.prepareReadiness(target: updateTarget))
    #expect(try afterReboot.reconcileReadiness(
        afterRebootProbe, installedTarget: updateTarget, authenticatedTarget: updateTarget
    ) == .ready)
}

@MainActor
@Test(arguments: ExtensionUpdatePhase.allCases, [false, true])
private func extensionUpdateRetiresObsoleteTargetAfterVerifiedBoot(
    phase: ExtensionUpdatePhase, restoreAfterReboot: Bool
) throws {
    let effects = ExtensionUpdateEffects()
    let (original, attempt) = try effects.makeAttempt(phase: phase)
    let oldProbe = try original.prepareReadiness(target: updateTarget)
    effects.boot = "boot-2"
    let updates = restoreAfterReboot ? try effects.make() : original
    let probe = try #require(try updates.prepareReadiness(target: replacementTarget))
    let receipt = try #require(effects.saved.receipts.first { $0.id == attempt.id })
    #expect(receipt.outcome == (phase == .prepared ? .expired : .superseded))
    #expect(receipt.expires == effects.now.addingTimeInterval(600))
    #expect(updates.state == .terminal(receipt))
    #expect(!updates.hasPendingAttempt)
    if let oldProbe {
        #expect(try updates.reconcileReadiness(
            oldProbe, installedTarget: updateTarget, authenticatedTarget: updateTarget
        ) == .ignored)
    }
    #expect(try updates.reconcileReadiness(
        probe, installedTarget: replacementTarget, authenticatedTarget: nil
    ) == .notReady)
    #expect(try updates.reconcileReadiness(
        probe, installedTarget: replacementTarget, authenticatedTarget: updateTarget
    ) == .notReady)
    #expect(updates.state == .terminal(receipt))
    #expect(try updates.reconcileReadiness(
        probe, installedTarget: replacementTarget, authenticatedTarget: replacementTarget
    ) == .ready)

    let restored = try effects.make()
    #expect(restored.stored.receipts.contains(receipt))
    #expect(throws: CloudGatewayMacControllerFailure.busy) {
        try restored.begin(target: replacementTarget, id: attempt.id)
    }
    let replacement = try restored.begin(target: replacementTarget)
    try restored.handle(.started, attemptId: replacement.id, installedTarget: replacementTarget)
    let pending = restored.stored
    for event in [ExtensionUpdates.Event.approval, .rebootRequired, .finished, .failed] {
        try restored.handle(event, attemptId: attempt.id, installedTarget: replacementTarget)
        #expect(restored.stored == pending)
    }
    #expect(throws: CloudGatewayMacControllerFailure.rejected) {
        try restored.handle(.started, attemptId: attempt.id, installedTarget: replacementTarget)
    }
    #expect(try restored.reconcileReadiness(
        probe, installedTarget: replacementTarget, authenticatedTarget: replacementTarget
    ) == .ignored)
}

@MainActor
@Test(arguments: [ExtensionUpdatePhase.submitted, .approvalPending, .rebootRequired, .outcomeUnknown])
private func extensionUpdateCanBeginReplacementAfterVerifiedBoot(phase: ExtensionUpdatePhase) throws {
    let effects = ExtensionUpdateEffects()
    let (updates, attempt) = try effects.makeAttempt(phase: phase)
    effects.boot = "boot-2"
    let replacement = try updates.begin(target: replacementTarget)
    #expect(updates.state == .prepared(replacement, deadline: effects.now.addingTimeInterval(30)))
    #expect(effects.saved == updates.stored)
    #expect(effects.saved.receipts.contains { $0.id == attempt.id && $0.outcome == .superseded })
    #expect(try updates.prepareReadiness(target: replacementTarget) == nil)
}

@MainActor
@Test(arguments: [ExtensionUpdatePhase.submitted, .approvalPending, .rebootRequired, .outcomeUnknown],
      ["boot-1", "unknown", ""])
private func extensionUpdateKeepsObsoleteTargetBlockedWithoutVerifiedBoot(
    phase: ExtensionUpdatePhase, currentBoot: String
) throws {
    let effects = ExtensionUpdateEffects()
    let (updates, attempt) = try effects.makeAttempt(phase: phase)
    effects.boot = currentBoot
    #expect(try updates.prepareReadiness(target: replacementTarget) == nil)
    #expect(updates.state.attempt == attempt)
    #expect(updates.stored.receipts.isEmpty)
    #expect(throws: CloudGatewayMacControllerFailure.busy) { try updates.begin(target: replacementTarget) }
    let restored = try effects.make()
    #expect(try restored.prepareReadiness(target: replacementTarget) == nil)
    #expect(throws: CloudGatewayMacControllerFailure.busy) { try restored.begin(target: replacementTarget) }
    #expect(restored.state.attempt == attempt)
    if phase == .rebootRequired { #expect(restored.state == .rebootRequired(attempt)) }
}

@MainActor
@Test(arguments: [ExtensionUpdatePhase.submitted, .approvalPending, .rebootRequired, .outcomeUnknown])
private func extensionUpdateUnknownOriginalBootCannotSupersedeTarget(phase: ExtensionUpdatePhase) throws {
    let effects = ExtensionUpdateEffects()
    effects.boot = "unknown"
    let (_, attempt) = try effects.makeAttempt(phase: phase)
    effects.boot = "boot-2"
    let restored = try effects.make()
    #expect(try restored.prepareReadiness(target: replacementTarget) == nil)
    #expect(throws: CloudGatewayMacControllerFailure.busy) { try restored.begin(target: replacementTarget) }
    #expect(restored.state.attempt == attempt)
    #expect(restored.stored.receipts.isEmpty)
    if phase == .rebootRequired { #expect(restored.state == .rebootRequired(attempt)) }
}

@MainActor
@Test(arguments: ExtensionUpdatePhase.allCases, [false, true])
private func extensionUpdateObsoleteTargetRetirementRollsBackOnPersistenceFailure(
    phase: ExtensionUpdatePhase, restoreAfterReboot: Bool
) throws {
    let effects = ExtensionUpdateEffects()
    let (original, attempt) = try effects.makeAttempt(phase: phase)
    let pending = effects.saved
    effects.boot = "boot-2"
    effects.failPersistence = true
    let updates = restoreAfterReboot ? try effects.make() : original
    let local = updates.stored
    #expect(throws: ExtensionUpdateEffects.Failure.persistence) {
        try updates.prepareReadiness(target: replacementTarget)
    }
    #expect(updates.stored == local)
    #expect(effects.saved == pending)
    #expect(throws: ExtensionUpdateEffects.Failure.persistence) { try updates.begin(target: replacementTarget) }
    #expect(updates.stored == local)
    #expect(effects.saved == pending)
    effects.failPersistence = false
    let replacement = try updates.begin(target: replacementTarget)
    #expect(updates.state.attempt == replacement)
    #expect(effects.saved == updates.stored)
    #expect(effects.saved.receipts.contains {
        $0.id == attempt.id && $0.outcome == (phase == .prepared ? .expired : .superseded)
    })
}

@MainActor
@Test func extensionReadinessReceiptSurvivesReconstructionAndCannotChangeNewAttempt() throws {
    let effects = ExtensionUpdateEffects()
    let original = try effects.make()
    let attempt = try original.begin(target: updateTarget)
    try original.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
    let probe = try #require(try original.prepareReadiness(target: updateTarget))
    #expect(try original.reconcileReadiness(
        probe, installedTarget: updateTarget, authenticatedTarget: updateTarget
    ) == .ready)
    let restored = try effects.make()
    let newAttempt = try restored.begin(target: replacementTarget)
    try restored.handle(.started, attemptId: newAttempt.id, installedTarget: replacementTarget)
    let current = restored.stored
    let currentProbe = try #require(try restored.prepareReadiness(target: replacementTarget))
    let writes = effects.writes
    effects.failPersistence = true
    for _ in 0..<2 {
        for event in [ExtensionUpdates.Event.finished, .failed, .approval, .rebootRequired] {
            try restored.handle(event, attemptId: attempt.id, installedTarget: replacementTarget)
            #expect(restored.stored == current)
        }
    }
    #expect(effects.writes == writes)
    effects.failPersistence = false
    #expect(try restored.reconcileReadiness(probe, installedTarget: updateTarget, authenticatedTarget: updateTarget) == .ignored)
    #expect(try restored.reconcileReadiness(
        currentProbe, installedTarget: replacementTarget, authenticatedTarget: replacementTarget
    ) == .ready)
    let reconstructedAgain = try effects.make()
    try reconstructedAgain.handle(.finished, attemptId: attempt.id, installedTarget: replacementTarget)
    #expect(reconstructedAgain.stored == effects.saved)
}

@MainActor
@Test func extensionUpdatePersistenceFailureRollsBackEveryAdmissionAndTerminalTransition() throws {
    let effects = ExtensionUpdateEffects()
    let updates = try effects.make()
    effects.failPersistence = true
    #expect(throws: ExtensionUpdateEffects.Failure.persistence) { try updates.begin(target: updateTarget) }
    #expect(updates.state == .idle)
    #expect(effects.saved.state == .idle)
    effects.failPersistence = false
    let attempt = try updates.begin(target: updateTarget)
    let prepared = updates.stored
    effects.failPersistence = true
    #expect(throws: ExtensionUpdateEffects.Failure.persistence) {
        try updates.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
    }
    #expect(updates.stored == prepared)
    #expect(effects.saved == prepared)
    effects.failPersistence = false
    try updates.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
    let submitted = updates.stored
    let probe = try #require(try updates.prepareReadiness(target: updateTarget))
    effects.failPersistence = true
    for event in [ExtensionUpdates.Event.approval, .rebootRequired, .finished, .failed] {
        #expect(throws: ExtensionUpdateEffects.Failure.persistence) {
            try updates.handle(event, attemptId: attempt.id, installedTarget: updateTarget)
        }
        #expect(updates.stored == submitted)
        #expect(effects.saved == submitted)
    }
    #expect(throws: ExtensionUpdateEffects.Failure.persistence) {
        try updates.reconcileReadiness(probe, installedTarget: updateTarget, authenticatedTarget: updateTarget)
    }
    #expect(updates.stored == submitted)
    effects.failPersistence = false
    #expect(try updates.reconcileReadiness(probe, installedTarget: updateTarget, authenticatedTarget: updateTarget) == .ready)
    #expect(effects.saved.receipts.first?.id == attempt.id)
}

@MainActor
@Test func extensionUpdateRestorationFailureDoesNotDiscardSubmittedAttempt() throws {
    let effects = ExtensionUpdateEffects()
    let updates = try effects.make()
    let attempt = try updates.begin(target: updateTarget)
    try updates.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
    let saved = effects.saved
    effects.failPersistence = true
    let restored = try effects.make()
    #expect(restored.state == .outcomeUnknown(attempt))
    #expect(effects.saved == saved)
    #expect(throws: ExtensionUpdateEffects.Failure.persistence) {
        try restored.prepareReadiness(target: updateTarget)
    }
    effects.failPersistence = false
    let token = try #require(try restored.prepareReadiness(target: updateTarget))
    #expect(try restored.reconcileReadiness(token, installedTarget: updateTarget, authenticatedTarget: updateTarget) == .ready)
    #expect(effects.saved.receipts.contains { $0.id == attempt.id && $0.outcome == .ready })
}

@MainActor
@Test func extensionUpdateFencesReadinessAcrossCallbackAndTargetChanges() throws {
    let effects = ExtensionUpdateEffects()
    let updates = try effects.make()
    let idleProbe = try #require(try updates.prepareReadiness(target: updateTarget))
    let attempt = try updates.begin(target: updateTarget)
    #expect(try updates.reconcileReadiness(idleProbe, installedTarget: updateTarget, authenticatedTarget: updateTarget) == .ignored)
    try updates.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
    let submittedProbe = try #require(try updates.prepareReadiness(target: updateTarget))
    try updates.handle(.approval, attemptId: attempt.id, installedTarget: updateTarget)
    #expect(updates.setupState == .awaitingApproval)
    #expect(try updates.reconcileReadiness(
        submittedProbe, installedTarget: updateTarget, authenticatedTarget: updateTarget
    ) == .ignored)
    let approvalProbe = try #require(try updates.prepareReadiness(target: updateTarget))
    #expect(try updates.reconcileReadiness(
        approvalProbe, installedTarget: replacementTarget, authenticatedTarget: updateTarget
    ) == .ignored)
    try updates.handle(.finished, attemptId: attempt.id, installedTarget: updateTarget)
    #expect(!updates.hasPendingAttempt)
    #expect(updates.setupState == .checkingConnection)
    #expect(try updates.reconcileReadiness(
        approvalProbe, installedTarget: updateTarget, authenticatedTarget: updateTarget
    ) == .ignored)
    let completedProbe = try #require(try updates.prepareReadiness(target: updateTarget))
    #expect(try updates.reconcileReadiness(
        completedProbe, installedTarget: updateTarget, authenticatedTarget: nil
    ) == .notReady)
    #expect(try updates.reconcileReadiness(
        completedProbe, installedTarget: updateTarget, authenticatedTarget: updateTarget
    ) == .ready)
}

@MainActor
@Test func extensionUpdateRetainsOnlyBoundedUnexpiredTerminalReceipts() throws {
    let effects = ExtensionUpdateEffects()
    let updates = try effects.make()
    var attempts: [ExtensionUpdates.Attempt] = []
    for index in 0..<20 {
        effects.boot = "boot-\(index)"
        let attempt = try updates.begin(target: updateTarget)
        attempts.append(attempt)
        if index.isMultiple(of: 2) {
            try updates.handle(.failed, attemptId: attempt.id, installedTarget: updateTarget)
        } else {
            try updates.handle(.started, attemptId: attempt.id, installedTarget: updateTarget)
            effects.boot = "boot-\(index)-after"
            _ = try updates.prepareReadiness(target: replacementTarget)
        }
        effects.now.addTimeInterval(1)
    }
    #expect(effects.saved.receipts.count == 16)
    #expect(effects.saved.receipts.filter { $0.outcome == .superseded }.count == 8)
    #expect(throws: CloudGatewayMacControllerFailure.rejected) {
        try updates.handle(.finished, attemptId: attempts[0].id, installedTarget: updateTarget)
    }
    try updates.handle(.finished, attemptId: attempts[19].id, installedTarget: updateTarget)
    let encoded = try JSONEncoder().encode(effects.saved)
    let decoded = try JSONDecoder().decode(ExtensionUpdates.StoredState.self, from: encoded)
    #expect(decoded == effects.saved)
    effects.now.addTimeInterval(600)
    let restored = try effects.make(stored: decoded)
    #expect(restored.state == .idle)
    #expect(restored.stored.receipts.isEmpty)
    #expect(throws: CloudGatewayMacControllerFailure.rejected) {
        try restored.handle(.finished, attemptId: attempts[19].id, installedTarget: updateTarget)
    }
}

@MainActor
@Test func extensionUpdateMigratesLegacySubmittedAndTerminalRecords() throws {
    let effects = ExtensionUpdateEffects()
    let id = UUID()
    let finished = UUID()
    let data = try JSONSerialization.data(withJSONObject: [
        "id": id.uuidString,
        "target": ["version": updateTarget.version, "build": updateTarget.build, "codeHash": updateTarget.codeHash],
        "bootSession": effects.boot, "phase": "activating",
        "deadline": effects.now.addingTimeInterval(120).timeIntervalSinceReferenceDate,
    ])
    let legacy = try JSONDecoder().decode(ExtensionUpdates.LegacyAttempt.self, from: data)
    let migrated = try ExtensionUpdates.StoredState(
        legacyAttempt: legacy, finishedExtensionUpdates: [finished: effects.now.addingTimeInterval(600)]
    )
    let updates = try effects.make(stored: migrated)
    #expect(updates.state == .outcomeUnknown(.init(id: id, target: updateTarget, bootSession: effects.boot)))
    try updates.handle(.finished, attemptId: finished, installedTarget: replacementTarget)
    #expect(updates.hasPendingAttempt)
}

