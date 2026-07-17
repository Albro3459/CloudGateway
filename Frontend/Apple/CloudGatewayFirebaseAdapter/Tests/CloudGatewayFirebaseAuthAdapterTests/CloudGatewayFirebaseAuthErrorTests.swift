import CloudGatewayAppCore
import Testing
@testable import CloudGatewayFirebaseAuthAdapter

@Test func firebaseSignInErrorCodesPreserveDomainMessages() {
    #expect(errorDescription(17004) == "Invalid email or password.")
    #expect(errorDescription(17009) == "Invalid email or password.")
    #expect(errorDescription(17011) == "Invalid email or password.")
    #expect(errorDescription(17008) == "Enter a valid email address.")
    #expect(errorDescription(17005) == "This account has been disabled. Contact support.")
    #expect(CloudGatewayFirebaseAuthAdapter.signInError(forRawCode: -1) == nil)
}

@Test func firebaseLinkAndReauthenticationCodesPreserveDomainMessages() {
    let expected: [Int: String] = [
        17014: "Sign in again before linking another sign-in method.",
        17025: "That sign-in method is already used by another CloudGateway account. Sign in with that account directly or contact support.",
        17007: "That sign-in method is already used by another CloudGateway account. Sign in with that account directly or contact support.",
        17015: "That sign-in method is already linked to this account.",
        17008: "Enter a valid email address.",
        17026: "Enter a stronger password.",
        17009: "The current password is incorrect.",
        17004: "The current password is incorrect.",
    ]
    for (code, description) in expected {
        #expect(CloudGatewayFirebaseAuthAdapter.authError(forRawCode: code)?.localizedDescription == description)
    }
    #expect(CloudGatewayFirebaseAuthAdapter.authError(forRawCode: -1) == nil)
}

private func errorDescription(_ code: Int) -> String? {
    CloudGatewayFirebaseAuthAdapter.signInError(forRawCode: code)?.localizedDescription
}
