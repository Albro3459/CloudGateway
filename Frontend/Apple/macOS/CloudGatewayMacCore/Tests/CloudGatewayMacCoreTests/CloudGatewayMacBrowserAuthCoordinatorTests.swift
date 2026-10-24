import CloudGatewayAppCore
import Foundation
import Synchronization
import Testing
@testable import CloudGatewayMacCore

private let requestId = String(repeating: "a", count: 32)
private let dashboardOrigin = URL(string: "https://dashboard.example.com")!
private let sampleCode = CloudGatewayDeviceCode(
    requestId: requestId, userCode: "000012",
    verificationURL: URL(string: "https://dashboard.example.com/#/auth/code?deviceRequestId=\(requestId)&userCode=000012")!,
    expiresIn: 100, interval: 5
)

private actor DeviceService: CloudGatewayDeviceAuthServicing {
    let code: CloudGatewayDeviceCode
    var results: [Result<CloudGatewayDeviceTokenResult, CloudGatewayDeviceAuthError>]
    var requestCount = 0
    var pollCount = 0
    var codeErrors: [CloudGatewayDeviceAuthError]
    var blockCode: Bool
    var codeContinuation: CheckedContinuation<CloudGatewayDeviceCode, any Error>?
    var blockPoll: Bool
    var pollContinuation: CheckedContinuation<CloudGatewayDeviceTokenResult, any Error>?

    init(code: CloudGatewayDeviceCode = sampleCode,
         results: [Result<CloudGatewayDeviceTokenResult, CloudGatewayDeviceAuthError>] = [.success(.approved(customToken: "fixture-token"))],
         blockCode: Bool = false, blockPoll: Bool = false, codeErrors: [CloudGatewayDeviceAuthError] = []) {
        self.code = code
        self.results = results
        self.blockCode = blockCode
        self.blockPoll = blockPoll
        self.codeErrors = codeErrors
    }

    func requestCode(secret: CloudGatewayDeviceSecret) async throws -> CloudGatewayDeviceCode {
        requestCount += 1
        if !codeErrors.isEmpty { throw codeErrors.removeFirst() }
        if blockCode { return try await withCheckedThrowingContinuation { codeContinuation = $0 } }
        return code
    }

    func releaseCode() {
        codeContinuation?.resume(returning: code)
        codeContinuation = nil
    }

    func pollToken(requestId: String, secret: CloudGatewayDeviceSecret) async throws -> CloudGatewayDeviceTokenResult {
        pollCount += 1
        if blockPoll { return try await withCheckedThrowingContinuation { pollContinuation = $0 } }
        guard !results.isEmpty else { throw CloudGatewayDeviceAuthError.unavailable }
        return try results.removeFirst().get()
    }

    func releasePoll() {
        blockPoll = false
        pollContinuation?.resume(returning: .approved(customToken: "late-token"))
        pollContinuation = nil
    }
}

@MainActor
private final class BrowserAuth: CloudGatewayCustomTokenAuthServicing {
    var currentUser: AuthenticatedUser?
    var isCustomTokenSignInSettling = false
    var signInCount = 0
    var signOutCount = 0
    var signOutError: CloudGatewayDeviceAuthError?
    var shouldSuspendExchange = false
    var continuation: CheckedContinuation<Void, Never>?
    private var generation = 0

    func signIn(customToken _: String) async throws -> AuthenticatedUser {
        signInCount += 1
        let attempt = generation
        isCustomTokenSignInSettling = true
        if shouldSuspendExchange { await withCheckedContinuation { continuation = $0 } }
        isCustomTokenSignInSettling = false
        guard generation == attempt else { throw CancellationError() }
        let user = AuthenticatedUser(uid: "user-a", email: nil)
        currentUser = user
        return user
    }

    func cancelCustomTokenSignIn() throws {
        if isCustomTokenSignInSettling { try signOut() }
    }

    func signOut() throws {
        generation += 1
        signOutCount += 1
        if let signOutError {
            currentUser = nil
            isCustomTokenSignInSettling = true
            throw signOutError
        }
        currentUser = nil
    }
}

private final class PollClock: Sendable {
    struct State: Sendable {
        var now = Duration.zero
        var sleeps = [Duration]()
    }
    let state = Mutex(State())

    var now: Duration { state.withLock { $0.now } }

    func sleep(_ duration: Duration) async {
        state.withLock {
            $0.sleeps.append(duration)
            $0.now += duration
        }
        await Task.yield()
    }
}

@MainActor
private func coordinator(service: DeviceService, auth: BrowserAuth, clock: PollClock,
                         open: @escaping (URL) -> Void = { _ in },
                         access: @escaping (AuthenticatedUser) async throws -> Bool = { _ in true }) -> CloudGatewayMacBrowserAuthCoordinator {
    CloudGatewayMacBrowserAuthCoordinator(
        service: service, auth: auth, dashboardOrigin: dashboardOrigin,
        openBrowser: open, checkAccess: access,
        now: { clock.now }, sleep: { await clock.sleep($0) }
    )
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        await Task.yield()
    }
    #expect(condition())
}

@Test @MainActor func browserCodeKeepsZerosAndDuplicateBeginDoesNotCreateRequests() async throws {
    let service = DeviceService()
    let auth = BrowserAuth()
    var opened = [URL]()
    var states = [CloudGatewayMacBrowserAuthState]()
    let flow = coordinator(service: service, auth: auth, clock: PollClock(), open: { opened.append($0) })
    flow.onChange = { states.append($0) }
    #expect(flow.begin())
    #expect(!flow.begin())
    await waitUntil { if case .signedIn = flow.state { true } else { false } }
    #expect(states.contains(.waitingForApproval(userCode: "000012", verificationURL: sampleCode.verificationURL)))
    #expect(opened == [sampleCode.verificationURL])
    let count = await service.requestCount
    #expect(count == 1)
    #expect(auth.signInCount == 1)
    #expect(!flow.begin())
}

@Test @MainActor func pollingHonorsRetryAfterAndNeverReducesItsInterval() async {
    let service = DeviceService(results: [
        .failure(.throttled(retryAfter: 12)), .success(.pending(interval: 5)),
        .success(.approved(customToken: "fixture-token")),
    ])
    let clock = PollClock()
    let flow = coordinator(service: service, auth: BrowserAuth(), clock: clock)
    flow.begin()
    await waitUntil { if case .signedIn = flow.state { true } else { false } }
    #expect(clock.state.withLock { $0.sleeps } == [.seconds(5), .seconds(12), .seconds(12)])
}

@Test @MainActor func codeRequestHonorsRetryAfterBeforeRetrying() async {
    let service = DeviceService(codeErrors: [.throttled(retryAfter: 25)])
    let clock = PollClock()
    let flow = coordinator(service: service, auth: BrowserAuth(), clock: clock)
    flow.begin()
    await waitUntil { if case .signedIn = flow.state { true } else { false } }
    #expect(clock.state.withLock { $0.sleeps } == [.seconds(25), .seconds(5)])
    let count = await service.requestCount
    #expect(count == 2)
}

@Test @MainActor func expiryBoundaryDoesNotPollOrExchangeAgain() async {
    let code = CloudGatewayDeviceCode(requestId: requestId, userCode: "000012", verificationURL: sampleCode.verificationURL,
                                      expiresIn: 10, interval: 5)
    let service = DeviceService(code: code, results: [.success(.pending(interval: 5))])
    let auth = BrowserAuth()
    let flow = coordinator(service: service, auth: auth, clock: PollClock())
    flow.begin()
    await waitUntil { flow.state == .failed(.expired) }
    let count = await service.pollCount
    #expect(count == 1)
    #expect(auth.signInCount == 0)
}

@Test @MainActor func throttledPollingSleepsOnlyUntilCodeExpiry() async {
    let code = CloudGatewayDeviceCode(requestId: requestId, userCode: "000012", verificationURL: sampleCode.verificationURL,
                                      expiresIn: 10, interval: 5)
    let service = DeviceService(code: code, results: [.failure(.throttled(retryAfter: 60))])
    let auth = BrowserAuth()
    let clock = PollClock()
    let flow = coordinator(service: service, auth: auth, clock: clock)
    flow.begin()
    await waitUntil { flow.state == .failed(.expired) }
    #expect(clock.state.withLock { $0.sleeps } == [.seconds(5), .seconds(5)])
    #expect(await service.pollCount == 1)
    #expect(auth.signInCount == 0)
}

@Test @MainActor func unexpectedApprovalURLNeverOpensBrowser() async {
    let code = CloudGatewayDeviceCode(requestId: requestId, userCode: "000012",
                                      verificationURL: URL(string: "https://unexpected.example/#/auth/code")!,
                                      expiresIn: 100, interval: 5)
    var opened = false
    let auth = BrowserAuth()
    let flow = coordinator(service: DeviceService(code: code), auth: auth, clock: PollClock(), open: { _ in opened = true })
    flow.begin()
    await waitUntil { flow.state == .failed(.invalidResponse) }
    #expect(!opened)
    #expect(auth.signInCount == 0)
}

@Test @MainActor func cancellationDiscardsLateCodeResponse() async {
    let service = DeviceService(blockCode: true)
    var opened = false
    let auth = BrowserAuth()
    let flow = coordinator(service: service, auth: auth, clock: PollClock(), open: { _ in opened = true })
    flow.begin()
    for _ in 0..<1000 {
        if await service.codeContinuation != nil { break }
        await Task.yield()
    }
    flow.cancel()
    await service.releaseCode()
    for _ in 0..<100 { await Task.yield() }
    #expect(flow.state == .signedOut)
    #expect(!opened)
    #expect(auth.signInCount == 0)
}

@Test @MainActor func cancelledPollCannotExchangeOrDisturbNewAttempt() async {
    let service = DeviceService(blockPoll: true)
    let auth = BrowserAuth()
    let flow = coordinator(service: service, auth: auth, clock: PollClock())
    flow.begin()
    for _ in 0..<1000 {
        if await service.pollContinuation != nil { break }
        await Task.yield()
    }
    #expect(await service.pollContinuation != nil)
    flow.cancel()
    #expect(flow.state == .signedOut)
    await service.releasePoll()
    #expect(flow.begin())
    await waitUntil { if case .signedIn = flow.state { true } else { false } }
    #expect(auth.signInCount == 1)
    #expect(auth.currentUser?.uid == "user-a")
    #expect(auth.signOutCount == 0)
}

@Test(arguments: ["000012\n", "000012\r\n", "x000012", "000012x"])
@MainActor func malformedCodeNeverOpensBrowser(_ userCode: String) async {
    let code = CloudGatewayDeviceCode(requestId: requestId, userCode: userCode,
                                      verificationURL: sampleCode.verificationURL, expiresIn: 100, interval: 5)
    var opened = false
    let flow = coordinator(service: DeviceService(code: code), auth: BrowserAuth(), clock: PollClock(), open: { _ in opened = true })
    flow.begin()
    await waitUntil { flow.state == .failed(.invalidResponse) }
    #expect(!opened)
}

@Test @MainActor func signOutFencesLateFirebaseCompletionAndBlocksNewAttemptUntilSettled() async {
    let auth = BrowserAuth()
    auth.shouldSuspendExchange = true
    let flow = coordinator(service: DeviceService(), auth: auth, clock: PollClock())
    flow.begin()
    await waitUntil { auth.continuation != nil }
    #expect(flow.signOut())
    #expect(!flow.begin())
    auth.continuation?.resume()
    auth.continuation = nil
    await waitUntil { !auth.isCustomTokenSignInSettling }
    #expect(flow.state == .signedOut)
    #expect(auth.currentUser == nil)
}

@Test @MainActor func signOutReportsFailedCleanupEvenWhenCredentialsAreSuppressed() async {
    let auth = BrowserAuth()
    auth.currentUser = AuthenticatedUser(uid: "user-a", email: nil)
    auth.signOutError = .unavailable
    let flow = coordinator(service: DeviceService(), auth: auth, clock: PollClock())

    #expect(!flow.signOut())
    #expect(flow.state == .failed(.unavailable))
    #expect(auth.currentUser == nil)
    #expect(auth.isCustomTokenSignInSettling)
    #expect(!flow.begin())
}

@Test @MainActor func productAccessDenialClearsSDKSession() async {
    let auth = BrowserAuth()
    let flow = coordinator(service: DeviceService(), auth: auth, clock: PollClock(), access: { _ in false })
    flow.begin()
    await waitUntil { flow.state == .failed(.denied) }
    #expect(auth.currentUser == nil)
    #expect(auth.signOutCount > 0)
}

@Test @MainActor func cancellationDuringAccessCheckClearsAcceptedSDKSession() async {
    let auth = BrowserAuth()
    var accessContinuation: CheckedContinuation<Bool, Never>?
    let flow = coordinator(service: DeviceService(), auth: auth, clock: PollClock(), access: { _ in
        await withCheckedContinuation { accessContinuation = $0 }
    })
    flow.begin()
    await waitUntil { accessContinuation != nil }
    #expect(auth.currentUser != nil)
    flow.cancel()
    #expect(auth.currentUser == nil)
    accessContinuation?.resume(returning: true)
    accessContinuation = nil
    for _ in 0..<100 { await Task.yield() }
    #expect(flow.state == .signedOut)
}

@Test @MainActor func terminalDeviceErrorsRequireANewUserStartedAttempt() async {
    let errors: [CloudGatewayDeviceAuthError] = [.denied, .expired, .consumed, .invalidRequest, .offline, .unavailable]
    for error in errors {
        let service = DeviceService(results: [.failure(error)])
        let auth = BrowserAuth()
        let flow = coordinator(service: service, auth: auth, clock: PollClock())
        flow.begin()
        await waitUntil { flow.state == .failed(error) }
        #expect(auth.signInCount == 0)
        let count = await service.requestCount
        #expect(count == 1)
    }
}

final class AuthDeadlineClock: Sendable {
    private struct State {
        var now = Duration.zero
        var timers: [UUID: (Duration, CheckedContinuation<Void, any Error>)] = [:]
    }
    private let state = Mutex(State())

    var now: Duration { state.withLock { $0.now } }

    func advance(to instant: Duration) {
        let ready = state.withLock { state in
            state.now = max(state.now, instant)
            let ready = state.timers.filter { $0.value.0 <= state.now }
            for id in ready.keys { state.timers.removeValue(forKey: id) }
            return ready.values.map { $0.1 }
        }
        ready.forEach { $0.resume() }
    }

    func sleep(_ duration: Duration) async {
        advance(to: now + duration)
        await Task.yield()
    }

    func timer(_ duration: Duration) async throws {
        let id = UUID()
        let end = now + duration
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if state.now >= end { return .success(()) }
                    state.timers[id] = (end, continuation)
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            self.state.withLock { $0.timers.removeValue(forKey: id) }?.1.resume(throwing: CancellationError())
        }
    }
}

private enum HeldAuthCall: CaseIterable, Sendable {
    case request, poll, exchange, access
}

@Test(arguments: HeldAuthCall.allCases) @MainActor
private func controllerExpiryFencesEverySuspendedLoginCall(_ held: HeldAuthCall) async {
    let clock = AuthDeadlineClock()
    let service = DeviceService(blockCode: held == .request, blockPoll: held == .poll)
    let auth = BrowserAuth()
    auth.shouldSuspendExchange = held == .exchange
    var access: CheckedContinuation<Bool, Never>?
    let flow = CloudGatewayMacBrowserAuthCoordinator(
        service: service, auth: auth, dashboardOrigin: dashboardOrigin, openBrowser: { _ in },
        checkAccess: { _ in
            if held == .access { return await withCheckedContinuation { access = $0 } }
            return true
        }, now: { clock.now }, sleep: { await clock.sleep($0) }, timer: { try await clock.timer($0) }
    )
    let id = UUID()
    #expect(flow.begin(attemptId: id, origin: .cli))
    for _ in 0..<5000 {
        let reached = switch held {
        case .request: await service.codeContinuation != nil
        case .poll: await service.pollContinuation != nil
        case .exchange: auth.continuation != nil
        case .access: access != nil
        }
        if reached { break }
        await Task.yield()
    }
    clock.advance(to: .seconds(500))
    await waitUntil { flow.loginStatus?.result == .expired }
    #expect(flow.state == .failed(.expired))
    #expect(auth.currentUser == nil)
    #expect(flow.loginStatus?.challenge == nil)
    if held == .exchange { #expect(!flow.begin(attemptId: UUID(), origin: .cli)) }
    switch held {
    case .request: await service.releaseCode()
    case .poll: await service.releasePoll()
    case .exchange: auth.continuation?.resume(); auth.continuation = nil
    case .access: access?.resume(returning: true); access = nil
    }
    for _ in 0..<100 { await Task.yield() }
    #expect(auth.currentUser == nil)
    #expect(flow.loginStatus?.attemptId == id)
    #expect(flow.loginStatus?.result == .expired)
}

@Test @MainActor func cliOriginNeverAutomaticallyOpensAndStaleCancelCannotClearNewAttempt() async {
    let service = DeviceService(blockCode: true)
    var opened = [URL]()
    let auth = BrowserAuth()
    let flow = coordinator(service: service, auth: auth, clock: PollClock(), open: { opened.append($0) })
    let old = UUID()
    #expect(flow.begin(attemptId: old, origin: .menu))
    flow.cancel(attemptId: old)
    let current = UUID()
    #expect(flow.begin(attemptId: current, origin: .cli))
    flow.cancel(attemptId: old)
    #expect(flow.loginStatus?.attemptId == current)
    #expect(flow.loginStatus?.result == nil)
    for _ in 0..<1000 {
        if await service.codeContinuation != nil { break }
        await Task.yield()
    }
    await service.releaseCode()
    await waitUntil { flow.loginStatus?.result == .authorized }
    flow.cancel(attemptId: current)
    #expect(auth.currentUser?.uid == "user-a")
    #expect(flow.loginStatus?.result == .authorized)
    #expect(opened.isEmpty)
}

@Test @MainActor func repeatedChallengeThrottleHasOneBoundedAcquisitionBudget() async {
    let service = DeviceService(codeErrors: Array(repeating: .throttled(retryAfter: 25), count: 10))
    let auth = BrowserAuth()
    let clock = PollClock()
    let flow = coordinator(service: service, auth: auth, clock: clock)
    #expect(flow.begin())
    await waitUntil { flow.loginStatus?.result == .expired }
    #expect(clock.now == .seconds(30))
    #expect(await service.requestCount == 2)
    #expect(auth.signInCount == 0)
}

@Test @MainActor func offlineProductAccessCheckKeepsTypedOfflineLoginFailure() async {
    let auth = BrowserAuth()
    let flow = coordinator(service: DeviceService(), auth: auth, clock: PollClock(), access: { _ in
        throw CloudGatewayMacInventoryError.offline
    })
    #expect(flow.begin(attemptId: UUID(), origin: .cli))
    await waitUntil { flow.loginStatus?.result == .offline }
    #expect(flow.state == .failed(.offline))
    #expect(auth.currentUser == nil)
    #expect(auth.signOutCount == 1)
}
