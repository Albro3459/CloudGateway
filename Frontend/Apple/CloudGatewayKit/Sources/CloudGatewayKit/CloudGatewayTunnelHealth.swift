import Foundation

public enum CloudGatewayTunnelHealth: String, Codable, Equatable, Sendable {
    case unknown
    case passingTraffic
    case notPassingTraffic
}

public enum CloudGatewayTunnelHealthFailureReason: Equatable, Sendable {
    case neverHandshaked
    case staleHandshake
    case oneWayTraffic
}

public enum CloudGatewayTunnelHealthEvidence: Equatable, Sendable {
    case warmingUp
    case healthy
    case failed(CloudGatewayTunnelHealthFailureReason)
}

public struct CloudGatewayTunnelHealthThresholds: Equatable, Sendable {
    public var neverHandshakeGrace: Duration
    public var staleHandshake: Duration
    public var oneWayFlatDuration: Duration
    public var oneWayMinTxGrowth: UInt64

    public init(
        neverHandshakeGrace: Duration,
        staleHandshake: Duration,
        oneWayFlatDuration: Duration,
        oneWayMinTxGrowth: UInt64 = 4096
    ) {
        self.neverHandshakeGrace = neverHandshakeGrace
        self.staleHandshake = staleHandshake
        self.oneWayFlatDuration = oneWayFlatDuration
        self.oneWayMinTxGrowth = oneWayMinTxGrowth
    }

    public init(
        timing: CloudGatewayTunnelHealthTiming = .production,
        oneWayMinTxGrowth: UInt64 = 4096
    ) {
        self.init(
            neverHandshakeGrace: timing.neverHandshakeGrace,
            staleHandshake: timing.staleHandshake,
            oneWayFlatDuration: timing.oneWayFlatDuration,
            oneWayMinTxGrowth: oneWayMinTxGrowth
        )
    }

    public static let `default` = CloudGatewayTunnelHealthThresholds(timing: .production)
}

/// Produces raw transport evidence. User-visible outage policy intentionally
/// lives in `CloudGatewayTunnelRecoveryPolicy`.
public struct CloudGatewayTunnelHealthEvaluator: Sendable {
    private let thresholds: CloudGatewayTunnelHealthThresholds
    private var startedAt: Duration
    private var previousSample: CloudGatewayTunnelRuntimeStats?
    private var previousSampleAt: Duration?
    private var oneWayCandidate: (startedAt: Duration, startingTx: UInt64)?
    // Once a one-way window concludes failed, stay failed while RX remains flat.
    // Without this the evaluator would blink `.healthy` between candidate windows
    // during a continuous blackhole, which reads as recovery and flaps the outage.
    private var oneWayLatched = false

    public init(startedAt: Date, thresholds: CloudGatewayTunnelHealthThresholds = .default) {
        self.thresholds = thresholds
        self.startedAt = .seconds(startedAt.timeIntervalSinceReferenceDate)
    }

    public init(
        startedAt moment: CloudGatewayTunnelHealthMoment,
        timing: CloudGatewayTunnelHealthTiming = .production,
        oneWayMinTxGrowth: UInt64 = 4096
    ) {
        thresholds = CloudGatewayTunnelHealthThresholds(
            timing: timing,
            oneWayMinTxGrowth: oneWayMinTxGrowth
        )
        startedAt = moment.monotonic
    }

    public mutating func evaluateEvidence(
        _ stats: CloudGatewayTunnelRuntimeStats,
        at moment: CloudGatewayTunnelHealthMoment
    ) -> CloudGatewayTunnelHealthEvidence {
        var sessionReset = false
        if let previousSampleAt, moment.monotonic < previousSampleAt {
            resetSession(at: moment)
            sessionReset = true
        }

        if let previousSample,
           stats.rxBytes < previousSample.rxBytes || stats.txBytes < previousSample.txBytes {
            resetSession(at: moment)
            sessionReset = true
        }

        if sessionReset {
            previousSample = stats
            previousSampleAt = moment.monotonic
            return .warmingUp
        }

        let prior = previousSample
        defer {
            previousSample = stats
            previousSampleAt = moment.monotonic
        }

        if let prior {
            if stats.rxBytes > prior.rxBytes {
                // Any inbound progress clears both the pending window and the latch.
                oneWayCandidate = nil
                oneWayLatched = false
            } else if stats.rxBytes == prior.rxBytes, stats.txBytes > prior.txBytes,
                      oneWayCandidate == nil {
                oneWayCandidate = (moment.monotonic, prior.txBytes)
            }
        }

        if stats.latestHandshakeEpochSeconds <= 0 {
            return moment.monotonic - startedAt >= thresholds.neverHandshakeGrace
                ? .failed(.neverHandshaked)
                : .warmingUp
        }

        let handshakeAge = moment.wall.timeIntervalSince1970
            - Double(stats.latestHandshakeEpochSeconds)
        if handshakeAge > thresholds.staleHandshake.gatewayTimeInterval {
            return .failed(.staleHandshake)
        }

        if oneWayLatched {
            return .failed(.oneWayTraffic)
        }

        if let candidate = oneWayCandidate,
           moment.monotonic - candidate.startedAt >= thresholds.oneWayFlatDuration {
            oneWayCandidate = nil
            if stats.txBytes >= candidate.startingTx,
               stats.txBytes - candidate.startingTx >= thresholds.oneWayMinTxGrowth {
                oneWayLatched = true
                return .failed(.oneWayTraffic)
            }
        }

        return .healthy
    }

    public mutating func evaluateEvidence(
        _ stats: CloudGatewayTunnelRuntimeStats,
        at now: Date
    ) -> CloudGatewayTunnelHealthEvidence {
        evaluateEvidence(
            stats,
            at: CloudGatewayTunnelHealthMoment(
                monotonic: .seconds(now.timeIntervalSinceReferenceDate),
                wall: now
            )
        )
    }

    /// Starts a new traffic observation window after a binding refresh while
    /// preserving handshake/session age.
    public mutating func resetTrafficEvidence(
        baseline: CloudGatewayTunnelRuntimeStats? = nil,
        at now: Date? = nil
    ) {
        oneWayCandidate = nil
        oneWayLatched = false
        previousSample = baseline
        previousSampleAt = baseline == nil ? nil : now
            .map { .seconds($0.timeIntervalSinceReferenceDate) }
    }

    public mutating func resetTrafficEvidence(
        baseline: CloudGatewayTunnelRuntimeStats? = nil,
        at moment: CloudGatewayTunnelHealthMoment
    ) {
        oneWayCandidate = nil
        oneWayLatched = false
        previousSample = baseline
        previousSampleAt = baseline == nil ? nil : moment.monotonic
    }

    public mutating func evaluate(_ stats: CloudGatewayTunnelRuntimeStats, at now: Date) -> CloudGatewayTunnelHealth {
        switch evaluateEvidence(stats, at: now) {
        case .warmingUp: return .unknown
        case .healthy: return .passingTraffic
        case .failed: return .notPassingTraffic
        }
    }

    /// Starts a fresh backend session, including handshake warmup and traffic
    /// baselines. Use when WireGuard's backend is intentionally recreated.
    public mutating func resetSession(at now: Date) {
        startedAt = .seconds(now.timeIntervalSinceReferenceDate)
        previousSample = nil
        previousSampleAt = nil
        oneWayCandidate = nil
        oneWayLatched = false
    }

    public mutating func resetSession(at moment: CloudGatewayTunnelHealthMoment) {
        startedAt = moment.monotonic
        previousSample = nil
        previousSampleAt = nil
        oneWayCandidate = nil
        oneWayLatched = false
    }
}
