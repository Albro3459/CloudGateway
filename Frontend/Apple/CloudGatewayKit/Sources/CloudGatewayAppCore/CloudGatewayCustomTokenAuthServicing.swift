#if os(macOS)
import Foundation

@MainActor
public protocol CloudGatewayCustomTokenAuthServicing: AnyObject {
    var currentUser: AuthenticatedUser? { get }
    var isCustomTokenSignInSettling: Bool { get }
    func signIn(customToken: String) async throws -> AuthenticatedUser
    func cancelCustomTokenSignIn() throws
    func signOut() throws
}
#endif
