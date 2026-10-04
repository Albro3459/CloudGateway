import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation
import Testing
@testable import CloudGatewayMacCore

@Test func macSignedOutMenuHidesAllInventoryAndVPNControlsWhileRetainingActiveGlyph() {
    let state = macMenuState(accountId: nil, options: [macMenuOption(clientId: "visible")], configs: [macMenuConfig()], profiles: [macMenuProfile(status: .connected)])
    #expect(state.groups.isEmpty)
    #expect(!state.canTurnOff)
    #expect(!state.canToggleVPN)
    #expect(!state.canRefresh)
    #expect(!state.canSignOut)
    #expect(state.hasActiveTunnel)
    #expect(state.statusTitle == "Signed out")
}

@Test func macConnectNeedsReadySetupAndNoCommandInFlight() {
    let option = macMenuOption(clientId: "client")
    #expect(macMenuState(setup: .required, options: [option]).groups.first?.rows.first?.isEnabled == false)
    #expect(macMenuState(setup: .updateRequired, options: [option]).groups.first?.rows.first?.isEnabled == false)
    #expect(macMenuState(setup: .invalidBundle, options: [option]).groups.first?.rows.first?.isEnabled == false)
    #expect(macMenuState(options: [option], busy: true).groups.first?.rows.first?.isEnabled == false)
    #expect(macMenuState(options: [option]).groups.first?.rows.first?.isEnabled == true)
}

@Test func retainedSessionCanSignOutWhileRestoringWithoutExposingVPNControls() {
    for busy in [false, true] {
        let state = macMenuState(accountId: nil, options: [macMenuOption(clientId: "visible")],
            configs: [macMenuConfig()], profiles: [macMenuProfile(status: .connected)],
            busy: busy, hasRetainedSession: true)
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
    #expect(state.canToggleVPN)
    #expect(state.canRefresh)
    #expect(!macMenuState(profiles: [macMenuProfile(status: .connected)], busy: true).canTurnOff)
}

@Test func macInventoryRefreshKeepsLocalStopAvailableAndConnectionsDisabled() {
    let state = macMenuState(options: [macMenuOption(clientId: "client")],
        profiles: [macMenuProfile(status: .connected)], inventoryBusy: true)
    #expect(state.canTurnOff)
    #expect(state.canToggleVPN)
    #expect(!state.canRefresh)
    #expect(state.groups.first?.rows.first?.isEnabled == false)
    #expect(state.statusTitle == "VPN connected")
    #expect(!macMenuState(profiles: [macMenuProfile(status: .connected)], busy: true,
        inventoryBusy: true).canTurnOff)
}

@Test func macPreferencesFailureRetainsLastObservedStatusAndErrorUntilSuccessfulRead() {
    var observation = CloudGatewayMacProfileObservation()
    let connected = macMenuProfile(status: .connected)
    observation.didRead([connected])
    observation.didFailRead()
    #expect(observation.profiles == [connected])
    #expect(observation.errorMessage == "Unable to read VPN preferences. Try Refresh again")
    let refreshedInventory = macMenuState(options: [macMenuOption(clientId: "client")],
        profiles: observation.profiles)
    #expect(refreshedInventory.hasActiveTunnel)
    #expect(refreshedInventory.statusTitle == "VPN connected")
    #expect(refreshedInventory.canTurnOff)
    observation.didFailRead()
    #expect(observation.profiles == [connected])
    #expect(observation.errorMessage != nil)
    observation.didRead([])
    #expect(observation.profiles.isEmpty)
    #expect(observation.errorMessage == nil)
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

@Test func macToggleReconnectsOnlyTheUsableLastSelectedClient() {
    let identifier = "account/region/last"
    let options = [macMenuOption(clientId: "first"), macMenuOption(clientId: "last")]
    let selected = macMenuState(options: options, lastSelectedIdentifier: identifier)
    #expect(selected.reconnectIdentifier == identifier)
    #expect(selected.canToggleVPN)
    #expect(selected.statusTitle == "VPN off")
    for selection in [nil, "account/region/removed", "other/region/last"] as [String?] {
        let state = macMenuState(options: options, lastSelectedIdentifier: selection)
        #expect(state.reconnectIdentifier == nil)
        #expect(!state.canToggleVPN)
        #expect(state.statusTitle == "Choose a client to connect")
    }
    for option in [macMenuOption(clientId: "last", status: .creating),
                   macMenuOption(clientId: "last", status: .removed),
                   macMenuOption(clientId: "last", regionEnabled: false)] {
        #expect(!macMenuState(options: [option], lastSelectedIdentifier: identifier).canToggleVPN)
    }
    #expect(!macMenuState(options: options, inventoryBusy: true,
        lastSelectedIdentifier: identifier).canToggleVPN)
    #expect(!macMenuState(options: options, busy: true,
        lastSelectedIdentifier: identifier).canToggleVPN)
    #expect(!macMenuState(setup: .updateRequired, options: options,
        lastSelectedIdentifier: identifier).canToggleVPN)
}

@Test func macToggleWaitsForTransitionsAndUsesObservedConnectionState() {
    for status in [CloudGatewayTunnelStatus.connecting, .disconnecting] {
        let state = macMenuState(profiles: [macMenuProfile(status: status)])
        #expect(!state.canToggleVPN)
        #expect(!state.hasActiveTunnel)
    }
    let stopping = macMenuState(profiles: [macMenuProfile(status: .connected),
        macMenuProfile(identifier: "account/region/other", status: .disconnecting)])
    #expect(!stopping.canToggleVPN)
    #expect(stopping.statusTitle == "VPN disconnecting…")
    #expect(macMenuState(profiles: [macMenuProfile(status: .reasserting)]).canToggleVPN)
    #expect(!macMenuState(profiles: [macMenuProfile(status: .connected)], busy: true).canToggleVPN)
}

@Test func macOfflineToggleRequiresTheLastSelectedAccountsInstalledProfile() {
    let identifier = "account/region/client"
    let config = macMenuConfig()
    let profile = macMenuProfile(status: .disconnected)
    let state = macMenuState(configs: [config], profiles: [profile], offline: true,
        lastSelectedIdentifier: identifier)
    #expect(state.reconnectIdentifier == identifier)
    #expect(state.canToggleVPN)
    #expect(state.statusTitle == "Offline · VPN off")
    #expect(!macMenuState(configs: [config], offline: true,
        lastSelectedIdentifier: identifier).canToggleVPN)
    #expect(!macMenuState(configs: [macMenuConfig(accountId: "other")], profiles: [profile],
        offline: true, lastSelectedIdentifier: "other/region/client").canToggleVPN)
    let mismatched = macMenuProfile(status: .disconnected, reference: "11111111-1111-1111-1111-111111111111")
    #expect(!macMenuState(configs: [config], profiles: [mismatched], offline: true,
        lastSelectedIdentifier: identifier).canToggleVPN)
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
    inventoryBusy: Bool = false,
    offline: Bool = false,
    hasRetainedSession: Bool = false,
    lastSelectedIdentifier: String? = nil
) -> CloudGatewayMacMenuState {
    CloudGatewayMacMenuState(accountId: accountId, setupState: setup, onlineOptions: options, cachedConfigs: configs,
                             profiles: profiles, commandInFlight: busy, isOffline: offline,
                             inventoryInFlight: inventoryBusy,
                             hasRetainedSession: hasRetainedSession, lastSelectedIdentifier: lastSelectedIdentifier)
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
