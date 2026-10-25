import Foundation

public enum CloudGatewayMacProfileRemoval {
    @MainActor
    public static func perform<Manager>(
        identifier: String,
        authorize: @MainActor () throws -> Void,
        load: @MainActor () async throws -> [Manager],
        profile: @MainActor (Manager) throws -> CloudGatewayMacInstalledProfile,
        reload: @MainActor (Manager) async throws -> Void,
        remove: @MainActor (Manager) async throws -> Void
    ) async throws {
        guard CloudGatewayMacProfileMetadata.validIdentifier(identifier) else {
            throw CloudGatewayMacConfigError.invalidConfig
        }
        try Task.checkCancellation()
        try authorize()
        try Task.checkCancellation()
        let managers = try await load()
        try Task.checkCancellation()
        try authorize()
        try Task.checkCancellation()
        let profiles = try managers.map(profile)
        guard let expected = try CloudGatewayMacProfileMetadata.inactiveTarget(identifier: identifier, profiles: profiles),
              let index = profiles.firstIndex(where: { $0.identifier == identifier }) else { return }
        let manager = managers[index]
        try await reload(manager)
        try Task.checkCancellation()
        try authorize()
        try Task.checkCancellation()
        let current = try profile(manager)
        guard current.identifier == expected.identifier, current.reference == expected.reference else {
            throw CloudGatewayMacConfigError.invalidConfig
        }
        guard !current.needsConfirmedStop else { throw CloudGatewayMacConfigError.clientActive }
        try await remove(manager)
        try Task.checkCancellation()
        try authorize()
        try Task.checkCancellation()
        let reloadedManagers = try await load()
        try Task.checkCancellation()
        try authorize()
        try Task.checkCancellation()
        let remaining = try reloadedManagers.map(profile)
        guard try CloudGatewayMacProfileMetadata.inactiveTarget(identifier: identifier, profiles: remaining) == nil else {
            throw CloudGatewayMacConfigError.unavailable
        }
    }
}
