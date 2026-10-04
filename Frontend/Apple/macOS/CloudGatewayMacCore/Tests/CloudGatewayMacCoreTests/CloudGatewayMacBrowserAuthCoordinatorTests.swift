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
    flow.signOut()
    #expect(!flow.begin())
    auth.continuation?.resume()
    auth.continuation = nil
    await waitUntil { !auth.isCustomTokenSignInSettling }
    #expect(flow.state == .signedOut)
    #expect(auth.currentUser == nil)
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
