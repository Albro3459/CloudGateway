import Foundation
import Testing
@testable import CloudGatewayKit

@Test func apiSessionUsesBoundedRequestTimeout() {
    let configuration = GatewayAPISession.makeConfiguration()
    #expect(configuration.timeoutIntervalForRequest == 10)
    #expect(GatewayAPISession.requestTimeout == 10)
}

@Test func apiSessionDoesNotWaitForConnectivity() {
    let configuration = GatewayAPISession.makeConfiguration()
    #expect(configuration.waitsForConnectivity == false)
}

@Test func apiSessionAppliesConfigurationToSession() {
    let session = GatewayAPISession.makeSession()
    #expect(session.configuration.timeoutIntervalForRequest == 10)
    #expect(session.configuration.waitsForConnectivity == false)
}
