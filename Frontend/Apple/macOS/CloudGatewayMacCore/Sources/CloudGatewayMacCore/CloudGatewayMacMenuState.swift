import CloudGatewayKit
import Foundation

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
