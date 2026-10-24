import CloudGatewayAppCore
import Foundation
import Testing
@testable import CloudGatewayMacCore

@Test @MainActor func clientRemovalSendsOneRegionalDeleteWithTheCapturedOwner() async throws {
    let fixture = ClientRemovalFixture()
    let response = try await fixture.perform()
    #expect(response.userId == "user-a")
    #expect(response.regionId == "region")
    #expect(response.clientId == "client")
    #expect(response.status == .removed)
    #expect(fixture.events == ["token", "authorize", "dispatch"])
    #expect(fixture.session.requests.count == 1)
    let request = try #require(fixture.session.requests.first)
    #expect(request.httpMethod == "DELETE")
    #expect(request.url?.absoluteString == "https://region.gocloudlaunch.com/api/clients/client")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
    #expect(body == ["userId": "user-a", "regionId": "region"])
}

@Test(arguments: [false, true]) @MainActor
func clientRemovalChecksSessionAndCancellationBeforeLoadingToken(cancel: Bool) async throws {
    let fixture = ClientRemovalFixture()
    if !cancel { fixture.currentAccountId = "another-account" }
    let request = fixture.start()
    if cancel { request.cancel() }
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(fixture.events.isEmpty)
    #expect(fixture.session.requests.isEmpty)
}

@Test(arguments: [false, true]) @MainActor
func clientRemovalRechecksAfterSuspendedTokenLoading(cancel: Bool) async throws {
    let fixture = ClientRemovalFixture()
    let gate = ClientRemovalGate()
    fixture.tokenGate = gate
    let request = fixture.start()
    try await removalWaitUntil { gate.entered }
    if cancel { request.cancel() }
    else { fixture.currentAccountId = "another-account" }
    gate.resume()
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(fixture.events == ["token"])
    #expect(fixture.session.requests.isEmpty)
}

@Test(arguments: [false, true]) @MainActor
func clientRemovalRechecksAfterSuspendedProfileGate(cancel: Bool) async throws {
    let fixture = ClientRemovalFixture()
    let gate = ClientRemovalGate()
    fixture.authorizationGate = gate
    let request = fixture.start()
    try await removalWaitUntil { gate.entered }
    if cancel { request.cancel() }
    else { fixture.currentAccountId = "another-account" }
    gate.resume()
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(fixture.events == ["token", "authorize"])
    #expect(fixture.session.requests.isEmpty)
}

@Test(arguments: [CloudGatewayMacConfigError.clientActive, .unavailable]) @MainActor
func clientRemovalDoesNotDispatchWhenFinalProfileObservationFails(failure: CloudGatewayMacConfigError) async throws {
    let fixture = ClientRemovalFixture()
    let gate = ClientRemovalGate()
    fixture.authorizationGate = gate
    let request = fixture.start()
    try await removalWaitUntil { gate.entered }
    fixture.authorizationError = failure
    gate.resume()
    await #expect(throws: failure) { try await request.value }
    #expect(fixture.events == ["token", "authorize"])
    #expect(fixture.session.requests.isEmpty)
}

@Test @MainActor func clientRemovalTokenDenialDoesNotEnterTheTransportGate() async throws {
    let fixture = ClientRemovalFixture()
    fixture.tokenError = CloudGatewayMacInventoryError.accessDenied
    await #expect(throws: CloudGatewayMacInventoryError.accessDenied) { _ = try await fixture.perform() }
    #expect(fixture.events == ["token"])
    #expect(fixture.session.requests.isEmpty)
}

@Test(arguments: ["bad/client", "client"]) @MainActor
func clientRemovalInvalidURLFailsBeforeTheTransportGate(clientId: String) async throws {
    let fixture = ClientRemovalFixture()
    await #expect(throws: (any Error).self) {
        _ = try await fixture.perform(clientId: clientId, regionId: clientId == "client" ? "bad/region" : "region")
    }
    #expect(fixture.events == ["token"])
    #expect(fixture.session.requests.isEmpty)
}

@Test(arguments: [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCancelled]) @MainActor
func clientRemovalTransportFailureRetainsHandoffEvidenceAndDoesNotRetry(code: Int) async throws {
    let fixture = ClientRemovalFixture()
    fixture.session.error = URLError(URLError.Code(rawValue: code))
    await #expect(throws: URLError.self) { _ = try await fixture.perform() }
    #expect(fixture.events == ["token", "authorize", "dispatch"])
    #expect(fixture.session.requests.count == 1)
}

@Test(arguments: [401, 403]) @MainActor
func clientRemovalRetainsDefiniteAPIAccessDenials(status: Int) async throws {
    let fixture = ClientRemovalFixture()
    fixture.session.statusCode = status
    fixture.session.body = #"{"error":{"message":"fixture denial"}}"#
    do {
        _ = try await fixture.perform()
        Issue.record("Expected a definite API denial")
    } catch CloudGatewayAppError.apiAccessDenied(_) {}
    #expect(fixture.events.last == "dispatch")
    #expect(fixture.session.requests.count == 1)
}

@Test @MainActor func clientRemovalReceivedDenialSurvivesPostDispatchCancellation() async throws {
    let fixture = ClientRemovalFixture()
    let gate = ClientRemovalGate()
    fixture.session.responseGate = gate
    fixture.session.statusCode = 403
    let request = fixture.start()
    try await removalWaitUntil { gate.entered }
    fixture.currentAccountId = "another-account"
    request.cancel()
    gate.resume()
    do {
        try await request.value
        Issue.record("Expected a definite API denial")
    } catch CloudGatewayAppError.apiAccessDenied(_) {}
    #expect(fixture.session.requests.count == 1)
}

@Test @MainActor func clientRemovalGateIsScopedToTheDeleteRequest() async throws {
    let fixture = ClientRemovalFixture()
    _ = try await fixture.perform()
    fixture.currentAccountId = "another-account"
    fixture.session.body = #"{"regionId":"region","capacityLimit":10,"allocatedClientCount":2}"#
    let client = CloudGatewayControlPlaneClient(originHost: "gocloudlaunch.com", session: fixture.session)
    let capacity = try await client.fetchCapacity(regionId: "region", idToken: "fixture-token")
    #expect(capacity.capacityLimit == 10)
    #expect(fixture.session.requests.map(\.httpMethod) == ["DELETE", "GET"])
    #expect(fixture.events == ["token", "authorize", "dispatch"])
}

@Test(arguments: [400, 404, 409, 500]) @MainActor
func clientRemovalDoesNotInterpretGenericAccessDeniedOrErrorTextAsDefiniteDenial(status: Int) async throws {
    let fixture = ClientRemovalFixture()
    fixture.session.statusCode = status
    fixture.session.body = #"{"error":{"code":"PERMISSION_DENIED","message":"403 already removed"}}"#
    do {
        _ = try await fixture.perform()
        Issue.record("Expected an uncertain HTTP failure")
    } catch CloudGatewayAppError.accessDenied(_) {
    } catch {
        Issue.record("Unexpected error type")
    }
    #expect(fixture.events.last == "dispatch")
    #expect(fixture.session.requests.count == 1)
}

@Test(arguments: [
    #"{"userId":"other-owner","regionId":"region","clientId":"client","status":"removed"}"#,
    #"{"userId":"user-a","regionId":"other-region","clientId":"client","status":"removed"}"#,
    #"{"userId":"user-a","regionId":"region","clientId":"other-client","status":"removed"}"#,
    #"{"userId":"user-a","regionId":"region","clientId":"client","status":"active"}"#,
    #"{"userId":"user-a","regionId":"region","clientId":"client"}"#,
    "not json",
]) @MainActor
func clientRemovalRejectsMismatchedOrMalformedSuccess(body: String) async throws {
    let fixture = ClientRemovalFixture()
    fixture.session.body = body
    await #expect(throws: (any Error).self) { _ = try await fixture.perform() }
    #expect(fixture.events.last == "dispatch")
    #expect(fixture.session.requests.count == 1)
    #expect(fixture.response == nil)
}

@Test(arguments: [false, true]) @MainActor
func clientRemovalVerifiedSuccessSurvivesAccountChangeAndCancellationAfterDispatch(cancel: Bool) async throws {
    let fixture = ClientRemovalFixture()
    let gate = ClientRemovalGate()
    fixture.session.responseGate = gate
    let request = fixture.start()
    try await removalWaitUntil { gate.entered }
    #expect(fixture.events == ["token", "authorize", "dispatch"])
    #expect(fixture.session.requests.count == 1)
    fixture.currentAccountId = "another-account"
    if cancel { request.cancel() }
    gate.resume()
    try await request.value
    #expect(fixture.response?.userId == "user-a")
    #expect(fixture.response?.status == .removed)
    #expect(fixture.session.requests.count == 1)
}

@MainActor
private final class ClientRemovalFixture {
    let session = MacClientRemovalSession()
    var currentAccountId = "admin-account"
    var tokenGate: ClientRemovalGate?
    var authorizationGate: ClientRemovalGate?
    var tokenError: (any Error)?
    var authorizationError: (any Error)?
    var events: [String] = []
    var response: CloudGatewayDeleteClientResponse?

    func start() -> Task<Void, Error> {
        Task { response = try await perform() }
    }

    func perform(clientId: String = "client", regionId: String = "region") async throws -> CloudGatewayDeleteClientResponse {
        try await CloudGatewayMacClientRemovalRequest.perform(
            clientId: clientId, ownerUid: "user-a", regionId: regionId,
            originHost: "gocloudlaunch.com", session: session,
            loadToken: {
                self.events.append("token")
                await self.tokenGate?.wait()
                if let error = self.tokenError { throw error }
                return "fixture-token"
            },
            validateSession: {
                guard self.currentAccountId == "admin-account" else { throw CancellationError() }
            },
            authorize: {
                self.events.append("authorize")
                await self.authorizationGate?.wait()
                if let error = self.authorizationError { throw error }
            },
            onDispatch: {
                #expect(self.session.requests.isEmpty)
                self.events.append("dispatch")
            }
        )
    }
}

@MainActor
final class MacClientRemovalSession: CloudGatewayControlPlaneSession {
    var requests: [URLRequest] = []
    var statusCode = 200
    var body = #"{"userId":"user-a","regionId":"region","clientId":"client","status":"removed"}"#
    var error: (any Error)?
    var responseGate: ClientRemovalGate?
    var onRequest: ((URLRequest) -> Void)?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        onRequest?(request)
        await responseGate?.wait()
        if let error { throw error }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil
        ))
        return (Data(body.utf8), response)
    }
}

@MainActor
final class ClientRemovalGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func removalWaitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<5000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Removal request did not reach its suspension point")
    throw CloudGatewayMacInventoryError.unavailable
}
