import CloudGatewayAppCore
import FirebaseAuth
import Foundation

@MainActor
public final class CloudGatewayFirebaseAuthAdapter: CloudGatewayAuthServicing {
    private let auth: Auth

    public init() {
        auth = Auth.auth()
    }

    public var currentUser: AuthenticatedUser? {
        auth.currentUser.map(Self.user)
    }

    public func addAuthStateListener(
        _ listener: @escaping (AuthenticatedUser?) -> Void
    ) -> CloudGatewayAuthStateListenerRegistration {
        let handle = auth.addStateDidChangeListener { _, user in
            listener(user.map(Self.user))
        }
        return CloudGatewayAuthStateListenerRegistration { [auth] in
            auth.removeStateDidChangeListener(handle)
        }
    }

    public func signIn(email: String, password: String) async throws -> AuthenticatedUser {
        try await withCheckedThrowingContinuation { continuation in
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
        let credential = GoogleAuthProvider.credential(
            withIDToken: credentials.idToken,
            accessToken: credentials.accessToken
        )
        return Self.user(try await auth.signIn(with: credential).user)
    }

    public func providerIds() -> [String] {
        auth.currentUser?.providerData.map(\.providerID) ?? []
    }

    public func linkEmailPassword(email: String, password: String) async throws -> AuthenticatedUser {
        guard let user = auth.currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        do {
            return Self.user(try await user.link(with: credential).user)
        } catch {
            throw Self.mapAuthError(error)
        }
    }

    public func linkApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser {
        guard let user = auth.currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        let credential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: rawNonce,
            fullName: nil
        )
        do {
            return Self.user(try await user.link(with: credential).user)
        } catch {
            throw Self.mapAuthError(error)
        }
    }

    public func linkGoogle(
        credentials: CloudGatewayGoogleCredentials
    ) async throws -> AuthenticatedUser {
        guard let user = auth.currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        let credential = GoogleAuthProvider.credential(
            withIDToken: credentials.idToken,
            accessToken: credentials.accessToken
        )
        do {
            return Self.user(try await user.link(with: credential).user)
        } catch {
            throw Self.mapAuthError(error)
        }
    }

    public func reauthenticateWithPassword(_ password: String) async throws {
        guard let user = auth.currentUser,
              let email = user.email else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        _ = try await user.reauthenticate(with: credential)
    }

    public func reauthenticateWithApple(
        idToken: String,
        rawNonce: String,
        authorizationCode: String,
        revoke: Bool
    ) async throws {
        guard let user = auth.currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        let credential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: rawNonce,
            fullName: nil
        )
        _ = try await user.reauthenticate(with: credential)
        if revoke {
            try await auth.revokeToken(withAuthorizationCode: authorizationCode)
        }
    }

    public func reauthenticateWithGoogle(credentials: CloudGatewayGoogleCredentials) async throws {
        guard let user = auth.currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        let credential = GoogleAuthProvider.credential(
            withIDToken: credentials.idToken,
            accessToken: credentials.accessToken
        )
        _ = try await user.reauthenticate(with: credential)
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
        try auth.signOut()
    }

    public func idToken(forceRefresh: Bool) async throws -> String {
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
