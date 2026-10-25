import CloudGatewayAppCore
import CloudGatewayKit
import Foundation
import Testing
@testable import CloudGatewayMacCore
@testable import CloudGatewayMacControllerIPC

@Test func controllerStateNormalizesRawMetadataAndFrontendFormatsTitles() throws {
    let snapshot = controllerSnapshot(clientName: "Work\tMac\nLaptop", regionName: "US\rCentral\tRegion", ownerLabel: "Owner\tLabel")
    let state = try controllerRoundTrip(.init(snapshot: snapshot, setupState: .ready, canUpdateExtension: true))
    #expect(state.clients.first?.regionName == "US Central Region")
    #expect(state.clients.first?.clientName == "Work Mac Laptop")
    #expect(state.clients.first?.ownerLabel == "Owner Label")
    #expect(state.clients.first?.identifier == "account-A._/r_E-1/c_Z.9")
    #expect(state.clients.first?.isEligible == true)
    let view = CloudGatewayMacControllerView(state: state)
    #expect(view.groups.first?.title == "US Central Region")
    #expect(view.groups.first?.rows.first?.title == "Work Mac Laptop (Owner Label)")
    #expect(view.accountId == snapshot.domain.accountId)
    #expect(view.lastSelectedIdentifier == snapshot.lastSelectedIdentifier)
    #expect(view.reconnectIdentifier == snapshot.lastSelectedIdentifier)
    #expect(view.canUpdateExtension)
    #expect(view.statusTitle == "VPN connected")
}

@Test func controllerStateBoundsDisplayTextWithoutSplittingUnicode() throws {
    for (clientName, regionName, expectedClient, expectedRegion) in [
        (String(repeating: "🙂", count: 600), String(repeating: "🙂", count: 300),
         String(repeating: "🙂", count: 512), String(repeating: "🙂", count: 256)),
        (String(repeating: "a", count: 2047) + "🙂", String(repeating: "a", count: 1023) + "🙂",
         String(repeating: "a", count: 2047), String(repeating: "a", count: 1023)),
        ("", "", "Untitled", "Untitled"),
        ("Work\u{0000}Mac\u{007f}", "US\u{000b}Central", "Work Mac ", "US Central")
    ] {
        let state = try controllerRoundTrip(.init(
            snapshot: controllerSnapshot(clientName: clientName, regionName: regionName),
            setupState: .ready, canUpdateExtension: false
        ))
        #expect(state.clients.first?.clientName == expectedClient)
        #expect(state.clients.first?.regionName == expectedRegion)
        let view = CloudGatewayMacControllerView(state: state)
        #expect(view.groups.first?.rows.first?.title == expectedClient)
        #expect(view.groups.first?.title == expectedRegion)
    }
    let state = try controllerRoundTrip(.init(
        snapshot: controllerSnapshot(clientName: String(repeating: "🙂", count: 511), ownerLabel: String(repeating: "🙂", count: 300)),
        setupState: .ready, canUpdateExtension: false
    ))
    #expect(state.clients.first?.ownerLabel == String(repeating: "🙂", count: 256))
    let title = try #require(CloudGatewayMacControllerView(state: state).groups.first?.rows.first?.title)
    #expect(title.utf8.count <= 2048)
    #expect(title == String(repeating: "🙂", count: 511) + " (")
}

@Test func controllerStatePreservesFixedSuccessfulCreationRefreshWarning() throws {
    let message = "Client was created, but the client list could not refresh. Choose Refresh before trying again"
    let state = try controllerRoundTrip(.init(
        snapshot: controllerSnapshot(errorMessage: message), setupState: .ready, canUpdateExtension: false
    ))
    #expect(state.errorMessage == message)
    #expect(CloudGatewayMacControllerView(state: state).errorMessage == message)
    let unsafe = "\"privateKey=secret\" was created, but the client list could not refresh. Choose Refresh before trying again"
    let sanitized = try controllerRoundTrip(.init(
        snapshot: controllerSnapshot(errorMessage: unsafe), setupState: .ready, canUpdateExtension: false
    ))
    #expect(sanitized.errorMessage == "CloudGateway could not complete the request. Refresh before trying again")
}

@Test func controllerFrontendGroupsByRegionIdentityAndSortsRawMetadata() throws {
    let clients: [CloudGatewayMacClientMetadata] = [
        controllerClient("account-A._/east/z", regionId: "east", regionName: "Region", regionOrder: 2,
                         clientName: "Zebra", ownerLabel: "Alice"),
        controllerClient("account-A._/east/a", regionId: "east", regionName: "Region", regionOrder: 2,
                         clientName: "Alpha", ownerLabel: "Alice"),
        controllerClient("account-A._/west/b", regionId: "west", regionName: "Region", regionOrder: 1,
                         clientName: "Beta", ownerLabel: nil),
        controllerClient("account-A._/east/b", regionId: "east", regionName: "Region", regionOrder: 2,
                         clientName: "Beta", ownerLabel: "Bob")
    ]
    let state = try controllerRoundTrip(.init(snapshot: controllerSnapshot(clients: clients), setupState: .ready, canUpdateExtension: false))
    let view = CloudGatewayMacControllerView(state: state)
    #expect(view.groups.count == 2)
    #expect(view.groups.map(\.title) == ["Region", "Region"])
    #expect(view.groups[0].rows.map(\.identifier) == ["account-A._/west/b"])
    #expect(view.groups[1].rows.map(\.title) == ["Alpha (Alice)", "Zebra (Alice)", "Beta (Bob)"])
}

@Test func controllerFrontendConnectUsesDomainEligibilityAndCapabilities() throws {
    for (eligible, authorized, busy, restoring, settling, setup, expected) in [
        (true, true, false, false, false, CloudGatewayMacSetupState.ready, true),
        (false, true, false, false, false, .ready, false),
        (true, false, false, false, false, .ready, false),
        (true, true, true, false, false, .ready, false),
        (true, true, false, true, false, .ready, false),
        (true, true, false, false, true, .ready, false),
        (true, true, false, false, false, .updateRequired, false)
    ] {
        let snapshot = controllerSnapshot(
            isEligible: eligible, accessAuthorized: authorized, commandInFlight: busy,
            isRestoringSession: restoring, isAuthSettling: settling, observedProfiles: []
        )
        let state = try controllerRoundTrip(.init(snapshot: snapshot, setupState: setup, canUpdateExtension: false))
        #expect(state.clients.first?.isEligible == eligible)
        let view = CloudGatewayMacControllerView(state: state)
        #expect(view.groups.first?.rows.first?.isEnabled == expected)
        #expect(view.canToggleVPN == expected)
        #expect(view.reconnectIdentifier == (expected ? snapshot.lastSelectedIdentifier : nil))
    }
}

@Test func controllerStateHidesForeignAccountMetadataAndKeepsLocalStopStatus() throws {
    let foreign = "other/region/client"
    let client = controllerClient(
        foreign, regionId: "region", regionName: "Foreign region",
        clientName: "Foreign client", ownerLabel: "Foreign owner", status: .connected
    )
    for accountId in ["account-A._", nil] {
        let snapshot = controllerSnapshot(
            accountId: accountId, clients: [client], installedIdentifiers: [foreign],
            observedProfiles: [.init(identifier: foreign, status: .connected, mode: nil)], selectedIdentifier: foreign
        )
        let state = try controllerRoundTrip(.init(snapshot: snapshot, setupState: .required, canUpdateExtension: false))
        #expect(state.clients.isEmpty)
        #expect(state.installedIdentifiers.isEmpty)
        #expect(state.selectedIdentifier == nil)
        #expect(state.observedProfiles.first?.identifier == nil)
        #expect(state.status.hasActiveTunnel)
        #expect(state.status.needsStop)
        let view = CloudGatewayMacControllerView(state: state)
        #expect(view.groups.isEmpty)
        #expect(view.canTurnOff)
        #expect(view.hasUnlistedActiveProfile)
        let text = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(!text.contains("Foreign"))
        #expect(!text.contains(foreign))
    }
}

@Test func controllerFrontendSignedOutStateRetainsLocalStopAndRetainedSessionActions() throws {
    for busy in [false, true] {
        let snapshot = controllerSnapshot(accountId: nil, commandInFlight: busy, hasRetainedSession: true)
        let state = try controllerRoundTrip(.init(snapshot: snapshot, setupState: .required, canUpdateExtension: false))
        let view = CloudGatewayMacControllerView(state: state)
        #expect(view.groups.isEmpty)
        #expect(view.lastSelectedIdentifier == nil)
        #expect(view.reconnectIdentifier == nil)
        #expect(view.canSignOut)
        #expect(!view.canRefresh)
        #expect(view.canTurnOff == !busy)
        #expect(view.canToggleVPN == !busy)
        #expect(view.hasActiveTunnel)
        #expect(view.statusTitle == "VPN connected")
    }
    let signedOut = try controllerRoundTrip(.init(
        snapshot: controllerSnapshot(accountId: nil, observedProfiles: []), setupState: .ready, canUpdateExtension: false
    ))
    let view = CloudGatewayMacControllerView(state: signedOut)
    #expect(!view.canSignOut)
    #expect(!view.canToggleVPN)
    #expect(!view.canTurnOff)
    #expect(view.statusTitle == "Signed out")
}

@Test func controllerFrontendInventoryRefreshPreservesLocalVPNControls() throws {
    for freshness in [CloudGatewayMacInventoryFreshness.current, .refreshing, .cached] {
        for busy in [false, true] {
            let state = try controllerRoundTrip(.init(
                snapshot: controllerSnapshot(commandInFlight: busy, inventoryFreshness: freshness),
                setupState: .ready, canUpdateExtension: false
            ))
            let view = CloudGatewayMacControllerView(state: state)
            #expect(view.canTurnOff == !busy)
            #expect(view.canToggleVPN == !busy)
            #expect(view.groups.first?.rows.first?.isEnabled == !busy)
            #expect(view.canRefresh == (!busy && freshness != .refreshing))
            #expect(view.statusTitle == "VPN connected")
        }
    }
}

@Test func controllerFrontendUsesObservedTunnelStatusAndWaitsForTransitions() throws {
    let identifier = "account-A._/r_E-1/c_Z.9"
    for (status, title, active, toggle) in [
        (CloudGatewayTunnelStatus.disconnected, "VPN off", false, true),
        (.invalid, "VPN off", false, true), (.connecting, "VPN connecting…", false, false),
        (.connected, "VPN connected", true, true), (.reasserting, "VPN connected", true, true),
        (.disconnecting, "VPN disconnecting…", false, false)
    ] {
        let state = try controllerRoundTrip(.init(
            snapshot: controllerSnapshot(observedProfiles: [.init(identifier: identifier, status: status, mode: nil)]),
            setupState: .ready, canUpdateExtension: false
        ))
        let view = CloudGatewayMacControllerView(state: state)
        #expect(view.statusTitle == title)
        #expect(view.hasActiveTunnel == active)
        #expect(view.canToggleVPN == toggle)
    }
    let profiles: [CloudGatewayMacObservedProfile] = [
        .init(identifier: identifier, status: .connected, mode: nil), .init(identifier: "account-A._/r_E-1/other", status: .disconnecting, mode: nil)
    ]
    let state = try controllerRoundTrip(.init(
        snapshot: controllerSnapshot(observedProfiles: profiles), setupState: .ready, canUpdateExtension: false
    ))
    let view = CloudGatewayMacControllerView(state: state)
    #expect(view.statusTitle == "VPN disconnecting…")
    #expect(view.hasActiveTunnel)
    #expect(!view.canToggleVPN)
    #expect(view.canTurnOff)
}

@Test func controllerFrontendReconnectRequiresAnEligibleCurrentAccountSelection() throws {
    for selection in [nil, "account-A._/r_E-1/missing", "other/r_E-1/c_Z.9"] as [String?] {
        let state = try controllerRoundTrip(.init(
            snapshot: controllerSnapshot(observedProfiles: [], selectedIdentifier: selection),
            setupState: .ready, canUpdateExtension: false
        ))
        let view = CloudGatewayMacControllerView(state: state)
        #expect(view.reconnectIdentifier == nil)
        #expect(!view.canToggleVPN)
        #expect(view.statusTitle == "VPN off")
    }
}

@Test func controllerFrontendLabelsStalePreferenceObservationsWithoutLosingLocalStop() throws {
    let state = try controllerRoundTrip(.init(
        snapshot: controllerSnapshot(observationIsFresh: false), setupState: .ready, canUpdateExtension: false
    ))
    #expect(!state.status.observationAvailable)
    let view = CloudGatewayMacControllerView(state: state)
    #expect(view.statusTitle == "VPN connected (last observed)")
    #expect(view.hasActiveTunnel)
    #expect(view.canTurnOff)
    let unavailable = try controllerRoundTrip(.init(
        snapshot: controllerSnapshot(observedProfiles: [], observationIsFresh: false),
        setupState: .ready, canUpdateExtension: false
    ))
    #expect(CloudGatewayMacControllerView(state: unavailable).statusTitle == "VPN status unavailable")
}

private func controllerSnapshot(
    clientName: String = "Work Mac", regionName: String = "US Central", ownerLabel: String? = nil,
    errorMessage: String? = nil, accountId: String? = "account-A._", clients: [CloudGatewayMacClientMetadata]? = nil,
    isEligible: Bool = true, accessAuthorized: Bool = true, commandInFlight: Bool = false, stopAllowed: Bool? = nil,
    isRestoringSession: Bool = false, isAuthSettling: Bool = false, installedIdentifiers: [String]? = nil,
    observedProfiles: [CloudGatewayMacObservedProfile]? = nil, selectedIdentifier: String? = "account-A._/r_E-1/c_Z.9",
    observationIsFresh: Bool = true, hasRetainedSession: Bool? = nil,
    inventoryFreshness: CloudGatewayMacInventoryFreshness = .current, selectedMode: CloudGatewayRoutingMode? = nil
) -> CloudGatewayMacControllerSnapshot {
    let identifier = "account-A._/r_E-1/c_Z.9"
    return CloudGatewayMacControllerSnapshot(
        domain: .init(
            accountId: accountId, hasRetainedSession: hasRetainedSession ?? (accountId != nil), accessAuthorized: accessAuthorized,
            access: accessAuthorized ? .online : .unverified, credentials: .unknown,
            inventoryFreshness: inventoryFreshness, installedIdentifiers: installedIdentifiers ?? [identifier],
            observedProfiles: observedProfiles ?? [.init(identifier: identifier, status: .connected, mode: nil)],
            observationIsFresh: observationIsFresh, profilesObservedAt: nil, commandInFlight: commandInFlight, stopAllowed: stopAllowed,
            clients: clients ?? [controllerClient(
                identifier, regionId: "r_E-1", regionName: regionName, clientName: clientName, ownerLabel: ownerLabel,
                isEligible: isEligible, isInstalled: installedIdentifiers?.contains(identifier) ?? true, status: .connected
            )], selectedMode: selectedMode
        ),
        lastSelectedIdentifier: selectedIdentifier,
        browserState: accountId.map { .signedIn(AuthenticatedUser(uid: $0, email: nil)) } ?? .signedOut,
        isRestoringSession: isRestoringSession, isAuthSettling: isAuthSettling,
        canCreateClient: true, errorMessage: errorMessage
    )
}

private func controllerRoundTrip(_ state: CloudGatewayMacControllerState) throws -> CloudGatewayMacControllerState {
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        CloudGatewayMacControllerReply(state: state), appVersion: "1.2.0", appBuild: "42", instanceId: UUID()
    )
    let reply = try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: "1.2.0", appBuild: "42")
    #expect(reply.error == nil)
    return try #require(reply.state)
}

private func controllerClient(
    _ identifier: String, regionId: String, regionName: String, regionOrder: Int = 1000, clientName: String,
    ownerLabel: String?, isEligible: Bool = true, isInstalled: Bool = false, status: CloudGatewayTunnelStatus? = nil
) -> CloudGatewayMacClientMetadata {
    .init(identifier: identifier, regionId: regionId, regionName: regionName, regionOrder: regionOrder,
          clientName: clientName, ownerLabel: ownerLabel, internalIp: nil, cloudState: .active,
          eligibility: isEligible ? .eligible : .configMissing, isInstalled: isInstalled, source: .cloud,
          readAt: Date(timeIntervalSince1970: 0), updatedAt: nil, status: status)
}

@Test(arguments: [false, true])
func controllerFrontendCanStopDuringCreationWhileOtherCommandsStayDisabled(allowed: Bool) throws {
    let state = try controllerRoundTrip(.init(
        snapshot: controllerSnapshot(commandInFlight: true, stopAllowed: allowed), setupState: .ready, canUpdateExtension: false
    ))
    #expect(state.stopAllowed == allowed)
    let view = CloudGatewayMacControllerView(state: state)
    #expect(view.canTurnOff == allowed)
    #expect(view.canToggleVPN == allowed)
    #expect(!view.canRefresh)
    #expect(view.reconnectIdentifier == nil)
    #expect(view.groups.allSatisfy { $0.rows.allSatisfy { !$0.isEnabled } })
}

@Test(arguments: [false, true])
func controllerFrontendMissingStopCapabilityUsesLegacyCommandAdmission(busy: Bool) throws {
    let original = CloudGatewayMacControllerState(
        snapshot: controllerSnapshot(commandInFlight: busy), setupState: .ready, canUpdateExtension: false
    )
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    json.removeValue(forKey: "stopAllowed")
    let state = try JSONDecoder().decode(CloudGatewayMacControllerState.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(state.stopAllowed == nil)
    #expect(CloudGatewayMacControllerView(state: state).canTurnOff == !busy)
}

@Test func controllerProjectsSelectedAndAppliedModesIndependently() throws {
    let identifier = "account-A._/r_E-1/c_Z.9"
    for (status, applied, active, title) in [
        (CloudGatewayTunnelStatus.connected, CloudGatewayRoutingMode.full, CloudGatewayRoutingMode.full as CloudGatewayRoutingMode?, "VPN connected · Full"),
        (.reasserting, .mesh, .mesh, "VPN connected · Mesh only"),
        (.disconnected, .full, nil, "VPN off"),
        (.connecting, .full, nil, "VPN connecting… · Mesh only"),
        (.disconnecting, .full, nil, "VPN disconnecting… · Mesh only")
    ] {
        let state = try controllerRoundTrip(.init(snapshot: controllerSnapshot(
            observedProfiles: [.init(identifier: identifier, status: status, mode: applied)], selectedMode: .mesh
        ), setupState: .ready, canUpdateExtension: false))
        #expect(state.selectedMode == .mesh)
        #expect(state.activeMode == active)
        #expect(state.status.selectedMode == .mesh)
        #expect(state.status.activeMode == active)
        let view = CloudGatewayMacControllerView(state: state)
        #expect(view.selectedMode == .mesh)
        #expect(view.activeMode == active)
        #expect(view.statusTitle == title)
        #expect(view.canSetMode == (status != .connecting && status != .disconnecting))
    }
}

@Test func controllerRetainsSignedOutTunnelModeWithoutAccountMetadata() throws {
    let state = try controllerRoundTrip(.init(snapshot: controllerSnapshot(
        accountId: nil, observedProfiles: [.init(identifier: "other/region/client", status: .connected, mode: .mesh)], selectedMode: .full
    ), setupState: .ready, canUpdateExtension: false))
    #expect(state.selectedMode == nil)
    #expect(state.activeMode == .mesh)
    #expect(state.observedProfiles.first?.identifier == nil)
    #expect(state.clients.isEmpty)
    let view = CloudGatewayMacControllerView(state: state)
    #expect(view.statusTitle == "VPN connected · Mesh only")
    #expect(view.canTurnOff)
    #expect(!view.canSetMode)
    let text = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    #expect(!text.contains("other/region/client"))
}

@Test func controllerNeverInfersActiveModeFromPreferenceOrAmbiguousProfiles() throws {
    for profiles in [
        [CloudGatewayMacObservedProfile(identifier: "account-A._/r_E-1/c_Z.9", status: .connected, mode: nil)],
        [.init(identifier: "account-A._/r_E-1/c_Z.9", status: .connected, mode: .mesh),
         .init(identifier: "other/region/client", status: .connected, mode: .full)],
        []
    ] {
        let state = try controllerRoundTrip(.init(snapshot: controllerSnapshot(
            observedProfiles: profiles, selectedMode: .mesh
        ), setupState: .ready, canUpdateExtension: false))
        #expect(state.selectedMode == .mesh)
        #expect(state.activeMode == nil)
        #expect(state.status.activeMode == nil)
        #expect(CloudGatewayMacControllerView(state: state).activeMode == nil)
    }
}

@Test func controllerModeControlsFollowCommandAuthSetupAndTransitionGates() {
    for (busy, authorized, restoring, settling, setup, allowed) in [
        (false, true, false, false, CloudGatewayMacSetupState.ready, true),
        (true, true, false, false, .ready, false),
        (false, false, false, false, .ready, false),
        (false, true, true, false, .ready, false),
        (false, true, false, true, .ready, false),
        (false, true, false, false, .updateRequired, false)
    ] {
        var state = CloudGatewayMacControllerState(snapshot: controllerSnapshot(
            accessAuthorized: authorized, commandInFlight: busy, isRestoringSession: restoring, isAuthSettling: settling,
            observedProfiles: [], selectedMode: .full
        ), setupState: setup, canUpdateExtension: false)
        #expect(CloudGatewayMacControllerView(state: state).canSetMode == allowed)
        state.modeChangeAllowed = false
        #expect(!CloudGatewayMacControllerView(state: state).canSetMode)
    }
}
