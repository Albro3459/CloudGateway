import CloudGatewayKit
import FirebaseAuth
import FirebaseFirestore
import Foundation

enum CloudGatewayAppError: LocalizedError {
    case missingCurrentUser
    case noEnabledRegions
    case invalidAPIResponse
    case accessDenied(String)

    var errorDescription: String? {
        switch self {
        case .missingCurrentUser:
            "Sign in again to continue."
        case .noEnabledRegions:
            "No enabled CloudGateway regions are available."
        case .invalidAPIResponse:
            "CloudGateway returned an invalid response."
        case .accessDenied(let message):
            message
        }
    }
}

struct CloudGatewayAccessCheck: Decodable, Equatable {
    let userId: String
    let email: String?
    let role: String
}

final class CloudGatewayFirebaseService {
    private let db = Firestore.firestore()
    private let accessCheckURL = URL(string: "https://us-sanjose-1.gocloudlaunch.com/api/auth/check-access")!

    var currentUser: User? {
        Auth.auth().currentUser
    }

    func addAuthStateListener(_ listener: @escaping (User?) -> Void) -> AuthStateDidChangeListenerHandle {
        Auth.auth().addStateDidChangeListener { _, user in
            listener(user)
        }
    }

    nonisolated func removeAuthStateListener(_ handle: AuthStateDidChangeListenerHandle) {
        Auth.auth().removeStateDidChangeListener(handle)
    }

    func signIn(email: String, password: String) async throws -> User {
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
                continuation.resume(returning: user)
            }
        }
    }

    func signOut() throws {
        try Auth.auth().signOut()
    }

    func idToken(for user: User) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
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

    func checkAccess(idToken: String) async throws -> CloudGatewayAccessCheck {
        var request = URLRequest(url: accessCheckURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudGatewayAppError.invalidAPIResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CloudGatewayAppError.accessDenied(apiErrorMessage(from: data) ?? "Unable to verify account access.")
        }
        do {
            return try JSONDecoder().decode(CloudGatewayAccessCheck.self, from: data)
        } catch {
            throw CloudGatewayAppError.invalidAPIResponse
        }
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
}
