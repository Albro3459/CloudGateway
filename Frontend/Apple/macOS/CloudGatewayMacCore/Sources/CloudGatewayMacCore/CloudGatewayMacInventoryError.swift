import Foundation

public struct CloudGatewayMacInventoryDiagnostic: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case accessToken, accessRequest, accessResponse, regions, clients, removalToken, connection
    }

    public enum Source: String, Codable, Sendable {
        case url, firestore, auth, http, deadline, invalidResponse, other
    }

    public let stage: Stage
    public let source: Source
    public let code: Int?

    public init(stage: Stage, source: Source, code: Int? = nil) {
        self.stage = stage
        self.source = source
        self.code = code
    }

    public init?(stage: Stage, error: Error) {
        guard !(error is CancellationError) else { return nil }
        let error = error as NSError
        let source: Source = switch error.domain {
        case NSURLErrorDomain: .url
        case "FIRFirestoreErrorDomain": .firestore
        case "FIRAuthErrorDomain": .auth
        default: .other
        }
        self.init(stage: stage, source: source, code: source == .other ? nil : error.code)
    }

    public var summary: String {
        "\(stage.rawValue): \(source.rawValue)\(code.map { " (\($0))" } ?? "")"
    }
}

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
