@testable import CloudGatewayAppCore
import XCTest

/// Port of `Frontend/Web/src/helpers/__tests__/meshValidation.test.ts`.
final class CloudGatewayMeshValidationTests: XCTestCase {
    func testAcceptsOnlyDecoded32ByteWireGuardKeys() {
        XCTAssertTrue(CloudGatewayMeshValidation.isValidWireGuardPublicKey("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidWireGuardPublicKey("public-key"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidWireGuardPublicKey(String(repeating: "!", count: 43) + "="))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidWireGuardPublicKey(nil))
    }

    func testValidatesHostnamesAndIPEndpoints() {
        XCTAssertTrue(CloudGatewayMeshValidation.isValidEndpointHostname("wg.example.com"))
        XCTAssertTrue(CloudGatewayMeshValidation.isValidEndpointHostname("192.0.2.1"))
        XCTAssertTrue(CloudGatewayMeshValidation.isValidEndpointHostname("2001:db8::1"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidEndpointHostname("-bad.example.com"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidEndpointHostname("bad-.example.com"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidEndpointHostname(nil))
    }

    func testValidatesCanonicalAggregateMeshNetworks() {
        XCTAssertTrue(CloudGatewayMeshValidation.isValidMeshNetworkV4("10.0.1.0/24"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkV4("10.1.1.0/24"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkV4("10.0.1.1/24"))
        XCTAssertTrue(CloudGatewayMeshValidation.isValidMeshNetworkV6("fd42:42:42:1::/64"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkV6("fd42:42:43:1::/64"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkV6("FD42:42:42:1::/64"))
    }

    func testValidatesCanonicalSlash24AndSlash64NetworkSyntaxIndependentlyFromMeshAggregates() {
        XCTAssertTrue(CloudGatewayMeshValidation.isValidMeshNetworkSyntaxV4("192.0.2.0/24"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkV4("192.0.2.0/24"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkSyntaxV4("192.0.2.1/24"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkSyntaxV4("192.0.2.0/25"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkSyntaxV4("192.000.2.0/24"))
        XCTAssertTrue(CloudGatewayMeshValidation.isValidMeshNetworkSyntaxV6("2001:db8:1:2::/64"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkV6("2001:db8:1:2::/64"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkSyntaxV6("2001:db8:1:2::1/64"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkSyntaxV6("2001:0db8:1:2::/64"))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkSyntaxV6("2001:db8:1:2::/63"))
    }

    func testValidatesPortsAndOverlap() {
        XCTAssertTrue(CloudGatewayMeshValidation.isValidMeshEndpointPort(51820))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshEndpointPort(nil))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshEndpointPort(0))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshEndpointPort(65536))
        XCTAssertTrue(CloudGatewayMeshValidation.isValidMeshEndpointPort(1))
        XCTAssertTrue(CloudGatewayMeshValidation.isValidMeshEndpointPort(65535))
        XCTAssertTrue(CloudGatewayMeshValidation.networksOverlap("10.0.1.0/24", "10.0.1.0/24"))
        XCTAssertFalse(CloudGatewayMeshValidation.networksOverlap("10.0.1.0/24", "10.0.2.0/24"))
        XCTAssertTrue(CloudGatewayMeshValidation.networksOverlap("fd42:42:42:1::/64", "fd42:42:42:1::/64"))
    }

    // MARK: - Swift-specific: `components(separatedBy:)` vs. `split` empty-subsequence pitfall
    //
    // JS `"".split(".")` yields `[""]`, so a trailing/doubled separator leaves an empty part behind.
    // Swift's `split(separator:)` drops empty subsequences by default and would wrongly let these
    // through; `components(separatedBy:)` (used throughout the port) preserves the empty parts.

    func testTrailingDotInIPv4LiteralIsRejected() {
        XCTAssertFalse(CloudGatewayMeshValidation.isValidEndpointHostname("10.0.0."))
    }

    func testDoubleDotInIPv4LiteralIsRejected() {
        XCTAssertFalse(CloudGatewayMeshValidation.isValidEndpointHostname("10..0.0"))
    }

    func testDoubleDotHostnameLabelIsRejected() {
        XCTAssertFalse(CloudGatewayMeshValidation.isValidEndpointHostname("a..b"))
    }

    func testTrailingDotHostnameIsRejected() {
        XCTAssertFalse(CloudGatewayMeshValidation.isValidEndpointHostname("wg.example.com."))
    }

    // MARK: - Swift-specific: base64 length mismatch

    func testWrongLengthPublicKeyStringIsRejectedBeforeDecoding() {
        // 42 chars + "=" fails the length/format gate outright, never reaching the decode step.
        XCTAssertFalse(CloudGatewayMeshValidation.isValidWireGuardPublicKey(String(repeating: "A", count: 42) + "="))
        // Two padding characters also fails the character-class gate on the 43rd character.
        XCTAssertFalse(CloudGatewayMeshValidation.isValidWireGuardPublicKey(String(repeating: "A", count: 42) + "=="))
    }

    // MARK: - Additional IPv6 parsing coverage (formatIPv6Canonical / parseIPv6 edge cases)

    func testIPv6DoubleColonCompressionIsRequiredForCanonicalForm() {
        // Fully expanded form is valid syntax but not canonical, so it fails the canonical check.
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkSyntaxV6("fd42:0042:0042:1:0:0:0:0/64"))
    }

    func testIPv6MultipleDoubleColonsAreRejected() {
        XCTAssertFalse(CloudGatewayMeshValidation.isValidEndpointHostname("fd42::42::1"))
    }

    func testIPv6WithEmbeddedDotIsRejected() {
        XCTAssertFalse(CloudGatewayMeshValidation.isValidEndpointHostname("fd42::192.0.2.1"))
    }

    func testNilInputsAreRejectedForSyntaxAndAggregateChecks() {
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkSyntaxV4(nil))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkV4(nil))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkSyntaxV6(nil))
        XCTAssertFalse(CloudGatewayMeshValidation.isValidMeshNetworkV6(nil))
    }

    func testMismatchedFamilyNetworksNeverOverlap() {
        XCTAssertFalse(CloudGatewayMeshValidation.networksOverlap("10.0.1.0/24", "fd42:42:42:1::/64"))
    }
}
