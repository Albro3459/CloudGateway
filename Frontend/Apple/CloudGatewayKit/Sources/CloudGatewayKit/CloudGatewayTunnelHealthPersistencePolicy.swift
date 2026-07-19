import Foundation

public struct CloudGatewayTunnelHealthPersistencePolicy: Equatable, Sendable {
    public let heartbeatInterval: Duration
    public private(set) var lastPersistedHealth: CloudGatewayTunnelHealth?
    public private(set) var lastPersistedAt: Duration?

    public init(timing: CloudGatewayTunnelHealthTiming = .production) {
        heartbeatInterval = timing.persistenceHeartbeat
    }

    public func shouldPersist(_ health: CloudGatewayTunnelHealth, at now: Duration) -> Bool {
        let transitioned = health != lastPersistedHealth
        let heartbeatDue = lastPersistedAt
            .map { now - $0 >= heartbeatInterval } ?? true
        return transitioned || heartbeatDue
    }

    public mutating func recordPersisted(_ health: CloudGatewayTunnelHealth, at now: Duration) {
        lastPersistedHealth = health
        lastPersistedAt = now
    }
}
