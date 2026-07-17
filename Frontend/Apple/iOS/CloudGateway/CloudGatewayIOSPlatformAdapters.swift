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
