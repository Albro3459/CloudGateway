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

    public func syncRegion(regionId: String, idToken: String) async throws -> CloudGatewayRegionSyncResponse {
        try await sendJSONRequest(
            url: try regionalAPIURL(regionId: regionId, path: "admin/sync"),
            method: "POST",
            idToken: idToken,
            body: SyncRegionRequest(regionId: regionId)
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

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudGatewayAppError.invalidAPIResponse
        }
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

    private func apiErrorMessage(from data: Data) -> String? {
        guard let response = try? JSONDecoder().decode(ErrorResponse.self, from: data) else {
            return nil
        }
        return response.error?.message ?? response.error?.code
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
