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
        .http(200, #"{"regionId":"us-a","syncedAt":"2026-07-17T12:34:56Z","added":1,"updated":2,"removed":3,"noChanges":false,"log":"done"}"#),
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
    let sync = try await client.syncRegion(regionId: "us-a", idToken: "token")
    _ = try await client.grantAccess(
        email: "new@example.com",
        regionId: "us-a",
        idToken: "token"
    )

    #expect(created.clientName == "Phone")
    #expect(sync.syncedAt == "2026-07-17T12:34:56Z")

    let requests = session.requests
    #expect(requests.count == 8)
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
        url: "https://us-a.example.com/api/admin/sync",
        body: ["regionId": "us-a"]
    )
    assertAuthenticatedJSONRequest(
        requests[7],
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
