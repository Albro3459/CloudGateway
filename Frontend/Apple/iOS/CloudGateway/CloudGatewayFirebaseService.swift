import CloudGatewayKit
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import GoogleSignIn
import UIKit

extension CloudGatewayViewModel {
    /// Production wiring: the live Firebase service + a config manager backed by the
    /// packet-tunnel VPN manager and on-disk cache. Kept out of the Firebase-free core
    /// so the view model can be unit-tested against a mock service.
    convenience init() {
        let keychainAccessGroupIdentifier = Self.cloudGatewayKeychainAccessGroup()
        let platform = GatewayPlatformConfiguration(
            appGroupIdentifier: "group.com.gocloudlaunch.gateway",
            appBundleIdentifier: "com.gocloudlaunch.gateway",
            providerBundleIdentifier: "com.gocloudlaunch.gateway.tunnel",
            tunnelDisplayName: "CloudGateway",
            keychainAccessGroupIdentifier: keychainAccessGroupIdentifier
        )
        self.init(
            service: CloudGatewayFirebaseService(),
            configManager: CloudGatewayConfigManager(
                tunnelManager: GatewayVPNManager(platform: platform),
                cache: CloudGatewayConfigCache(platform: platform),
                secretStore: GatewayKeychainConfigSecretStore(
                    accessGroup: platform.keychainAccessGroupIdentifier
                ),
                configSecretServiceName: platform.configSecretServiceName
            ),
            healthReader: CloudGatewayTunnelHealthReader(
                store: GatewayTunnelHealthStore(appGroupIdentifier: platform.appGroupIdentifier)
            )
        )
    }

    private static func cloudGatewayKeychainAccessGroup() -> String {
        do {
            return try CloudGatewayRuntimeConfiguration.keychainAccessGroup(
                Bundle.main.object(forInfoDictionaryKey: "CGKeychainAccessGroup")
            )
        } catch {
            preconditionFailure(error.localizedDescription)
        }
    }
}

struct CloudGatewayTunnelHealthReader: CloudGatewayTunnelHealthReading {
    let store: GatewayTunnelHealthStore

    func currentSnapshot() -> GatewayTunnelHealthSnapshot? {
        try? store.read()
    }
}

struct CloudGatewayCreateClientResponse: Decodable, Equatable {
    let clientId: String
    let regionId: String
    let clientName: String
    let status: CloudGatewayClientStatus
    let wireguardConfig: String
}

struct CloudGatewayCapacityResponse: Decodable, Equatable {
    let regionId: String
    let capacityLimit: Int
    let allocatedClientCount: Int
}

struct CloudGatewayRegionsResponse: Decodable, Equatable {
    struct Region: Decodable, Equatable {
        let regionId: String
        let displayName: String
        let displayOrder: Int
    }

    let regions: [Region]
}

final class CloudGatewayFirebaseService: CloudGatewayServicing {
    private let db = Firestore.firestore()
    private let apiOriginHost = "gocloudlaunch.com"
    // Bounded request timeout so a dead/blackholing tunnel fails in ~10s instead
    // of URLSession's 60s default (see GatewayAPISession).
    private let apiSession = GatewayAPISession.makeSession()

    var currentUser: AuthenticatedUser? {
        guard let user = Auth.auth().currentUser else {
            return nil
        }
        return AuthenticatedUser(uid: user.uid, email: user.email)
    }

    func addAuthStateListener(_ listener: @escaping (AuthenticatedUser?) -> Void) -> Any {
        Auth.auth().addStateDidChangeListener { _, user in
            listener(user.map { AuthenticatedUser(uid: $0.uid, email: $0.email) })
        }
    }

    nonisolated func removeAuthStateListener(_ token: Any) {
        guard let handle = token as? AuthStateDidChangeListenerHandle else {
            return
        }
        Auth.auth().removeStateDidChangeListener(handle)
    }

    func signIn(email: String, password: String) async throws -> AuthenticatedUser {
        try await withCheckedThrowingContinuation { continuation in
            Auth.auth().signIn(withEmail: email, password: password) { result, error in
                if let error {
                    continuation.resume(throwing: Self.mapSignInAuthError(error))
                    return
                }
                guard let user = result?.user else {
                    continuation.resume(throwing: CloudGatewayAppError.missingCurrentUser)
                    return
                }
                continuation.resume(returning: AuthenticatedUser(uid: user.uid, email: user.email))
            }
        }
    }

    func signInWithApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser {
        let credential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: rawNonce,
            fullName: nil
        )
        let result = try await Auth.auth().signIn(with: credential)
        return AuthenticatedUser(uid: result.user.uid, email: result.user.email)
    }

    func signInWithGoogle() async throws -> AuthenticatedUser {
        let (idToken, accessToken) = try await Self.presentGoogleSignIn(clientID: googleClientID())
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        let result = try await Auth.auth().signIn(with: credential)
        return AuthenticatedUser(uid: result.user.uid, email: result.user.email)
    }

    func providerIds() -> [String] {
        Auth.auth().currentUser?.providerData.map(\.providerID) ?? []
    }

    func linkEmailPassword(email: String, password: String) async throws -> AuthenticatedUser {
        guard let user = Auth.auth().currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        do {
            let result = try await user.link(with: credential)
            return AuthenticatedUser(uid: result.user.uid, email: result.user.email)
        } catch {
            throw Self.mapAuthError(error)
        }
    }

    func linkApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser {
        guard let user = Auth.auth().currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        let credential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: rawNonce,
            fullName: nil
        )
        do {
            let result = try await user.link(with: credential)
            return AuthenticatedUser(uid: result.user.uid, email: result.user.email)
        } catch {
            throw Self.mapAuthError(error)
        }
    }

    func linkGoogle() async throws -> AuthenticatedUser {
        guard let user = Auth.auth().currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        let (idToken, accessToken) = try await Self.presentGoogleSignIn(clientID: googleClientID())
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        do {
            let result = try await user.link(with: credential)
            return AuthenticatedUser(uid: result.user.uid, email: result.user.email)
        } catch {
            throw Self.mapAuthError(error)
        }
    }

    func reauthenticateWithPassword(_ password: String) async throws {
        guard let user = Auth.auth().currentUser,
              let email = user.email else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        _ = try await user.reauthenticate(with: credential)
    }

    // `revoke` is only for account deletion, which must revoke the Apple grant.
    // Account-linking recovery passes `revoke: false` so re-linking a provider
    // never tears down the user's existing Apple grant.
    func reauthenticateWithApple(idToken: String, rawNonce: String, authorizationCode: String, revoke: Bool) async throws {
        guard let user = Auth.auth().currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        let credential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: rawNonce,
            fullName: nil
        )
        _ = try await user.reauthenticate(with: credential)
        if revoke {
            try await Auth.auth().revokeToken(withAuthorizationCode: authorizationCode)
        }
    }

    // `revoke` is only for account deletion, which must disconnect the Google
    // grant. Account-linking recovery passes `revoke: false` so it does not
    // disconnect a grant merely to link a new provider.
    func reauthenticateWithGoogle(revoke: Bool) async throws {
        guard let user = Auth.auth().currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        let (idToken, accessToken) = try await Self.presentGoogleSignIn(clientID: googleClientID())
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        _ = try await user.reauthenticate(with: credential)
        if revoke {
            try await Self.disconnectGoogle()
        }
    }

    private static func mapAuthError(_ error: Error) -> Error {
        guard let code = authErrorCode(for: error) else {
            return error
        }
        switch code {
        case .requiresRecentLogin:
            return CloudGatewayAppError.requiresRecentLogin
        case .credentialAlreadyInUse, .emailAlreadyInUse:
            return CloudGatewayAppError.credentialAlreadyInUse
        case .providerAlreadyLinked:
            return CloudGatewayAppError.providerAlreadyLinked
        case .invalidEmail:
            return CloudGatewayAppError.invalidEmail
        case .weakPassword:
            return CloudGatewayAppError.weakPassword
        case .wrongPassword, .invalidCredential:
            return CloudGatewayAppError.wrongPassword
        default:
            return error
        }
    }

    private static func mapSignInAuthError(_ error: Error) -> Error {
        guard let code = authErrorCode(for: error) else {
            return error
        }
        return CloudGatewayFirebaseAuthErrorCode.signInError(forRawCode: code.rawValue) ?? error
    }

    private static func authErrorCode(for error: Error) -> AuthErrorCode? {
        let nsError = error as NSError
        return AuthErrorCode(_bridgedNSError: nsError)?.code ?? AuthErrorCode(rawValue: nsError.code)
    }

    private static func disconnectGoogle() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            GIDSignIn.sharedInstance.disconnect { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }

    private func googleClientID() throws -> String {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw CloudGatewayAppError.invalidAPIResponse
        }
        return clientID
    }

    @MainActor
    private static func presentGoogleSignIn(clientID: String) async throws -> (idToken: String, accessToken: String) {
        guard let presenting = topViewController() else {
            throw CloudGatewayAppError.invalidAPIResponse
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenting)
            guard let idToken = result.user.idToken?.tokenString else {
                throw CloudGatewayAppError.invalidAPIResponse
            }
            return (idToken, result.user.accessToken.tokenString)
        } catch let error as GIDSignInError where error.code == .canceled {
            throw CloudGatewayAppError.cancelled
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    func sendPasswordReset(email: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Auth.auth().sendPasswordReset(withEmail: email) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }

    func signOut() throws {
        // Firebase sign-out alone leaves Google Sign-In's current user (and its
        // saved Keychain session) in place, so clear it too.
        GIDSignIn.sharedInstance.signOut()
        try Auth.auth().signOut()
    }

    func idToken(forceRefresh: Bool) async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        return try await withCheckedThrowingContinuation { continuation in
            user.getIDTokenForcingRefresh(forceRefresh) { token, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let token else {
                    continuation.resume(throwing: CloudGatewayAppError.missingCurrentUser)
                    return
                }
                continuation.resume(returning: token)
            }
        }
    }

    func fetchUserRole(uid: String) async throws -> String? {
        let snapshot = try await getDocument(db.collection("UserRoles").document(uid))
        guard snapshot.exists else {
            return nil
        }
        return string(snapshot.data()?["roleId"])
    }

    func fetchRegions() async throws -> [CloudGatewayRegion] {
        let response: CloudGatewayRegionsResponse = try await sendUnauthenticatedRequest(
            url: try apexAPIURL(path: "regions"),
            method: "GET"
        )
        let regions: [CloudGatewayRegion] = response.regions.compactMap { region in
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

    func addCapacity(to regions: [CloudGatewayRegion], idToken: String) async -> [CloudGatewayRegion] {
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

    func checkAccess(idToken: String, regions: [CloudGatewayRegion]) async throws -> CloudGatewayAccessCheck {
        _ = regions
        let response: CloudGatewayAccessCheck = try await sendJSONRequest(
            url: try apexAPIURL(path: "auth/check-access"),
            method: "POST",
            idToken: idToken,
            body: EmptyRequest()
        )
        return response
    }

    func fetchCapacity(regionId: String, idToken: String) async throws -> CloudGatewayCapacityResponse {
        try await sendJSONRequest(
            url: try regionalAPIURL(regionId: regionId, path: "capacity"),
            method: "GET",
            idToken: idToken
        )
    }

    func createClient(
        regionId: String,
        clientName: String,
        idToken: String
    ) async throws -> CloudGatewayClient {
        let response: CloudGatewayCreateClientResponse = try await sendJSONRequest(
            url: try regionalAPIURL(regionId: regionId, path: "clients"),
            method: "POST",
            idToken: idToken,
            body: CreateClientRequest(
                regionId: regionId,
                clientName: clientName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        return CloudGatewayClient(
            clientId: response.clientId,
            clientName: response.clientName,
            regionId: response.regionId,
            status: response.status,
            wireGuardConfig: response.wireguardConfig,
            updatedAt: nil,
            ownerUid: Auth.auth().currentUser?.uid,
            ownerEmail: Auth.auth().currentUser?.email
        )
    }

    func deleteClient(
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

    func deleteAccount(idToken: String) async throws -> CloudGatewayDeleteAccountResponse {
        try await sendJSONRequest(
            url: try apexAPIURL(path: "account"),
            method: "DELETE",
            idToken: idToken
        )
    }

    func syncRegion(regionId: String, idToken: String) async throws -> CloudGatewayRegionSyncResponse {
        try await sendJSONRequest(
            url: try regionalAPIURL(regionId: regionId, path: "admin/sync"),
            method: "POST",
            idToken: idToken,
            body: SyncRegionRequest(regionId: regionId)
        )
    }

    func grantAccess(email: String, regionId: String, idToken: String) async throws -> CloudGatewayGrantAccessResponse {
        try await sendJSONRequest(
            url: try regionalAPIURL(regionId: regionId, path: "users"),
            method: "POST",
            idToken: idToken,
            body: GrantAccessRequest(email: email)
        )
    }

    func fetchOwnedClients(uid: String) async throws -> [CloudGatewayClient] {
        let snapshot = try await getDocuments(
            db.collectionGroup("Instances").whereField("ownerUid", isEqualTo: uid)
        )
        return snapshot.documents.compactMap { document in
            let regionFallback = document.reference.parent.parent?.documentID
            return client(from: document.documentID, regionFallback: regionFallback, data: document.data())
        }
    }

    func fetchAllClients() async throws -> [CloudGatewayClient] {
        let snapshot = try await getDocuments(db.collectionGroup("Instances"))
        return snapshot.documents.compactMap { document in
            let regionFallback = document.reference.parent.parent?.documentID
            return client(from: document.documentID, regionFallback: regionFallback, data: document.data())
        }
    }

    private func getDocuments(_ query: Query) async throws -> QuerySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            query.getDocuments { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let snapshot else {
                    continuation.resume(throwing: CloudGatewayAppError.invalidAPIResponse)
                    return
                }
                continuation.resume(returning: snapshot)
            }
        }
    }

    private func getDocument(_ reference: DocumentReference) async throws -> DocumentSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            reference.getDocument { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let snapshot else {
                    continuation.resume(throwing: CloudGatewayAppError.invalidAPIResponse)
                    return
                }
                continuation.resume(returning: snapshot)
            }
        }
    }

    private func client(
        from documentId: String,
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
            updatedAt: date(data["updatedAt"]),
            ownerUid: string(data["ownerUid"]),
            ownerEmail: string(data["ownerEmail"]) ?? string(data["email"])
        )
    }

    private func apiErrorMessage(from data: Data) -> String? {
        struct ErrorResponse: Decodable {
            struct Detail: Decodable {
                let code: String?
                let message: String?
            }
            let error: Detail?
        }

        guard let response = try? JSONDecoder().decode(ErrorResponse.self, from: data) else {
            return nil
        }
        return response.error?.message ?? response.error?.code
    }

    private func string(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func date(_ value: Any?) -> Date? {
        if let value = value as? Timestamp {
            return value.dateValue()
        }
        return value as? Date
    }

    private func apexAPIURL(path: String) throws -> URL {
        try CloudGatewayAPIURLBuilder.apexAPIURL(originHost: apiOriginHost, path: path)
    }

    private func regionalAPIURL(regionId: String, path: String) throws -> URL {
        try CloudGatewayAPIURLBuilder.regionalAPIURL(originHost: apiOriginHost, regionId: regionId, path: path)
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
        let (data, response) = try await apiSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudGatewayAppError.invalidAPIResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CloudGatewayAppError.accessDenied(apiErrorMessage(from: data) ?? "CloudGateway API request failed.")
        }
        do {
            return try JSONDecoder.gatewayAPI.decode(Response.self, from: data)
        } catch {
            throw CloudGatewayAppError.invalidAPIResponse
        }
    }
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
