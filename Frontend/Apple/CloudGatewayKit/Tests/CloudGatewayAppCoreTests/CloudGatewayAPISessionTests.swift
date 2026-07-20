import Foundation
import Testing
@testable import CloudGatewayAppCore

@Test func apiSessionUsesBoundedRequestTimeout() {
    let configuration = CloudGatewayAPISession.makeConfiguration()
    #expect(configuration.timeoutIntervalForRequest == 10)
    #expect(CloudGatewayAPISession.requestTimeout == 10)
}

@Test func apiSessionDoesNotWaitForConnectivity() {
    let configuration = CloudGatewayAPISession.makeConfiguration()
    #expect(configuration.waitsForConnectivity == false)
}

@Test func apiSessionAppliesConfigurationToSession() {
    let session = CloudGatewayAPISession.makeSession()
    #expect(session.configuration.timeoutIntervalForRequest == 10)
    #expect(session.configuration.waitsForConnectivity == false)
}
