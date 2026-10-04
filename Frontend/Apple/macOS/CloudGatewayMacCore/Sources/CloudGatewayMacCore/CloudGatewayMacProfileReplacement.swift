public enum CloudGatewayMacProfileReplacement {
    public static func perform(
        existing: CloudGatewayMacInstalledProfile?,
        stop: @Sendable () async throws -> Void,
        replace: @Sendable () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        if existing?.needsConfirmedStop == true {
            try await stop()
        }
        try Task.checkCancellation()
        try await replace()
    }
}
