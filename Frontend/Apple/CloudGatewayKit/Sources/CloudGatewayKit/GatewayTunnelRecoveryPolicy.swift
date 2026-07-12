import Foundation

public enum GatewayTunnelPathAvailability: Equatable, Sendable {
    case unavailable
    case settling
    case satisfied
}

public struct GatewayTunnelRecoveryAction: Equatable, Sendable {
    public let health: GatewayTunnelHealth
    public let requestBindingRefresh: Bool

    public init(health: GatewayTunnelHealth, requestBindingRefresh: Bool = false) {
        self.health = health
        self.requestBindingRefresh = requestBindingRefresh
    }
}

/// Converts raw WireGuard evidence into the stable outward health contract.
/// Feed this type from one serial queue.
public struct GatewayTunnelRecoveryPolicy {
    public struct Thresholds: Equatable, Sendable {
        public var verificationDuration: TimeInterval
        public var runtimeUnavailableDuration: TimeInterval
        public var healthyPollsToRecover: Int

        public init(
            verificationDuration: TimeInterval = 10,
            runtimeUnavailableDuration: TimeInterval = 20,
            healthyPollsToRecover: Int = 2
        ) {
            self.verificationDuration = verificationDuration
            self.runtimeUnavailableDuration = runtimeUnavailableDuration
            self.healthyPollsToRecover = healthyPollsToRecover
        }
    }

    private enum State {
        case observing
        case runtimeUnavailable(since: Date)
        case refreshPending(attempt: Int)
        case awaitingBaseline(attempt: Int, acceptedAt: Date)
        case verifying(attempt: Int, since: Date, baseline: GatewayTunnelRuntimeStats)
        case confirmed
        case probation(confirmed: Bool, healthyPolls: Int)
    }

    private let thresholds: Thresholds
    private var state: State = .observing
    private var routeGeneration: UInt64?
    private var runtimeUnavailableSince: Date?

    public init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    public mutating func update(
        stats: GatewayTunnelRuntimeStats?,
        evidence: GatewayTunnelHealthEvidence?,
        path: GatewayTunnelPathAvailability,
        routeGeneration: UInt64,
        at now: Date
    ) -> GatewayTunnelRecoveryAction {
        let generationChanged = self.routeGeneration != routeGeneration
        self.routeGeneration = routeGeneration

        if generationChanged, !isConfirmed {
            state = .observing
            runtimeUnavailableSince = nil
        }

        guard path == .satisfied else {
            if !isConfirmed {
                state = .observing
                runtimeUnavailableSince = nil
            }
            return GatewayTunnelRecoveryAction(health: isConfirmed ? .notPassingTraffic : .unknown)
        }

        if case let .runtimeUnavailable(since) = state {
            if stats != nil {
                state = .observing
                runtimeUnavailableSince = nil
                return GatewayTunnelRecoveryAction(health: .unknown)
            }
            if now.timeIntervalSince(since) >= thresholds.runtimeUnavailableDuration {
                state = .confirmed
                return GatewayTunnelRecoveryAction(health: .notPassingTraffic)
            }
            return GatewayTunnelRecoveryAction(health: .unknown)
        }

        guard let stats, let evidence else {
            if runtimeUnavailableSince == nil { runtimeUnavailableSince = now }
            if !isConfirmed,
               now.timeIntervalSince(runtimeUnavailableSince ?? now) >= thresholds.runtimeUnavailableDuration {
                state = .confirmed
            }
            return GatewayTunnelRecoveryAction(health: isConfirmed ? .notPassingTraffic : .unknown)
        }
        runtimeUnavailableSince = nil

        switch state {
        case .observing:
            switch evidence {
            case .warmingUp:
                return GatewayTunnelRecoveryAction(health: .unknown)
            case .healthy:
                return GatewayTunnelRecoveryAction(health: .passingTraffic)
            case .failed:
                state = .refreshPending(attempt: 1)
                return GatewayTunnelRecoveryAction(health: .unknown, requestBindingRefresh: true)
            }

        case .runtimeUnavailable:
            return GatewayTunnelRecoveryAction(health: .unknown)

        case .refreshPending:
            return GatewayTunnelRecoveryAction(health: .unknown)

        case let .awaitingBaseline(attempt, acceptedAt):
            // The first post-refresh sample only fixes the verification baseline.
            // Recovery must be proven by later inbound progress, not by a single
            // `.healthy` verdict: right after a traffic-evidence reset a one-way
            // blackhole has no matured candidate yet and reads `.healthy`, which
            // is not proof the tunnel recovered.
            state = .verifying(attempt: attempt, since: acceptedAt, baseline: stats)
            return GatewayTunnelRecoveryAction(health: .unknown)

        case let .verifying(attempt, since, baseline):
            if hasInboundProgress(stats, since: baseline) {
                state = .probation(confirmed: false, healthyPolls: 1)
                return GatewayTunnelRecoveryAction(health: .unknown)
            }
            guard now.timeIntervalSince(since) >= thresholds.verificationDuration,
                  hasFreshFailureActivity(stats, evidence: evidence, since: baseline) else {
                return GatewayTunnelRecoveryAction(health: .unknown)
            }
            if attempt == 1 {
                state = .refreshPending(attempt: 2)
                return GatewayTunnelRecoveryAction(health: .unknown, requestBindingRefresh: true)
            }
            state = .confirmed
            return GatewayTunnelRecoveryAction(health: .notPassingTraffic)

        case .confirmed:
            if evidence == .healthy {
                state = .probation(confirmed: true, healthyPolls: 1)
            }
            return GatewayTunnelRecoveryAction(health: .notPassingTraffic)

        case let .probation(confirmed, healthyPolls):
            guard evidence == .healthy else {
                state = confirmed ? .confirmed : .observing
                return GatewayTunnelRecoveryAction(health: confirmed ? .notPassingTraffic : .unknown)
            }
            let count = healthyPolls + 1
            if count >= thresholds.healthyPollsToRecover {
                state = .observing
                return GatewayTunnelRecoveryAction(health: .passingTraffic)
            }
            state = .probation(confirmed: confirmed, healthyPolls: count)
            return GatewayTunnelRecoveryAction(health: confirmed ? .notPassingTraffic : .unknown)
        }
    }

    public mutating func bindingRefreshCompleted(
        accepted: Bool,
        at now: Date
    ) {
        guard case let .refreshPending(attempt) = state else { return }
        if accepted {
            state = .awaitingBaseline(attempt: attempt, acceptedAt: now)
        } else {
            state = .runtimeUnavailable(since: now)
        }
    }

    public mutating func invalidatePendingBindingRefresh() {
        guard case .refreshPending = state else { return }
        state = .observing
    }

    private var isConfirmed: Bool {
        switch state {
        case .confirmed, .probation(confirmed: true, healthyPolls: _): return true
        default: return false
        }
    }

    private func hasInboundProgress(
        _ stats: GatewayTunnelRuntimeStats,
        since baseline: GatewayTunnelRuntimeStats
    ) -> Bool {
        stats.rxBytes > baseline.rxBytes || stats.latestHandshakeEpochSeconds > baseline.latestHandshakeEpochSeconds
    }

    private func hasFreshFailureActivity(
        _ stats: GatewayTunnelRuntimeStats,
        evidence: GatewayTunnelHealthEvidence,
        since baseline: GatewayTunnelRuntimeStats
    ) -> Bool {
        guard stats.txBytes > baseline.txBytes else { return false }
        switch evidence {
        case .failed: return true
        case .warmingUp, .healthy: return false
        }
    }
}
