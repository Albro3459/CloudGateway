import Foundation

/// Tracks coarse path changes after the platform-specific fingerprint has
/// filtered out link-quality chatter. Feed this type from one serial queue.
public struct CloudGatewayTunnelPathPolicy: Sendable {
    public private(set) var policyGeneration: UInt64 = 0
    public private(set) var recoveryRouteGeneration: UInt64 = 0

    private let quietPeriod: Duration
    private let settlingCap: Duration
    private var isSatisfied = false
    private var settlingStartedAt: Duration?
    private var lastPathChangeAt: Duration?
    private var settlingCapReached = false

    public init(timing: CloudGatewayTunnelHealthTiming = .production) {
        quietPeriod = timing.pathQuietPeriod
        settlingCap = timing.pathSettlingCap
    }

    public mutating func recordPathChange(isSatisfied: Bool, at now: Duration) {
        if self.isSatisfied,
           settlingStartedAt != nil,
           let lastPathChangeAt,
           now - lastPathChangeAt >= quietPeriod {
            settlingStartedAt = nil
            settlingCapReached = false
        }

        self.isSatisfied = isSatisfied
        lastPathChangeAt = now
        recoveryRouteGeneration &+= 1

        guard isSatisfied else {
            settlingStartedAt = nil
            settlingCapReached = false
            policyGeneration &+= 1
            return
        }

        if settlingStartedAt == nil {
            settlingStartedAt = now
            settlingCapReached = false
        }
        if now - (settlingStartedAt ?? now) < settlingCap {
            policyGeneration &+= 1
        }
    }

    public mutating func availability(at now: Duration) -> CloudGatewayTunnelPathAvailability {
        guard isSatisfied, let lastPathChangeAt else {
            return .unavailable
        }
        guard let settlingStartedAt else {
            return .satisfied
        }

        let quietAge = now - lastPathChangeAt
        if quietAge >= quietPeriod {
            self.settlingStartedAt = nil
            return .satisfied
        }
        if now - settlingStartedAt >= settlingCap {
            settlingCapReached = true
            return .satisfied
        }
        return .settling
    }

    var nextAvailabilityDeadline: Duration? {
        guard isSatisfied,
              !settlingCapReached,
              let settlingStartedAt,
              let lastPathChangeAt else {
            return nil
        }
        return min(lastPathChangeAt + quietPeriod, settlingStartedAt + settlingCap)
    }
}
