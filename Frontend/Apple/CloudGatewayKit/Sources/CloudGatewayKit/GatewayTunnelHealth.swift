import Foundation

public enum GatewayTunnelHealth: String, Codable, Equatable, Sendable {
    case unknown
    case passingTraffic
    case notPassingTraffic
}

public enum GatewayTunnelHealthFailureReason: Equatable, Sendable {
    case neverHandshaked
    case staleHandshake
    case oneWayTraffic
}

public enum GatewayTunnelHealthEvidence: Equatable, Sendable {
    case warmingUp
    case healthy
    case failed(GatewayTunnelHealthFailureReason)
}

public struct GatewayTunnelHealthThresholds: Equatable, Sendable {
    public var neverHandshakeGrace: TimeInterval
    public var staleHandshake: TimeInterval
    public var oneWayFlatDuration: TimeInterval
    public var oneWayMinTxGrowth: UInt64

    public init(
        neverHandshakeGrace: TimeInterval = 10,
        staleHandshake: TimeInterval = 180,
        oneWayFlatDuration: TimeInterval = 10,
        oneWayMinTxGrowth: UInt64 = 4096
    ) {
        self.neverHandshakeGrace = neverHandshakeGrace
        self.staleHandshake = staleHandshake
        self.oneWayFlatDuration = oneWayFlatDuration
        self.oneWayMinTxGrowth = oneWayMinTxGrowth
    }

    public static let `default` = GatewayTunnelHealthThresholds()
}

/// Produces raw transport evidence. User-visible outage policy intentionally
/// lives in `GatewayTunnelRecoveryPolicy`.
public struct GatewayTunnelHealthEvaluator {
    private let thresholds: GatewayTunnelHealthThresholds
    private var startedAt: Date
    private var previousSample: GatewayTunnelRuntimeStats?
    private var previousSampleAt: Date?
    private var oneWayCandidate: (startedAt: Date, startingTx: UInt64)?
    // Once a one-way window concludes failed, stay failed while RX remains flat.
    // Without this the evaluator would blink `.healthy` between candidate windows
    // during a continuous blackhole, which reads as recovery and flaps the outage.
    private var oneWayLatched = false

    public init(startedAt: Date, thresholds: GatewayTunnelHealthThresholds = .default) {
        self.thresholds = thresholds
        self.startedAt = startedAt
    }

    public mutating func evaluateEvidence(
        _ stats: GatewayTunnelRuntimeStats,
        at now: Date
    ) -> GatewayTunnelHealthEvidence {
        var sessionReset = false
        if let previousSampleAt, now < previousSampleAt {
            resetSession(at: now)
            sessionReset = true
        }

        if let previousSample,
           stats.rxBytes < previousSample.rxBytes || stats.txBytes < previousSample.txBytes {
            resetSession(at: now)
            sessionReset = true
        }

        if sessionReset {
            previousSample = stats
            previousSampleAt = now
            return .warmingUp
        }

        let prior = previousSample
        defer {
            previousSample = stats
            previousSampleAt = now
        }

        if let prior {
            if stats.rxBytes > prior.rxBytes {
                // Any inbound progress clears both the pending window and the latch.
                oneWayCandidate = nil
                oneWayLatched = false
            } else if stats.rxBytes == prior.rxBytes, stats.txBytes > prior.txBytes,
                      oneWayCandidate == nil {
                oneWayCandidate = (now, prior.txBytes)
            }
        }

        if stats.latestHandshakeEpochSeconds <= 0 {
            return now.timeIntervalSince(startedAt) >= thresholds.neverHandshakeGrace
                ? .failed(.neverHandshaked)
                : .warmingUp
        }

        let handshakeAge = now.timeIntervalSince1970 - Double(stats.latestHandshakeEpochSeconds)
        if handshakeAge > thresholds.staleHandshake {
            return .failed(.staleHandshake)
        }

        if oneWayLatched {
            return .failed(.oneWayTraffic)
        }

        if let candidate = oneWayCandidate,
           now.timeIntervalSince(candidate.startedAt) >= thresholds.oneWayFlatDuration {
            oneWayCandidate = nil
            if stats.txBytes >= candidate.startingTx,
               stats.txBytes - candidate.startingTx >= thresholds.oneWayMinTxGrowth {
                oneWayLatched = true
                return .failed(.oneWayTraffic)
            }
        }

        return .healthy
    }

    /// Starts a new traffic observation window after a binding refresh while
    /// preserving handshake/session age.
    public mutating func resetTrafficEvidence(
        baseline: GatewayTunnelRuntimeStats? = nil,
        at now: Date? = nil
    ) {
        oneWayCandidate = nil
        oneWayLatched = false
        previousSample = baseline
        previousSampleAt = baseline == nil ? nil : now
    }

    public mutating func evaluate(_ stats: GatewayTunnelRuntimeStats, at now: Date) -> GatewayTunnelHealth {
        switch evaluateEvidence(stats, at: now) {
        case .warmingUp: return .unknown
        case .healthy: return .passingTraffic
        case .failed: return .notPassingTraffic
        }
    }

    /// Starts a fresh backend session, including handshake warmup and traffic
    /// baselines. Use when WireGuard's backend is intentionally recreated.
    public mutating func resetSession(at now: Date) {
        startedAt = now
        previousSample = nil
        previousSampleAt = nil
        oneWayCandidate = nil
        oneWayLatched = false
    }
}
