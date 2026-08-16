import CloudGatewayKit
import Foundation
import Testing
@testable import CloudGatewayAppCore

@MainActor
@Test func appServiceFacadePreservesGoogleGrantCleanupOrder() async throws {
    let events = EventLog()
    let auth = FacadeAuthFake(events: events)
    let presenter = GooglePresenterFake(events: events)
    let facade = makeFacade(auth: auth, presenter: presenter)

    try await facade.reauthenticateWithGoogle(revoke: true)

    #expect(events.values == ["google.present", "auth.googleReauth", "google.disconnect"])

    events.values = []
    try await facade.reauthenticateWithGoogle(revoke: false)
    #expect(events.values == ["google.present", "auth.googleReauth"])

    events.values = []
    auth.googleReauthenticationError = CloudGatewayAppError.requiresRecentLogin
    await #expect(throws: CloudGatewayAppError.self) {
        try await facade.reauthenticateWithGoogle(revoke: true)
    }
    #expect(events.values == ["google.present", "auth.googleReauth"])
}

@MainActor
@Test func appServiceFacadeClearsGoogleSessionBeforeFirebaseSignOut() throws {
    let events = EventLog()
    let auth = FacadeAuthFake(events: events)
    let facade = makeFacade(auth: auth, presenter: GooglePresenterFake(events: events))

    try facade.signOut()

    #expect(events.values == ["google.signOut", "auth.signOut"])

    events.values = []
    auth.signOutError = CloudGatewayAppError.missingCurrentUser
    #expect(throws: CloudGatewayAppError.self) {
        try facade.signOut()
    }
    #expect(events.values == ["google.signOut", "auth.signOut"])
}

@MainActor
@Test func appServiceFacadePinsGoogleAccountActionsToInitiatingUser() async throws {
    let events = EventLog()
    let auth = FacadeAuthFake(events: events)
    let presenter = GooglePresenterFake(events: events)
    let facade = makeFacade(auth: auth, presenter: presenter)
    let initiatingUser = AuthenticatedUser(uid: "user-a", email: "a@example.com")
    let replacementUser = AuthenticatedUser(uid: "user-b", email: "b@example.com")

    auth.user = initiatingUser
    presenter.onPresent = { auth.user = replacementUser }
    await #expect(throws: CloudGatewayAppError.self) {
        _ = try await facade.linkGoogle()
    }
    #expect(auth.googleLinkExpectedUserIds == ["user-a"])

    auth.user = initiatingUser
    await #expect(throws: CloudGatewayAppError.self) {
        try await facade.reauthenticateWithGoogle(revoke: true)
    }
    #expect(auth.googleReauthenticationExpectedUserIds == ["user-a"])
    #expect(!events.values.contains("google.disconnect"))

    presenter.onPresent = nil
    auth.user = initiatingUser
    _ = try await facade.linkGoogle()
    #expect(auth.googleLinkExpectedUserIds == ["user-a", "user-a"])
}

@MainActor
@Test func appServiceFacadePinsAppleAndPasswordAccountActionsToInitiatingUser() async throws {
    let events = EventLog()
    let auth = FacadeAuthFake(events: events)
    let presenter = GooglePresenterFake(events: events)
    let facade = makeFacade(auth: auth, presenter: presenter)
    let initiatingUser = AuthenticatedUser(uid: "user-a", email: "a@example.com")

    auth.user = initiatingUser
    _ = try await facade.linkEmailPassword(email: "a@example.com", password: "pw")
    #expect(auth.passwordLinkExpectedUserIds == ["user-a"])

    auth.user = initiatingUser
    _ = try await facade.linkApple(idToken: "tok", rawNonce: "nonce")
    #expect(auth.appleLinkExpectedUserIds == ["user-a"])

    auth.user = initiatingUser
    try await facade.reauthenticateWithPassword("pw")
    #expect(auth.passwordReauthenticationExpectedUserIds == ["user-a"])

    auth.user = initiatingUser
    try await facade.reauthenticateWithApple(
        idToken: "tok",
        rawNonce: "nonce",
        authorizationCode: "code",
        revoke: false
    )
    #expect(auth.appleReauthenticationExpectedUserIds == ["user-a"])

    auth.user = nil
    await #expect(throws: CloudGatewayAppError.self) {
        _ = try await facade.linkEmailPassword(email: "a@example.com", password: "pw")
    }
    await #expect(throws: CloudGatewayAppError.self) {
        _ = try await facade.linkApple(idToken: "tok", rawNonce: "nonce")
    }
    await #expect(throws: CloudGatewayAppError.self) {
        try await facade.reauthenticateWithPassword("pw")
    }
    await #expect(throws: CloudGatewayAppError.self) {
        try await facade.reauthenticateWithApple(
            idToken: "tok",
            rawNonce: "nonce",
            authorizationCode: "code",
            revoke: false
        )
    }
}

@MainActor
@Test func appServiceFacadeForwardsAppleRevocationAndGoogleCancellation() async throws {
    let events = EventLog()
    let auth = FacadeAuthFake(events: events)
    let presenter = GooglePresenterFake(events: events)
    let facade = makeFacade(auth: auth, presenter: presenter)

    try await facade.reauthenticateWithApple(
        idToken: "apple-id",
        rawNonce: "nonce",
        authorizationCode: "code",
        revoke: true
    )
    try await facade.reauthenticateWithApple(
        idToken: "apple-id",
        rawNonce: "nonce",
        authorizationCode: "code",
        revoke: false
    )
    #expect(auth.appleRevokeFlags == [true, false])

    presenter.presentationError = CloudGatewayAppError.cancelled
    await #expect(throws: CloudGatewayAppError.self) {
        _ = try await facade.signInWithGoogle()
    }
    #expect(auth.googleSignInCount == 0)
}

@MainActor
@Test func appServiceFacadeDelegatesRepositoriesAndDecoratesCreatedClient() async throws {
    let auth = FacadeAuthFake(events: EventLog())
    auth.user = AuthenticatedUser(uid: "owner-after-request", email: "owner@example.com")
    let repository = FacadeRepositoryFake()
    repository.role = "admin"
    repository.ownedClients = [client("owned")]
    let controlPlane = FacadeControlPlaneFake()
    let facade = CloudGatewayAppServiceFacade(
        auth: auth,
        repository: repository,
        controlPlane: controlPlane,
        googlePresenter: GooglePresenterFake(events: EventLog())
    )

    let role = try await facade.fetchUserRole(uid: "owner-after-request")
    let owned = try await facade.fetchOwnedClients(uid: "owner-after-request")
    let created = try await facade.createClient(
        regionId: "us-a",
        clientName: "Phone",
        idToken: "token"
    )

    #expect(role == "admin")
    #expect(owned.map(\.clientId) == ["owned"])
    #expect(repository.lastRoleUID == "owner-after-request")
    #expect(repository.lastOwnedUID == "owner-after-request")
    #expect(controlPlane.createArguments == .init(
        regionId: "us-a",
        clientName: "Phone",
        idToken: "token"
    ))
    #expect(created.ownerUid == "owner-after-request")
    #expect(created.ownerEmail == "owner@example.com")
}

@MainActor
@Test func appServiceFacadeForwardsMeshRepositoryCallsUnchanged() async throws {
    let repository = FacadeRepositoryFake()
    let region = CloudGatewayMeshRegion(
        regionId: "us-a",
        displayName: "US A",
        enabled: true,
        displayOrder: 1,
        meshEnabled: true,
        wireguardPublicKey: nil,
        wireguardEndpointHostname: nil,
        wireguardPort: nil,
        tunnelNetworkV4: nil,
        tunnelNetworkV6: nil
    )
    let doc = CloudGatewayMeshDoc(regionId: "us-a", meshEnabled: true, updatedAt: nil, peers: [:])
    repository.meshRegions = [region]
    repository.meshDocs = ["us-a": doc]
    let facade = CloudGatewayAppServiceFacade(
        auth: FacadeAuthFake(events: EventLog()),
        repository: repository,
        controlPlane: FacadeControlPlaneFake(),
        googlePresenter: GooglePresenterFake(events: EventLog())
    )

    let regions = try await facade.fetchMeshRegions()
    let docs = try await facade.fetchMeshDocs()
    try await facade.setRegionMeshEnabled(regionId: "us-b", enabled: false)

    #expect(regions == [region])
    #expect(docs == ["us-a": doc])
    #expect(repository.lastSetMeshEnabledRegionId == "us-b")
    #expect(repository.lastSetMeshEnabledFlag == false)
}

@MainActor
@Test func appServiceFacadeForwardsSyncRegionsToControlPlaneUnchanged() async throws {
    let controlPlane = FacadeControlPlaneFake()
    let firstOutcome = CloudGatewayRegionSyncOutcome(regionId: "us-a", result: .alreadyRunning)
    let secondOutcome = CloudGatewayRegionSyncOutcome(
        regionId: "us-b",
        result: .failure(message: "boom", requestId: "req-1", isIncompatibleResponse: false)
    )
    controlPlane.syncRegionsOutcomes = [firstOutcome, secondOutcome]
    let facade = CloudGatewayAppServiceFacade(
        auth: FacadeAuthFake(events: EventLog()),
        repository: FacadeRepositoryFake(),
        controlPlane: controlPlane,
        googlePresenter: GooglePresenterFake(events: EventLog())
    )

    let outcomes = await facade.syncRegions(regionIds: ["us-a", "us-b"], idToken: "token")

    #expect(outcomes == [firstOutcome, secondOutcome])
    #expect(controlPlane.syncRegionsArguments == .init(regionIds: ["us-a", "us-b"], idToken: "token"))
}

@Test func firestoreClientMapperPreservesDocumentFallbackAndSanitization() {
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let mapped = CloudGatewayFirestoreClientMapper.client(
        documentId: "document-client",
        regionFallback: "fallback-region",
        data: [
            "status": "active",
            "clientName": "  Phone  ",
            "wireguardConfig": "  config  ",
            "updatedAt": updatedAt,
            "ownerUid": " owner ",
            "ownerEmail": "   ",
            "email": " fallback@example.com ",
        ]
    )

    #expect(mapped?.clientId == "document-client")
    #expect(mapped?.regionId == "fallback-region")
    #expect(mapped?.clientName == "Phone")
    #expect(mapped?.wireGuardConfig == "config")
    #expect(mapped?.updatedAt == updatedAt)
    #expect(mapped?.ownerUid == "owner")
    #expect(mapped?.ownerEmail == "fallback@example.com")

    #expect(CloudGatewayFirestoreClientMapper.client(
        documentId: "client",
        regionFallback: "region",
        data: ["status": "unknown"]
    ) == nil)
    #expect(CloudGatewayFirestoreClientMapper.client(
        documentId: "",
        regionFallback: nil,
        data: ["status": "active"]
    ) == nil)
}

@MainActor
private func makeFacade(
    auth: FacadeAuthFake,
    presenter: GooglePresenterFake
) -> CloudGatewayAppServiceFacade {
    CloudGatewayAppServiceFacade(
        auth: auth,
        repository: FacadeRepositoryFake(),
        controlPlane: FacadeControlPlaneFake(),
        googlePresenter: presenter
    )
}

private func client(_ id: String) -> CloudGatewayClient {
    CloudGatewayClient(
        clientId: id,
        clientName: id,
        regionId: "us-a",
        status: .active,
        wireGuardConfig: nil,
        assignedTunnelIpv4: nil,
        serverEndpointIpv4: nil,
        serverEndpointHostname: nil,
        updatedAt: nil,
        ownerUid: nil,
        ownerEmail: nil
    )
}

@MainActor
private final class EventLog {
    var values: [String] = []
}

@MainActor
private final class GooglePresenterFake: CloudGatewayGoogleSignInPresenting {
    private let events: EventLog
    var presentationError: Error?
    var onPresent: (() -> Void)?

    init(events: EventLog) {
        self.events = events
    }

    func presentCredentials() async throws -> CloudGatewayGoogleCredentials {
        events.values.append("google.present")
        onPresent?()
        if let presentationError {
            throw presentationError
        }
        return CloudGatewayGoogleCredentials(idToken: "id", accessToken: "access")
    }

    func signOut() {
        events.values.append("google.signOut")
    }

    func disconnect() async throws {
        events.values.append("google.disconnect")
    }
}

@MainActor
private final class FacadeAuthFake: CloudGatewayAuthServicing {
    private let events: EventLog
    var user: AuthenticatedUser? = AuthenticatedUser(uid: "user", email: "user@example.com")
    var googleReauthenticationError: Error?
    var signOutError: Error?
    var appleRevokeFlags: [Bool] = []
    var googleSignInCount = 0
    var googleLinkExpectedUserIds: [String] = []
    var googleReauthenticationExpectedUserIds: [String] = []
    var passwordLinkExpectedUserIds: [String] = []
    var appleLinkExpectedUserIds: [String] = []
    var passwordReauthenticationExpectedUserIds: [String] = []
    var appleReauthenticationExpectedUserIds: [String] = []

    init(events: EventLog) {
        self.events = events
    }

    var currentUser: AuthenticatedUser? { user }

    func addAuthStateListener(
        _: @escaping (AuthenticatedUser?) -> Void
    ) -> CloudGatewayAuthStateListenerRegistration {
        CloudGatewayAuthStateListenerRegistration(cancellation: {})
    }

    func signIn(email _: String, password _: String) async throws -> AuthenticatedUser { try requiredUser() }
    func signInWithApple(idToken _: String, rawNonce _: String) async throws -> AuthenticatedUser { try requiredUser() }
    func signInWithGoogle(credentials _: CloudGatewayGoogleCredentials) async throws -> AuthenticatedUser {
        googleSignInCount += 1
        return try requiredUser()
    }
    func providerIds() -> [String] { [] }
    func linkEmailPassword(
        email _: String,
        password _: String,
        expectedUserId: String
    ) async throws -> AuthenticatedUser {
        passwordLinkExpectedUserIds.append(expectedUserId)
        return try requiredUser(expectedUserId: expectedUserId)
    }
    func linkApple(
        idToken _: String,
        rawNonce _: String,
        expectedUserId: String
    ) async throws -> AuthenticatedUser {
        appleLinkExpectedUserIds.append(expectedUserId)
        return try requiredUser(expectedUserId: expectedUserId)
    }
    func linkGoogle(
        credentials _: CloudGatewayGoogleCredentials,
        expectedUserId: String
    ) async throws -> AuthenticatedUser {
        googleLinkExpectedUserIds.append(expectedUserId)
        return try requiredUser(expectedUserId: expectedUserId)
    }
    func reauthenticateWithPassword(_: String, expectedUserId: String) async throws {
        passwordReauthenticationExpectedUserIds.append(expectedUserId)
        _ = try requiredUser(expectedUserId: expectedUserId)
    }
    func reauthenticateWithApple(
        idToken _: String,
        rawNonce _: String,
        authorizationCode _: String,
        revoke: Bool,
        expectedUserId: String
    ) async throws {
        appleReauthenticationExpectedUserIds.append(expectedUserId)
        _ = try requiredUser(expectedUserId: expectedUserId)
        appleRevokeFlags.append(revoke)
    }

    func reauthenticateWithGoogle(
        credentials _: CloudGatewayGoogleCredentials,
        expectedUserId: String
    ) async throws {
        events.values.append("auth.googleReauth")
        googleReauthenticationExpectedUserIds.append(expectedUserId)
        _ = try requiredUser(expectedUserId: expectedUserId)
        if let googleReauthenticationError {
            throw googleReauthenticationError
        }
    }

    func sendPasswordReset(email _: String) async throws {}

    func signOut() throws {
        events.values.append("auth.signOut")
        if let signOutError {
            throw signOutError
        }
    }

    func idToken(forceRefresh _: Bool) async throws -> String { "token" }

    private func requiredUser() throws -> AuthenticatedUser {
        guard let user else { throw CloudGatewayAppError.missingCurrentUser }
        return user
    }

    private func requiredUser(expectedUserId: String) throws -> AuthenticatedUser {
        let user = try requiredUser()
        guard user.uid == expectedUserId else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        return user
    }
}

@MainActor
private final class FacadeRepositoryFake: CloudGatewayClientRepository {
    var role: String?
    var ownedClients: [CloudGatewayClient] = []
    var allClients: [CloudGatewayClient] = []
    var meshRegions: [CloudGatewayMeshRegion] = []
    var meshDocs: [String: CloudGatewayMeshDoc] = [:]
    var lastRoleUID: String?
    var lastOwnedUID: String?
    var lastSetMeshEnabledRegionId: String?
    var lastSetMeshEnabledFlag: Bool?

    func fetchUserRole(uid: String) async throws -> String? {
        lastRoleUID = uid
        return role
    }

    func fetchOwnedClients(uid: String) async throws -> [CloudGatewayClient] {
        lastOwnedUID = uid
        return ownedClients
    }

    func fetchAllClients() async throws -> [CloudGatewayClient] { allClients }

    func fetchMeshRegions() async throws -> [CloudGatewayMeshRegion] { meshRegions }

    func fetchMeshDocs() async throws -> [String: CloudGatewayMeshDoc] { meshDocs }

    func setRegionMeshEnabled(regionId: String, enabled: Bool) async throws {
        lastSetMeshEnabledRegionId = regionId
        lastSetMeshEnabledFlag = enabled
    }
}

private final class FacadeControlPlaneFake: CloudGatewayControlPlaneServicing, @unchecked Sendable {
    struct CreateArguments: Equatable {
        // periphery:ignore - compared via synthesized Equatable
        let regionId: String
        // periphery:ignore - compared via synthesized Equatable
        let clientName: String
        // periphery:ignore - compared via synthesized Equatable
        let idToken: String
    }

    struct SyncRegionsArguments: Equatable {
        // periphery:ignore - compared via synthesized Equatable
        let regionIds: [String]
        // periphery:ignore - compared via synthesized Equatable
        let idToken: String
    }

    private let lock = NSLock()
    private var storedCreateArguments: CreateArguments?
    private var storedSyncRegionsArguments: SyncRegionsArguments?

    var createArguments: CreateArguments? {
        lock.withLock { storedCreateArguments }
    }

    var syncRegionsArguments: SyncRegionsArguments? {
        lock.withLock { storedSyncRegionsArguments }
    }

    var syncRegionsOutcomes: [CloudGatewayRegionSyncOutcome] = []

    func fetchRegions() async throws -> [CloudGatewayRegion] { [] }
    func addCapacity(to regions: [CloudGatewayRegion], idToken: String) async -> [CloudGatewayRegion] { regions }

    func checkAccess(idToken: String) async throws -> CloudGatewayAccessCheck {
        CloudGatewayAccessCheck(userId: "user", email: nil, role: "user")
    }

    func createClient(
        regionId: String,
        clientName: String,
        idToken: String
    ) async throws -> CloudGatewayCreateClientResponse {
        lock.withLock {
            storedCreateArguments = CreateArguments(
                regionId: regionId,
                clientName: clientName,
                idToken: idToken
            )
        }
        return CloudGatewayCreateClientResponse(
            clientId: "created",
            regionId: regionId,
            clientName: clientName,
            status: .active,
            wireguardConfig: "config",
            assignedTunnelIpv4: nil,
            serverEndpointIpv4: nil,
            serverEndpointHostname: nil
        )
    }

    func deleteClient(clientId: String, userId: String, regionId: String, idToken: String) async throws -> CloudGatewayDeleteClientResponse {
        CloudGatewayDeleteClientResponse(userId: userId, clientId: clientId, regionId: regionId, status: .removed)
    }

    func deleteAccount(idToken: String) async throws -> CloudGatewayDeleteAccountResponse {
        CloudGatewayDeleteAccountResponse(userId: "user", deletedClientCount: 0)
    }

    func syncRegions(regionIds: [String], idToken: String) async -> [CloudGatewayRegionSyncOutcome] {
        lock.withLock {
            storedSyncRegionsArguments = SyncRegionsArguments(regionIds: regionIds, idToken: idToken)
        }
        return syncRegionsOutcomes
    }

    func grantAccess(email: String, regionId: String, idToken: String) async throws -> CloudGatewayGrantAccessResponse {
        CloudGatewayGrantAccessResponse(email: email, alreadyExisted: false)
    }
}
