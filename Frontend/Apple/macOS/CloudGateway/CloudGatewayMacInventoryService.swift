import CloudGatewayAppCore
import CloudGatewayFirebaseAuthAdapter
import CloudGatewayKit
import CloudGatewayMacCore
import FirebaseFirestore
import Foundation

@MainActor
final class CloudGatewayMacInventoryService: CloudGatewayMacInventoryServicing {
    typealias Failure = CloudGatewayMacInventoryError

    private let auth: CloudGatewayFirebaseAuthAdapter
    private var database: Firestore
    private var reconnectBeforeRead = false
    private var reconnectTask: Task<Void, Error>?
    private let session: URLSession
    private let controlPlane: CloudGatewayControlPlaneClient
    private(set) var lastFailure: CloudGatewayMacInventoryDiagnostic?

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
        var stage = CloudGatewayMacInventoryDiagnostic.Stage.accessToken
        return try await CloudGatewayMacInventoryRequest.read(onTimeout: { [self] in
            lastFailure = .init(stage: stage, source: .deadline)
            return .failure(Failure.offline)
        }) { complete in
            let task = Task {
                do { complete(.success(try await loadAccess(for: user, onRequest: { stage = .accessRequest }))) }
                catch { complete(.failure(Failure.classify(error))) }
            }
            return { task.cancel() }
        }
    }

    private func loadAccess(for user: AuthenticatedUser, onRequest: () -> Void) async throws -> CloudGatewayMacAccountRole {
        guard auth.currentUser?.uid == user.uid else { throw Failure.accessDenied }
        let token: String
        do { token = try await auth.idToken(forceRefresh: false) }
        catch {
            try Task.checkCancellation()
            lastFailure = .init(stage: .accessToken, error: error)
            throw Failure.classify(error)
        }
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
        onRequest()
        do { (data, response) = try await session.data(for: request) }
        catch {
            if !(error is CancellationError), (error as NSError).code != NSURLErrorCancelled {
                lastFailure = .init(stage: .accessRequest, error: error)
            }
            throw Failure.classify(error)
        }
        try Task.checkCancellation()
        guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse, response.url == request.url else {
            lastFailure = .init(stage: .accessResponse, source: .invalidResponse)
            throw Failure.unavailable
        }
        if let failure = Failure.accessResponseFailure(statusCode: response.statusCode) {
            lastFailure = .init(stage: .accessResponse, source: .http, code: response.statusCode)
            throw failure
        }
        guard data.count <= 64 * 1024,
              let result = try? JSONDecoder().decode(CloudGatewayAccessCheck.self, from: data),
              result.userId == user.uid,
              let role = CloudGatewayMacAccountRole(rawValue: result.role) else {
            lastFailure = .init(stage: .accessResponse, source: .invalidResponse)
            throw Failure.unavailable
        }
        return role
    }

    func fetchOptions(for user: AuthenticatedUser, role: CloudGatewayMacAccountRole) async throws -> [CloudGatewayClientOption] {
        guard auth.currentUser?.uid == user.uid else {
            throw Failure.accessDenied
        }
        try await prepareDatabase()
        guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
        let regionQuery = database.collection("Regions").whereField("enabled", isEqualTo: true)
        let instances = database.collectionGroup("Instances")
        let clientQuery: Query = role == .admin ? instances : instances.whereField("ownerUid", isEqualTo: user.uid)
        let (fetchedRegions, fetchedClients) = try await CloudGatewayMacInventoryRequest.inventory(loadRegions: { [self] in
            try await documents(regionQuery, stage: .regions) { document -> CloudGatewayRegion? in
                let data = document.data()
                guard data["enabled"] as? Bool == true,
                      let name = CloudGatewayFirestoreClientMapper.string(data["displayName"]) else { return nil }
                return CloudGatewayRegion(regionId: document.documentID, displayName: name, enabled: true,
                                          displayOrder: (data["displayOrder"] as? NSNumber)?.intValue ?? 1000)
            }
        }, loadClients: { [self] in
            try await documents(clientQuery, stage: .clients) { document -> CloudGatewayClient? in
                var data = document.data()
                if let timestamp = data["updatedAt"] as? Timestamp { data["updatedAt"] = timestamp.dateValue() }
                guard let client = CloudGatewayFirestoreClientMapper.client(
                    documentId: document.documentID, regionFallback: document.reference.parent.parent?.documentID, data: data
                ), role == .admin || client.ownerUid == user.uid else { return nil }
                return client
            }
        })
        try Task.checkCancellation()
        guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
        let regionsById = Dictionary(uniqueKeysWithValues: fetchedRegions.map { ($0.regionId, $0) })
        return fetchedClients.map { CloudGatewayClientOption(client: $0, region: regionsById[$0.regionId]) }
    }

    func vpnStateDidChange() {
        reconnectBeforeRead = true
    }

    private func prepareDatabase() async throws {
        while reconnectBeforeRead || reconnectTask != nil {
            if reconnectTask == nil {
                reconnectBeforeRead = false
                // Firestore's reachability monitor can miss VPN changes that keep the internet reachable
                reconnectTask = Task { [self, database] in
                    defer { reconnectTask = nil }
                    do {
                        let settings = database.settings
                        let app = database.app
                        try await database.terminate()
                        let next = Firestore.firestore(app: app)
                        next.settings = settings
                        self.database = next
                    } catch {
                        reconnectBeforeRead = true
                        lastFailure = .init(stage: .connection, error: error)
                        throw Failure.classify(error)
                    }
                }
            }
            try await reconnectTask?.value
            try Task.checkCancellation()
        }
    }

    func fetchCreateRegions(for user: AuthenticatedUser) async throws -> [CloudGatewayRegion] {
        guard auth.currentUser?.uid == user.uid else { throw Failure.accessDenied }
        let regions = try await CloudGatewayMacCapacityPreparation.prepare(
            loadRegions: { [self] in
                let regions = try await controlPlane.fetchRegions()
                try Task.checkCancellation()
                guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
                return regions
            },
            loadToken: { [self] in
                let token: String
                do { token = try await auth.idToken(forceRefresh: false) }
                catch { throw Failure.classify(error) }
                try Task.checkCancellation()
                guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
                return token
            },
            fetchCapacity: { [self] regionId, token in
                do {
                    let response = try await controlPlane.fetchCapacity(regionId: regionId, idToken: token)
                    try Task.checkCancellation()
                    guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
                    return response.regionId == regionId
                        ? .known(limit: response.capacityLimit, allocated: response.allocatedClientCount) : .unknown
                } catch CloudGatewayAppError.apiAccessDenied(_) {
                    throw Failure.accessDenied
                }
            }
        )
        try Task.checkCancellation()
        guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
        return regions
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

    func deleteClient(
        clientId: String, ownerUid: String, regionId: String, for user: AuthenticatedUser,
        authorize: @escaping @MainActor () async throws -> Void,
        onDispatch: @escaping @MainActor () -> Void
    ) async throws -> CloudGatewayDeleteClientResponse {
        try await CloudGatewayMacClientRemovalRequest.perform(
            clientId: clientId, ownerUid: ownerUid, regionId: regionId,
            originHost: "gocloudlaunch.com", session: session,
            loadToken: { [self] in
                do { return try await auth.idToken(forceRefresh: false) }
                catch {
                    try Task.checkCancellation()
                    lastFailure = .init(stage: .removalToken, error: error)
                    throw Failure.classify(error)
                }
            },
            validateSession: { [self] in
                guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
            },
            authorize: authorize, onDispatch: onDispatch
        )
    }

    private func documents<Value: Sendable>(
        _ query: Query,
        stage: CloudGatewayMacInventoryDiagnostic.Stage,
        map: @escaping @Sendable (QueryDocumentSnapshot) -> Value?
    ) async throws -> [Value] {
        var timedOut = false
        do {
            return try await CloudGatewayMacInventoryRequest.read(onTimeout: { [self] in
                timedOut = true
                lastFailure = .init(stage: stage, source: .deadline)
                return .failure(Failure.offline)
            }) { complete in
                let listener = query.addSnapshotListener(includeMetadataChanges: true) { @Sendable snapshot, error in
                    if let error { complete(.failure(error)) }
                    else if let snapshot, !snapshot.metadata.isFromCache {
                        complete(.success(snapshot.documents.compactMap(map)))
                    }
                }
                return { listener.remove() }
            }
        } catch {
            try Task.checkCancellation()
            if !timedOut { lastFailure = .init(stage: stage, error: error) }
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
