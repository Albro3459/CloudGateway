import AppKit
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
