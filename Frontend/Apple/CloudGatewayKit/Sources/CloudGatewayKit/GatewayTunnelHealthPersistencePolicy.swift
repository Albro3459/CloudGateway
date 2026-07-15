import Foundation

public struct GatewayTunnelHealthPersistencePolicy: Equatable, Sendable {
    public let heartbeatInterval: Duration
    public private(set) var lastPersistedHealth: GatewayTunnelHealth?
    public private(set) var lastPersistedAt: Duration?

    public init(timing: GatewayTunnelHealthTiming = .production) {
        heartbeatInterval = timing.persistenceHeartbeat
    }

    public init(heartbeatInterval: Duration) {
        self.heartbeatInterval = heartbeatInterval
    }

    public init(heartbeatInterval: TimeInterval) {
        self.heartbeatInterval = .seconds(heartbeatInterval)
    }

    public func shouldPersist(_ health: GatewayTunnelHealth, at now: Duration) -> Bool {
        let transitioned = health != lastPersistedHealth
        let heartbeatDue = lastPersistedAt
            .map { now - $0 >= heartbeatInterval } ?? true
        return transitioned || heartbeatDue
    }

    public mutating func recordPersisted(_ health: GatewayTunnelHealth, at now: Duration) {
        lastPersistedHealth = health
        lastPersistedAt = now
    }

    public func shouldPersist(_ health: GatewayTunnelHealth, at date: Date) -> Bool {
        shouldPersist(health, at: .seconds(date.timeIntervalSinceReferenceDate))
    }

    public mutating func recordPersisted(_ health: GatewayTunnelHealth, at date: Date) {
        recordPersisted(health, at: .seconds(date.timeIntervalSinceReferenceDate))
    }
}
