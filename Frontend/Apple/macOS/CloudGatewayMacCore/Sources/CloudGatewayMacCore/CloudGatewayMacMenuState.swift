import CloudGatewayKit
import Foundation

public struct CloudGatewayMacMenuClient: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let status: CloudGatewayTunnelStatus?
    public let isEnabled: Bool
}

public struct CloudGatewayMacMenuRegion: Equatable, Sendable {
    public let title: String
    public let rows: [CloudGatewayMacMenuClient]
}

public struct CloudGatewayMacMenuState: Sendable {
    private let accountId: String?
    private let setupState: CloudGatewayMacSetupState
    private let onlineOptions: [CloudGatewayClientOption]
    private let cachedConfigs: [CloudGatewayMacInstalledConfig]
    private let profiles: [CloudGatewayMacInstalledProfile]
    private let commandInFlight: Bool
    private let inventoryInFlight: Bool
    private let isOffline: Bool
    private let hasError: Bool
    private let hasRetainedSession: Bool

    public init(
        accountId: String?,
        setupState: CloudGatewayMacSetupState,
        onlineOptions: [CloudGatewayClientOption],
        cachedConfigs: [CloudGatewayMacInstalledConfig],
        profiles: [CloudGatewayMacInstalledProfile],
        commandInFlight: Bool,
        isOffline: Bool,
        inventoryInFlight: Bool = false,
        hasError: Bool = false,
        hasRetainedSession: Bool = false
    ) {
        self.accountId = accountId
        self.setupState = setupState
        self.onlineOptions = onlineOptions
        self.cachedConfigs = cachedConfigs
        self.profiles = profiles
        self.commandInFlight = commandInFlight
        self.inventoryInFlight = inventoryInFlight
        self.isOffline = isOffline
        self.hasError = hasError
        self.hasRetainedSession = hasRetainedSession
    }

    public var canRefresh: Bool { accountId != nil && !commandInFlight && !inventoryInFlight }
    public var canSignOut: Bool { accountId != nil || hasRetainedSession }
    public var canTurnOff: Bool {
        accountId != nil && !commandInFlight && profiles.contains(where: \.needsConfirmedStop)
    }

    public var hasActiveTunnel: Bool {
        profiles.contains { $0.status == .connected || $0.status == .reasserting }
    }

    public var groups: [CloudGatewayMacMenuRegion] {
        guard let accountId else { return [] }
        if isOffline {
            let accountConfigs = cachedConfigs.filter { $0.accountId == accountId }
            let regions = CloudGatewayConfigSelection.offlineRegions(from: accountConfigs.map(\.snapshot))
            return regions.map { region in
                let rows = accountConfigs.filter { $0.snapshot.regionId == region.regionId }.sorted {
                    $0.snapshot.clientDisplayName.localizedCaseInsensitiveCompare($1.snapshot.clientDisplayName) == .orderedAscending
                }.map { config in
                    let matching = profiles.first {
                        $0.identifier == config.identifier && $0.reference == (try? config.reference)
                    }
                    return CloudGatewayMacMenuClient(
                        identifier: config.identifier,
                        title: config.snapshot.clientDisplayName,
                        status: matching?.status,
                        isEnabled: canConnect && matching != nil && config.snapshot.status == .active
                    )
                }
                return CloudGatewayMacMenuRegion(title: region.displayName, rows: rows)
            }
        }
        let regionIds = Set(onlineOptions.filter { $0.client.status != .removed }.map { $0.client.regionId })
        let regions = CloudGatewayConfigSelection.sortedRegions(regionIds.map { regionId in
            onlineOptions.first { $0.client.regionId == regionId }?.region
                ?? CloudGatewayRegion(regionId: regionId, displayName: regionId, enabled: false)
        })
        return regions.map { region in
            let options = onlineOptions.filter { $0.client.regionId == region.regionId && $0.client.status != .removed }.sorted {
                let ownerComparison = ($0.client.ownerEmail ?? "").localizedCaseInsensitiveCompare($1.client.ownerEmail ?? "")
                if ownerComparison != .orderedSame { return ownerComparison == .orderedAscending }
                return $0.client.displayName.localizedCaseInsensitiveCompare($1.client.displayName) == .orderedAscending
            }
            let rows = options.map { option in
                let identifier = "\(accountId)/\(option.client.regionId)/\(option.client.clientId)"
                let profile = profiles.first { $0.identifier == identifier }
                let title = option.client.ownerEmail.map { "\(option.client.displayName) (\($0))" } ?? option.client.displayName
                return CloudGatewayMacMenuClient(
                    identifier: identifier,
                    title: title,
                    status: profile?.status,
                    isEnabled: canConnect && option.client.hasUsableConfig && option.region?.enabled == true
                )
            }
            return CloudGatewayMacMenuRegion(title: region.displayName, rows: rows)
        }
    }

    public var statusTitle: String {
        guard accountId != nil else { return "Signed out" }
        let tunnelTitle: String
        if profiles.contains(where: { $0.status == .connected || $0.status == .reasserting }) {
            tunnelTitle = "VPN connected"
        } else if profiles.contains(where: { $0.status == .connecting }) {
            tunnelTitle = "VPN connecting…"
        } else if profiles.contains(where: { $0.status == .disconnecting }) {
            tunnelTitle = "VPN disconnecting…"
        } else if commandInFlight || inventoryInFlight {
            tunnelTitle = "Working…"
        } else if setupState != .ready {
            return setupState.title
        } else if hasError {
            return "Could not complete the action"
        } else {
            tunnelTitle = "VPN off"
        }
        return isOffline ? "Offline · \(tunnelTitle)" : tunnelTitle
    }

    private var canConnect: Bool { accountId != nil && setupState == .ready && !commandInFlight && !inventoryInFlight }
}

public struct CloudGatewayMacProfileObservation: Sendable {
    public private(set) var profiles: [CloudGatewayMacInstalledProfile] = []
    public private(set) var errorMessage: String?

    public init() {}

    public mutating func didRead(_ profiles: [CloudGatewayMacInstalledProfile]) {
        self.profiles = profiles
        errorMessage = nil
    }

    public mutating func didFailRead() {
        errorMessage = "Unable to read VPN preferences. Try Refresh again"
    }
}

public struct CloudGatewayMacSessionToken: Equatable, Sendable {
    public let accountId: String
    fileprivate let epoch: UInt64
}

public struct CloudGatewayMacSessionFence: Sendable {
    private var accountId: String?
    private var epoch: UInt64 = 0

    public init() {}

    public var currentToken: CloudGatewayMacSessionToken? {
        accountId.map { CloudGatewayMacSessionToken(accountId: $0, epoch: epoch) }
    }

    public mutating func changeAccount(to accountId: String?) {
        epoch &+= 1
        self.accountId = accountId
    }

    public mutating func invalidate() { epoch &+= 1 }

    public func isCurrent(_ token: CloudGatewayMacSessionToken) -> Bool {
        accountId == token.accountId && epoch == token.epoch
    }
}

public enum CloudGatewayMacInventoryFailure: Equatable, Sendable {
    case accessDenied
    case transport
    case invalidResponse
}

public enum CloudGatewayMacOfflinePolicy {
    public static func canUseCache(
        after failure: CloudGatewayMacInventoryFailure,
        cache: CloudGatewayMacAccountCacheSnapshot
    ) -> Bool {
        failure == .transport && cache.accessAllowed
    }
}
