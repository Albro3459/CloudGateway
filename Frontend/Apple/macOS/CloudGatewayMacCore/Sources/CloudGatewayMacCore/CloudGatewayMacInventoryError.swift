import Foundation

public enum CloudGatewayMacInventoryError: Error, Equatable, Sendable {
    case accessDenied
    case offline
    case unavailable

    public var cacheFailure: CloudGatewayMacInventoryFailure {
        switch self {
        case .accessDenied: .accessDenied
        case .offline: .transport
        case .unavailable: .invalidResponse
        }
    }

    public static func accessResponseFailure(statusCode: Int) -> Self? {
        switch statusCode {
        case 200: nil
        case 401, 403: .accessDenied
        default: .unavailable
        }
    }

    public static func classify(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let failure = error as? Self { return failure }
        let error = error as NSError
        if error.domain == "FIRFirestoreErrorDomain" {
            if error.code == 7 || error.code == 16 { return Self.accessDenied }
            if error.code == 4 || error.code == 14 { return Self.offline }
        }
        if error.domain == "FIRAuthErrorDomain" {
            if [17005, 17011, 17017, 17021, 17020].contains(error.code) {
                return error.code == 17020 ? Self.offline : Self.accessDenied
            }
        }
        if error.domain == NSURLErrorDomain,
           [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed].contains(error.code) { return Self.offline }
        return Self.unavailable
    }
}
