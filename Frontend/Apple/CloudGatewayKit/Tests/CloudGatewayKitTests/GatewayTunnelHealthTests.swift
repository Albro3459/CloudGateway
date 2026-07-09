import Foundation
import Testing
@testable import CloudGatewayKit

// MARK: - Runtime stats parsing

@Test func parsesSinglePeerRuntimeStats() {
    let uapi = """
    private_key=aa
    listen_port=51820
    public_key=bb
    endpoint=1.2.3.4:51820
    last_handshake_time_sec=1700000000
    last_handshake_time_nsec=0
    tx_bytes=1500
    rx_bytes=2500
    persistent_keepalive_interval=25
    allowed_ip=0.0.0.0/0
    errno=0
    """
    let stats = GatewayTunnelRuntimeStats.parse(uapi)
    #expect(stats == GatewayTunnelRuntimeStats(latestHandshakeEpochSeconds: 1700000000, rxBytes: 2500, txBytes: 1500))
}

@Test func aggregatesMultiplePeers() {
    let uapi = """
    private_key=aa
    public_key=bb
    last_handshake_time_sec=1700000000
    tx_bytes=100
    rx_bytes=200
    public_key=cc
    last_handshake_time_sec=1700000500
    tx_bytes=50
    rx_bytes=25
    """
    let stats = GatewayTunnelRuntimeStats.parse(uapi)
    // Newest handshake, summed counters.
    #expect(stats == GatewayTunnelRuntimeStats(latestHandshakeEpochSeconds: 1700000500, rxBytes: 225, txBytes: 150))
}

@Test func neverHandshakedParsesAsZero() {
    let uapi = """
    private_key=aa
    public_key=bb
    last_handshake_time_sec=0
    tx_bytes=0
    rx_bytes=0
    """
    let stats = GatewayTunnelRuntimeStats.parse(uapi)
    #expect(stats?.latestHandshakeEpochSeconds == 0)
    #expect(stats?.rxBytes == 0)
}

@Test func interfaceOnlyConfigReturnsNil() {
    let uapi = """
    private_key=aa
    listen_port=51820
    errno=0
    """
    #expect(GatewayTunnelRuntimeStats.parse(uapi) == nil)
}

@Test func parserIgnoresMalformedLines() {
    let uapi = """
    public_key=bb
    garbage-without-separator
    last_handshake_time_sec=notanumber
    rx_bytes=10
    tx_bytes=
    """
    let stats = GatewayTunnelRuntimeStats.parse(uapi)
    #expect(stats == GatewayTunnelRuntimeStats(latestHandshakeEpochSeconds: 0, rxBytes: 10, txBytes: 0))
}

// MARK: - Health evaluation

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func stats(handshakeSecondsAgo: Double?, rx: UInt64, tx: UInt64, relativeTo reference: Date = now) -> GatewayTunnelRuntimeStats {
    let epoch: Int
    if let handshakeSecondsAgo {
        epoch = Int(reference.timeIntervalSince1970 - handshakeSecondsAgo)
    } else {
        epoch = 0
    }
    return GatewayTunnelRuntimeStats(latestHandshakeEpochSeconds: epoch, rxBytes: rx, txBytes: tx)
}

@Test func neverHandshakedIsUnknownWithinGraceThenDead() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    #expect(evaluator.evaluate(stats(handshakeSecondsAgo: nil, rx: 0, tx: 0), at: now.addingTimeInterval(10)) == .unknown)
    #expect(evaluator.evaluate(stats(handshakeSecondsAgo: nil, rx: 0, tx: 0), at: now.addingTimeInterval(16)) == .notPassingTraffic)
}

@Test func freshHandshakeWithReceiveActivityIsHealthy() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    let sample = stats(handshakeSecondsAgo: 5, rx: 1000, tx: 1000, relativeTo: now.addingTimeInterval(1))
    #expect(evaluator.evaluate(sample, at: now.addingTimeInterval(1)) == .passingTraffic)
}

@Test func staleHandshakeIsDead() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    let sample = stats(handshakeSecondsAgo: 200, rx: 1000, tx: 1000, relativeTo: now.addingTimeInterval(5))
    #expect(evaluator.evaluate(sample, at: now.addingTimeInterval(5)) == .notPassingTraffic)
}

@Test func oneWayDeadWhenReceiveFlatAndSendGrows() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    _ = evaluator.evaluate(stats(handshakeSecondsAgo: 5, rx: 1000, tx: 1000), at: now)
    // 11s later: rx unchanged, tx grew 5000 (> 4096) -> one-way dead.
    let sample = stats(handshakeSecondsAgo: 16, rx: 1000, tx: 6000, relativeTo: now.addingTimeInterval(11))
    #expect(evaluator.evaluate(sample, at: now.addingTimeInterval(11)) == .notPassingTraffic)
}

@Test func idleTunnelIsNotFlaggedOneWayDead() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    _ = evaluator.evaluate(stats(handshakeSecondsAgo: 5, rx: 1000, tx: 1000), at: now)
    // rx flat but only tiny tx growth (keepalive noise, < 4096) -> still healthy.
    let sample = stats(handshakeSecondsAgo: 16, rx: 1000, tx: 1100, relativeTo: now.addingTimeInterval(11))
    #expect(evaluator.evaluate(sample, at: now.addingTimeInterval(11)) == .passingTraffic)
}

@Test func resumedReceiveResetsFlatnessClock() {
    var evaluator = GatewayTunnelHealthEvaluator(startedAt: now)
    _ = evaluator.evaluate(stats(handshakeSecondsAgo: 5, rx: 1000, tx: 1000), at: now)
    // rx advances at +6s, resetting the flat baseline.
    _ = evaluator.evaluate(stats(handshakeSecondsAgo: 11, rx: 1500, tx: 6000, relativeTo: now.addingTimeInterval(6)), at: now.addingTimeInterval(6))
    // At +11s only 5s of flatness since the advance -> still healthy despite big tx growth.
    let sample = stats(handshakeSecondsAgo: 16, rx: 1500, tx: 11000, relativeTo: now.addingTimeInterval(11))
    #expect(evaluator.evaluate(sample, at: now.addingTimeInterval(11)) == .passingTraffic)
}

// MARK: - Health store

@Test func healthStoreRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = GatewayTunnelHealthStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(try store.read() == nil)

    let snapshot = GatewayTunnelHealthSnapshot(
        tunnelIdentifier: "client-1",
        health: .notPassingTraffic,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try store.write(snapshot)
    #expect(try store.read() == snapshot)

    try store.clear()
    #expect(try store.read() == nil)
}

@Test func healthSnapshotExpiresAfterExtensionStopsUpdatingIt() {
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = GatewayTunnelHealthSnapshot(
        tunnelIdentifier: "client-1",
        health: .notPassingTraffic,
        updatedAt: updatedAt
    )

    #expect(snapshot.isFresh(at: updatedAt.addingTimeInterval(30)))
    #expect(!snapshot.isFresh(at: updatedAt.addingTimeInterval(31)))
}
