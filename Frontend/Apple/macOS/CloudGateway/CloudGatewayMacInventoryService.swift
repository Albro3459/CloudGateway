import CloudGatewayAppCore
import CloudGatewayFirebaseAuthAdapter
import CloudGatewayKit
import CloudGatewayMacCore
import FirebaseFirestore
import Foundation

@MainActor
final class CloudGatewayMacInventoryService {
    typealias Failure = CloudGatewayMacInventoryError

    private let auth: CloudGatewayFirebaseAuthAdapter
    private let database: Firestore
    private let session: URLSession
    private let controlPlane: CloudGatewayControlPlaneClient

    init(auth: CloudGatewayFirebaseAuthAdapter, database: Firestore) {
        self.auth = auth
        self.database = database
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = CloudGatewayAPISession.requestTimeout
        configuration.timeoutIntervalForResource = CloudGatewayAPISession.requestTimeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        self.session = session
        controlPlane = CloudGatewayControlPlaneClient(originHost: "gocloudlaunch.com", session: session)
    }

    func checkAccess(for user: AuthenticatedUser) async throws -> CloudGatewayMacAccountRole {
        guard auth.currentUser?.uid == user.uid else { throw Failure.accessDenied }
        let token: String
        do { token = try await auth.idToken(forceRefresh: false) }
        catch { throw Failure.classify(error) }
        try Task.checkCancellation()
        guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
        var request = URLRequest(url: try CloudGatewayAPIURLBuilder.apexAPIURL(
            originHost: "gocloudlaunch.com", path: "auth/check-access"
        ), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = CloudGatewayAPISession.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("CloudGateway-macOS/1.0", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw Failure.classify(error) }
        try Task.checkCancellation()
        guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse, response.url == request.url else { throw Failure.unavailable }
        if let failure = Failure.accessResponseFailure(statusCode: response.statusCode) { throw failure }
        guard data.count <= 64 * 1024,
              let result = try? JSONDecoder().decode(CloudGatewayAccessCheck.self, from: data),
              result.userId == user.uid,
              let role = CloudGatewayMacAccountRole(rawValue: result.role) else { throw Failure.unavailable }
        return role
    }

    func fetchOptions(for user: AuthenticatedUser, role: CloudGatewayMacAccountRole) async throws -> [CloudGatewayClientOption] {
        guard auth.currentUser?.uid == user.uid else {
            throw Failure.accessDenied
        }
        let regionQuery = database.collection("Regions").whereField("enabled", isEqualTo: true)
        var clientQuery: Query = database.collectionGroup("Instances")
        if role != .admin { clientQuery = clientQuery.whereField("ownerUid", isEqualTo: user.uid) }
        let regions = try await documents(regionQuery).documents.compactMap { document -> CloudGatewayRegion? in
            let data = document.data()
            guard data["enabled"] as? Bool == true,
                  let name = CloudGatewayFirestoreClientMapper.string(data["displayName"]) else { return nil }
            return CloudGatewayRegion(regionId: document.documentID, displayName: name, enabled: true,
                                      displayOrder: (data["displayOrder"] as? NSNumber)?.intValue ?? 1000)
        }
        try Task.checkCancellation()
        guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
        let clients = try await documents(clientQuery).documents.compactMap { document -> CloudGatewayClient? in
            var data = document.data()
            if let timestamp = data["updatedAt"] as? Timestamp { data["updatedAt"] = timestamp.dateValue() }
            guard let client = CloudGatewayFirestoreClientMapper.client(
                documentId: document.documentID, regionFallback: document.reference.parent.parent?.documentID, data: data
            ), role == .admin || client.ownerUid == user.uid else { return nil }
            return client
        }
        try Task.checkCancellation()
        guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
        let regionsById = Dictionary(uniqueKeysWithValues: regions.map { ($0.regionId, $0) })
        return clients.map { CloudGatewayClientOption(client: $0, region: regionsById[$0.regionId]) }
    }

    func fetchCreateRegions(for user: AuthenticatedUser) async throws -> [CloudGatewayRegion] {
        guard auth.currentUser?.uid == user.uid else { throw Failure.accessDenied }
        let regions = try await controlPlane.fetchRegions()
        try Task.checkCancellation()
        guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
        let token: String
        do { token = try await auth.idToken(forceRefresh: false) }
        catch { throw Failure.classify(error) }
        try Task.checkCancellation()
        guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
        var regionsWithCapacity: [CloudGatewayRegion] = []
        for region in regions {
            let capacity: CloudGatewayRegionCapacity
            do {
                let response = try await controlPlane.fetchCapacity(regionId: region.regionId, idToken: token)
                capacity = response.regionId == region.regionId
                    ? .known(limit: response.capacityLimit, allocated: response.allocatedClientCount) : .unknown
            } catch CloudGatewayAppError.apiAccessDenied(_) {
                try Task.checkCancellation()
                guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
                throw Failure.accessDenied
            } catch {
                capacity = .unknown
            }
            try Task.checkCancellation()
            guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
            regionsWithCapacity.append(CloudGatewayRegion(
                regionId: region.regionId, displayName: region.displayName,
                enabled: region.enabled, displayOrder: region.displayOrder, capacity: capacity
            ))
        }
        return regionsWithCapacity
    }

    func createClient(regionId: String, clientName: String, for user: AuthenticatedUser) async throws -> String {
        guard auth.currentUser?.uid == user.uid else { throw Failure.accessDenied }
        let token: String
        do { token = try await auth.idToken(forceRefresh: false) }
        catch { throw Failure.classify(error) }
        try Task.checkCancellation()
        guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
        let response = try await controlPlane.createClient(regionId: regionId, clientName: clientName, idToken: token)
        try Task.checkCancellation()
        guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
        return response.clientName
    }

    private func documents(_ query: Query) async throws -> QuerySnapshot {
        do {
            try Task.checkCancellation()
            let snapshot: QuerySnapshot = try await withCheckedThrowingContinuation { continuation in
                query.getDocuments(source: .server) { snapshot, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let snapshot { continuation.resume(returning: snapshot) }
                    else { continuation.resume(throwing: Failure.unavailable) }
                }
            }
            try Task.checkCancellation()
            return snapshot
        } catch {
            try Task.checkCancellation()
            throw Failure.classify(error)
        }
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

}
