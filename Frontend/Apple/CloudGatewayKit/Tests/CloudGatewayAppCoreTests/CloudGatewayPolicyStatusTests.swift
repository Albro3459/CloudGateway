@testable import CloudGatewayAppCore
import XCTest

/// Port of `Frontend/Web/src/helpers/__tests__/policyHelper.test.ts`, plus mapper coverage for
/// `CloudGatewayFirestorePolicyMapper`. Policy docs for the parse cases are built through the
/// mapper (not the model initializer directly) so field coercion is exercised the same way the TS
/// tests exercise `parsePolicyDocument`.
final class CloudGatewayPolicyStatusTests: XCTestCase {
    private let mapHashV4 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let mapHashV6 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private let otherMapHashV4 = "cccccccccccccccccccccccccccccccc"
    private let otherMapHashV6 = "dddddddddddddddddddddddddddddddd"

    private func makeRegion(_ regionId: String, enabled: Bool = true) -> CloudGatewayMeshRegion {
        CloudGatewayMeshRegion(
            regionId: regionId,
            displayName: regionId,
            enabled: enabled,
            displayOrder: 1000,
            meshEnabled: true,
            wireguardPublicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            wireguardEndpointHostname: "wg.example.com",
            wireguardPort: 51820,
            tunnelNetworkV4: "10.0.1.0/24",
            tunnelNetworkV6: "fd42:42:42:1::/64"
        )
    }

    private func makeDoc(
        _ regionId: String,
        mapHashV4: String? = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        mapHashV6: String? = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        rowCount: Int? = 3,
        updatedAt: Date? = Date(timeIntervalSince1970: 1_767_225_600)
    ) -> CloudGatewayPolicyDoc {
        CloudGatewayPolicyDoc(regionId: regionId, mapHashV4: mapHashV4, mapHashV6: mapHashV6, rowCount: rowCount, updatedAt: updatedAt)
    }

    // MARK: - parsePolicyDocument (via policyDoc mapper)

    func testParsesAWellFormedDoc() {
        let updatedAt = Date(timeIntervalSince1970: 1_767_312_000)
        let doc = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "us-sanjose-1", data: [
            "mapHashV4": mapHashV4,
            "mapHashV6": mapHashV6,
            "rowCount": 12,
            "updatedAt": updatedAt,
        ])

        XCTAssertEqual(doc, CloudGatewayPolicyDoc(regionId: "us-sanjose-1", mapHashV4: mapHashV4, mapHashV6: mapHashV6, rowCount: 12, updatedAt: updatedAt))
    }

    func testNeverThrowsOnAMalformedOrPartialDocCoercingBadFieldsToNil() {
        let doc = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "us-sanjose-1", data: [
            "mapHashV4": 12345,
            // mapHashV6 missing entirely
            "rowCount": "not-a-number",
            // updatedAt missing entirely
        ])

        XCTAssertEqual(doc, CloudGatewayPolicyDoc(regionId: "us-sanjose-1", mapHashV4: nil, mapHashV6: nil, rowCount: nil, updatedAt: nil))
    }

    func testTreatsAnEmptyDictionaryAsAFullyNilDocRatherThanCrashing() {
        let doc = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "us-sanjose-1", data: [:])

        XCTAssertEqual(doc.regionId, "us-sanjose-1")
        XCTAssertNil(doc.mapHashV4)
        XCTAssertNil(doc.mapHashV6)
        XCTAssertNil(doc.rowCount)
        XCTAssertNil(doc.updatedAt)
    }

    func testParsesAZeroRowSnapshotAsUsableRatherThanAsAMissingField() {
        let doc = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "us-sanjose-1", data: [
            "mapHashV4": mapHashV4,
            "mapHashV6": mapHashV6,
            "rowCount": 0,
            "updatedAt": Date(timeIntervalSince1970: 1_767_312_000),
        ])

        XCTAssertEqual(doc.rowCount, 0)
    }

    // MARK: - buildPolicyStatusRows

    func testMarksARegionOkWhenItsHashesMatchAClearFleetMajority() {
        let regions = [makeRegion("us-sanjose-1"), makeRegion("us-chicago-1"), makeRegion("us-dallas-1")]
        let docs: [String: CloudGatewayPolicyDoc] = [
            "us-sanjose-1": makeDoc("us-sanjose-1"),
            "us-chicago-1": makeDoc("us-chicago-1"),
            "us-dallas-1": makeDoc("us-dallas-1", mapHashV4: otherMapHashV4),
        ]

        let rows = CloudGatewayPolicyStatus.buildPolicyStatusRows(regions: regions, policyDocs: docs)

        XCTAssertEqual(rows.first { $0.regionId == "us-sanjose-1" }?.state, .ok)
        XCTAssertEqual(rows.first { $0.regionId == "us-chicago-1" }?.state, .ok)
    }

    func testFlagsTheMinorityRegionAsDriftedAgainstAClearMajority() {
        let regions = [makeRegion("us-sanjose-1"), makeRegion("us-chicago-1"), makeRegion("us-dallas-1")]
        let docs: [String: CloudGatewayPolicyDoc] = [
            "us-sanjose-1": makeDoc("us-sanjose-1"),
            "us-chicago-1": makeDoc("us-chicago-1"),
            "us-dallas-1": makeDoc("us-dallas-1", mapHashV4: otherMapHashV4),
        ]

        let rows = CloudGatewayPolicyStatus.buildPolicyStatusRows(regions: regions, policyDocs: docs)

        let dallas = rows.first { $0.regionId == "us-dallas-1" }
        XCTAssertEqual(dallas?.state, .drifted)
        XCTAssertEqual(dallas?.driftedV4, true)
        XCTAssertEqual(dallas?.driftedV6, false)
    }

    func testFlagsEveryComparableRegionAsDriftedWhenThereIsNoStrictMajorityEvenSplit() {
        let regions = [makeRegion("us-sanjose-1"), makeRegion("us-chicago-1")]
        let docs: [String: CloudGatewayPolicyDoc] = [
            "us-sanjose-1": makeDoc("us-sanjose-1", mapHashV4: mapHashV4),
            "us-chicago-1": makeDoc("us-chicago-1", mapHashV4: otherMapHashV4),
        ]

        let rows = CloudGatewayPolicyStatus.buildPolicyStatusRows(regions: regions, policyDocs: docs)

        XCTAssertEqual(rows.first { $0.regionId == "us-sanjose-1" }?.state, .drifted)
        XCTAssertEqual(rows.first { $0.regionId == "us-sanjose-1" }?.driftedV4, true)
        XCTAssertEqual(rows.first { $0.regionId == "us-chicago-1" }?.state, .drifted)
        XCTAssertEqual(rows.first { $0.regionId == "us-chicago-1" }?.driftedV4, true)
    }

    func testFlagsEveryComparableRegionAsDriftedWhenEveryRegionDisagreesThreeWaySplit() {
        let regions = [makeRegion("us-sanjose-1"), makeRegion("us-chicago-1"), makeRegion("us-dallas-1")]
        let docs: [String: CloudGatewayPolicyDoc] = [
            "us-sanjose-1": makeDoc("us-sanjose-1", mapHashV4: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            "us-chicago-1": makeDoc("us-chicago-1", mapHashV4: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
            "us-dallas-1": makeDoc("us-dallas-1", mapHashV4: "cccccccccccccccccccccccccccccccc"),
        ]

        let rows = CloudGatewayPolicyStatus.buildPolicyStatusRows(regions: regions, policyDocs: docs)

        XCTAssertTrue(rows.allSatisfy { $0.state == .drifted })
    }

    func testNeverMarksALoneComparableRegionAsDriftedSinceItHasNoPeersToDifferFrom() {
        let regions = [makeRegion("us-sanjose-1")]
        let docs: [String: CloudGatewayPolicyDoc] = ["us-sanjose-1": makeDoc("us-sanjose-1")]

        let rows = CloudGatewayPolicyStatus.buildPolicyStatusRows(regions: regions, policyDocs: docs)

        XCTAssertEqual(rows[0].state, .ok)
        XCTAssertFalse(rows[0].driftedV4)
        XCTAssertFalse(rows[0].driftedV6)
    }

    func testExcludesADisabledRegionFromTheComparisonEntirely() {
        let regions = [makeRegion("us-sanjose-1"), makeRegion("us-chicago-1"), makeRegion("us-dallas-1", enabled: false)]
        let docs: [String: CloudGatewayPolicyDoc] = [
            "us-sanjose-1": makeDoc("us-sanjose-1"),
            "us-chicago-1": makeDoc("us-chicago-1"),
            // Dallas is disabled and wildly divergent - must not affect anyone.
            "us-dallas-1": makeDoc("us-dallas-1", mapHashV4: otherMapHashV4, mapHashV6: otherMapHashV6),
        ]

        let rows = CloudGatewayPolicyStatus.buildPolicyStatusRows(regions: regions, policyDocs: docs)

        XCTAssertEqual(rows.first { $0.regionId == "us-sanjose-1" }?.state, .ok)
        XCTAssertEqual(rows.first { $0.regionId == "us-chicago-1" }?.state, .ok)
        let dallas = rows.first { $0.regionId == "us-dallas-1" }
        XCTAssertEqual(dallas?.state, .disabled)
        XCTAssertFalse(dallas?.driftedV4 ?? true)
        XCTAssertFalse(dallas?.driftedV6 ?? true)
        // Its doc values still render even though it doesn't participate.
        XCTAssertEqual(dallas?.doc?.mapHashV4, otherMapHashV4)
    }

    func testGivesADisabledRegionItsOwnStateEvenWithNoDocAtAllRatherThanNeverSynced() {
        let regions = [makeRegion("us-sanjose-1", enabled: false)]
        let rows = CloudGatewayPolicyStatus.buildPolicyStatusRows(regions: regions, policyDocs: [:])

        XCTAssertEqual(rows[0].state, .disabled)
        XCTAssertNil(rows[0].doc)
        XCTAssertFalse(rows[0].driftedV4)
        XCTAssertFalse(rows[0].driftedV6)
    }

    func testRendersARegionMissingEntirelyFromTheDocsMapAsNeverSynced() {
        let regions = [makeRegion("us-sanjose-1")]
        let rows = CloudGatewayPolicyStatus.buildPolicyStatusRows(regions: regions, policyDocs: [:])

        XCTAssertEqual(rows[0].state, .neverSynced)
        XCTAssertNil(rows[0].doc)
        XCTAssertFalse(rows[0].driftedV4)
        XCTAssertFalse(rows[0].driftedV6)
    }

    func testRendersADocMissingIdentityFieldsAsUnreadableRatherThanComparingIt() {
        let regions = [makeRegion("us-sanjose-1"), makeRegion("us-chicago-1")]
        let docs: [String: CloudGatewayPolicyDoc] = [
            "us-sanjose-1": makeDoc("us-sanjose-1", mapHashV4: nil),
            "us-chicago-1": makeDoc("us-chicago-1"),
        ]

        let rows = CloudGatewayPolicyStatus.buildPolicyStatusRows(regions: regions, policyDocs: docs)

        let sanJose = rows.first { $0.regionId == "us-sanjose-1" }
        XCTAssertEqual(sanJose?.state, .unreadable)
        XCTAssertFalse(sanJose?.driftedV4 ?? true)
        XCTAssertFalse(sanJose?.driftedV6 ?? true)
        // The doc still renders (its usable fields, if any) even though it's unreadable overall.
        XCTAssertEqual(sanJose?.doc?.mapHashV6, mapHashV6)
        // The unreadable doc must not count toward the comparable set for the other region's
        // drift check.
        let chicago = rows.first { $0.regionId == "us-chicago-1" }
        XCTAssertEqual(chicago?.state, .ok)
        XCTAssertFalse(chicago?.driftedV4 ?? true)
    }

    func testRendersAZeroRowSnapshotsRowCountAndLastAppliedTimeRatherThanTreatingItAsUnusable() {
        let regions = [makeRegion("us-sanjose-1")]
        let updatedAt = Date(timeIntervalSince1970: 1_767_398_400)
        let docs: [String: CloudGatewayPolicyDoc] = [
            "us-sanjose-1": makeDoc("us-sanjose-1", rowCount: 0, updatedAt: updatedAt),
        ]

        let rows = CloudGatewayPolicyStatus.buildPolicyStatusRows(regions: regions, policyDocs: docs)

        XCTAssertEqual(rows[0].state, .ok)
        XCTAssertEqual(rows[0].doc?.rowCount, 0)
        XCTAssertEqual(rows[0].doc?.updatedAt, updatedAt)
    }

    // MARK: - CloudGatewayFirestorePolicyMapper: rowCount (Swift-specific, no TS equivalent)

    func testRowCountRejectsACFBooleanBackedNSNumber() {
        // On Apple platforms `NSNumber as? Bool` spuriously succeeds for non-boolean numerics, so
        // a real Firestore boolean must be rejected explicitly rather than read as 0/1.
        let trueDoc = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["rowCount": NSNumber(value: true)])
        let falseDoc = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["rowCount": NSNumber(value: false)])

        XCTAssertNil(trueDoc.rowCount)
        XCTAssertNil(falseDoc.rowCount)
    }

    func testRowCountRejectsAFractionalValue() {
        let doc = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["rowCount": 3.5])
        XCTAssertNil(doc.rowCount)
    }

    func testRowCountRejectsNonFiniteValues() {
        let infinite = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["rowCount": Double.infinity])
        let nan = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["rowCount": Double.nan])

        XCTAssertNil(infinite.rowCount)
        XCTAssertNil(nan.rowCount)
    }

    func testRowCountRejectsAValueBeyondIntsRange() {
        // `Int(_: Double)` traps rather than returning nil, so an out-of-range number has to be
        // rejected before the conversion or a corrupt doc crashes the app.
        let doc = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["rowCount": 1e300])
        XCTAssertNil(doc.rowCount)
    }

    func testRowCountAcceptsIntegralDoubleIntNegativeAndZero() {
        // The web Firestore mapper imposes no non-negativity check, so none is added here either.
        XCTAssertEqual(CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["rowCount": 12.0]).rowCount, 12)
        XCTAssertEqual(CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["rowCount": 12]).rowCount, 12)
        XCTAssertEqual(CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["rowCount": -1]).rowCount, -1)
        XCTAssertEqual(CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["rowCount": 0]).rowCount, 0)
    }

    // MARK: - CloudGatewayFirestorePolicyMapper: updatedAt

    func testUpdatedAtAcceptsADateAndRejectsAStringOrNumber() {
        // Firebase `Timestamp` -> `Date` conversion is the iOS repository adapter's job and cannot
        // be exercised from the Firebase-free AppCore test target; this only covers the mapper's
        // own `Any? -> Date?` gate.
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let dateDoc = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["updatedAt": date])
        let stringDoc = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["updatedAt": "2026-01-01T00:00:00Z"])
        let numberDoc = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["updatedAt": 1_767_225_600])

        XCTAssertEqual(dateDoc.updatedAt, date)
        XCTAssertNil(stringDoc.updatedAt)
        XCTAssertNil(numberDoc.updatedAt)
    }

    // MARK: - CloudGatewayFirestorePolicyMapper: string coercion

    func testStringCoercionPreservesTheUntrimmedOriginalRejectsBlankAndRejectsNonString() {
        let untrimmed = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["mapHashV4": "  abcd  "])
        let blank = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["mapHashV4": "   "])
        let nonString = CloudGatewayFirestorePolicyMapper.policyDoc(documentId: "r", data: ["mapHashV4": 12345])

        XCTAssertEqual(untrimmed.mapHashV4, "  abcd  ")
        XCTAssertNil(blank.mapHashV4)
        XCTAssertNil(nonString.mapHashV4)
    }
}
