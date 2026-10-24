import CloudGatewayMacControllerIPC
import CloudGatewayMacCore
import Foundation

@MainActor
public struct CloudGatewayMacCLILoginEffects {
    let qrMatrix: (URL) throws -> [[Bool]]
    let copy: (URL) -> Bool
    let open: (URL) -> Bool

    public init(qrMatrix: @escaping (URL) throws -> [[Bool]] = { _ in [] },
                copy: @escaping (URL) -> Bool = { _ in false },
                open: @escaping (URL) -> Bool = { _ in false }) {
        self.qrMatrix = qrMatrix
        self.copy = copy
        self.open = open
    }
}

@MainActor
struct CloudGatewayMacCLILogin {
    let client: CloudGatewayMacFrontendClient
    let clock: CloudGatewayMacCLIClock
    let terminal: CloudGatewayMacCLITerminal
    let output: (String) throws -> Void
    let diagnostics: (String) -> Void
    var input: any CloudGatewayMacCLILoginInput = CloudGatewayMacCLILoginTerminal()
    var effects = CloudGatewayMacCLILoginEffects()

    func run(invocation: CloudGatewayMacCLIInvocation, showsQR: Bool, startedAt invocationStartedAt: Duration? = nil) async -> Result<CloudGatewayMacCLIData, CloudGatewayMacCLIError> {
        let id = UUID()
        let startedAt = invocationStartedAt ?? clock.now()
        let callerDeadline = invocation.timeout.map { startedAt + $0 }
        var deadline = min(callerDeadline ?? startedAt + .seconds(30), startedAt + .seconds(30))
        var challengeDeadline: Duration?
        let interactive = terminal.isOutputTerminal && !invocation.isJSON && !invocation.isNonInteractive
            && terminal.variables["TERM"] != "dumb"
        let shortcuts = input.start(shortcuts: interactive)
        defer { input.close() }
        var submitted = false
        var shouldCancel = false
        do {
            let lifecycle = try await bounded(until: deadline) { try await client.handshake() }
            guard client.isCurrentBuild else {
                throw CloudGatewayMacCLIError(lifecycle.state == .invalidInstallation ? .installationRequired : .incompatibleVersion)
            }
            submitted = true
            var reply = try await bounded(until: deadline) { try await client.send(.beginLogin, id: id, loginOrigin: .cli) }
            var printed = false
            while true {
                try Task.checkCancellation()
                if let interruption = input.interruption { throw interruption }
                guard let status = reply.login, status.attemptId == id else { throw CloudGatewayMacCLIError(CloudGatewayMacCLIError.Code.invalidResponse) }
                if let challenge = status.challenge {
                    let expiresAt = clock.now() + .seconds(challenge.remainingSeconds)
                    let observedDeadline = min(challengeDeadline ?? expiresAt, expiresAt)
                    challengeDeadline = observedDeadline
                    deadline = min(callerDeadline ?? observedDeadline, observedDeadline)
                    if !printed {
                        do {
                            try printChallenge(challenge, invocation: invocation, showsQR: showsQR && interactive && terminal.allowsStyle(for: invocation), shortcuts: shortcuts)
                        } catch {
                            shouldCancel = true
                            throw error
                        }
                        printed = true
                    }
                }
                guard clock.now() < deadline else { throw LoginDeadlineReached() }
                if let result = status.result {
                    guard result == .authorized else { throw failure(result) }
                    let snapshot = try await bounded(until: deadline) { try await client.send(.snapshot) }
                    guard let state = snapshot.state, state.accountId != nil, state.accessAuthorized else {
                        throw CloudGatewayMacCLIError(CloudGatewayMacCLIError.Code.invalidResponse)
                    }
                    return .success(.auth(.init(state)))
                }
                if shortcuts, let challenge = status.challenge {
                    for key in input.readKeys() {
                        if key == 3 { throw CloudGatewayMacCLILoginInterruption.cancelled }
                        if key == 99, !effects.copy(challenge.verificationURL) {
                            diagnostics("Clipboard unavailable. Use the approval link above on another device\n")
                        }
                        if key == 111, !effects.open(challenge.verificationURL) {
                            diagnostics("Browser unavailable. Use the approval link above on another device\n")
                        }
                    }
                }
                let delay = min(.milliseconds(250), max(.zero, deadline - clock.now()))
                _ = try await bounded(until: deadline) { try await clock.sleep(delay); return true }
                reply = try await bounded(until: deadline) { try await client.send(.loginStatus, contextId: id) }
            }
        } catch {
            input.close()
            shouldCancel = shouldCancel || error is LoginDeadlineReached
                || error as? CloudGatewayMacCLILoginInterruption == .cancelled
            if input.interruption == .detached || Task.isCancelled { shouldCancel = false }
            if submitted, shouldCancel {
                // Explicit cancellation and caller deadlines only affect this invocation's attempt
                _ = try? await bounded(until: clock.now() + .seconds(1), checkInterrupt: false) {
                    try await client.send(.cancelLogin, contextId: id)
                }
            }
            if error is LoginDeadlineReached { return .failure(.init(CloudGatewayMacCLIError.Code.timeout)) }
            if error as? CloudGatewayMacCLILoginInterruption != nil {
                return .failure(.init(CloudGatewayMacCLIError.Code.interrupted))
            }
            return .failure(.init(error))
        }
    }

    private func printChallenge(_ challenge: CloudGatewayMacLoginStatus.Challenge,
                                invocation: CloudGatewayMacCLIInvocation, showsQR: Bool, shortcuts: Bool) throws {
        if invocation.isJSON {
            let record = LoginChallengeRecord(data: .init(verificationURL: challenge.verificationURL.absoluteString,
                                                          userCode: challenge.userCode, expiresIn: challenge.remainingSeconds))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try output(String(decoding: encoder.encode(record), as: UTF8.self) + "\n")
            return
        }
        try output("Approve sign-in: \(challenge.verificationURL.absoluteString)\nCode: \(challenge.userCode)\n")
        if showsQR {
            if let qr = try? effects.qrMatrix(challenge.verificationURL),
               let rendered = CloudGatewayMacCLIQR.renderQR(qr, width: input.width) {
                try output(rendered)
            } else { diagnostics("QR unavailable or terminal too narrow. Use the approval link and code above\n") }
        }
        if shortcuts {
            try output("Press c to copy the link, o to open it, or Ctrl-C to cancel\n")
            if terminal.variables["SSH_CONNECTION"] != nil || terminal.variables["SSH_TTY"] != nil {
                try output("Clipboard and browser shortcuts act on this remote Mac. You can approve on another device\n")
            }
        }
    }

    private func failure(_ result: CloudGatewayMacLoginStatus.Result) -> CloudGatewayMacCLIError {
        switch result {
        case .authorized: .init(CloudGatewayMacCLIError.Code.invalidResponse)
        case .busy: .init(CloudGatewayMacCLIError.Code.busy)
        case .cancelled: .init(CloudGatewayMacCLIError.Code.interrupted)
        case .expired: .init(CloudGatewayMacCLIError.Code.timeout, message: "The sign-in code or acquisition deadline expired", suggestion: "Run: cloudgateway auth login")
        case .denied: .init(CloudGatewayMacCLIError.Code.accessDenied)
        case .invalidResponse: .init(CloudGatewayMacCLIError.Code.invalidResponse)
        case .offline: .init(CloudGatewayMacCLIError.Code.networkUnavailable)
        case .unavailable: .init(CloudGatewayMacCLIError.Code.credentialsUnavailable, message: "Sign-in could not finish. Try again")
        }
    }

    private func bounded<Value: Sendable>(until deadline: Duration, checkInterrupt: Bool = true,
                                         work: @escaping @MainActor () async throws -> Value) async throws -> Value {
        guard clock.now() < deadline else { throw LoginDeadlineReached() }
        let race = LoginCallRace<Value>()
        let worker = Task {
            do {
                let value = try await work()
                guard clock.now() < deadline else { throw LoginDeadlineReached() }
                race.finish(.success(value))
            } catch { race.finish(.failure(error)) }
        }
        let timer = Task {
            do { try await clock.timer(max(.zero, deadline - clock.now())) } catch { return }
            race.finish(.failure(LoginDeadlineReached()))
        }
        let signals = Task {
            guard checkInterrupt else { return }
            while !Task.isCancelled {
                if let interruption = input.interruption { race.finish(.failure(interruption)); return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        defer { worker.cancel(); timer.cancel(); signals.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { race.start($0) }
        } onCancel: {
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }
}

private struct LoginChallengeRecord: Encodable {
    struct Challenge: Encodable {
        let verificationURL: String
        let userCode: String
        let expiresIn: Int
    }

    let schemaVersion = 1
    let type = "login_required"
    let command = "auth login"
    let data: Challenge

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(type, forKey: .type)
        try container.encode(command, forKey: .command)
        try container.encodeNil(forKey: .operationId)
        try container.encode(data, forKey: .data)
        try container.encodeNil(forKey: .error)
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, type, command, operationId, data, error }
}

@MainActor
private final class LoginCallRace<Value: Sendable> {
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?

    func start(_ continuation: CheckedContinuation<Value, any Error>) {
        if let result { continuation.resume(with: result) }
        else { self.continuation = continuation }
    }

    func finish(_ result: Result<Value, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

private struct LoginDeadlineReached: Error {}
