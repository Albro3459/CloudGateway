@testable import CloudGatewayMacControllerIPC
import CloudGatewayMacCore
import Foundation
import Synchronization
import Testing
@testable import CloudGatewayMacCLI

@MainActor
private final class LoginInput: CloudGatewayMacCLILoginInput {
    var width = 100
    var interruption: CloudGatewayMacCLILoginInterruption?
    var starts: [Bool] = []
    var reads = 0
    var closes = 0
    var acceptsInput = false
    var restoredAfterEOF = false
    var keys = [UInt8]()

    func start(shortcuts: Bool) -> Bool { starts.append(shortcuts); return shortcuts && acceptsInput }
    func readKeys() -> [UInt8] {
        reads += 1
        if keys.isEmpty { restoredAfterEOF = true }
        defer { keys = [] }
        return keys
    }
    func close() { closes += 1 }
}

@MainActor
private final class LoginFixture {
    let clock = CLITestClock()
    let input = LoginInput()
    let instance = UUID()
    var id: UUID?
    var polls = 0
    var remainingSeconds = 100
    var injectedClock: CloudGatewayMacCLIClock?
    var pollError: CloudGatewayMacControllerFailure?
    var cancellations: [UUID] = []
    var output = ""
    var diagnostics = ""
    var copied = 0
    var opened = 0
    var encoded = 0
    var variables = ["TERM": "xterm", "SSH_CONNECTION": "fixture"]
    var result = CloudGatewayMacLoginStatus.Result.authorized
    var onOutput: (() throws -> Void)?
    var onPoll: (() async -> Void)?
    let url = URL(string: "https://dashboard.example.com/#/auth/code?deviceRequestId=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&userCode=000012")!

    func run(_ flags: [String] = [], terminal: Bool = false) async -> Result<CloudGatewayMacCLIData, CloudGatewayMacCLIError> {
        let client = CloudGatewayMacFrontendClient(identity: cliBuild, transport: { request in
            var reply: CloudGatewayMacControllerReply
            switch request.action {
            case .lifecycle: reply = .init(lifecycle: .init(running: cliBuild, installed: cliBuild, state: .current))
            case .beginLogin:
                self.id = request.id
                #expect(request.loginOrigin == .cli)
                reply = .init(login: self.status(request.id, finished: false))
            case .loginStatus:
                self.polls += 1
                await self.onPoll?()
                if let error = self.pollError { throw error }
                reply = .init(login: self.status(try #require(request.contextId), finished: self.polls >= 2))
            case .cancelLogin:
                self.cancellations.append(try #require(request.contextId))
                reply = .init(login: .init(attemptId: try #require(request.contextId), origin: .cli,
                                          phase: .finished, result: .cancelled))
            case .snapshot: reply = .init(state: cliState())
            default: throw CloudGatewayMacControllerFailure.invalidRequest
            }
            reply.instanceId = self.instance
            return reply
        }, bootstrap: {})
        let effects = CloudGatewayMacCLILoginEffects(qrMatrix: { _ in
            self.encoded += 1
            return Array(repeating: Array(repeating: true, count: 21), count: 21)
        }, copy: { _ in self.copied += 1; return false }, open: { _ in self.opened += 1; return false })
        let runner = CloudGatewayMacCLILogin(client: client, clock: injectedClock ?? clock.clock,
            terminal: .init(isOutputTerminal: terminal, variables: variables),
            output: { try self.onOutput?(); self.output += $0 }, diagnostics: { self.diagnostics += $0 },
            input: input, effects: effects)
        return await runner.run(invocation: try! CloudGatewayMacCLIParser.parse(["auth", "login"] + flags), showsQR: !flags.contains("--no-qr"))
    }

    private func status(_ id: UUID, finished: Bool) -> CloudGatewayMacLoginStatus {
        .init(attemptId: id, origin: .cli, phase: finished ? .finished : .waitingForApproval,
              challenge: finished ? nil : .init(userCode: "000012", verificationURL: url, remainingSeconds: remainingSeconds),
              result: finished ? result : nil)
    }
}

@Test(arguments: [["--json"], ["--non-interactive"], []]) @MainActor
private func loginWithoutInteractiveStdinStillPollsToAuthorization(_ flags: [String]) async throws {
    let fixture = LoginFixture()
    let result = await fixture.run(flags)
    _ = try result.get()
    #expect(fixture.polls == 2)
    #expect(fixture.input.starts == [false])
    #expect(fixture.input.reads == 0)
    #expect(fixture.input.closes >= 1)
    #expect(fixture.opened == 0 && fixture.copied == 0 && fixture.encoded == 0)
    #expect(fixture.cancellations.isEmpty)
    if flags.contains("--json") {
        let record = try #require(JSONSerialization.jsonObject(with: Data(fixture.output.utf8)) as? [String: Any])
        #expect(record["type"] as? String == "login_required")
        #expect(record["schemaVersion"] as? Int == 1)
        #expect((record["data"] as? [String: Any])?["userCode"] as? String == "000012")
        #expect(!fixture.output.contains("\u{001B}"))
        #expect(!fixture.output.contains("Press"))
    } else { #expect(fixture.output.contains("Code: 000012")) }
}

@Test @MainActor func loginEOFAndFailedShortcutsLeaveReadableChallengeAndPolling() async throws {
    let fixture = LoginFixture()
    fixture.input.acceptsInput = true
    fixture.input.keys = [99, 111]
    fixture.input.width = 1
    _ = try await fixture.run(terminal: true).get()
    #expect(fixture.copied == 1 && fixture.opened == 1)
    #expect(fixture.input.reads >= 2)
    #expect(fixture.input.restoredAfterEOF)
    #expect(fixture.polls == 2)
    #expect(fixture.output.contains(fixture.url.absoluteString))
    #expect(fixture.output.contains("remote Mac"))
    #expect(fixture.diagnostics.contains("Clipboard unavailable"))
    #expect(fixture.diagnostics.contains("Browser unavailable"))
    #expect(fixture.diagnostics.contains("terminal too narrow"))
    #expect(!fixture.diagnostics.contains("000012"))
}

@Test @MainActor func loginNoQRKeepsShortcutsAndNeverAutomaticallyOpens() async throws {
    let fixture = LoginFixture()
    fixture.input.acceptsInput = true
    _ = try await fixture.run(["--no-qr"], terminal: true).get()
    #expect(fixture.encoded == 0)
    #expect(fixture.opened == 0)
    #expect(fixture.output.contains("Press c"))
}

@Test @MainActor func loginOutputFailureCancelsOnlySubmittedAttemptAndRestoresInput() async {
    let fixture = LoginFixture()
    fixture.onOutput = { throw CocoaError(.fileWriteUnknown) }
    let result = await fixture.run()
    if case .success = result { Issue.record("Output failure must fail login") }
    #expect(fixture.input.closes >= 1)
    let expected = fixture.id.map { [$0] } ?? []
    #expect(fixture.cancellations == expected)
    #expect(fixture.polls == 0)
}

@Test(arguments: [CloudGatewayMacLoginStatus.Result.denied, .expired, .busy, .cancelled, .offline]) @MainActor
private func terminalLoginResultsRestoreInput(_ terminal: CloudGatewayMacLoginStatus.Result) async {
    let fixture = LoginFixture()
    fixture.result = terminal
    let result = await fixture.run(["--json"])
    guard case .failure(let error) = result else { Issue.record("Expected terminal failure"); return }
    let exit: Int32 = switch terminal {
    case .denied: 3
    case .expired: 8
    case .busy: 7
    case .offline: 6
    default: 130
    }
    #expect(error.code.exitCode == exit)
    #expect(fixture.input.closes >= 1)
}

@Test func terminalQRHasQuietZoneAndKeepsTopAndBottomModuleOrientation() throws {
    var matrix = Array(repeating: Array(repeating: false, count: 21), count: 21)
    matrix[0][0] = true
    matrix[1][1] = true
    matrix[2][2] = true
    matrix[3][2] = true
    #expect(CloudGatewayMacCLIQR.renderQR(matrix, width: 28) == nil)
    let qr = try #require(CloudGatewayMacCLIQR.renderQR(matrix, width: 29))
    let lines = qr.replacingOccurrences(of: "\u{001B}[30;47m", with: "")
        .replacingOccurrences(of: "\u{001B}[0m", with: "").split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines[0] == String(repeating: " ", count: 29))
    #expect(lines[1] == String(repeating: " ", count: 29))
    #expect(lines[2].hasPrefix("    ▀▄"))
    #expect(lines[3].hasPrefix("      █"))
    #expect(lines[2].count == 29)
}

@Test @MainActor func loginHandledSignalRestoresInputAndCancelsItsAttempt() async {
    let fixture = LoginFixture()
    fixture.input.acceptsInput = true
    fixture.onOutput = { fixture.input.interruption = .cancelled }
    let result = await fixture.run(["--no-qr"], terminal: true)
    guard case .failure(let error) = result else { Issue.record("Signal must interrupt login"); return }
    #expect(error.code == .interrupted)
    #expect(fixture.input.closes >= 1)
    let expected = fixture.id.map { [$0] } ?? []
    #expect(fixture.cancellations == expected)
}

@Test @MainActor func loginCallerDeadlineDoesNotWaitForSuspendedPollingReply() async {
    let fixture = LoginFixture()
    fixture.onPoll = {
        fixture.clock.expire()
        try? await cliSuspendUntilCancelled()
    }
    let result = await fixture.run(["--json", "--timeout", "10"])
    guard case .failure(let error) = result else { Issue.record("Held polling must time out"); return }
    #expect(error.code == .timeout)
    #expect(fixture.input.starts == [false])
    #expect(fixture.input.closes >= 1)
    #expect(!fixture.output.contains("\u{001B}"))
}

@Test @MainActor func loginHangupRestoresTerminalAndLeavesControllerAttemptRunning() async {
    let fixture = LoginFixture()
    fixture.onOutput = { fixture.input.interruption = .detached }
    let result = await fixture.run(["--no-qr"], terminal: true)
    guard case .failure(let error) = result else { Issue.record("Hangup must detach this caller"); return }
    #expect(error.code == .interrupted)
    #expect(fixture.cancellations.isEmpty)
    #expect(fixture.input.closes >= 1)
}

@Test @MainActor func loginTransportFailureDoesNotCancelControllerAttempt() async {
    let fixture = LoginFixture()
    fixture.pollError = .unavailable
    let result = await fixture.run(["--json"])
    guard case .failure(let error) = result else { Issue.record("Transport failure must end this caller"); return }
    #expect(error.code == .controllerUnavailable)
    #expect(fixture.cancellations.isEmpty)
    #expect(fixture.input.closes >= 1)
}

@Test @MainActor func loginExplicitControlCCancelsOnlyMatchingAttempt() async {
    let fixture = LoginFixture()
    fixture.input.acceptsInput = true
    fixture.input.keys = [3]
    let result = await fixture.run(["--no-qr"], terminal: true)
    guard case .failure(let error) = result else { Issue.record("Ctrl-C must cancel login"); return }
    #expect(error.code == .interrupted)
    let expected = fixture.id.map { [$0] } ?? []
    #expect(fixture.cancellations == expected)
    #expect(fixture.input.closes >= 1)
}

@Test @MainActor func loginDetachedTaskDoesNotCancelControllerAttempt() async throws {
    let fixture = LoginFixture()
    var entered = false
    fixture.onPoll = { entered = true; try? await cliSuspendUntilCancelled() }
    let caller = Task { await fixture.run(["--json"]) }
    try await loginWaitUntil { entered }
    caller.cancel()
    let result = await caller.value
    guard case .failure(let error) = result else { Issue.record("Task detachment must end this caller"); return }
    #expect(error.code == .interrupted)
    #expect(fixture.cancellations.isEmpty)
    #expect(fixture.input.closes >= 1)
}

@Test @MainActor func loginNoColorSuppressesANSIQRAndKeepsReadableApprovalAndShortcuts() async throws {
    let fixture = LoginFixture()
    fixture.variables["NO_COLOR"] = "1"
    fixture.input.acceptsInput = true
    _ = try await fixture.run(terminal: true).get()
    #expect(fixture.encoded == 0)
    #expect(!fixture.output.contains("\u{001B}"))
    #expect(fixture.output.contains(fixture.url.absoluteString))
    #expect(fixture.output.contains("Code: 000012"))
    #expect(fixture.output.contains("Press c"))
}

private final class LoginDeadlineClock: Sendable {
    private struct State {
        var now = Duration.zero
        var timers: [UUID: (Duration, CheckedContinuation<Void, any Error>)] = [:]
    }
    private let state = Mutex(State())

    var now: Duration { state.withLock { $0.now } }

    func hasTimer(at deadline: Duration) -> Bool { state.withLock { $0.timers.values.contains { $0.0 == deadline } } }

    func advance(to instant: Duration) {
        let ready = state.withLock { state in
            state.now = max(state.now, instant)
            let ready = state.timers.filter { $0.value.0 <= state.now }
            for id in ready.keys { state.timers.removeValue(forKey: id) }
            return ready.values.map { $0.1 }
        }
        ready.forEach { $0.resume() }
    }

    var clock: CloudGatewayMacCLIClock {
        .init(now: { self.now }, sleep: { duration in self.advance(to: self.now + duration) }, timer: { duration in
            let id = UUID()
            let deadline = self.now + duration
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let result: Result<Void, any Error>? = self.state.withLock { state in
                        if Task.isCancelled { return .failure(CancellationError()) }
                        if state.now >= deadline { return .success(()) }
                        state.timers[id] = (deadline, continuation)
                        return nil
                    }
                    if let result { continuation.resume(with: result) }
                }
            } onCancel: {
                self.state.withLock { $0.timers.removeValue(forKey: id) }?.1.resume(throwing: CancellationError())
            }
        })
    }
}

private struct LoginWaitTimeout: Error {}

@MainActor
private func loginWaitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<5000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Login did not reach the expected state")
    throw LoginWaitTimeout()
}

@Test(arguments: [[], ["--timeout", "100"], ["--timeout", "1"]]) @MainActor
private func loginChallengeExpiryBoundsHeldStatusAndExplicitTimeoutOnlyShortens(_ flags: [String]) async throws {
    let fixture = LoginFixture()
    let time = LoginDeadlineClock()
    fixture.injectedClock = time.clock
    fixture.remainingSeconds = 2
    var entered = false
    fixture.onPoll = { entered = true; try? await cliSuspendUntilCancelled() }
    let deadline = flags.last == "1" ? Duration.seconds(1) : .seconds(2)
    let caller = Task { await fixture.run(["--json"] + flags) }
    try await loginWaitUntil { entered && time.hasTimer(at: deadline) }
    time.advance(to: deadline)
    let result = await caller.value
    guard case .failure(let error) = result else { Issue.record("Held status must respect code expiry"); return }
    #expect(error.code == .timeout)
    #expect(time.now == deadline)
    #expect(fixture.input.closes >= 1)
    let expected = fixture.id.map { [$0] } ?? []
    #expect(fixture.cancellations == expected)
}
