import CloudGatewayAppCore
import Foundation

@MainActor
public enum CloudGatewayMacClientRemovalRequest {
    public static func perform(
        clientId: String,
        ownerUid: String,
        regionId: String,
        originHost: String,
        session: any CloudGatewayControlPlaneSession,
        loadToken: @MainActor () async throws -> String,
        validateSession: @escaping @MainActor () throws -> Void,
        authorize: @escaping @MainActor () async throws -> Void,
        onDispatch: @escaping @MainActor () -> Void
    ) async throws -> CloudGatewayDeleteClientResponse {
        try Task.checkCancellation()
        try validateSession()
        let token = try await loadToken()
        let transport = ClientRemovalSession(
            session: session, validateSession: validateSession, authorize: authorize, onDispatch: onDispatch
        )
        let client = CloudGatewayControlPlaneClient(originHost: originHost, session: transport)
        let response: CloudGatewayDeleteClientResponse
        do {
            response = try await client.deleteClient(
                clientId: clientId, userId: ownerUid, regionId: regionId, idToken: token
            )
        } catch CloudGatewayAppError.apiAccessDenied(_) {
            throw CloudGatewayMacInventoryError.accessDenied
        }
        guard response.userId == ownerUid, response.regionId == regionId,
              response.clientId == clientId, response.status == .removed else {
            throw CloudGatewayMacInventoryError.unavailable
        }
        // Preserve verified remote success even if the original session changed during the request
        return response
    }
}

@MainActor
private final class ClientRemovalSession: CloudGatewayControlPlaneSession {
    private let session: any CloudGatewayControlPlaneSession
    private let validateSession: @MainActor () throws -> Void
    private let authorize: @MainActor () async throws -> Void
    private let onDispatch: @MainActor () -> Void
    private var dispatched = false

    init(
        session: any CloudGatewayControlPlaneSession,
        validateSession: @escaping @MainActor () throws -> Void,
        authorize: @escaping @MainActor () async throws -> Void,
        onDispatch: @escaping @MainActor () -> Void
    ) {
        self.session = session
        self.validateSession = validateSession
        self.authorize = authorize
        self.onDispatch = onDispatch
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        try validateSession()
        try await authorize()
        try Task.checkCancellation()
        try validateSession()
        guard !dispatched else { throw CloudGatewayMacInventoryError.unavailable }
        dispatched = true
        onDispatch()
        return try await session.data(for: request)
    }
}
