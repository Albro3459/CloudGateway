import CloudGatewayKit
import Foundation
import Security

public actor CloudGatewayMacSecretService {
    private struct StartGrant {
        let reference: CloudGatewayMacSecretReference
        let configId: String
        let ownerUserId: UInt32
        let expiresAt: Duration
    }

    private let store: any CloudGatewayMacSecretStoring
    private let now: @Sendable () -> Duration
    private var grants = [String: StartGrant]()

    public init() {
        store = CloudGatewayMacSystemKeychainStore()
        let clock = ContinuousClock()
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
    }

    init(store: any CloudGatewayMacSecretStoring, now: @escaping @Sendable () -> Duration = {
        .nanoseconds(Int64(DispatchTime.now().uptimeNanoseconds))
    }) {
        self.store = store
        self.now = now
    }

    func install(configId: String, config: String, userId: UInt32) throws -> CloudGatewayMacSecretReference {
        try authorize(userId: userId)
        try CloudGatewayMacSecretBounds.validate(configId: configId)
        guard config.utf8.count <= CloudGatewayMacSecretBounds.configBytes else {
            throw CloudGatewayMacSecretError.invalidRequest
        }
        let validatedConfig: CloudGatewayWireGuardConfig
        do { validatedConfig = try CloudGatewayWireGuardConfig(config) }
        catch { throw CloudGatewayMacSecretError.invalidRequest }
        let reference = try CloudGatewayMacSecretReference(value: UUID().uuidString.lowercased())
        try store.add(CloudGatewayMacStoredSecret(
            ownerUserId: userId, configId: configId,
            config: validatedConfig.rawValue, isCommitted: false
        ), reference: reference)
        return reference
    }

    func commit(reference: CloudGatewayMacSecretReference, configId: String, userId: UInt32) throws {
        var record = try ownedRecord(reference: reference, configId: configId, userId: userId)
        guard !record.isCommitted else { return }
        record.isCommitted = true
        try store.update(record, reference: reference)
    }

    func rollback(reference: CloudGatewayMacSecretReference, configId: String, userId: UInt32) throws {
        let record = try ownedRecord(reference: reference, configId: configId, userId: userId)
        guard !record.isCommitted else { throw CloudGatewayMacSecretError.retainedSecret }
        try store.remove(reference: reference)
    }

    func isAvailable(reference: CloudGatewayMacSecretReference, configId: String, userId: UInt32) throws -> Bool {
        try authorize(userId: userId)
        try CloudGatewayMacSecretBounds.validate(configId: configId)
        guard let record = try store.read(reference: reference) else { return false }
        guard record.ownerUserId == userId, record.configId == configId else {
            throw CloudGatewayMacSecretError.unauthorized
        }
        return record.isCommitted
    }

    func authorizeStart(reference: CloudGatewayMacSecretReference, configId: String, userId: UInt32) throws -> String {
        let record = try ownedRecord(reference: reference, configId: configId, userId: userId)
        guard record.isCommitted else { throw CloudGatewayMacSecretError.unavailable }
        grants = grants.filter { $0.value.expiresAt > now() }
        guard grants.count < 256,
              grants.values.filter({ $0.ownerUserId == userId }).count < 16 else {
            throw CloudGatewayMacSecretError.unavailable
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CloudGatewayMacSecretError.unavailable
        }
        let token = Data(bytes).base64EncodedString()
        grants[token] = StartGrant(reference: reference, configId: configId,
                                   ownerUserId: userId, expiresAt: now() + .seconds(30))
        return token
    }

    public func resolveForStart(
        reference: CloudGatewayMacSecretReference,
        configId: String,
        grant token: String
    ) throws -> CloudGatewayWireGuardConfig {
        guard token.utf8.count <= 64,
              let grant = grants.removeValue(forKey: token), grant.expiresAt > now(),
              grant.reference == reference, grant.configId == configId else {
            throw CloudGatewayMacSecretError.unauthorized
        }
        let record = try ownedRecord(reference: reference, configId: configId, userId: grant.ownerUserId)
        guard record.isCommitted else { throw CloudGatewayMacSecretError.unavailable }
        do { return try CloudGatewayWireGuardConfig(record.config) }
        catch { throw CloudGatewayMacSecretError.storageFailure }
    }

    private func ownedRecord(
        reference: CloudGatewayMacSecretReference, configId: String, userId: UInt32
    ) throws -> CloudGatewayMacStoredSecret {
        try authorize(userId: userId)
        try CloudGatewayMacSecretBounds.validate(configId: configId)
        guard let record = try store.read(reference: reference) else { throw CloudGatewayMacSecretError.unavailable }
        guard record.ownerUserId == userId, record.configId == configId else {
            throw CloudGatewayMacSecretError.unauthorized
        }
        return record
    }

    private func authorize(userId: UInt32) throws {
        guard userId != 0, userId != UInt32.max else { throw CloudGatewayMacSecretError.unauthorized }
    }
}
