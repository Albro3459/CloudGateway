import CloudGatewayAppCore
import FirebaseAuth
import Foundation

@MainActor
public final class CloudGatewayFirebaseAuthAdapter: CloudGatewayAuthServicing {
    private let auth: Auth
    #if os(macOS)
    private lazy var customTokenSession = CloudGatewayFirebaseCustomTokenSession(
        backend: FirebaseCustomTokenBackend(auth: auth), marker: CloudGatewayFirebaseDefaultsExchangeMarker()
    )
    private var customTokenListeners = [UUID: (AuthenticatedUser?) -> Void]()
    #endif

    public init() {
        auth = Auth.auth()
    }

    public var currentUser: AuthenticatedUser? {
        #if os(macOS)
        customTokenSession.currentUser
        #else
        auth.currentUser.map(Self.user)
        #endif
    }

    #if os(macOS)
    public var isCustomTokenSignInSettling: Bool { customTokenSession.isSettling }
    #endif

    public func addAuthStateListener(
        _ listener: @escaping (AuthenticatedUser?) -> Void
    ) -> CloudGatewayAuthStateListenerRegistration {
        #if os(macOS)
        let id = UUID()
        customTokenListeners[id] = listener
        let handle = auth.addStateDidChangeListener { [weak self] _, _ in
            guard let self else { return }
            listener(self.currentUser)
        }
        return CloudGatewayAuthStateListenerRegistration { [weak self, auth] in
            auth.removeStateDidChangeListener(handle)
            self?.customTokenListeners.removeValue(forKey: id)
        }
        #else
        let handle = auth.addStateDidChangeListener { _, user in
            listener(user.map(Self.user))
        }
        return CloudGatewayAuthStateListenerRegistration { [auth] in
            auth.removeStateDidChangeListener(handle)
        }
        #endif
    }

    #if os(macOS)
    public func signIn(customToken: String) async throws -> AuthenticatedUser {
        defer { notifyCustomTokenListeners() }
        return try await customTokenSession.signIn(customToken: customToken)
    }

    public func cancelCustomTokenSignIn() throws {
        defer { notifyCustomTokenListeners() }
        try customTokenSession.cancel()
    }

    private func notifyCustomTokenListeners() {
        for listener in customTokenListeners.values { listener(currentUser) }
    }
    #endif

    public func signIn(email: String, password: String) async throws -> AuthenticatedUser {
        #if os(macOS)
        guard !customTokenSession.isSettling else { throw CloudGatewayDeviceAuthError.unavailable }
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            auth.signIn(withEmail: email, password: password) { result, error in
                if let error {
                    continuation.resume(throwing: Self.mapSignInError(error))
                    return
                }
                guard let user = result?.user else {
                    continuation.resume(throwing: CloudGatewayAppError.missingCurrentUser)
                    return
                }
                continuation.resume(returning: Self.user(user))
            }
        }
    }

    public func signInWithApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser {
        #if os(macOS)
        guard !customTokenSession.isSettling else { throw CloudGatewayDeviceAuthError.unavailable }
        #endif
        let credential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: rawNonce,
            fullName: nil
        )
        return Self.user(try await auth.signIn(with: credential).user)
    }

    public func signInWithGoogle(
        credentials: CloudGatewayGoogleCredentials
    ) async throws -> AuthenticatedUser {
        #if os(macOS)
        guard !customTokenSession.isSettling else { throw CloudGatewayDeviceAuthError.unavailable }
        #endif
        let credential = GoogleAuthProvider.credential(
            withIDToken: credentials.idToken,
            accessToken: credentials.accessToken
        )
        return Self.user(try await auth.signIn(with: credential).user)
    }

    public func providerIds() -> [String] {
        #if os(macOS)
        guard currentUser != nil else { return [] }
        #endif
        return auth.currentUser?.providerData.map(\.providerID) ?? []
    }

    public func linkEmailPassword(
        email: String,
        password: String,
        expectedUserId: String
    ) async throws -> AuthenticatedUser {
        try await Self.guardedLinkEmailPassword(
            currentUser: currentGuardedUser(),
            email: email,
            password: password,
            expectedUserId: expectedUserId
        )
    }

    public func linkApple(
        idToken: String,
        rawNonce: String,
        expectedUserId: String
    ) async throws -> AuthenticatedUser {
        try await Self.guardedLinkApple(
            currentUser: currentGuardedUser(),
            idToken: idToken,
            rawNonce: rawNonce,
            expectedUserId: expectedUserId
        )
    }

    public func linkGoogle(
        credentials: CloudGatewayGoogleCredentials,
        expectedUserId: String
    ) async throws -> AuthenticatedUser {
        try await Self.guardedLinkGoogle(
            currentUser: currentGuardedUser(),
            credentials: credentials,
            expectedUserId: expectedUserId
        )
    }

    public func reauthenticateWithPassword(_ password: String, expectedUserId: String) async throws {
        try await Self.guardedReauthenticatePassword(
            currentUser: currentGuardedUser(),
            password: password,
            expectedUserId: expectedUserId
        )
    }

    public func reauthenticateWithApple(
        idToken: String,
        rawNonce: String,
        authorizationCode: String,
        revoke: Bool,
        expectedUserId: String
    ) async throws {
        try await Self.guardedReauthenticateApple(
            currentUser: currentGuardedUser(),
            idToken: idToken,
            rawNonce: rawNonce,
            expectedUserId: expectedUserId
        )
        if revoke {
            try await auth.revokeToken(withAuthorizationCode: authorizationCode)
        }
    }

    public func reauthenticateWithGoogle(
        credentials: CloudGatewayGoogleCredentials,
        expectedUserId: String
    ) async throws {
        try await Self.guardedReauthenticateGoogle(
            currentUser: currentGuardedUser(),
            credentials: credentials,
            expectedUserId: expectedUserId
        )
    }

    public func sendPasswordReset(email: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            auth.sendPasswordReset(withEmail: email) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func signOut() throws {
        #if os(macOS)
        defer { notifyCustomTokenListeners() }
        try customTokenSession.signOut()
        #else
        try auth.signOut()
        #endif
    }

    public func idToken(forceRefresh: Bool) async throws -> String {
        #if os(macOS)
        guard currentUser != nil else { throw CloudGatewayAppError.missingCurrentUser }
        #endif
        guard let user = auth.currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        return try await withCheckedThrowingContinuation { continuation in
            user.getIDTokenForcingRefresh(forceRefresh) { token, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let token else {
                    continuation.resume(throwing: CloudGatewayAppError.missingCurrentUser)
                    return
                }
                continuation.resume(returning: token)
            }
        }
    }

    // Mid-flight user-swap guard, factored out of the link/reauth methods so it can
    // be unit-tested without a live `FirebaseAuth.Auth`. A swapped `uid` throws
    // before any link/reauth credential call runs; a nil user reports the standard
    // domain error.
    static func guardedLinkEmailPassword(
        currentUser: CloudGatewayFirebaseGuardedUser?,
        email: String,
        password: String,
        expectedUserId: String
    ) async throws -> AuthenticatedUser {
        guard let currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        guard currentUser.uid == expectedUserId else { throw CancellationError() }
        do {
            return try await currentUser.linkEmailPassword(email: email, password: password)
        } catch {
            throw mapAuthError(error)
        }
    }

    static func guardedLinkApple(
        currentUser: CloudGatewayFirebaseGuardedUser?,
        idToken: String,
        rawNonce: String,
        expectedUserId: String
    ) async throws -> AuthenticatedUser {
        guard let currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        guard currentUser.uid == expectedUserId else { throw CancellationError() }
        do {
            return try await currentUser.linkApple(idToken: idToken, rawNonce: rawNonce)
        } catch {
            throw mapAuthError(error)
        }
    }

    static func guardedReauthenticatePassword(
        currentUser: CloudGatewayFirebaseGuardedUser?,
        password: String,
        expectedUserId: String
    ) async throws {
        guard let currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        guard currentUser.uid == expectedUserId else { throw CancellationError() }
        try await currentUser.reauthenticatePassword(password)
    }

    static func guardedReauthenticateApple(
        currentUser: CloudGatewayFirebaseGuardedUser?,
        idToken: String,
        rawNonce: String,
        expectedUserId: String
    ) async throws {
        guard let currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        guard currentUser.uid == expectedUserId else { throw CancellationError() }
        try await currentUser.reauthenticateApple(idToken: idToken, rawNonce: rawNonce)
    }

    static func guardedLinkGoogle(
        currentUser: CloudGatewayFirebaseGuardedUser?,
        credentials: CloudGatewayGoogleCredentials,
        expectedUserId: String
    ) async throws -> AuthenticatedUser {
        guard let currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        guard currentUser.uid == expectedUserId else { throw CancellationError() }
        do {
            return try await currentUser.linkGoogle(credentials)
        } catch {
            throw mapAuthError(error)
        }
    }

    static func guardedReauthenticateGoogle(
        currentUser: CloudGatewayFirebaseGuardedUser?,
        credentials: CloudGatewayGoogleCredentials,
        expectedUserId: String
    ) async throws {
        guard let currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        guard currentUser.uid == expectedUserId else { throw CancellationError() }
        try await currentUser.reauthenticateGoogle(credentials)
    }

    private func currentGuardedUser() -> CloudGatewayFirebaseGuardedUser? {
        #if os(macOS)
        guard currentUser != nil else { return nil }
        #endif
        return auth.currentUser.map(FirebaseGuardedUser.init)
    }

    private struct FirebaseGuardedUser: CloudGatewayFirebaseGuardedUser {
        let user: User

        var uid: String { user.uid }

        func linkGoogle(_ credentials: CloudGatewayGoogleCredentials) async throws -> AuthenticatedUser {
            let credential = GoogleAuthProvider.credential(
                withIDToken: credentials.idToken,
                accessToken: credentials.accessToken
            )
            return CloudGatewayFirebaseAuthAdapter.user(try await user.link(with: credential).user)
        }

        func reauthenticateGoogle(_ credentials: CloudGatewayGoogleCredentials) async throws {
            let credential = GoogleAuthProvider.credential(
                withIDToken: credentials.idToken,
                accessToken: credentials.accessToken
            )
            _ = try await user.reauthenticate(with: credential)
        }

        func linkEmailPassword(email: String, password: String) async throws -> AuthenticatedUser {
            let credential = EmailAuthProvider.credential(withEmail: email, password: password)
            return CloudGatewayFirebaseAuthAdapter.user(try await user.link(with: credential).user)
        }

        func linkApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser {
            let credential = OAuthProvider.appleCredential(
                withIDToken: idToken,
                rawNonce: rawNonce,
                fullName: nil
            )
            return CloudGatewayFirebaseAuthAdapter.user(try await user.link(with: credential).user)
        }

        func reauthenticatePassword(_ password: String) async throws {
            guard let email = user.email else {
                throw CloudGatewayAppError.missingCurrentUser
            }
            let credential = EmailAuthProvider.credential(withEmail: email, password: password)
            _ = try await user.reauthenticate(with: credential)
        }

        func reauthenticateApple(idToken: String, rawNonce: String) async throws {
            let credential = OAuthProvider.appleCredential(
                withIDToken: idToken,
                rawNonce: rawNonce,
                fullName: nil
            )
            _ = try await user.reauthenticate(with: credential)
        }
    }

    nonisolated static func signInError(forRawCode code: Int) -> CloudGatewayAppError? {
        switch code {
        case 17008:
            return .invalidEmail
        case 17004, 17009, 17011:
            return .invalidSignInCredentials
        case 17005:
            return .accessDenied("This account has been disabled. Contact support.")
        default:
            return nil
        }
    }

    nonisolated static func authError(forRawCode code: Int) -> CloudGatewayAppError? {
        switch code {
        case 17014:
            return .requiresRecentLogin
        case 17025, 17007:
            return .credentialAlreadyInUse
        case 17015:
            return .providerAlreadyLinked
        case 17008:
            return .invalidEmail
        case 17026:
            return .weakPassword
        case 17009, 17004:
            return .wrongPassword
        default:
            return nil
        }
    }

    private static func user(_ user: User) -> AuthenticatedUser {
        AuthenticatedUser(uid: user.uid, email: user.email)
    }

    #if os(macOS)
    private struct FirebaseCustomTokenBackend: CloudGatewayFirebaseCustomTokenBackend {
        let auth: Auth

        var currentUser: AuthenticatedUser? { auth.currentUser.map(CloudGatewayFirebaseAuthAdapter.user) }

        func signIn(customToken: String) async throws -> AuthenticatedUser {
            CloudGatewayFirebaseAuthAdapter.user(try await auth.signIn(withCustomToken: customToken).user)
        }

        func signOut() throws { try auth.signOut() }
    }
    #endif

    private static func mapAuthError(_ error: Error) -> Error {
        authError(forRawCode: rawCode(for: error)) ?? error
    }

    private static func mapSignInError(_ error: Error) -> Error {
        signInError(forRawCode: rawCode(for: error)) ?? error
    }

    private static func rawCode(for error: Error) -> Int {
        let nsError = error as NSError
        return AuthErrorCode(_bridgedNSError: nsError)?.code.rawValue ?? nsError.code
    }
}

#if os(macOS)
extension CloudGatewayFirebaseAuthAdapter: CloudGatewayCustomTokenAuthServicing {}
#endif

// Seam over the signed-in Firebase user used only by the Google link/reauth
// guard. Production wraps `FirebaseAuth.User`; tests inject a fake so the guard
// runs without configuring Firebase.
@MainActor
protocol CloudGatewayFirebaseGuardedUser {
    var uid: String { get }
    func linkGoogle(_ credentials: CloudGatewayGoogleCredentials) async throws -> AuthenticatedUser
    func reauthenticateGoogle(_ credentials: CloudGatewayGoogleCredentials) async throws
    func linkEmailPassword(email: String, password: String) async throws -> AuthenticatedUser
    func linkApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser
    func reauthenticatePassword(_ password: String) async throws
    func reauthenticateApple(idToken: String, rawNonce: String) async throws
}
