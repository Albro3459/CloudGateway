import CloudGatewayKit
import FirebaseAuth
import FirebaseFirestore
import Foundation

extension CloudGatewayViewModel {
    /// Production wiring: the live Firebase service + a config manager backed by the
    /// packet-tunnel VPN manager and on-disk cache. Kept out of the Firebase-free core
    /// so the view model can be unit-tested against a mock service.
    convenience init() {
        let platform = GatewayPlatformConfiguration(
            appGroupIdentifier: "group.com.gocloudlaunch.gateway",
            appBundleIdentifier: "com.gocloudlaunch.gateway",
            providerBundleIdentifier: "com.gocloudlaunch.gateway.tunnel",
            tunnelDisplayName: "CloudGateway"
        )
        self.init(
            service: CloudGatewayFirebaseService(),
            configManager: CloudGatewayConfigManager(
                tunnelManager: GatewayVPNManager(platform: platform),
                cache: CloudGatewayConfigCache(platform: platform)
            )
        )
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

final class CloudGatewayFirebaseService: CloudGatewayServicing {
    private let db = Firestore.firestore()
    private let apiOriginHost = "gocloudlaunch.com"

    var currentUser: AuthenticatedUser? {
        Auth.auth().currentUser.map(AuthenticatedUser.init)
    }

    func addAuthStateListener(_ listener: @escaping (AuthenticatedUser?) -> Void) -> Any {
        Auth.auth().addStateDidChangeListener { _, user in
            listener(user.map(AuthenticatedUser.init))
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
                    continuation.resume(throwing: error)
                    return
                }
                guard let user = result?.user else {
                    continuation.resume(throwing: CloudGatewayAppError.missingCurrentUser)
                    return
                }
                continuation.resume(returning: AuthenticatedUser(user))
            }
        }
    }

    func signOut() throws {
        try Auth.auth().signOut()
    }

    func idToken() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        return try await withCheckedThrowingContinuation { continuation in
            user.getIDToken { token, error in
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

    func fetchEnabledRegions() async throws -> [CloudGatewayRegion] {
        let snapshot = try await getDocuments(
            db.collection("Regions").whereField("enabled", isEqualTo: true)
        )
        let regions = snapshot.documents.compactMap { document in
            region(from: document.documentID, data: document.data())
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
        try await sendJSONRequest(
            url: firstEnabledRegionURL(regions: regions, path: "auth/check-access"),
            method: "POST",
            idToken: idToken,
            body: EmptyRequest()
        )
    }

    func fetchCapacity(regionId: String, idToken: String) async throws -> CloudGatewayCapacityResponse {
        try await sendJSONRequest(
            url: regionalAPIURL(regionId: regionId, path: "capacity"),
            method: "GET",
            idToken: idToken
        )
    }

    func createClient(
        regionId: String,
        clientName: String?,
        idToken: String
    ) async throws -> CloudGatewayClient {
        let response: CloudGatewayCreateClientResponse = try await sendJSONRequest(
            url: regionalAPIURL(regionId: regionId, path: "clients"),
            method: "POST",
            idToken: idToken,
            body: CreateClientRequest(
                regionId: regionId,
                clientName: clientName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
        )
        return CloudGatewayClient(
            clientId: response.clientId,
            clientName: response.clientName,
            regionId: response.regionId,
            status: response.status,
            wireGuardConfig: response.wireguardConfig,
            updatedAt: nil
        )
    }

    func deleteClient(
        clientId: String,
        userId: String,
        regionId: String,
        idToken: String
    ) async throws -> CloudGatewayDeleteClientResponse {
        try await sendJSONRequest(
            url: regionalAPIURL(regionId: regionId, path: "clients/\(clientId)"),
            method: "DELETE",
            idToken: idToken,
            body: DeleteClientRequest(userId: userId, regionId: regionId)
        )
    }

    func syncRegion(regionId: String, idToken: String) async throws -> CloudGatewayRegionSyncResponse {
        try await sendJSONRequest(
            url: regionalAPIURL(regionId: regionId, path: "admin/sync"),
            method: "POST",
            idToken: idToken,
            body: SyncRegionRequest(regionId: regionId)
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

    private func region(from documentId: String, data: [String: Any]) -> CloudGatewayRegion? {
        let regionId = string(data["regionId"]) ?? documentId
        guard let displayName = string(data["displayName"]), !regionId.isEmpty else {
            return nil
        }
        return CloudGatewayRegion(
            regionId: regionId,
            displayName: displayName,
            enabled: bool(data["enabled"]),
            displayOrder: int(data["displayOrder"]) ?? 1000
        )
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
            updatedAt: date(data["updatedAt"])
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

    private func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return false
    }

    private func int(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private func date(_ value: Any?) -> Date? {
        if let value = value as? Timestamp {
            return value.dateValue()
        }
        return value as? Date
    }

    private func firstEnabledRegionURL(regions: [CloudGatewayRegion], path: String) throws -> URL {
        guard let region = CloudGatewayConfigSelection.sortedRegions(regions).first(where: \.enabled) else {
            throw CloudGatewayAppError.noEnabledRegions
        }
        return regionalAPIURL(regionId: region.regionId, path: path)
    }

    private func regionalAPIURL(regionId: String, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(regionId).\(apiOriginHost)"
        components.path = "/api/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        return components.url!
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

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
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

private extension AuthenticatedUser {
    init(_ user: User) {
        self.init(uid: user.uid, email: user.email)
    }
}

private struct EmptyRequest: Encodable {}

private struct CreateClientRequest: Encodable {
    let regionId: String
    let clientName: String?
}

private struct DeleteClientRequest: Encodable {
    let userId: String
    let regionId: String
}

private struct SyncRegionRequest: Encodable {
    let regionId: String
}

private extension JSONDecoder {
    static var gatewayAPI: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
