#if os(macOS)
import CryptoKit
import Foundation
import Security

public struct CloudGatewayDeviceSecret: Sendable {
    private let bytes: Data

    public init() throws {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw CloudGatewayDeviceAuthError.unavailable }
        self.bytes = bytes
    }

    // periphery:ignore - Deterministic bytes verify device-secret encoding in host-free tests
    init(bytes: Data) throws {
        guard bytes.count == 32 else { throw CloudGatewayDeviceAuthError.invalidResponse }
        self.bytes = bytes
    }

    public var hash: String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public var encoded: String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct CloudGatewayDeviceCode: Equatable, Sendable {
    public let requestId: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresIn: Int
    public let interval: Int

    public init(requestId: String, userCode: String, verificationURL: URL, expiresIn: Int, interval: Int) {
        self.requestId = requestId
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

public enum CloudGatewayDeviceTokenResult: Equatable, Sendable {
    case pending(interval: Int)
    case approved(customToken: String)
}

public enum CloudGatewayDeviceAuthError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case denied
    case expired
    case consumed
    case invalidRequest
    case throttled(retryAfter: Int)
    case offline
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "CloudGateway returned an invalid sign-in response. Start sign-in again."
        case .denied: "Sign-in was denied in the browser."
        case .expired: "The sign-in code expired. Start sign-in again."
        case .consumed: "This sign-in request was already used. Start sign-in again."
        case .invalidRequest: "This sign-in request is invalid. Start sign-in again."
        case .throttled: "Sign-in is temporarily limited. Wait before trying again."
        case .offline: "Sign-in was interrupted by a network failure. Start sign-in again when online."
        case .unavailable: "Sign-in is unavailable. Start sign-in again later."
        }
    }
}

public protocol CloudGatewayDeviceAuthServicing: Sendable {
    func requestCode(secret: CloudGatewayDeviceSecret) async throws -> CloudGatewayDeviceCode
    func pollToken(requestId: String, secret: CloudGatewayDeviceSecret) async throws -> CloudGatewayDeviceTokenResult
}

public final class CloudGatewayDeviceAuthClient: CloudGatewayDeviceAuthServicing {
    private let originHost: String
    private let dashboardOrigin: URL
    private let session: any CloudGatewayControlPlaneSession

    public init(
        originHost: String,
        dashboardOrigin: URL,
        session: (any CloudGatewayControlPlaneSession)? = nil
    ) {
        self.originHost = originHost
        self.dashboardOrigin = dashboardOrigin
        self.session = session ?? Self.makeSession()
    }

    public func requestCode(secret: CloudGatewayDeviceSecret) async throws -> CloudGatewayDeviceCode {
        let (data, response) = try await send(path: "device/code", body: CodeRequest(
            deviceSecretHash: secret.hash,
            deviceName: "CloudGateway for macOS"
        ))
        try checkStatus(response, expected: [201])
        let code: CodeResponse = try decode(data)
        guard Self.matches(code.deviceRequestId, pattern: "^[0-9a-f]{32}$"),
              Self.matches(code.userCode, pattern: "^[0-9]{6}$"),
              (1...300).contains(code.expiresIn),
              (5...300).contains(code.interval),
              let completeURL = URL(string: code.verificationUriComplete),
              let baseURL = URL(string: code.verificationUri),
              Self.isApprovalURL(baseURL, dashboardOrigin: dashboardOrigin, fragment: "/auth/code"),
              Self.isApprovalURL(
                completeURL,
                dashboardOrigin: dashboardOrigin,
                fragment: "/auth/code?deviceRequestId=\(code.deviceRequestId)&userCode=\(code.userCode)"
              ) else {
            throw CloudGatewayDeviceAuthError.invalidResponse
        }
        return CloudGatewayDeviceCode(
            requestId: code.deviceRequestId,
            userCode: code.userCode,
            verificationURL: completeURL,
            expiresIn: code.expiresIn,
            interval: code.interval
        )
    }

    public func pollToken(
        requestId: String,
        secret: CloudGatewayDeviceSecret
    ) async throws -> CloudGatewayDeviceTokenResult {
        guard Self.matches(requestId, pattern: "^[0-9a-f]{32}$") else {
            throw CloudGatewayDeviceAuthError.invalidRequest
        }
        let (data, response) = try await send(path: "device/token", body: TokenRequest(
            deviceRequestId: requestId,
            deviceSecret: secret.encoded
        ))
        try checkStatus(response, expected: [200, 202])
        if response.statusCode == 202 {
            let pending: PendingResponse = try decode(data)
            guard pending.state == "pending", (5...300).contains(pending.interval) else {
                throw CloudGatewayDeviceAuthError.invalidResponse
            }
            return .pending(interval: pending.interval)
        }
        let approved: TokenResponse = try decode(data)
        guard !approved.customToken.isEmpty, approved.customToken.utf8.count <= 16_384 else {
            throw CloudGatewayDeviceAuthError.invalidResponse
        }
        return .approved(customToken: approved.customToken)
    }

    private func send<Body: Encodable>(
        path: String,
        body: Body
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try CloudGatewayAPIURLBuilder.apexAPIURL(originHost: originHost, path: path)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.timeoutInterval = CloudGatewayAPISession.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("CloudGateway-macOS/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw CloudGatewayDeviceAuthError.offline
        } catch {
            throw CloudGatewayDeviceAuthError.unavailable
        }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              response.url == url,
              data.count <= 32_768 else {
            throw CloudGatewayDeviceAuthError.invalidResponse
        }
        return (data, response)
    }

    private func checkStatus(_ response: HTTPURLResponse, expected: Set<Int>) throws {
        guard !expected.contains(response.statusCode) else { return }
        switch response.statusCode {
        case 400: throw CloudGatewayDeviceAuthError.invalidRequest
        case 403: throw CloudGatewayDeviceAuthError.denied
        case 409: throw CloudGatewayDeviceAuthError.consumed
        case 410: throw CloudGatewayDeviceAuthError.expired
        case 429:
            guard let value = response.value(forHTTPHeaderField: "Retry-After"),
                  let interval = Int(value), interval > 0, interval <= 86_400 else {
                throw CloudGatewayDeviceAuthError.invalidResponse
            }
            throw CloudGatewayDeviceAuthError.throttled(retryAfter: interval)
        default: throw CloudGatewayDeviceAuthError.unavailable
        }
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw CloudGatewayDeviceAuthError.invalidResponse }
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }

    private static func isApprovalURL(_ url: URL, dashboardOrigin: URL, fragment: String) -> Bool {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let origin = URLComponents(url: dashboardOrigin, resolvingAgainstBaseURL: false),
              origin.scheme == "https", origin.host != nil,
              origin.user == nil, origin.password == nil,
              origin.path.isEmpty || origin.path == "/",
              origin.query == nil, origin.fragment == nil else { return false }
        return value.scheme == "https" && value.host == origin.host &&
            (value.port ?? 443) == (origin.port ?? 443) &&
            value.user == nil && value.password == nil &&
            value.path == "/" && value.query == nil && value.fragment == fragment
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = CloudGatewayAPISession.requestTimeout
        configuration.timeoutIntervalForResource = CloudGatewayAPISession.requestTimeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    private struct CodeRequest: Encodable {
        let deviceSecretHash: String
        let deviceName: String
    }

    private struct TokenRequest: Encodable {
        let deviceRequestId: String
        let deviceSecret: String
    }

    private struct CodeResponse: Decodable {
        let deviceRequestId: String
        let userCode: String
        let verificationUri: String
        let verificationUriComplete: String
        let expiresIn: Int
        let interval: Int
    }

    private struct PendingResponse: Decodable {
        let state: String
        let interval: Int
    }

    private struct TokenResponse: Decodable {
        let customToken: String
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
#endif
