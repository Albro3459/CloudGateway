import Foundation

public struct CloudGatewayTunnelHealthPersistencePolicy: Equatable, Sendable {
    public let heartbeatInterval: Duration
    public private(set) var lastPersistedHealth: CloudGatewayTunnelHealth?
    public private(set) var lastPersistedAt: Duration?

    public init(timing: CloudGatewayTunnelHealthTiming = .production) {
        heartbeatInterval = timing.persistenceHeartbeat
    }

    public init(heartbeatInterval: Duration) {
        self.heartbeatInterval = heartbeatInterval
    }

    public init(heartbeatInterval: TimeInterval) {
        self.heartbeatInterval = .seconds(heartbeatInterval)
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

    public func shouldPersist(_ health: CloudGatewayTunnelHealth, at date: Date) -> Bool {
        shouldPersist(health, at: .seconds(date.timeIntervalSinceReferenceDate))
    }

    public mutating func recordPersisted(_ health: CloudGatewayTunnelHealth, at date: Date) {
        recordPersisted(health, at: .seconds(date.timeIntervalSinceReferenceDate))
    }
}
