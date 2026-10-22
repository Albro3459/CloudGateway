import CloudGatewayKit
import Foundation

@MainActor
public enum CloudGatewayMacInventoryRequest {
    public static func read<Value: Sendable>(
        timeout: Duration = .seconds(10),
        onTimeout: @escaping @MainActor () -> Result<Value, Error> = {
            .failure(CloudGatewayMacInventoryError.offline)
        },
        start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> (() -> Void)
    ) async throws -> Value {
        let pending = PendingInventoryRequest<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending.continuation = continuation
                pending.cleanup = start { result in
                    Task { @MainActor in pending.finish(result) }
                }
                pending.timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                        pending.finish(onTimeout())
                    } catch {}
                }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(.failure(CancellationError())) }
        }
    }

    public static func perform<Value: Sendable>(
        timeout: Duration = .seconds(10),
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try await read(timeout: timeout) { complete in
            let task = Task {
                do { complete(.success(try await operation())) }
                catch { complete(.failure(error)) }
            }
            return { task.cancel() }
        }
    }
}

@MainActor
public enum CloudGatewayMacCapacityPreparation {
    public static func prepare(
        timeout: Duration = .seconds(20),
        maxConcurrentReads: Int = 4,
        loadRegions: @escaping @MainActor @Sendable () async throws -> [CloudGatewayRegion],
        loadToken: @escaping @MainActor @Sendable () async throws -> String,
        fetchCapacity: @escaping @MainActor @Sendable (String, String) async throws -> CloudGatewayRegionCapacity
    ) async throws -> [CloudGatewayRegion] {
        let progress = CapacityPreparationProgress()
        return try await CloudGatewayMacInventoryRequest.read(timeout: timeout, onTimeout: {
            progress.regions.map { .success($0) } ?? .failure(CloudGatewayMacInventoryError.offline)
        }) { complete in
            let task = Task {
                do {
                    let regions = try await CloudGatewayMacInventoryRequest.perform(operation: loadRegions)
                    progress.regions = regions.map { region in
                        CloudGatewayRegion(regionId: region.regionId, displayName: region.displayName,
                            enabled: region.enabled, displayOrder: region.displayOrder, capacity: .unknown)
                    }
                    guard !regions.isEmpty else { complete(.success([])); return }
                    let token: String
                    do { token = try await CloudGatewayMacInventoryRequest.perform(operation: loadToken) }
                    catch CloudGatewayMacInventoryError.offline {
                        try Task.checkCancellation()
                        complete(.success(progress.regions ?? []))
                        return
                    }
                    try await withThrowingTaskGroup(of: (Int, CloudGatewayRegionCapacity).self) { group in
                        var nextIndex = 0
                        func enqueue(_ index: Int) {
                            let regionId = regions[index].regionId
                            group.addTask {
                                do {
                                    let capacity = try await CloudGatewayMacInventoryRequest.perform {
                                        try await fetchCapacity(regionId, token)
                                    }
                                    return (index, capacity)
                                } catch CloudGatewayMacInventoryError.accessDenied {
                                    throw CloudGatewayMacInventoryError.accessDenied
                                } catch {
                                    try Task.checkCancellation()
                                    return (index, .unknown)
                                }
                            }
                        }
                        for index in 0..<min(max(1, maxConcurrentReads), regions.count) {
                            enqueue(index)
                            nextIndex += 1
                        }
                        while let (index, capacity) = try await group.next() {
                            try Task.checkCancellation()
                            let region = regions[index]
                            progress.regions?[index] = CloudGatewayRegion(
                                regionId: region.regionId, displayName: region.displayName,
                                enabled: region.enabled, displayOrder: region.displayOrder, capacity: capacity
                            )
                            if nextIndex < regions.count { enqueue(nextIndex); nextIndex += 1 }
                        }
                    }
                    try Task.checkCancellation()
                    complete(.success(progress.regions ?? []))
                } catch { complete(.failure(error)) }
            }
            return { task.cancel() }
        }
    }
}

@MainActor
private final class CapacityPreparationProgress {
    var regions: [CloudGatewayRegion]?
}

@MainActor
private final class PendingInventoryRequest<Value: Sendable> {
    var continuation: CheckedContinuation<Value, Error>?
    var cleanup: (() -> Void)?
    var timeoutTask: Task<Void, Never>?

    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        cleanup?()
        cleanup = nil
        continuation.resume(with: result)
    }
}
