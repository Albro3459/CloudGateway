import CloudGatewayAppCore
import CloudGatewayFirebaseAuthAdapter
import CloudGatewayKit
import CloudGatewayMacCore
import FirebaseFirestore
import Foundation

@MainActor
final class CloudGatewayMacInventoryService {
    enum Failure: Error {
        case accessDenied
        case offline
        case unavailable

        var cacheFailure: CloudGatewayMacInventoryFailure {
            switch self {
            case .accessDenied: .accessDenied
            case .offline: .transport
            case .unavailable: .invalidResponse
            }
        }
    }

    private let auth: CloudGatewayFirebaseAuthAdapter
    private let database: Firestore
    private let session: URLSession

    init(auth: CloudGatewayFirebaseAuthAdapter, database: Firestore) {
        self.auth = auth
        self.database = database
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = CloudGatewayAPISession.requestTimeout
        configuration.timeoutIntervalForResource = CloudGatewayAPISession.requestTimeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func checkAccess(for user: AuthenticatedUser) async throws -> String {
        guard auth.currentUser?.uid == user.uid else { throw Failure.accessDenied }
        let token: String
        do { token = try await auth.idToken(forceRefresh: false) }
        catch { throw Self.failure(error) }
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
        catch { throw Self.failure(error) }
        try Task.checkCancellation()
        guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse, response.url == request.url else { throw Failure.unavailable }
        if response.statusCode == 401 || response.statusCode == 403 { throw Failure.accessDenied }
        guard response.statusCode == 200, data.count <= 64 * 1024,
              let result = try? JSONDecoder().decode(CloudGatewayAccessCheck.self, from: data),
              result.userId == user.uid,
              result.role == "user" || result.role == "admin" else { throw Failure.unavailable }
        return result.role
    }

    func fetchOptions(for user: AuthenticatedUser, role: String) async throws -> [CloudGatewayClientOption] {
        guard auth.currentUser?.uid == user.uid, role == "user" || role == "admin" else {
            throw Failure.accessDenied
        }
        let regionQuery = database.collection("Regions").whereField("enabled", isEqualTo: true)
        var clientQuery: Query = database.collectionGroup("Instances")
        if role != "admin" { clientQuery = clientQuery.whereField("ownerUid", isEqualTo: user.uid) }
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
            ), role == "admin" || client.ownerUid == user.uid else { return nil }
            return client
        }
        try Task.checkCancellation()
        guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
        let regionsById = Dictionary(uniqueKeysWithValues: regions.map { ($0.regionId, $0) })
        return clients.map { CloudGatewayClientOption(client: $0, region: regionsById[$0.regionId]) }
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
            throw Self.failure(error)
        }
    }

    private static func failure(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let failure = error as? Failure { return failure }
        let error = error as NSError
        if error.domain == "FIRFirestoreErrorDomain" {
            if error.code == 7 || error.code == 16 { return Failure.accessDenied }
            if error.code == 4 || error.code == 14 { return Failure.offline }
        }
        if error.domain == "FIRAuthErrorDomain" {
            if [17005, 17011, 17021, 17020].contains(error.code) {
                return error.code == 17020 ? Failure.offline : Failure.accessDenied
            }
        }
        if error.domain == NSURLErrorDomain,
           [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed].contains(error.code) { return Failure.offline }
        return Failure.unavailable
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
