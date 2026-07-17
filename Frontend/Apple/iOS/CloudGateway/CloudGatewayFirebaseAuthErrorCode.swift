import CloudGatewayAppCore

enum CloudGatewayFirebaseAuthErrorCode {
    static func signInError(forRawCode code: Int) -> CloudGatewayAppError? {
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
}
