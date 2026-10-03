import CloudGatewayKit
import Foundation
import Synchronization
import Testing
@testable import CloudGatewayMacIPC

private let sampleConfig = """
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.0.0.2/32
"""

private final class MemorySecretStore: CloudGatewayMacSecretStoring, Sendable {
    struct State: Sendable {
        var records = [CloudGatewayMacSecretReference: CloudGatewayMacStoredSecret]()
        var shouldFailWrites = false
        var shouldFailReads = false
    }

    let state = Mutex(State())

    func add(_ record: CloudGatewayMacStoredSecret, reference: CloudGatewayMacSecretReference) throws {
        try state.withLock { state in
            guard !state.shouldFailWrites else { throw CloudGatewayMacSecretError.storageFailure }
            state.records[reference] = record
        }
    }

    func read(reference: CloudGatewayMacSecretReference) throws -> CloudGatewayMacStoredSecret? {
        try state.withLock { state in
            guard !state.shouldFailReads else { throw CloudGatewayMacSecretError.storageFailure }
            return state.records[reference]
        }
    }

    func update(_ record: CloudGatewayMacStoredSecret, reference: CloudGatewayMacSecretReference) throws {
        try add(record, reference: reference)
    }

    func remove(reference: CloudGatewayMacSecretReference) throws {
        try state.withLock { state in
            guard !state.shouldFailWrites else { throw CloudGatewayMacSecretError.storageFailure }
            state.records.removeValue(forKey: reference)
        }
    }
}

@Test func secretOwnerAndConfigIdentityAreRequired() async throws {
    let store = MemorySecretStore()
    let service = CloudGatewayMacSecretService(store: store)
    let reference = try await service.install(configId: "client-a", config: sampleConfig, userId: 501)
    await #expect(throws: CloudGatewayMacSecretError.unauthorized) {
        try await service.commit(reference: reference, configId: "client-a", userId: 502)
    }
    await #expect(throws: CloudGatewayMacSecretError.unauthorized) {
        try await service.rollback(reference: reference, configId: "client-b", userId: 501)
    }
    await #expect(throws: CloudGatewayMacSecretError.unauthorized) {
        try await service.isAvailable(reference: reference, configId: "client-a", userId: 502)
    }
    #expect(store.state.withLock { $0.records.count } == 1)
}

@Test func committedSecretSurvivesRollbackAndServiceReplacement() async throws {
    let store = MemorySecretStore()
    let service = CloudGatewayMacSecretService(store: store)
    let reference = try await service.install(configId: "a", config: sampleConfig, userId: 501)
    #expect(try await !service.isAvailable(reference: reference, configId: "a", userId: 501))
    try await service.commit(reference: reference, configId: "a", userId: 501)
    await #expect(throws: CloudGatewayMacSecretError.retainedSecret) {
        try await service.rollback(reference: reference, configId: "a", userId: 501)
    }
    let replacement = CloudGatewayMacSecretService(store: store)
    #expect(try await replacement.isAvailable(reference: reference, configId: "a", userId: 501))
}

@Test func provisionalRollbackRemovesOnlyItsOwnRecord() async throws {
    let store = MemorySecretStore()
    let service = CloudGatewayMacSecretService(store: store)
    let old = try await service.install(configId: "a", config: sampleConfig, userId: 501)
    try await service.commit(reference: old, configId: "a", userId: 501)
    let replacement = try await service.install(configId: "a", config: sampleConfig, userId: 501)
    try await service.rollback(reference: replacement, configId: "a", userId: 501)
    #expect(try await service.isAvailable(reference: old, configId: "a", userId: 501))
    #expect(try await !service.isAvailable(reference: replacement, configId: "a", userId: 501))
}

@Test func storageErrorsDoNotEraseWorkingSecret() async throws {
    let store = MemorySecretStore()
    let service = CloudGatewayMacSecretService(store: store)
    let reference = try await service.install(configId: "a", config: sampleConfig, userId: 501)
    try await service.commit(reference: reference, configId: "a", userId: 501)
    store.state.withLock { $0.shouldFailWrites = true }
    await #expect(throws: CloudGatewayMacSecretError.storageFailure) {
        try await service.install(configId: "a", config: sampleConfig, userId: 501)
    }
    store.state.withLock { $0.shouldFailReads = true }
    await #expect(throws: CloudGatewayMacSecretError.storageFailure) {
        try await service.isAvailable(reference: reference, configId: "a", userId: 501)
    }
    #expect(store.state.withLock { $0.records[reference]?.isCommitted } == true)
}

@Test func provisionalSecretCannotStartAndGrantCannotBeReplayed() async throws {
    let service = CloudGatewayMacSecretService(store: MemorySecretStore())
    let reference = try await service.install(configId: "a", config: sampleConfig, userId: 501)
    await #expect(throws: CloudGatewayMacSecretError.unavailable) {
        try await service.authorizeStart(reference: reference, configId: "a", userId: 501)
    }
    try await service.commit(reference: reference, configId: "a", userId: 501)
    await #expect(throws: CloudGatewayMacSecretError.unauthorized) {
        try await service.authorizeStart(reference: reference, configId: "a", userId: 502)
    }
    let grant = try await service.authorizeStart(reference: reference, configId: "a", userId: 501)
    #expect(Data(base64Encoded: grant)?.count == 32)
    let config = try await service.resolveForStart(reference: reference, configId: "a", grant: grant)
    #expect(config == (try CloudGatewayWireGuardConfig(sampleConfig)))
    await #expect(throws: CloudGatewayMacSecretError.unauthorized) {
        try await service.resolveForStart(reference: reference, configId: "a", grant: grant)
    }
}

@Test func grantExpiryAndConfigurationBindingRejectStarts() async throws {
    let clock = Mutex(Duration.seconds(100))
    let service = CloudGatewayMacSecretService(store: MemorySecretStore(), now: { clock.withLock { $0 } })
    let reference = try await service.install(configId: "a", config: sampleConfig, userId: 501)
    try await service.commit(reference: reference, configId: "a", userId: 501)
    let mismatched = try await service.authorizeStart(reference: reference, configId: "a", userId: 501)
    await #expect(throws: CloudGatewayMacSecretError.unauthorized) {
        try await service.resolveForStart(reference: reference, configId: "b", grant: mismatched)
    }
    let expired = try await service.authorizeStart(reference: reference, configId: "a", userId: 501)
    clock.withLock { $0 += .seconds(31) }
    await #expect(throws: CloudGatewayMacSecretError.unauthorized) {
        try await service.resolveForStart(reference: reference, configId: "a", grant: expired)
    }
}

@Test func failedCommitAndRollbackKeepProvisionalRecordForRetry() async throws {
    let store = MemorySecretStore()
    let service = CloudGatewayMacSecretService(store: store)
    let reference = try await service.install(configId: "a", config: sampleConfig, userId: 501)
    store.state.withLock { $0.shouldFailWrites = true }
    await #expect(throws: CloudGatewayMacSecretError.storageFailure) {
        try await service.commit(reference: reference, configId: "a", userId: 501)
    }
    await #expect(throws: CloudGatewayMacSecretError.storageFailure) {
        try await service.rollback(reference: reference, configId: "a", userId: 501)
    }
    #expect(store.state.withLock { $0.records[reference]?.isCommitted } == false)
    store.state.withLock { $0.shouldFailWrites = false }
    try await service.commit(reference: reference, configId: "a", userId: 501)
    #expect(try await service.isAvailable(reference: reference, configId: "a", userId: 501))
}

@Test func malformedRequestsAndUntrustedUIDCannotReachStorage() async throws {
    let store = MemorySecretStore()
    let service = CloudGatewayMacSecretService(store: store)
    await #expect(throws: CloudGatewayMacSecretError.unauthorized) {
        try await service.install(configId: "a", config: sampleConfig, userId: 0)
    }
    await #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
        try await service.install(configId: "a", config: String(repeating: "x", count: 65_537), userId: 501)
    }
    await #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
        try await service.install(configId: "a\n", config: sampleConfig, userId: 501)
    }
    #expect(store.state.withLock { $0.records.isEmpty })
    #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
        try CloudGatewayMacPeerRequirement.make(teamIdentifier: "ABC\"123456", bundleIdentifier: "com.example")
    }
    #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
        try CloudGatewayMacPeerRequirement.make(teamIdentifier: "ABCD123456", bundleIdentifier: "com.example\" or true")
    }
    #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
        try CloudGatewayMacSecretReference(value: "../../other-user")
    }
}
