import AppKit
import CloudGatewayKit
import Testing
@testable import CloudGatewayMacControllerIPC

@MainActor
@Test(arguments: [false, true])
func menuUpdatesNeverEnableClientsFromStaleSnapshotsOrWhileActionsAreBlocked(isFresh: Bool) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let item = NSMenuItem(title: "Mac", action: NSSelectorFromString("selectClient:"), keyEquivalent: "")
    item.representedObject = "account/region/client"
    menu.addItem(item)
    let state = CloudGatewayMacControllerView(state: controllerBoundaryState(active: true))
    CloudGatewayMacMenuUpdates.updateClients(in: menu, from: state, isSnapshotFresh: isFresh, canConnect: false)
    #expect(!item.isEnabled)
    #expect(item.state == (isFresh ? .on : .off))
    CloudGatewayMacMenuUpdates.updateClients(in: menu, from: state, isSnapshotFresh: false, canConnect: true)
    #expect(!item.isEnabled)
    #expect(item.state == .off)
    #expect(menu.items.first === item)
}

@MainActor
@Test func menuUpdatesDisableRemovedClientsWithoutReplacingItemsOrInsertingNewClients() {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let item = NSMenuItem(title: "Original Mac", action: NSSelectorFromString("selectClient:"), keyEquivalent: "")
    item.representedObject = "old-account/region/client"
    item.isEnabled = true
    item.state = .on
    menu.addItem(item)
    let state = CloudGatewayMacControllerView(state: controllerBoundaryState(active: true))
    CloudGatewayMacMenuUpdates.updateClients(in: menu, from: state, isSnapshotFresh: true, canConnect: true)
    #expect(!item.isEnabled)
    #expect(item.state == .off)
    #expect(menu.items.count == 1)
    #expect(menu.items.first === item)
    #expect(item.title == "Original Mac")
    #expect(item.representedObject as? String == "old-account/region/client")
}

@MainActor
@Test func menuModeChoicesKeepPreferenceCheckmarksAndFollowLiveCommandGates() {
    let menu = NSMenu()
    let parent = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
    let choices = NSMenu()
    choices.autoenablesItems = false
    parent.submenu = choices
    menu.addItem(parent)
    for mode in CloudGatewayRoutingMode.allCases {
        let item = NSMenuItem(title: mode.displayName, action: NSSelectorFromString("selectMode:"), keyEquivalent: "")
        item.representedObject = mode.rawValue
        choices.addItem(item)
    }
    #expect(choices.items.map(\.title) == ["Full", "Mesh only"])
    let state = CloudGatewayMacControllerView(selectedMode: .mesh, activeMode: .full, canSetMode: true)
    CloudGatewayMacMenuUpdates.updateClients(in: menu, from: state, isSnapshotFresh: true, canConnect: true)
    CloudGatewayMacMenuUpdates.updateModes(in: menu, from: state, isSnapshotFresh: true, canSetMode: true)
    #expect(choices.items.map(\.state) == [.off, .on])
    #expect(choices.items.allSatisfy { $0.isEnabled })
    for (fresh, allowed) in [(false, true), (true, false)] {
        CloudGatewayMacMenuUpdates.updateModes(in: menu, from: state, isSnapshotFresh: fresh, canSetMode: allowed)
        #expect(choices.items.allSatisfy { !$0.isEnabled })
        #expect(choices.items.map(\.state) == [.off, .on])
    }
    CloudGatewayMacMenuUpdates.updateModes(in: menu, from: .init(activeMode: .mesh), isSnapshotFresh: true, canSetMode: true)
    #expect(choices.items.allSatisfy { !$0.isEnabled && $0.state == .off })
}
