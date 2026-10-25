import Foundation
import Testing
@testable import CloudGatewayMacControllerIPC

@Test func canceledControllerRequestBeforeContinuationDoesNotStartTransport() async {
    let cleanup = CleanupCount()
    let pending = ControllerPendingReply { cleanup.record() }
    pending.finish(.failure(CancellationError()))
    do {
        let _: CloudGatewayMacControllerReply = try await withCheckedThrowingContinuation { continuation in
            #expect(!pending.start(continuation))
        }
        Issue.record("Canceled controller request returned a reply")
    } catch { #expect(error is CancellationError) }
    #expect(cleanup.value == 1)
}

@Test func canceledControllerRequestAfterStartDoesNotSetUpTransport() async {
    let transport = PendingReplyTransport()
    let pending = ControllerPendingReply { transport.invalidate() }
    do {
        let _: CloudGatewayMacControllerReply = try await withCheckedThrowingContinuation { continuation in
            #expect(pending.start(continuation))
            pending.finish(.failure(CancellationError()))
            pending.withTransportSetup {
                transport.installCallback { pending.finish(.failure(CloudGatewayMacControllerFailure.unavailable)) }
                transport.activate()
                pending.armTimeout()
                transport.send()
            }
        }
        Issue.record("Canceled controller request returned a reply")
    } catch { #expect(error is CancellationError) }
    #expect(transport.events == ["cleanup"])
    #expect(!transport.hasCallback)
}

@Test func controllerCancellationCallbackDuringSetupCanFinishAndClearTransport() async {
    let transport = PendingReplyTransport()
    let pending = ControllerPendingReply { transport.invalidate() }
    do {
        let _: CloudGatewayMacControllerReply = try await withCheckedThrowingContinuation { continuation in
            #expect(pending.start(continuation))
            pending.withTransportSetup {
                transport.installCallback { pending.finish(.failure(CancellationError())) }
                transport.activate()
                pending.armTimeout()
                transport.send()
            }
            pending.withTransportSetup { Issue.record("Canceled controller request restarted transport") }
            pending.finish(.success(CloudGatewayMacControllerReply(accepted: true)))
        }
        Issue.record("Canceled controller request returned a reply")
    } catch { #expect(error is CancellationError) }
    #expect(transport.events == ["callbacks", "activate", "send", "cleanup"])
    #expect(!transport.hasCallback)
}

@Test func controllerCancellationOnAnotherQueueCleansUpAfterTransportSetup() async {
    let transport = PendingReplyTransport()
    let pending = ControllerPendingReply { transport.invalidate() }
    let cancellationStarted = DispatchSemaphore(value: 0)
    do {
        let _: CloudGatewayMacControllerReply = try await withCheckedThrowingContinuation { continuation in
            #expect(pending.start(continuation))
            pending.withTransportSetup {
                transport.installCallback {}
                DispatchQueue.global().async {
                    cancellationStarted.signal()
                    pending.finish(.failure(CancellationError()))
                }
                #expect(cancellationStarted.wait(timeout: .now() + .seconds(1)) == .success)
                transport.activate()
                pending.armTimeout()
                transport.send()
            }
        }
        Issue.record("Canceled controller request returned a reply")
    } catch { #expect(error is CancellationError) }
    #expect(transport.events == ["callbacks", "activate", "send", "cleanup"])
    #expect(!transport.hasCallback)
}

@Test func controllerReplyRacingTimeoutAndDisconnectCompletesExactlyOnce() async throws {
    let cleanup = CleanupCount()
    let pending = ControllerPendingReply { cleanup.record() }
    let expected = CloudGatewayMacControllerReply(accepted: true, operationId: UUID())
    let reply: CloudGatewayMacControllerReply = try await withCheckedThrowingContinuation { continuation in
        #expect(pending.start(continuation))
        pending.finish(.success(expected))
        pending.armTimeout(after: .zero)
        pending.finish(.failure(CloudGatewayMacControllerFailure.unavailable))
        pending.finish(.failure(CancellationError()))
    }
    #expect(reply == expected)
    #expect(cleanup.value == 1)
}

@Test func stalledControllerRequestHasBoundedDeadlineAndReleasesTransport() async {
    let cleanup = CleanupCount()
    let pending = ControllerPendingReply { cleanup.record() }
    do {
        let _: CloudGatewayMacControllerReply = try await withCheckedThrowingContinuation { continuation in
            #expect(pending.start(continuation))
            pending.armTimeout(after: .milliseconds(1))
        }
        Issue.record("Stalled controller request returned a reply")
    } catch { #expect(error as? CloudGatewayMacControllerFailure == .timeout) }
    #expect(cleanup.value == 1)
}

private final class CleanupCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func record() { lock.withLock { count += 1 } }
}

private final class PendingReplyTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var callback: (@Sendable () -> Void)?

    var events: [String] { lock.withLock { recordedEvents } }
    var hasCallback: Bool { lock.withLock { callback != nil } }

    func installCallback(_ callback: @escaping @Sendable () -> Void) {
        lock.withLock {
            recordedEvents.append("callbacks")
            self.callback = callback
        }
    }

    func activate() { lock.withLock { recordedEvents.append("activate") } }

    func send() {
        let callback = lock.withLock {
            recordedEvents.append("send")
            return self.callback
        }
        callback?()
    }

    func invalidate() {
        lock.withLock {
            recordedEvents.append("cleanup")
            callback = nil
        }
    }
}
