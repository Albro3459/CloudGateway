import CloudGatewayAppCore
import Foundation

public enum CloudGatewayMacBrowserAuthState: Equatable, Sendable {
    case signedOut
    case requestingCode
    case waitingForApproval(userCode: String, verificationURL: URL)
    case exchangingToken
    case signedIn(AuthenticatedUser)
    case failed(CloudGatewayDeviceAuthError)
}

@MainActor
public final class CloudGatewayMacBrowserAuthCoordinator {
    public private(set) var state: CloudGatewayMacBrowserAuthState = .signedOut {
        didSet { onChange?(state) }
    }
    public var onChange: ((CloudGatewayMacBrowserAuthState) -> Void)?

    private let service: any CloudGatewayDeviceAuthServicing
    private let auth: any CloudGatewayCustomTokenAuthServicing
    private let dashboardOrigin: URL
    private let openURL: ((URL) -> Void)?
    private let checkAccess: (AuthenticatedUser) async throws -> Bool
    private let now: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var attemptId: UUID?
    private var origin = CloudGatewayMacLoginOrigin.menu
    private var lastStatus: CloudGatewayMacLoginStatus?
    private var deadline = Duration.zero
    private var challenge: CloudGatewayMacLoginStatus.Challenge?
    private var exchangeStarted = false
    private var watchdog: Task<Void, Never>?
    private let timer: @Sendable (Duration) async throws -> Void
    private var task: Task<Void, Never>?

    init(
        service: any CloudGatewayDeviceAuthServicing,
        auth: any CloudGatewayCustomTokenAuthServicing,
        dashboardOrigin: URL,
        openBrowser: @escaping (URL) -> Void,
        checkAccess: @escaping (AuthenticatedUser) async throws -> Bool,
        now: @escaping @Sendable () -> Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        timer: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.auth = auth
        self.dashboardOrigin = dashboardOrigin
        openURL = openBrowser
        self.checkAccess = checkAccess
        self.now = now
        self.sleep = sleep
        self.timer = timer
    }

    public var loginStatus: CloudGatewayMacLoginStatus? {
        guard let attemptId else { return lastStatus }
        let phase: CloudGatewayMacLoginStatus.Phase = switch state {
        case .requestingCode: .requestingCode
        case .waitingForApproval: .waitingForApproval
        default: .exchangingToken
        }
        let currentChallenge = challenge.map {
            CloudGatewayMacLoginStatus.Challenge(userCode: $0.userCode, verificationURL: $0.verificationURL,
                                                remainingSeconds: max(0, Int((deadline - now()).components.seconds)))
        }
        return .init(attemptId: attemptId, origin: origin, phase: phase, challenge: currentChallenge)
    }

    @discardableResult
    public func begin() -> Bool { begin(attemptId: UUID(), origin: .menu) }

    @discardableResult
    public func begin(attemptId id: UUID, origin: CloudGatewayMacLoginOrigin) -> Bool {
        guard attemptId == nil, auth.currentUser == nil, !auth.isCustomTokenSignInSettling else { return false }
        attemptId = id
        self.origin = origin
        challenge = nil
        exchangeStarted = false
        deadline = now() + .seconds(30)
        armDeadline(id)
        state = .requestingCode
        task = Task { [weak self] in await self?.run(attempt: id) }
        return true
    }

    public func cancel() {
        guard let attemptId else { return }
        cancel(attemptId: attemptId)
    }

    public func cancel(attemptId id: UUID) {
        guard attemptId == id else { return }
        finish(id, result: .cancelled, state: .signedOut)
    }

    private func armDeadline(_ id: UUID) {
        watchdog?.cancel()
        let end = deadline
        watchdog = Task { [weak self, timer] in
            guard let self else { return }
            do { try await timer(max(end - now(), .zero)) } catch { return }
            guard !Task.isCancelled, attemptId == id, deadline == end else { return }
            finish(id, result: .expired, state: .failed(.expired))
        }
    }

    private func finish(_ id: UUID, result: CloudGatewayMacLoginStatus.Result,
                        state nextState: CloudGatewayMacBrowserAuthState) {
        guard attemptId == id else { return }
        lastStatus = .init(attemptId: id, origin: origin, phase: .finished, result: result)
        let needsSignOut = exchangeStarted
        invalidateAttempt()
        do {
            if needsSignOut { try auth.signOut() }
            else { try auth.cancelCustomTokenSignIn() }
            state = nextState
        } catch {
            lastStatus = .init(attemptId: id, origin: origin, phase: .finished, result: .unavailable)
            state = .failed(.unavailable)
        }
    }

    @discardableResult
    public func signOut() -> Bool {
        lastStatus = nil
        invalidateAttempt()
        state = .signedOut
        do {
            try auth.signOut()
            return true
        } catch {
            state = .failed(.unavailable)
            return false
        }
    }

    private func invalidateAttempt() {
        attemptId = nil
        task?.cancel()
        task = nil
        watchdog?.cancel()
        watchdog = nil
        challenge = nil
    }

    private func run(attempt id: UUID) async {
        do {
            try ensureCurrent(id)
            let secret = try CloudGatewayDeviceSecret()
            let code: CloudGatewayDeviceCode
            var requestStarted: Duration
            while true {
                requestStarted = now()
                do {
                    code = try await service.requestCode(secret: secret)
                    break
                } catch CloudGatewayDeviceAuthError.throttled(let retryAfter) {
                    try ensureCurrent(id)
                    guard retryAfter > 0, retryAfter <= 86_400 else {
                        throw CloudGatewayDeviceAuthError.invalidResponse
                    }
                    try await sleep(min(.seconds(retryAfter), max(deadline - now(), .zero)))
                    try ensureCurrent(id)
                }
            }
            try ensureCurrent(id)
            try validate(code)
            deadline = requestStarted + .seconds(code.expiresIn)
            armDeadline(id)
            guard now() < deadline else { throw CloudGatewayDeviceAuthError.expired }
            challenge = .init(userCode: code.userCode, verificationURL: code.verificationURL, remainingSeconds: code.expiresIn)
            state = .waitingForApproval(userCode: code.userCode, verificationURL: code.verificationURL)
            try ensureCurrent(id)
            if origin == .menu { openURL?(code.verificationURL) }
            var interval = code.interval
            while true {
                let remaining = deadline - now()
                guard remaining > .zero else { throw CloudGatewayDeviceAuthError.expired }
                try await sleep(min(.seconds(interval), remaining))
                try ensureCurrent(id)
                guard now() < deadline else { throw CloudGatewayDeviceAuthError.expired }
                let result: CloudGatewayDeviceTokenResult
                do {
                    result = try await service.pollToken(requestId: code.requestId, secret: secret)
                } catch CloudGatewayDeviceAuthError.throttled(let retryAfter) {
                    try ensureCurrent(id)
                    guard retryAfter > 0, retryAfter <= 86_400 else {
                        throw CloudGatewayDeviceAuthError.invalidResponse
                    }
                    interval = max(interval, retryAfter)
                    continue
                }
                try ensureCurrent(id)
                guard now() < deadline else { throw CloudGatewayDeviceAuthError.expired }
                switch result {
                case .pending(let nextInterval):
                    guard (5...300).contains(nextInterval) else { throw CloudGatewayDeviceAuthError.invalidResponse }
                    interval = max(interval, nextInterval)
                case .approved(let token):
                    guard !token.isEmpty, token.utf8.count <= 16_384 else {
                        throw CloudGatewayDeviceAuthError.invalidResponse
                    }
                    state = .exchangingToken
                    try ensureCurrent(id)
                    exchangeStarted = true
                    let user = try await auth.signIn(customToken: token)
                    try ensureCurrent(id)
                    let isAllowed: Bool
                    do { isAllowed = try await checkAccess(user) }
                    catch CloudGatewayMacInventoryError.offline { throw CloudGatewayDeviceAuthError.offline }
                    try ensureCurrent(id)
                    guard isAllowed else { throw CloudGatewayDeviceAuthError.denied }
                    lastStatus = .init(attemptId: id, origin: origin, phase: .finished, result: .authorized)
                    invalidateAttempt()
                    state = .signedIn(user)
                    return
                }
            }
        } catch {
            guard attemptId == id else { return }
            let failure = (error as? CloudGatewayDeviceAuthError) ?? .unavailable
            let result: CloudGatewayMacLoginStatus.Result = switch failure {
            case .expired: .expired
            case .denied: .denied
            case .invalidResponse, .invalidRequest, .consumed: .invalidResponse
            case .offline: .offline
            default: .unavailable
            }
            finish(id, result: error is CancellationError ? .cancelled : result,
                   state: error is CancellationError ? .signedOut : .failed(failure))
        }
    }

    private func ensureCurrent(_ id: UUID) throws {
        guard attemptId == id, !Task.isCancelled else { throw CancellationError() }
        guard now() < deadline else { throw CloudGatewayDeviceAuthError.expired }
    }

    private func validate(_ code: CloudGatewayDeviceCode) throws {
        let expectedFragment = "/auth/code?deviceRequestId=\(code.requestId)&userCode=\(code.userCode)"
        guard code.requestId.range(of: "^[0-9a-f]{32}$", options: .regularExpression) == code.requestId.startIndex..<code.requestId.endIndex,
              code.userCode.range(of: "^[0-9]{6}$", options: .regularExpression) == code.userCode.startIndex..<code.userCode.endIndex,
              (1...300).contains(code.expiresIn), (5...300).contains(code.interval),
              let origin = URLComponents(url: dashboardOrigin, resolvingAgainstBaseURL: false),
              origin.scheme == "https", origin.host != nil,
              origin.user == nil, origin.password == nil,
              origin.path.isEmpty || origin.path == "/", origin.query == nil, origin.fragment == nil,
              let url = URLComponents(url: code.verificationURL, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host == origin.host,
              (url.port ?? 443) == (origin.port ?? 443), url.user == nil, url.password == nil,
              url.path == "/", url.query == nil, url.fragment == expectedFragment else {
            throw CloudGatewayDeviceAuthError.invalidResponse
        }
    }
}
