import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation
import Testing
@testable import CloudGatewayMacCore

@MainActor
@Test(arguments: [CloudGatewayTunnelStatus.disconnected, .invalid])
func macProfileRemovalRemovesOnlyTheExactInactiveManager(status: CloudGatewayTunnelStatus) async throws {
    let preferences = MacRemovalPreferences()
    let target = MacRemovalManager(status: status)
    let other = MacRemovalManager(identifier: "account/region/other", status: .connected)
    let otherAccount = MacRemovalManager(identifier: "other-account/region/client", status: .reasserting)
    preferences.managers = [other, otherAccount, target]
    try await preferences.perform()
    #expect(preferences.managers.count == 2)
    #expect(preferences.managers[0] === other)
    #expect(preferences.managers[1] === otherAccount)
    #expect(preferences.removed == [target.identifier])
    #expect(preferences.events == ["load", "reload", "remove", "load"])
}

@MainActor
@Test func macProfileRemovalTreatsAbsenceAsSuccessWithoutSelectingAnotherManager() async throws {
    let preferences = MacRemovalPreferences()
    let other = MacRemovalManager(identifier: "account/region/other", status: .connected)
    preferences.managers = [other]
    try await preferences.perform()
    #expect(preferences.managers.count == 1)
    #expect(preferences.managers[0] === other)
    #expect(preferences.removed.isEmpty)
    #expect(preferences.events == ["load"])
}

@MainActor
@Test(arguments: [CloudGatewayTunnelStatus.connected, .connecting, .reasserting, .disconnecting])
func macProfileRemovalRejectsEveryActiveStateBeforeReloadOrMutation(status: CloudGatewayTunnelStatus) async throws {
    let preferences = MacRemovalPreferences()
    preferences.managers = [MacRemovalManager(status: status)]
    await #expect(throws: CloudGatewayMacConfigError.clientActive) { try await preferences.perform() }
    #expect(preferences.removed.isEmpty)
    #expect(preferences.events == ["load"])
}

@MainActor
@Test(arguments: [true, false])
func macProfileRemovalRejectsDuplicatesAndMalformedOwnedMetadata(duplicate: Bool) async throws {
    let preferences = MacRemovalPreferences()
    let target = MacRemovalManager()
    let other = MacRemovalManager()
    if !duplicate { other.metadata[CloudGatewayMacProviderKey.secretReference] = "malformed" }
    preferences.managers = [target, other]
    await #expect(throws: CloudGatewayMacConfigError.invalidConfig) { try await preferences.perform() }
    #expect(preferences.removed.isEmpty)
    #expect(preferences.events == ["load"])
}

@MainActor
@Test(arguments: [CloudGatewayTunnelStatus.connected, .connecting, .reasserting, .disconnecting])
func macProfileRemovalRechecksExternalActivationImmediatelyBeforeMutation(status: CloudGatewayTunnelStatus) async throws {
    let preferences = MacRemovalPreferences()
    let target = MacRemovalManager()
    preferences.managers = [target]
    preferences.onReload = { target.status = status }
    await #expect(throws: CloudGatewayMacConfigError.clientActive) { try await preferences.perform() }
    #expect(preferences.managers.count == 1)
    #expect(preferences.removed.isEmpty)
    #expect(preferences.events == ["load", "reload"])
}

@MainActor
@Test(arguments: ["identity", "reference", "ownership", "metadata"])
func macProfileRemovalRechecksIdentityReferenceOwnershipAndMetadata(change: String) async throws {
    let preferences = MacRemovalPreferences()
    let target = MacRemovalManager()
    preferences.managers = [target]
    preferences.onReload = {
        switch change {
        case "identity":
            target.metadata[CloudGatewayMacProviderKey.configId] = "other-account/region/client"
            target.metadata[CloudGatewayProviderConfigurationKey.tunnelIdentifier] = "other-account/region/client"
        case "reference":
            target.metadata[CloudGatewayMacProviderKey.secretReference] = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        case "ownership": target.owned = false
        default: target.metadata[CloudGatewayProviderConfigurationKey.tunnelIdentifier] = "malformed"
        }
    }
    await #expect(throws: CloudGatewayMacConfigError.invalidConfig) { try await preferences.perform() }
    #expect(preferences.removed.isEmpty)
    #expect(preferences.events == ["load", "reload"])
}

@MainActor
@Test(arguments: [MacRemovalFailure.load, .reload, .remove, .verification])
private func macProfileRemovalPropagatesObservationMutationAndVerificationFailures(failure: MacRemovalFailure) async throws {
    let preferences = MacRemovalPreferences()
    preferences.managers = [MacRemovalManager()]
    preferences.failure = failure
    await #expect(throws: failure) { try await preferences.perform() }
    #expect(preferences.removed.isEmpty == (failure != .verification))
    #expect(preferences.managers.isEmpty == (failure == .verification))
}

@MainActor
@Test func macProfileRemovalRequiresVerifiedAbsenceAfterPreferencesRemoval() async throws {
    let preferences = MacRemovalPreferences()
    preferences.managers = [MacRemovalManager()]
    preferences.retainRemovedManager = true
    await #expect(throws: CloudGatewayMacConfigError.unavailable) { try await preferences.perform() }
    #expect(preferences.events == ["load", "reload", "remove", "load"])
    #expect(preferences.managers.count == 1)
}

@MainActor
@Test(arguments: [1, 2, 3, 4, 5])
func macProfileRemovalAuthorizesEveryAwaitedPreferencesBoundary(deniedCheck: Int) async throws {
    let preferences = MacRemovalPreferences()
    preferences.managers = [MacRemovalManager()]
    var checks = 0
    await #expect(throws: CloudGatewayMacConfigError.cancelled) {
        try await preferences.perform {
            checks += 1
            if checks == deniedCheck { throw CloudGatewayMacConfigError.cancelled }
        }
    }
    #expect(checks == deniedCheck)
    #expect(preferences.removed.isEmpty == (deniedCheck <= 3))
    let expected = deniedCheck == 1 ? [] : deniedCheck == 2 ? ["load"]
        : deniedCheck == 3 ? ["load", "reload"] : deniedCheck == 4 ? ["load", "reload", "remove"]
        : ["load", "reload", "remove", "load"]
    #expect(preferences.events == expected)
}

@MainActor
@Test func macProfileRemovalCancellationAtTheFinalAuthorizationCannotMutatePreferences() async throws {
    let preferences = MacRemovalPreferences()
    preferences.managers = [MacRemovalManager()]
    let task = Task {
        var checks = 0
        try await preferences.perform {
            checks += 1
            if checks == 3 { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(preferences.removed.isEmpty)
    #expect(preferences.events == ["load", "reload"])
}

private enum MacRemovalFailure: Error, Equatable {
    case load, reload, remove, verification
}

@MainActor
private final class MacRemovalManager {
    let identifier: String
    var metadata: [String: Any]
    var status: CloudGatewayTunnelStatus
    var owned = true

    init(identifier: String = "account/region/client", status: CloudGatewayTunnelStatus = .disconnected) {
        self.identifier = identifier
        self.status = status
        metadata = [
            CloudGatewayMacProviderKey.configId: identifier,
            CloudGatewayProviderConfigurationKey.tunnelIdentifier: identifier,
            CloudGatewayMacProviderKey.secretReference: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        ]
    }
}

@MainActor
private final class MacRemovalPreferences {
    var managers: [MacRemovalManager] = []
    var events: [String] = []
    var removed: [String] = []
    var failure: MacRemovalFailure?
    var retainRemovedManager = false
    var onReload: (() -> Void)?

    func perform(authorize: @MainActor () throws -> Void = {}) async throws {
        try await CloudGatewayMacProfileRemoval.perform(identifier: "account/region/client", authorize: authorize, load: {
            let verifying = self.events.contains("load")
            self.events.append("load")
            if self.failure == .load { throw MacRemovalFailure.load }
            if verifying, self.failure == .verification { throw MacRemovalFailure.verification }
            return self.managers
        }, profile: { manager in
            guard manager.owned else { throw CloudGatewayMacConfigError.invalidConfig }
            return try CloudGatewayMacProfileMetadata.decode(manager.metadata, status: manager.status)
        }, reload: { _ in
            self.events.append("reload")
            if self.failure == .reload { throw MacRemovalFailure.reload }
            self.onReload?()
        }, remove: { manager in
            self.events.append("remove")
            if self.failure == .remove { throw MacRemovalFailure.remove }
            self.removed.append(manager.identifier)
            if !self.retainRemovedManager { self.managers.removeAll { $0 === manager } }
        })
    }
}
