import Foundation
import Testing
import CloudGatewayKit
@testable import CloudGatewayAppCore

@Test func controlPlaneEndpointContractsStayStable() async throws {
    let session = RecordingControlPlaneSession(stubs: [
        .http(200, #"{"regions":[{"regionId":"us-b","displayName":"Beta","displayOrder":20},{"regionId":"us-a","displayName":"Alpha","displayOrder":10}]}"#),
        .http(200, #"{"userId":"user-1","email":"user@example.com","role":"admin"}"#),
        .http(200, #"{"regionId":"us-a","capacityLimit":50,"allocatedClientCount":7}"#),
        .http(201, #"{"clientId":"client-1","regionId":"us-a","clientName":"Phone","status":"active","wireguardConfig":"config","assignedTunnelIpv4":"10.0.0.2","serverEndpointIpv4":"192.0.2.1","serverEndpointHostname":"wg.example.com"}"#),
        .http(200, #"{"userId":"user-1","clientId":"client-1","regionId":"us-a","status":"removed"}"#),
        .http(200, #"{"userId":"user-1","deletedClientCount":2}"#),
        .http(200, #"{"email":"new@example.com","alreadyExisted":false}"#),
    ])
    let client = CloudGatewayControlPlaneClient(originHost: "example.com", session: session)

    _ = try await client.fetchRegions()
    _ = try await client.checkAccess(idToken: "token")
    _ = try await client.fetchCapacity(regionId: "us-a", idToken: "token")
    let created = try await client.createClient(
        regionId: "us-a",
        clientName: "  Phone  ",
        idToken: "token"
    )
    _ = try await client.deleteClient(
        clientId: "client-1",
        userId: "user-1",
        regionId: "us-a",
        idToken: "token"
    )
    _ = try await client.deleteAccount(idToken: "token")
    _ = try await client.grantAccess(
        email: "new@example.com",
        regionId: "us-a",
        idToken: "token"
    )

    #expect(created.clientName == "Phone")

    let requests = session.requests
    #expect(requests.count == 7)
    assertRequest(requests[0], method: "GET", url: "https://api.example.com/api/regions")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == nil)
    #expect(requests[0].httpBody == nil)

    assertAuthenticatedJSONRequest(
        requests[1],
        method: "POST",
        url: "https://api.example.com/api/auth/check-access",
        body: [:]
    )
    assertAuthenticatedJSONRequest(
        requests[2],
        method: "GET",
        url: "https://us-a.example.com/api/capacity",
        body: nil
    )
    assertAuthenticatedJSONRequest(
        requests[3],
        method: "POST",
        url: "https://us-a.example.com/api/clients",
        body: ["clientName": "Phone", "regionId": "us-a"]
    )
    assertAuthenticatedJSONRequest(
        requests[4],
        method: "DELETE",
        url: "https://us-a.example.com/api/clients/client-1",
        body: ["regionId": "us-a", "userId": "user-1"]
    )
    assertAuthenticatedJSONRequest(
        requests[5],
        method: "DELETE",
        url: "https://api.example.com/api/account",
        body: nil
    )
    assertAuthenticatedJSONRequest(
        requests[6],
        method: "POST",
        url: "https://us-a.example.com/api/users",
        body: ["email": "new@example.com"]
    )
}

@Test func controlPlaneRegionsFilterAndSortInvalidRows() async throws {
    let session = RecordingControlPlaneSession(stubs: [
        .http(200, #"{"regions":[{"regionId":"us-b","displayName":"Beta","displayOrder":20},{"regionId":"","displayName":"Missing ID","displayOrder":1},{"regionId":"us-empty","displayName":"","displayOrder":2},{"regionId":"us-a","displayName":"Alpha","displayOrder":10}]}"#),
    ])
    let client = CloudGatewayControlPlaneClient(originHost: "example.com", session: session)

    let regions = try await client.fetchRegions()

    #expect(regions.map(\.regionId) == ["us-a", "us-b"])
    #expect(regions.allSatisfy { $0.enabled })
}

@Test func controlPlaneCapacityRemainsSerialAndBestEffort() async {
    let session = RecordingControlPlaneSession(stubs: [
        .http(200, #"{"regionId":"us-c","capacityLimit":10,"allocatedClientCount":4}"#),
        .http(200, #"{"regionId":"wrong-region","capacityLimit":20,"allocatedClientCount":5}"#),
        .failure(URLError(.timedOut)),
    ])
    let client = CloudGatewayControlPlaneClient(originHost: "example.com", session: session)
    let regions = [
        region("us-c", order: 30),
        region("us-a", order: 10),
        region("us-b", order: 20),
    ]

    let result = await client.addCapacity(to: regions, idToken: "token")

    #expect(session.requests.map { $0.url?.host } == [
        "us-c.example.com",
        "us-a.example.com",
        "us-b.example.com",
    ])
    #expect(result.map(\.regionId) == ["us-a", "us-b", "us-c"])
    #expect(result.allSatisfy { region in
        if region.regionId == "us-c" {
            return region.capacity == .known(limit: 10, allocated: 4)
        }
        return region.capacity == .unknown
    })
}

@Test func controlPlaneMapsHTTPAndDecodeFailuresWithoutHidingTransportErrors() async {
    let session = RecordingControlPlaneSession(stubs: [
        .http(403, #"{"error":{"code":"denied","message":"No access"}}"#),
        .http(500, #"{"error":{"code":"server_error"}}"#),
        .http(500, "not-json"),
        .http(200, "not-json"),
        .nonHTTP("{}"),
        .failure(URLError(.timedOut)),
    ])
    let client = CloudGatewayControlPlaneClient(originHost: "example.com", session: session)

    await expectErrorDescription("No access") {
        _ = try await client.fetchRegions()
    }
    await expectErrorDescription("server_error") {
        _ = try await client.fetchRegions()
    }
    await expectErrorDescription("CloudGateway API request failed.") {
        _ = try await client.fetchRegions()
    }
    await expectErrorDescription("CloudGateway returned an invalid response.") {
        _ = try await client.fetchRegions()
    }
    await expectErrorDescription("CloudGateway returned an invalid response.") {
        _ = try await client.fetchRegions()
    }
    do {
        _ = try await client.fetchRegions()
        Issue.record("Expected the transport error to escape unchanged.")
    } catch let error as URLError {
        #expect(error.code == .timedOut)
    } catch {
        Issue.record("Expected URLError, got \(type(of: error)).")
    }
}

@Test func controlPlaneRejectsPathInjectionBeforeSendingARequest() async {
    let session = RecordingControlPlaneSession(stubs: [])
    let client = CloudGatewayControlPlaneClient(originHost: "example.com", session: session)

    await expectErrorDescription("CloudGateway returned an invalid response.") {
        _ = try await client.deleteClient(
            clientId: "../client",
            userId: "user-1",
            regionId: "us-a",
            idToken: "token"
        )
    }
    #expect(session.requests.isEmpty)
}

@Test func syncRegionsClassifies409SyncInProgressAsAlreadyRunning() async {
    let session = RecordingControlPlaneSession(stubs: [
        .http(409, #"{"error":{"code":"SYNC_IN_PROGRESS","message":"sync already running","requestId":"req-1"}}"#),
    ])
    let client = CloudGatewayControlPlaneClient(originHost: "example.com", session: session)

    let outcomes = await client.syncRegions(regionIds: ["us-a"], idToken: "token")

    #expect(outcomes.count == 1)
    #expect(outcomes[0].regionId == "us-a")
    #expect(outcomes[0].result == .alreadyRunning)
}

@Test func syncRegionsFoldsANonJSONErrorBodyIntoAGenericMessage() async {
    let session = RecordingControlPlaneSession(stubs: [
        .http(502, "<html><body>502 Bad Gateway</body></html>"),
    ])
    let client = CloudGatewayControlPlaneClient(originHost: "example.com", session: session)

    let outcomes = await client.syncRegions(regionIds: ["us-a"], idToken: "token")

    guard case .failure(let message, let requestId, let isIncompatibleResponse) = outcomes[0].result else {
        Issue.record("Expected a failure outcome")
        return
    }
    #expect(!message.contains("<html>"))
    #expect(!message.contains("Bad Gateway"))
    #expect(message.contains("502"))
    #expect(requestId == nil)
    #expect(isIncompatibleResponse == false)
}

@Test func syncRegionsClassifiesAnIncompatible2xxShapeAsFailure() async {
    let session = RecordingControlPlaneSession(stubs: [
        .http(200, #"{"regionId":"us-a"}"#),
    ])
    let client = CloudGatewayControlPlaneClient(originHost: "example.com", session: session)

    let outcomes = await client.syncRegions(regionIds: ["us-a"], idToken: "token")

    guard case .failure(let message, let requestId, let isIncompatibleResponse) = outcomes[0].result else {
        Issue.record("Expected a failure outcome")
        return
    }
    #expect(isIncompatibleResponse)
    #expect(requestId == nil)
    #expect(message.contains("us-a"))
}

@Test func syncRegionsClassifiesATransportErrorAsAGenericFailure() async {
    let session = RecordingControlPlaneSession(stubs: [
        .failure(URLError(.networkConnectionLost)),
    ])
    let client = CloudGatewayControlPlaneClient(originHost: "example.com", session: session)

    let outcomes = await client.syncRegions(regionIds: ["us-a"], idToken: "token")

    guard case .failure(let message, let requestId, let isIncompatibleResponse) = outcomes[0].result else {
        Issue.record("Expected a failure outcome")
        return
    }
    #expect(!message.isEmpty)
    #expect(requestId == nil)
    #expect(isIncompatibleResponse == false)
}

@Test func syncRegionsReordersMixedOutcomesToTheRequestedOrderAndKeepsMeshFields() async {
    let successBody = #"{"regionId":"us-a","syncedAt":"2026-08-15T20:38:37.814426Z","added":2,"updated":1,"removed":0,"noChanges":false,"log":"sync log","meshUpdated":1,"meshEnabled":true,"meshApplied":1,"meshAdded":1,"meshRemoved":0,"meshSkipped":0,"meshRoutesAdded":2,"meshRoutesRemoved":0,"meshStatusWritten":true,"meshPeers":[{"regionId":"us-b","status":"applied","endpointHostname":"wg.us-b.example.com","endpointPort":51820,"allowedNetworkV4":"10.0.1.0/24","allowedNetworkV6":"fd42:42:42:1::/64"}]}"#
    let session = RegionKeyedControlPlaneSession(stubsByHost: [
        "us-a.example.com": .http(200, successBody),
        "us-b.example.com": .http(409, #"{"error":{"code":"SYNC_IN_PROGRESS"}}"#),
        "us-c.example.com": .http(500, #"{"error":{"code":"server_error","message":"boom"}}"#),
    ])
    let client = CloudGatewayControlPlaneClient(originHost: "example.com", session: session)

    let outcomes = await client.syncRegions(regionIds: ["us-c", "us-a", "us-b"], idToken: "token")

    #expect(outcomes.map(\.regionId) == ["us-c", "us-a", "us-b"])

    guard case .failure(let cMessage, _, let cIncompatible) = outcomes[0].result else {
        Issue.record("Expected us-c to fail")
        return
    }
    #expect(cMessage == "boom")
    #expect(cIncompatible == false)

    guard case .success(let response) = outcomes[1].result else {
        Issue.record("Expected us-a to succeed")
        return
    }
    #expect(response.regionId == "us-a")
    #expect(response.meshPeers.count == 1)
    #expect(response.meshPeers[0].regionId == "us-b")
    #expect(response.meshPeers[0].status == .applied)
    #expect(response.meshPeers[0].endpointHostname == "wg.us-b.example.com")
    #expect(response.meshPeers[0].endpointPort == 51820)
    #expect(response.meshPeers[0].allowedNetworkV4 == "10.0.1.0/24")
    #expect(response.meshPeers[0].allowedNetworkV6 == "fd42:42:42:1::/64")

    #expect(outcomes[2].result == .alreadyRunning)

    // One token is fetched before the fan-out and reused across every region, and each
    // request carries the admin-sync timeout rather than the session's fast-fail default.
    // Requests complete in arbitrary order, so assert over the set, not a sequence.
    let requests = session.requests
    #expect(requests.count == 3)
    #expect(requests.allSatisfy { $0.timeoutInterval == CloudGatewayAPISession.adminSyncRequestTimeout })
    #expect(Set(requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }) == ["Bearer token"])
}

@Test func syncRegionsSetsTheAdminSyncTimeoutButOtherEndpointsKeepTheSessionDefault() async throws {
    let session = RecordingControlPlaneSession(stubs: [
        .http(409, #"{"error":{"code":"SYNC_IN_PROGRESS"}}"#),
        .http(200, #"{"userId":"user-1","email":"user@example.com","role":"admin"}"#),
    ])
    let client = CloudGatewayControlPlaneClient(originHost: "example.com", session: session)

    _ = await client.syncRegions(regionIds: ["us-a"], idToken: "token")
    _ = try await client.checkAccess(idToken: "token")

    let requests = session.requests
    #expect(requests[0].timeoutInterval == CloudGatewayAPISession.adminSyncRequestTimeout)
    #expect(requests[1].timeoutInterval != CloudGatewayAPISession.adminSyncRequestTimeout)
}

private func region(_ id: String, order: Int) -> CloudGatewayRegion {
    CloudGatewayRegion(regionId: id, displayName: id, enabled: true, displayOrder: order)
}

private func assertRequest(_ request: URLRequest, method: String, url: String) {
    #expect(request.httpMethod == method)
    #expect(request.url?.absoluteString == url)
}

private func assertAuthenticatedJSONRequest(
    _ request: URLRequest,
    method: String,
    url: String,
    body: [String: String]?
) {
    assertRequest(request, method: method, url: url)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    guard let body else {
        #expect(request.httpBody == nil)
        return
    }
    let actualBody = request.httpBody.flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? NSDictionary
    }
    #expect(actualBody == body as NSDictionary)
}

private func expectErrorDescription(
    _ description: String,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected error: \(description)")
    } catch {
        #expect(error.localizedDescription == description)
    }
}

private final class RecordingControlPlaneSession: CloudGatewayControlPlaneSession, @unchecked Sendable {
    enum Stub {
        case http(Int, Data)
        case nonHTTP(Data)
        case failure(Error)

        static func http(_ status: Int, _ body: String) -> Stub {
            .http(status, Data(body.utf8))
        }

        static func nonHTTP(_ body: String) -> Stub {
            .nonHTTP(Data(body.utf8))
        }
    }

    private let lock = NSLock()
    private var stubs: [Stub]
    private var capturedRequests: [URLRequest] = []

    init(stubs: [Stub]) {
        self.stubs = stubs
    }

    var requests: [URLRequest] {
        lock.withLock { capturedRequests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let stub = lock.withLock { () -> Stub? in
            capturedRequests.append(request)
            guard !stubs.isEmpty else { return nil }
            return stubs.removeFirst()
        }
        guard let stub else {
            throw URLError(.resourceUnavailable)
        }
        switch stub {
        case .http(let status, let data):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        case .nonHTTP(let data):
            return (data, URLResponse(
                url: request.url!,
                mimeType: nil,
                expectedContentLength: data.count,
                textEncodingName: nil
            ))
        case .failure(let error):
            throw error
        }
    }
}

/// Resolves a stub by request host rather than call order, so a `syncRegions` fan-out (which
/// issues requests concurrently and may complete in any order) still gets a deterministic,
/// per-region response.
private final class RegionKeyedControlPlaneSession: CloudGatewayControlPlaneSession, @unchecked Sendable {
    struct Stub {
        let status: Int
        let body: Data

        static func http(_ status: Int, _ body: String) -> Stub {
            Stub(status: status, body: Data(body.utf8))
        }
    }

    private let lock = NSLock()
    private let stubsByHost: [String: Stub]
    private var capturedRequests: [URLRequest] = []

    init(stubsByHost: [String: Stub]) {
        self.stubsByHost = stubsByHost
    }

    var requests: [URLRequest] {
        lock.withLock { capturedRequests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let stub: Stub? = lock.withLock {
            capturedRequests.append(request)
            return request.url?.host.flatMap { stubsByHost[$0] }
        }
        guard let stub else {
            throw URLError(.resourceUnavailable)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (stub.body, response)
    }
}
