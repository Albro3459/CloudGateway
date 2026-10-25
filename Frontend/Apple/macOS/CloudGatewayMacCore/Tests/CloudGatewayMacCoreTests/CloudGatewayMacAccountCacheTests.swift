import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation
import Testing
@testable import CloudGatewayMacCore

@Test func accountCacheStoresMetadataAndSelectionWithoutConfigMaterial() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())")
    let cache = CloudGatewayMacAccountCache(directory: directory)
    let (config, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    try await cache.save(config)
    try await cache.select(identifier: config.identifier, accountId: "user-a")
    let restored = try await CloudGatewayMacAccountCache(directory: directory).load(accountId: "user-a")
    #expect(restored.configs == [config])
    #expect(restored.selectedIdentifier == config.identifier)
    #expect(restored.accessAllowed)
    let accountDirectories = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let data = try Data(contentsOf: #require(accountDirectories.first).appendingPathComponent("inventory.json"))
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("PrivateKey"))
    #expect(!json.contains("wireGuardConfig"))
    #expect(!json.contains("customToken"))
    let permissions = try FileManager.default.attributesOfItem(atPath: accountDirectories[0].path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o700)
}

@Test func accountCacheDoesNotShareInventoryOrSelectionBetweenAccounts() async throws {
    let cache = CloudGatewayMacAccountCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())"))
    let (config, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    try await cache.save(config)
    try await cache.select(identifier: config.identifier, accountId: "user-a")
    let other = try await cache.load(accountId: "user-b")
    #expect(other.configs.isEmpty)
    #expect(other.selectedIdentifier == nil)
    #expect(!other.accessAllowed)
    await #expect(throws: CloudGatewayMacCacheError.invalidMetadata) {
        try await cache.select(identifier: config.identifier, accountId: "user-b")
    }
    #expect(try await cache.load(accountId: "user-a").configs == [config])
}

@Test func explicitDenialPersistsAndLateInstallationCannotRestoreOfflineAccess() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())")
    let cache = CloudGatewayMacAccountCache(directory: directory)
    let (config, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    try await cache.save(config)
    try await cache.deny(accountId: "user-a")
    await #expect(throws: CloudGatewayMacCacheError.accessDenied) {
        try await cache.save(config)
    }
    let restored = try await CloudGatewayMacAccountCache(directory: directory).load(accountId: "user-a")
    #expect(restored.configs.isEmpty)
    #expect(!restored.accessAllowed)
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    #expect(try await cache.load(accountId: "user-a").accessAllowed)
}

@Test func denialStillBlocksOfflineCacheWhenPersistenceFails() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())")
    let cache = CloudGatewayMacAccountCache(directory: directory)
    let (config, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    try await cache.save(config)
    let directories = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let accountDirectory = try #require(directories.first)
    let backup = directory.appendingPathComponent("backup")
    try FileManager.default.moveItem(at: accountDirectory, to: backup)
    try Data().write(to: accountDirectory)
    await #expect(throws: CloudGatewayMacCacheError.unavailable) { try await cache.deny(accountId: "user-a") }
    try FileManager.default.moveItem(at: accountDirectory, to: directory.appendingPathComponent("blocker"))
    try FileManager.default.moveItem(at: backup, to: accountDirectory)
    let denied = try await cache.load(accountId: "user-a")
    #expect(!denied.accessAllowed)
    #expect(denied.configs.isEmpty)
    await #expect(throws: CloudGatewayMacCacheError.accessDenied) { try await cache.save(config) }
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    try await cache.save(config)
    #expect(try await cache.load(accountId: "user-a").configs == [config])
}

@Test func successfulRefreshPrunesRevokedOrRotatedInstalledConfigs() async throws {
    let cache = CloudGatewayMacAccountCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())"))
    let (config, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    try await cache.save(config)
    try await cache.select(identifier: config.identifier, accountId: "user-a")
    let (_, rotated) = try accountCacheFixture(accountId: "user-a", address: "10.0.0.3/32")
    try await cache.authorize(accountId: "user-a", role: .user, options: [rotated])
    #expect(try await cache.load(accountId: "user-a").configs.isEmpty)
    #expect(try await cache.load(accountId: "user-a").selectedIdentifier == nil)
    await #expect(throws: CloudGatewayMacCacheError.accessDenied) { try await cache.save(config) }
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    try await cache.save(config)
    try await cache.authorize(accountId: "user-a", role: .user, options: [])
    #expect(try await cache.load(accountId: "user-a").configs.isEmpty)
}

@Test func refreshUpdatesOfflineNamesWithoutReplacingInstalledSecret() async throws {
    let cache = CloudGatewayMacAccountCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())"))
    let (config, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    try await cache.save(config)
    try await cache.select(identifier: config.identifier, accountId: "user-a")
    let (_, renamed) = try accountCacheFixture(accountId: "user-a", clientName: "Renamed Mac", regionName: "Renamed Region")
    try await cache.authorize(accountId: "user-a", role: .user, options: [renamed])
    let restored = try await cache.load(accountId: "user-a")
    let saved = try #require(restored.configs.first)
    #expect(saved.snapshot.clientName == "Renamed Mac")
    #expect(saved.snapshot.regionDisplayName == "Renamed Region")
    #expect(saved.snapshot.secretReference == config.snapshot.secretReference)
    #expect(saved.snapshot.configHash == config.snapshot.configHash)
    #expect(restored.selectedIdentifier == config.identifier)
}

@Test func duplicateAuthorizationDoesNotReplaceValidCache() async throws {
    let cache = CloudGatewayMacAccountCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())"))
    let (config, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    try await cache.save(config)
    await #expect(throws: CloudGatewayMacCacheError.invalidMetadata) {
        try await cache.authorize(accountId: "user-a", role: .user, options: [option, option])
    }
    #expect(try await cache.load(accountId: "user-a").configs == [config])
}

@Test func removedClientHistoryDoesNotBlockLiveInventoryOrRetainRemovedConfigs() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())")
    let cache = CloudGatewayMacAccountCache(directory: directory)
    let (config, option) = try accountCacheFixture(accountId: "user-a")
    let history = (0..<1001).map { index in
        CloudGatewayClientOption(client: CloudGatewayClient(
            clientId: "removed-\(index)", clientName: nil, regionId: "us-a", status: .removed,
            wireGuardConfig: nil, ownerUid: "user-a"
        ), region: option.region)
    }
    try await cache.authorize(accountId: "user-a", role: .user, options: history + [option])
    try await cache.save(config)
    #expect(try await CloudGatewayMacAccountCache(directory: directory).load(accountId: "user-a").configs == [config])
    try await cache.authorize(accountId: "user-a", role: .user, options: history)
    #expect(try await cache.load(accountId: "user-a").configs.isEmpty)
    await #expect(throws: CloudGatewayMacCacheError.accessDenied) { try await cache.save(config) }
}

@Test func liveInventoryLimitStillRejectsOverflowWithoutChangingAuthorization() async throws {
    let cache = CloudGatewayMacAccountCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())"))
    let (config, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    try await cache.save(config)
    let overflow = (0..<1001).map { index in
        CloudGatewayClientOption(client: CloudGatewayClient(
            clientId: "active-\(index)", clientName: nil, regionId: "us-a", status: .active,
            wireGuardConfig: option.client.wireGuardConfig, ownerUid: "user-a"
        ), region: option.region)
    }
    await #expect(throws: CloudGatewayMacCacheError.invalidMetadata) {
        try await cache.authorize(accountId: "user-a", role: .user, options: overflow)
    }
    #expect(try await cache.load(accountId: "user-a").configs == [config])
}

@Test func cacheRejectsUnboundOrNonMacSecretReferences() async throws {
    let cache = CloudGatewayMacAccountCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())"))
    let (config, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    let forged = CloudGatewayMacInstalledConfig(accountId: "user-b", identifier: config.identifier, snapshot: config.snapshot)
    await #expect(throws: CloudGatewayMacCacheError.invalidMetadata) { try await cache.save(forged) }
    await #expect(throws: CloudGatewayMacCacheError.invalidMetadata) { try await cache.load(accountId: "") }
    let (foreignService, _) = try accountCacheFixture(
        accountId: "user-a", secretReference: .init(service: "com.example.other", account: config.snapshot.secretReference.account)
    )
    await #expect(throws: CloudGatewayMacConfigError.invalidConfig) { try await cache.save(foreignService) }
    let (malformedReference, _) = try accountCacheFixture(
        accountId: "user-a", secretReference: .init(service: CloudGatewayMacInstalledConfig.secretService, account: "invalid")
    )
    await #expect(throws: CloudGatewayMacSecretError.invalidRequest) { try await cache.save(malformedReference) }
    try await cache.save(config)
    #expect(try await cache.load(accountId: "user-a").configs == [config])
}

@Test func adminDowngradeBlocksTransportFallbackAndPersistsAcrossRestart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())")
    let cache = CloudGatewayMacAccountCache(directory: directory)
    let (config, option) = try accountCacheFixture(accountId: "user-a", ownerUid: "other-owner")
    try await cache.authorize(accountId: "user-a", role: .admin, options: [option])
    try await cache.save(config)
    try await cache.select(identifier: config.identifier, accountId: "user-a")
    #expect(try await cache.observeRole(accountId: "user-a", role: .user))
    let denied = try await cache.load(accountId: "user-a")
    #expect(denied.configs.isEmpty)
    #expect(denied.selectedIdentifier == nil)
    #expect(!CloudGatewayMacOfflinePolicy.canUseCache(after: .transport, cache: denied))
    await #expect(throws: CloudGatewayMacCacheError.accessDenied) { try await cache.save(config) }
    let restored = try await CloudGatewayMacAccountCache(directory: directory).load(accountId: "user-a")
    #expect(restored == denied)
    try await cache.authorize(accountId: "user-a", role: .user, options: [])
    #expect(try await cache.load(accountId: "user-a").accessAllowed)
}

@Test(arguments: [CloudGatewayMacAccountRole.user, .admin])
func observingUnchangedRolePreservesOfflineInventory(role: CloudGatewayMacAccountRole) async throws {
    let cache = CloudGatewayMacAccountCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())"))
    let (config, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: role, options: [option])
    try await cache.save(config)
    try await cache.select(identifier: config.identifier, accountId: "user-a")
    let saved = try await cache.load(accountId: "user-a")
    #expect(try await cache.observeRole(accountId: "user-a", role: role) == false)
    #expect(try await cache.load(accountId: "user-a") == saved)
    #expect(CloudGatewayMacOfflinePolicy.canUseCache(after: .transport, cache: saved))
}

@Test func cancelledRoleObservationStillPersistsKnownDowngrade() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())")
    let cache = CloudGatewayMacAccountCache(directory: directory)
    let (config, option) = try accountCacheFixture(accountId: "user-a", ownerUid: "other-owner")
    try await cache.authorize(accountId: "user-a", role: .admin, options: [option])
    try await cache.save(config)
    let observation = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await cache.observeRole(accountId: "user-a", role: .user)
    }
    #expect(try await observation.value)
    let reopened = try await CloudGatewayMacAccountCache(directory: directory).load(accountId: "user-a")
    #expect(reopened.configs.isEmpty)
    #expect(!CloudGatewayMacOfflinePolicy.canUseCache(after: .transport, cache: reopened))
}

@Test func observingAdminUpgradeRetainsOnlyPreviouslyAuthorizedUserInventory() async throws {
    let cache = CloudGatewayMacAccountCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())"))
    let (config, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    try await cache.save(config)
    let saved = try await cache.load(accountId: "user-a")
    #expect(try await cache.observeRole(accountId: "user-a", role: .admin) == false)
    #expect(try await cache.load(accountId: "user-a") == saved)
}

@Test func legacyCacheWithoutRoleRequiresCompleteAuthorizedRefresh() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())")
    let cache = CloudGatewayMacAccountCache(directory: directory)
    let (config, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .admin, options: [option])
    try await cache.save(config)
    try await cache.select(identifier: config.identifier, accountId: "user-a")
    let accountDirectories = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let path = try #require(accountDirectories.first).appendingPathComponent("inventory.json")
    var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    legacy.removeValue(forKey: "authorizedRole")
    try JSONSerialization.data(withJSONObject: legacy).write(to: path, options: .atomic)
    let reopened = CloudGatewayMacAccountCache(directory: directory)
    let restored = try await reopened.load(accountId: "user-a")
    #expect(restored.configs.isEmpty)
    #expect(restored.selectedIdentifier == nil)
    #expect(!CloudGatewayMacOfflinePolicy.canUseCache(after: .transport, cache: restored))
    await #expect(throws: CloudGatewayMacCacheError.accessDenied) { try await reopened.save(config) }
    try await reopened.authorize(accountId: "user-a", role: .user, options: [option])
    try await reopened.save(config)
    #expect(try await reopened.load(accountId: "user-a").configs == [config])
}

@Test func userAuthorizationRejectsAnotherOwnersOptionsWithoutChangingCache() async throws {
    let cache = CloudGatewayMacAccountCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())"))
    let (config, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    try await cache.save(config)
    let (_, otherOwnersOption) = try accountCacheFixture(accountId: "user-a", ownerUid: "other-owner")
    await #expect(throws: CloudGatewayMacCacheError.accessDenied) {
        try await cache.authorize(accountId: "user-a", role: .user, options: [otherOwnersOption])
    }
    #expect(try await cache.load(accountId: "user-a").configs == [config])
}

@Test func downgradeBlocksOfflineCacheEvenWhenDenialPersistenceFails() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())")
    let cache = CloudGatewayMacAccountCache(directory: directory)
    let (config, option) = try accountCacheFixture(accountId: "user-a", ownerUid: "other-owner")
    try await cache.authorize(accountId: "user-a", role: .admin, options: [option])
    try await cache.save(config)
    let directories = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let accountDirectory = try #require(directories.first)
    let backup = directory.appendingPathComponent("backup")
    try FileManager.default.moveItem(at: accountDirectory, to: backup)
    try Data().write(to: accountDirectory)
    await #expect(throws: CloudGatewayMacCacheError.unavailable) {
        try await cache.observeRole(accountId: "user-a", role: .user)
    }
    try FileManager.default.moveItem(at: accountDirectory, to: directory.appendingPathComponent("blocker"))
    try FileManager.default.moveItem(at: backup, to: accountDirectory)
    let denied = try await cache.load(accountId: "user-a")
    #expect(denied.configs.isEmpty)
    #expect(!CloudGatewayMacOfflinePolicy.canUseCache(after: .transport, cache: denied))
    await #expect(throws: CloudGatewayMacCacheError.accessDenied) { try await cache.save(config) }
}

@Test(arguments: [false, true], [CloudGatewayMacAccountRole.user, .admin])
func evictionPreservesOtherClientsAuthorizationRoleAndSelection(selectedTarget: Bool, role: CloudGatewayMacAccountRole) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())")
    let cache = CloudGatewayMacAccountCache(directory: directory)
    let (target, targetOption) = try accountCacheFixture(accountId: "user-a")
    let (remaining, remainingOption) = try accountCacheFixture(accountId: "user-a", clientId: "client-b")
    let (otherAccount, otherOption) = try accountCacheFixture(accountId: "user-b")
    try await cache.authorize(accountId: "user-a", role: role, options: [targetOption, remainingOption])
    try await cache.save(target)
    try await cache.save(remaining)
    try await cache.select(identifier: selectedTarget ? target.identifier : remaining.identifier, accountId: "user-a")
    try await cache.authorize(accountId: "user-b", role: .user, options: [otherOption])
    try await cache.save(otherAccount)
    try await cache.select(identifier: otherAccount.identifier, accountId: "user-b")
    let otherBefore = try await cache.load(accountId: "user-b")

    let evicted = try await cache.evict(identifier: target.identifier, accountId: "user-a")
    #expect(evicted.configs == [remaining])
    #expect(evicted.selectedIdentifier == (selectedTarget ? nil : remaining.identifier))
    #expect(evicted.accessAllowed)
    let reopened = CloudGatewayMacAccountCache(directory: directory)
    #expect(try await reopened.load(accountId: "user-a") == evicted)
    #expect(try await reopened.load(accountId: "user-b") == otherBefore)
    #expect(try await reopened.observeRole(accountId: "user-a", role: role) == false)
    #expect(CloudGatewayMacOfflinePolicy.canUseCache(after: .transport, cache: evicted))
    await #expect(throws: CloudGatewayMacCacheError.accessDenied) { try await reopened.save(target) }
    await #expect(throws: CloudGatewayMacCacheError.invalidMetadata) {
        try await reopened.select(identifier: target.identifier, accountId: "user-a")
    }
    try await reopened.save(remaining)
    try await reopened.select(identifier: remaining.identifier, accountId: "user-a")
    #expect(try await reopened.load(accountId: "user-a").selectedIdentifier == remaining.identifier)
    #expect(try await reopened.observeRole(accountId: "user-a", role: .user) == (role == .admin))
}

@Test func evictionRevokesANeverInstalledClientAndIsIdempotent() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())")
    let cache = CloudGatewayMacAccountCache(directory: directory)
    let (target, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    let evicted = try await cache.evict(identifier: target.identifier, accountId: "user-a")
    #expect(evicted == .init(accessAllowed: true))
    let reopened = CloudGatewayMacAccountCache(directory: directory)
    await #expect(throws: CloudGatewayMacCacheError.accessDenied) { try await reopened.save(target) }
    #expect(try await reopened.evict(identifier: target.identifier, accountId: "user-a") == evicted)
    try await reopened.authorize(accountId: "user-a", role: .user, options: [option])
    try await reopened.save(target)
    #expect(try await reopened.load(accountId: "user-a").configs == [target])
    #expect(try await reopened.load(accountId: "user-a").selectedIdentifier == nil)
}

@Test(arguments: [
    "user-b/us-a/client-a", "user-a/us-a/", "user-a//client-a", "/us-a/client-a",
    "user-a/us-a/client-a/extra", "user-a/../client-a", "user-a/./client-a",
    "user-a/us a/client-a", "user-a/us-a/client\na", "user-a/us-a/clïent-a",
    "user-a/us-a/" + String(repeating: "a", count: 257), "user-a-prefix/us-a/client-a"
])
func evictionRejectsInvalidNamespacesWithoutChangingCache(identifier: String) async throws {
    let cache = CloudGatewayMacAccountCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())"))
    let (config, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    try await cache.save(config)
    try await cache.select(identifier: config.identifier, accountId: "user-a")
    let before = try await cache.load(accountId: "user-a")
    await #expect(throws: CloudGatewayMacCacheError.invalidMetadata) {
        try await cache.evict(identifier: identifier, accountId: "user-a")
    }
    #expect(try await cache.load(accountId: "user-a") == before)
    try await cache.save(config)
}

@Test(arguments: ["", "user\na", "user/a", ".", "..", String(repeating: "a", count: 129)])
func evictionRejectsInvalidAccountNamespaces(accountId: String) async throws {
    let cache = CloudGatewayMacAccountCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())"))
    await #expect(throws: CloudGatewayMacCacheError.invalidMetadata) {
        try await cache.evict(identifier: "\(accountId)/us-a/client-a", accountId: accountId)
    }
}

@Test func evictionReportsFailedPersistenceAndLeavesExistingCacheIntact() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())")
    let cache = CloudGatewayMacAccountCache(directory: directory)
    let (target, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    try await cache.save(target)
    try await cache.select(identifier: target.identifier, accountId: "user-a")
    let before = try await cache.load(accountId: "user-a")
    let accountDirectory = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
    let backup = directory.appendingPathComponent("backup")
    try FileManager.default.moveItem(at: accountDirectory, to: backup)
    try Data().write(to: accountDirectory)
    await #expect(throws: CloudGatewayMacCacheError.unavailable) {
        try await cache.evict(identifier: target.identifier, accountId: "user-a")
    }
    try FileManager.default.moveItem(at: accountDirectory, to: directory.appendingPathComponent("blocker"))
    try FileManager.default.moveItem(at: backup, to: accountDirectory)
    #expect(try await CloudGatewayMacAccountCache(directory: directory).load(accountId: "user-a") == before)
}

@Test func evictionDoesNotOverwriteAnInvalidPayload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayCacheTests-\(UUID())")
    let cache = CloudGatewayMacAccountCache(directory: directory)
    let (target, option) = try accountCacheFixture(accountId: "user-a")
    try await cache.authorize(accountId: "user-a", role: .user, options: [option])
    try await cache.save(target)
    let accountDirectory = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
    let path = accountDirectory.appendingPathComponent("inventory.json")
    var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    payload["authorizedConfigHashes"] = [String: String]()
    let invalid = try JSONSerialization.data(withJSONObject: payload)
    try invalid.write(to: path, options: .atomic)
    await #expect(throws: CloudGatewayMacCacheError.invalidMetadata) {
        try await cache.evict(identifier: target.identifier, accountId: "user-a")
    }
    #expect(try Data(contentsOf: path) == invalid)
}

private func accountCacheFixture(
    accountId: String,
    clientId: String = "client-a",
    address: String = "10.0.0.2/32",
    clientName: String = "Mac",
    regionName: String = "US",
    ownerUid: String? = nil,
    secretReference: CloudGatewayConfigSecretReference? = nil
) throws -> (CloudGatewayMacInstalledConfig, CloudGatewayClientOption) {
    let rawConfig = """
    [Interface]
    PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    Address = \(address)
    [Peer]
    PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    Endpoint = wg.example.com:51820
    AllowedIPs = 0.0.0.0/0
    """
    let client = CloudGatewayClient(clientId: clientId, clientName: clientName, regionId: "us-a", status: .active, wireGuardConfig: rawConfig, ownerUid: ownerUid ?? accountId)
    let option = CloudGatewayClientOption(client: client, region: CloudGatewayRegion(regionId: "us-a", displayName: regionName, enabled: true))
    let snapshot = CloudGatewayConfigSnapshot(
        clientId: client.clientId, regionId: client.regionId, clientName: client.clientName,
        regionDisplayName: regionName, status: .active,
        configHash: CloudGatewayConfigHash.make(for: try CloudGatewayWireGuardConfig(rawConfig)),
        secretReference: secretReference ?? CloudGatewayConfigSecretReference(service: CloudGatewayMacInstalledConfig.secretService, account: UUID().uuidString.lowercased()),
        readAt: Date(timeIntervalSince1970: 1), updatedAt: nil
    )
    return (CloudGatewayMacInstalledConfig(accountId: accountId, identifier: "\(accountId)/us-a/\(clientId)", snapshot: snapshot), option)
}
