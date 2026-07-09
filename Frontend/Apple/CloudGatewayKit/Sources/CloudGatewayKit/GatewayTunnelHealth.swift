import Foundation

/// Whether the tunnel is actually carrying traffic, as judged from WireGuard
/// runtime stats. A full tunnel keeps running even when its peer is deleted or
/// the server is down; this distinguishes "packets are flowing" from "packets
/// are being blackholed."
public enum GatewayTunnelHealth: String, Codable, Equatable, Sendable {
    /// Not enough information yet (e.g. still within the initial handshake grace).
    case unknown
    /// The tunnel handshaked recently and traffic is not one-way dead.
    case passingTraffic
    /// The tunnel is blackholing: never handshaked past the grace window, the
    /// handshake went stale, or traffic is flowing out with nothing coming back.
    case notPassingTraffic
}

public struct GatewayTunnelHealthThresholds: Equatable, Sendable {
    /// How long a freshly started tunnel may go without any handshake before it
    /// is judged dead.
    public var neverHandshakeGrace: TimeInterval
    /// A handshake older than this on an established tunnel means the peer went
    /// dark. Must sit above WireGuard's rekey interval (~120s) so a healthy idle
    /// tunnel is not false-flagged.
    public var staleHandshake: TimeInterval
    /// How long received bytes must stay flat (while bytes are still being sent)
    /// before the tunnel is judged one-way dead.
    public var oneWayFlatDuration: TimeInterval
    /// Minimum sent-byte growth during the flat window, above keepalive noise, to
    /// confirm the tunnel is one-way dead rather than merely idle.
    public var oneWayMinTxGrowth: UInt64

    public init(
        neverHandshakeGrace: TimeInterval = 15,
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

/// Evaluates a stream of tunnel runtime samples into a health verdict. Holds the
/// small amount of state needed to detect a one-way-dead tunnel (received bytes
/// flat while sent bytes climb). Not thread-safe: feed it from a single queue.
public struct GatewayTunnelHealthEvaluator {
    private let thresholds: GatewayTunnelHealthThresholds
    private let startedAt: Date
    private var lastRxBytes: UInt64?
    private var lastRxAdvanceAt: Date
    private var txBytesAtLastRxAdvance: UInt64

    public init(startedAt: Date, thresholds: GatewayTunnelHealthThresholds = .default) {
        self.thresholds = thresholds
        self.startedAt = startedAt
        self.lastRxBytes = nil
        self.lastRxAdvanceAt = startedAt
        self.txBytesAtLastRxAdvance = 0
    }

    public mutating func evaluate(_ stats: GatewayTunnelRuntimeStats, at now: Date) -> GatewayTunnelHealth {
        updateReceiveActivity(stats, at: now)

        if stats.latestHandshakeEpochSeconds <= 0 {
            return now.timeIntervalSince(startedAt) >= thresholds.neverHandshakeGrace
                ? .notPassingTraffic
                : .unknown
        }

        let handshakeAge = now.timeIntervalSince1970 - Double(stats.latestHandshakeEpochSeconds)
        if handshakeAge > thresholds.staleHandshake {
            return .notPassingTraffic
        }

        if isOneWayDead(stats, at: now) {
            return .notPassingTraffic
        }

        return .passingTraffic
    }

    // Reset the flatness baseline whenever received bytes change (traffic is
    // coming back) or the counters reset (tunnel restarted). A stable rx count
    // across polls is what accumulates the flat duration.
    private mutating func updateReceiveActivity(_ stats: GatewayTunnelRuntimeStats, at now: Date) {
        guard let lastRxBytes else {
            self.lastRxBytes = stats.rxBytes
            lastRxAdvanceAt = now
            txBytesAtLastRxAdvance = stats.txBytes
            return
        }
        if stats.rxBytes != lastRxBytes {
            self.lastRxBytes = stats.rxBytes
            lastRxAdvanceAt = now
            txBytesAtLastRxAdvance = stats.txBytes
        }
    }

    private func isOneWayDead(_ stats: GatewayTunnelRuntimeStats, at now: Date) -> Bool {
        guard now.timeIntervalSince(lastRxAdvanceAt) >= thresholds.oneWayFlatDuration else {
            return false
        }
        let txGrowth = stats.txBytes >= txBytesAtLastRxAdvance
            ? stats.txBytes - txBytesAtLastRxAdvance
            : 0
        return txGrowth >= thresholds.oneWayMinTxGrowth
    }
}
