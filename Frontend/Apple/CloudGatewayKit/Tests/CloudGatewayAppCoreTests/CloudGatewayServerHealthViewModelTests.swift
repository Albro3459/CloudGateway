@testable import CloudGatewayAppCore
import XCTest

// Admin gating (redirecting non-admins / signed-out users away from the page)
// lives in the iOS view layer (ContentView dismisses the cover when the role
// stops being admin), not in this view model - see TODO/ios-server-health.md
// stage 5. What belongs here is the identity guard: an async step must not
// publish results for a user who is no longer current, which these tests
// cover directly (sign-out mid-toggle, mid-sync-fan-out).
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
