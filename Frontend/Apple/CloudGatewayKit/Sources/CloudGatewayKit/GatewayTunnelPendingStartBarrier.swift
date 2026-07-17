import Foundation

public final class GatewayTunnelPendingStartBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var pendingID: UInt64?
    private var stopCompletion: (@Sendable () -> Void)?
    private var stopping = false

    public init() {}

    public func begin() -> UInt64 {
        lock.lock()
        nextID &+= 1
        pendingID = nextID
        stopCompletion = nil
        stopping = false
        let id = nextID
        lock.unlock()
        return id
    }

    public func prepareToStop(
        completion: @escaping @Sendable () -> Void
    ) -> Bool {
        lock.lock()
        stopping = true
        guard pendingID != nil else {
            lock.unlock()
            return false
        }
        stopCompletion = completion
        lock.unlock()
        return true
    }

    public func canContinue(_ id: UInt64) -> Bool {
        lock.lock()
        let canContinue = pendingID == id && !stopping
        lock.unlock()
        return canContinue
    }

    @discardableResult
    public func performIfCanContinue(
        _ id: UInt64,
        _ action: () -> Void
    ) -> Bool {
        lock.lock()
        guard pendingID == id, !stopping else {
            lock.unlock()
            return false
        }
        action()
        lock.unlock()
        return true
    }

    public func prepareJoinedStop(
        completion: @escaping @Sendable () -> Void
    ) -> GatewayTunnelStartStopJoin {
        let join = GatewayTunnelStartStopJoin(completion: completion)
        let waitsForPendingStart = prepareToStop {
            join.startFinished()
        }
        if !waitsForPendingStart {
            join.startFinished()
        }
        return join
    }

    public func complete(_ id: UInt64) {
        lock.lock()
        guard pendingID == id else {
            lock.unlock()
            return
        }
        pendingID = nil
        let completion = stopCompletion
        stopCompletion = nil
        lock.unlock()
        completion?()
    }
}
