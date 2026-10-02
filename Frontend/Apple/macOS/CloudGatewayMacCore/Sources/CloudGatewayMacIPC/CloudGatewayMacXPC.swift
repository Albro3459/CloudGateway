import CloudGatewayKit
import Foundation
import Security

@objc protocol CloudGatewayMacSecretXPC {
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

private struct SecretRequest: Codable, Sendable {
    enum Action: String, Codable, Sendable { case ping, install, commit, rollback, available, authorizeStart }
    let action: Action
    let configId: String
    var reference: String?
    var config: String?
}

private struct SecretReply: Codable, Sendable {
    var reference: String?
    var isAvailable: Bool?
    var grant: String?
    var error: CloudGatewayMacSecretError?
}

public enum CloudGatewayMacPeerRequirement {
    public static func make(teamIdentifier: String, bundleIdentifier: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard teamIdentifier.count == 10,
              teamIdentifier.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }),
              !bundleIdentifier.isEmpty, bundleIdentifier.utf8.count <= 256,
              bundleIdentifier.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw CloudGatewayMacSecretError.invalidRequest
        }
        return "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

public final class CloudGatewayMacXPCListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    public static let machServiceName = "group.com.gocloudlaunch.gateway.macos.tunnel"
    private let service: CloudGatewayMacSecretService
    private let requirement: String
    private let listener: NSXPCListener

    public init(service: CloudGatewayMacSecretService, teamIdentifier: String) throws {
        self.service = service
        requirement = try CloudGatewayMacPeerRequirement.make(
            teamIdentifier: teamIdentifier, bundleIdentifier: "com.gocloudlaunch.gateway.macos"
        )
        listener = NSXPCListener(machServiceName: Self.machServiceName)
        super.init()
        listener.delegate = self
        listener.setConnectionCodeSigningRequirement(requirement)
    }

    public func start() { listener.activate() }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let userId = connection.effectiveUserIdentifier
        guard userId != 0, userId != UInt32.max else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: CloudGatewayMacSecretXPC.self)
        connection.exportedObject = SecretEndpoint(service: service, userId: userId)
        connection.activate()
        return true
    }

    deinit { listener.invalidate() }
}

private final class SecretEndpoint: NSObject, CloudGatewayMacSecretXPC, Sendable {
    private let service: CloudGatewayMacSecretService
    private let userId: UInt32

    init(service: CloudGatewayMacSecretService, userId: UInt32) {
        self.service = service
        self.userId = userId
    }

    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard NSXPCConnection.current()?.effectiveUserIdentifier == userId else {
            reply(Self.encode(SecretReply(error: .unauthorized)))
            return
        }
        guard request.count <= CloudGatewayMacSecretBounds.requestBytes,
              let request = try? JSONDecoder().decode(SecretRequest.self, from: request) else {
            reply(Self.encode(SecretReply(error: .invalidRequest)))
            return
        }
        Task {
            let result: SecretReply
            do {
                try CloudGatewayMacSecretBounds.validate(configId: request.configId)
                switch request.action {
                case .ping:
                    guard request.config == nil, request.reference == nil else {
                        throw CloudGatewayMacSecretError.invalidRequest
                    }
                    result = SecretReply()
                case .install:
                    guard let config = request.config, request.reference == nil else {
                        throw CloudGatewayMacSecretError.invalidRequest
                    }
                    let reference = try await service.install(configId: request.configId, config: config, userId: userId)
                    result = SecretReply(reference: reference.value)
                case .commit, .rollback, .available, .authorizeStart:
                    guard let value = request.reference, request.config == nil else {
                        throw CloudGatewayMacSecretError.invalidRequest
                    }
                    let reference = try CloudGatewayMacSecretReference(value: value)
                    switch request.action {
                    case .commit:
                        try await service.commit(reference: reference, configId: request.configId, userId: userId)
                        result = SecretReply()
                    case .rollback:
                        try await service.rollback(reference: reference, configId: request.configId, userId: userId)
                        result = SecretReply()
                    case .available:
                        result = SecretReply(isAvailable: try await service.isAvailable(
                            reference: reference, configId: request.configId, userId: userId
                        ))
                    case .authorizeStart:
                        result = SecretReply(grant: try await service.authorizeStart(
                            reference: reference, configId: request.configId, userId: userId
                        ))
                    case .ping, .install: throw CloudGatewayMacSecretError.invalidRequest
                    }
                }
            } catch {
                result = SecretReply(error: (error as? CloudGatewayMacSecretError) ?? .storageFailure)
            }
            reply(Self.encode(result))
        }
    }

    private static func encode(_ result: SecretReply) -> Data {
        (try? JSONEncoder().encode(result)) ?? Data("{\"error\":4}".utf8)
    }
}

public final class CloudGatewayMacXPCSecretClient: CloudGatewayMacSecretClient, Sendable {
    private let requirement: String

    public init(teamIdentifier: String) throws {
        requirement = try CloudGatewayMacPeerRequirement.make(
            teamIdentifier: teamIdentifier, bundleIdentifier: "com.gocloudlaunch.gateway.tunnel.macos"
        )
    }

    public func ping() async throws {
        _ = try await send(SecretRequest(action: .ping, configId: "readiness"))
    }

    public func install(configId: String, config: CloudGatewayWireGuardConfig) async throws -> CloudGatewayMacSecretReference {
        let result = try await send(SecretRequest(action: .install, configId: configId, config: config.rawValue))
        guard let value = result.reference else { throw CloudGatewayMacSecretError.connectionFailure }
        return try CloudGatewayMacSecretReference(value: value)
    }

    public func commit(reference: CloudGatewayMacSecretReference, configId: String) async throws {
        _ = try await send(SecretRequest(action: .commit, configId: configId, reference: reference.value))
    }

    public func rollback(reference: CloudGatewayMacSecretReference, configId: String) async throws {
        _ = try await send(SecretRequest(action: .rollback, configId: configId, reference: reference.value))
    }

    public func isAvailable(reference: CloudGatewayMacSecretReference, configId: String) async throws -> Bool {
        let result = try await send(SecretRequest(action: .available, configId: configId, reference: reference.value))
        guard let isAvailable = result.isAvailable else { throw CloudGatewayMacSecretError.connectionFailure }
        return isAvailable
    }

    public func authorizeStart(reference: CloudGatewayMacSecretReference, configId: String) async throws -> String {
        let result = try await send(SecretRequest(action: .authorizeStart, configId: configId, reference: reference.value))
        guard let grant = result.grant, Data(base64Encoded: grant)?.count == 32 else {
            throw CloudGatewayMacSecretError.connectionFailure
        }
        return grant
    }

    private func send(_ request: SecretRequest) async throws -> SecretReply {
        try Task.checkCancellation()
        try CloudGatewayMacSecretBounds.validate(configId: request.configId)
        let data = try JSONEncoder().encode(request)
        guard data.count <= CloudGatewayMacSecretBounds.requestBytes,
              (request.config?.utf8.count ?? 0) <= CloudGatewayMacSecretBounds.configBytes else {
            throw CloudGatewayMacSecretError.invalidRequest
        }
        let connection = NSXPCConnection(machServiceName: CloudGatewayMacXPCListener.machServiceName, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: CloudGatewayMacSecretXPC.self)
        let reply: SecretReply = try await withCheckedThrowingContinuation { continuation in
            let pending = PendingReply(continuation: continuation, connection: connection)
            connection.interruptionHandler = { pending.finish(.failure(CloudGatewayMacSecretError.connectionFailure)) }
            connection.invalidationHandler = { pending.finish(.failure(CloudGatewayMacSecretError.connectionFailure)) }
            connection.activate()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                pending.finish(.failure(CloudGatewayMacSecretError.connectionFailure))
            }) as? any CloudGatewayMacSecretXPC else {
                pending.finish(.failure(CloudGatewayMacSecretError.connectionFailure))
                return
            }
            proxy.perform(data) { data in
                guard data.count <= CloudGatewayMacSecretBounds.responseBytes,
                      let reply = try? JSONDecoder().decode(SecretReply.self, from: data) else {
                    pending.finish(.failure(CloudGatewayMacSecretError.connectionFailure))
                    return
                }
                if let error = reply.error { pending.finish(.failure(error)) }
                else { pending.finish(.success(reply)) }
            }
            Task {
                try? await Task.sleep(for: .seconds(10))
                pending.finish(.failure(CloudGatewayMacSecretError.timeout))
            }
        }
        // Return an installed handle so canceled callers can roll it back safely
        if request.action != .install { try Task.checkCancellation() }
        return reply
    }
}

private final class PendingReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SecretReply, any Error>?
    private let connection: NSXPCConnection

    init(continuation: CheckedContinuation<SecretReply, any Error>, connection: NSXPCConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func finish(_ result: Result<SecretReply, any Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection.invalidate()
        pending.resume(with: result)
    }
}
