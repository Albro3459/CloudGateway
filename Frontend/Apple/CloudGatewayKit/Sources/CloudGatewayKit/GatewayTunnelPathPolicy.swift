import Foundation

/// Tracks coarse path changes after the platform-specific fingerprint has
/// filtered out link-quality chatter. Feed this type from one serial queue.
public struct GatewayTunnelPathPolicy: Sendable {
    public private(set) var policyGeneration: UInt64 = 0
    public private(set) var recoveryRouteGeneration: UInt64 = 0

    private var isSatisfied = false
    private var settlingStartedAt: Date?
    private var lastPathChangeAt: Date?

    public init() {}

    public mutating func recordPathChange(isSatisfied: Bool, at now: Date) {
        if self.isSatisfied,
           settlingStartedAt != nil,
           let lastPathChangeAt,
           now.timeIntervalSince(lastPathChangeAt) >= 10 {
            settlingStartedAt = nil
        }

        self.isSatisfied = isSatisfied
        lastPathChangeAt = now
        recoveryRouteGeneration &+= 1

        guard isSatisfied else {
            settlingStartedAt = nil
            policyGeneration &+= 1
            return
        }

        if settlingStartedAt == nil {
            settlingStartedAt = now
        }
        if now.timeIntervalSince(settlingStartedAt ?? now) < 30 {
            policyGeneration &+= 1
        }
    }

    public mutating func availability(at now: Date) -> GatewayTunnelPathAvailability {
        guard isSatisfied, let lastPathChangeAt else {
            return .unavailable
        }
        guard let settlingStartedAt else {
            return .satisfied
        }

        let quietAge = now.timeIntervalSince(lastPathChangeAt)
        if quietAge >= 10 {
            self.settlingStartedAt = nil
            return .satisfied
        }
        if now.timeIntervalSince(settlingStartedAt) >= 30 {
            return .satisfied
        }
        return .settling
    }
}
