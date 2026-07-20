import Foundation

/// Per-tunnel traffic counters parsed from WireGuard's UAPI `get` output
/// (the string returned by `WireGuardAdapter.getRuntimeConfiguration`).
///
/// Only the fields needed to judge whether the tunnel is passing traffic are
/// kept. Values are aggregated across peers: the newest handshake and the summed
/// byte counters. No key material or endpoints are retained.
public struct CloudGatewayTunnelRuntimeStats: Equatable, Sendable {
    /// Unix time (seconds) of the most recent successful handshake across peers.
    /// `0` means no peer has ever handshaked.
    public let latestHandshakeEpochSeconds: Int
    public let rxBytes: UInt64
    public let txBytes: UInt64

    public init(latestHandshakeEpochSeconds: Int, rxBytes: UInt64, txBytes: UInt64) {
        self.latestHandshakeEpochSeconds = latestHandshakeEpochSeconds
        self.rxBytes = rxBytes
        self.txBytes = txBytes
    }

    /// Parses a UAPI `get` configuration string. Returns `nil` when the string
    /// describes no peer (e.g. an interface-only config), so callers know there
    /// is nothing to evaluate.
    public static func parse(_ uapiConfiguration: String) -> CloudGatewayTunnelRuntimeStats? {
        var sawPeer = false
        var latestHandshake = 0
        var rxBytes: UInt64 = 0
        var txBytes: UInt64 = 0

        for line in uapiConfiguration.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[line.startIndex..<separator])
            let value = line[line.index(after: separator)...]
            switch key {
            case "public_key":
                sawPeer = true
            case "last_handshake_time_sec":
                if let seconds = Int(value) {
                    latestHandshake = max(latestHandshake, seconds)
                }
            case "rx_bytes":
                if let bytes = UInt64(value) {
                    rxBytes &+= bytes
                }
            case "tx_bytes":
                if let bytes = UInt64(value) {
                    txBytes &+= bytes
                }
            default:
                break
            }
        }

        guard sawPeer else {
            return nil
        }
        return CloudGatewayTunnelRuntimeStats(
            latestHandshakeEpochSeconds: latestHandshake,
            rxBytes: rxBytes,
            txBytes: txBytes
        )
    }
}
