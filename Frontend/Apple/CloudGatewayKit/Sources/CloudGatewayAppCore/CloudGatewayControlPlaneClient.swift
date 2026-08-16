import CloudGatewayKit
import Foundation

public protocol CloudGatewayControlPlaneSession: AnyObject, Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: CloudGatewayControlPlaneSession {}

public struct CloudGatewayCreateClientResponse: Decodable, Equatable, Sendable {
    public let clientId: String
    public let regionId: String
    public let clientName: String
    public let status: CloudGatewayClientStatus
    public let wireguardConfig: String
    public let assignedTunnelIpv4: String?
    public let serverEndpointIpv4: String?
    public let serverEndpointHostname: String?

    // periphery:ignore - shared test-fixture initializer
    public init(
        clientId: String,
        regionId: String,
        clientName: String,
        status: CloudGatewayClientStatus,
        wireguardConfig: String,
        assignedTunnelIpv4: String?,
        serverEndpointIpv4: String?,
        serverEndpointHostname: String?
    ) {
        self.clientId = clientId
        self.regionId = regionId
        self.clientName = clientName
        self.status = status
        self.wireguardConfig = wireguardConfig
        self.assignedTunnelIpv4 = assignedTunnelIpv4
        self.serverEndpointIpv4 = serverEndpointIpv4
        self.serverEndpointHostname = serverEndpointHostname
    }
}

public struct CloudGatewayCapacityResponse: Decodable, Equatable, Sendable {
    public let regionId: String
    public let capacityLimit: Int
    public let allocatedClientCount: Int
}

public final class CloudGatewayControlPlaneClient: CloudGatewayControlPlaneServicing {
    private let originHost: String
    private let session: any CloudGatewayControlPlaneSession

    public init(
        originHost: String,
        session: any CloudGatewayControlPlaneSession = CloudGatewayAPISession.makeSession()
    ) {
        self.originHost = originHost
        self.session = session
    }

    public func fetchRegions() async throws -> [CloudGatewayRegion] {
        let response: RegionsResponse = try await sendUnauthenticatedRequest(
            url: try apexAPIURL(path: "regions"),
            method: "GET"
        )
        let regions = response.regions.compactMap { region -> CloudGatewayRegion? in
            guard !region.regionId.isEmpty, !region.displayName.isEmpty else {
                return nil
            }
            return CloudGatewayRegion(
                regionId: region.regionId,
                displayName: region.displayName,
                enabled: true,
                displayOrder: region.displayOrder
            )
        }
        return CloudGatewayConfigSelection.sortedRegions(regions)
    }

    public func checkAccess(idToken: String) async throws -> CloudGatewayAccessCheck {
        try await sendJSONRequest(
            url: try apexAPIURL(path: "auth/check-access"),
            method: "POST",
            idToken: idToken,
            body: EmptyRequest()
        )
    }

    public func fetchCapacity(regionId: String, idToken: String) async throws -> CloudGatewayCapacityResponse {
        try await sendJSONRequest(
            url: try regionalAPIURL(regionId: regionId, path: "capacity"),
            method: "GET",
            idToken: idToken
        )
    }

    public func addCapacity(
        to regions: [CloudGatewayRegion],
        idToken: String
    ) async -> [CloudGatewayRegion] {
        var regionsWithCapacity = [CloudGatewayRegion]()
        for region in regions {
            do {
                let capacity = try await fetchCapacity(regionId: region.regionId, idToken: idToken)
                guard capacity.regionId == region.regionId else {
                    regionsWithCapacity.append(region.withCapacity(.unknown))
                    continue
                }
                regionsWithCapacity.append(region.withCapacity(.known(
                    limit: capacity.capacityLimit,
                    allocated: capacity.allocatedClientCount
                )))
            } catch {
                regionsWithCapacity.append(region.withCapacity(.unknown))
            }
        }
        return CloudGatewayConfigSelection.sortedRegions(regionsWithCapacity)
    }

    public func createClient(
        regionId: String,
        clientName: String,
        idToken: String
    ) async throws -> CloudGatewayCreateClientResponse {
        try await sendJSONRequest(
            url: try regionalAPIURL(regionId: regionId, path: "clients"),
            method: "POST",
            idToken: idToken,
            body: CreateClientRequest(
                regionId: regionId,
                clientName: clientName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }

    public func deleteClient(
        clientId: String,
        userId: String,
        regionId: String,
        idToken: String
    ) async throws -> CloudGatewayDeleteClientResponse {
        let safeClientId = try CloudGatewayAPIURLBuilder.validatedClientId(clientId)
        return try await sendJSONRequest(
            url: try regionalAPIURL(regionId: regionId, path: "clients/\(safeClientId)"),
            method: "DELETE",
            idToken: idToken,
            body: DeleteClientRequest(userId: userId, regionId: regionId)
        )
    }

    public func deleteAccount(idToken: String) async throws -> CloudGatewayDeleteAccountResponse {
        try await sendJSONRequest(
            url: try apexAPIURL(path: "account"),
            method: "DELETE",
            idToken: idToken
        )
    }

    public func grantAccess(
        email: String,
        regionId: String,
        idToken: String
    ) async throws -> CloudGatewayGrantAccessResponse {
        try await sendJSONRequest(
            url: try regionalAPIURL(regionId: regionId, path: "users"),
            method: "POST",
            idToken: idToken,
            body: GrantAccessRequest(email: email)
        )
    }

    /// Fans out `admin/sync` to every region in parallel and never throws: each region's outcome
    /// is classified independently (see `sendAdminSync`) so one unreachable host cannot hide the
    /// others' results. Regions number in the low single digits, so full parallelism is fine.
    public func syncRegions(regionIds: [String], idToken: String) async -> [CloudGatewayRegionSyncOutcome] {
        await withTaskGroup(of: IndexedSyncOutcome.self) { group in
            for (index, regionId) in regionIds.enumerated() {
                group.addTask {
                    IndexedSyncOutcome(
                        index: index,
                        outcome: await self.sendAdminSync(regionId: regionId, idToken: idToken)
                    )
                }
            }
            var outcomesByIndex: [Int: CloudGatewayRegionSyncOutcome] = [:]
            for await indexed in group {
                outcomesByIndex[indexed.index] = indexed.outcome
            }
            // A task group yields in completion order, not submission order; reorder to match
            // the caller's requested region order.
            return regionIds.indices.compactMap { outcomesByIndex[$0] }
        }
    }

    private func apexAPIURL(path: String) throws -> URL {
        try CloudGatewayAPIURLBuilder.apexAPIURL(originHost: originHost, path: path)
    }

    private func regionalAPIURL(regionId: String, path: String) throws -> URL {
        try CloudGatewayAPIURLBuilder.regionalAPIURL(
            originHost: originHost,
            regionId: regionId,
            path: path
        )
    }

    private func sendJSONRequest<Response: Decodable, Body: Encodable>(
        url: URL,
        method: String,
        idToken: String,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func sendJSONRequest<Response: Decodable>(
        url: URL,
        method: String,
        idToken: String
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request)
    }

    private func sendUnauthenticatedRequest<Response: Decodable>(
        url: URL,
        method: String
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        return try await send(request)
    }

    /// Shared transport step: performs the request and validates it produced an HTTP response.
    /// Reused by `send` (throwing, for every non-sync endpoint) and `sendAdminSync` (non-throwing)
    /// so URLSession handling lives in exactly one place.
    private func sendTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudGatewayAppError.invalidAPIResponse
        }
        return (data, httpResponse)
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, httpResponse) = try await sendTransport(request)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CloudGatewayAppError.accessDenied(
                apiErrorMessage(from: data) ?? "CloudGateway API request failed."
            )
        }
        do {
            return try JSONDecoder.gatewayAPI.decode(Response.self, from: data)
        } catch {
            throw CloudGatewayAppError.invalidAPIResponse
        }
    }

    /// Never throws: transport failure, HTTP status, and body shape are all folded into
    /// `CloudGatewayRegionSyncOutcome.Result` so a task-group child has nothing to catch and one
    /// region's failure can never mask the others'.
    private func sendAdminSync(regionId: String, idToken: String) async -> CloudGatewayRegionSyncOutcome {
        guard let url = try? regionalAPIURL(regionId: regionId, path: "admin/sync") else {
            return CloudGatewayRegionSyncOutcome(regionId: regionId, result: .genericFailure())
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Overrides the session's fast-fail default for this request only: a sync pass routinely
        // outlives it and has no server-side duration bound.
        request.timeoutInterval = CloudGatewayAPISession.adminSyncRequestTimeout
        guard let body = try? JSONEncoder().encode(SyncRegionRequest(regionId: regionId)) else {
            return CloudGatewayRegionSyncOutcome(regionId: regionId, result: .genericFailure())
        }
        request.httpBody = body

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await sendTransport(request)
        } catch {
            return CloudGatewayRegionSyncOutcome(regionId: regionId, result: .genericFailure())
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let detail = decodedErrorDetail(from: data)
            if httpResponse.statusCode == 409, detail?.code == "SYNC_IN_PROGRESS" {
                return CloudGatewayRegionSyncOutcome(regionId: regionId, result: .alreadyRunning)
            }
            let message = detail?.message
                ?? detail?.code
                ?? "CloudGateway sync failed for \(regionId) (HTTP \(httpResponse.statusCode))."
            return CloudGatewayRegionSyncOutcome(
                regionId: regionId,
                result: .failure(message: message, requestId: detail?.requestId, isIncompatibleResponse: false)
            )
        }

        guard let response = CloudGatewayRegionSyncParsing.parse(data: data, requestedRegionId: regionId) else {
            return CloudGatewayRegionSyncOutcome(
                regionId: regionId,
                result: .failure(
                    message: "Incompatible admin sync response from \(regionId).",
                    requestId: nil,
                    isIncompatibleResponse: true
                )
            )
        }
        return CloudGatewayRegionSyncOutcome(regionId: regionId, result: .success(response))
    }

    private func decodedErrorDetail(from data: Data) -> ErrorResponse.Detail? {
        (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
    }

    private func apiErrorMessage(from data: Data) -> String? {
        let detail = decodedErrorDetail(from: data)
        return detail?.message ?? detail?.code
    }
}

private struct IndexedSyncOutcome: Sendable {
    let index: Int
    let outcome: CloudGatewayRegionSyncOutcome
}

private extension CloudGatewayRegionSyncOutcome.Result {
    /// Short, generic message with no request ID or body text: used for transport failures and
    /// pre-transport errors (URL building, request encoding) where there is no API envelope.
    static func genericFailure() -> Self {
        .failure(message: "Could not reach the region.", requestId: nil, isIncompatibleResponse: false)
    }
}

private struct RegionsResponse: Decodable {
    struct Region: Decodable {
        let regionId: String
        let displayName: String
        let displayOrder: Int
    }

    let regions: [Region]
}

private struct EmptyRequest: Encodable {}

private struct CreateClientRequest: Encodable {
    let regionId: String
    let clientName: String
}

private struct DeleteClientRequest: Encodable {
    let userId: String
    let regionId: String
}

private struct SyncRegionRequest: Encodable {
    let regionId: String
}

private struct GrantAccessRequest: Encodable {
    let email: String
}

private struct ErrorResponse: Decodable {
    struct Detail: Decodable {
        let code: String?
        let message: String?
        let requestId: String?
    }

    let error: Detail?
}

private extension JSONDecoder {
    static var gatewayAPI: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension CloudGatewayRegion {
    func withCapacity(_ capacity: CloudGatewayRegionCapacity) -> CloudGatewayRegion {
        CloudGatewayRegion(
            regionId: regionId,
            displayName: displayName,
            enabled: enabled,
            displayOrder: displayOrder,
            capacity: capacity
        )
    }
}
