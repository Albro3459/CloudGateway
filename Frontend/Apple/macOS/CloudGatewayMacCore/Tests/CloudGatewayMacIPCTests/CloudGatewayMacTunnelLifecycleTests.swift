import Foundation
import Testing
@testable import CloudGatewayMacIPC

@Test func macTunnelStartCompletionIsDeliveredOnce() async {
    let fixture = MacLifecycleFixture()
    fixture.start()
    await fixture.drain()
    fixture.state.value.startCallback?(nil)
    fixture.state.value.startCallback?(nil)
    await fixture.drain()
    #expect(fixture.state.value.startResults == [nil])
}

@Test func macTunnelStopBeforeSecretResolutionFencesLateSubmission() async {
    let fixture = MacLifecycleFixture()
    fixture.lifecycle.start(operation: { attempt in
        fixture.state.update { $0.attempt = attempt }
    }, completion: { error in
        fixture.state.update { $0.startResults.append(error as? CloudGatewayMacTunnelLifecycleError) }
    })
    await fixture.drain()
    fixture.stop()
    await fixture.drain()
    fixture.state.value.attempt?.submitAdapterStart { callback in
        fixture.state.update {
            $0.events.append("late start")
            $0.startCallback = callback
        }
    }
    await fixture.drain()
    #expect(fixture.state.value.startResults == [.cancelled])
    #expect(fixture.state.value.stopCount == 1)
    #expect(fixture.state.value.events.isEmpty)
}

@Test func macTunnelAdapterStartIsSubmittedBeforeStopAndLateStartCannotReviveSession() async {
    let fixture = MacLifecycleFixture()
    fixture.start()
    await fixture.drain()
    fixture.stop()
    await fixture.drain()
    fixture.state.value.startCallback?(nil)
    await fixture.drain()
    #expect(fixture.state.value.events == ["start", "stop"])
    #expect(fixture.state.value.startResults == [.cancelled])
    #expect(fixture.state.value.stopCount == 0)
    fixture.state.value.stopCallback?()
    await fixture.drain()
    #expect(fixture.state.value.stopCount == 1)
}

@Test func macTunnelStopDeadlineKeepsCompletionPendingUntilConfirmedStop() async {
    let fixture = MacLifecycleFixture()
    fixture.start()
    await fixture.drain()
    fixture.stop()
    await fixture.drain()
    fixture.state.value.deadline?()
    fixture.state.value.deadline?()
    await fixture.drain()
    fixture.start()
    await fixture.drain()
    #expect(fixture.state.value.stopCount == 0)
    #expect(fixture.state.value.startResults == [.cancelled, .stopUnconfirmed])
    #expect(fixture.state.value.events == ["start", "stop"])
    fixture.state.value.stopCallback?()
    await fixture.drain()
    fixture.start()
    await fixture.drain()
    #expect(fixture.state.value.events == ["start", "stop", "start"])
    #expect(fixture.state.value.stopCount == 1)
}

@Test func macTunnelRepeatedStopAfterDeadlineWaitsForActualShutdown() async {
    let fixture = MacLifecycleFixture()
    fixture.start()
    await fixture.drain()
    fixture.stop()
    await fixture.drain()
    fixture.state.value.deadline?()
    await fixture.drain()
    fixture.stop()
    await fixture.drain()
    #expect(fixture.state.value.stopCount == 0)
    #expect(fixture.state.value.events == ["start", "stop"])
    fixture.state.value.stopCallback?()
    fixture.state.value.stopCallback?()
    await fixture.drain()
    #expect(fixture.state.value.stopCount == 2)
}

@Test func macTunnelOldCallbacksDoNotCompleteReplacementSession() async {
    let fixture = MacLifecycleFixture()
    fixture.start()
    await fixture.drain()
    let oldStart = fixture.state.value.startCallback
    fixture.stop()
    await fixture.drain()
    let oldStop = fixture.state.value.stopCallback
    let oldDeadline = fixture.state.value.deadline
    oldStop?()
    await fixture.drain()
    fixture.start()
    await fixture.drain()
    oldStart?(nil)
    oldStop?()
    oldDeadline?()
    await fixture.drain()
    #expect(fixture.state.value.startResults == [.cancelled])
    fixture.state.value.startCallback?(nil)
    await fixture.drain()
    #expect(fixture.state.value.startResults == [.cancelled, nil])
}

@Test func macTunnelRepeatedStopJoinsOneBackendOperation() async {
    let fixture = MacLifecycleFixture()
    fixture.start()
    await fixture.drain()
    fixture.stop()
    fixture.stop()
    await fixture.drain()
    fixture.state.value.stopCallback?()
    fixture.state.value.stopCallback?()
    await fixture.drain()
    #expect(fixture.state.value.events == ["start", "stop"])
    #expect(fixture.state.value.stopCount == 2)
}

@Test func macTunnelFailedPreparationAllowsAnotherSession() async {
    let fixture = MacLifecycleFixture()
    fixture.lifecycle.start(operation: { $0.fail(CloudGatewayMacTunnelLifecycleError.cancelled) }, completion: { error in
        fixture.state.update { $0.startResults.append(error as? CloudGatewayMacTunnelLifecycleError) }
    })
    await fixture.drain()
    fixture.start()
    await fixture.drain()
    #expect(fixture.state.value.events == ["start"])
    #expect(fixture.state.value.startResults == [.cancelled])
}

private final class MacLifecycleFixture: Sendable {
    struct State {
        var events: [String] = []
        var startResults: [CloudGatewayMacTunnelLifecycleError?] = []
        var stopCount = 0
        var startCallback: CloudGatewayMacTunnelLifecycle.StartCompletion?
        var stopCallback: CloudGatewayMacTunnelLifecycle.StopCompletion?
        var deadline: CloudGatewayMacTunnelLifecycle.StopCompletion?
        var attempt: CloudGatewayMacTunnelLifecycle.StartAttempt?
    }

    let state = MacLifecycleState()
    let queue = DispatchQueue(label: "CloudGatewayMacTunnelLifecycleTests")
    let lifecycle: CloudGatewayMacTunnelLifecycle

    init() {
        let state = self.state
        lifecycle = CloudGatewayMacTunnelLifecycle(queue: queue, scheduleStopDeadline: { callback in
            state.update { $0.deadline = callback }
        })
    }

    func start() {
        lifecycle.start(operation: { [state] attempt in
            attempt.submitAdapterStart { callback in
                state.update {
                    $0.events.append("start")
                    $0.startCallback = callback
                }
            }
        }, completion: { [state] error in
            state.update { $0.startResults.append(error as? CloudGatewayMacTunnelLifecycleError) }
        })
    }

    func stop() {
        lifecycle.stop(operation: { [state] callback in
            state.update {
                $0.events.append("stop")
                $0.stopCallback = callback
            }
        }, completion: { [state] in
            state.update { $0.stopCount += 1 }
        })
    }

    func drain() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume() }
            }
        }
    }
}

private final class MacLifecycleState: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = MacLifecycleFixture.State()

    var value: MacLifecycleFixture.State {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func update(_ body: (inout MacLifecycleFixture.State) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}
