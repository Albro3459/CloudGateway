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
    func linkEmailPassword(email: String, password: String) async throws -> AuthenticatedUser
    func linkApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser
    func linkGoogle(credentials: CloudGatewayGoogleCredentials) async throws -> AuthenticatedUser
    func reauthenticateWithPassword(_ password: String) async throws
    func reauthenticateWithApple(
        idToken: String,
        rawNonce: String,
        authorizationCode: String,
        revoke: Bool
    ) async throws
    func reauthenticateWithGoogle(credentials: CloudGatewayGoogleCredentials) async throws
    func sendPasswordReset(email: String) async throws
    func signOut() throws
    func idToken(forceRefresh: Bool) async throws -> String
}

@MainActor
public protocol CloudGatewayClientRepository: AnyObject {
    func fetchUserRole(uid: String) async throws -> String?
    func fetchOwnedClients(uid: String) async throws -> [CloudGatewayClient]
    func fetchAllClients() async throws -> [CloudGatewayClient]
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
    func syncRegion(regionId: String, idToken: String) async throws -> CloudGatewayRegionSyncResponse
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
        try await auth.linkEmailPassword(email: email, password: password)
    }

    public func linkApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser {
        try await auth.linkApple(idToken: idToken, rawNonce: rawNonce)
    }

    public func linkGoogle() async throws -> AuthenticatedUser {
        let credentials = try await googlePresenter.presentCredentials()
        return try await auth.linkGoogle(credentials: credentials)
    }

    public func reauthenticateWithPassword(_ password: String) async throws {
        try await auth.reauthenticateWithPassword(password)
    }

    public func reauthenticateWithApple(
        idToken: String,
        rawNonce: String,
        authorizationCode: String,
        revoke: Bool
    ) async throws {
        try await auth.reauthenticateWithApple(
            idToken: idToken,
            rawNonce: rawNonce,
            authorizationCode: authorizationCode,
            revoke: revoke
        )
    }

    public func reauthenticateWithGoogle(revoke: Bool) async throws {
        let credentials = try await googlePresenter.presentCredentials()
        try await auth.reauthenticateWithGoogle(credentials: credentials)
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

    public func checkAccess(
        idToken: String,
        regions: [CloudGatewayRegion]
    ) async throws -> CloudGatewayAccessCheck {
        _ = regions
        return try await controlPlane.checkAccess(idToken: idToken)
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

    public func syncRegion(regionId: String, idToken: String) async throws -> CloudGatewayRegionSyncResponse {
        try await controlPlane.syncRegion(regionId: regionId, idToken: idToken)
    }

    public func grantAccess(
        email: String,
        regionId: String,
        idToken: String
    ) async throws -> CloudGatewayGrantAccessResponse {
        try await controlPlane.grantAccess(email: email, regionId: regionId, idToken: idToken)
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
