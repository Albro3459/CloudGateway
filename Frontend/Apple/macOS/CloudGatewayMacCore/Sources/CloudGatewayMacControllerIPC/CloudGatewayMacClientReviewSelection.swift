import Foundation

struct CloudGatewayMacClientReviewSelection {
    let accountId: String?
    private(set) var groups: [CloudGatewayMacControllerView.Region] = []
    private(set) var regionId: String?
    private(set) var identifier: String?
    private(set) var isValid = true

    init(snapshot: CloudGatewayMacControllerView) {
        accountId = snapshot.accountId
        update(snapshot: snapshot, isSnapshotFresh: true, isCurrentBuild: true)
    }

    var rows: [CloudGatewayMacControllerView.Client] {
        groups.first { $0.regionId == regionId }?.rows ?? []
    }

    var selectedClient: CloudGatewayMacControllerView.Client? {
        rows.first { $0.identifier == identifier }
    }

    var canDelete: Bool { isValid && selectedClient?.removalPermission == .inactive }

    var message: String {
        guard !groups.isEmpty else { return "No clients are available to review" }
        guard let selectedClient else { return "Select a region and config to review" }
        switch selectedClient.removalPermission {
        case .inactive: return "Deleting this client removes its cloud config and local VPN profile. This cannot be undone"
        case .active: return "Disconnect this config and wait for it to stop before deleting it"
        case .unavailable: return "VPN status is unavailable. Cancel and choose Refresh before deleting this config"
        }
    }

    mutating func selectRegion(_ regionId: String?) {
        let next = groups.first { $0.regionId == regionId }?.regionId
        if self.regionId != next { identifier = nil }
        self.regionId = next
    }

    mutating func selectClient(_ identifier: String?) {
        self.identifier = rows.first { $0.identifier == identifier }?.identifier
    }

    mutating func update(snapshot: CloudGatewayMacControllerView, isSnapshotFresh: Bool, isCurrentBuild: Bool) {
        guard isValid, isSnapshotFresh, isCurrentBuild, accountId != nil,
              snapshot.accountId == accountId, snapshot.canReviewClient else {
            invalidate()
            return
        }
        groups = snapshot.groups
        if !groups.contains(where: { $0.regionId == regionId }) { selectRegion(nil) }
        if !rows.contains(where: { $0.identifier == identifier }) { identifier = nil }
    }

    mutating func invalidate() {
        isValid = false
        groups = []
        regionId = nil
        identifier = nil
    }
}
