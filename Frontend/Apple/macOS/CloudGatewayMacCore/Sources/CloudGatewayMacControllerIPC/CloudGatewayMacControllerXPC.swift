import CloudGatewayMacIPC
import Darwin
import Foundation

@objc protocol CloudGatewayMacControllerXPC {
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

enum ControllerPeerIdentity {
    static func accepts(peerUserId: UInt32, ownerUserId: UInt32) -> Bool {
        ownerUserId != 0 && ownerUserId != UInt32.max && peerUserId == ownerUserId
    }

    static func requirement(teamIdentifier: String) throws -> String {
        do {
            return try CloudGatewayMacPeerRequirement.make(
                teamIdentifier: teamIdentifier,
                bundleIdentifier: CloudGatewayMacControllerProtocol.appBundleIdentifier
            )
        } catch { throw CloudGatewayMacControllerFailure.invalidRequest }
    }
}

@MainActor
public final class CloudGatewayMacControllerServer: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private nonisolated let state: ControllerServerState

    public init(
        teamIdentifier: String,
        appVersion: String,
        appBuild: String,
        handler: @escaping @MainActor (CloudGatewayMacControllerRequest) async -> CloudGatewayMacControllerReply
    ) throws {
        try CloudGatewayMacControllerProtocol.validateVersion(appVersion, build: appBuild)
        let userId = geteuid()
        guard ControllerPeerIdentity.accepts(peerUserId: getuid(), ownerUserId: userId) else {
            throw CloudGatewayMacControllerFailure.rejected
        }
        let requirement = try ControllerPeerIdentity.requirement(teamIdentifier: teamIdentifier)
        state = ControllerServerState(
            requirement: requirement, userId: userId, appVersion: appVersion, appBuild: appBuild, handler: handler
        )
        listener = NSXPCListener(machServiceName: CloudGatewayMacControllerProtocol.machServiceName)
        super.init()
        listener.delegate = self
        listener.setConnectionCodeSigningRequirement(requirement)
    }

    public func resume() {
        guard state.resume() else { return }
        listener.activate()
    }

    public func invalidate() {
        state.invalidate()
        listener.invalidate()
    }

    public nonisolated func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard ControllerPeerIdentity.accepts(peerUserId: connection.effectiveUserIdentifier, ownerUserId: state.userId),
              state.admit(connection) else { return false }
        connection.setCodeSigningRequirement(state.requirement)
        connection.exportedInterface = NSXPCInterface(with: CloudGatewayMacControllerXPC.self)
        connection.exportedObject = ControllerEndpoint(state: state)
        let id = ObjectIdentifier(connection)
        connection.invalidationHandler = { [state] in state.remove(id) }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.activate()
        return true
    }

    isolated deinit {
        state.invalidate()
        listener.invalidate()
    }
}

private final class ControllerServerState: @unchecked Sendable {
    let requirement: String
    let userId: UInt32
    let appVersion: String
    let appBuild: String
    let instanceId = UUID()
    let handler: @MainActor (CloudGatewayMacControllerRequest) async -> CloudGatewayMacControllerReply
    private let lock = NSLock()
    private var isRunning = false
    private var isInvalidated = false
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]
    private var activeRequests = 0

    init(
        requirement: String, userId: UInt32, appVersion: String, appBuild: String,
        handler: @escaping @MainActor (CloudGatewayMacControllerRequest) async -> CloudGatewayMacControllerReply
    ) {
        self.requirement = requirement
        self.userId = userId
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.handler = handler
    }

    func resume() -> Bool {
        lock.withLock {
            guard !isRunning, !isInvalidated else { return false }
            isRunning = true
            return true
        }
    }

    func admit(_ connection: NSXPCConnection) -> Bool {
        lock.withLock {
            guard isRunning, !isInvalidated,
                  connections.count < CloudGatewayMacControllerProtocol.maximumConnections else { return false }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
    }

    func remove(_ id: ObjectIdentifier) {
        _ = lock.withLock { connections.removeValue(forKey: id) }
    }

    func beginRequest(_ connection: NSXPCConnection) -> Bool {
        lock.withLock {
            guard !isInvalidated, connections[ObjectIdentifier(connection)] != nil,
                  activeRequests < CloudGatewayMacControllerProtocol.maximumRequests else { return false }
            activeRequests += 1
            return true
        }
    }

    func endRequest() { lock.withLock { activeRequests -= 1 } }

    func invalidate() {
        let pending = lock.withLock {
            isInvalidated = true
            let pending = Array(connections.values)
            connections.removeAll()
            return pending
        }
        pending.forEach { $0.invalidate() }
    }

    func encode(_ reply: CloudGatewayMacControllerReply) -> Data {
        CloudGatewayMacControllerProtocol.encodeReply(
            reply, appVersion: appVersion, appBuild: appBuild, instanceId: instanceId
        )
    }
}

private final class ControllerEndpoint: NSObject, CloudGatewayMacControllerXPC, Sendable {
    private let state: ControllerServerState

    init(state: ControllerServerState) { self.state = state }

    func perform(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let connection = NSXPCConnection.current(),
              ControllerPeerIdentity.accepts(peerUserId: connection.effectiveUserIdentifier, ownerUserId: state.userId) else {
            reply(state.encode(CloudGatewayMacControllerReply(error: .rejected)))
            return
        }
        let request: CloudGatewayMacControllerRequest
        do {
            request = try CloudGatewayMacControllerProtocol.decodeRequest(
                data, appVersion: state.appVersion, appBuild: state.appBuild
            )
        } catch {
            reply(state.encode(CloudGatewayMacControllerReply(
                error: error as? CloudGatewayMacControllerFailure ?? .invalidRequest
            )))
            return
        }
        guard state.beginRequest(connection) else {
            reply(state.encode(CloudGatewayMacControllerReply(error: .busy)))
            return
        }
        // The controller keeps admitted work when the frontend disconnects
        Task { @MainActor [state] in
            defer { state.endRequest() }
            reply(state.encode(await state.handler(request)))
        }
    }
}

@MainActor
public final class CloudGatewayMacControllerClient {
    private let machServiceName: String
    private let requirement: String
    private let userId: UInt32
    private let appVersion: String
    private let appBuild: String
    private var pending: [UUID: ControllerPendingReply] = [:]
    private var isInvalidated = false

    public convenience init(teamIdentifier: String, appVersion: String, appBuild: String) throws {
        try self.init(
            teamIdentifier: teamIdentifier, appVersion: appVersion, appBuild: appBuild,
            machServiceName: CloudGatewayMacControllerProtocol.machServiceName
        )
    }

    init(teamIdentifier: String, appVersion: String, appBuild: String, machServiceName: String) throws {
        try CloudGatewayMacControllerProtocol.validateVersion(appVersion, build: appBuild)
        userId = geteuid()
        guard ControllerPeerIdentity.accepts(peerUserId: getuid(), ownerUserId: userId) else {
            throw CloudGatewayMacControllerFailure.rejected
        }
        requirement = try ControllerPeerIdentity.requirement(teamIdentifier: teamIdentifier)
        self.machServiceName = machServiceName
        self.appVersion = appVersion
        self.appBuild = appBuild
    }

    public func request(_ request: CloudGatewayMacControllerRequest) async throws -> CloudGatewayMacControllerReply {
        try Task.checkCancellation()
        guard !isInvalidated else { throw CloudGatewayMacControllerFailure.unavailable }
        guard pending.count < CloudGatewayMacControllerProtocol.maximumClientRequests else {
            throw CloudGatewayMacControllerFailure.busy
        }
        let data = try CloudGatewayMacControllerProtocol.encodeRequest(request, appVersion: appVersion, appBuild: appBuild)
        let connection = NSXPCConnection(machServiceName: machServiceName)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: CloudGatewayMacControllerXPC.self)
        let peer = ControllerPeerConnection(connection)
        let operation = ControllerPendingReply {
            peer.invalidate()
        }
        let id = UUID()
        pending[id] = operation
        defer { pending[id] = nil }
        let userId = userId
        let appVersion = appVersion
        let appBuild = appBuild
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard operation.start(continuation) else { return }
                operation.withTransportSetup {
                    // Foundation invokes these callbacks on the XPC queue, outside MainActor
                    connection.interruptionHandler = { @Sendable in
                        operation.finish(.failure(CloudGatewayMacControllerFailure.unavailable))
                    }
                    connection.invalidationHandler = { @Sendable in
                        operation.finish(.failure(CloudGatewayMacControllerFailure.unavailable))
                    }
                    connection.activate()
                    operation.armTimeout()
                    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in
                        operation.finish(.failure(CloudGatewayMacControllerFailure.unavailable))
                    }) as? any CloudGatewayMacControllerXPC else {
                        operation.finish(.failure(CloudGatewayMacControllerFailure.unavailable))
                        return
                    }
                    proxy.perform(data) { data in
                        guard ControllerPeerIdentity.accepts(peerUserId: peer.userId, ownerUserId: userId) else {
                            operation.finish(.failure(CloudGatewayMacControllerFailure.rejected))
                            return
                        }
                        do {
                            let reply = try CloudGatewayMacControllerProtocol.decodeReply(
                                data, appVersion: appVersion, appBuild: appBuild
                            )
                            operation.finish(.success(reply))
                        } catch { operation.finish(.failure(error)) }
                    }
                }
            }
        } onCancel: { operation.finish(.failure(CancellationError())) }
    }

    public func invalidate() {
        isInvalidated = true
        let requests = Array(pending.values)
        pending.removeAll()
        requests.forEach { $0.finish(.failure(CloudGatewayMacControllerFailure.unavailable)) }
    }

    deinit {
        pending.values.forEach { $0.finish(.failure(CloudGatewayMacControllerFailure.unavailable)) }
    }
}

// XPC invokes replies and invalidation on its own queue after MainActor setup
private final class ControllerPeerConnection: @unchecked Sendable {
    private let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) { self.connection = connection }

    var userId: UInt32 { connection.effectiveUserIdentifier }

    func invalidate() {
        connection.interruptionHandler = nil
        connection.invalidationHandler = nil
        connection.invalidate()
    }
}

final class ControllerPendingReply: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let cleanup: @Sendable () -> Void
    private var continuation: CheckedContinuation<CloudGatewayMacControllerReply, any Error>?
    private var result: Result<CloudGatewayMacControllerReply, any Error>?
    private var timeout: Task<Void, Never>?

    init(cleanup: @escaping @Sendable () -> Void) { self.cleanup = cleanup }

    func start(_ continuation: CheckedContinuation<CloudGatewayMacControllerReply, any Error>) -> Bool {
        let finished: Result<CloudGatewayMacControllerReply, any Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let finished { continuation.resume(with: finished); return false }
        return true
    }

    func withTransportSetup(_ setup: () -> Void) {
        lock.withLock {
            guard result == nil else { return }
            setup()
        }
    }

    func armTimeout(after duration: Duration = .seconds(30)) {
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.finish(.failure(CloudGatewayMacControllerFailure.timeout))
        }
        lock.withLock {
            if result == nil { timeout = timer }
            else { timer.cancel() }
        }
    }

    func finish(_ result: Result<CloudGatewayMacControllerReply, any Error>) {
        let completion = lock.withLock { () -> (CheckedContinuation<CloudGatewayMacControllerReply, any Error>?, Task<Void, Never>?)? in
            guard self.result == nil else { return nil }
            self.result = result
            let completion = (continuation, timeout)
            continuation = nil
            timeout = nil
            return completion
        }
        guard let completion else { return }
        completion.1?.cancel()
        cleanup()
        completion.0?.resume(with: result)
    }
}
