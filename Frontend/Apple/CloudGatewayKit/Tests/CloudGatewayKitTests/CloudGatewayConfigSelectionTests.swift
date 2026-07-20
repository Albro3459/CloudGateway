import Foundation
import Testing
@testable import CloudGatewayKit

private let usableConfig = """
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

[Peer]
PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
"""

@Test func regionsSortByDisplayOrderThenName() {
    let regions = [
        CloudGatewayRegion(regionId: "us-z", displayName: "Zulu", enabled: true, displayOrder: 20),
        CloudGatewayRegion(regionId: "us-a", displayName: "Alpha", enabled: true, displayOrder: 10),
        CloudGatewayRegion(regionId: "us-b", displayName: "Beta", enabled: true, displayOrder: 10),
    ]

    #expect(CloudGatewayConfigSelection.sortedRegions(regions).map(\.regionId) == ["us-a", "us-b", "us-z"])
}

@Test func usableOptionsFilterInactiveMissingConfigsAndUnavailableRegions() {
    let clients = [
        CloudGatewayClient(
            clientId: "active",
            clientName: "Phone",
            regionId: "us-sanjose-1",
            status: .active,
            wireGuardConfig: usableConfig
        ),
        CloudGatewayClient(
            clientId: "creating",
            clientName: "Creating",
            regionId: "us-sanjose-1",
            status: .creating,
            wireGuardConfig: usableConfig
        ),
        CloudGatewayClient(
            clientId: "missing-config",
            clientName: "Missing",
            regionId: "us-sanjose-1",
            status: .active,
            wireGuardConfig: nil
        ),
        CloudGatewayClient(
            clientId: "removed",
            clientName: "Removed",
            regionId: "us-sanjose-1",
            status: .removed,
            wireGuardConfig: usableConfig
        ),
        CloudGatewayClient(
            clientId: "missing-region",
            clientName: "Missing Region",
            regionId: "us-missing-1",
            status: .active,
            wireGuardConfig: usableConfig
        ),
        CloudGatewayClient(
            clientId: "disabled-region",
            clientName: "Disabled Region",
            regionId: "us-disabled-1",
            status: .active,
            wireGuardConfig: usableConfig
        ),
    ]

    let options = CloudGatewayConfigSelection.usableOptions(
        clients: clients,
        regions: [
            CloudGatewayRegion(regionId: "us-sanjose-1", displayName: "San Jose", enabled: true),
            CloudGatewayRegion(regionId: "us-disabled-1", displayName: "Disabled", enabled: false),
        ]
    )

    #expect(options.map(\.client.clientId) == ["active"])
    #expect(options.first?.region == CloudGatewayRegion(regionId: "us-sanjose-1", displayName: "San Jose", enabled: true))
}

@Test func usableOptionsSortByRegionThenClientName() {
    let regions = [
        CloudGatewayRegion(regionId: "us-ashburn-1", displayName: "Ashburn", enabled: true, displayOrder: 20),
        CloudGatewayRegion(regionId: "us-sanjose-1", displayName: "San Jose", enabled: true, displayOrder: 10),
    ]
    let clients = [
        CloudGatewayClient(clientId: "z", clientName: "Z Phone", regionId: "us-ashburn-1", status: .active, wireGuardConfig: usableConfig),
        CloudGatewayClient(clientId: "b", clientName: "B Phone", regionId: "us-sanjose-1", status: .active, wireGuardConfig: usableConfig),
        CloudGatewayClient(clientId: "a", clientName: "A Phone", regionId: "us-sanjose-1", status: .active, wireGuardConfig: usableConfig),
    ]

    let options = CloudGatewayConfigSelection.usableOptions(clients: clients, regions: regions)

    #expect(options.map(\.client.clientId) == ["a", "b", "z"])
}

@Test func clientOptionsKeepCreatingAndFailedButHideRemovedByDefault() {
    let regions = [
        CloudGatewayRegion(regionId: "us-sanjose-1", displayName: "San Jose", enabled: true, displayOrder: 10),
    ]
    let clients = [
        CloudGatewayClient(clientId: "active", clientName: "Active", regionId: "us-sanjose-1", status: .active, wireGuardConfig: usableConfig),
        CloudGatewayClient(clientId: "creating", clientName: "Creating", regionId: "us-sanjose-1", status: .creating, wireGuardConfig: nil),
        CloudGatewayClient(clientId: "failed", clientName: "Failed", regionId: "us-sanjose-1", status: .failed, wireGuardConfig: nil),
        CloudGatewayClient(clientId: "removed", clientName: "Removed", regionId: "us-sanjose-1", status: .removed, wireGuardConfig: usableConfig),
    ]

    let options = CloudGatewayConfigSelection.clientOptions(clients: clients, regions: regions)

    #expect(options.map(\.client.clientId) == ["active", "creating", "failed"])
}

@Test func clientOptionsFilterBySelectedRegionOnlyWhenProvided() {
    let options = [
        CloudGatewayClientOption(
            client: CloudGatewayClient(clientId: "sj", clientName: "Phone", regionId: "us-sanjose-1", status: .active, wireGuardConfig: usableConfig),
            region: CloudGatewayRegion(regionId: "us-sanjose-1", displayName: "San Jose", enabled: true)
        ),
        CloudGatewayClientOption(
            client: CloudGatewayClient(clientId: "ash", clientName: "Laptop", regionId: "us-ashburn-1", status: .active, wireGuardConfig: usableConfig),
            region: CloudGatewayRegion(regionId: "us-ashburn-1", displayName: "Ashburn", enabled: true)
        ),
    ]

    #expect(CloudGatewayConfigSelection.clientOptions(in: nil, options: options).map(\.client.clientId) == ["sj", "ash"])
    #expect(CloudGatewayConfigSelection.clientOptions(in: "us-ashburn-1", options: options).map(\.client.clientId) == ["ash"])
}

@Test func regionCapacityReportsKnownUnknownAndFullStates() {
    let unknown = CloudGatewayRegionCapacity.unknown
    let available = CloudGatewayRegionCapacity.known(limit: 10, allocated: 9)
    let full = CloudGatewayRegionCapacity.known(limit: 10, allocated: 10)

    #expect(!unknown.isKnown)
    #expect(unknown.displayText == "Capacity unavailable")
    #expect(available.displayText == "9 / 10 used")
    #expect(!available.isAtCapacity)
    #expect(full.isAtCapacity)
}

@Test func snapshotUsesSelectedClientAndValidatesConfig() throws {
    let option = CloudGatewayClientOption(
        client: CloudGatewayClient(
            clientId: "client-1",
            clientName: "iPhone",
            regionId: "us-sanjose-1",
            status: .active,
            wireGuardConfig: usableConfig,
            updatedAt: Date(timeIntervalSince1970: 100)
        ),
        region: CloudGatewayRegion(regionId: "us-sanjose-1", displayName: "San Jose", enabled: true)
    )

    let snapshot = try CloudGatewayConfigSelection.snapshot(from: option, readAt: Date(timeIntervalSince1970: 200))

    #expect(snapshot.clientId == "client-1")
    #expect(snapshot.regionDisplayName == "San Jose")
    #expect(snapshot.clientDisplayName == "iPhone")
    #expect(try snapshot.tunnelConfiguration().identifier == "client-1")
}

@Test func snapshotPreservesCanonicalDisplayMetadataForOfflineRows() throws {
    let option = CloudGatewayClientOption(
        client: CloudGatewayClient(
            clientId: "client-1",
            clientName: "iPhone",
            regionId: "us-sanjose-1",
            status: .active,
            wireGuardConfig: usableConfig,
            assignedTunnelIpv4: "10.0.0.2/32",
            serverEndpointIpv4: "203.0.113.10",
            serverEndpointHostname: "wg.us-sanjose-1.example.com"
        ),
        region: CloudGatewayRegion(regionId: "us-sanjose-1", displayName: "San Jose", enabled: true)
    )

    let snapshot = try CloudGatewayConfigSelection.snapshot(from: option)
    let offline = CloudGatewayConfigSelection.offlineClientOptions(from: [snapshot]).first?.client

    #expect(offline?.assignedTunnelIpv4 == "10.0.0.2/32")
    #expect(offline?.serverEndpointIpv4 == "203.0.113.10")
    #expect(offline?.serverEndpointHostname == "wg.us-sanjose-1.example.com")
}

@Test func mergeClientsLetsExistingOverrideFetchedByRegionAndClientId() {
    let fetched = [
        CloudGatewayClient(clientId: "a", clientName: "Old A", regionId: "us-sanjose-1", status: .active, wireGuardConfig: usableConfig),
        CloudGatewayClient(clientId: "b", clientName: "B", regionId: "us-sanjose-1", status: .active, wireGuardConfig: usableConfig),
    ]
    let existing = [
        CloudGatewayClient(clientId: "a", clientName: "New A", regionId: "us-sanjose-1", status: .creating, wireGuardConfig: nil),
        CloudGatewayClient(clientId: "a", clientName: "Other Region A", regionId: "us-ashburn-1", status: .active, wireGuardConfig: usableConfig),
    ]

    let merged = CloudGatewayConfigSelection.mergeClients(existing: existing, fetched: fetched)
    let byKey = Dictionary(uniqueKeysWithValues: merged.map { ("\($0.regionId)/\($0.clientId)", $0) })

    #expect(merged.count == 3)
    #expect(byKey["us-sanjose-1/a"]?.clientName == "New A")
    #expect(byKey["us-sanjose-1/a"]?.status == .creating)
    #expect(byKey["us-sanjose-1/b"]?.clientName == "B")
    #expect(byKey["us-ashburn-1/a"]?.clientName == "Other Region A")
}

@Test func resolvedRegionSelectionKeepsValidSelectionOtherwiseFallsBackToFirst() {
    let regions = [
        CloudGatewayRegion(regionId: "us-sanjose-1", displayName: "San Jose", enabled: true, displayOrder: 10),
        CloudGatewayRegion(regionId: "us-ashburn-1", displayName: "Ashburn", enabled: true, displayOrder: 20),
    ]

    #expect(CloudGatewayConfigSelection.resolvedRegionSelection(current: "us-ashburn-1", regions: regions) == "us-ashburn-1")
    #expect(CloudGatewayConfigSelection.resolvedRegionSelection(current: "us-gone-1", regions: regions) == "us-sanjose-1")
    #expect(CloudGatewayConfigSelection.resolvedRegionSelection(current: nil, regions: regions) == "us-sanjose-1")
    #expect(CloudGatewayConfigSelection.resolvedRegionSelection(current: "us-sanjose-1", regions: []) == nil)
}

@Test func resolvedRegionSelectionPrefersFirstRegionWithConfigInDisplayOrder() {
    let regions = [
        CloudGatewayRegion(regionId: "us-sanjose-1", displayName: "San Jose", enabled: true, displayOrder: 10),
        CloudGatewayRegion(regionId: "us-ashburn-1", displayName: "Ashburn", enabled: true, displayOrder: 20),
        CloudGatewayRegion(regionId: "us-chicago-1", displayName: "Chicago", enabled: true, displayOrder: 30),
    ]
    func option(regionId: String) -> CloudGatewayClientOption {
        CloudGatewayClientOption(
            client: CloudGatewayClient(clientId: regionId, clientName: "Phone", regionId: regionId, status: .active, wireGuardConfig: usableConfig),
            region: regions.first { $0.regionId == regionId }
        )
    }

    // First region has no config; preselect the next region (in display order) that does.
    #expect(CloudGatewayConfigSelection.resolvedRegionSelection(
        current: nil,
        regions: regions,
        clientOptions: [option(regionId: "us-chicago-1"), option(regionId: "us-ashburn-1")]
    ) == "us-ashburn-1")

    // No config anywhere falls back to the first region by display order.
    #expect(CloudGatewayConfigSelection.resolvedRegionSelection(
        current: nil,
        regions: regions,
        clientOptions: []
    ) == "us-sanjose-1")

    // A still-valid current selection is preserved regardless of configs.
    #expect(CloudGatewayConfigSelection.resolvedRegionSelection(
        current: "us-sanjose-1",
        regions: regions,
        clientOptions: [option(regionId: "us-ashburn-1")]
    ) == "us-sanjose-1")

    // No regions still resolves to nil (check-access would have failed already).
    #expect(CloudGatewayConfigSelection.resolvedRegionSelection(
        current: nil,
        regions: [],
        clientOptions: [option(regionId: "us-ashburn-1")]
    ) == nil)
}

@Test func prunedClientSelectionDropsSelectionOutsideFilteredRegion() {
    let options = [
        CloudGatewayClientOption(
            client: CloudGatewayClient(clientId: "sj", clientName: "Phone", regionId: "us-sanjose-1", status: .active, wireGuardConfig: usableConfig),
            region: CloudGatewayRegion(regionId: "us-sanjose-1", displayName: "San Jose", enabled: true)
        ),
        CloudGatewayClientOption(
            client: CloudGatewayClient(clientId: "ash", clientName: "Laptop", regionId: "us-ashburn-1", status: .active, wireGuardConfig: usableConfig),
            region: CloudGatewayRegion(regionId: "us-ashburn-1", displayName: "Ashburn", enabled: true)
        ),
    ]

    #expect(CloudGatewayConfigSelection.prunedClientSelection(current: "sj", regionId: "us-sanjose-1", options: options) == "sj")
    #expect(CloudGatewayConfigSelection.prunedClientSelection(current: "sj", regionId: "us-ashburn-1", options: options) == nil)
    #expect(CloudGatewayConfigSelection.prunedClientSelection(current: "gone", regionId: nil, options: options) == nil)
    #expect(CloudGatewayConfigSelection.prunedClientSelection(current: nil, regionId: nil, options: options) == nil)
}

@Test func selectedRegionResolvesByIdentifier() {
    let regions = [
        CloudGatewayRegion(regionId: "us-sanjose-1", displayName: "San Jose", enabled: true),
        CloudGatewayRegion(regionId: "us-ashburn-1", displayName: "Ashburn", enabled: true),
    ]

    #expect(CloudGatewayConfigSelection.selectedRegion(id: "us-ashburn-1", in: regions)?.regionId == "us-ashburn-1")
    #expect(CloudGatewayConfigSelection.selectedRegion(id: nil, in: regions) == nil)
    #expect(CloudGatewayConfigSelection.selectedRegion(id: "us-gone-1", in: regions) == nil)
}

@Test func configMatchesRequiresSameClientRegionAndConfig() throws {
    let snapshot = try CloudGatewayConfigSnapshot(
        clientId: "client-1",
        regionId: "us-sanjose-1",
        clientName: "Phone",
        regionDisplayName: "San Jose",
        status: .active,
        wireGuardConfig: usableConfig,
        readAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let matchingOption = CloudGatewayClientOption(
        client: CloudGatewayClient(
            clientId: "client-1",
            clientName: "Phone",
            regionId: "us-sanjose-1",
            status: .active,
            wireGuardConfig: usableConfig
        ),
        region: CloudGatewayRegion(regionId: "us-sanjose-1", displayName: "San Jose", enabled: true)
    )
    let changedOption = CloudGatewayClientOption(
        client: CloudGatewayClient(
            clientId: "client-1",
            clientName: "Phone",
            regionId: "us-sanjose-1",
            status: .active,
            wireGuardConfig: usableConfig + "\n# changed"
        ),
        region: CloudGatewayRegion(regionId: "us-sanjose-1", displayName: "San Jose", enabled: true)
    )

    #expect(CloudGatewayConfigSelection.configMatches(snapshot, option: matchingOption))
    #expect(!CloudGatewayConfigSelection.configMatches(snapshot, option: changedOption))
}

@Test func offlineClientOptionsBuildRegionScopedRowsFromSnapshots() throws {
    func snapshot(
        clientId: String,
        clientName: String,
        regionId: String,
        regionDisplayName: String
    ) throws -> CloudGatewayConfigSnapshot {
        try CloudGatewayConfigSnapshot(
            clientId: clientId,
            regionId: regionId,
            clientName: clientName,
            regionDisplayName: regionDisplayName,
            status: .active,
            wireGuardConfig: usableConfig,
            readAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
    }

    let snapshots = [
        try snapshot(clientId: "b", clientName: "Zulu", regionId: "us-sanjose-1", regionDisplayName: "San Jose"),
        try snapshot(clientId: "a", clientName: "Alpha", regionId: "us-sanjose-1", regionDisplayName: "San Jose"),
        try snapshot(clientId: "c", clientName: "Laptop", regionId: "us-ashburn-1", regionDisplayName: "Ashburn"),
    ]

    let options = CloudGatewayConfigSelection.offlineClientOptions(from: snapshots)

    // Sorted by region name (Ashburn < San Jose) then client display name.
    #expect(options.map(\.client.clientId) == ["c", "a", "b"])
    // The WireGuard config lives in the keychain, never in the offline row.
    #expect(options.allSatisfy { $0.client.wireGuardConfig == nil })
    // Region display name comes from the snapshot, not just the id.
    #expect(options.first?.regionDisplayName == "Ashburn")
    #expect(options.first?.client.status == .active)
    #expect(options.first?.client.updatedAt == Date(timeIntervalSince1970: 200))
    // Region-filtering keeps offline rows scoped like remote ones.
    #expect(CloudGatewayConfigSelection.clientOptions(in: "us-sanjose-1", options: options).map(\.client.clientId) == ["a", "b"])
}

@Test func offlineRegionsUseLatestCachedDisplayNameAndFallbackToRegionId() throws {
    func snapshot(
        clientId: String,
        regionId: String,
        regionDisplayName: String,
        readAt: TimeInterval
    ) throws -> CloudGatewayConfigSnapshot {
        try CloudGatewayConfigSnapshot(
            clientId: clientId,
            regionId: regionId,
            clientName: clientId,
            regionDisplayName: regionDisplayName,
            status: .active,
            wireGuardConfig: usableConfig,
            readAt: Date(timeIntervalSince1970: readAt),
            updatedAt: nil
        )
    }

    let snapshots = [
        try snapshot(clientId: "old", regionId: "us-sanjose-1", regionDisplayName: "Old California", readAt: 100),
        try snapshot(clientId: "new", regionId: "us-sanjose-1", regionDisplayName: "California", readAt: 200),
        try snapshot(clientId: "unknown", regionId: "us-unknown-1", regionDisplayName: "", readAt: 300),
    ]

    let regions = CloudGatewayConfigSelection.offlineRegions(from: snapshots)

    #expect(regions.map(\.regionId) == ["us-sanjose-1", "us-unknown-1"])
    #expect(regions.map(\.displayName) == ["California", "us-unknown-1"])
}

@Test func installStateTreatsCachedRowWithoutConfigAsInstalled() throws {
    let snapshot = try CloudGatewayConfigSnapshot(
        clientId: "client-1",
        regionId: "us-sanjose-1",
        clientName: "Phone",
        regionDisplayName: "San Jose",
        status: .active,
        wireGuardConfig: usableConfig,
        readAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let state = CloudGatewayConfigManagerState(installedSnapshots: [snapshot])
    let offlineOption = CloudGatewayConfigSelection.offlineClientOptions(from: [snapshot])[0]

    // No remote config to diff against -> installed, not a spurious "update available".
    #expect(offlineOption.client.wireGuardConfig == nil)
    #expect(state.installState(for: offlineOption) == .installed)
}
