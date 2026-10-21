import CloudGatewayAppCore
import CloudGatewayKit
import Foundation
import Testing
@testable import CloudGatewayMacCore
@testable import CloudGatewayMacControllerIPC

@Test func controllerSnapshotNormalizesDisplayControlsAndPreservesIdentifiers() throws {
    let snapshot = controllerSnapshot(clientTitle: "Work\tMac\nLaptop", regionTitle: "US\rCentral\tRegion")
    let view = CloudGatewayMacControllerView(snapshot: snapshot, setupState: .ready)
    let decoded = try controllerRoundTrip(view)
    #expect(decoded.groups.first?.title == "US Central Region")
    #expect(decoded.groups.first?.rows.first?.title == "Work Mac Laptop")
    #expect(decoded.groups.first?.rows.first?.identifier == snapshot.groups.first?.rows.first?.identifier)
    #expect(decoded.accountId == snapshot.accountId)
    #expect(decoded.lastSelectedIdentifier == snapshot.lastSelectedIdentifier)
    #expect(decoded.reconnectIdentifier == snapshot.reconnectIdentifier)
}

@Test func controllerSnapshotBoundsDisplayTextWithoutSplittingUnicode() throws {
    for (clientTitle, regionTitle, expectedClient, expectedRegion) in [
        (String(repeating: "🙂", count: 600), String(repeating: "🙂", count: 300),
         String(repeating: "🙂", count: 512), String(repeating: "🙂", count: 256)),
        (String(repeating: "a", count: 2047) + "🙂", String(repeating: "a", count: 1023) + "🙂",
         String(repeating: "a", count: 2047), String(repeating: "a", count: 1023)),
        ("", "", "Untitled", "Untitled"),
        ("Work\u{0000}Mac\u{007f}", "US\u{000b}Central", "Work Mac ", "US Central")
    ] {
        let view = CloudGatewayMacControllerView(
            snapshot: controllerSnapshot(clientTitle: clientTitle, regionTitle: regionTitle), setupState: .ready
        )
        let decoded = try controllerRoundTrip(view)
        #expect(decoded.groups.first?.rows.first?.title == expectedClient)
        #expect(decoded.groups.first?.title == expectedRegion)
    }
}

@Test func controllerSnapshotPreservesFixedSuccessfulCreationRefreshWarning() throws {
    let message = "Client was created, but the client list could not refresh. Choose Refresh before trying again"
    let view = CloudGatewayMacControllerView(
        snapshot: controllerSnapshot(errorMessage: message), setupState: .ready
    )
    #expect(try controllerRoundTrip(view).errorMessage == message)
    let unsafe = "\"privateKey=secret\" was created, but the client list could not refresh. Choose Refresh before trying again"
    #expect(ControllerVisibleError.sanitize(unsafe) == "CloudGateway could not complete the request. Refresh before trying again")
}

private func controllerSnapshot(
    clientTitle: String = "Work Mac", regionTitle: String = "US Central", errorMessage: String? = nil
) -> CloudGatewayMacControllerSnapshot {
    let identifier = "account-A._/r_E-1/c_Z.9"
    return CloudGatewayMacControllerSnapshot(
        groups: [.init(title: regionTitle, rows: [
            .init(identifier: identifier, title: clientTitle, status: .connected, isEnabled: true)
        ])],
        statusTitle: "VPN connected", canToggleVPN: true, canTurnOff: true, hasActiveTunnel: true,
        reconnectIdentifier: identifier, canRefresh: true, canSignOut: true,
        accountId: "account-A._", lastSelectedIdentifier: identifier,
        browserState: .signedIn(AuthenticatedUser(uid: "account-A._", email: nil)),
        isRestoringSession: false, isAuthSettling: false, hasRetainedSession: true,
        inventoryInFlight: false, canCreateClient: true, errorMessage: errorMessage,
        hasUnlistedActiveProfile: false
    )
}

private func controllerRoundTrip(_ view: CloudGatewayMacControllerView) throws -> CloudGatewayMacControllerView {
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        CloudGatewayMacControllerReply(snapshot: view), appVersion: "1.2.0", appBuild: "42", instanceId: UUID()
    )
    let reply = try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: "1.2.0", appBuild: "42")
    #expect(reply.error == nil)
    return try #require(reply.snapshot)
}
