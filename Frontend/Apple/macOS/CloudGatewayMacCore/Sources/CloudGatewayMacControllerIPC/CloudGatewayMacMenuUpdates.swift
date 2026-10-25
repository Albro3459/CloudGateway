import AppKit
import CloudGatewayKit

public enum CloudGatewayMacMenuUpdates {
    @MainActor
    public static func updateClients(in menu: NSMenu, from snapshot: CloudGatewayMacControllerView,
                                     isSnapshotFresh: Bool, canConnect: Bool) {
        let rows = Dictionary(snapshot.groups.flatMap(\.rows).map { ($0.identifier, $0) },
                              uniquingKeysWith: { first, _ in first })
        updateClients(in: menu, rows: rows, isSnapshotFresh: isSnapshotFresh, canConnect: canConnect)
    }

    @MainActor
    public static func updateModes(in menu: NSMenu, from snapshot: CloudGatewayMacControllerView,
                                   isSnapshotFresh: Bool, canSetMode: Bool) {
        for item in menu.items {
            if let value = item.representedObject as? String, let mode = CloudGatewayRoutingMode(rawValue: value) {
                item.state = snapshot.selectedMode == mode ? .on : .off
                item.isEnabled = isSnapshotFresh && canSetMode && snapshot.canSetMode
            }
            if let submenu = item.submenu {
                updateModes(in: submenu, from: snapshot, isSnapshotFresh: isSnapshotFresh, canSetMode: canSetMode)
            }
        }
    }

    @MainActor
    private static func updateClients(in menu: NSMenu, rows: [String: CloudGatewayMacControllerView.Client],
                                      isSnapshotFresh: Bool, canConnect: Bool) {
        for item in menu.items {
            if let identifier = item.representedObject as? String, CloudGatewayRoutingMode(rawValue: identifier) == nil {
                let row = rows[identifier]
                item.isEnabled = isSnapshotFresh && canConnect && row?.isEnabled == true
                item.state = isSnapshotFresh && (row?.status == .connected || row?.status == .reasserting) ? .on : .off
            }
            if let submenu = item.submenu {
                updateClients(in: submenu, rows: rows, isSnapshotFresh: isSnapshotFresh, canConnect: canConnect)
            }
        }
    }
}
