import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation
import Testing
@testable import CloudGatewayMacCore

@Test func macConfigInstallSavesProfileBeforeCommitAndMetadataCache() async throws {
    let fixture = MacConfigFixture()
    let installed = try await fixture.install()
    #expect(await fixture.events.values == ["install", "save", "commit", "cache"])
    #expect(installed.identifier == "account/region/client")
    #expect(installed.snapshot.secretReference.account == fixture.reference.value)
    let persisted = String(decoding: try JSONEncoder().encode(installed), as: UTF8.self)
    #expect(!persisted.contains("PrivateKey"))
    #expect(!persisted.contains(macTestWireGuardConfig))
}

@Test func macConfigFailedProfileSaveRollsBackOnlyDefinitelyUnreferencedSecret() async throws {
    let fixture = MacConfigFixture()
    await fixture.profiles.setSaveFailure(.beforeSave)
    await #expect(throws: CloudGatewayMacConfigError.profileInstallationFailed) {
        try await fixture.install()
    }
    #expect(await fixture.events.values == ["install", "save", "profiles", "rollback"])
}

@Test func macConfigFailedReloadCommitsAndCachesSecretReferencedBySavedProfile() async throws {
    let fixture = MacConfigFixture()
    await fixture.profiles.setSaveFailure(.afterSave)
    await #expect(throws: CloudGatewayMacConfigError.profileInstallationFailed) {
        try await fixture.install()
    }
    #expect(await fixture.events.values == ["install", "save", "profiles", "commit", "cache"])
    #expect(await fixture.profiles.values.first?.reference == fixture.reference)
}

@Test func macConfigUnknownPreferencesAfterSaveFailureRetainsProvisionalSecret() async throws {
    let fixture = MacConfigFixture()
    await fixture.profiles.setSaveFailure(.unknownPreferences)
    await #expect(throws: CloudGatewayMacConfigError.profileInstallationFailed) {
        try await fixture.install()
    }
    #expect(await fixture.events.values == ["install", "save", "profiles"])
}

@Test func macConfigCacheFailureRetainsCommittedProfileAndSecret() async throws {
    let fixture = MacConfigFixture()
    await fixture.snapshots.failSave()
    await #expect(throws: CloudGatewayMacConfigError.snapshotPersistenceFailed) {
        try await fixture.install()
    }
    #expect(await fixture.events.values == ["install", "save", "commit", "cache"])
    #expect(await fixture.profiles.values.first?.reference == fixture.reference)
}

@Test func macConfigCommitFailureRetainsReferencedProvisionalSecret() async throws {
    let fixture = MacConfigFixture()
    await fixture.secrets.failCommit()
    await #expect(throws: CloudGatewayMacConfigError.secretCommitFailed) {
        try await fixture.install()
    }
    #expect(await fixture.events.values == ["install", "save", "commit"])
}

@Test func macConfigReplacementNeverDeletesOldReference() async throws {
    let fixture = MacConfigFixture()
    let old = try CloudGatewayMacSecretReference(value: "11111111-1111-1111-1111-111111111111")
    await fixture.profiles.setProfiles([
        CloudGatewayMacInstalledProfile(identifier: "account/region/client", reference: old, status: .disconnected)
    ])
    _ = try await fixture.install()
    #expect(await fixture.events.values == ["install", "save", "commit", "cache"])
    #expect(await fixture.profiles.values.first?.reference == fixture.reference)
}

@Test func macConfigSwitchWaitsForConfirmedStopBeforeGrantAndStart() async throws {
    let fixture = MacConfigFixture()
    let config = try await fixture.install()
    await fixture.events.clear()
    let old = try CloudGatewayMacSecretReference(value: "11111111-1111-1111-1111-111111111111")
    await fixture.profiles.setProfiles([
        CloudGatewayMacInstalledProfile(identifier: "other-account/region/client", reference: old, status: .connected),
        CloudGatewayMacInstalledProfile(identifier: config.identifier, reference: fixture.reference, status: .disconnected),
    ])
    try await fixture.coordinator.connect(config)
    #expect(await fixture.events.values == ["available", "profiles", "stop:other-account/region/client", "grant", "start:account/region/client"])
}

@Test func macConfigSwitchStopTimeoutNeverStartsNextTunnel() async throws {
    let fixture = MacConfigFixture()
    let config = try await fixture.install()
    await fixture.events.clear()
    let old = try CloudGatewayMacSecretReference(value: "11111111-1111-1111-1111-111111111111")
    await fixture.profiles.setProfiles([
        CloudGatewayMacInstalledProfile(identifier: "other", reference: old, status: .disconnecting),
        CloudGatewayMacInstalledProfile(identifier: config.identifier, reference: fixture.reference, status: .disconnected),
    ])
    await fixture.profiles.failStop()
    await #expect(throws: MacConfigTestFailure.self) {
        try await fixture.coordinator.connect(config)
    }
    #expect(await fixture.events.values == ["available", "profiles", "stop:other"])
}

@Test func macConfigCancellationDuringSecretInstallPreventsProfileSave() async throws {
    let fixture = MacConfigFixture()
    let gate = MacConfigTestGate()
    await fixture.secrets.pauseInstall(gate)
    let task = Task { try await fixture.install() }
    await gate.waitUntilEntered()
    await fixture.coordinator.cancelPendingWork()
    await gate.release()
    await #expect(throws: CloudGatewayMacConfigError.cancelled) { try await task.value }
    #expect(await fixture.events.values == ["install", "profiles", "rollback"])
}

@Test func macConfigCancellationDuringStartAuthorizationPreventsStart() async throws {
    let fixture = MacConfigFixture()
    let config = try await fixture.install()
    await fixture.events.clear()
    let gate = MacConfigTestGate()
    await fixture.secrets.pauseAuthorization(gate)
    let task = Task { try await fixture.coordinator.connect(config) }
    await gate.waitUntilEntered()
    await fixture.coordinator.cancelPendingWork()
    await gate.release()
    await #expect(throws: CloudGatewayMacConfigError.cancelled) { try await task.value }
    #expect(await fixture.events.values == ["available", "profiles", "grant"])
}

@Test func macConfigCancellationAfterSavedProfileStillCommitsReferencedSecret() async throws {
    let fixture = MacConfigFixture()
    let gate = MacConfigTestGate()
    await fixture.profiles.pauseSave(gate)
    let task = Task { try await fixture.install() }
    await gate.waitUntilEntered()
    await fixture.coordinator.cancelPendingWork()
    await gate.release()
    await #expect(throws: CloudGatewayMacConfigError.cancelled) { try await task.value }
    #expect(await fixture.events.values == ["install", "save", "commit", "cache"])
    #expect(await fixture.profiles.values.first?.reference == fixture.reference)
}

@Test func macConfigParentTaskCancellationStillRollsBackUnreferencedInstall() async throws {
    let fixture = MacConfigFixture()
    let gate = MacConfigTestGate()
    await fixture.secrets.pauseInstall(gate)
    let task = Task { try await fixture.install() }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.release()
    await #expect(throws: CloudGatewayMacConfigError.cancelled) { try await task.value }
    #expect(await fixture.events.values == ["install", "profiles", "rollback"])
}

@Test func macConfigParentTaskCancellationStillCommitsAlreadySavedProfile() async throws {
    let fixture = MacConfigFixture()
    let gate = MacConfigTestGate()
    await fixture.profiles.pauseSave(gate)
    let task = Task { try await fixture.install() }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.release()
    await #expect(throws: CloudGatewayMacConfigError.cancelled) { try await task.value }
    #expect(await fixture.events.values == ["install", "save", "commit", "cache"])
    #expect(await fixture.profiles.values.first?.reference == fixture.reference)
}

@Test func macConfigCancellationWithFailedReloadStillCommitsSavedProfile() async throws {
    let fixture = MacConfigFixture()
    let gate = MacConfigTestGate()
    await fixture.profiles.pauseSave(gate)
    await fixture.profiles.setSaveFailure(.afterSave)
    let task = Task { try await fixture.install() }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.release()
    await #expect(throws: CloudGatewayMacConfigError.cancelled) { try await task.value }
    #expect(await fixture.events.values == ["install", "save", "profiles", "commit", "cache"])
    #expect(await fixture.profiles.values.first?.reference == fixture.reference)
}

@Test func macConfigRecoveredProfileCacheFailureSurfacesPersistenceError() async throws {
    let fixture = MacConfigFixture()
    await fixture.profiles.setSaveFailure(.afterSave)
    await fixture.snapshots.failSave()
    await #expect(throws: CloudGatewayMacConfigError.snapshotPersistenceFailed) { try await fixture.install() }
    #expect(await fixture.events.values == ["install", "save", "profiles", "commit", "cache"])
    #expect(await fixture.profiles.values.first?.reference == fixture.reference)
}

@Test func macConfigCancellationDuringLastStopDoesNotReportCommandSuccess() async throws {
    let fixture = MacConfigFixture()
    await fixture.profiles.setProfiles([
        CloudGatewayMacInstalledProfile(identifier: "account/region/client", reference: fixture.reference, status: .connected)
    ])
    let gate = MacConfigTestGate()
    await fixture.profiles.pauseStop(gate)
    let task = Task { try await fixture.coordinator.turnOff() }
    await gate.waitUntilEntered()
    await fixture.coordinator.cancelPendingWork()
    await gate.release()
    await #expect(throws: CloudGatewayMacConfigError.cancelled) { try await task.value }
    #expect(await fixture.events.values == ["profiles", "stop:account/region/client"])
}

@Test func macConfigCancelPendingWorkBeforeReplacementStopPreservesExistingProfile() async throws {
    let fixture = MacConfigFixture()
    let old = try CloudGatewayMacSecretReference(value: "11111111-1111-1111-1111-111111111111")
    await fixture.profiles.setProfiles([
        CloudGatewayMacInstalledProfile(identifier: "account/region/client", reference: old, status: .connected)
    ])
    let gate = MacConfigTestGate()
    await fixture.profiles.pauseSavePreparation(gate)
    let task = Task { try await fixture.install() }
    await gate.waitUntilEntered()
    await fixture.coordinator.cancelPendingWork()
    await gate.release()
    await #expect(throws: CloudGatewayMacConfigError.cancelled) { try await task.value }
    #expect(await fixture.profiles.values.first?.reference == old)
    #expect(await fixture.events.values == ["install", "save", "profiles", "rollback"])
}

@Test func macConfigCancelPendingWorkInsideStartPreferencesPreventsLiveStart() async throws {
    let fixture = MacConfigFixture()
    let config = try await fixture.install()
    await fixture.events.clear()
    let gate = MacConfigTestGate()
    await fixture.profiles.pauseStartPreparation(gate)
    let task = Task { try await fixture.coordinator.connect(config) }
    await gate.waitUntilEntered()
    await fixture.coordinator.cancelPendingWork()
    await gate.release()
    await #expect(throws: CloudGatewayMacConfigError.cancelled) { try await task.value }
    #expect(await fixture.events.values == ["available", "profiles", "grant"])
}

@Test func macConfigConcurrentCommandIsRejectedWhileInstallationSuspended() async throws {
    let fixture = MacConfigFixture()
    let gate = MacConfigTestGate()
    await fixture.secrets.pauseInstall(gate)
    let task = Task { try await fixture.install() }
    await gate.waitUntilEntered()
    await #expect(throws: CloudGatewayMacConfigError.busy) { try await fixture.coordinator.turnOff() }
    await gate.release()
    _ = try await task.value
}

@Test(arguments: [CloudGatewayTunnelStatus.disconnected, .invalid, .connected, .connecting, .reasserting, .disconnecting])
func macConfigScopedStopOnlyStopsItsExactTarget(status: CloudGatewayTunnelStatus) async throws {
    let fixture = MacConfigFixture()
    let identifier = "account/region/client"
    let target = CloudGatewayMacInstalledProfile(identifier: identifier, reference: fixture.reference, status: status)
    await fixture.profiles.setProfiles([
        .init(identifier: "account/region/other", reference: fixture.reference, status: .connected), target,
        .init(identifier: "another-account/region/client", reference: fixture.reference, status: .connected)
    ])
    try await fixture.coordinator.disconnectClient(identifier: identifier, authorize: {})
    #expect(await fixture.events.values == (target.needsConfirmedStop ? ["profiles", "stop:\(identifier)"] : ["profiles"]))
}

@Test func macConfigScopedStopWithNoInstalledTargetLeavesTheActiveProfileAlone() async throws {
    let fixture = MacConfigFixture()
    await fixture.profiles.setProfiles([
        .init(identifier: "account/region/other", reference: fixture.reference, status: .connected)
    ])
    try await fixture.coordinator.disconnectClient(identifier: "account/region/client", authorize: {})
    #expect(await fixture.events.values == ["profiles"])
}

@Test func macConfigScopedStopRejectsDuplicateInstalledTargets() async throws {
    let fixture = MacConfigFixture()
    let target = CloudGatewayMacInstalledProfile(identifier: "account/region/client", reference: fixture.reference, status: .connected)
    await fixture.profiles.setProfiles([target, target])
    await #expect(throws: CloudGatewayMacConfigError.unavailable) {
        try await fixture.coordinator.disconnectClient(identifier: target.identifier, authorize: {})
    }
    #expect(await fixture.events.values == ["profiles"])
}

@MainActor
@Test func macConfigScopedStopRechecksAuthorizationAfterReadingProfiles() async throws {
    let fixture = MacConfigFixture()
    await fixture.profiles.setProfiles([
        .init(identifier: "account/region/client", reference: fixture.reference, status: .connected)
    ])
    var checks = 0
    await #expect(throws: CloudGatewayMacConfigError.unavailable) {
        try await fixture.coordinator.disconnectClient(identifier: "account/region/client") {
            checks += 1
            if checks == 2 { throw CloudGatewayMacConfigError.unavailable }
        }
    }
    #expect(checks == 2)
    #expect(await fixture.events.values == ["profiles"])
}

@MainActor
@Test func macConfigScopedStopPassesAuthorizationToTheAdapterStopBoundary() async throws {
    let fixture = MacConfigFixture()
    await fixture.profiles.setProfiles([
        .init(identifier: "account/region/client", reference: fixture.reference, status: .connected)
    ])
    var checks = 0
    await #expect(throws: CloudGatewayMacConfigError.unavailable) {
        try await fixture.coordinator.disconnectClient(identifier: "account/region/client") {
            checks += 1
            if checks == 3 { throw CloudGatewayMacConfigError.unavailable }
        }
    }
    #expect(checks == 3)
    #expect(await fixture.events.values == ["profiles"])
}

@Test func macConfigCancellationDrainWaitsForReferencedSecretRecovery() async throws {
    let fixture = MacConfigFixture()
    let saveGate = MacConfigTestGate()
    let cacheGate = MacConfigTestGate()
    await fixture.profiles.pauseSave(saveGate)
    await fixture.profiles.setSaveFailure(.afterSave)
    await fixture.snapshots.pauseSave(cacheGate)
    let command = Task { try await fixture.install() }
    await saveGate.waitUntilEntered()
    await fixture.coordinator.cancelPendingWork()
    let drain = Task {
        await fixture.coordinator.waitForPendingWork()
        await fixture.events.append("drained")
    }
    await saveGate.release()
    await cacheGate.waitUntilEntered()
    await #expect(throws: CloudGatewayMacConfigError.busy) { try await fixture.coordinator.turnOff() }
    await cacheGate.release()
    await #expect(throws: CloudGatewayMacConfigError.cancelled) { try await command.value }
    await drain.value
    #expect(await fixture.events.values == ["install", "save", "profiles", "commit", "cache", "cache-resumed", "drained"])
    try await fixture.coordinator.turnOff()
}

@Test func macConfigCancellationDrainWaitsForUnreferencedSecretRollback() async throws {
    let fixture = MacConfigFixture()
    let installGate = MacConfigTestGate()
    let rollbackGate = MacConfigTestGate()
    await fixture.secrets.pauseInstall(installGate)
    await fixture.secrets.pauseRollback(rollbackGate)
    let command = Task { try await fixture.install() }
    await installGate.waitUntilEntered()
    await fixture.coordinator.cancelPendingWork()
    let drain = Task {
        await fixture.coordinator.waitForPendingWork()
        await fixture.events.append("drained")
    }
    await installGate.release()
    await rollbackGate.waitUntilEntered()
    await #expect(throws: CloudGatewayMacConfigError.busy) { try await fixture.coordinator.turnOff() }
    await rollbackGate.release()
    await #expect(throws: CloudGatewayMacConfigError.cancelled) { try await command.value }
    await drain.value
    #expect(await fixture.events.values == ["install", "profiles", "rollback", "rollback-resumed", "drained"])
    try await fixture.coordinator.turnOff()
}

@Test(arguments: [CloudGatewayTunnelStatus.disconnected, .invalid, .connected, .connecting, .reasserting, .disconnecting])
func macConfigRemovalRequiresAnInactiveExactTarget(status: CloudGatewayTunnelStatus) async throws {
    let fixture = MacConfigFixture()
    let identifier = "account/region/client"
    let target = CloudGatewayMacInstalledProfile(identifier: identifier, reference: fixture.reference, status: status)
    let unrelated: [CloudGatewayMacInstalledProfile] = [
        .init(identifier: "account/region/other", reference: fixture.reference, status: .connected),
        .init(identifier: "other-account/region/client", reference: fixture.reference, status: .connecting)
    ]
    await fixture.profiles.setProfiles(unrelated + [target])
    if target.needsConfirmedStop {
        await #expect(throws: CloudGatewayMacConfigError.clientActive) {
            try await fixture.coordinator.validateInactiveClient(identifier: identifier, authorize: {})
        }
        await #expect(throws: CloudGatewayMacConfigError.clientActive) {
            try await fixture.coordinator.removeClientProfile(identifier: identifier, authorize: {})
        }
        #expect(await fixture.profiles.values == unrelated + [target])
        #expect(await fixture.events.values == ["profiles", "profiles"])
    } else {
        try await fixture.coordinator.validateInactiveClient(identifier: identifier, authorize: {})
        #expect(await fixture.profiles.values == unrelated + [target])
        try await fixture.coordinator.removeClientProfile(identifier: identifier, authorize: {})
        #expect(await fixture.profiles.values == unrelated)
        #expect(await fixture.events.values == ["profiles", "profiles", "remove:\(identifier)", "reload"])
    }
}

@Test func macConfigAbsentRemovalLeavesEveryOtherProfileAndSecretAlone() async throws {
    let fixture = MacConfigFixture()
    let unrelated = CloudGatewayMacInstalledProfile(identifier: "other-account/region/client", reference: fixture.reference, status: .connected)
    await fixture.profiles.setProfiles([unrelated])
    try await fixture.coordinator.validateInactiveClient(identifier: "account/region/client", authorize: {})
    try await fixture.coordinator.removeClientProfile(identifier: "account/region/client", authorize: {})
    #expect(await fixture.profiles.values == [unrelated])
    #expect(await fixture.events.values == ["profiles", "profiles"])
}

@Test(arguments: ["", "client", "account//client", "account/../client", "account/region/client/extra", "account/region/client name"])
func macConfigRemovalRejectsNoncanonicalIdentifiers(identifier: String) async throws {
    let fixture = MacConfigFixture()
    await #expect(throws: CloudGatewayMacConfigError.invalidConfig) {
        try await fixture.coordinator.validateInactiveClient(identifier: identifier, authorize: {})
    }
    await #expect(throws: CloudGatewayMacConfigError.invalidConfig) {
        try await fixture.coordinator.removeClientProfile(identifier: identifier, authorize: {})
    }
    #expect(await fixture.events.values.isEmpty)
}

@Test(arguments: [true, false])
func macConfigRemovalRejectsDuplicateOrMalformedProfiles(duplicate: Bool) async throws {
    let fixture = MacConfigFixture()
    let target = CloudGatewayMacInstalledProfile(identifier: "account/region/client", reference: fixture.reference, status: .disconnected)
    await fixture.profiles.setProfiles(duplicate ? [target, target] : [target, .init(identifier: "malformed", reference: fixture.reference, status: .invalid)])
    await #expect(throws: CloudGatewayMacConfigError.invalidConfig) {
        try await fixture.coordinator.validateInactiveClient(identifier: target.identifier, authorize: {})
    }
    await #expect(throws: CloudGatewayMacConfigError.invalidConfig) {
        try await fixture.coordinator.removeClientProfile(identifier: target.identifier, authorize: {})
    }
    #expect(await fixture.events.values == ["profiles", "profiles"])
}

@Test func macConfigRemovalFailsClosedWhenPreferencesCannotBeRead() async throws {
    let fixture = MacConfigFixture()
    await fixture.profiles.failRead()
    await #expect(throws: MacConfigTestFailure.self) {
        try await fixture.coordinator.validateInactiveClient(identifier: "account/region/client", authorize: {})
    }
    await #expect(throws: MacConfigTestFailure.self) {
        try await fixture.coordinator.removeClientProfile(identifier: "account/region/client", authorize: {})
    }
    #expect(await fixture.events.values == ["profiles", "profiles"])
}

@Test(arguments: [MacConfigTestProfiles.RemovalFailure.beforeRemove, .reload, .stillPresent])
private func macConfigRemovalDoesNotHideRemovalOrReloadFailure(failure: MacConfigTestProfiles.RemovalFailure) async throws {
    let fixture = MacConfigFixture()
    let config = try await fixture.install()
    await fixture.events.clear()
    await fixture.profiles.setRemovalFailure(failure)
    await #expect(throws: MacConfigTestFailure.self) {
        try await fixture.coordinator.removeClientProfile(identifier: config.identifier, authorize: {})
    }
    #expect(await fixture.events.values == (failure == .beforeRemove ? ["profiles"] : ["profiles", "remove:\(config.identifier)", "reload"]))
    #expect(await fixture.profiles.values.isEmpty == (failure == .reload))
}

@Test(arguments: [CloudGatewayTunnelStatus.connected, .connecting, .reasserting, .disconnecting])
func macConfigExternalActivationAtRemovalBoundaryPreventsRemoval(status: CloudGatewayTunnelStatus) async throws {
    let fixture = MacConfigFixture()
    let config = try await fixture.install()
    await fixture.events.clear()
    let gate = MacConfigTestGate()
    await fixture.profiles.pauseRemovalPreparation(gate)
    let task = Task { try await fixture.coordinator.removeClientProfile(identifier: config.identifier, authorize: {}) }
    await gate.waitUntilEntered()
    await fixture.profiles.setProfiles([.init(identifier: config.identifier, reference: fixture.reference, status: status)])
    await gate.release()
    await #expect(throws: CloudGatewayMacConfigError.clientActive) { try await task.value }
    #expect(await fixture.events.values == ["profiles"])
    #expect(await fixture.profiles.values.first?.status == status)
}

@Test(arguments: [true, false])
func macConfigRemovalAndInstallOrStartCannotOverlap(removalFirst: Bool) async throws {
    let fixture = MacConfigFixture()
    let config = try await fixture.install()
    await fixture.events.clear()
    let gate = MacConfigTestGate()
    if removalFirst {
        await fixture.profiles.pauseRemovalPreparation(gate)
        let task = Task { try await fixture.coordinator.removeClientProfile(identifier: config.identifier, authorize: {}) }
        await gate.waitUntilEntered()
        await #expect(throws: CloudGatewayMacConfigError.busy) { try await fixture.install() }
        await #expect(throws: CloudGatewayMacConfigError.busy) { try await fixture.coordinator.connect(config) }
        await #expect(throws: CloudGatewayMacConfigError.busy) {
            try await fixture.coordinator.validateInactiveClient(identifier: config.identifier, authorize: {})
        }
        await gate.release()
        try await task.value
        #expect(await fixture.events.values == ["profiles", "remove:\(config.identifier)", "reload"])
    } else {
        await fixture.profiles.pauseStartPreparation(gate)
        let task = Task { try await fixture.coordinator.connect(config) }
        await gate.waitUntilEntered()
        await #expect(throws: CloudGatewayMacConfigError.busy) {
            try await fixture.coordinator.removeClientProfile(identifier: config.identifier, authorize: {})
        }
        await #expect(throws: CloudGatewayMacConfigError.busy) {
            try await fixture.coordinator.validateInactiveClient(identifier: config.identifier, authorize: {})
        }
        await gate.release()
        _ = try await task.value
        #expect(await fixture.events.values == ["available", "profiles", "grant", "start:\(config.identifier)"])
    }
}

@Test func macConfigInstallationBlocksRemovalAndFreshInactiveValidation() async throws {
    let fixture = MacConfigFixture()
    let gate = MacConfigTestGate()
    await fixture.secrets.pauseInstall(gate)
    let task = Task { try await fixture.install() }
    await gate.waitUntilEntered()
    await #expect(throws: CloudGatewayMacConfigError.busy) {
        try await fixture.coordinator.removeClientProfile(identifier: "account/region/client", authorize: {})
    }
    await #expect(throws: CloudGatewayMacConfigError.busy) {
        try await fixture.coordinator.validateInactiveClient(identifier: "account/region/client", authorize: {})
    }
    await gate.release()
    _ = try await task.value
    #expect(await fixture.events.values == ["install", "save", "commit", "cache"])
}

@MainActor
@Test(arguments: [1, 2, 3, 4, 5, 6])
func macConfigRemovalFencesAuthorizationAtEveryAwaitedBoundary(deniedCheck: Int) async throws {
    let fixture = MacConfigFixture()
    let config = try await fixture.install()
    await fixture.events.clear()
    var checks = 0
    await #expect(throws: CloudGatewayMacConfigError.unavailable) {
        try await fixture.coordinator.removeClientProfile(identifier: config.identifier) {
            checks += 1
            if checks == deniedCheck { throw CloudGatewayMacConfigError.unavailable }
        }
    }
    #expect(checks == deniedCheck)
    let expected = deniedCheck == 1 ? [] : deniedCheck <= 4 ? ["profiles"]
        : deniedCheck == 5 ? ["profiles", "remove:\(config.identifier)"] : ["profiles", "remove:\(config.identifier)", "reload"]
    #expect(await fixture.events.values == expected)
}

@Test(arguments: [true, false])
func macConfigCancellationBeforeRemovalPreservesTheProfile(parentCancellation: Bool) async throws {
    let fixture = MacConfigFixture()
    let config = try await fixture.install()
    await fixture.events.clear()
    let gate = MacConfigTestGate()
    await fixture.profiles.pauseRemovalPreparation(gate)
    let task = Task { try await fixture.coordinator.removeClientProfile(identifier: config.identifier, authorize: {}) }
    await gate.waitUntilEntered()
    if parentCancellation { task.cancel() }
    else { await fixture.coordinator.cancelPendingWork() }
    await gate.release()
    await #expect(throws: CloudGatewayMacConfigError.cancelled) { try await task.value }
    #expect(await fixture.events.values == ["profiles"])
    #expect(await fixture.profiles.values.first?.identifier == config.identifier)
    try await fixture.coordinator.validateInactiveClient(identifier: config.identifier, authorize: {})
}

@Test func macConfigCancellationAfterRemovalDoesNotRestoreTheProfileOrTouchSecrets() async throws {
    let fixture = MacConfigFixture()
    let config = try await fixture.install()
    await fixture.events.clear()
    let gate = MacConfigTestGate()
    await fixture.profiles.pauseRemoval(gate)
    let task = Task { try await fixture.coordinator.removeClientProfile(identifier: config.identifier, authorize: {}) }
    await gate.waitUntilEntered()
    await fixture.coordinator.cancelPendingWork()
    await gate.release()
    await #expect(throws: CloudGatewayMacConfigError.cancelled) { try await task.value }
    #expect(await fixture.events.values == ["profiles", "remove:\(config.identifier)"])
    #expect(await fixture.profiles.values.isEmpty)
}

@Test func macConfigFreshValidationRechecksCancellationAfterObservation() async throws {
    let fixture = MacConfigFixture()
    let gate = MacConfigTestGate()
    await fixture.profiles.pauseRead(gate)
    let task = Task { try await fixture.coordinator.validateInactiveClient(identifier: "account/region/client", authorize: {}) }
    await gate.waitUntilEntered()
    await fixture.coordinator.cancelPendingWork()
    await gate.release()
    await #expect(throws: CloudGatewayMacConfigError.cancelled) { try await task.value }
    #expect(await fixture.events.values == ["profiles"])
}

@MainActor
@Test(arguments: [1, 2])
func macConfigInactiveValidationFencesAuthorizationAroundTheFreshRead(deniedCheck: Int) async throws {
    let fixture = MacConfigFixture()
    var checks = 0
    await #expect(throws: CloudGatewayMacConfigError.unavailable) {
        try await fixture.coordinator.validateInactiveClient(identifier: "account/region/client") {
            checks += 1
            if checks == deniedCheck { throw CloudGatewayMacConfigError.unavailable }
        }
    }
    #expect(checks == deniedCheck)
    #expect(await fixture.events.values == (deniedCheck == 1 ? [] : ["profiles"]))
}

@Test func macConfigInactiveValidationNeverReusesAnEarlierInactiveObservation() async throws {
    let fixture = MacConfigFixture()
    let identifier = "account/region/client"
    try await fixture.coordinator.validateInactiveClient(identifier: identifier, authorize: {})
    await fixture.profiles.setProfiles([.init(identifier: identifier, reference: fixture.reference, status: .disconnecting)])
    await #expect(throws: CloudGatewayMacConfigError.clientActive) {
        try await fixture.coordinator.validateInactiveClient(identifier: identifier, authorize: {})
    }
    #expect(await fixture.events.values == ["profiles", "profiles"])
}

private let macTestWireGuardConfig = """
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.0.0.2/32
DNS = 1.1.1.1
[Peer]
PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
AllowedIPs = 0.0.0.0/0
Endpoint = example.com:51820
"""

private struct MacConfigFixture: Sendable {
    let reference = try! CloudGatewayMacSecretReference(value: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    let events: MacConfigTestEvents
    let secrets: MacConfigTestSecrets
    let profiles: MacConfigTestProfiles
    let snapshots: MacConfigTestSnapshots
    let coordinator: CloudGatewayMacConfigCoordinator

    init() {
        events = MacConfigTestEvents()
        secrets = MacConfigTestSecrets(events: events, reference: reference)
        profiles = MacConfigTestProfiles(events: events)
        snapshots = MacConfigTestSnapshots(events: events)
        coordinator = CloudGatewayMacConfigCoordinator(secrets: secrets, profiles: profiles, snapshots: snapshots)
    }

    func install() async throws -> CloudGatewayMacInstalledConfig {
        try await coordinator.install(option: CloudGatewayClientOption(
            client: CloudGatewayClient(clientId: "client", clientName: "Client", regionId: "region", status: .active,
                                       wireGuardConfig: macTestWireGuardConfig),
            region: CloudGatewayRegion(regionId: "region", displayName: "Region", enabled: true)
        ), accountId: "account")
    }
}

private struct MacConfigTestFailure: Error {}

private actor MacConfigTestEvents {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func clear() { values = [] }
}

private actor MacConfigTestSecrets: CloudGatewayMacSecretClient {
    let events: MacConfigTestEvents
    let reference: CloudGatewayMacSecretReference
    private var commitFails = false
    private var installGate: MacConfigTestGate?
    private var authorizationGate: MacConfigTestGate?
    private var rollbackGate: MacConfigTestGate?

    init(events: MacConfigTestEvents, reference: CloudGatewayMacSecretReference) {
        self.events = events
        self.reference = reference
    }

    func failCommit() { commitFails = true }
    func pauseInstall(_ gate: MacConfigTestGate) { installGate = gate }
    func pauseAuthorization(_ gate: MacConfigTestGate) { authorizationGate = gate }
    func pauseRollback(_ gate: MacConfigTestGate) { rollbackGate = gate }

    func install(configId: String, config: CloudGatewayWireGuardConfig) async throws -> CloudGatewayMacSecretReference {
        try Task.checkCancellation()
        await events.append("install")
        await installGate?.arriveAndWait()
        return reference
    }

    func commit(reference: CloudGatewayMacSecretReference, configId: String) async throws {
        try Task.checkCancellation()
        await events.append("commit")
        if commitFails { throw MacConfigTestFailure() }
    }

    func rollback(reference: CloudGatewayMacSecretReference, configId: String) async throws {
        try Task.checkCancellation()
        await events.append("rollback")
        if let rollbackGate {
            await rollbackGate.arriveAndWait()
            await events.append("rollback-resumed")
        }
    }

    func isAvailable(reference: CloudGatewayMacSecretReference, configId: String) async throws -> Bool {
        try Task.checkCancellation()
        await events.append("available")
        return true
    }

    func authorizeStart(reference: CloudGatewayMacSecretReference, configId: String) async throws -> String {
        try Task.checkCancellation()
        await events.append("grant")
        await authorizationGate?.arriveAndWait()
        return "single-use-start-grant"
    }
}

private actor MacConfigTestProfiles: CloudGatewayMacProfileAdapter {
    enum SaveFailure { case beforeSave, afterSave, unknownPreferences }
    enum RemovalFailure: Sendable { case beforeRemove, reload, stillPresent }
    let events: MacConfigTestEvents
    var values: [CloudGatewayMacInstalledProfile] = []
    private var saveFailure: SaveFailure?
    private var readFails = false
    private var stopFails = false
    private var saveGate: MacConfigTestGate?
    private var savePreparationGate: MacConfigTestGate?
    private var startPreparationGate: MacConfigTestGate?
    private var stopGate: MacConfigTestGate?
    private var readGate: MacConfigTestGate?
    private var removalPreparationGate: MacConfigTestGate?
    private var removalGate: MacConfigTestGate?
    private var removalFailure: RemovalFailure?

    init(events: MacConfigTestEvents) { self.events = events }
    func setSaveFailure(_ failure: SaveFailure) { saveFailure = failure }
    func setProfiles(_ profiles: [CloudGatewayMacInstalledProfile]) { values = profiles }
    func failStop() { stopFails = true }
    func pauseSave(_ gate: MacConfigTestGate) { saveGate = gate }
    func pauseSavePreparation(_ gate: MacConfigTestGate) { savePreparationGate = gate }
    func pauseStartPreparation(_ gate: MacConfigTestGate) { startPreparationGate = gate }
    func pauseStop(_ gate: MacConfigTestGate) { stopGate = gate }
    func failRead() { readFails = true }
    func pauseRead(_ gate: MacConfigTestGate) { readGate = gate }
    func pauseRemovalPreparation(_ gate: MacConfigTestGate) { removalPreparationGate = gate }
    func pauseRemoval(_ gate: MacConfigTestGate) { removalGate = gate }
    func setRemovalFailure(_ failure: RemovalFailure) { removalFailure = failure }

    func installedProfiles() async throws -> [CloudGatewayMacInstalledProfile] {
        try Task.checkCancellation()
        await events.append("profiles")
        await readGate?.arriveAndWait()
        if readFails { throw MacConfigTestFailure() }
        return values
    }

    func saveAndReload(_ config: CloudGatewayMacInstalledConfig) async throws {
        try Task.checkCancellation()
        await events.append("save")
        await savePreparationGate?.arriveAndWait()
        try Task.checkCancellation()
        if saveFailure == .beforeSave { throw MacConfigTestFailure() }
        if saveFailure == .unknownPreferences {
            readFails = true
            throw MacConfigTestFailure()
        }
        if values.contains(where: { $0.identifier == config.identifier && $0.needsConfirmedStop }) {
            await events.append("replacement-stop")
        }
        values.removeAll { $0.identifier == config.identifier }
        values.append(CloudGatewayMacInstalledProfile(identifier: config.identifier, reference: try config.reference, status: .disconnected))
        await saveGate?.arriveAndWait()
        if saveFailure == .afterSave { throw MacConfigTestFailure() }
    }

    func start(identifier: String, grant _: String) async throws {
        try Task.checkCancellation()
        await startPreparationGate?.arriveAndWait()
        try Task.checkCancellation()
        await events.append("start:\(identifier)")
    }

    func stopAndWait(identifier: String) async throws {
        try Task.checkCancellation()
        await events.append("stop:\(identifier)")
        await stopGate?.arriveAndWait()
        if stopFails { throw MacConfigTestFailure() }
    }

    func stopAndWait(identifier: String, authorize: @escaping @MainActor @Sendable () throws -> Void) async throws {
        await stopGate?.arriveAndWait()
        try Task.checkCancellation()
        try await authorize()
        try Task.checkCancellation()
        await events.append("stop:\(identifier)")
        if stopFails { throw MacConfigTestFailure() }
    }

    func remove(identifier: String, authorize: @escaping @MainActor @Sendable () throws -> Void) async throws {
        try Task.checkCancellation()
        try await authorize()
        guard let expected = try CloudGatewayMacProfileMetadata.inactiveTarget(identifier: identifier, profiles: values) else { return }
        await removalPreparationGate?.arriveAndWait()
        try Task.checkCancellation()
        try await authorize()
        try Task.checkCancellation()
        guard let current = try CloudGatewayMacProfileMetadata.inactiveTarget(identifier: identifier, profiles: values),
              current.reference == expected.reference else { throw CloudGatewayMacConfigError.invalidConfig }
        if removalFailure == .beforeRemove { throw MacConfigTestFailure() }
        await events.append("remove:\(identifier)")
        values.removeAll { $0.identifier == identifier }
        await removalGate?.arriveAndWait()
        try Task.checkCancellation()
        try await authorize()
        await events.append("reload")
        if removalFailure == .reload { throw MacConfigTestFailure() }
        if removalFailure == .stillPresent { values.append(expected) }
        guard !values.contains(where: { $0.identifier == identifier }) else { throw MacConfigTestFailure() }
    }
}

private actor MacConfigTestSnapshots: CloudGatewayMacSnapshotPersisting {
    let events: MacConfigTestEvents
    private var saveFails = false
    private var saveGate: MacConfigTestGate?
    init(events: MacConfigTestEvents) { self.events = events }
    func failSave() { saveFails = true }
    func pauseSave(_ gate: MacConfigTestGate) { saveGate = gate }
    func save(_: CloudGatewayMacInstalledConfig) async throws {
        try Task.checkCancellation()
        await events.append("cache")
        if let saveGate {
            await saveGate.arriveAndWait()
            await events.append("cache-resumed")
        }
        if saveFails { throw MacConfigTestFailure() }
    }
}

private actor MacConfigTestGate {
    private var entered = false
    private var released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        entered = true
        observers.forEach { $0.resume() }
        observers = []
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
