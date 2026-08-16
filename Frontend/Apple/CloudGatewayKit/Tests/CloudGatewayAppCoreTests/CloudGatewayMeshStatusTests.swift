@testable import CloudGatewayAppCore
import XCTest

/// Port of `Frontend/Web/src/helpers/__tests__/meshHelper.test.ts`, plus mapper coverage for
/// `CloudGatewayFirestoreMeshMapper`. Mesh docs are built through the mapper (not the model
/// initializers directly) so peer-entry validation is exercised the same way the TS tests exercise
/// `parseMeshDocument`.
final class CloudGatewayMeshStatusTests: XCTestCase {
    private let validPublicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    private let otherPublicKey = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="

    private func makeRegion(
        _ regionId: String,
        meshEnabled: Bool,
        enabled: Bool = true,
        wireguardEndpointHostname: String? = "wg.example.com",
        wireguardPort: Int? = 51820,
        wireguardPublicKey: String? = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        tunnelNetworkV4: String? = "10.0.1.0/24",
        tunnelNetworkV6: String? = "fd42:42:42:1::/64"
    ) -> CloudGatewayMeshRegion {
        CloudGatewayMeshRegion(
            regionId: regionId,
            displayName: regionId,
            enabled: enabled,
            displayOrder: 1000,
            meshEnabled: meshEnabled,
            wireguardPublicKey: wireguardPublicKey,
            wireguardEndpointHostname: wireguardEndpointHostname,
            wireguardPort: wireguardPort,
            tunnelNetworkV4: tunnelNetworkV4,
            tunnelNetworkV6: tunnelNetworkV6
        )
    }

    private func peerData(
        endpointHostname: String? = "wg.example.com",
        endpointPort: Int? = 51820,
        publicKey: String? = nil,
        allowedNetworkV4: String? = "10.0.1.0/24",
        allowedNetworkV6: String? = "fd42:42:42:1::/64",
        status: String = "applied",
        reasonCode: String? = nil,
        appliedAt: Date? = nil
    ) -> [String: Any] {
        var data: [String: Any] = ["status": status]
        if let endpointHostname { data["endpointHostname"] = endpointHostname }
        if let endpointPort { data["endpointPort"] = endpointPort }
        let key = publicKey ?? validPublicKey
        data["publicKey"] = key
        if let allowedNetworkV4 { data["allowedNetworkV4"] = allowedNetworkV4 }
        if let allowedNetworkV6 { data["allowedNetworkV6"] = allowedNetworkV6 }
        if let reasonCode { data["reasonCode"] = reasonCode }
        if let appliedAt { data["appliedAt"] = appliedAt }
        return data
    }

    private func meshDoc(_ regionId: String, meshEnabled: Bool, peers: [String: Any] = [:]) -> CloudGatewayMeshDoc {
        CloudGatewayFirestoreMeshMapper.meshDoc(documentId: regionId, data: ["meshEnabled": meshEnabled, "peers": peers])
    }

    // MARK: - parseMeshDocument (via meshDoc mapper)

    func testParsesPeerEntriesAndDropsIncompleteOnes() {
        let doc = CloudGatewayFirestoreMeshMapper.meshDoc(documentId: "us-sanjose-1", data: [
            "meshEnabled": true,
            "updatedAt": Date(timeIntervalSince1970: 1_767_225_600),
            "peers": [
                "us-chicago-1": peerData(publicKey: otherPublicKey, appliedAt: Date(timeIntervalSince1970: 1_767_225_600)),
                // Missing publicKey - should be dropped rather than crash rendering.
                "us-dallas-1": ["endpointHostname": "wg.us-dallas-1.example.com", "status": "applied"],
            ],
        ])

        XCTAssertEqual(doc.regionId, "us-sanjose-1")
        XCTAssertTrue(doc.meshEnabled)
        XCTAssertEqual(Array(doc.peers.keys), ["us-chicago-1"])
        XCTAssertEqual(doc.peers["us-chicago-1"]?.status, .applied)
    }

    func testDefaultsMeshEnabledFalseAndPeersEmptyWhenFieldsAreMissing() {
        let doc = CloudGatewayFirestoreMeshMapper.meshDoc(documentId: "us-sanjose-1", data: [:])

        XCTAssertFalse(doc.meshEnabled)
        XCTAssertTrue(doc.peers.isEmpty)
        XCTAssertNil(doc.updatedAt)
    }

    func testRetainsBackendShapedSkippedIncompleteEntriesWithEmptyMetadata() {
        let doc = CloudGatewayFirestoreMeshMapper.meshDoc(documentId: "us-sanjose-1", data: [
            "meshEnabled": true,
            "peers": ["us-chicago-1": ["status": "skipped-incomplete", "reasonCode": "invalid-endpoint-port"]],
        ])

        let entry = doc.peers["us-chicago-1"]
        XCTAssertEqual(entry?.status, .skippedIncomplete)
        XCTAssertNil(entry?.endpointHostname)
        XCTAssertNil(entry?.endpointPort)
        XCTAssertNil(entry?.publicKey)
        XCTAssertNil(entry?.allowedNetworkV4)
        XCTAssertNil(entry?.allowedNetworkV6)
        XCTAssertEqual(entry?.reasonCode, "invalid-endpoint-port")
    }

    func testDropsAppliedEntriesWithoutTheCurrentEndpointPortSnapshot() {
        let legacyPeer: [String: Any] = [
            "endpointHostname": "wg.example.com",
            "publicKey": validPublicKey,
            "allowedNetworkV4": "10.0.1.0/24",
            "allowedNetworkV6": "fd42:42:42:1::/64",
            "status": "applied",
        ]
        let doc = CloudGatewayFirestoreMeshMapper.meshDoc(documentId: "us-sanjose-1", data: ["peers": ["us-chicago-1": legacyPeer]])

        XCTAssertNil(doc.peers["us-chicago-1"])
    }

    func testPreservesFutureReasonCodesInsteadOfDroppingEntries() {
        let doc = CloudGatewayFirestoreMeshMapper.meshDoc(documentId: "us-sanjose-1", data: [
            "peers": ["us-chicago-1": peerData(status: "skipped-incomplete", reasonCode: "future-reason")],
        ])

        XCTAssertEqual(doc.peers["us-chicago-1"]?.reasonCode, "future-reason")
    }

    // MARK: - isRegionMeshPending

    func testIsPendingWhenDesiredFlagDisagreesWithLastAppliedFlag() {
        let region = makeRegion("us-sanjose-1", meshEnabled: true)
        let doc = meshDoc("us-sanjose-1", meshEnabled: false)

        XCTAssertTrue(CloudGatewayMeshStatus.isRegionMeshPending(region: region, meshDoc: doc))
    }

    func testIsPendingWhenEnabledButNoMeshDocExistsYet() {
        XCTAssertTrue(CloudGatewayMeshStatus.isRegionMeshPending(region: makeRegion("us-sanjose-1", meshEnabled: true), meshDoc: nil))
    }

    func testIsNotPendingWhenDisabledAndThereIsNoMeshDoc() {
        XCTAssertFalse(CloudGatewayMeshStatus.isRegionMeshPending(region: makeRegion("us-sanjose-1", meshEnabled: false), meshDoc: nil))
    }

    func testIsNotPendingWhenTheFlagsAgree() {
        let doc = meshDoc("us-sanjose-1", meshEnabled: true)
        XCTAssertFalse(CloudGatewayMeshStatus.isRegionMeshPending(region: makeRegion("us-sanjose-1", meshEnabled: true), meshDoc: doc))
    }

    func testIsNeverPendingForADisabledRegion() {
        let disabled = makeRegion("us-chicago-1", meshEnabled: true, enabled: false)
        let doc = meshDoc("us-chicago-1", meshEnabled: false)

        XCTAssertFalse(CloudGatewayMeshStatus.isRegionMeshPending(region: disabled, meshDoc: nil))
        XCTAssertFalse(CloudGatewayMeshStatus.isRegionMeshPending(region: disabled, meshDoc: doc))
    }

    // MARK: - buildMeshLinkRows

    func testDoesNotTreatAnAppliedEntryWithoutEndpointPortAsCurrentState() {
        let regions = [makeRegion("us-sanjose-1", meshEnabled: true), makeRegion("us-chicago-1", meshEnabled: true)]
        let legacy = peerData(endpointPort: nil)
        let docs: [String: CloudGatewayMeshDoc] = [
            "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true, peers: ["us-chicago-1": legacy]),
            "us-chicago-1": meshDoc("us-chicago-1", meshEnabled: true, peers: ["us-sanjose-1": peerData()]),
        ]
        let rows = CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: docs)

        XCTAssertEqual(rows[0].status, .oneSided)
        XCTAssertTrue(rows[0].pending)
        XCTAssertFalse(rows[0].aToBStale)
    }

    func testMarksAnAppliedSnapshotStaleWhenAFieldChanges() {
        let mismatches: [[String: Any]] = [
            peerData(publicKey: otherPublicKey),
            peerData(endpointHostname: "other.example.com"),
            peerData(endpointPort: 51821),
            peerData(allowedNetworkV4: "10.0.2.0/24"),
            peerData(allowedNetworkV6: "fd42:42:42:2::/64"),
        ]
        for mismatch in mismatches {
            let regions = [makeRegion("us-sanjose-1", meshEnabled: true), makeRegion("us-chicago-1", meshEnabled: true)]
            let docs: [String: CloudGatewayMeshDoc] = [
                "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true, peers: ["us-chicago-1": mismatch]),
                "us-chicago-1": meshDoc("us-chicago-1", meshEnabled: true, peers: ["us-sanjose-1": peerData()]),
            ]
            let rows = CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: docs)

            XCTAssertEqual(rows[0].status, .stale)
            XCTAssertTrue(rows[0].pending)
        }
    }

    func testMarksAnAppliedEntryPendingWhenMeshMembershipIsDisabled() {
        let regions = [makeRegion("us-sanjose-1", meshEnabled: false), makeRegion("us-chicago-1", meshEnabled: true)]
        let docs: [String: CloudGatewayMeshDoc] = [
            "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: false, peers: ["us-chicago-1": peerData()]),
            "us-chicago-1": meshDoc("us-chicago-1", meshEnabled: true, peers: ["us-sanjose-1": peerData()]),
        ]

        XCTAssertTrue(CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: docs)[0].pending)
    }

    func testDoesNotKeepPendingAPersistentIdenticalInvalidSkip() {
        func invalidRegion(_ regionId: String) -> CloudGatewayMeshRegion {
            makeRegion(
                regionId, meshEnabled: true,
                wireguardEndpointHostname: nil, wireguardPort: nil, wireguardPublicKey: nil,
                tunnelNetworkV4: nil, tunnelNetworkV6: nil
            )
        }
        let regions = [invalidRegion("us-sanjose-1"), invalidRegion("us-chicago-1")]
        let invalid: [String: Any] = ["status": "skipped-incomplete", "reasonCode": "invalid-endpoint-port"]
        let docs: [String: CloudGatewayMeshDoc] = [
            "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true, peers: ["us-chicago-1": invalid]),
            "us-chicago-1": meshDoc("us-chicago-1", meshEnabled: true, peers: ["us-sanjose-1": invalid]),
        ]
        let rows = CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: docs)

        XCTAssertEqual(rows[0].status, .notSynced)
        XCTAssertFalse(rows[0].pending)
    }

    func testKeepsLocalNetworkInvalidAsAPersistentConfigurationFailure() {
        let regions = [makeRegion("us-sanjose-1", meshEnabled: true), makeRegion("us-chicago-1", meshEnabled: true)]
        var localNetworkInvalid = peerData()
        localNetworkInvalid["status"] = "skipped-incomplete"
        localNetworkInvalid["reasonCode"] = "local-network-invalid"
        let docs: [String: CloudGatewayMeshDoc] = [
            "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true, peers: ["us-chicago-1": localNetworkInvalid]),
            "us-chicago-1": meshDoc("us-chicago-1", meshEnabled: true, peers: ["us-sanjose-1": peerData()]),
        ]

        XCTAssertFalse(CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: docs)[0].pending)
    }

    func testDoesNotMarkUnchangedBackendShapedReasonCodesAsPending() {
        // (regionOverrides, peerOverrides, reasonCode)
        let cases: [(nilPublicKey: Bool, nilHostname: Bool, nilPort: Bool, nilV4: Bool, nilV6: Bool, reasonCode: String)] = [
            (true, false, false, false, false, "missing-public-key"),
            (true, false, false, false, false, "invalid-public-key"),
            (false, true, false, false, false, "missing-endpoint-hostname"),
            (false, true, false, false, false, "invalid-endpoint-hostname"),
            (false, false, true, false, false, "invalid-endpoint-port"),
            (false, false, false, true, false, "invalid-network-v4"),
            (false, false, false, false, true, "invalid-network-v6"),
        ]

        for testCase in cases {
            func invalidRegion(_ regionId: String) -> CloudGatewayMeshRegion {
                makeRegion(
                    regionId, meshEnabled: true,
                    wireguardEndpointHostname: testCase.nilHostname ? nil : "wg.example.com",
                    wireguardPort: testCase.nilPort ? nil : 51820,
                    wireguardPublicKey: testCase.nilPublicKey ? nil : validPublicKey,
                    tunnelNetworkV4: testCase.nilV4 ? nil : "10.0.1.0/24",
                    tunnelNetworkV6: testCase.nilV6 ? nil : "fd42:42:42:1::/64"
                )
            }
            let regions = [invalidRegion("us-sanjose-1"), invalidRegion("us-chicago-1")]
            var skipped = peerData(
                endpointHostname: testCase.nilHostname ? nil : "wg.example.com",
                endpointPort: testCase.nilPort ? nil : 51820,
                publicKey: testCase.nilPublicKey ? nil : validPublicKey,
                allowedNetworkV4: testCase.nilV4 ? nil : "10.0.1.0/24",
                allowedNetworkV6: testCase.nilV6 ? nil : "fd42:42:42:1::/64"
            )
            if testCase.nilPublicKey { skipped.removeValue(forKey: "publicKey") }
            skipped["status"] = "skipped-incomplete"
            skipped["reasonCode"] = testCase.reasonCode
            let docs: [String: CloudGatewayMeshDoc] = [
                "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true, peers: ["us-chicago-1": skipped]),
                "us-chicago-1": meshDoc("us-chicago-1", meshEnabled: true, peers: ["us-sanjose-1": skipped]),
            ]

            XCTAssertFalse(
                CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: docs)[0].pending,
                "reasonCode \(testCase.reasonCode) should not be pending"
            )
        }
    }

    func testDoesNotMarkAnInvalidEndpointPortAsPending() {
        let invalidPorts: [Int?] = [0, -1, 65536, nil]
        for wireguardPort in invalidPorts {
            func invalidRegion(_ regionId: String) -> CloudGatewayMeshRegion {
                makeRegion(regionId, meshEnabled: true, wireguardPort: wireguardPort)
            }
            let skipped: [String: Any] = [
                "status": "skipped-incomplete",
                "reasonCode": "invalid-endpoint-port",
                "endpointHostname": "wg.example.com",
                "publicKey": validPublicKey,
                "allowedNetworkV4": "10.0.1.0/24",
                "allowedNetworkV6": "fd42:42:42:1::/64",
            ]
            let regions = [invalidRegion("us-sanjose-1"), invalidRegion("us-chicago-1")]
            let docs: [String: CloudGatewayMeshDoc] = [
                "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true, peers: ["us-chicago-1": skipped]),
                "us-chicago-1": meshDoc("us-chicago-1", meshEnabled: true, peers: ["us-sanjose-1": skipped]),
            ]

            XCTAssertFalse(
                CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: docs)[0].pending,
                "port \(String(describing: wireguardPort)) should not be pending"
            )
        }
    }

    func testMarksARepairedValidEndpointPortPendingUntilSyncApplies() {
        let regions = [makeRegion("us-sanjose-1", meshEnabled: true), makeRegion("us-chicago-1", meshEnabled: true)]
        var invalidPort = peerData(endpointPort: 0)
        invalidPort["status"] = "skipped-incomplete"
        invalidPort["reasonCode"] = "invalid-endpoint-port"
        let pendingDocs: [String: CloudGatewayMeshDoc] = [
            "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true, peers: ["us-chicago-1": invalidPort]),
            "us-chicago-1": meshDoc("us-chicago-1", meshEnabled: true, peers: ["us-sanjose-1": peerData()]),
        ]
        XCTAssertTrue(CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: pendingDocs)[0].pending)

        let syncedDocs: [String: CloudGatewayMeshDoc] = [
            "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true, peers: ["us-chicago-1": peerData()]),
            "us-chicago-1": meshDoc("us-chicago-1", meshEnabled: true, peers: ["us-sanjose-1": peerData()]),
        ]
        XCTAssertFalse(CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: syncedDocs)[0].pending)
    }

    func testMarksOneSidedCurrentApplicationPendingWhenBothRegionsAreEnabled() {
        let regions = [makeRegion("us-sanjose-1", meshEnabled: true), makeRegion("us-chicago-1", meshEnabled: true)]
        let docs: [String: CloudGatewayMeshDoc] = [
            "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true, peers: ["us-chicago-1": peerData()]),
            "us-chicago-1": meshDoc("us-chicago-1", meshEnabled: true),
        ]
        let row = CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: docs)[0]

        XCTAssertEqual(row.status, .oneSided)
        XCTAssertTrue(row.pending)
    }

    func testMarksALinkBothAppliedWhenEachSideRecordedTheOtherAsApplied() {
        let regions = [makeRegion("us-sanjose-1", meshEnabled: true), makeRegion("us-chicago-1", meshEnabled: true)]
        let docs: [String: CloudGatewayMeshDoc] = [
            "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true, peers: ["us-chicago-1": peerData()]),
            "us-chicago-1": meshDoc("us-chicago-1", meshEnabled: true, peers: ["us-sanjose-1": peerData()]),
        ]
        let rows = CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: docs)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].regionAId, "us-sanjose-1")
        XCTAssertEqual(rows[0].regionBId, "us-chicago-1")
        XCTAssertEqual(rows[0].status, .bothApplied)
        XCTAssertFalse(rows[0].pending)
    }

    func testMarksALinkOneSidedWhenOnlyOneSideAppliedWithoutErroringTheWholeLink() {
        let regions = [makeRegion("us-sanjose-1", meshEnabled: true), makeRegion("us-dallas-1", meshEnabled: true)]
        let docs: [String: CloudGatewayMeshDoc] = [
            "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true, peers: ["us-dallas-1": peerData()]),
        ]
        let rows = CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: docs)

        XCTAssertEqual(rows[0].status, .oneSided)
        XCTAssertEqual(rows[0].aToB, .applied)
        XCTAssertNil(rows[0].bToA)
        // us-dallas-1 wants in but has never synced - the region itself is
        // pending, which makes the link pending too.
        XCTAssertTrue(rows[0].pending)
    }

    func testMarksALinkNotSyncedWhenNeitherSideHasAnAppliedEntry() {
        let regions = [makeRegion("us-sanjose-1", meshEnabled: false, enabled: true), makeRegion("us-chicago-1", meshEnabled: false, enabled: true)]
        let rows = CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: [:])

        XCTAssertEqual(rows[0].status, .notSynced)
        XCTAssertFalse(rows[0].pending)
    }

    func testIsPendingWhenBothSidesEnabledButAPeerEntryIsAbsent() {
        let regions = [makeRegion("us-sanjose-1", meshEnabled: true), makeRegion("us-chicago-1", meshEnabled: true)]
        // Both regions already report meshEnabled true (not region-pending), but
        // San Jose's doc has no entry for Chicago yet.
        let docs: [String: CloudGatewayMeshDoc] = [
            "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true),
            "us-chicago-1": meshDoc("us-chicago-1", meshEnabled: true, peers: ["us-sanjose-1": peerData()]),
        ]

        XCTAssertTrue(CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: docs)[0].pending)
    }

    func testKeepsAnUnchangedSkippedDirectionVisibleWithoutMarkingItPending() {
        let regions = [makeRegion("us-sanjose-1", meshEnabled: true), makeRegion("us-chicago-1", meshEnabled: true)]
        var skippedOverlap = peerData()
        skippedOverlap["status"] = "skipped-overlap"
        let docs: [String: CloudGatewayMeshDoc] = [
            "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true, peers: ["us-chicago-1": skippedOverlap]),
            "us-chicago-1": meshDoc("us-chicago-1", meshEnabled: true, peers: ["us-sanjose-1": peerData()]),
        ]
        let rows = CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: docs)

        XCTAssertEqual(rows[0].status, .oneSided)
        XCTAssertFalse(rows[0].pending)
    }

    func testBuildsOneRowPerPairForMoreThanTwoRegions() {
        let regions = [
            makeRegion("a", meshEnabled: false, enabled: false),
            makeRegion("b", meshEnabled: false, enabled: false),
            makeRegion("c", meshEnabled: false, enabled: false),
        ]
        let rows = CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: [:])

        XCTAssertEqual(rows.map { "\($0.regionAId)-\($0.regionBId)" }, ["a-b", "a-c", "b-c"])
    }

    func testMarksALiveHostsPeerForADisabledRegionAsPendingRemoval() {
        let regions = [
            makeRegion("us-sanjose-1", meshEnabled: true),
            makeRegion("us-chicago-1", meshEnabled: true, enabled: false),
        ]
        let docs: [String: CloudGatewayMeshDoc] = [
            "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true, peers: ["us-chicago-1": peerData()]),
        ]
        let row = CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: docs)[0]

        XCTAssertTrue(row.pending)
        XCTAssertEqual(row.status, .oneSided)
    }

    func testDoesNotMarkADeadHostsOwnStalePeerAsPending() {
        // Only a live host runs a sync pass, so nothing can reconcile an entry
        // that lives in a disabled region's own Mesh doc.
        let regions = [
            makeRegion("us-sanjose-1", meshEnabled: true, enabled: false),
            makeRegion("us-chicago-1", meshEnabled: true, enabled: false),
        ]
        let docs: [String: CloudGatewayMeshDoc] = [
            "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true, peers: ["us-chicago-1": peerData()]),
        ]

        XCTAssertFalse(CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: docs)[0].pending)
    }

    // MARK: - hasAnyMeshPending

    func testHasAnyMeshPendingIsTrueWhenALoneEnabledRegionHasNeverSynced() {
        XCTAssertTrue(CloudGatewayMeshStatus.hasAnyMeshPending(regions: [makeRegion("us-sanjose-1", meshEnabled: true)], meshDocs: [:]))
    }

    func testHasAnyMeshPendingIsFalseWhenNothingIsPending() {
        XCTAssertFalse(CloudGatewayMeshStatus.hasAnyMeshPending(regions: [makeRegion("us-sanjose-1", meshEnabled: false)], meshDocs: [:]))
    }

    // MARK: - collectMeshWarnings

    func testCollectsSkippedOverlapAndSkippedIncompleteEntriesNotAppliedOnes() {
        var skippedOverlap = peerData()
        skippedOverlap["status"] = "skipped-overlap"
        var skippedIncomplete = peerData()
        skippedIncomplete["status"] = "skipped-incomplete"
        let docs: [String: CloudGatewayMeshDoc] = [
            "us-sanjose-1": meshDoc("us-sanjose-1", meshEnabled: true, peers: [
                "us-chicago-1": peerData(),
                "us-dallas-1": skippedOverlap,
            ]),
            "us-chicago-1": meshDoc("us-chicago-1", meshEnabled: true, peers: ["us-dallas-1": skippedIncomplete]),
        ]
        let warnings = CloudGatewayMeshStatus.collectMeshWarnings(docs)

        XCTAssertEqual(warnings.count, 2)
        XCTAssertTrue(warnings.contains { $0.regionId == "us-sanjose-1" && $0.peerRegionId == "us-dallas-1" && $0.status == .skippedOverlap })
        XCTAssertTrue(warnings.contains { $0.regionId == "us-chicago-1" && $0.peerRegionId == "us-dallas-1" && $0.status == .skippedIncomplete })
    }

    func testPreservesDiagnosticReasonCodesInWarnings() {
        let doc = CloudGatewayFirestoreMeshMapper.meshDoc(documentId: "us-sanjose-1", data: [
            "meshEnabled": true,
            "peers": ["us-chicago-1": ["status": "skipped-incomplete", "reasonCode": "duplicate-public-key"]],
        ])

        XCTAssertEqual(CloudGatewayMeshStatus.collectMeshWarnings(["us-sanjose-1": doc])[0].reasonCode, "duplicate-public-key")
    }

    func testWarningsCarryTheRecordingHostsAppliedAtTimestamp() {
        let recordedAt = Date(timeIntervalSince1970: 1_767_225_600)
        var overlap = peerData(appliedAt: recordedAt)
        overlap["status"] = "skipped-overlap"
        let doc = CloudGatewayFirestoreMeshMapper.meshDoc(
            documentId: "us-sanjose-1",
            data: ["peers": ["us-dallas-1": overlap]]
        )

        let warnings = CloudGatewayMeshStatus.collectMeshWarnings(["us-sanjose-1": doc])

        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings[0].appliedAt, recordedAt)
    }

    func testCollectMeshWarningsIsSortedByRegionThenPeerRegionForDeterminism() {
        var overlap = peerData()
        overlap["status"] = "skipped-overlap"
        let docs: [String: CloudGatewayMeshDoc] = [
            "z-region": meshDoc("z-region", meshEnabled: true, peers: ["b-peer": overlap, "a-peer": overlap]),
            "a-region": meshDoc("a-region", meshEnabled: true, peers: ["z-peer": overlap]),
        ]
        let ids = CloudGatewayMeshStatus.collectMeshWarnings(docs).map(\.id)

        XCTAssertEqual(ids, ["a-region-z-peer", "z-region-a-peer", "z-region-b-peer"])
    }

    // MARK: - getMeshStaleness

    func testStalenessIsUnknownWhenThereIsNoUpdatedAt() {
        XCTAssertEqual(CloudGatewayMeshStatus.meshStaleness(updatedAt: nil), .unknown)
    }

    func testStalenessIsFreshWithinTheThresholdAndStaleBeyondIt() {
        let now = Date(timeIntervalSince1970: 1_767_312_000)
        let justInside = now.addingTimeInterval(-CloudGatewayMeshStatus.meshStaleThreshold + 1000)
        let justOutside = now.addingTimeInterval(-CloudGatewayMeshStatus.meshStaleThreshold - 1000)

        XCTAssertEqual(CloudGatewayMeshStatus.meshStaleness(updatedAt: justInside, now: now), .fresh)
        XCTAssertEqual(CloudGatewayMeshStatus.meshStaleness(updatedAt: justOutside, now: now), .stale)
    }

    // MARK: - CloudGatewayFirestoreMeshMapper: meshRegion

    func testMeshRegionIsNilWhenDisplayNameIsMissing() {
        XCTAssertNil(CloudGatewayFirestoreMeshMapper.meshRegion(documentId: "us-sanjose-1", data: [:]))
    }

    func testMeshRegionDisplayOrderDefaultsTo1000() {
        let region = CloudGatewayFirestoreMeshMapper.meshRegion(documentId: "us-sanjose-1", data: ["displayName": "San Jose"])
        XCTAssertEqual(region?.displayOrder, 1000)
    }

    func testMeshRegionParsesANumericStringDisplayOrder() {
        let region = CloudGatewayFirestoreMeshMapper.meshRegion(documentId: "us-sanjose-1", data: ["displayName": "San Jose", "displayOrder": "42"])
        XCTAssertEqual(region?.displayOrder, 42)
    }

    func testMeshRegionPreservesAnUntrimmedStringField() {
        let region = CloudGatewayFirestoreMeshMapper.meshRegion(
            documentId: "us-sanjose-1",
            data: ["displayName": " San Jose ", "wireguardEndpointHostname": " wg.example.com "]
        )
        XCTAssertEqual(region?.displayName, " San Jose ")
        XCTAssertEqual(region?.wireguardEndpointHostname, " wg.example.com ")
    }

    // `Int(_: Double)` traps rather than returning nil, so an out-of-range number
    // has to be rejected before the conversion or a corrupt doc crashes the app.
    func testMeshRegionFallsBackInsteadOfTrappingOnOutOfRangeNumbers() {
        let region = CloudGatewayFirestoreMeshMapper.meshRegion(
            documentId: "us-sanjose-1",
            data: ["displayName": "San Jose", "displayOrder": 1e30, "wireguardPort": 1e30]
        )
        XCTAssertEqual(region?.displayOrder, 1000)
        XCTAssertNil(region?.wireguardPort)

        let infinite = CloudGatewayFirestoreMeshMapper.meshRegion(
            documentId: "us-sanjose-1",
            data: ["displayName": "San Jose", "displayOrder": Double.infinity]
        )
        XCTAssertEqual(infinite?.displayOrder, 1000)
    }

    func testMeshRegionRejectsANonIntegralWireguardPort() {
        let region = CloudGatewayFirestoreMeshMapper.meshRegion(
            documentId: "us-sanjose-1",
            data: ["displayName": "San Jose", "wireguardPort": 51820.5]
        )
        XCTAssertNil(region?.wireguardPort)
    }

    func testMeshRegionAcceptsAValidIntegerWireguardPort() {
        let region = CloudGatewayFirestoreMeshMapper.meshRegion(
            documentId: "us-sanjose-1",
            data: ["displayName": "San Jose", "wireguardPort": 51820]
        )
        XCTAssertEqual(region?.wireguardPort, 51820)
    }

    func testMeshRegionEnabledRejectsANonBooleanNumericOne() {
        // Firestore integer 1 must not be coerced to `enabled == true`.
        let region = CloudGatewayFirestoreMeshMapper.meshRegion(
            documentId: "us-sanjose-1",
            data: ["displayName": "San Jose", "enabled": 1]
        )
        XCTAssertFalse(region?.enabled ?? true)
    }

    // MARK: - CloudGatewayFirestoreMeshMapper: meshDoc

    func testMeshDocWithOneValidAndOneUnparseablePeerEntry() {
        let doc = CloudGatewayFirestoreMeshMapper.meshDoc(documentId: "us-sanjose-1", data: [
            "peers": [
                "us-chicago-1": peerData(),
                "us-dallas-1": ["status": "not-a-real-status"],
            ],
        ])

        XCTAssertEqual(Array(doc.peers.keys), ["us-chicago-1"])
    }

    func testMeshDocSkippedIncompleteEntryWithBlankFieldsSurvives() {
        let doc = CloudGatewayFirestoreMeshMapper.meshDoc(documentId: "us-sanjose-1", data: [
            "peers": ["us-chicago-1": ["status": "skipped-incomplete"]],
        ])

        XCTAssertNotNil(doc.peers["us-chicago-1"])
        XCTAssertEqual(doc.peers["us-chicago-1"]?.status, .skippedIncomplete)
        XCTAssertNil(doc.peers["us-chicago-1"]?.reasonCode)
    }
}
