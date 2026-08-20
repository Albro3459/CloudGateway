@testable import CloudGatewayAppCore
import XCTest

// Admin gating (redirecting non-admins / signed-out users away from the page)
// lives in the iOS view layer (ContentView dismisses the cover when the role
// stops being admin), not in this view model - see the iOS Server Health
// section in TODO/shared-subnet-mesh.md. What belongs here is the identity
// guard: an async step must not publish results for a user who is no longer
// current, which these tests cover directly (sign-out mid-toggle,
// mid-sync-fan-out).
@MainActor
final class CloudGatewayServerHealthViewModelTests: XCTestCase {
    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("waitUntil timed out", file: file, line: line)
    }

    private func region(
        _ id: String,
        enabled: Bool = true,
        meshEnabled: Bool = true,
        displayOrder: Int = 1
    ) -> CloudGatewayMeshRegion {
        CloudGatewayMeshRegion(
            regionId: id,
            displayName: id,
            enabled: enabled,
            displayOrder: displayOrder,
            meshEnabled: meshEnabled,
            wireguardPublicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            wireguardEndpointHostname: "wg.example.com",
            wireguardPort: 51820,
            tunnelNetworkV4: "10.0.1.0/24",
            tunnelNetworkV6: "fd42:42:42:1::/64"
        )
    }

    private func peer(
        status: CloudGatewayMeshPeerStatus = .applied,
        reasonCode: String? = nil
    ) -> CloudGatewayMeshPeerEntry {
        CloudGatewayMeshPeerEntry(
            endpointHostname: status == .skippedIncomplete ? nil : "wg.example.com",
            endpointPort: status == .skippedIncomplete ? nil : 51820,
            publicKey: status == .skippedIncomplete ? nil : "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            allowedNetworkV4: status == .skippedIncomplete ? nil : "10.0.1.0/24",
            allowedNetworkV6: status == .skippedIncomplete ? nil : "fd42:42:42:1::/64",
            status: status,
            reasonCode: reasonCode,
            appliedAt: nil
        )
    }

    private func policyDoc(
        _ regionId: String,
        mapHashV4: String? = "hash-v4",
        mapHashV6: String? = "hash-v6",
        rowCount: Int? = 10,
        updatedAt: Date? = Date()
    ) -> CloudGatewayPolicyDoc {
        CloudGatewayPolicyDoc(
            regionId: regionId, mapHashV4: mapHashV4, mapHashV6: mapHashV6, rowCount: rowCount, updatedAt: updatedAt
        )
    }

    private func signedInService() -> MockGatewayService {
        let service = MockGatewayService()
        service.currentUser = AuthenticatedUser(uid: "admin-1", email: "admin@example.com")
        return service
    }

    // MARK: - Load

    func testLoadPopulatesRegionsAndRecomputesDerivedStateOnce() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1"), region("us-chicago-1")]
        service.meshDocs = [
            "us-sanjose-1": CloudGatewayMeshDoc(
                regionId: "us-sanjose-1", meshEnabled: true, updatedAt: nil,
                peers: ["us-chicago-1": peer()]
            ),
        ]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)

        await viewModel.load()

        XCTAssertTrue(viewModel.dataAvailable)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.bannerText)
        XCTAssertEqual(viewModel.regions.map(\.regionId), ["us-sanjose-1", "us-chicago-1"])
        XCTAssertEqual(viewModel.linkRows.count, 1)
        XCTAssertEqual(viewModel.linkRows.first?.status, .oneSided)
    }

    func testDerivedStateReflectsWarningsAndPendingFromLoadedMeshDocs() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1"), region("us-chicago-1")]
        service.meshDocs = [
            "us-sanjose-1": CloudGatewayMeshDoc(
                regionId: "us-sanjose-1", meshEnabled: true, updatedAt: nil,
                peers: ["us-chicago-1": peer(status: .skippedIncomplete, reasonCode: "missing-public-key")]
            ),
        ]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)

        await viewModel.load()

        XCTAssertEqual(viewModel.warnings.count, 1)
        XCTAssertEqual(viewModel.warnings.first?.reasonCode, "missing-public-key")
        XCTAssertTrue(viewModel.anyPending)
    }

    func testLoadFailureSetsBannerWithoutWipingExistingData() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1")]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        XCTAssertEqual(viewModel.regions.count, 1)

        service.fetchMeshRegionsError = URLError(.notConnectedToInternet)
        await viewModel.load()

        XCTAssertEqual(viewModel.bannerText, "Unable to load server health data.")
        XCTAssertEqual(viewModel.regions.count, 1)
        XCTAssertTrue(viewModel.dataAvailable)
    }

    // A slow load (A) can resolve after a toggle's own post-success reload
    // (B) has already applied newer state. Once the toggle clears,
    // togglingRegionIds.isEmpty passes for A too, so only the generation
    // counter - not the toggling guard - stops A from clobbering B.
    func testStaleLoadDoesNotClobberNewerToggleReload() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1", meshEnabled: false), region("us-chicago-1", meshEnabled: false)]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        let target = viewModel.regions[0]

        let regionsGateA = AsyncTestGate()
        service.fetchMeshRegionsGate = regionsGateA
        let loadA = Task { await viewModel.load() }
        await waitUntil { service.fetchMeshRegionsCallCount == 2 }

        // Load A is now blocked mid-fetch, having already captured
        // pre-toggle state. Unblock future fetchMeshRegions calls so the
        // toggle's own reload (load B) can run to completion ahead of A.
        service.fetchMeshRegionsGate = nil
        await viewModel.toggleMesh(region: target)
        XCTAssertEqual(viewModel.regions.first?.meshEnabled, true)

        await regionsGateA.open()
        await loadA.value

        // A resolved last but is stale; it must not overwrite B's newer state.
        XCTAssertEqual(viewModel.regions.first?.meshEnabled, true)
    }

    // MARK: - Policy

    func testLoadPopulatesPolicyRowsWithExpectedStatesAndLeavesPolicyLoadFailedFalse() async {
        let service = signedInService()
        service.meshRegions = [
            region("us-sanjose-1"),
            region("us-chicago-1"),
            region("us-austin-1"),
            region("us-portland-1", enabled: false),
        ]
        service.policyDocs = [
            "us-sanjose-1": policyDoc("us-sanjose-1", mapHashV4: "hash-v4", mapHashV6: "hash-v6"),
            "us-chicago-1": policyDoc("us-chicago-1", mapHashV4: "hash-v4", mapHashV6: "hash-v6"),
            "us-austin-1": policyDoc("us-austin-1", mapHashV4: "different-v4", mapHashV6: "hash-v6"),
            "us-portland-1": policyDoc("us-portland-1", mapHashV4: "hash-v4", mapHashV6: "hash-v6"),
        ]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)

        await viewModel.load()

        XCTAssertFalse(viewModel.policyLoadFailed)
        XCTAssertEqual(viewModel.policyRows.count, 4)
        XCTAssertEqual(viewModel.policyRows.first { $0.regionId == "us-sanjose-1" }?.state, .ok)
        XCTAssertEqual(viewModel.policyRows.first { $0.regionId == "us-chicago-1" }?.state, .ok)
        let austin = viewModel.policyRows.first { $0.regionId == "us-austin-1" }
        XCTAssertEqual(austin?.state, .drifted)
        XCTAssertEqual(austin?.driftedV4, true)
        XCTAssertEqual(austin?.driftedV6, false)
        XCTAssertEqual(viewModel.policyRows.first { $0.regionId == "us-portland-1" }?.state, .disabled)
    }

    // A Policy read failure must not blank the fresh Regions/Mesh state, and must not
    // manufacture a `neverSynced` row for every region out of the empty map a failure
    // leaves behind - that would assert a fleet state we don't actually know.
    func testPolicyFetchFailureAppliesFreshMeshStateAndLeavesPolicyRowsEmpty() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1"), region("us-chicago-1")]
        service.meshDocs = [
            "us-sanjose-1": CloudGatewayMeshDoc(
                regionId: "us-sanjose-1", meshEnabled: true, updatedAt: nil,
                peers: ["us-chicago-1": peer()]
            ),
        ]
        service.fetchPolicyDocsError = URLError(.notConnectedToInternet)
        let viewModel = CloudGatewayServerHealthViewModel(service: service)

        await viewModel.load()

        XCTAssertEqual(viewModel.regions.map(\.regionId), ["us-sanjose-1", "us-chicago-1"])
        XCTAssertEqual(viewModel.linkRows.count, 1)
        XCTAssertTrue(viewModel.dataAvailable)
        XCTAssertNil(viewModel.bannerText)

        XCTAssertTrue(viewModel.policyLoadFailed)
        XCTAssertTrue(viewModel.policyRows.isEmpty)
    }

    func testPolicyLoadFailedClearsOnASubsequentSuccessfulLoad() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1")]
        service.fetchPolicyDocsError = URLError(.notConnectedToInternet)
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        XCTAssertTrue(viewModel.policyLoadFailed)
        XCTAssertTrue(viewModel.policyRows.isEmpty)

        service.fetchPolicyDocsError = nil
        service.policyDocs = ["us-sanjose-1": policyDoc("us-sanjose-1")]
        await viewModel.load()

        XCTAssertFalse(viewModel.policyLoadFailed)
        XCTAssertEqual(viewModel.policyRows.count, 1)
        XCTAssertEqual(viewModel.policyRows.first?.state, .ok)
    }

    // The pre-existing Regions/Mesh all-or-nothing behavior is unchanged: a Regions
    // failure keeps the existing page-level error and must not apply a Policy result
    // that happened to succeed in the same concurrent fetch.
    func testRegionsFailureKeepsPageLevelErrorAndDoesNotApplyASeparatelySucceededPolicyResult() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1")]
        service.policyDocs = ["us-sanjose-1": policyDoc("us-sanjose-1")]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        XCTAssertFalse(viewModel.policyRows.isEmpty)

        service.fetchMeshRegionsError = URLError(.notConnectedToInternet)
        service.policyDocs = ["us-sanjose-1": policyDoc("us-sanjose-1", mapHashV4: "should-not-apply")]
        await viewModel.load()

        XCTAssertEqual(viewModel.bannerText, "Unable to load server health data.")
        XCTAssertNotEqual(viewModel.policyRows.first?.doc?.mapHashV4, "should-not-apply")
        XCTAssertFalse(viewModel.policyLoadFailed)
    }

    func testSyncAllRereadsPolicyAfterTheFanOut() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1")]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        let callCountBeforeSync = service.fetchPolicyDocsCallCount

        await viewModel.syncAll()

        XCTAssertGreaterThan(service.fetchPolicyDocsCallCount, callCountBeforeSync)
    }

    func testSyncAllPolicyReReadFailureStillAppliesFreshRegionsMeshAndFlipsPolicyLoadFailed() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1")]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()

        service.meshDocs = [
            "us-sanjose-1": CloudGatewayMeshDoc(regionId: "us-sanjose-1", meshEnabled: true, updatedAt: nil, peers: [:]),
        ]
        service.fetchPolicyDocsError = URLError(.notConnectedToInternet)

        await viewModel.syncAll()

        XCTAssertTrue(viewModel.policyLoadFailed)
        XCTAssertTrue(viewModel.policyRows.isEmpty)
        XCTAssertNotNil(viewModel.meshDoc(for: "us-sanjose-1"))
    }

    // A slow load (A) can resolve after a newer load (B) has already applied fresher
    // policy state; only the generation counter stops A's stale Policy result from
    // clobbering B's, mirroring testStaleLoadDoesNotClobberNewerToggleReload for mesh.
    func testStalePolicyResultIsDroppedWhenANewerLoadCompletesFirst() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1")]
        service.policyDocs = ["us-sanjose-1": policyDoc("us-sanjose-1", mapHashV4: "v4-old")]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        XCTAssertEqual(viewModel.policyRows.first?.doc?.mapHashV4, "v4-old")

        let policyGateA = AsyncTestGate()
        service.fetchPolicyDocsGate = policyGateA
        let loadA = Task { await viewModel.load() }
        await waitUntil { service.fetchPolicyDocsCallCount == 2 }

        // Load A is now blocked mid-fetch. Unblock future fetchPolicyDocs calls and
        // update the backing data so a newer load (B) can run to completion ahead of A.
        service.fetchPolicyDocsGate = nil
        service.policyDocs = ["us-sanjose-1": policyDoc("us-sanjose-1", mapHashV4: "v4-new")]
        await viewModel.load()
        XCTAssertEqual(viewModel.policyRows.first?.doc?.mapHashV4, "v4-new")

        await policyGateA.open()
        await loadA.value

        // A resolved last but is stale; it must not overwrite B's newer state.
        XCTAssertEqual(viewModel.policyRows.first?.doc?.mapHashV4, "v4-new")
    }

    // A uid mismatch drops the whole combined apply(), including the Policy result,
    // exactly like it drops the Regions/Mesh result.
    func testUidMismatchDuringLoadDropsPolicyResultLikeMeshResult() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1")]
        service.policyDocs = ["us-sanjose-1": policyDoc("us-sanjose-1")]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        XCTAssertFalse(viewModel.policyRows.isEmpty)

        let policyGate = AsyncTestGate()
        service.fetchPolicyDocsGate = policyGate
        service.policyDocs = ["us-sanjose-1": policyDoc("us-sanjose-1", mapHashV4: "changed")]
        let load = Task { await viewModel.load() }
        await waitUntil { service.fetchPolicyDocsCallCount == 2 }

        service.currentUser = AuthenticatedUser(uid: "admin-2", email: "other@example.com")
        await policyGate.open()
        await load.value

        XCTAssertNotEqual(viewModel.policyRows.first?.doc?.mapHashV4, "changed")
    }

    // MARK: - Toggle

    func testToggleRollsBackLocalValueOnWriteFailureAndBannersTheRegion() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1", meshEnabled: false)]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        let target = viewModel.regions[0]

        service.setRegionMeshEnabledError = CloudGatewayAppError.accessDenied("nope")
        await viewModel.toggleMesh(region: target)

        XCTAssertEqual(viewModel.regions.first?.meshEnabled, false)
        XCTAssertEqual(viewModel.bannerText, "Unable to update us-sanjose-1.")
        XCTAssertTrue(viewModel.togglingRegionIds.isEmpty)
    }

    func testToggleIsNoOpForDisabledRegion() async {
        let service = signedInService()
        service.meshRegions = [region("us-chicago-1", enabled: false, meshEnabled: true)]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        let target = viewModel.regions[0]

        XCTAssertFalse(viewModel.canToggleMesh(target))
        await viewModel.toggleMesh(region: target)

        XCTAssertEqual(service.setRegionMeshEnabledCallCount, 0)
        XCTAssertEqual(viewModel.regions.first?.meshEnabled, true)
    }

    func testSecondToggleForSameRegionWhileInFlightIsNoOp() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1", meshEnabled: false)]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        let target = viewModel.regions[0]

        let writeGate = AsyncTestGate()
        service.setRegionMeshEnabledGate = writeGate
        let firstToggle = Task { await viewModel.toggleMesh(region: target) }
        await waitUntil { service.setRegionMeshEnabledCallCount == 1 }

        await viewModel.toggleMesh(region: target)
        XCTAssertEqual(service.setRegionMeshEnabledCallCount, 1)

        await writeGate.open()
        await firstToggle.value
    }

    // A load's results are dropped while a toggle for that region is in
    // flight, so a stale/background refresh can never clobber the optimistic
    // value; a reload is issued once the toggle completes to catch up.
    func testLoadLandingMidToggleDoesNotClobberOptimisticValue() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1", meshEnabled: false), region("us-chicago-1", meshEnabled: false)]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        let target = viewModel.regions[0]

        let writeGate = AsyncTestGate()
        service.setRegionMeshEnabledGate = writeGate
        let toggle = Task { await viewModel.toggleMesh(region: target) }
        await waitUntil { service.setRegionMeshEnabledCallCount == 1 }
        XCTAssertEqual(viewModel.regions.first?.meshEnabled, true)
        XCTAssertTrue(viewModel.togglingRegionIds.contains("us-sanjose-1"))

        // A refresh lands while the write is still in flight; its own fetch
        // reflects the pre-toggle backend state, but must not be applied.
        await viewModel.load()
        XCTAssertEqual(viewModel.regions.first?.meshEnabled, true)

        await writeGate.open()
        await toggle.value

        // The toggle's own post-success reload picks up the now-current state.
        XCTAssertEqual(viewModel.regions.first?.meshEnabled, true)
        XCTAssertTrue(viewModel.togglingRegionIds.isEmpty)
    }

    // Same drop-and-catch-up guarantee, but the toggle fails: the dropped
    // load's data must still surface once the (failed) toggle finishes.
    func testDroppedLoadCatchesUpAfterFailedToggle() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1", meshEnabled: false), region("us-chicago-1", meshEnabled: false)]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        let target = viewModel.regions[0]

        let writeGate = AsyncTestGate()
        service.setRegionMeshEnabledGate = writeGate
        service.setRegionMeshEnabledError = CloudGatewayAppError.accessDenied("nope")
        let toggle = Task { await viewModel.toggleMesh(region: target) }
        await waitUntil { service.setRegionMeshEnabledCallCount == 1 }

        // Chicago becomes enabled server-side while San Jose's toggle is
        // in flight; the dropped load should surface it once the toggle -
        // even a failing one - finishes.
        service.meshRegions[1] = region("us-chicago-1", meshEnabled: true)
        await viewModel.load()
        XCTAssertEqual(viewModel.regions.first { $0.regionId == "us-chicago-1" }?.meshEnabled, false)

        await writeGate.open()
        await toggle.value

        XCTAssertEqual(viewModel.regions.first { $0.regionId == "us-sanjose-1" }?.meshEnabled, false)
        XCTAssertEqual(viewModel.regions.first { $0.regionId == "us-chicago-1" }?.meshEnabled, true)
        XCTAssertEqual(viewModel.bannerText, "Unable to update us-sanjose-1.")
    }

    func testSignOutDuringToggleDropsResultAndClearsTogglingState() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1", meshEnabled: false)]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        let target = viewModel.regions[0]

        let writeGate = AsyncTestGate()
        service.setRegionMeshEnabledGate = writeGate
        let toggle = Task { await viewModel.toggleMesh(region: target) }
        await waitUntil { service.setRegionMeshEnabledCallCount == 1 }

        service.currentUser = nil
        await writeGate.open()
        await toggle.value

        XCTAssertTrue(viewModel.togglingRegionIds.isEmpty)
        XCTAssertNil(viewModel.bannerText)
    }

    // Both uid-mismatch early returns used to bail out of toggleMesh before
    // reaching the reloadPendingAfterToggle bookkeeping, so a load dropped
    // while this toggle was in flight would leak the flag and its catch-up
    // reload was silently lost forever. The bookkeeping - and the reload it
    // triggers - must still run when the toggle itself resolves for a user
    // who is no longer current.
    func testDroppedLoadCatchesUpAfterToggleResolvesWithUidMismatch() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1", meshEnabled: false), region("us-chicago-1", meshEnabled: false)]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        let target = viewModel.regions[0]

        let writeGate = AsyncTestGate()
        service.setRegionMeshEnabledGate = writeGate
        let toggle = Task { await viewModel.toggleMesh(region: target) }
        await waitUntil { service.setRegionMeshEnabledCallCount == 1 }

        // Dropped because the toggle is still in flight - this is what sets
        // reloadPendingAfterToggle.
        await viewModel.load()

        // The toggle resolves for a different signed-in user, and chicago
        // flips server-side in the meantime.
        service.currentUser = AuthenticatedUser(uid: "admin-2", email: "other@example.com")
        service.meshRegions[1] = region("us-chicago-1", meshEnabled: true)
        await writeGate.open()
        await toggle.value

        // The pending flag was consumed rather than leaked, and its catch-up
        // reload actually ran: chicago's new state surfaces instead of
        // staying silently stale.
        XCTAssertTrue(viewModel.togglingRegionIds.isEmpty)
        XCTAssertEqual(viewModel.regions.first { $0.regionId == "us-chicago-1" }?.meshEnabled, true)
        XCTAssertNil(viewModel.bannerText)
    }

    // MARK: - Sync All

    func testSyncAllReportsPerRegionOutcomesAndRereadsMeshDocsAfterward() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1"), region("us-chicago-1")]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()

        service.syncRegionsOutcomes = [
            "us-chicago-1": .failure(message: "Unable to reach us-chicago-1.", requestId: "req-1", isIncompatibleResponse: false),
        ]
        service.meshDocs = [
            "us-sanjose-1": CloudGatewayMeshDoc(
                regionId: "us-sanjose-1", meshEnabled: true, updatedAt: nil,
                peers: ["us-chicago-1": peer()]
            ),
        ]

        await viewModel.syncAll()

        XCTAssertEqual(service.syncRegionsRegionIds, ["us-sanjose-1", "us-chicago-1"])
        // One token is fetched immediately before the fan-out and reused across it.
        XCTAssertEqual(service.syncRegionsIdToken, "test-token")
        XCTAssertEqual(service.idTokenForceRefreshValues.count, 1)
        XCTAssertEqual(viewModel.syncResults?.count, 2)

        guard case .failure(let message, _, _) = viewModel.syncResults?.first(where: { $0.regionId == "us-chicago-1" })?.result else {
            return XCTFail("expected a failure outcome for us-chicago-1")
        }
        XCTAssertEqual(message, "Unable to reach us-chicago-1.")

        guard case .success = viewModel.syncResults?.first(where: { $0.regionId == "us-sanjose-1" })?.result else {
            return XCTFail("expected a success outcome for us-sanjose-1")
        }

        // The fan-out response is ephemeral; the durable Mesh/* re-read is
        // what the link rows must reflect.
        XCTAssertEqual(service.fetchMeshDocsCallCount, 2)
        XCTAssertNotNil(viewModel.meshDoc(for: "us-sanjose-1"))
        XCTAssertFalse(viewModel.isSyncing)
    }

    func testSyncAllRendersAlreadyRunningOutcomeDistinctFromFailure() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1")]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()

        service.syncRegionsOutcomes = ["us-sanjose-1": .alreadyRunning]

        await viewModel.syncAll()

        guard case .alreadyRunning = viewModel.syncResults?.first(where: { $0.regionId == "us-sanjose-1" })?.result else {
            return XCTFail("expected .alreadyRunning for us-sanjose-1")
        }
    }

    func testSyncAllOnlyTargetsEnabledRegions() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1", enabled: true), region("us-chicago-1", enabled: false)]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()

        await viewModel.syncAll()

        XCTAssertEqual(service.syncRegionsRegionIds, ["us-sanjose-1"])
    }

    func testSignOutDuringSyncAllFanOutDropsResults() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1")]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()

        let syncGate = AsyncTestGate()
        service.syncRegionsGate = syncGate
        let sync = Task { await viewModel.syncAll() }
        await waitUntil { viewModel.isSyncing }

        service.currentUser = nil
        await syncGate.open()
        await sync.value

        XCTAssertNil(viewModel.syncResults)
        XCTAssertFalse(viewModel.isSyncing)
    }

    // MARK: - Session boundary

    // The view model is built once per app process and outlives every sign-in,
    // so nothing here may survive an identity change: the sync log alone
    // carries user emails, client names and IDs, public keys, and tunnel IPs.
    private func populatedViewModel(_ service: MockGatewayService) async -> CloudGatewayServerHealthViewModel {
        service.meshRegions = [region("us-sanjose-1"), region("us-chicago-1")]
        service.meshDocs = [
            "us-sanjose-1": CloudGatewayMeshDoc(
                regionId: "us-sanjose-1", meshEnabled: true, updatedAt: nil,
                peers: ["us-chicago-1": peer(status: .skippedIncomplete, reasonCode: "missing-public-key")]
            ),
        ]
        service.policyDocs = ["us-sanjose-1": policyDoc("us-sanjose-1")]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        await viewModel.syncAll()
        XCTAssertNotNil(viewModel.syncResults)
        XCTAssertTrue(viewModel.dataAvailable)
        XCTAssertFalse(viewModel.regions.isEmpty)
        XCTAssertFalse(viewModel.warnings.isEmpty)
        XCTAssertFalse(viewModel.policyRows.isEmpty)
        return viewModel
    }

    private func assertNoAccountScopedState(
        _ viewModel: CloudGatewayServerHealthViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(viewModel.syncResults, file: file, line: line)
        XCTAssertNil(viewModel.bannerText, file: file, line: line)
        XCTAssertFalse(viewModel.dataAvailable, file: file, line: line)
        XCTAssertTrue(viewModel.regions.isEmpty, file: file, line: line)
        XCTAssertTrue(viewModel.meshDocs.isEmpty, file: file, line: line)
        XCTAssertTrue(viewModel.linkRows.isEmpty, file: file, line: line)
        XCTAssertTrue(viewModel.warnings.isEmpty, file: file, line: line)
        XCTAssertFalse(viewModel.anyPending, file: file, line: line)
        XCTAssertTrue(viewModel.policyRows.isEmpty, file: file, line: line)
        XCTAssertFalse(viewModel.policyLoadFailed, file: file, line: line)
        XCTAssertTrue(viewModel.togglingRegionIds.isEmpty, file: file, line: line)
        XCTAssertFalse(viewModel.isLoading, file: file, line: line)
        XCTAssertFalse(viewModel.isSyncing, file: file, line: line)
    }

    func testSignOutClearsCompletedSyncResultsAndEveryOtherAccountScopedValue() async {
        let service = signedInService()
        let viewModel = await populatedViewModel(service)

        service.emitAuthState(nil)
        await waitUntil { !viewModel.dataAvailable }

        assertNoAccountScopedState(viewModel)
    }

    // A handoff between two admins never has to pass through a signed-out
    // state, so the A -> B transition needs its own coverage.
    func testDirectAccountSwapClearsPreviousAdminsData() async {
        let service = signedInService()
        let viewModel = await populatedViewModel(service)

        service.emitAuthState(AuthenticatedUser(uid: "admin-2", email: "other@example.com"))
        await waitUntil { !viewModel.dataAvailable }

        assertNoAccountScopedState(viewModel)
    }

    func testCompletedSyncFromThePreviousAdminIsNeverPublishedAfterASwap() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1")]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        let loadsBeforeSync = service.fetchMeshRegionsCallCount

        let syncGate = AsyncTestGate()
        service.syncRegionsGate = syncGate
        let sync = Task { await viewModel.syncAll() }
        await waitUntil { viewModel.isSyncing }

        service.emitAuthState(AuthenticatedUser(uid: "admin-2", email: "other@example.com"))
        await waitUntil { !viewModel.dataAvailable }
        await syncGate.open()
        await sync.value

        // Neither the fan-out result nor its post-sync re-read may land in the
        // new session.
        assertNoAccountScopedState(viewModel)
        XCTAssertEqual(service.fetchMeshRegionsCallCount, loadsBeforeSync)
    }

    func testInFlightLoadFromThePreviousAdminCannotRepopulateTheClearedPage() async {
        let service = signedInService()
        let viewModel = await populatedViewModel(service)

        let loadGate = AsyncTestGate()
        service.fetchMeshRegionsGate = loadGate
        let load = Task { await viewModel.load() }
        await waitUntil { viewModel.isLoading }

        service.emitAuthState(nil)
        await waitUntil { !viewModel.dataAvailable }
        await loadGate.open()
        await load.value

        assertNoAccountScopedState(viewModel)
    }

    func testStaleToggleDoesNotLaunchACatchUpLoadForTheNewSession() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1", meshEnabled: false), region("us-chicago-1", meshEnabled: false)]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        let target = viewModel.regions[0]

        let writeGate = AsyncTestGate()
        service.setRegionMeshEnabledGate = writeGate
        let toggle = Task { await viewModel.toggleMesh(region: target) }
        await waitUntil { service.setRegionMeshEnabledCallCount == 1 }

        // Dropped because the toggle is in flight, so a catch-up reload is
        // pending when the account changes.
        await viewModel.load()

        service.emitAuthState(AuthenticatedUser(uid: "admin-2", email: "other@example.com"))
        await waitUntil { !viewModel.dataAvailable }
        let loadsAfterSwap = service.fetchMeshRegionsCallCount

        await writeGate.open()
        await toggle.value

        // The pending flag was cleared with the rest of the session state, and
        // the toggle neither refetched nor republished anything.
        XCTAssertEqual(service.fetchMeshRegionsCallCount, loadsAfterSwap)
        assertNoAccountScopedState(viewModel)
    }

    // Firebase re-emits the current user on listener registration and on token
    // refresh; that is not an account boundary and must not wipe a live page.
    func testRepeatedAuthCallbackForTheSameUidLeavesTheLoadedPageIntact() async {
        let service = signedInService()
        let viewModel = await populatedViewModel(service)
        let syncResultCount = viewModel.syncResults?.count

        service.emitAuthState(AuthenticatedUser(uid: "admin-1", email: "admin@example.com"))
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertTrue(viewModel.dataAvailable)
        XCTAssertEqual(viewModel.regions.map(\.regionId), ["us-sanjose-1", "us-chicago-1"])
        XCTAssertEqual(viewModel.syncResults?.count, syncResultCount)
        XCTAssertFalse(viewModel.warnings.isEmpty)
        XCTAssertFalse(viewModel.policyRows.isEmpty)
    }

    // Losing the admin role keeps the same uid, so auth state reports no
    // boundary at all - the iOS view layer calls this directly when the role
    // stops being admin, and it must invalidate in-flight work too.
    func testAdminRoleLossClearsStateAndInvalidatesAnInFlightSync() async {
        let service = signedInService()
        let viewModel = await populatedViewModel(service)

        let syncGate = AsyncTestGate()
        service.syncRegionsGate = syncGate
        let sync = Task { await viewModel.syncAll() }
        await waitUntil { viewModel.isSyncing }

        viewModel.resetAccountScopedState()
        assertNoAccountScopedState(viewModel)

        await syncGate.open()
        await sync.value

        assertNoAccountScopedState(viewModel)
    }

    // The uid never changes here, so only the session generation can stop the
    // toggle's success path from refetching and repainting the cleared page.
    func testRoleLossDuringToggleDoesNotRepopulateTheClearedPage() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1", meshEnabled: false)]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        let target = viewModel.regions[0]

        let writeGate = AsyncTestGate()
        service.setRegionMeshEnabledGate = writeGate
        let toggle = Task { await viewModel.toggleMesh(region: target) }
        await waitUntil { service.setRegionMeshEnabledCallCount == 1 }

        viewModel.resetAccountScopedState()
        let loadsAfterReset = service.fetchMeshRegionsCallCount

        await writeGate.open()
        await toggle.value

        XCTAssertEqual(service.fetchMeshRegionsCallCount, loadsAfterReset)
        assertNoAccountScopedState(viewModel)
    }

    // togglingRegionIds and the deferred-reload flag are session state too, so
    // a toggle left over from the previous admin must not clear the new
    // admin's in-flight marker when it finally resolves.
    func testStaleToggleDoesNotDisturbTheNewSessionsToggleBookkeeping() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1", meshEnabled: false)]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        let target = viewModel.regions[0]

        let staleWriteGate = AsyncTestGate()
        service.setRegionMeshEnabledGate = staleWriteGate
        let staleToggle = Task { await viewModel.toggleMesh(region: target) }
        await waitUntil { service.setRegionMeshEnabledCallCount == 1 }

        service.emitAuthState(AuthenticatedUser(uid: "admin-2", email: "other@example.com"))
        await waitUntil { viewModel.togglingRegionIds.isEmpty }

        // The new admin loads the page and starts their own toggle of the same
        // region.
        let freshWriteGate = AsyncTestGate()
        service.setRegionMeshEnabledGate = freshWriteGate
        await viewModel.load()
        let freshTarget = viewModel.regions[0]
        let freshToggle = Task { await viewModel.toggleMesh(region: freshTarget) }
        await waitUntil { service.setRegionMeshEnabledCallCount == 2 }

        await staleWriteGate.open()
        await staleToggle.value

        XCTAssertTrue(viewModel.togglingRegionIds.contains("us-sanjose-1"))
        XCTAssertTrue(viewModel.dataAvailable)

        await freshWriteGate.open()
        await freshToggle.value
        XCTAssertTrue(viewModel.togglingRegionIds.isEmpty)
    }

    func testAuthListenerIsRegisteredOnceAndCancelledWhenTheViewModelIsReleased() async {
        let service = signedInService()
        var viewModel: CloudGatewayServerHealthViewModel? = CloudGatewayServerHealthViewModel(service: service)
        XCTAssertNotNil(viewModel)
        XCTAssertEqual(service.addAuthStateListenerCallCount, 1)
        XCTAssertEqual(service.removeAuthStateListenerCallCount, 0)

        viewModel = nil

        XCTAssertNil(viewModel)
        XCTAssertEqual(service.removeAuthStateListenerCallCount, 1)
    }

    // MARK: - Mutual exclusion

    func testSyncAllAndToggleMeshAreMutuallyExclusiveWhileEitherIsInFlight() async {
        let service = signedInService()
        service.meshRegions = [region("us-sanjose-1", meshEnabled: false)]
        let viewModel = CloudGatewayServerHealthViewModel(service: service)
        await viewModel.load()
        let target = viewModel.regions[0]

        XCTAssertTrue(viewModel.canSyncAll)
        XCTAssertTrue(viewModel.canToggleMesh(target))

        let writeGate = AsyncTestGate()
        service.setRegionMeshEnabledGate = writeGate
        let toggle = Task { await viewModel.toggleMesh(region: target) }
        await waitUntil { service.setRegionMeshEnabledCallCount == 1 }

        XCTAssertFalse(viewModel.canSyncAll)
        await viewModel.syncAll()
        XCTAssertEqual(service.syncRegionsCallCount, 0)

        await writeGate.open()
        await toggle.value
        XCTAssertTrue(viewModel.canSyncAll)

        let syncGate = AsyncTestGate()
        service.syncRegionsGate = syncGate
        let sync = Task { await viewModel.syncAll() }
        await waitUntil { viewModel.isSyncing }

        XCTAssertFalse(viewModel.canToggleMesh(target))
        await viewModel.toggleMesh(region: target)
        XCTAssertEqual(service.setRegionMeshEnabledCallCount, 1)

        await syncGate.open()
        await sync.value
    }
}
