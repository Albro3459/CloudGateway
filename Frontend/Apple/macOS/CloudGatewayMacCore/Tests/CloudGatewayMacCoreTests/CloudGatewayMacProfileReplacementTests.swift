import CloudGatewayKit
import CloudGatewayMacIPC
import Testing
@testable import CloudGatewayMacCore

@Test func macProfileReplacementStopsActiveTargetBeforeWritingPreferences() async throws {
    let events = MacReplacementEvents()
    try await CloudGatewayMacProfileReplacement.perform(existing: macReplacementProfile(status: .connected), stop: {
        await events.append("stop confirmed")
    }, replace: {
        await events.append("save")
    })
    #expect(await events.values == ["stop confirmed", "save"])
}

@Test func macProfileReplacementStopTimeoutLeavesPreferencesUnmodified() async {
    let events = MacReplacementEvents()
    await #expect(throws: MacReplacementFailure.self) {
        try await CloudGatewayMacProfileReplacement.perform(existing: macReplacementProfile(status: .disconnecting), stop: {
            throw MacReplacementFailure()
        }, replace: {
            await events.append("save")
        })
    }
    #expect(await events.values.isEmpty)
}

@Test func macProfileReplacementCancellationAfterStopLeavesPreferencesUnmodified() async {
    let events = MacReplacementEvents()
    let gate = MacReplacementGate()
    let task = Task {
        try await CloudGatewayMacProfileReplacement.perform(existing: macReplacementProfile(status: .connecting), stop: {
            await gate.arriveAndWait()
        }, replace: {
            await events.append("save")
        })
    }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await events.values.isEmpty)
}

@Test func macProfileReplacementDoesNotStopDisconnectedTarget() async throws {
    let events = MacReplacementEvents()
    try await CloudGatewayMacProfileReplacement.perform(existing: macReplacementProfile(status: .disconnected), stop: {
        await events.append("stop")
    }, replace: {
        await events.append("save")
    })
    #expect(await events.values == ["save"])
}

private func macReplacementProfile(status: CloudGatewayTunnelStatus) -> CloudGatewayMacInstalledProfile {
    CloudGatewayMacInstalledProfile(
        identifier: "account/region/client",
        reference: try! CloudGatewayMacSecretReference(value: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
        status: status
    )
}

private struct MacReplacementFailure: Error {}

private actor MacReplacementEvents {
    var values: [String] = []
    func append(_ event: String) { values.append(event) }
}

private actor MacReplacementGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        entered = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { waiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}
