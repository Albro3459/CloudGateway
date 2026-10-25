import AppKit
import CloudGatewayAppCore
import CloudGatewayKit
import Foundation
import Testing
@testable import CloudGatewayMacCore
@testable import CloudGatewayMacControllerIPC

private let removalIdentifier = "account/region/client"

private func removalState(
    accountId: String? = "account", profiles: [CloudGatewayMacObservedProfile] = [],
    observationIsFresh: Bool = true, eligibility: CloudGatewayMacClientEligibility = .eligible,
    installed: Bool = false, authorized: Bool = true, busy: Bool = false,
    restoring: Bool = false, settling: Bool = false, inventory: CloudGatewayMacInventoryFreshness = .current,
    setup: CloudGatewayMacSetupState = .ready, clients: [CloudGatewayMacClientMetadata]? = nil
) -> CloudGatewayMacControllerState {
    .init(snapshot: .init(domain: .init(
        accountId: accountId, hasRetainedSession: accountId != nil, accessAuthorized: authorized,
        access: authorized ? .online : .unverified, credentials: .available, inventoryFreshness: inventory,
        installedIdentifiers: installed ? [removalIdentifier] : [], observedProfiles: profiles,
        observationIsFresh: observationIsFresh, profilesObservedAt: nil, commandInFlight: busy,
        clients: clients ?? [removalClient(removalIdentifier, eligibility: eligibility, installed: installed)]
    ), lastSelectedIdentifier: removalIdentifier,
       browserState: accountId.map { .signedIn(.init(uid: $0, email: nil)) } ?? .signedOut,
       isRestoringSession: restoring, isAuthSettling: settling, canCreateClient: false, errorMessage: nil),
          setupState: setup, canUpdateExtension: false)
}

private func removalClient(_ identifier: String, regionId: String = "region", regionOrder: Int = 0,
                          eligibility: CloudGatewayMacClientEligibility = .eligible,
                          installed: Bool = false) -> CloudGatewayMacClientMetadata {
    .init(identifier: identifier, regionId: regionId, regionName: "Region", regionOrder: regionOrder,
          clientName: "Work Mac", ownerLabel: "Owner", internalIp: nil, cloudState: .active,
          eligibility: eligibility, isInstalled: installed, source: .cloud,
          readAt: Date(timeIntervalSince1970: 0), updatedAt: nil, status: nil)
}

@Test func removalProjectionUsesObservedCanonicalIdentityForEveryTunnelStatus() throws {
    for (status, permission) in [
        (CloudGatewayTunnelStatus.invalid, CloudGatewayMacControllerView.RemovalPermission.inactive),
        (.disconnected, .inactive), (.connecting, .active), (.connected, .active),
        (.reasserting, .active), (.disconnecting, .active)
    ] {
        let state = removalState(profiles: [.init(identifier: removalIdentifier, status: status)], installed: true)
        let view = CloudGatewayMacControllerView(state: state)
        let row = try #require(view.groups.first?.rows.first)
        #expect(row.status == nil)
        #expect(row.removalPermission == permission)
        var selection = CloudGatewayMacClientRemovalSelection(snapshot: view)
        selection.selectRegion("region")
        selection.selectClient(removalIdentifier)
        #expect(selection.canDelete == (permission == .inactive))
        if permission == .active {
            #expect(selection.message == "Disconnect this config and wait for it to stop before deleting it")
        }
    }
}

@Test func removalAllowsMissingConfigsAndAnUnrelatedActiveProfileWithoutSetupOrCreationCapacity() throws {
    for eligibility in [CloudGatewayMacClientEligibility.eligible, .inactive, .configMissing, .regionUnavailable] {
        for installed in [false, true] {
            let view = CloudGatewayMacControllerView(state: removalState(
                profiles: [.init(identifier: "account/region/other", status: .connected)],
                eligibility: eligibility, installed: installed, setup: .unavailable
            ))
            #expect(view.canRemoveClient)
            #expect(!view.canCreateClient)
            #expect(view.lastSelectedIdentifier == removalIdentifier)
            #expect(view.groups.first?.rows.first?.isEnabled == false)
            #expect(view.groups.first?.rows.first?.removalPermission == .inactive)
        }
    }
    let mixed = CloudGatewayMacControllerView(state: removalState(profiles: [
        .init(identifier: removalIdentifier, status: .disconnected),
        .init(identifier: removalIdentifier, status: .connecting)
    ]))
    #expect(mixed.groups.first?.rows.first?.removalPermission == .active)
}

@Test func removalSelectionKeepsIDsAndOwnerLabelsAndResetsConfigOnRegionChange() throws {
    let first = "account/east/client"
    let second = "account/east/other"
    let west = "account/west/client"
    let view = CloudGatewayMacControllerView(state: removalState(clients: [
        removalClient(second, regionId: "east", regionOrder: 2),
        removalClient(first, regionId: "east", regionOrder: 2),
        removalClient(west, regionId: "west", regionOrder: 1)
    ]))
    var selection = CloudGatewayMacClientRemovalSelection(snapshot: view)
    #expect(selection.groups.map(\.regionId) == ["west", "east"])
    #expect(selection.groups.map(\.title) == ["Region", "Region"])
    #expect(!selection.canDelete)
    selection.selectClient(first)
    #expect(selection.identifier == nil)
    selection.selectRegion("east")
    #expect(selection.rows.map(\.identifier) == [first, second])
    #expect(selection.rows.map(\.title) == ["Work Mac (Owner)", "Work Mac (Owner)"])
    selection.selectClient(second)
    #expect(selection.identifier == second)
    #expect(selection.canDelete)
    selection.selectRegion("east")
    #expect(selection.identifier == second)
    selection.selectRegion("west")
    #expect(selection.identifier == nil)
    #expect(!selection.canDelete)
    selection.selectClient(second)
    #expect(selection.identifier == nil)
    selection.selectClient(west)
    #expect(selection.canDelete)
    selection.selectRegion("missing")
    #expect(selection.regionId == nil)
    #expect(selection.identifier == nil)
}

@Test func removalSelectionHandlesEmptyRemovedAndNewlyActiveSelections() {
    var selection = CloudGatewayMacClientRemovalSelection(snapshot: .init(state: removalState()))
    selection.selectRegion("region")
    selection.selectClient(removalIdentifier)
    #expect(selection.canDelete)
    selection.update(snapshot: .init(state: removalState(profiles: [
        .init(identifier: removalIdentifier, status: .disconnecting)
    ])), isSnapshotFresh: true, isCurrentBuild: true)
    #expect(selection.identifier == removalIdentifier)
    #expect(!selection.canDelete)
    selection.update(snapshot: .init(state: removalState()), isSnapshotFresh: true, isCurrentBuild: true)
    #expect(selection.canDelete)
    selection.update(snapshot: .init(state: removalState(clients: [])), isSnapshotFresh: true, isCurrentBuild: true)
    #expect(selection.isValid)
    #expect(selection.regionId == nil)
    #expect(selection.identifier == nil)
    #expect(!selection.canDelete)
    #expect(selection.message == "No clients are available to remove")
}

@Test func removalNeverEnablesDeleteForUnavailableObservations() {
    for profiles in [[], [.init(identifier: removalIdentifier, status: .disconnected)]] as [[CloudGatewayMacObservedProfile]] {
        let view = CloudGatewayMacControllerView(state: removalState(profiles: profiles, observationIsFresh: false))
        #expect(view.canRemoveClient)
        #expect(view.groups.first?.rows.first?.removalPermission == .unavailable)
        var selection = CloudGatewayMacClientRemovalSelection(snapshot: view)
        selection.selectRegion("region")
        selection.selectClient(removalIdentifier)
        #expect(!selection.canDelete)
        #expect(selection.message == "VPN status is unavailable. Cancel and choose Refresh before deleting this config")
    }
}

@Test func removalInvalidatesForSessionInventoryBuildAndSnapshotChanges() {
    var blockedByOwner = removalState()
    blockedByOwner.removalAllowed = false
    let invalidStates = [
        removalState(accountId: nil), removalState(accountId: "other"), removalState(authorized: false),
        removalState(busy: true), removalState(restoring: true), removalState(settling: true),
        removalState(inventory: .refreshing), removalState(inventory: .unavailable), blockedByOwner
    ]
    for state in invalidStates {
        var selection = CloudGatewayMacClientRemovalSelection(snapshot: .init(state: removalState()))
        selection.selectRegion("region")
        selection.selectClient(removalIdentifier)
        selection.update(snapshot: .init(state: state), isSnapshotFresh: true, isCurrentBuild: true)
        #expect(!selection.isValid)
        #expect(!selection.canDelete)
        #expect(selection.identifier == nil)
    }
    for (fresh, current) in [(false, true), (true, false)] {
        var selection = CloudGatewayMacClientRemovalSelection(snapshot: .init(state: removalState()))
        selection.selectRegion("region")
        selection.selectClient(removalIdentifier)
        selection.update(snapshot: .init(state: removalState()), isSnapshotFresh: fresh, isCurrentBuild: current)
        #expect(!selection.isValid)
        selection.update(snapshot: .init(state: removalState()), isSnapshotFresh: true, isCurrentBuild: true)
        #expect(!selection.isValid)
    }
    var cancelled = CloudGatewayMacClientRemovalSelection(snapshot: .init(state: removalState()))
    cancelled.selectRegion("region")
    cancelled.selectClient(removalIdentifier)
    cancelled.invalidate()
    #expect(cancelled.identifier == nil)
    #expect(!cancelled.canDelete)
}

@Test func removalMessagesSurviveControllerSanitizationWithoutAdmittingArbitraryText() {
    for message in [
        "Client was removed. Disconnect it explicitly or stop it in System Settings before local cleanup, then Refresh",
        "Client was removed, but the client list could not refresh. Choose Refresh",
        "Could not confirm whether the client was removed. Refresh the client list before trying again",
        "Disconnect this client and wait for it to stop before removing it",
        "Client could not be removed. Refresh before trying again"
    ] {
        #expect(ControllerVisibleError.sanitize(message) == message)
    }
    #expect(ControllerVisibleError.sanitize("Client could not be removed: privateKey=secret")
        == "CloudGateway could not complete the request. Refresh before trying again")
}

@MainActor
@Test func removalDialogShowsRemoveClientTitle() throws {
    _ = NSApplication.shared
    let dialog = CloudGatewayMacClientRemovalDialog(snapshot: .init(state: removalState()))
    var views = [try #require(dialog.regionPicker.window?.contentView)]
    var labels: [String] = []
    while let view = views.popLast() {
        if let label = view as? NSTextField { labels.append(label.stringValue) }
        views.append(contentsOf: view.subviews)
    }
    #expect(labels.contains("Remove Client"))
}

@MainActor
@Test func removalDialogPreservesPickerItemsAcrossRepeatedSnapshots() throws {
    _ = NSApplication.shared
    let view = CloudGatewayMacControllerView(state: removalState())
    let dialog = CloudGatewayMacClientRemovalDialog(snapshot: view)
    dialog.regionPicker.selectItem(at: 1)
    #expect(dialog.regionPicker.sendAction(try #require(dialog.regionPicker.action), to: dialog.regionPicker.target))
    let regionItems = dialog.regionPicker.itemArray
    let configItems = dialog.configPicker.itemArray
    #expect(configItems.count == 2)
    for _ in 0..<3 {
        dialog.update(snapshot: view, isSnapshotFresh: true, isCurrentBuild: true)
        #expect(zip(regionItems, dialog.regionPicker.itemArray).allSatisfy { $0 === $1 })
        #expect(zip(configItems, dialog.configPicker.itemArray).allSatisfy { $0 === $1 })
        #expect(dialog.regionPicker.numberOfItems == regionItems.count)
        #expect(dialog.configPicker.numberOfItems == configItems.count)
    }
}

@MainActor
@Test func removalDialogDefersInventoryChangesUntilPickerTrackingEnds() async throws {
    _ = NSApplication.shared
    let dialog = CloudGatewayMacClientRemovalDialog(snapshot: .init(state: removalState()))
    dialog.regionPicker.selectItem(at: 1)
    #expect(dialog.regionPicker.sendAction(try #require(dialog.regionPicker.action), to: dialog.regionPicker.target))
    let menu = try #require(dialog.configPicker.menu)
    let configItem = try #require(dialog.configPicker.item(at: 1))
    dialog.menuWillOpen(menu)
    dialog.update(snapshot: .init(state: removalState(clients: [
        removalClient(removalIdentifier), removalClient("account/region/other")
    ])), isSnapshotFresh: true, isCurrentBuild: true)
    #expect(dialog.configPicker.numberOfItems == 2)
    #expect(dialog.configPicker.item(at: 1) === configItem)
    dialog.menuDidClose(menu)
    try #require(await controllerBoundaryEventually { dialog.configPicker.numberOfItems == 3 })
    #expect(dialog.configPicker.itemArray.dropFirst().compactMap { $0.representedObject as? String }
        == [removalIdentifier, "account/region/other"])
}

@MainActor
@Test func removalDialogInvalidationBeforePresentationReturnsNoSelection() async throws {
    _ = NSApplication.shared
    let dialog = CloudGatewayMacClientRemovalDialog(snapshot: .init(state: removalState()))
    dialog.update(snapshot: .init(state: removalState(accountId: nil)), isSnapshotFresh: true, isCurrentBuild: true)
    #expect(try await dialog.prompt() == nil)
}

@MainActor
@Test func removalDialogCancellationBeforePresentationThrowsWithoutReturningASelection() async throws {
    _ = NSApplication.shared
    let dialog = CloudGatewayMacClientRemovalDialog(snapshot: .init(state: removalState()))
    let task = Task { try await dialog.prompt() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}
