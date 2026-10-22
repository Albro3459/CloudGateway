import CloudGatewayKit
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

@Test @MainActor func capacityPreparationReturnsHealthyRegionsAndUnknownStallsWithinOneDeadline() async throws {
    let probe = CapacityPreparationProbe()
    let regions = try await CloudGatewayMacCapacityPreparation.prepare(
        timeout: .milliseconds(50), maxConcurrentReads: 2,
        loadRegions: { probe.regions }, loadToken: { "test-token" },
        fetchCapacity: { regionId, _ in try await probe.capacity(regionId) }
    )
    #expect(regions.map(\.regionId) == probe.regions.map(\.regionId))
    #expect(regions.first?.capacity == .known(limit: 10, allocated: 1))
    #expect(regions.dropFirst().allSatisfy { $0.capacity == .unknown })
    #expect(probe.maximumConcurrentReads == 2)
    try await capacityWaitUntil { probe.activeReads == 0 }
    #expect(probe.cancelledReads > 0)
}

@Test @MainActor func capacityPreparationDeadlineIncludesStalledTokenRetrieval() async throws {
    let probe = CapacityPreparationProbe()
    var tokenCancelled = false
    let regions = try await CloudGatewayMacCapacityPreparation.prepare(
        timeout: .milliseconds(20), loadRegions: { probe.regions },
        loadToken: {
            defer { tokenCancelled = Task.isCancelled }
            try await Task.sleep(for: .seconds(60))
            return "test-token"
        },
        fetchCapacity: { regionId, _ in try await probe.capacity(regionId) }
    )
    #expect(regions.allSatisfy { $0.capacity == .unknown })
    #expect(probe.maximumConcurrentReads == 0)
    try await capacityWaitUntil { tokenCancelled }
}

@Test @MainActor func capacityPreparationCancellationReleasesAllReadOnlyWorkers() async throws {
    let probe = CapacityPreparationProbe()
    let preparation = Task {
        try await CloudGatewayMacCapacityPreparation.prepare(
            maxConcurrentReads: 2, loadRegions: { probe.regions }, loadToken: { "test-token" },
            fetchCapacity: { regionId, _ in try await probe.capacity(regionId) }
        )
    }
    try await capacityWaitUntil { probe.activeReads == 2 }
    preparation.cancel()
    await #expect(throws: CancellationError.self) { try await preparation.value }
    try await capacityWaitUntil { probe.activeReads == 0 }
    #expect(probe.cancelledReads == 2)
}

@Test @MainActor func capacityPreparationAccessDenialCancelsOtherWorkers() async throws {
    let probe = CapacityPreparationProbe()
    await #expect(throws: CloudGatewayMacInventoryError.accessDenied) {
        try await CloudGatewayMacCapacityPreparation.prepare(
            loadRegions: { probe.regions }, loadToken: { "test-token" },
            fetchCapacity: { regionId, _ in
                if regionId == "region-0" { throw CloudGatewayMacInventoryError.accessDenied }
                return try await probe.capacity(regionId)
            }
        )
    }
    try await capacityWaitUntil { probe.activeReads == 0 }
}

@MainActor
private func capacityWaitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<5000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Capacity preparation did not finish cleanup")
    throw CloudGatewayMacInventoryError.unavailable
}

@MainActor
private final class CapacityPreparationProbe {
    let regions = (0..<8).map {
        CloudGatewayRegion(regionId: "region-\($0)", displayName: "Region \($0)", enabled: true)
    }
    private(set) var activeReads = 0
    private(set) var maximumConcurrentReads = 0
    private(set) var cancelledReads = 0

    func capacity(_ regionId: String) async throws -> CloudGatewayRegionCapacity {
        activeReads += 1
        maximumConcurrentReads = max(maximumConcurrentReads, activeReads)
        defer {
            activeReads -= 1
            if Task.isCancelled { cancelledReads += 1 }
        }
        if regionId == "region-0" { return .known(limit: 10, allocated: 1) }
        try await Task.sleep(for: .seconds(60))
        return .unknown
    }
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
