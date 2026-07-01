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

@Test func cachedSnapshotDoesNotSelectRemoteConfigAutomatically() throws {
    let cached = CloudGatewayConfigSnapshot(
        clientId: "old-client",
        regionId: "us-sanjose-1",
        clientName: "Old",
        regionDisplayName: "San Jose",
        status: .active,
        wireGuardConfig: usableConfig,
        readAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let options = [
        CloudGatewayClientOption(
            client: CloudGatewayClient(
                clientId: "new-client",
                clientName: "New",
                regionId: "us-sanjose-1",
                status: .active,
                wireGuardConfig: usableConfig
            ),
            region: CloudGatewayRegion(regionId: "us-sanjose-1", displayName: "San Jose", enabled: true)
        )
    ]

    #expect(!CloudGatewayConfigSelection.containsUsableClient(matching: cached, in: options))
}

@Test func configMatchesRequiresSameClientRegionAndConfig() throws {
    let snapshot = CloudGatewayConfigSnapshot(
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
