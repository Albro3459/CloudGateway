#if os(macOS)
import Foundation
import Testing
@testable import CloudGatewayAppCore

@Test func deviceSecretUsesCanonicalProofAndHash() throws {
    let secret = try CloudGatewayDeviceSecret(bytes: Data(repeating: 0, count: 32))
    #expect(secret.encoded == String(repeating: "A", count: 43))
    #expect(secret.hash == "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925")
    #expect(throws: CloudGatewayDeviceAuthError.invalidResponse) {
        try CloudGatewayDeviceSecret(bytes: Data(repeating: 0, count: 31))
    }
    #expect(try CloudGatewayDeviceSecret().encoded.count == 43)
    let highBytes = try CloudGatewayDeviceSecret(bytes: Data(repeating: 255, count: 32))
    #expect(highBytes.encoded == String(repeating: "_", count: 42) + "8")
    #expect(!highBytes.encoded.contains("="))
    #expect(!highBytes.encoded.contains("/"))
}

@Test func deviceAuthKeepsLeadingZerosAndSecretsOutOfURLs() async throws {
    let session = DeviceAuthTestSession(responses: [
        .init(status: 201, body: deviceCodeJSON()),
        .init(status: 202, body: #"{"state":"pending","interval":5}"#),
        .init(status: 200, body: #"{"customToken":"fixture-token"}"#),
    ])
    let client = makeDeviceAuthClient(session)
    let secret = try CloudGatewayDeviceSecret(bytes: Data(repeating: 0, count: 32))
    let code = try await client.requestCode(secret: secret)
    #expect(code.userCode == "004281")
    #expect(code.expiresIn == 300)
    #expect(try await client.pollToken(requestId: code.requestId, secret: secret) == .pending(interval: 5))
    #expect(try await client.pollToken(requestId: code.requestId, secret: secret) == .approved(customToken: "fixture-token"))
    let requests = await session.requests
    #expect(requests.count == 3)
    #expect(requests[0].url?.absoluteString == "https://api.example.com/api/device/code")
    #expect(requests[1].url?.absoluteString == "https://api.example.com/api/device/token")
    for request in requests {
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Referer") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "CloudGateway-macOS/1.0")
        #expect(request.timeoutInterval == 10)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }
    let codeData = try #require(requests[0].httpBody)
    let codeBody = try #require(JSONSerialization.jsonObject(with: codeData) as? [String: String])
    #expect(codeBody["deviceSecretHash"] == secret.hash)
    #expect(codeBody["deviceSecret"] == nil)
    let pollData = try #require(requests[1].httpBody)
    let pollBody = try #require(JSONSerialization.jsonObject(with: pollData) as? [String: String])
    #expect(pollBody["deviceSecret"] == secret.encoded)
    #expect(pollBody["deviceSecretHash"] == nil)
}

@Test(arguments: [
    "https://evil.example/#/auth/code?deviceRequestId=0123456789abcdef0123456789abcdef&userCode=004281",
    "http://example.com/#/auth/code?deviceRequestId=0123456789abcdef0123456789abcdef&userCode=004281",
    "https://example.com:444/#/auth/code?deviceRequestId=0123456789abcdef0123456789abcdef&userCode=004281",
    "https://user@example.com/#/auth/code?deviceRequestId=0123456789abcdef0123456789abcdef&userCode=004281",
    "https://example.com/?token=unexpected#/auth/code?deviceRequestId=0123456789abcdef0123456789abcdef&userCode=004281",
    "https://example.com/#/auth/code?deviceRequestId=0123456789abcdef0123456789abcdef&userCode=999999",
    "https://example.com/#/auth/code?deviceRequestId=0123456789abcdef0123456789abcdef&userCode=004281&redirect=evil",
    "https://example.com/other#/auth/code?deviceRequestId=0123456789abcdef0123456789abcdef&userCode=004281",
])
func deviceAuthRejectsUnexpectedApprovalURLs(_ completeURL: String) async throws {
    let session = DeviceAuthTestSession(responses: [.init(status: 201, body: deviceCodeJSON(completeURL: completeURL))])
    await #expect(throws: CloudGatewayDeviceAuthError.invalidResponse) {
        try await makeDeviceAuthClient(session).requestCode(secret: CloudGatewayDeviceSecret())
    }
}

@Test(arguments: [
    (400, CloudGatewayDeviceAuthError.invalidRequest),
    (403, CloudGatewayDeviceAuthError.denied),
    (409, CloudGatewayDeviceAuthError.consumed),
    (410, CloudGatewayDeviceAuthError.expired),
    (503, CloudGatewayDeviceAuthError.unavailable),
])
func deviceAuthMapsTerminalStatuses(_ status: Int, _ expected: CloudGatewayDeviceAuthError) async throws {
    let session = DeviceAuthTestSession(responses: [.init(status: status, body: "sensitive-server-error")])
    await #expect(throws: expected) {
        try await makeDeviceAuthClient(session).pollToken(
            requestId: "0123456789abcdef0123456789abcdef",
            secret: CloudGatewayDeviceSecret()
        )
    }
    #expect(!(expected.errorDescription ?? "").contains("sensitive"))
}

@Test func deviceAuthHonorsRetryAfterAndRejectsMalformedResponses() async throws {
    let secret = try CloudGatewayDeviceSecret()
    let throttled = DeviceAuthTestSession(responses: [.init(status: 429, body: "{}", headers: ["Retry-After": "12"])])
    await #expect(throws: CloudGatewayDeviceAuthError.throttled(retryAfter: 12)) {
        try await makeDeviceAuthClient(throttled).pollToken(requestId: "0123456789abcdef0123456789abcdef", secret: secret)
    }
    for response in [
        DeviceAuthTestSession.Response(status: 429, body: "{}", headers: ["Retry-After": "-1"]),
        .init(status: 429, body: "{}"),
        .init(status: 200, body: #"{"customToken":""}"#),
        .init(status: 202, body: #"{"state":"denied","interval":5}"#),
        .init(status: 202, body: #"{"state":"pending","interval":0}"#),
        .init(status: 200, body: String(repeating: "x", count: 32_769)),
        .init(status: 200, body: #"{"customToken":"token"}"#, url: URL(string: "https://evil.example/api/device/token")),
    ] {
        let session = DeviceAuthTestSession(responses: [response])
        await #expect(throws: CloudGatewayDeviceAuthError.invalidResponse) {
            try await makeDeviceAuthClient(session).pollToken(requestId: "0123456789abcdef0123456789abcdef", secret: secret)
        }
    }
}

@Test func deviceAuthDoesNotSendMalformedRequestIds() async throws {
    let session = DeviceAuthTestSession(responses: [])
    await #expect(throws: CloudGatewayDeviceAuthError.invalidRequest) {
        try await makeDeviceAuthClient(session).pollToken(requestId: "invalid", secret: CloudGatewayDeviceSecret())
    }
    #expect(await session.requests.isEmpty)
}

private func makeDeviceAuthClient(_ session: DeviceAuthTestSession) -> CloudGatewayDeviceAuthClient {
    CloudGatewayDeviceAuthClient(originHost: "example.com", dashboardOrigin: URL(string: "https://example.com")!, session: session)
}

private func deviceCodeJSON(completeURL: String? = nil) -> String {
    let complete = completeURL ?? "https://example.com/#/auth/code?deviceRequestId=0123456789abcdef0123456789abcdef&userCode=004281"
    return """
    {"deviceRequestId":"0123456789abcdef0123456789abcdef","userCode":"004281","verificationUri":"https://example.com/#/auth/code","verificationUriComplete":"\(complete)","expiresIn":300,"interval":5}
    """
}

private actor DeviceAuthTestSession: CloudGatewayControlPlaneSession {
    struct Response: Sendable {
        let status: Int
        let body: String
        var headers: [String: String] = [:]
        var url: URL?
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw CloudGatewayDeviceAuthError.unavailable }
        let response = responses.removeFirst()
        let url = try #require(response.url ?? request.url)
        return (Data(response.body.utf8), try #require(HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: response.headers
        )))
    }
}
#endif
