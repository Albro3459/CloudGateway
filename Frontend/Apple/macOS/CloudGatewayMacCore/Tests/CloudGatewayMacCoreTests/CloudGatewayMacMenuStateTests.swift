import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation
import Testing
@testable import CloudGatewayMacCore

@Test func macPreferencesFailureRetainsLastObservedStatusAndErrorUntilSuccessfulRead() {
    var observation = CloudGatewayMacProfileObservation()
    let connected = macObservedProfile(status: .connected)
    observation.didRead([connected])
    observation.didFailRead()
    #expect(observation.profiles == [connected])
    #expect(observation.errorMessage == "Unable to read VPN preferences. Try Refresh again")
    observation.didFailRead()
    #expect(observation.profiles == [connected])
    #expect(observation.errorMessage != nil)
    observation.didRead([])
    #expect(observation.profiles.isEmpty)
    #expect(observation.errorMessage == nil)
}

@Test func macSessionFenceRejectsLateInventoryAndCommandsAcrossSignOutAndAccountChanges() throws {
    var fence = CloudGatewayMacSessionFence()
    #expect(fence.currentToken == nil)
    fence.changeAccount(to: "first")
    let first = try #require(fence.currentToken)
    #expect(fence.isCurrent(first))
    fence.changeAccount(to: nil)
    #expect(!fence.isCurrent(first))
    fence.changeAccount(to: "second")
    #expect(!fence.isCurrent(first))
    let second = try #require(fence.currentToken)
    #expect(second.accountId == "second")
    fence.changeAccount(to: "first")
    #expect(!fence.isCurrent(first))
    #expect(!fence.isCurrent(second))
}

@Test func macSessionFenceInvalidationRejectsOlderRefreshWithinSameAccount() throws {
    var fence = CloudGatewayMacSessionFence()
    fence.changeAccount(to: "account")
    let old = try #require(fence.currentToken)
    fence.invalidate()
    #expect(!fence.isCurrent(old))
    #expect(fence.currentToken?.accountId == "account")
}

@Test func macOfflineFallbackRequiresTransportFailureAndPreviouslyAuthorizedCache() {
    let allowed = CloudGatewayMacAccountCacheSnapshot(configs: [macPolicyConfig()], accessAllowed: true)
    #expect(CloudGatewayMacOfflinePolicy.canUseCache(after: .transport, cache: allowed))
    #expect(!CloudGatewayMacOfflinePolicy.canUseCache(after: .accessDenied, cache: allowed))
    #expect(!CloudGatewayMacOfflinePolicy.canUseCache(after: .invalidResponse, cache: allowed))
    #expect(!CloudGatewayMacOfflinePolicy.canUseCache(after: .transport, cache: .init()))
}

private func macPolicyConfig() -> CloudGatewayMacInstalledConfig {
    CloudGatewayMacInstalledConfig(accountId: "account", identifier: "account/region/client", snapshot: CloudGatewayConfigSnapshot(
        clientId: "client", regionId: "region", clientName: nil, regionDisplayName: "Region", status: .active,
        configHash: String(repeating: "0", count: 64),
        secretReference: CloudGatewayConfigSecretReference(service: CloudGatewayMacInstalledConfig.secretService,
                                                          account: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
        readAt: Date(timeIntervalSince1970: 0), updatedAt: nil
    ))
}

private func macObservedProfile(status: CloudGatewayTunnelStatus) -> CloudGatewayMacInstalledProfile {
    CloudGatewayMacInstalledProfile(
        identifier: "account/region/client",
        reference: try! CloudGatewayMacSecretReference(value: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"), status: status
    )
}
