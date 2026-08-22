import CloudGatewayKit
import Foundation

public struct CloudGatewayGoogleCredentials: Equatable, Sendable {
    public let idToken: String
    public let accessToken: String

    public init(idToken: String, accessToken: String) {
        self.idToken = idToken
        self.accessToken = accessToken
    }
}

@MainActor
public protocol CloudGatewayGoogleSignInPresenting: AnyObject {
    func presentCredentials() async throws -> CloudGatewayGoogleCredentials
    func signOut()
    func disconnect() async throws
}

@MainActor
public protocol CloudGatewayAuthServicing: AnyObject {
    var currentUser: AuthenticatedUser? { get }
    func addAuthStateListener(
        _ listener: @escaping (AuthenticatedUser?) -> Void
    ) -> CloudGatewayAuthStateListenerRegistration
    func signIn(email: String, password: String) async throws -> AuthenticatedUser
    func signInWithApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser
    func signInWithGoogle(credentials: CloudGatewayGoogleCredentials) async throws -> AuthenticatedUser
    func providerIds() -> [String]
    func linkEmailPassword(
        email: String,
        password: String,
        expectedUserId: String
    ) async throws -> AuthenticatedUser
    func linkApple(
        idToken: String,
        rawNonce: String,
        expectedUserId: String
    ) async throws -> AuthenticatedUser
    func linkGoogle(
        credentials: CloudGatewayGoogleCredentials,
        expectedUserId: String
    ) async throws -> AuthenticatedUser
    func reauthenticateWithPassword(_ password: String, expectedUserId: String) async throws
    func reauthenticateWithApple(
        idToken: String,
        rawNonce: String,
        authorizationCode: String,
        revoke: Bool,
        expectedUserId: String
    ) async throws
    func reauthenticateWithGoogle(
        credentials: CloudGatewayGoogleCredentials,
        expectedUserId: String
    ) async throws
    func sendPasswordReset(email: String) async throws
    func signOut() throws
    func idToken(forceRefresh: Bool) async throws -> String
}

@MainActor
public protocol CloudGatewayClientRepository: AnyObject {
    func fetchUserRole(uid: String) async throws -> String?
    func fetchOwnedClients(uid: String) async throws -> [CloudGatewayClient]
    func fetchAllClients() async throws -> [CloudGatewayClient]
    func fetchMeshRegions() async throws -> [CloudGatewayMeshRegion]
    func fetchMeshDocs() async throws -> [String: CloudGatewayMeshDoc]
    func fetchPolicyDocs() async throws -> [String: CloudGatewayPolicyDoc]
    func setRegionMeshEnabled(regionId: String, enabled: Bool) async throws
}

public protocol CloudGatewayControlPlaneServicing: AnyObject, Sendable {
    func fetchRegions() async throws -> [CloudGatewayRegion]
    func addCapacity(to regions: [CloudGatewayRegion], idToken: String) async -> [CloudGatewayRegion]
    func checkAccess(idToken: String) async throws -> CloudGatewayAccessCheck
    func createClient(
        regionId: String,
        clientName: String,
        idToken: String
    ) async throws -> CloudGatewayCreateClientResponse
    func deleteClient(
        clientId: String,
        userId: String,
        regionId: String,
        idToken: String
    ) async throws -> CloudGatewayDeleteClientResponse
    func deleteAccount(idToken: String) async throws -> CloudGatewayDeleteAccountResponse
    func syncRegions(regionIds: [String], idToken: String) async -> [CloudGatewayRegionSyncOutcome]
    func grantAccess(
        email: String,
        regionId: String,
        idToken: String
    ) async throws -> CloudGatewayGrantAccessResponse
}

@MainActor
public final class CloudGatewayAppServiceFacade: CloudGatewayServicing {
    private let auth: any CloudGatewayAuthServicing
    private let repository: any CloudGatewayClientRepository
    private let controlPlane: any CloudGatewayControlPlaneServicing
    private let googlePresenter: any CloudGatewayGoogleSignInPresenting

    public init(
        auth: any CloudGatewayAuthServicing,
        repository: any CloudGatewayClientRepository,
        controlPlane: any CloudGatewayControlPlaneServicing,
        googlePresenter: any CloudGatewayGoogleSignInPresenting
    ) {
        self.auth = auth
        self.repository = repository
        self.controlPlane = controlPlane
        self.googlePresenter = googlePresenter
    }

    public var currentUser: AuthenticatedUser? {
        auth.currentUser
    }

    public func addAuthStateListener(
        _ listener: @escaping (AuthenticatedUser?) -> Void
    ) -> CloudGatewayAuthStateListenerRegistration {
        auth.addAuthStateListener(listener)
    }

    public func signIn(email: String, password: String) async throws -> AuthenticatedUser {
        try await auth.signIn(email: email, password: password)
    }

    public func signInWithApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser {
        try await auth.signInWithApple(idToken: idToken, rawNonce: rawNonce)
    }

    public func signInWithGoogle() async throws -> AuthenticatedUser {
        let credentials = try await googlePresenter.presentCredentials()
        return try await auth.signInWithGoogle(credentials: credentials)
    }

    public func providerIds() -> [String] {
        auth.providerIds()
    }

    public func linkEmailPassword(email: String, password: String) async throws -> AuthenticatedUser {
        guard let expectedUserId = auth.currentUser?.uid else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        return try await auth.linkEmailPassword(
            email: email,
            password: password,
            expectedUserId: expectedUserId
        )
    }

    public func linkApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser {
        guard let expectedUserId = auth.currentUser?.uid else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        return try await auth.linkApple(
            idToken: idToken,
            rawNonce: rawNonce,
            expectedUserId: expectedUserId
        )
    }

    public func linkGoogle() async throws -> AuthenticatedUser {
        guard let expectedUserId = auth.currentUser?.uid else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        let credentials = try await googlePresenter.presentCredentials()
        return try await auth.linkGoogle(
            credentials: credentials,
            expectedUserId: expectedUserId
        )
    }

    public func reauthenticateWithPassword(_ password: String) async throws {
        guard let expectedUserId = auth.currentUser?.uid else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        try await auth.reauthenticateWithPassword(password, expectedUserId: expectedUserId)
    }

    public func reauthenticateWithApple(
        idToken: String,
        rawNonce: String,
        authorizationCode: String,
        revoke: Bool
    ) async throws {
        guard let expectedUserId = auth.currentUser?.uid else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        try await auth.reauthenticateWithApple(
            idToken: idToken,
            rawNonce: rawNonce,
            authorizationCode: authorizationCode,
            revoke: revoke,
            expectedUserId: expectedUserId
        )
    }

    public func reauthenticateWithGoogle(revoke: Bool) async throws {
        guard let expectedUserId = auth.currentUser?.uid else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        let credentials = try await googlePresenter.presentCredentials()
        try await auth.reauthenticateWithGoogle(
            credentials: credentials,
            expectedUserId: expectedUserId
        )
        if revoke {
            try await googlePresenter.disconnect()
        }
    }

    public func sendPasswordReset(email: String) async throws {
        try await auth.sendPasswordReset(email: email)
    }

    public func signOut() throws {
        googlePresenter.signOut()
        try auth.signOut()
    }

    public func idToken(forceRefresh: Bool) async throws -> String {
        try await auth.idToken(forceRefresh: forceRefresh)
    }

    public func fetchUserRole(uid: String) async throws -> String? {
        try await repository.fetchUserRole(uid: uid)
    }

    public func fetchRegions() async throws -> [CloudGatewayRegion] {
        try await controlPlane.fetchRegions()
    }

    public func addCapacity(to regions: [CloudGatewayRegion], idToken: String) async -> [CloudGatewayRegion] {
        await controlPlane.addCapacity(to: regions, idToken: idToken)
    }

    public func checkAccess(idToken: String) async throws -> CloudGatewayAccessCheck {
        try await controlPlane.checkAccess(idToken: idToken)
    }

    public func fetchOwnedClients(uid: String) async throws -> [CloudGatewayClient] {
        try await repository.fetchOwnedClients(uid: uid)
    }

    public func fetchAllClients() async throws -> [CloudGatewayClient] {
        try await repository.fetchAllClients()
    }

    public func createClient(
        regionId: String,
        clientName: String,
        idToken: String
    ) async throws -> CloudGatewayClient {
        let response = try await controlPlane.createClient(
            regionId: regionId,
            clientName: clientName,
            idToken: idToken
        )
        return CloudGatewayClient(
            clientId: response.clientId,
            clientName: response.clientName,
            regionId: response.regionId,
            status: response.status,
            wireGuardConfig: response.wireguardConfig,
            assignedTunnelIpv4: response.assignedTunnelIpv4,
            serverEndpointIpv4: response.serverEndpointIpv4,
            serverEndpointHostname: response.serverEndpointHostname,
            updatedAt: nil,
            ownerUid: auth.currentUser?.uid,
            ownerEmail: auth.currentUser?.email
        )
    }

    public func deleteClient(
        clientId: String,
        userId: String,
        regionId: String,
        idToken: String
    ) async throws -> CloudGatewayDeleteClientResponse {
        try await controlPlane.deleteClient(
            clientId: clientId,
            userId: userId,
            regionId: regionId,
            idToken: idToken
        )
    }

    public func deleteAccount(idToken: String) async throws -> CloudGatewayDeleteAccountResponse {
        try await controlPlane.deleteAccount(idToken: idToken)
    }

    public func syncRegions(regionIds: [String], idToken: String) async -> [CloudGatewayRegionSyncOutcome] {
        await controlPlane.syncRegions(regionIds: regionIds, idToken: idToken)
    }

    public func grantAccess(
        email: String,
        regionId: String,
        idToken: String
    ) async throws -> CloudGatewayGrantAccessResponse {
        try await controlPlane.grantAccess(email: email, regionId: regionId, idToken: idToken)
    }

    public func fetchMeshRegions() async throws -> [CloudGatewayMeshRegion] {
        try await repository.fetchMeshRegions()
    }

    public func fetchMeshDocs() async throws -> [String: CloudGatewayMeshDoc] {
        try await repository.fetchMeshDocs()
    }

    public func fetchPolicyDocs() async throws -> [String: CloudGatewayPolicyDoc] {
        try await repository.fetchPolicyDocs()
    }

    public func setRegionMeshEnabled(regionId: String, enabled: Bool) async throws {
        try await repository.setRegionMeshEnabled(regionId: regionId, enabled: enabled)
    }
}

public enum CloudGatewayFirestoreClientMapper {
    public static func client(
        documentId: String,
        regionFallback: String?,
        data: [String: Any]
    ) -> CloudGatewayClient? {
        guard let statusValue = string(data["status"]),
              let status = CloudGatewayClientStatus(rawValue: statusValue) else {
            return nil
        }
        let clientId = string(data["clientId"]) ?? documentId
        let regionId = string(data["regionId"]) ?? regionFallback ?? ""
        guard !clientId.isEmpty, !regionId.isEmpty else {
            return nil
        }
        return CloudGatewayClient(
            clientId: clientId,
            clientName: string(data["clientName"]),
            regionId: regionId,
            status: status,
            wireGuardConfig: string(data["wireguardConfig"]),
            assignedTunnelIpv4: string(data["assignedTunnelIpv4"]),
            serverEndpointIpv4: string(data["serverEndpointIpv4"]),
            serverEndpointHostname: string(data["serverEndpointHostname"]),
            updatedAt: data["updatedAt"] as? Date,
            ownerUid: string(data["ownerUid"]),
            ownerEmail: string(data["ownerEmail"]) ?? string(data["email"])
        )
    }

    public static func string(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
