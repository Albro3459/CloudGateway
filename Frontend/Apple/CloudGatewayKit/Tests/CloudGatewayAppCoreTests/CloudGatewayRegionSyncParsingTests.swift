@testable import CloudGatewayAppCore
import XCTest

/// Port of the sync-parsing cases from `Frontend/Web/src/helpers/__tests__/APIHelper.test.ts`.
final class CloudGatewayRegionSyncParsingTests: XCTestCase {
    // MARK: - Fixtures

    private func baseFields(overrides: [String: Any?] = [:]) -> [String: Any] {
        var fields: [String: Any] = [
            "regionId": "us-sanjose-1",
            "syncedAt": "2026-08-10T00:00:00Z",
            "added": 0,
            "updated": 0,
            "removed": 0,
            "noChanges": true,
            "log": "sync log",
            "meshUpdated": 0,
            "meshEnabled": true,
            "meshApplied": 0,
            "meshAdded": 0,
            "meshRemoved": 0,
            "meshSkipped": 0,
            "meshRoutesAdded": 0,
            "meshRoutesRemoved": 0,
            "meshPeers": [[String: Any]](),
        ]
        apply(overrides, to: &fields)
        return fields
    }

    private func appliedPeer(overrides: [String: Any?] = [:]) -> [String: Any] {
        var fields: [String: Any] = [
            "regionId": "us-chicago-1",
            "status": "applied",
            "endpointHostname": "wg.us-chicago-1.example.com",
            "endpointPort": 51820,
            "allowedNetworkV4": "10.0.1.0/24",
            "allowedNetworkV6": "fd42:42:42:1::/64",
        ]
        apply(overrides, to: &fields)
        return fields
    }

    private func skippedIncompletePeer(overrides: [String: Any?] = [:]) -> [String: Any] {
        var fields: [String: Any] = [
            "regionId": "us-chicago-1",
            "status": "skipped-incomplete",
            "reasonCode": "outside-aggregate",
        ]
        apply(overrides, to: &fields)
        return fields
    }

    private func apply(_ overrides: [String: Any?], to fields: inout [String: Any]) {
        for (key, value) in overrides {
            if let value {
                fields[key] = value
            } else {
                fields.removeValue(forKey: key)
            }
        }
    }

    private func parse(_ fields: [String: Any], regionId: String = "us-sanjose-1") -> CloudGatewayRegionSyncResponse? {
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return CloudGatewayRegionSyncParsing.parse(data: data, requestedRegionId: regionId)
    }

    // MARK: - Required fields and shape

    func testRejectsResponseMissingRequiredMeshUpdatedField() {
        var fields = baseFields()
        fields.removeValue(forKey: "meshUpdated")
        XCTAssertNil(parse(fields))
    }

    func testRejectsResponseMissingRegionId() {
        var fields = baseFields()
        fields.removeValue(forKey: "regionId")
        XCTAssertNil(parse(fields))
    }

    func testRejectsNonObjectTopLevelPayload() {
        let data = try! JSONSerialization.data(withJSONObject: [1, 2, 3])
        XCTAssertNil(CloudGatewayRegionSyncParsing.parse(data: data, requestedRegionId: "us-sanjose-1"))
    }

    func testRejectsResponseForADifferentRequestedRegion() {
        XCTAssertNil(parse(baseFields(), regionId: "us-chicago-1"))
    }

    // MARK: - meshStatusWritten: absent vs. malformed

    func testAbsentMeshStatusWrittenParsesAsUnknown() {
        let result = parse(baseFields())
        XCTAssertNotNil(result)
        XCTAssertNil(result?.meshStatusWritten)
    }

    func testFalseMeshStatusWrittenSurvivesAsASuccessfulSync() {
        let result = parse(baseFields(overrides: ["meshStatusWritten": false]))
        XCTAssertEqual(result?.meshStatusWritten, false)
    }

    func testRejectsNonBooleanMeshStatusWritten() {
        XCTAssertNil(parse(baseFields(overrides: ["meshStatusWritten": "false"])))
    }

    func testRejectsExplicitNullMeshStatusWritten() {
        XCTAssertNil(parse(baseFields(overrides: ["meshStatusWritten": NSNull()])))
    }

    // MARK: - Counters

    func testRejectsNegativeCounter() {
        XCTAssertNil(parse(baseFields(overrides: ["added": -1])))
    }

    func testRejectsNonIntegerCounter() {
        XCTAssertNil(parse(baseFields(overrides: ["added": 3.5])))
    }

    func testAcceptsAnIntegralFloatCounter() {
        // JS `Number.isInteger(3.0)` is true; mirror that instead of rejecting on a decimal point.
        XCTAssertNotNil(parse(baseFields(overrides: ["added": 3.0])))
    }

    // MARK: - Applied / skipped-overlap peers

    func testAcceptsAppliedPeerShapeWithoutRequiringAReasonCode() {
        let fields = baseFields(overrides: [
            "noChanges": false,
            "meshUpdated": 1,
            "meshApplied": 1,
            "meshAdded": 1,
            "meshRoutesAdded": 2,
            "meshPeers": [appliedPeer()],
        ])
        guard let result = parse(fields) else { return XCTFail("expected a parsed response") }
        XCTAssertEqual(result.meshPeers.count, 1)
        let peer = result.meshPeers[0]
        XCTAssertEqual(peer.regionId, "us-chicago-1")
        XCTAssertEqual(peer.status, .applied)
        XCTAssertEqual(peer.endpointHostname, "wg.us-chicago-1.example.com")
        XCTAssertEqual(peer.endpointPort, 51820)
        XCTAssertEqual(peer.allowedNetworkV4, "10.0.1.0/24")
        XCTAssertEqual(peer.allowedNetworkV6, "fd42:42:42:1::/64")
        XCTAssertNil(peer.reasonCode)
    }

    func testRejectsAppliedPeerWithInvalidEndpointHostname() {
        let peer = appliedPeer(overrides: ["endpointHostname": 123])
        XCTAssertNil(parse(baseFields(overrides: ["meshPeers": [peer]])))
    }

    func testRejectsAppliedPeerWithInvalidEndpointPort() {
        let peer = appliedPeer(overrides: ["endpointPort": "51820"])
        XCTAssertNil(parse(baseFields(overrides: ["meshPeers": [peer]])))
    }

    func testRejectsAppliedPeerWithNullNetworkV4() {
        let peer = appliedPeer(overrides: ["allowedNetworkV4": NSNull()])
        XCTAssertNil(parse(baseFields(overrides: ["meshPeers": [peer]])))
    }

    func testRejectsAppliedPeerWithWrongTypeNetworkV6() {
        let peer = appliedPeer(overrides: ["allowedNetworkV6": [String: Any]()])
        XCTAssertNil(parse(baseFields(overrides: ["meshPeers": [peer]])))
    }

    func testRejectsPeerWithUnknownStatus() {
        let peer = appliedPeer(overrides: ["status": "bogus-status"])
        XCTAssertNil(parse(baseFields(overrides: ["meshPeers": [peer]])))
    }

    func testRejectsAppliedPeerWithUnknownReasonCode() {
        let peer = appliedPeer(overrides: ["reasonCode": "not-a-real-code"])
        XCTAssertNil(parse(baseFields(overrides: ["meshPeers": [peer]])))
    }

    func testAppliedPeerAcceptsAKnownReasonCode() {
        let peer = appliedPeer(overrides: ["reasonCode": "duplicate-public-key"])
        guard let result = parse(baseFields(overrides: ["meshPeers": [peer]])) else {
            return XCTFail("expected a parsed response")
        }
        XCTAssertEqual(result.meshPeers.first?.reasonCode, "duplicate-public-key")
    }

    func testSkippedOverlapRequiresAKnownReasonCode() {
        let peer = appliedPeer(overrides: ["status": "skipped-overlap"])
        XCTAssertNil(parse(baseFields(overrides: ["meshPeers": [peer]])))
    }

    func testSkippedOverlapWithAKnownReasonCodeParses() {
        let peer = appliedPeer(overrides: ["status": "skipped-overlap", "reasonCode": "overlap-candidate"])
        guard let result = parse(baseFields(overrides: ["meshPeers": [peer]])) else {
            return XCTFail("expected a parsed response")
        }
        XCTAssertEqual(result.meshPeers.first?.status, .skippedOverlap)
        XCTAssertEqual(result.meshPeers.first?.reasonCode, "overlap-candidate")
    }

    // MARK: - skipped-incomplete peers

    func testOmitsAbsentNullAndBlankOptionalSkippedIncompletePeerFields() {
        let peers: [[String: Any]] = [
            skippedIncompletePeer(overrides: ["reasonCode": "missing-endpoint-hostname"]),
            skippedIncompletePeer(overrides: [
                "reasonCode": "invalid-network-v4",
                "endpointHostname": NSNull(),
                "endpointPort": NSNull(),
                "allowedNetworkV4": NSNull(),
                "allowedNetworkV6": NSNull(),
            ]),
            skippedIncompletePeer(overrides: [
                "reasonCode": "invalid-network-v6",
                "endpointHostname": "  ",
                "allowedNetworkV4": "",
                "allowedNetworkV6": "\t",
            ]),
        ]
        let fields = baseFields(overrides: ["meshSkipped": 3, "meshPeers": peers])
        guard let result = parse(fields) else { return XCTFail("expected a parsed response") }
        XCTAssertEqual(result.meshPeers.count, 3)
        for peer in result.meshPeers {
            XCTAssertEqual(peer.status, .skippedIncomplete)
            XCTAssertNil(peer.endpointHostname)
            XCTAssertNil(peer.endpointPort)
            XCTAssertNil(peer.allowedNetworkV4)
            XCTAssertNil(peer.allowedNetworkV6)
        }
        XCTAssertEqual(result.meshPeers.map(\.reasonCode), [
            "missing-endpoint-hostname", "invalid-network-v4", "invalid-network-v6",
        ])
    }

    func testAcceptsPresentNonblankValidSkippedIncompletePeerOptionalFields() {
        let peer = skippedIncompletePeer(overrides: [
            "endpointHostname": "2001:db8::1",
            "endpointPort": 51820,
            "allowedNetworkV4": "192.0.2.0/24",
            "allowedNetworkV6": "2001:db8:1:2::/64",
        ])
        let fields = baseFields(overrides: ["meshSkipped": 1, "meshPeers": [peer]])
        guard let result = parse(fields), let parsedPeer = result.meshPeers.first else {
            return XCTFail("expected a parsed peer")
        }
        XCTAssertEqual(parsedPeer.endpointHostname, "2001:db8::1")
        XCTAssertEqual(parsedPeer.endpointPort, 51820)
        XCTAssertEqual(parsedPeer.allowedNetworkV4, "192.0.2.0/24")
        XCTAssertEqual(parsedPeer.allowedNetworkV6, "2001:db8:1:2::/64")
        XCTAssertEqual(parsedPeer.reasonCode, "outside-aggregate")
    }

    func testRejectsSkippedIncompletePeerWithInvalidNonblankHostname() {
        let peer = skippedIncompletePeer(overrides: ["endpointHostname": "bad_hostname.example.com"])
        XCTAssertNil(parse(baseFields(overrides: ["meshSkipped": 1, "meshPeers": [peer]])))
    }

    func testRejectsSkippedIncompletePeerWithInvalidNonblankPort() {
        let peer = skippedIncompletePeer(overrides: ["endpointPort": 65536])
        XCTAssertNil(parse(baseFields(overrides: ["meshSkipped": 1, "meshPeers": [peer]])))
    }

    func testRejectsSkippedIncompletePeerWithInvalidNonblankNetworkV4() {
        // Aggregate-membership is deliberately not required here, only syntax; this is out-of-range
        // syntactically valid /24 so only the aggregate check would catch it — must still pass.
        let peer = skippedIncompletePeer(overrides: ["allowedNetworkV4": "192.0.2.1/24"])
        XCTAssertNil(parse(baseFields(overrides: ["meshSkipped": 1, "meshPeers": [peer]])))
    }

    func testRejectsSkippedIncompletePeerWithInvalidNonblankNetworkV6() {
        let peer = skippedIncompletePeer(overrides: ["allowedNetworkV6": "2001:db8:1:2::1/64"])
        XCTAssertNil(parse(baseFields(overrides: ["meshSkipped": 1, "meshPeers": [peer]])))
    }

    func testRejectsSkippedIncompletePeerWithUnknownReasonCode() {
        let peer = skippedIncompletePeer(overrides: ["reasonCode": "not-a-real-code"])
        XCTAssertNil(parse(baseFields(overrides: ["meshSkipped": 1, "meshPeers": [peer]])))
    }

    func testRejectsSkippedIncompletePeerMissingReasonCode() {
        let peer = skippedIncompletePeer(overrides: ["reasonCode": nil])
        XCTAssertNil(parse(baseFields(overrides: ["meshSkipped": 1, "meshPeers": [peer]])))
    }

    // MARK: - syncedAt shapes

    func testParsesFractionalSecondsSyncedAt() {
        // Real pydantic v2 output: tz-aware UTC datetime serialized with microseconds and `Z`.
        XCTAssertNotNil(CloudGatewayRegionSyncParsing.syncedAtDate("2026-08-15T20:38:37.814426Z"))
    }

    func testParsesPlainZSyncedAt() {
        XCTAssertNotNil(CloudGatewayRegionSyncParsing.syncedAtDate("2026-08-10T00:00:00Z"))
    }

    func testParsesOffsetFormSyncedAt() {
        // The (currently inaccurate) docs example shape; must still parse.
        XCTAssertNotNil(CloudGatewayRegionSyncParsing.syncedAtDate("2026-06-17T18:30:00+00:00"))
    }

    func testRejectsUnparseableSyncedAt() {
        XCTAssertNil(CloudGatewayRegionSyncParsing.syncedAtDate("not-a-date"))
        XCTAssertNil(parse(baseFields(overrides: ["syncedAt": "not-a-date"])))
    }

    func testRejectsBlankSyncedAt() {
        XCTAssertNil(parse(baseFields(overrides: ["syncedAt": "   "])))
    }

    // MARK: - Full round trip

    func testParsesAFullyPopulatedResponse() {
        let applied = appliedPeer()
        let overlap = appliedPeer(overrides: [
            "regionId": "us-austin-1",
            "status": "skipped-overlap",
            "reasonCode": "overlap-candidate",
        ])
        let incomplete = skippedIncompletePeer()
        let fields = baseFields(overrides: [
            "syncedAt": "2026-08-15T20:38:37.814426Z",
            "added": 2,
            "updated": 1,
            "removed": 0,
            "noChanges": false,
            "log": "sync log",
            "meshUpdated": 3,
            "meshApplied": 1,
            "meshAdded": 1,
            "meshRemoved": 0,
            "meshSkipped": 1,
            "meshRoutesAdded": 2,
            "meshRoutesRemoved": 0,
            "meshStatusWritten": true,
            "meshPeers": [applied, overlap, incomplete],
        ])
        guard let result = parse(fields) else { return XCTFail("expected a parsed response") }
        XCTAssertEqual(result.regionId, "us-sanjose-1")
        XCTAssertEqual(result.syncedAt, "2026-08-15T20:38:37.814426Z")
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.removed, 0)
        XCTAssertFalse(result.noChanges)
        XCTAssertEqual(result.log, "sync log")
        XCTAssertEqual(result.meshUpdated, 3)
        XCTAssertTrue(result.meshEnabled)
        XCTAssertEqual(result.meshApplied, 1)
        XCTAssertEqual(result.meshAdded, 1)
        XCTAssertEqual(result.meshRemoved, 0)
        XCTAssertEqual(result.meshSkipped, 1)
        XCTAssertEqual(result.meshRoutesAdded, 2)
        XCTAssertEqual(result.meshRoutesRemoved, 0)
        XCTAssertEqual(result.meshStatusWritten, true)
        XCTAssertEqual(result.meshPeers.map(\.status), [.applied, .skippedOverlap, .skippedIncomplete])
        XCTAssertNotNil(CloudGatewayRegionSyncParsing.syncedAtDate(result.syncedAt))
    }
}
