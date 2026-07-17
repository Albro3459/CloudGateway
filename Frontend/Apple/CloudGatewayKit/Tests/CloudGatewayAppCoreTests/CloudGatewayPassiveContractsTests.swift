@testable import CloudGatewayAppCore
import Foundation
import Testing

@Suite("CloudGatewayAppCore passive contracts")
struct CloudGatewayPassiveContractsTests {
    @Test("API URLs normalize safe regions and paths")
    func apiURLConstruction() throws {
        #expect(
            try CloudGatewayAPIURLBuilder.apexAPIURL(
                originHost: "gocloudlaunch.com",
                path: "/regions"
            ).absoluteString == "https://api.gocloudlaunch.com/api/regions"
        )
        #expect(
            try CloudGatewayAPIURLBuilder.regionalAPIURL(
                originHost: "gocloudlaunch.com",
                regionId: " WWW.US-SANJOSE-1 ",
                path: "clients"
            ).absoluteString == "https://us-sanjose-1.gocloudlaunch.com/api/clients"
        )
    }

    @Test("API identifiers reject path injection")
    func apiIdentifierValidation() throws {
        #expect(try CloudGatewayAPIURLBuilder.validatedClientId("Client_123-abc") == "Client_123-abc")
        for unsafeClientId in ["", "../client", "client/id", "client?id", "client#id"] {
            #expect(throws: CloudGatewayAppError.self) {
                try CloudGatewayAPIURLBuilder.validatedClientId(unsafeClientId)
            }
        }
        for unsafeRegionId in ["-region", "region-", "region.example", "region/path"] {
            #expect(throws: CloudGatewayAppError.self) {
                try CloudGatewayAPIURLBuilder.regionalAPIURL(
                    originHost: "gocloudlaunch.com",
                    regionId: unsafeRegionId,
                    path: "clients"
                )
            }
        }
    }

    @Test("Runtime configuration accepts only resolved access groups")
    func runtimeConfiguration() throws {
        #expect(
            try CloudGatewayRuntimeConfiguration.keychainAccessGroup(" ABC123.com.example.shared ")
                == "ABC123.com.example.shared"
        )
        #expect(throws: CloudGatewayRuntimeConfiguration.Error.missingKeychainAccessGroup) {
            try CloudGatewayRuntimeConfiguration.keychainAccessGroup(nil)
        }
        #expect(throws: CloudGatewayRuntimeConfiguration.Error.missingKeychainAccessGroup) {
            try CloudGatewayRuntimeConfiguration.keychainAccessGroup("")
        }
        #expect(throws: CloudGatewayRuntimeConfiguration.Error.missingKeychainAccessGroup) {
            try CloudGatewayRuntimeConfiguration.keychainAccessGroup("$(ACCESS_GROUP)")
        }
    }

    @Test("Apple nonce hashing stays stable and random nonces use the safe alphabet")
    func appleNonce() {
        #expect(
            AppleSignInNonce.sha256("cloudgateway")
                == "c3dca693be9ef2c5c8081baf14e93d3b6b5d29604571b1110e047aad42e01ebb"
        )
        let nonce = AppleSignInNonce.randomNonceString(length: 64)
        #expect(nonce.count == 64)
        #expect(nonce.allSatisfy { "0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._".contains($0) })
    }

    @Test("Notification policies preserve first and existing install behavior")
    @MainActor
    func notificationPolicies() {
        let authorizer = RecordingNotificationAuthorizer()

        CloudGatewayExistingInstallNotificationAuthorization.requestIfNeeded(
            hasInstalledConfig: false,
            authorizer: authorizer
        )
        #expect(authorizer.undeterminedRequestCount == 0)

        CloudGatewayExistingInstallNotificationAuthorization.requestIfNeeded(
            hasInstalledConfig: true,
            authorizer: authorizer
        )
        #expect(authorizer.undeterminedRequestCount == 1)

        CloudGatewayFirstInstallNotificationAuthorization.request(authorizer: authorizer)
        #expect(authorizer.requestCount == 1)
    }
}

@MainActor
private final class RecordingNotificationAuthorizer: CloudGatewayNotificationAuthorizing {
    private(set) var requestCount = 0
    private(set) var undeterminedRequestCount = 0

    func requestAuthorization() {
        requestCount += 1
    }

    func requestAuthorizationIfUndetermined() {
        undeterminedRequestCount += 1
    }
}
