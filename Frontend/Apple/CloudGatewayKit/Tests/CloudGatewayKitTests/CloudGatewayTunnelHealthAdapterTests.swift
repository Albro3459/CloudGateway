import Foundation
import Testing
@testable import CloudGatewayKit

private final class LockedAdapterTrace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        let values = storage
        lock.unlock()
        return values
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private enum StoreOperation: Equatable, Sendable {
    case write
    case clear
}

private enum StoreTestError: Error {
    case failed
}

private final class ManualStoreExecutor:
    CloudGatewayTunnelHealthStoreExecuting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var actions: [@Sendable () -> Void] = []

    func enqueue(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        actions.append(action)
        lock.unlock()
    }

    var pendingCount: Int {
        lock.lock()
        let count = actions.count
        lock.unlock()
        return count
    }

    @discardableResult
    func runNext() -> Bool {
        lock.lock()
        guard !actions.isEmpty else {
            lock.unlock()
            return false
        }
        let action = actions.removeFirst()
        lock.unlock()
        action()
        return true
    }
}

private actor AdapterCallbackRecorder<Value: Sendable> {
    private var storage: [Value] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func append(_ value: Value) {
        storage.append(value)
        let ready = waiters.filter { storage.count >= $0.0 }
        waiters.removeAll { storage.count >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
    }

    func waitForCount(_ count: Int) async {
        if storage.count >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    var values: [Value] { storage }
}

private final class LockedAuthorizationCallback: @unchecked Sendable {
    typealias Callback = @Sendable (
        CloudGatewayTunnelHealthNotificationAuthorizationResult
    ) -> Void

    private let lock = NSLock()
    private var callback: Callback?

    func set(_ callback: @escaping Callback) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func call(_ result: CloudGatewayTunnelHealthNotificationAuthorizationResult) {
        lock.lock()
        let callback = callback
        lock.unlock()
        callback?(result)
    }
}

private final class LockedNotificationResultCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (CloudGatewayTunnelNotificationResult) -> Void)?

    func set(
        _ callback: @escaping @Sendable (CloudGatewayTunnelNotificationResult) -> Void
    ) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func call(_ result: CloudGatewayTunnelNotificationResult) {
        lock.lock()
        let callback = callback
        lock.unlock()
        callback?(result)
    }
}

@Test func storeAdapterEnqueuesStalledWorkAndPreservesFIFO() async {
    let executor = ManualStoreExecutor()
    let physical = LockedAdapterTrace<StoreOperation>()
    let callbacks = AdapterCallbackRecorder<CloudGatewayTunnelEffectResult>()
    let adapter = CloudGatewayTunnelHealthStoreAdapter(
        write: { _ in
            physical.append(.write)
        },
        clear: {
            physical.append(.clear)
        },
        executor: executor
    )
    let snapshot = CloudGatewayTunnelHealthSnapshot(
        tunnelIdentifier: "client-1",
        health: .notPassingTraffic,
        updatedAt: Date(timeIntervalSince1970: 1)
    )

    adapter.write(snapshot) { result in
        await callbacks.append(result)
    }
    adapter.clear { result in
        await callbacks.append(result)
    }

    #expect(executor.pendingCount == 2)
    #expect(physical.values.isEmpty)
    #expect(executor.runNext())
    await callbacks.waitForCount(1)
    #expect(physical.values == [.write])
    #expect(executor.runNext())
    await callbacks.waitForCount(2)

    #expect(physical.values == [.write, .clear])
    #expect(await callbacks.values == [.success, .success])
}

@Test func storeAdapterFailureDoesNotOvertakeFollowingClear() async {
    let executor = ManualStoreExecutor()
    let physical = LockedAdapterTrace<StoreOperation>()
    let callbacks = AdapterCallbackRecorder<CloudGatewayTunnelEffectResult>()
    let adapter = CloudGatewayTunnelHealthStoreAdapter(
        write: { _ in
            physical.append(.write)
            throw StoreTestError.failed
        },
        clear: {
            physical.append(.clear)
        },
        executor: executor
    )
    let snapshot = CloudGatewayTunnelHealthSnapshot(
        tunnelIdentifier: "client-1",
        health: .notPassingTraffic,
        updatedAt: Date(timeIntervalSince1970: 1)
    )

    adapter.write(snapshot) { result in
        await callbacks.append(result)
    }
    adapter.clear { result in
        await callbacks.append(result)
    }
    #expect(executor.runNext())
    await callbacks.waitForCount(1)
    #expect(executor.runNext())
    await callbacks.waitForCount(2)

    #expect(physical.values == [.write, .clear])
    #expect(await callbacks.values == [.failure, .success])
}

@Test func notificationRegistrationWithdrawalBlocksDelayedAuthorization() async {
    let fence = CloudGatewayTunnelHealthNotificationRegistrationFence()
    let authorization = LockedAuthorizationCallback()
    let trace = LockedAdapterTrace<String>()
    let results = AdapterCallbackRecorder<CloudGatewayTunnelNotificationResult>()

    fence.register(
        authorization: { authorization.set($0) },
        add: { callback in
            trace.append("add")
            callback(.registered)
        },
        remove: { trace.append("repair-remove") },
        completion: { await results.append($0) }
    )
    fence.withdraw { trace.append("withdraw-remove") }
    authorization.call(.allowed)
    await results.waitForCount(1)

    #expect(trace.values == ["withdraw-remove"])
    #expect(await results.values == [.absent])
}

@Test func notificationRegistrationReplacementIgnoresOldAuthorization() async {
    let fence = CloudGatewayTunnelHealthNotificationRegistrationFence()
    let firstAuthorization = LockedAuthorizationCallback()
    let secondAuthorization = LockedAuthorizationCallback()
    let trace = LockedAdapterTrace<String>()
    let results = AdapterCallbackRecorder<CloudGatewayTunnelNotificationResult>()

    fence.register(
        authorization: { firstAuthorization.set($0) },
        add: { callback in
            trace.append("first-add")
            callback(.registered)
        },
        remove: { trace.append("first-repair-remove") },
        completion: { result in
            trace.append("first-\(result)")
            await results.append(result)
        }
    )
    fence.withdraw { trace.append("withdraw-remove") }
    fence.register(
        authorization: { secondAuthorization.set($0) },
        add: { callback in
            trace.append("second-add")
            callback(.registered)
        },
        remove: { trace.append("second-repair-remove") },
        completion: { result in
            trace.append("second-\(result)")
            await results.append(result)
        }
    )

    secondAuthorization.call(.allowed)
    firstAuthorization.call(.allowed)
    await results.waitForCount(2)

    #expect(trace.values.contains("second-add"))
    #expect(!trace.values.contains("first-add"))
    #expect(await results.values.contains(.registered))
    #expect(await results.values.contains(.unknown))
}

@Test func notificationRegistrationSuspensionRejectsQueuedAddUntilResume() async {
    let fence = CloudGatewayTunnelHealthNotificationRegistrationFence()
    let suspendedAuthorization = LockedAuthorizationCallback()
    let resumedAuthorization = LockedAuthorizationCallback()
    let trace = LockedAdapterTrace<String>()
    let results = AdapterCallbackRecorder<CloudGatewayTunnelNotificationResult>()

    fence.suspend()
    fence.register(
        authorization: { suspendedAuthorization.set($0) },
        add: { callback in
            trace.append("suspended-add")
            callback(.registered)
        },
        remove: {},
        completion: { await results.append($0) }
    )
    suspendedAuthorization.call(.allowed)
    await results.waitForCount(1)

    fence.resume()
    fence.register(
        authorization: { resumedAuthorization.set($0) },
        add: { callback in
            trace.append("resumed-add")
            callback(.registered)
        },
        remove: {},
        completion: { await results.append($0) }
    )
    resumedAuthorization.call(.allowed)
    await results.waitForCount(2)

    #expect(trace.values == ["resumed-add"])
    #expect(await results.values == [.absent, .registered])
}

@Test func oldAddCompletionDoesNotRemoveReplacementRegistration() async {
    let fence = CloudGatewayTunnelHealthNotificationRegistrationFence()
    let oldAdd = LockedNotificationResultCallback()
    let trace = LockedAdapterTrace<String>()
    let results = AdapterCallbackRecorder<CloudGatewayTunnelNotificationResult>()

    fence.register(
        authorization: { $0(.allowed) },
        add: { oldAdd.set($0) },
        remove: { trace.append("old-repair-remove") },
        completion: { await results.append($0) }
    )
    fence.withdraw { trace.append("withdraw-remove") }
    fence.register(
        authorization: { $0(.allowed) },
        add: { callback in
            trace.append("replacement-add")
            callback(.registered)
        },
        remove: { trace.append("replacement-repair-remove") },
        completion: { await results.append($0) }
    )
    oldAdd.call(.registered)
    await results.waitForCount(2)

    #expect(trace.values == ["withdraw-remove", "replacement-add"])
    #expect(await results.values.contains(.registered))
    #expect(await results.values.contains(.unknown))
}

@Test func notificationRegistrationFenceInvalidatesDelayedSubmission() {
    let fence = CloudGatewayTunnelHealthNotificationRegistrationFence()
    let epoch = fence.begin()
    var submitted = false

    fence.invalidate()

    #expect(fence.disposition(for: epoch) == .invalidated)
    #expect(!fence.performIfCurrent(epoch) { submitted = true })
    #expect(!submitted)
}

@Test func notificationRegistrationFenceDistinguishesReplacement() {
    let fence = CloudGatewayTunnelHealthNotificationRegistrationFence()
    let replaced = fence.begin()
    let current = fence.begin()
    var submissions: [String] = []

    #expect(fence.disposition(for: replaced) == .replaced)
    #expect(!fence.performIfCurrent(replaced) { submissions.append("old") })
    #expect(fence.disposition(for: current) == .current)
    #expect(fence.performIfCurrent(current) { submissions.append("new") })
    #expect(submissions == ["new"])
}
