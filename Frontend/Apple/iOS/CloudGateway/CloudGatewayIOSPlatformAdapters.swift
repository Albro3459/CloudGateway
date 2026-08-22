import CloudGatewayAppCore
import CloudGatewayKit
import FirebaseFirestore
import Foundation
import GoogleSignIn
import UIKit

struct CloudGatewayTunnelHealthReader: CloudGatewayTunnelHealthReading {
    let store: CloudGatewayTunnelHealthStore

    func currentSnapshot() -> CloudGatewayTunnelHealthSnapshot? {
        try? store.read()
    }
}

@MainActor
final class CloudGatewayIOSFirestoreRepository: CloudGatewayClientRepository {
    private let database: Firestore

    init(database: Firestore) {
        self.database = database
    }

    func fetchUserRole(uid: String) async throws -> String? {
        let snapshot = try await getDocument(database.collection("UserRoles").document(uid))
        guard snapshot.exists else {
            return nil
        }
        return CloudGatewayFirestoreClientMapper.string(snapshot.data()?["roleId"])
    }

    func fetchOwnedClients(uid: String) async throws -> [CloudGatewayClient] {
        let snapshot = try await getDocuments(
            database.collectionGroup("Instances").whereField("ownerUid", isEqualTo: uid)
        )
        return clients(from: snapshot)
    }

    func fetchAllClients() async throws -> [CloudGatewayClient] {
        clients(from: try await getDocuments(database.collectionGroup("Instances")))
    }

    func fetchMeshRegions() async throws -> [CloudGatewayMeshRegion] {
        let snapshot = try await getDocuments(database.collection("Regions"))
        let regions = snapshot.documents.compactMap {
            CloudGatewayFirestoreMeshMapper.meshRegion(documentId: $0.documentID, data: $0.data())
        }
        return sortedMeshRegions(regions)
    }

    func fetchMeshDocs() async throws -> [String: CloudGatewayMeshDoc] {
        let snapshot = try await getDocuments(database.collection("Mesh"))
        var docs: [String: CloudGatewayMeshDoc] = [:]
        for document in snapshot.documents {
            let data = convertingTimestamps(document.data())
            docs[document.documentID] = CloudGatewayFirestoreMeshMapper.meshDoc(documentId: document.documentID, data: data)
        }
        return docs
    }

    // Policy/* is observability-only: written by the regional host via the Admin SDK
    // per firestore.rules, and never written by this client.
    func fetchPolicyDocs() async throws -> [String: CloudGatewayPolicyDoc] {
        let snapshot = try await getDocuments(database.collection("Policy"))
        var docs: [String: CloudGatewayPolicyDoc] = [:]
        for document in snapshot.documents {
            let data = convertingTimestamps(document.data())
            docs[document.documentID] = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: document.documentID, data: data)
        }
        return docs
    }

    func setRegionMeshEnabled(regionId: String, enabled: Bool) async throws {
        try await updateDocument(database.collection("Regions").document(regionId), fields: ["meshEnabled": enabled])
    }

    private func clients(from snapshot: QuerySnapshot) -> [CloudGatewayClient] {
        snapshot.documents.compactMap { document in
            var data = document.data()
            if let timestamp = data["updatedAt"] as? Timestamp {
                data["updatedAt"] = timestamp.dateValue()
            }
            return CloudGatewayFirestoreClientMapper.client(
                documentId: document.documentID,
                regionFallback: document.reference.parent.parent?.documentID,
                data: data
            )
        }
    }

    // Mirrors CloudGatewayConfigSelection.sortedRegions (display order, then
    // display name, then region ID), which operates on the API-shaped
    // CloudGatewayRegion and cannot be reused directly for mesh regions.
    private func sortedMeshRegions(_ regions: [CloudGatewayMeshRegion]) -> [CloudGatewayMeshRegion] {
        regions.sorted { lhs, rhs in
            if lhs.displayOrder != rhs.displayOrder {
                return lhs.displayOrder < rhs.displayOrder
            }
            let displayNameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if displayNameComparison != .orderedSame {
                return displayNameComparison == .orderedAscending
            }
            return lhs.regionId.localizedCaseInsensitiveCompare(rhs.regionId) == .orderedAscending
        }
    }

    // CloudGatewayFirestoreMeshMapper and CloudGatewayFirestorePolicyMapper live in
    // CloudGatewayAppCore and cannot import FirebaseFirestore, so every Timestamp
    // (top-level updatedAt, appliedAt nested inside each peers.{regionId} entry, and
    // the Policy doc's updatedAt) must become a Date before it reaches the mapper.
    private func convertingTimestamps(_ data: [String: Any]) -> [String: Any] {
        data.mapValues { convertingTimestamps($0) }
    }

    private func convertingTimestamps(_ value: Any) -> Any {
        if let timestamp = value as? Timestamp {
            return timestamp.dateValue()
        }
        if let dict = value as? [String: Any] {
            return dict.mapValues { convertingTimestamps($0) }
        }
        if let array = value as? [Any] {
            return array.map { convertingTimestamps($0) }
        }
        return value
    }

    private func updateDocument(_ reference: DocumentReference, fields: [String: Any]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.updateData(fields) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
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
}

@MainActor
final class CloudGatewayIOSGoogleSignInPresenter: CloudGatewayGoogleSignInPresenting {
    private let clientID: String?

    init(clientID: String?) {
        self.clientID = clientID
    }

    func presentCredentials() async throws -> CloudGatewayGoogleCredentials {
        guard let clientID,
              let presenting = Self.topViewController() else {
            throw CloudGatewayAppError.invalidAPIResponse
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenting)
            guard let idToken = result.user.idToken?.tokenString else {
                throw CloudGatewayAppError.invalidAPIResponse
            }
            return CloudGatewayGoogleCredentials(
                idToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
        } catch let error as GIDSignInError where error.code == .canceled {
            throw CloudGatewayAppError.cancelled
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }

    func disconnect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            GIDSignIn.sharedInstance.disconnect { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
