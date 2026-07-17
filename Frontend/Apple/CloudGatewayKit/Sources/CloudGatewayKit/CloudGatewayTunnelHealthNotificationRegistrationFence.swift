import Foundation

public enum CloudGatewayTunnelHealthNotificationAuthorizationResult: Sendable {
    case allowed
    case terminalFailure
    case retryableFailure
}

/// Orders a stable notification request against replacement and withdrawal.
public final class CloudGatewayTunnelHealthNotificationRegistrationFence: @unchecked Sendable {
    public struct Epoch: Equatable, Sendable {
        fileprivate let revision: UInt64
    }

    public enum Disposition: Equatable, Sendable {
        case current
        case replaced
        case invalidated
    }

    private let lock = NSRecursiveLock()
    private var revision: UInt64 = 0
    private var current: Epoch?
    private var acceptsRegistrations = true

    public init() {}

    public func register(
        authorization: @escaping @Sendable (
            @escaping @Sendable (CloudGatewayTunnelHealthNotificationAuthorizationResult) -> Void
        ) -> Void,
        add: @escaping @Sendable (
            @escaping @Sendable (CloudGatewayTunnelNotificationResult) -> Void
        ) -> Void,
        remove: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable (CloudGatewayTunnelNotificationResult) async -> Void
    ) {
        let epoch = begin()
        let delivery = CloudGatewayTunnelHealthNotificationResultDelivery(completion)
        authorization { [self] result in
            guard disposition(for: epoch) == .current else {
                delivery.deliver(staleResult(for: epoch))
                return
            }
            switch result {
            case .allowed:
                let submitted = performIfCurrent(epoch) {
                    add { [self] result in
                        delivery.deliver(resolveAddCompletion(
                            result,
                            for: epoch,
                            remove: remove
                        ))
                    }
                }
                if !submitted {
                    delivery.deliver(staleResult(for: epoch))
                }
            case .terminalFailure:
                delivery.deliver(
                    disposition(for: epoch) == .current
                        ? .terminalFailure
                        : staleResult(for: epoch)
                )
            case .retryableFailure:
                delivery.deliver(
                    disposition(for: epoch) == .current
                        ? .retryableFailure
                        : staleResult(for: epoch)
                )
            }
        }
    }

    public func withdraw(_ removal: () -> Void) {
        lock.lock()
        revision &+= 1
        current = nil
        removal()
        lock.unlock()
    }

    public func begin() -> Epoch {
        lock.lock()
        revision &+= 1
        let epoch = Epoch(revision: revision)
        current = acceptsRegistrations ? epoch : nil
        lock.unlock()
        return epoch
    }

    public func resume() {
        lock.lock()
        revision &+= 1
        current = nil
        acceptsRegistrations = true
        lock.unlock()
    }

    public func suspend() {
        lock.lock()
        revision &+= 1
        current = nil
        acceptsRegistrations = false
        lock.unlock()
    }

    public func invalidate() {
        lock.lock()
        revision &+= 1
        current = nil
        lock.unlock()
    }

    @discardableResult
    public func performIfCurrent(
        _ epoch: Epoch,
        _ action: () -> Void
    ) -> Bool {
        lock.lock()
        guard current == epoch else {
            lock.unlock()
            return false
        }
        action()
        lock.unlock()
        return true
    }

    public func disposition(for epoch: Epoch) -> Disposition {
        lock.lock()
        let disposition: Disposition
        if current == epoch {
            disposition = .current
        } else if current != nil {
            disposition = .replaced
        } else {
            disposition = .invalidated
        }
        lock.unlock()
        return disposition
    }

    private func staleResult(for epoch: Epoch) -> CloudGatewayTunnelNotificationResult {
        disposition(for: epoch) == .invalidated ? .absent : .unknown
    }

    private func resolveAddCompletion(
        _ result: CloudGatewayTunnelNotificationResult,
        for epoch: Epoch,
        remove: () -> Void
    ) -> CloudGatewayTunnelNotificationResult {
        lock.lock()
        let resolved: CloudGatewayTunnelNotificationResult
        if current == epoch {
            resolved = result
        } else if current != nil {
            resolved = .unknown
        } else {
            remove()
            resolved = .absent
        }
        lock.unlock()
        return resolved
    }
}

private final class CloudGatewayTunnelHealthNotificationResultDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (CloudGatewayTunnelNotificationResult) async -> Void)?

    init(
        _ completion: @escaping @Sendable (CloudGatewayTunnelNotificationResult) async -> Void
    ) {
        self.completion = completion
    }

    func deliver(_ result: CloudGatewayTunnelNotificationResult) {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()
        guard let completion else { return }
        Task { await completion(result) }
    }
}
