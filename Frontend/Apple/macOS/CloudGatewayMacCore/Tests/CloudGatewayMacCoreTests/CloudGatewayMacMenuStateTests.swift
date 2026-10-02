import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation
import Testing
@testable import CloudGatewayMacCore

@Test func macSignedOutMenuHidesAllInventoryAndVPNControlsWhileRetainingActiveGlyph() {
    let state = macMenuState(accountId: nil, options: [macMenuOption(clientId: "visible")], configs: [macMenuConfig()], profiles: [macMenuProfile(status: .connected)])
    #expect(state.groups.isEmpty)
    #expect(!state.canTurnOff)
    #expect(!state.canRefresh)
    #expect(!state.canSignOut)
    #expect(state.hasActiveTunnel)
    #expect(state.statusTitle == "Signed out")
}

@Test func macConnectNeedsReadySetupAndNoCommandInFlight() {
    let option = macMenuOption(clientId: "client")
    #expect(macMenuState(setup: .required, options: [option]).groups.first?.rows.first?.isEnabled == false)
    #expect(macMenuState(options: [option], busy: true).groups.first?.rows.first?.isEnabled == false)
    #expect(macMenuState(options: [option]).groups.first?.rows.first?.isEnabled == true)
}

@Test func retainedSessionCanSignOutWhileRestoringWithoutExposingVPNControls() {
    for busy in [false, true] {
        let state = macMenuState(accountId: nil, options: [macMenuOption(clientId: "visible")],
            configs: [macMenuConfig()], profiles: [macMenuProfile(status: .connected)],
            busy: busy, hasError: true, hasRetainedSession: true)
        #expect(state.canSignOut)
        #expect(state.groups.isEmpty)
        #expect(!state.canTurnOff)
        #expect(!state.canRefresh)
        #expect(state.hasActiveTunnel)
    }
}

@Test func macTurnOffWorksWithSignedInActiveTunnelEvenWhenSetupIsUnavailable() {
    let state = macMenuState(setup: .required, profiles: [macMenuProfile(status: .connected)])
    #expect(state.canTurnOff)
    #expect(state.canRefresh)
    #expect(!macMenuState(profiles: [macMenuProfile(status: .connected)], busy: true).canTurnOff)
}

@Test func macOfflineInventoryUsesOnlyCurrentAccountsMatchingInstalledReferences() {
    let other = macMenuConfig(accountId: "other", clientId: "secret-client")
    let state = macMenuState(configs: [macMenuConfig(), other], profiles: [macMenuProfile(status: .disconnected)], offline: true)
    #expect(state.groups.count == 1)
    #expect(state.groups.first?.rows.map(\.identifier) == ["account/region/client"])
    #expect(state.groups.first?.rows.first?.isEnabled == true)
    #expect(macMenuState(configs: [macMenuConfig()], offline: true).groups.first?.rows.first?.isEnabled == false)
    let wrongReference = macMenuProfile(status: .disconnected, reference: "11111111-1111-1111-1111-111111111111")
    #expect(macMenuState(configs: [macMenuConfig()], profiles: [wrongReference], offline: true).groups.first?.rows.first?.isEnabled == false)
}

@Test func macHiddenActiveTunnelUsesGenericStatusAndDoesNotDecorateCurrentAccountRow() {
    let hidden = macMenuProfile(identifier: "hidden-account/private-region/private-client", status: .connected)
    let state = macMenuState(options: [macMenuOption(clientId: "client")], profiles: [hidden])
    #expect(state.statusTitle == "VPN connected")
    #expect(state.hasActiveTunnel)
    #expect(state.groups.first?.rows.first?.status == nil)
    #expect(state.groups.first?.rows.first?.title == "client")
    #expect(state.canTurnOff)
}

@Test func macMenuConnectedUsesAppleStatusRatherThanCommandSuccess() {
    #expect(!macMenuState(profiles: [macMenuProfile(status: .connecting)]).hasActiveTunnel)
    #expect(macMenuState(profiles: [macMenuProfile(status: .connecting)]).statusTitle == "VPN connecting…")
    #expect(macMenuState(profiles: [macMenuProfile(status: .reasserting)]).hasActiveTunnel)
    #expect(!macMenuState(profiles: [macMenuProfile(status: .disconnecting)]).hasActiveTunnel)
    #expect(macMenuState(profiles: [macMenuProfile(status: .connected)], offline: true).statusTitle == "Offline · VPN connected")
}

@Test func macMenuGroupsAuthorizedClientsByRegionAndDisablesUnusableRows() {
    let creating = macMenuOption(clientId: "creating", regionId: "second", status: .creating)
    let removed = macMenuOption(clientId: "removed", regionId: "second", status: .removed)
    let disabledRegion = macMenuOption(clientId: "disabled", regionId: "disabled", regionEnabled: false)
    let state = macMenuState(options: [creating, removed, disabledRegion, macMenuOption(clientId: "client")])
    #expect(state.groups.map(\.title) == ["disabled", "region", "second"])
    let rows = state.groups.flatMap(\.rows)
    #expect(!rows.contains { $0.identifier.hasSuffix("/removed") })
    #expect(rows.first { $0.identifier.hasSuffix("/creating") }?.isEnabled == false)
    #expect(rows.first { $0.identifier.hasSuffix("/disabled") }?.isEnabled == false)
    #expect(rows.first { $0.identifier.hasSuffix("/client") }?.isEnabled == true)
}

@Test func macMenuRefreshFailureDoesNotPresentAnyRawError() {
    #expect(macMenuState(hasError: true).statusTitle == "Could not complete the action")
    #expect(macMenuState(profiles: [macMenuProfile(status: .connected)], hasError: true).statusTitle == "VPN connected")
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
    let allowed = CloudGatewayMacAccountCacheSnapshot(configs: [macMenuConfig()], accessAllowed: true)
    #expect(CloudGatewayMacOfflinePolicy.canUseCache(after: .transport, cache: allowed))
    #expect(!CloudGatewayMacOfflinePolicy.canUseCache(after: .accessDenied, cache: allowed))
    #expect(!CloudGatewayMacOfflinePolicy.canUseCache(after: .invalidResponse, cache: allowed))
    #expect(!CloudGatewayMacOfflinePolicy.canUseCache(after: .transport, cache: .init()))
}

private func macMenuState(
    accountId: String? = "account",
    setup: CloudGatewayMacSetupState = .ready,
    options: [CloudGatewayClientOption] = [],
    configs: [CloudGatewayMacInstalledConfig] = [],
    profiles: [CloudGatewayMacInstalledProfile] = [],
    busy: Bool = false,
    offline: Bool = false,
    hasError: Bool = false,
    hasRetainedSession: Bool = false
) -> CloudGatewayMacMenuState {
    CloudGatewayMacMenuState(accountId: accountId, setupState: setup, onlineOptions: options, cachedConfigs: configs,
                             profiles: profiles, commandInFlight: busy, isOffline: offline,
                             hasError: hasError, hasRetainedSession: hasRetainedSession)
}

private func macMenuOption(
    clientId: String,
    regionId: String = "region",
    status: CloudGatewayClientStatus = .active,
    regionEnabled: Bool = true
) -> CloudGatewayClientOption {
    CloudGatewayClientOption(
        client: CloudGatewayClient(clientId: clientId, clientName: nil, regionId: regionId, status: status,
                                   wireGuardConfig: "[Interface]\nPrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="),
        region: CloudGatewayRegion(regionId: regionId, displayName: regionId, enabled: regionEnabled)
    )
}

private func macMenuConfig(accountId: String = "account", clientId: String = "client") -> CloudGatewayMacInstalledConfig {
    CloudGatewayMacInstalledConfig(accountId: accountId, identifier: "\(accountId)/region/\(clientId)", snapshot: CloudGatewayConfigSnapshot(
        clientId: clientId, regionId: "region", clientName: nil, regionDisplayName: "Region", status: .active,
        configHash: String(repeating: "0", count: 64),
        secretReference: CloudGatewayConfigSecretReference(service: CloudGatewayMacInstalledConfig.secretService,
                                                          account: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
        readAt: Date(timeIntervalSince1970: 0), updatedAt: nil
    ))
}

private func macMenuProfile(
    identifier: String = "account/region/client",
    status: CloudGatewayTunnelStatus,
    reference: String = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
) -> CloudGatewayMacInstalledProfile {
    CloudGatewayMacInstalledProfile(identifier: identifier, reference: try! CloudGatewayMacSecretReference(value: reference), status: status)
}
