import CloudGatewayKit
import Foundation

public enum CloudGatewayMacSecretError: Int, Error, Codable, Sendable {
    case invalidRequest = 1
    case unauthorized
    case unavailable
    case storageFailure
    case retainedSecret
    case connectionFailure
    case timeout
}

public struct CloudGatewayMacSecretReference: Codable, Equatable, Hashable, Sendable {
    public let value: String

    public init(value: String) throws {
        guard UUID(uuidString: value)?.uuidString.lowercased() == value else {
            throw CloudGatewayMacSecretError.invalidRequest
        }
        self.value = value
    }
}

public protocol CloudGatewayMacSecretClient: Sendable {
    func install(configId: String, config: CloudGatewayWireGuardConfig) async throws -> CloudGatewayMacSecretReference
    func commit(reference: CloudGatewayMacSecretReference, configId: String) async throws
    func rollback(reference: CloudGatewayMacSecretReference, configId: String) async throws
    func isAvailable(reference: CloudGatewayMacSecretReference, configId: String) async throws -> Bool
    func authorizeStart(reference: CloudGatewayMacSecretReference, configId: String) async throws -> String
}

public enum CloudGatewayMacProviderKey {
    public static let secretReference = "macSecretReference"
    public static let configId = "macConfigId"
    public static let startGrant = "macStartGrant"
}

enum CloudGatewayMacSecretBounds {
    static let configBytes = 64 * 1024
    static let requestBytes = 96 * 1024
    static let responseBytes = 1024

    static func validate(configId: String) throws {
        guard !configId.isEmpty, configId.utf8.count <= 256,
              configId.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw CloudGatewayMacSecretError.invalidRequest
        }
    }
}

struct CloudGatewayMacStoredSecret: Codable, Sendable {
    let ownerUserId: UInt32
    let configId: String
    let config: String
    var isCommitted: Bool
}

protocol CloudGatewayMacSecretStoring: Sendable {
    func add(_ record: CloudGatewayMacStoredSecret, reference: CloudGatewayMacSecretReference) throws
    func read(reference: CloudGatewayMacSecretReference) throws -> CloudGatewayMacStoredSecret?
    func update(_ record: CloudGatewayMacStoredSecret, reference: CloudGatewayMacSecretReference) throws
    func remove(reference: CloudGatewayMacSecretReference) throws
}
