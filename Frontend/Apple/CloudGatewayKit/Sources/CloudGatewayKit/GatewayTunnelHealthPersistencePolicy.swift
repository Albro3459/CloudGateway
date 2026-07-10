import Foundation

public struct GatewayTunnelHealthPersistencePolicy: Equatable, Sendable {
    public let heartbeatInterval: TimeInterval
    public private(set) var lastPersistedHealth: GatewayTunnelHealth?
    public private(set) var lastPersistedAt: Date?

    public init(heartbeatInterval: TimeInterval = 15) {
        self.heartbeatInterval = heartbeatInterval
    }

    public func shouldPersist(_ health: GatewayTunnelHealth, at date: Date) -> Bool {
        let transitioned = health != lastPersistedHealth
        let heartbeatDue = lastPersistedAt
            .map { date.timeIntervalSince($0) >= heartbeatInterval } ?? true
        return transitioned || heartbeatDue
    }

    public mutating func recordPersisted(_ health: GatewayTunnelHealth, at date: Date) {
        lastPersistedHealth = health
        lastPersistedAt = date
    }
}
