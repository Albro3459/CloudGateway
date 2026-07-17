import Foundation

public enum CloudGatewayTunnelPathAvailability: Equatable, Sendable {
    case unavailable
    case settling
    case satisfied
}

public enum CloudGatewayTunnelRecoveryRequest: Equatable, Sendable {
    case bindingRefresh
    case backendRestart
}

public struct CloudGatewayTunnelRecoveryAction: Equatable, Sendable {
    public let health: CloudGatewayTunnelHealth
    public let recoveryRequest: CloudGatewayTunnelRecoveryRequest?

    public init(
        health: CloudGatewayTunnelHealth,
        recoveryRequest: CloudGatewayTunnelRecoveryRequest? = nil
    ) {
        self.health = health
        self.recoveryRequest = recoveryRequest
    }
}

/// Converts raw WireGuard evidence into the stable outward health contract.
/// Feed this type from one serial queue.
public struct CloudGatewayTunnelRecoveryPolicy: Sendable {
    public struct Thresholds: Equatable, Sendable {
        public var verificationDuration: Duration
        public var runtimeUnavailableDuration: Duration
        public var healthyPollsToRecover: Int

        public init(
            verificationDuration: Duration,
            runtimeUnavailableDuration: Duration,
            healthyPollsToRecover: Int
        ) {
            self.verificationDuration = verificationDuration
            self.runtimeUnavailableDuration = runtimeUnavailableDuration
            self.healthyPollsToRecover = healthyPollsToRecover
        }

        public init(timing: CloudGatewayTunnelHealthTiming = .production) {
            self.init(
                verificationDuration: timing.recoveryVerificationDuration,
                runtimeUnavailableDuration: timing.runtimeUnavailableDuration,
                healthyPollsToRecover: timing.healthyPollsToRecover
            )
        }

        public init(runtimeUnavailableDuration: TimeInterval) {
            self.init(
                verificationDuration: CloudGatewayTunnelHealthTiming.production
                    .recoveryVerificationDuration,
                runtimeUnavailableDuration: .seconds(runtimeUnavailableDuration),
                healthyPollsToRecover: CloudGatewayTunnelHealthTiming.production
                    .healthyPollsToRecover
            )
        }
    }

    private enum State: Sendable {
        case observing
        case runtimeUnavailable(attempt: Int, since: Duration)
        case recoveryPending(attempt: Int)
        case awaitingBaseline(attempt: Int, acceptedAt: Duration)
        case verifying(attempt: Int, since: Duration, baseline: CloudGatewayTunnelRuntimeStats)
        case confirmed
        case probation(
            confirmed: Bool,
            attempt: Int?,
            healthyPolls: Int,
            failureSince: Duration?,
            failureBaseline: CloudGatewayTunnelRuntimeStats?
        )
    }

    private let thresholds: Thresholds
    private var state: State = .observing
    private var routeGeneration: UInt64?
    private var runtimeUnavailableSince: Duration?
    // Set whenever the policy confirms an outage; cleared only when traffic is
    // proven flowing again. While set it floors any `.unknown` report to
    // `.notPassingTraffic` (see `emit`) so a re-armed recovery ladder can run
    // after a network change without withdrawing or duplicating the outage
    // notification, which is edge-triggered on the health transitions.
    private var confirmedOutageLatched = false

    public init(thresholds: Thresholds = Thresholds(timing: .production)) {
        self.thresholds = thresholds
    }

    public init(timing: CloudGatewayTunnelHealthTiming) {
        thresholds = Thresholds(timing: timing)
    }

    public mutating func update(
        stats: CloudGatewayTunnelRuntimeStats?,
        evidence: CloudGatewayTunnelHealthEvidence?,
        path: CloudGatewayTunnelPathAvailability,
        routeGeneration: UInt64,
        at now: Duration
    ) -> CloudGatewayTunnelRecoveryAction {
        let generationChanged = self.routeGeneration != routeGeneration
        self.routeGeneration = routeGeneration

        if generationChanged {
            // A materially new path re-arms the full recovery ladder even from a
            // confirmed outage: the failure may have been specific to the old
            // path (stale NAT/UDP binding, black-holed socket). The outage latch
            // keeps outward health at `.notPassingTraffic` throughout the retry.
            state = .observing
            runtimeUnavailableSince = nil
        }

        guard path == .satisfied else {
            if !isConfirmed {
                state = .observing
                runtimeUnavailableSince = nil
            }
            return emit(isConfirmed ? .notPassingTraffic : .unknown)
        }

        if case let .runtimeUnavailable(attempt, _) = state {
            if let stats, let evidence {
                if evidence == .healthy || (attempt == 2 && hasInitialInboundProgress(stats)) {
                    state = .probation(
                        confirmed: false,
                        attempt: attempt,
                        healthyPolls: 1,
                        failureSince: now,
                        failureBaseline: stats
                    )
                } else {
                    state = .verifying(attempt: attempt, since: now, baseline: stats)
                }
                runtimeUnavailableSince = nil
                return emit(.unknown)
            }
        }

        guard let stats, let evidence else {
            return handleRuntimeUnavailable(at: now)
        }
        runtimeUnavailableSince = nil

        switch state {
        case .observing:
            switch evidence {
            case .warmingUp:
                return emit(.unknown)
            case .healthy:
                // While an outage is latched, a single healthy poll after a
                // network change is not proof of recovery. Require the same
                // two-poll probation as any other recovery before withdrawing
                // the warning. `confirmed: false` so a failed probation returns
                // to `.observing` and keeps the re-armed ladder available.
                guard confirmedOutageLatched else {
                    return emit(.passingTraffic)
                }
                state = .probation(
                    confirmed: false,
                    attempt: nil,
                    healthyPolls: 1,
                    failureSince: nil,
                    failureBaseline: nil
                )
                return emit(.unknown)
            case .failed:
                state = .recoveryPending(attempt: 1)
                return emit(.unknown, recoveryRequest: .bindingRefresh)
            }

        case .runtimeUnavailable:
            return emit(.unknown)

        case .recoveryPending:
            return emit(.unknown)

        case let .awaitingBaseline(attempt, acceptedAt):
            if attempt == 2, hasInitialInboundProgress(stats) {
                state = .probation(
                    confirmed: false,
                    attempt: attempt,
                    healthyPolls: 1,
                    failureSince: now,
                    failureBaseline: stats
                )
                return emit(.unknown)
            }
            // The first post-attempt sample only fixes the verification baseline.
            // Recovery must be proven by later inbound progress, not by a single
            // `.healthy` verdict: right after a traffic-evidence reset a one-way
            // blackhole has no matured candidate yet and reads `.healthy`, which
            // is not proof the tunnel recovered.
            state = .verifying(attempt: attempt, since: acceptedAt, baseline: stats)
            return emit(.unknown)

        case let .verifying(attempt, since, baseline):
            if hasInboundProgress(stats, since: baseline) {
                state = .probation(
                    confirmed: false,
                    attempt: attempt,
                    healthyPolls: 1,
                    failureSince: now,
                    failureBaseline: stats
                )
                return emit(.unknown)
            }
            guard now - since >= thresholds.verificationDuration,
                  hasFreshFailureActivity(stats, evidence: evidence, since: baseline) else {
                return emit(.unknown)
            }
            if attempt == 1 {
                state = .recoveryPending(attempt: 2)
                return emit(.unknown, recoveryRequest: .backendRestart)
            }
            state = .confirmed
            return emit(.notPassingTraffic)

        case .confirmed:
            if evidence == .healthy {
                state = .probation(
                    confirmed: true,
                    attempt: nil,
                    healthyPolls: 1,
                    failureSince: nil,
                    failureBaseline: nil
                )
            }
            return emit(.notPassingTraffic)

        case let .probation(
            confirmed,
            attempt,
            healthyPolls,
            failureSince,
            failureBaseline
        ):
            guard evidence == .healthy else {
                if confirmed {
                    state = .confirmed
                    return emit(.notPassingTraffic)
                }
                if let attempt, let failureSince, let failureBaseline {
                    state = .verifying(
                        attempt: attempt,
                        since: failureSince,
                        baseline: failureBaseline
                    )
                } else {
                    state = .observing
                }
                return emit(.unknown)
            }
            let count = healthyPolls + 1
            if count >= thresholds.healthyPollsToRecover {
                state = .observing
                return emit(.passingTraffic)
            }
            state = .probation(
                confirmed: confirmed,
                attempt: attempt,
                healthyPolls: count,
                failureSince: failureSince,
                failureBaseline: failureBaseline
            )
            return emit(confirmed ? .notPassingTraffic : .unknown)
        }
    }

    /// Single exit point for every action, so the confirmed-outage latch cannot
    /// be missed at an individual return site. Every `.notPassingTraffic` this
    /// policy emits corresponds to a confirmed or just-confirmed state, so
    /// latching on it (and clearing only on `.passingTraffic`) keeps an outage
    /// sticky: while latched, an `.unknown` report is floored to
    /// `.notPassingTraffic` so a re-armed recovery ladder can run after a
    /// network change without withdrawing or duplicating the edge-triggered
    /// outage notification.
    private mutating func emit(
        _ health: CloudGatewayTunnelHealth,
        recoveryRequest: CloudGatewayTunnelRecoveryRequest? = nil
    ) -> CloudGatewayTunnelRecoveryAction {
        if health == .passingTraffic {
            confirmedOutageLatched = false
        } else if health == .notPassingTraffic {
            confirmedOutageLatched = true
        }
        let reported: CloudGatewayTunnelHealth =
            confirmedOutageLatched && health == .unknown ? .notPassingTraffic : health
        return CloudGatewayTunnelRecoveryAction(health: reported, recoveryRequest: recoveryRequest)
    }

    public mutating func recoveryAttemptCompleted(
        accepted: Bool,
        at now: Duration
    ) {
        guard case let .recoveryPending(attempt) = state else { return }
        runtimeUnavailableSince = nil
        if accepted {
            state = .awaitingBaseline(attempt: attempt, acceptedAt: now)
        } else {
            state = .runtimeUnavailable(attempt: attempt, since: now)
        }
    }

    public mutating func invalidatePendingRecoveryAttempt() {
        guard case .recoveryPending = state else { return }
        state = .observing
    }

    /// Confirms an outage when the local WireGuard runtime reader itself has
    /// exceeded its deadline. Adapter recovery cannot be requested from this
    /// condition because it shares the stalled serial queue. Keeping the normal
    /// confirmed state preserves the two-poll recovery probation if the read
    /// eventually completes.
    public mutating func runtimeReadTimedOut(
        routeGeneration: UInt64
    ) -> CloudGatewayTunnelRecoveryAction {
        self.routeGeneration = routeGeneration
        runtimeUnavailableSince = nil
        state = .confirmed
        return emit(.notPassingTraffic)
    }

    public mutating func recoveryAttemptTimedOut(
        routeGeneration: UInt64
    ) -> CloudGatewayTunnelRecoveryAction {
        self.routeGeneration = routeGeneration
        runtimeUnavailableSince = nil
        state = .confirmed
        return emit(.notPassingTraffic)
    }

    private mutating func handleRuntimeUnavailable(
        at now: Duration
    ) -> CloudGatewayTunnelRecoveryAction {
        if isConfirmed {
            return emit(.notPassingTraffic)
        }
        if case .recoveryPending = state {
            return emit(.unknown)
        }

        let unavailableSince: Duration
        if case let .runtimeUnavailable(_, since) = state {
            unavailableSince = since
        } else if let runtimeUnavailableSince {
            unavailableSince = runtimeUnavailableSince
        } else {
            runtimeUnavailableSince = now
            return emit(.unknown)
        }

        guard now - unavailableSince >= thresholds.runtimeUnavailableDuration else {
            return emit(.unknown)
        }
        runtimeUnavailableSince = nil

        switch currentAttempt {
        case nil:
            state = .recoveryPending(attempt: 1)
            return emit(.unknown, recoveryRequest: .bindingRefresh)
        case 1:
            state = .recoveryPending(attempt: 2)
            return emit(.unknown, recoveryRequest: .backendRestart)
        default:
            state = .confirmed
            return emit(.notPassingTraffic)
        }
    }

    public mutating func update(
        stats: CloudGatewayTunnelRuntimeStats?,
        evidence: CloudGatewayTunnelHealthEvidence?,
        path: CloudGatewayTunnelPathAvailability,
        routeGeneration: UInt64,
        at now: Date
    ) -> CloudGatewayTunnelRecoveryAction {
        update(
            stats: stats,
            evidence: evidence,
            path: path,
            routeGeneration: routeGeneration,
            at: .seconds(now.timeIntervalSinceReferenceDate)
        )
    }

    public mutating func recoveryAttemptCompleted(accepted: Bool, at now: Date) {
        recoveryAttemptCompleted(
            accepted: accepted,
            at: .seconds(now.timeIntervalSinceReferenceDate)
        )
    }

    private var currentAttempt: Int? {
        switch state {
        case let .runtimeUnavailable(attempt, _),
             let .recoveryPending(attempt),
             let .awaitingBaseline(attempt, _),
             let .verifying(attempt, _, _):
            return attempt
        case let .probation(false, attempt, _, _, _):
            return attempt
        case .observing, .confirmed, .probation(true, _, _, _, _):
            return nil
        }
    }

    private var isConfirmed: Bool {
        switch state {
        case .confirmed,
             .probation(
                confirmed: true,
                attempt: _,
                healthyPolls: _,
                failureSince: _,
                failureBaseline: _
             ):
            return true
        default: return false
        }
    }

    private func hasInboundProgress(
        _ stats: CloudGatewayTunnelRuntimeStats,
        since baseline: CloudGatewayTunnelRuntimeStats
    ) -> Bool {
        stats.rxBytes > baseline.rxBytes || stats.latestHandshakeEpochSeconds > baseline.latestHandshakeEpochSeconds
    }

    private func hasInitialInboundProgress(_ stats: CloudGatewayTunnelRuntimeStats) -> Bool {
        stats.rxBytes > 0 || stats.latestHandshakeEpochSeconds > 0
    }

    private func hasFreshFailureActivity(
        _ stats: CloudGatewayTunnelRuntimeStats,
        evidence: CloudGatewayTunnelHealthEvidence,
        since baseline: CloudGatewayTunnelRuntimeStats
    ) -> Bool {
        guard stats.txBytes > baseline.txBytes else { return false }
        switch evidence {
        case .failed: return true
        case .warmingUp, .healthy: return false
        }
    }
}
