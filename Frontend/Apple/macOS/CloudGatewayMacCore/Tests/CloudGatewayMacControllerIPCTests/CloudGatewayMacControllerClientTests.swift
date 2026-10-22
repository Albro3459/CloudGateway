import Foundation
import Testing
@testable import CloudGatewayMacControllerIPC

@Test @MainActor func unavailableControllerRequestsReturnFailureFromXPCQueue() async throws {
    let client = try CloudGatewayMacControllerClient(
        teamIdentifier: "ABCDE12345", appVersion: "1.2.0", appBuild: "42",
        machServiceName: "com.gocloudlaunch.gateway.tests.missing.\(UUID().uuidString)"
    )
    defer { client.invalidate() }
    for _ in 0..<2 {
        do {
            _ = try await client.request(CloudGatewayMacControllerRequest(action: .snapshot))
            Issue.record("Unavailable controller returned a reply")
        } catch { #expect(error as? CloudGatewayMacControllerFailure == .unavailable) }
    }
}
