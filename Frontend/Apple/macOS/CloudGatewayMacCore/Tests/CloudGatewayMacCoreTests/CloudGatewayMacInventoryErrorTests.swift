import Foundation
import Testing
@testable import CloudGatewayMacCore

@Test func macInventoryDiagnosticsKeepOnlyKnownErrorCodes() throws {
    let sensitive: [String: Any] = [NSLocalizedDescriptionKey: "private account and credentials",
        NSURLErrorFailingURLErrorKey: URL(string: "https://private.invalid/account")!]
    let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: sensitive)
    let evidence = try #require(CloudGatewayMacInventoryDiagnostic(stage: .accessRequest, error: error))
    #expect(evidence.source == .url)
    #expect(evidence.code == NSURLErrorNetworkConnectionLost)
    let encoded = try JSONEncoder().encode(evidence)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(!text.contains("private"))
    #expect(!text.contains("credentials"))
    #expect(try JSONDecoder().decode(CloudGatewayMacInventoryDiagnostic.self, from: encoded) == evidence)
    let unknown = try #require(CloudGatewayMacInventoryDiagnostic(stage: .clients,
        error: NSError(domain: "private.invalid/account", code: 123, userInfo: sensitive)))
    #expect(unknown.source == .other && unknown.code == nil)
    #expect(CloudGatewayMacInventoryDiagnostic(stage: .clients, error: CancellationError()) == nil)
}

@Test func macAccessResponseDistinguishesDeniedIdentityFromVerifierOutage() {
    #expect(CloudGatewayMacInventoryError.accessResponseFailure(statusCode: 200) == nil)
    for status in [401, 403] {
        #expect(CloudGatewayMacInventoryError.accessResponseFailure(statusCode: status) == .accessDenied)
    }
    for status in [302, 429, 500, 502, 503, 504] {
        #expect(CloudGatewayMacInventoryError.accessResponseFailure(statusCode: status) == .unavailable)
    }
}

@Test func macVerifierOutageDoesNotAuthorizeCachedOrOnlineInventory() throws {
    let cached = CloudGatewayMacAccountCacheSnapshot(accessAllowed: true)
    let failure = try #require(CloudGatewayMacInventoryError.accessResponseFailure(statusCode: 503))
    #expect(failure == .unavailable)
    #expect(!CloudGatewayMacOfflinePolicy.canUseCache(after: failure.cacheFailure, cache: cached))
    #expect(CloudGatewayMacOfflinePolicy.canUseCache(after: .transport, cache: cached))
}

@Test func macFirebaseIdentityDenialsAndServiceFailuresStayDistinct() {
    for code in [17005, 17011, 17017, 17021] {
        let failure = CloudGatewayMacInventoryError.classify(NSError(domain: "FIRAuthErrorDomain", code: code))
        #expect(failure as? CloudGatewayMacInventoryError == .accessDenied)
    }
    let outage = CloudGatewayMacInventoryError.classify(NSError(domain: "FIRAuthErrorDomain", code: 17999))
    #expect(outage as? CloudGatewayMacInventoryError == .unavailable)
    let transport = CloudGatewayMacInventoryError.classify(NSError(domain: "FIRAuthErrorDomain", code: 17020))
    #expect(transport as? CloudGatewayMacInventoryError == .offline)
    #expect(CloudGatewayMacInventoryError.classify(CancellationError()) is CancellationError)
}
