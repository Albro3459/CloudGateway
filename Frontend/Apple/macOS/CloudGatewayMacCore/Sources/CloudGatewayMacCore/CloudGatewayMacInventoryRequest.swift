import Foundation

@MainActor
public enum CloudGatewayMacInventoryRequest {
    public static func read<Value: Sendable>(
        timeout: Duration = .seconds(10),
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
                        pending.finish(.failure(CloudGatewayMacInventoryError.offline))
                    } catch {}
                }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(.failure(CancellationError())) }
        }
    }
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
