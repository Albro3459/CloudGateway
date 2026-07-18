@testable import CloudGatewayAppCore
import CloudGatewayKit
import Foundation

actor AsyncTestGate {
    private var isOpen = false
    private var continuations = [CheckedContinuation<Void, Never>]()

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

final class FakeTunnelHealthReader: CloudGatewayTunnelHealthReading {
    var snapshot: CloudGatewayTunnelHealthSnapshot?
    private(set) var readCount = 0

    init(snapshot: CloudGatewayTunnelHealthSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func currentSnapshot() -> CloudGatewayTunnelHealthSnapshot? {
        readCount += 1
        return snapshot
    }
}

actor ControlledPresentationSleeper: CloudGatewayPresentationSleeping {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var durations = [Duration]()
    private var waiters = [Waiter]()

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        durations.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func recordedDurations() -> [Duration] {
        durations
    }

    func waitingCount() -> Int {
        waiters.count
    }

    func resumeNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// In-memory tunnel manager for view-model tests. Reports "no installed tunnel" by
/// default so `CloudGatewayConfigManager.refreshStatus()` maps it to a nil status.
actor FakeTunnelManager: CloudGatewayTunnelManaging {
    private var status: CloudGatewayTunnelStatus?
    private var statuses = [String: CloudGatewayTunnelStatus]()
    private var knownIdentifiers = Set<String>()
    private var startError: Error?
    private var stopError: Error?
    private var statusReadError: Error?
    private var allStatusesReadDelay: Duration?
    private var stopDelay: Duration?
    private var stopResultStatus: CloudGatewayTunnelStatus = .disconnected
    private var stoppedIdentifiers = [String]()
    private var installGate: AsyncTestGate?
    private var installCallCount = 0

    init(status: CloudGatewayTunnelStatus? = nil) {
        self.status = status
    }

    func installedStatus(for identifier: String) async throws -> CloudGatewayTunnelStatus {
        guard let status = try await installedStatuses(for: [identifier])[identifier] else {
            throw CloudGatewayVPNError.missingInstalledTunnel
        }
        return status
    }

    func installedStatuses(for identifiers: [String]) async throws -> [String: CloudGatewayTunnelStatus] {
        if let statusReadError {
            throw statusReadError
        }
        knownIdentifiers.formUnion(identifiers)
        return identifiers.reduce(into: [String: CloudGatewayTunnelStatus]()) { result, identifier in
            if let status = statuses[identifier] ?? status {
                result[identifier] = status
            }
        }
    }

    func allInstalledStatuses() async throws -> [String: CloudGatewayTunnelStatus] {
        if let allStatusesReadDelay {
            try await ContinuousClock().sleep(for: allStatusesReadDelay)
        }
        if let statusReadError {
            throw statusReadError
        }
        return knownIdentifiers.reduce(into: statuses) { result, identifier in
            if let status {
                result[identifier] = result[identifier] ?? status
            }
        }
    }

    func installTunnel(_ tunnel: CloudGatewayTunnelConfiguration) async throws {
        installCallCount += 1
        if let installGate {
            await installGate.wait()
        }
        statuses[tunnel.identifier] = .disconnected
    }

    func startTunnel(identifier: String) async throws {
        if let startError {
            throw startError
        }
        statuses[identifier] = .connected
    }

    func stopTunnel(identifier: String) async throws {
        if let stopError {
            throw stopError
        }
        stoppedIdentifiers.append(identifier)
        if let stopDelay {
            try await ContinuousClock().sleep(for: stopDelay)
        }
        statuses[identifier] = stopResultStatus
    }

    func removeTunnel(identifier: String) async throws {
        statuses[identifier] = nil
    }

    func setStatus(_ status: CloudGatewayTunnelStatus?, for identifier: String) {
        statuses[identifier] = status
    }

    func setStartError(_ error: Error?) {
        startError = error
    }

    func setStopError(_ error: Error?) {
        stopError = error
    }

    func setStatusReadError(_ error: Error?) {
        statusReadError = error
    }

    func setAllStatusesReadDelay(_ delay: Duration?) {
        allStatusesReadDelay = delay
    }

    func setStopDelay(_ delay: Duration?) {
        stopDelay = delay
    }

    func setStopResultStatus(_ status: CloudGatewayTunnelStatus) {
        stopResultStatus = status
    }

    func stopRequests() -> [String] {
        stoppedIdentifiers
    }

    func setInstallGate(_ gate: AsyncTestGate?) {
        installGate = gate
    }

    func installRequests() -> Int {
        installCallCount
    }
}

/// In-memory config cache for view-model tests.
actor FakeConfigCache: CloudGatewayConfigCaching {
    private var snapshots: [CloudGatewayConfigSnapshot]
    private var loadGate: AsyncTestGate?
    private var loadRequestCount = 0

    init(snapshots: [CloudGatewayConfigSnapshot] = []) {
        self.snapshots = snapshots
    }

    func load() async throws -> [CloudGatewayConfigSnapshot] {
        loadRequestCount += 1
        // Capture the result before waiting on the gate so a paused caller sees
        // the data as of when it called in, not whatever is current when it is
        // later released - mirrors a real cache read racing a concurrent write.
        let result = snapshots
        if let loadGate {
            await loadGate.wait()
        }
        return result
    }

    func setLoadGate(_ gate: AsyncTestGate?) {
        loadGate = gate
    }

    func setSnapshots(_ snapshots: [CloudGatewayConfigSnapshot]) {
        self.snapshots = snapshots
    }

    func loadRequests() -> Int {
        loadRequestCount
    }

    func save(_ snapshot: CloudGatewayConfigSnapshot) async throws {
        snapshots.removeAll { $0.clientId == snapshot.clientId }
        snapshots.append(snapshot)
    }

    func clear(identifier: String) async throws {
        snapshots.removeAll { $0.clientId == identifier }
    }
}

final class FakeConfigSecretStore: CloudGatewayConfigSecretStoring, @unchecked Sendable {
    private var configs = [CloudGatewayConfigSecretReference: CloudGatewayWireGuardConfig]()

    func saveConfig(_ config: CloudGatewayWireGuardConfig, for reference: CloudGatewayConfigSecretReference) throws {
        configs[reference] = config
    }

    func loadConfig(for reference: CloudGatewayConfigSecretReference) throws -> CloudGatewayWireGuardConfig {
        guard let config = configs[reference] else {
            throw CloudGatewayVPNError.keychainReadFailed(-25300)
        }
        return config
    }

    func deleteConfig(for reference: CloudGatewayConfigSecretReference) throws {
        configs[reference] = nil
    }
}
