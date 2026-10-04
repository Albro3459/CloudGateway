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
    private let openURL: (URL) -> Void
    private let checkAccess: (AuthenticatedUser) async throws -> Bool
    private let now: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var attemptId: UUID?
    private var task: Task<Void, Never>?

    public init(
        service: any CloudGatewayDeviceAuthServicing,
        auth: any CloudGatewayCustomTokenAuthServicing,
        dashboardOrigin: URL,
        openBrowser: @escaping (URL) -> Void,
        checkAccess: @escaping (AuthenticatedUser) async throws -> Bool
    ) {
        self.service = service
        self.auth = auth
        self.dashboardOrigin = dashboardOrigin
        openURL = openBrowser
        self.checkAccess = checkAccess
        let clock = ContinuousClock()
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { try await Task.sleep(for: $0) }
    }

    // periphery:ignore - Injected monotonic time supports host-free polling tests
    init(
        service: any CloudGatewayDeviceAuthServicing,
        auth: any CloudGatewayCustomTokenAuthServicing,
        dashboardOrigin: URL,
        openBrowser: @escaping (URL) -> Void,
        checkAccess: @escaping (AuthenticatedUser) async throws -> Bool,
        now: @escaping @Sendable () -> Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.service = service
        self.auth = auth
        self.dashboardOrigin = dashboardOrigin
        openURL = openBrowser
        self.checkAccess = checkAccess
        self.now = now
        self.sleep = sleep
    }

    @discardableResult
    public func begin() -> Bool {
        guard attemptId == nil, auth.currentUser == nil, !auth.isCustomTokenSignInSettling else { return false }
        let id = UUID()
        attemptId = id
        state = .requestingCode
        task = Task { [weak self] in await self?.run(attempt: id) }
        return true
    }

    public func openBrowser() {
        guard case .waitingForApproval(_, let url) = state else { return }
        openURL(url)
    }

    public func cancel() {
        guard attemptId != nil else { return }
        let wasExchanging = state == .exchangingToken
        invalidateAttempt()
        do {
            if wasExchanging { try auth.signOut() }
            else { try auth.cancelCustomTokenSignIn() }
            state = .signedOut
        } catch { state = .failed(.unavailable) }
    }

    public func signOut() {
        invalidateAttempt()
        state = .signedOut
        do { try auth.signOut() }
        catch { state = .failed(.unavailable) }
    }

    private func invalidateAttempt() {
        attemptId = nil
        task?.cancel()
        task = nil
    }

    private func run(attempt id: UUID) async {
        var exchangeStarted = false
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
                    try await sleep(.seconds(retryAfter))
                    try ensureCurrent(id)
                }
            }
            try ensureCurrent(id)
            try validate(code)
            let deadline = requestStarted + .seconds(code.expiresIn)
            guard now() < deadline else { throw CloudGatewayDeviceAuthError.expired }
            state = .waitingForApproval(userCode: code.userCode, verificationURL: code.verificationURL)
            try ensureCurrent(id)
            openURL(code.verificationURL)
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
                    let isAllowed = try await checkAccess(user)
                    try ensureCurrent(id)
                    guard isAllowed else { throw CloudGatewayDeviceAuthError.denied }
                    attemptId = nil
                    task = nil
                    state = .signedIn(user)
                    return
                }
            }
        } catch {
            guard attemptId == id else { return }
            attemptId = nil
            task = nil
            if exchangeStarted {
                do { try auth.signOut() }
                catch { state = .failed(.unavailable); return }
            }
            if error is CancellationError { state = .signedOut }
            else { state = .failed((error as? CloudGatewayDeviceAuthError) ?? .unavailable) }
        }
    }

    private func ensureCurrent(_ id: UUID) throws {
        guard attemptId == id, !Task.isCancelled else { throw CancellationError() }
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
