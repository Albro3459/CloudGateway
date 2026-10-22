import Foundation
import Testing
@testable import CloudGatewayMacCore

@Test @MainActor func inventoryReadCompletesOnceFromABackgroundCallbackAndRemovesListener() async throws {
    let probe = InventoryRequestProbe()
    let value: Int = try await CloudGatewayMacInventoryRequest.read { complete in
        let cleanup = probe.start(complete)
        Task.detached {
            complete(.success(42))
            complete(.failure(CloudGatewayMacInventoryError.accessDenied))
        }
        return cleanup
    }
    #expect(value == 42)
    #expect(probe.removals == 1)
}

@Test @MainActor func inventoryReadTimesOutWithoutSDKCompletionAndIgnoresLateReplies() async throws {
    let probe = InventoryRequestProbe()
    await #expect(throws: CloudGatewayMacInventoryError.offline) {
        try await CloudGatewayMacInventoryRequest.read(timeout: .milliseconds(10), start: probe.start)
    }
    #expect(probe.removals == 1)
    probe.complete?(.success(99))
    await Task.yield()
    #expect(probe.removals == 1)
}

@Test @MainActor func inventoryReadCancellationDetachesAStalledListenerImmediately() async throws {
    let probe = InventoryRequestProbe()
    let request = Task { try await CloudGatewayMacInventoryRequest.read(start: probe.start) }
    for _ in 0..<5000 {
        if probe.complete != nil { break }
        await Task.yield()
    }
    #expect(probe.complete != nil)
    request.cancel()
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(probe.removals == 1)
    probe.complete?(.failure(CloudGatewayMacInventoryError.accessDenied))
    await Task.yield()
    #expect(probe.removals == 1)
}

@Test @MainActor func inventoryReadCancelledBeforeStartingDoesNotAttachAListener() async throws {
    let probe = InventoryRequestProbe()
    let request = Task { try await CloudGatewayMacInventoryRequest.read(start: probe.start) }
    request.cancel()
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(probe.complete == nil)
    #expect(probe.removals == 0)
}

@MainActor
private final class InventoryRequestProbe {
    var complete: (@Sendable (Result<Int, Error>) -> Void)?
    var removals = 0

    func start(_ complete: @escaping @Sendable (Result<Int, Error>) -> Void) -> (() -> Void) {
        self.complete = complete
        return { self.removals += 1 }
    }
}
