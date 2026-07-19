@testable import CloudGatewayAppCore
import CloudGatewayKit
import XCTest

@MainActor
final class CloudGatewayViewModelTests: XCTestCase {
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

    private func waitForLocalState(
        _ viewModel: CloudGatewayViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 where viewModel.installedSnapshots.isEmpty {
            await Task.yield()
        }
        if viewModel.installedSnapshots.isEmpty {
            XCTFail("waitForLocalState timed out", file: file, line: line)
        }
    }

    private func waitForCacheLoads(
        _ cache: FakeConfigCache,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await cache.loadRequests() >= count {
                return
            }
            await Task.yield()
        }
        XCTFail("waitForCacheLoads timed out", file: file, line: line)
    }

    private func waitForSleeper(
        _ sleeper: ControlledPresentationSleeper,
        recordedDurationCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await sleeper.recordedDurations().count >= recordedDurationCount {
                return
            }
            await Task.yield()
        }
        XCTFail("waitForSleeper timed out", file: file, line: line)
    }

    private func makeViewModel(_ service: MockGatewayService) -> CloudGatewayViewModel {
        CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: FakeTunnelManager(),
                cache: FakeConfigCache(),
                secretStore: FakeConfigSecretStore()
            )
        )
    }

    private func makeViewModel(
        _ service: MockGatewayService,
        installedSnapshots: [CloudGatewayConfigSnapshot],
        tunnelStatus: CloudGatewayTunnelStatus,
        healthReader: CloudGatewayTunnelHealthReading = NoopTunnelHealthReader()
    ) -> CloudGatewayViewModel {
        CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: FakeTunnelManager(status: tunnelStatus),
                cache: FakeConfigCache(snapshots: installedSnapshots),
                secretStore: FakeConfigSecretStore()
            ),
            healthReader: healthReader
        )
    }

    private func signedInService() -> MockGatewayService {
        let service = MockGatewayService()
        service.currentUser = AuthenticatedUser(uid: "u1", email: "a@b.com")
        return service
    }

    func testDeadTunnelTimeoutShowsVpnWarningInsteadOfGenericTimeout() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.fetchRegionsError = URLError(.timedOut)
        let healthReader = FakeTunnelHealthReader(snapshot: CloudGatewayTunnelHealthSnapshot(
            tunnelIdentifier: "c1",
            health: .notPassingTraffic,
            updatedAt: Date()
        ))
        let viewModel = makeViewModel(
            service,
            installedSnapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")],
            tunnelStatus: .connected,
            healthReader: healthReader
        )

        await viewModel.refresh()

        XCTAssertTrue(viewModel.shouldShowDeadTunnelWarning)
        XCTAssertNil(viewModel.errorText)
        XCTAssertEqual(viewModel.appMode, .signedIn)
    }

    func testLoggedOutUserCanSeeAndDisconnectDeadTunnelWarning() async {
        let service = MockGatewayService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let healthReader = FakeTunnelHealthReader(snapshot: CloudGatewayTunnelHealthSnapshot(
            tunnelIdentifier: "c1",
            health: .notPassingTraffic,
            updatedAt: Date()
        ))
        let notificationAuthorizer = FakeNotificationAuthorizer()
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: FakeTunnelManager(status: .connected),
                cache: FakeConfigCache(snapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")]),
                secretStore: FakeConfigSecretStore()
            ),
            healthReader: healthReader,
            notificationAuthorizer: notificationAuthorizer
        )

        await viewModel.refresh()
        await waitForLocalState(viewModel)
        viewModel.refreshTunnelHealth()

        XCTAssertEqual(viewModel.appMode, .guest)
        XCTAssertTrue(viewModel.shouldShowDeadTunnelWarning)
        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertEqual(notificationAuthorizer.undeterminedAuthorizationRequestCount, 1)

        await viewModel.disconnectDeadTunnel()

        XCTAssertFalse(viewModel.shouldShowDeadTunnelWarning)
        XCTAssertEqual(viewModel.tunnelStatuses["c1"], .disconnected)
    }

    func testExistingInstallNotificationAuthorizationSkipsDevicesWithoutConfigs() {
        let notificationAuthorizer = FakeNotificationAuthorizer()

        CloudGatewayExistingInstallNotificationAuthorization.requestIfNeeded(
            hasInstalledConfig: false,
            authorizer: notificationAuthorizer
        )

        XCTAssertEqual(notificationAuthorizer.undeterminedAuthorizationRequestCount, 0)
    }

    func testFirstInstallNotificationAuthorizationRequestsPermission() {
        let notificationAuthorizer = FakeNotificationAuthorizer()

        CloudGatewayFirstInstallNotificationAuthorization.request(
            authorizer: notificationAuthorizer
        )

        XCTAssertEqual(notificationAuthorizer.authorizationRequestCount, 1)
    }

    func testAuthListenerInitialUserLoadsSignedInState() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let viewModel = makeViewModel(service)

        service.emitAuthState(service.currentUser)
        await waitUntil { viewModel.appMode == .signedIn && !viewModel.isWorking }

        XCTAssertEqual(service.addAuthStateListenerCallCount, 1)
        XCTAssertEqual(viewModel.signedInUid, "u1")
        XCTAssertEqual(viewModel.signedInEmail, "a@b.com")
        XCTAssertEqual(service.fetchOwnedClientsCallCount, 1)
    }

    func testAuthListenerExternalSignOutDropsLoadedSessionToGuest() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let viewModel = makeViewModel(service)

        service.emitAuthState(service.currentUser)
        await waitUntil { viewModel.appMode == .signedIn && !viewModel.isWorking }
        service.emitAuthState(nil)
        await waitUntil { viewModel.appMode == .guest && !viewModel.isWorking }

        XCTAssertNil(viewModel.signedInUid)
        XCTAssertEqual(viewModel.regions.map(\.regionId), ["us-sanjose-1"])
    }

    func testAuthListenerUserReplacementClearsOldStateAndQueuesNewLoad() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("user-a-client", regionId: "us-sanjose-1")]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()
        XCTAssertEqual(viewModel.clientOptions.map(\.client.clientId), ["user-a-client"])

        let fetchRegionsGate = AsyncTestGate()
        service.fetchRegionsGate = fetchRegionsGate
        let staleRefresh = Task { await viewModel.refresh() }
        await waitUntil { viewModel.isWorking && service.fetchRegionsCallCount == 2 }

        service.ownedClients = [TestFixtures.client("user-b-client", regionId: "us-sanjose-1")]
        service.emitAuthState(AuthenticatedUser(uid: "u2", email: "b@example.com"))
        await waitUntil {
            viewModel.signedInUid == "u2" && viewModel.clientOptions.isEmpty
        }
        service.emitAuthState(AuthenticatedUser(uid: "u2", email: "b@example.com"))

        await fetchRegionsGate.open()
        await staleRefresh.value
        await waitUntil {
            viewModel.signedInUid == "u2"
                && !viewModel.isWorking
                && viewModel.clientOptions.map(\.client.clientId) == ["user-b-client"]
        }

        XCTAssertEqual(viewModel.signedInEmail, "b@example.com")
        XCTAssertEqual(viewModel.clientOptions.map(\.client.clientId), ["user-b-client"])
        XCTAssertFalse(viewModel.clientOptions.contains { $0.client.clientId == "user-a-client" })
        XCTAssertEqual(service.fetchRegionsCallCount, 3)
    }

    // Covers the reloadAuthState wait loop's re-check of authStateGeneration when a
    // *second* swap lands while a waiter is already parked - not just the
    // single-swap-then-resume case above. u2's waiter must wake up and bail without
    // refreshing once u3 has superseded it; only u3's waiter should trigger a load.
    func testSecondUserSwapWhileReloadAuthStateWaiterIsParkedSkipsStaleWaiter() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("user-a-client", regionId: "us-sanjose-1")]
        let viewModel = makeViewModel(service)

        let fetchRegionsGate = AsyncTestGate()
        service.fetchRegionsGate = fetchRegionsGate
        let staleRefresh = Task { await viewModel.refresh() }
        await waitUntil { viewModel.isWorking && service.fetchRegionsCallCount == 1 }

        // First swap (u1 -> u2): isWorking is still true, so reloadAuthState parks a
        // continuation instead of refreshing immediately.
        service.ownedClients = [TestFixtures.client("user-b-client", regionId: "us-sanjose-1")]
        service.emitAuthState(AuthenticatedUser(uid: "u2", email: "b@example.com"))
        await waitUntil { viewModel.signedInUid == "u2" }

        // Second swap (u2 -> u3) arrives while u2's waiter is still parked; it bumps
        // authStateGeneration again and parks its own waiter behind u2's.
        service.ownedClients = [TestFixtures.client("user-c-client", regionId: "us-sanjose-1")]
        service.emitAuthState(AuthenticatedUser(uid: "u3", email: "c@example.com"))
        await waitUntil { viewModel.signedInUid == "u3" }

        await fetchRegionsGate.open()
        await staleRefresh.value
        await waitUntil {
            viewModel.signedInUid == "u3"
                && !viewModel.isWorking
                && viewModel.clientOptions.map(\.client.clientId) == ["user-c-client"]
        }

        XCTAssertEqual(viewModel.signedInEmail, "c@example.com")
        XCTAssertEqual(viewModel.clientOptions.map(\.client.clientId), ["user-c-client"])
        XCTAssertFalse(viewModel.clientOptions.contains { $0.client.clientId == "user-b-client" })
        // u1's stale refresh() fails its own fence and bails; u2's parked waiter wakes
        // up superseded and bails too; only u3's waiter actually reloads - two total
        // fetchRegions calls, not three.
        XCTAssertEqual(service.fetchRegionsCallCount, 2)
    }

    func testUserReplacementDuringPullToRefreshCannotPublishOldOfflineFallback() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("user-a-client", regionId: "us-sanjose-1")]
        let cache = FakeConfigCache(snapshots: [TestFixtures.snapshot("user-a-client", regionId: "us-sanjose-1")])
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: FakeTunnelManager(),
                cache: cache,
                secretStore: FakeConfigSecretStore()
            )
        )
        await viewModel.refresh()
        let initialCacheLoadCount = await cache.loadRequests()

        service.fetchRegionsError = URLError(.notConnectedToInternet)
        let fallbackGate = AsyncTestGate()
        await cache.setLoadGate(fallbackGate)
        let stalePull = Task { await viewModel.pullToRefresh() }
        await waitForCacheLoads(cache, count: initialCacheLoadCount + 1)

        service.fetchRegionsError = nil
        service.ownedClients = [TestFixtures.client("user-b-client", regionId: "us-sanjose-1")]
        service.emitAuthState(AuthenticatedUser(uid: "u2", email: "b@example.com"))
        await waitUntil { viewModel.signedInUid == "u2" }
        await fallbackGate.open()
        await stalePull.value
        await waitUntil {
            viewModel.signedInUid == "u2"
                && viewModel.clientOptions.map(\.client.clientId) == ["user-b-client"]
        }

        XCTAssertFalse(viewModel.remoteRefreshUnavailable)
        XCTAssertNil(viewModel.staleText)
        XCTAssertEqual(viewModel.clientOptions.map(\.client.clientId), ["user-b-client"])
    }

    // Covers the compound race the "cancel the outer .refreshable task" comment on
    // pullToRefresh exists for: reloadCurrentState captures `generation` *inside*
    // the detached Task it spawns (CloudGatewayViewModel.swift:696-700), so the
    // fence still applies even after SwiftUI retracts the pull and cancels the
    // outer awaiting task.
    //
    // This re-authenticates as the *same* uid (sign out, then back in as u1)
    // rather than swapping to a different user, on purpose: a different-uid swap
    // would also be caught by the plain isCurrentUser identity check, which
    // wouldn't pin down that the generation fence specifically is what's doing
    // the work. Sign-out-then-back-in bumps authStateGeneration twice while
    // uid stays "u1", so isCurrentUser(user) alone would let a stale reload
    // through - only the generation check inside ensureCurrentSession can catch
    // it. Cancel the outer task while A's original-session detached reload is
    // gated mid-flight, then reauth as u1 while it's still suspended: the stale
    // session's reload must never publish its data into the new session.
    func testSameUserReauthDuringCancelledOuterPullToRefreshCannotPublishStaleSessionData() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("a-client", regionId: "us-sanjose-1")]
        let viewModel = makeViewModel(service)
        await viewModel.refresh()
        XCTAssertEqual(viewModel.clientOptions.map(\.client.clientId), ["a-client"])

        // Gates only the stale detached reload's fetchRegions call - the
        // sign-out/re-sign-in reloads below are left ungated so the legitimate
        // new-session reload can run to completion first. That ordering matters:
        // it proves the fence, not last-write-wins scheduling, is what keeps the
        // stale write out once it resumes afterward.
        let staleReloadGate = AsyncTestGate()
        service.fetchRegionsGate = staleReloadGate
        let outerPull = Task { await viewModel.pullToRefresh() }
        await waitUntil { service.fetchRegionsCallCount == 2 }

        // Simulate SwiftUI retracting the pull control mid-flight. pullToRefresh's
        // detached reload is an independent unstructured Task, so cancelling the
        // outer awaiting task here must not tear it down or skip its fence.
        outerPull.cancel()

        // Sign out and back in as the same uid: a brand-new session for the same
        // account. Ungate fetchRegions first so this reload isn't stuck behind
        // the still-gated stale one.
        service.fetchRegionsGate = nil
        service.emitAuthState(nil)
        await waitUntil { viewModel.appMode == .guest }
        service.ownedClients = [TestFixtures.client("a-client-resession", regionId: "us-sanjose-1")]
        service.emitAuthState(AuthenticatedUser(uid: "u1", email: "a@b.com"))
        await waitUntil {
            viewModel.appMode == .signedIn
                && viewModel.clientOptions.map(\.client.clientId) == ["a-client-resession"]
        }

        // Change the server-side data again so a leaked publish from the stale
        // session is unmistakable, then release it. isCurrentUser(user) alone
        // would pass here (still uid "u1"), so only the generation fence can
        // stop this from clobbering the new session's already-applied state.
        service.ownedClients = [TestFixtures.client("stale-session-leak", regionId: "us-sanjose-1")]
        await staleReloadGate.open()
        _ = await outerPull.value

        XCTAssertEqual(viewModel.signedInUid, "u1")
        XCTAssertEqual(viewModel.clientOptions.map(\.client.clientId), ["a-client-resession"])
        XCTAssertFalse(viewModel.clientOptions.contains { $0.client.clientId == "stale-session-leak" })
        XCTAssertEqual(viewModel.regions.map(\.regionId), ["us-sanjose-1"])
    }

    func testAuthListenerExternalSignOutDuringRefreshCannotRestoreOldSession() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let fetchRegionsGate = AsyncTestGate()
        service.fetchRegionsGate = fetchRegionsGate
        let viewModel = makeViewModel(service)

        let refresh = Task { await viewModel.refresh() }
        await waitUntil { viewModel.isWorking && service.fetchRegionsCallCount == 1 }
        service.emitAuthState(nil)
        await waitUntil { viewModel.appMode == .guest }
        await fetchRegionsGate.open()
        await refresh.value
        await waitUntil { viewModel.appMode == .guest && !viewModel.isWorking }

        XCTAssertEqual(viewModel.appMode, .guest)
        XCTAssertNil(viewModel.signedInUid)
    }

    func testAuthListenerExternalSignOutDuringConfigApplyCannotRestoreOldSession() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let cache = FakeConfigCache()
        let configApplyGate = AsyncTestGate()
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: FakeTunnelManager(),
                cache: cache,
                secretStore: FakeConfigSecretStore()
            )
        )
        for _ in 0..<1_000 where await cache.loadRequests() == 0 {
            await Task.yield()
        }
        await cache.setLoadGate(configApplyGate)

        let refresh = Task { await viewModel.refresh() }
        for _ in 0..<1_000 where await cache.loadRequests() < 2 {
            await Task.yield()
        }
        service.emitAuthState(nil)
        await waitUntil { viewModel.appMode == .guest }
        await configApplyGate.open()
        await refresh.value
        await waitUntil { !viewModel.isWorking }

        XCTAssertEqual(viewModel.appMode, .guest)
        XCTAssertNil(viewModel.signedInUid)
        XCTAssertTrue(viewModel.clientOptions.isEmpty)
    }

    func testAuthListenerIgnoresRedundantCallbackAfterManualSignOut() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()
        await viewModel.signOut()
        let fetchCountAfterGuestLoad = service.fetchRegionsCallCount
        service.emitAuthState(nil)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(viewModel.appMode, .guest)
        XCTAssertEqual(service.fetchRegionsCallCount, fetchCountAfterGuestLoad)
    }

    func testAuthListenerIgnoresRedundantCallbackAfterForcedSignOut() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.checkAccessError = CloudGatewayAppError.accessDenied("No access")
        let viewModel = makeViewModel(service)

        await viewModel.refresh()
        let fetchCountAfterGuestLoad = service.fetchRegionsCallCount
        service.emitAuthState(nil)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(viewModel.appMode, .guest)
        XCTAssertEqual(service.signOutCallCount, 1)
        XCTAssertEqual(service.fetchRegionsCallCount, fetchCountAfterGuestLoad)
    }

    func testViewModelDeinitRemovesAuthListener() async {
        let service = MockGatewayService()
        var viewModel: CloudGatewayViewModel? = makeViewModel(service)
        let weakViewModel = WeakBox(viewModel)

        XCTAssertEqual(service.addAuthStateListenerCallCount, 1)
        viewModel = nil
        await waitUntil { weakViewModel.value == nil }

        XCTAssertNil(weakViewModel.value)
        XCTAssertEqual(service.removeAuthStateListenerCallCount, 1)
    }

    func testPresentationAppearancePerformsOneImmediateLocalHealthRead() async {
        let service = MockGatewayService()
        let healthReader = FakeTunnelHealthReader(snapshot: CloudGatewayTunnelHealthSnapshot(
            tunnelIdentifier: "c1",
            health: .passingTraffic,
            updatedAt: Date()
        ))
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: FakeTunnelManager(),
                cache: FakeConfigCache(),
                secretStore: FakeConfigSecretStore()
            ),
            healthReader: healthReader
        )
        await waitUntil { healthReader.readCount > 0 }
        let initialReadCount = healthReader.readCount

        viewModel.presentationDidAppear()

        XCTAssertEqual(healthReader.readCount, initialReadCount + 1)
        XCTAssertEqual(viewModel.tunnelHealthSnapshot?.health, .passingTraffic)
        XCTAssertEqual(service.fetchRegionsCallCount, 0)
    }

    func testPresentationMonitorRefreshesImmediatelyThenEveryFiveSeconds() async {
        let service = MockGatewayService()
        let healthReader = FakeTunnelHealthReader()
        let sleeper = ControlledPresentationSleeper()
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: FakeTunnelManager(),
                cache: FakeConfigCache(),
                secretStore: FakeConfigSecretStore()
            ),
            healthReader: healthReader,
            presentationSleeper: sleeper
        )
        await waitUntil { healthReader.readCount > 0 }
        let initialReadCount = healthReader.readCount

        let monitor = Task { await viewModel.monitorPresentationHealthAndStatus() }
        await waitForSleeper(sleeper, recordedDurationCount: 1)

        XCTAssertEqual(healthReader.readCount, initialReadCount + 1)
        let firstDurations = await sleeper.recordedDurations()
        XCTAssertEqual(firstDurations, [.seconds(5)])

        await sleeper.resumeNext()
        await waitForSleeper(sleeper, recordedDurationCount: 2)

        XCTAssertEqual(healthReader.readCount, initialReadCount + 2)
        let secondDurations = await sleeper.recordedDurations()
        XCTAssertEqual(secondDurations, [.seconds(5), .seconds(5)])

        monitor.cancel()
        await monitor.value
        let cancelledReadCount = healthReader.readCount
        await sleeper.resumeNext()
        await Task.yield()
        XCTAssertEqual(healthReader.readCount, cancelledReadCount)
    }

    func testNewPresentationMonitorSupersedesOlderLoop() async {
        let healthReader = FakeTunnelHealthReader()
        let sleeper = ControlledPresentationSleeper()
        let viewModel = CloudGatewayViewModel(
            service: MockGatewayService(),
            configManager: CloudGatewayConfigManager(
                tunnelManager: FakeTunnelManager(),
                cache: FakeConfigCache(),
                secretStore: FakeConfigSecretStore()
            ),
            healthReader: healthReader,
            presentationSleeper: sleeper
        )
        await waitUntil { healthReader.readCount > 0 }
        let initialReadCount = healthReader.readCount

        let olderMonitor = Task { await viewModel.monitorPresentationHealthAndStatus() }
        await waitForSleeper(sleeper, recordedDurationCount: 1)
        let newerMonitor = Task { await viewModel.monitorPresentationHealthAndStatus() }
        await waitForSleeper(sleeper, recordedDurationCount: 2)

        XCTAssertEqual(healthReader.readCount, initialReadCount + 2)

        await sleeper.resumeNext()
        await olderMonitor.value
        XCTAssertEqual(healthReader.readCount, initialReadCount + 2)

        await sleeper.resumeNext()
        await waitForSleeper(sleeper, recordedDurationCount: 3)
        XCTAssertEqual(healthReader.readCount, initialReadCount + 3)

        newerMonitor.cancel()
        await newerMonitor.value
    }

    func testCancelledPresentationMonitorDiscardsLateLocalStatusCompletion() async {
        let service = MockGatewayService()
        let cache = FakeConfigCache(snapshots: [
            TestFixtures.snapshot("c1", regionId: "us-sanjose-1")
        ])
        let tunnelManager = FakeTunnelManager(status: .disconnected)
        let healthReader = FakeTunnelHealthReader(snapshot: CloudGatewayTunnelHealthSnapshot(
            tunnelIdentifier: "c1",
            health: .notPassingTraffic,
            updatedAt: Date()
        ))
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: cache,
                secretStore: FakeConfigSecretStore()
            ),
            healthReader: healthReader,
            presentationSleeper: ControlledPresentationSleeper()
        )
        await waitForLocalState(viewModel)
        XCTAssertEqual(viewModel.tunnelStatuses["c1"], .disconnected)

        await tunnelManager.setStatus(.connected, for: "c1")
        let gate = AsyncTestGate()
        await cache.setLoadGate(gate)
        let loadCountBeforeMonitor = await cache.loadRequests()
        let monitor = Task { await viewModel.monitorPresentationHealthAndStatus() }
        for _ in 0..<1_000 {
            if await cache.loadRequests() > loadCountBeforeMonitor {
                break
            }
            await Task.yield()
        }

        monitor.cancel()
        await gate.open()
        await monitor.value

        XCTAssertEqual(viewModel.tunnelStatuses["c1"], .disconnected)
        XCTAssertEqual(service.fetchRegionsCallCount, 0)
    }

    func testFutureMacOSCompositionConstructsAppCoreWithInjectedPlatformIdentifiers() {
        let platform = CloudGatewayPlatformConfiguration(
            appGroupIdentifier: "group.com.example.cloudgateway.macos",
            appBundleIdentifier: "com.example.cloudgateway.macos",
            providerBundleIdentifier: "com.example.cloudgateway.macos.tunnel",
            tunnelDisplayName: "CloudGateway for macOS",
            keychainAccessGroupIdentifier: "TEAMID.com.example.cloudgateway.macos"
        )
        let service = MockGatewayService()
        let tunnelManager = CloudGatewayVPNManager(platform: platform)

        _ = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(),
                secretStore: FakeConfigSecretStore(),
                configSecretServiceName: platform.configSecretServiceName
            )
        )

        XCTAssertEqual(tunnelManager.platform, platform)
        XCTAssertEqual(service.addAuthStateListenerCallCount, 1)
    }

    func testDeadTunnelRefreshReconcilesExternallyStartedStatusWithoutOverlay() async {
        let service = MockGatewayService()
        let tunnelManager = FakeTunnelManager(status: .disconnected)
        let healthReader = FakeTunnelHealthReader(snapshot: CloudGatewayTunnelHealthSnapshot(
            tunnelIdentifier: "c1",
            health: .notPassingTraffic,
            updatedAt: Date()
        ))
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(snapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")]),
                secretStore: FakeConfigSecretStore()
            ),
            healthReader: healthReader
        )

        await waitForLocalState(viewModel)
        XCTAssertEqual(viewModel.tunnelStatuses["c1"], .disconnected)
        await tunnelManager.setStatus(.connected, for: "c1")

        await viewModel.refreshTunnelHealthAndStatus()

        XCTAssertEqual(viewModel.tunnelStatuses["c1"], .connected)
        XCTAssertTrue(viewModel.shouldShowDeadTunnelWarning)
        XCTAssertFalse(viewModel.isWorking)
    }

    func testDeadTunnelRefreshRetriesAfterStatusReadFailure() async {
        let service = MockGatewayService()
        let tunnelManager = FakeTunnelManager(status: .disconnected)
        let healthReader = FakeTunnelHealthReader(snapshot: CloudGatewayTunnelHealthSnapshot(
            tunnelIdentifier: "c1",
            health: .notPassingTraffic,
            updatedAt: Date()
        ))
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(snapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")]),
                secretStore: FakeConfigSecretStore()
            ),
            healthReader: healthReader
        )

        await waitForLocalState(viewModel)
        let readError = NSError(domain: "FakeTunnelManager", code: 1)
        await tunnelManager.setStatusReadError(readError)
        await viewModel.refreshTunnelHealthAndStatus()
        XCTAssertEqual(viewModel.tunnelStatuses["c1"], .disconnected)

        await tunnelManager.setStatusReadError(nil)
        await tunnelManager.setStatus(.connected, for: "c1")
        await viewModel.refreshTunnelHealthAndStatus()

        XCTAssertEqual(viewModel.tunnelStatuses["c1"], .connected)
    }

    func testDeadTunnelDisconnectTimeoutDoesNotReloadThroughDisconnectingTunnel() async {
        let service = MockGatewayService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let tunnelManager = FakeTunnelManager(status: .connected)
        await tunnelManager.setStopResultStatus(.disconnecting)
        await tunnelManager.setAllStatusesReadDelay(.seconds(60))
        let healthReader = FakeTunnelHealthReader(snapshot: CloudGatewayTunnelHealthSnapshot(
            tunnelIdentifier: "c1",
            health: .notPassingTraffic,
            updatedAt: Date()
        ))
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(snapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")]),
                secretStore: FakeConfigSecretStore()
            ),
            healthReader: healthReader,
            deadTunnelDisconnectTimeout: .milliseconds(20),
            deadTunnelDisconnectPollInterval: .milliseconds(1)
        )

        await viewModel.refresh()
        await waitForLocalState(viewModel)
        await viewModel.refreshTunnelHealthAndStatus()
        let fetchCountBeforeDisconnect = service.fetchRegionsCallCount
        let clock = ContinuousClock()
        let startedAt = clock.now

        await viewModel.disconnectDeadTunnel()

        let stopRequests = await tunnelManager.stopRequests()
        XCTAssertTrue(startedAt.duration(to: clock.now) < .seconds(1))
        XCTAssertEqual(viewModel.errorText, CloudGatewayViewModel.deadTunnelDisconnectTimeoutMessage)
        XCTAssertEqual(viewModel.tunnelStatuses["c1"], .disconnecting)
        XCTAssertEqual(service.fetchRegionsCallCount, fetchCountBeforeDisconnect)
        XCTAssertEqual(stopRequests, ["c1"])
    }

    func testDeadTunnelDisconnectTimeoutBoundsStopRequest() async {
        let service = MockGatewayService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let tunnelManager = FakeTunnelManager(status: .connected)
        await tunnelManager.setStopDelay(.seconds(60))
        let healthReader = FakeTunnelHealthReader(snapshot: CloudGatewayTunnelHealthSnapshot(
            tunnelIdentifier: "c1",
            health: .notPassingTraffic,
            updatedAt: Date()
        ))
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(snapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")]),
                secretStore: FakeConfigSecretStore()
            ),
            healthReader: healthReader,
            deadTunnelDisconnectTimeout: .milliseconds(20),
            deadTunnelDisconnectPollInterval: .milliseconds(1)
        )

        await viewModel.refresh()
        await waitForLocalState(viewModel)
        await viewModel.refreshTunnelHealthAndStatus()
        let clock = ContinuousClock()
        let startedAt = clock.now

        await viewModel.disconnectDeadTunnel()

        let stopRequests = await tunnelManager.stopRequests()
        XCTAssertTrue(startedAt.duration(to: clock.now) < .seconds(1))
        XCTAssertEqual(viewModel.errorText, CloudGatewayViewModel.deadTunnelDisconnectTimeoutMessage)
        XCTAssertEqual(viewModel.tunnelStatuses["c1"], .connected)
        XCTAssertEqual(stopRequests, ["c1"])
        XCTAssertFalse(viewModel.isWorking)
    }

    func testDisconnectDeadTunnelMidFlightCancellationTearsDownOperationAndTimeout() async {
        let service = MockGatewayService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let tunnelManager = FakeTunnelManager(status: .connected)
        await tunnelManager.setStopDelay(.seconds(5))
        let healthReader = FakeTunnelHealthReader(snapshot: CloudGatewayTunnelHealthSnapshot(
            tunnelIdentifier: "c1",
            health: .notPassingTraffic,
            updatedAt: Date()
        ))
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(snapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")]),
                secretStore: FakeConfigSecretStore()
            ),
            healthReader: healthReader,
            deadTunnelDisconnectTimeout: .seconds(5),
            deadTunnelDisconnectPollInterval: .milliseconds(1)
        )

        await viewModel.refresh()
        await waitForLocalState(viewModel)
        await viewModel.refreshTunnelHealthAndStatus()

        let clock = ContinuousClock()
        let startedAt = clock.now
        let disconnect = Task { await viewModel.disconnectDeadTunnel() }
        for _ in 0..<1_000 {
            if await tunnelManager.stopRequests().count == 1 {
                break
            }
            await Task.yield()
        }
        let stopRequestsBeforeCancel = await tunnelManager.stopRequests()
        XCTAssertEqual(stopRequestsBeforeCancel, ["c1"])

        // Cancel the caller while the operation task is suspended inside the
        // (cancellation-aware) stop-tunnel delay, well before either the 5s
        // stop delay or the 5s disconnect timeout could legitimately elapse.
        disconnect.cancel()
        await disconnect.value

        XCTAssertTrue(startedAt.duration(to: clock.now) < .seconds(1))
        XCTAssertNil(viewModel.errorText)
        XCTAssertFalse(viewModel.isWorking)

        // The operation task never reached the line that records the stop as
        // complete, proving it was torn down mid-flight rather than left to
        // finish in the background after the caller stopped awaiting it.
        let status = try? await tunnelManager.installedStatuses(for: ["c1"])
        XCTAssertEqual(status?["c1"], .connected)

        // If the timeout task had survived cancellation it would fire here and
        // overwrite errorText with the timeout message; give it that chance.
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(viewModel.errorText)
    }

    func testStaleDeadTunnelSnapshotDoesNotShowWarning() async {
        let service = signedInService()
        let healthReader = FakeTunnelHealthReader(snapshot: CloudGatewayTunnelHealthSnapshot(
            tunnelIdentifier: "c1",
            health: .notPassingTraffic,
            updatedAt: Date(timeIntervalSinceNow: -CloudGatewayTunnelHealthSnapshot.freshnessWindow - 1)
        ))
        let viewModel = makeViewModel(
            service,
            installedSnapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")],
            tunnelStatus: .connected,
            healthReader: healthReader
        )

        await waitForLocalState(viewModel)
        viewModel.refreshTunnelHealth()

        XCTAssertNil(viewModel.tunnelHealthSnapshot)
        XCTAssertFalse(viewModel.shouldShowDeadTunnelWarning)
    }

    // MARK: - Guest flow

    func testGuestRefreshLoadsRegionsWithoutAuthCalls() async {
        let service = MockGatewayService()
        service.enabledRegions = [
            TestFixtures.region("us-ashburn-1", displayOrder: 20, capacity: .known(limit: 10, allocated: 2)),
            TestFixtures.region("us-sanjose-1", displayOrder: 10, capacity: .known(limit: 10, allocated: 1)),
        ]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.appMode, .guest)
        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertEqual(viewModel.regions.map(\.regionId), ["us-sanjose-1", "us-ashburn-1"])
        XCTAssertTrue(viewModel.regions.allSatisfy { $0.capacity == nil })
        XCTAssertEqual(viewModel.selectedRegionId, "us-sanjose-1")
        XCTAssertEqual(service.fetchRegionsCallCount, 1)
        XCTAssertEqual(service.checkAccessCallCount, 0)
        XCTAssertEqual(service.addCapacityCallCount, 0)
        XCTAssertEqual(service.fetchUserRoleCallCount, 0)
        XCTAssertEqual(service.fetchOwnedClientsCallCount, 0)
    }

    func testGuestCreateIsBlockedBeforeAPI() async {
        let service = MockGatewayService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()
        viewModel.newClientName = "Guest laptop"
        await viewModel.createClient()

        XCTAssertEqual(viewModel.appMode, .guest)
        XCTAssertTrue(viewModel.createDisabled)
        XCTAssertNotNil(viewModel.errorText)
        XCTAssertEqual(service.createClientCallCount, 0)
    }

    func testSignOutReturnsToGuestAndHidesInstalledConfig() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()
        guard let option = viewModel.configOptions.first else {
            XCTFail("Expected an active signed-in config option.")
            return
        }
        viewModel.email = "user@example.com"
        viewModel.password = "secret-password"
        await viewModel.installFromCloud(option)

        XCTAssertEqual(viewModel.appMode, .signedIn)
        XCTAssertFalse(viewModel.installedSnapshots.isEmpty)
        XCTAssertTrue(viewModel.installedSnapshots.contains { $0.clientId == option.client.clientId })
        XCTAssertNotNil(viewModel.tunnelStatuses[option.client.clientId])

        await viewModel.signOut()

        XCTAssertEqual(viewModel.appMode, .guest)
        XCTAssertFalse(viewModel.isSignedIn)
        // Credentials are cleared on sign-out; the email is kept for convenience.
        XCTAssertEqual(viewModel.password, "")
        XCTAssertEqual(viewModel.email, "user@example.com")
        XCTAssertFalse(viewModel.installedSnapshots.isEmpty)
    }

    func testSignInMapsCredentialErrorsToGenericMessage() async {
        let service = MockGatewayService()
        service.signInError = CloudGatewayAppError.invalidSignInCredentials
        let viewModel = makeViewModel(service)
        viewModel.email = "user@example.com"
        viewModel.password = "wrong-password"

        await viewModel.signIn()

        XCTAssertEqual(service.signInCallCount, 1)
        XCTAssertEqual(viewModel.errorText, "Invalid email or password.")
    }

    func testSignInPreservesUnknownSignInErrors() async {
        let service = MockGatewayService()
        service.signInError = NSError(
            domain: "CloudGatewayTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Network unavailable."]
        )
        let viewModel = makeViewModel(service)
        viewModel.email = "user@example.com"
        viewModel.password = "password"

        await viewModel.signIn()

        XCTAssertEqual(service.signInCallCount, 1)
        XCTAssertEqual(viewModel.errorText, "Network unavailable.")
    }

    func testSignInPreservesDisabledAccountMessage() async {
        let service = MockGatewayService()
        service.signInError = CloudGatewayAppError.accessDenied("This account has been disabled. Contact support.")
        let viewModel = makeViewModel(service)
        viewModel.email = "user@example.com"
        viewModel.password = "password"

        await viewModel.signIn()

        XCTAssertEqual(service.signInCallCount, 1)
        XCTAssertEqual(viewModel.errorText, "This account has been disabled. Contact support.")
    }

    // MARK: - Reset password

    func testResetPasswordSendsEmailForValidAddress() async {
        let service = MockGatewayService()
        let viewModel = makeViewModel(service)
        viewModel.email = "user@example.com"

        await viewModel.resetPassword()

        XCTAssertEqual(service.sendPasswordResetCallCount, 1)
        XCTAssertEqual(service.sendPasswordResetEmail, "user@example.com")
        XCTAssertNotNil(viewModel.successText)
        XCTAssertNil(viewModel.errorText)
    }

    func testResetPasswordBlocksInvalidEmail() async {
        let service = MockGatewayService()
        let viewModel = makeViewModel(service)
        viewModel.email = "not-an-email"

        await viewModel.resetPassword()

        XCTAssertEqual(service.sendPasswordResetCallCount, 0)
        XCTAssertNotNil(viewModel.errorText)
    }

    // MARK: - Grant access

    private func signedInAdminService() -> MockGatewayService {
        let service = signedInService()
        service.userRole = "admin"
        service.accessRole = "admin"
        service.enabledRegions = [
            TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))
        ]
        return service
    }

    func testGrantAccessGrantsForAdminNewUser() async {
        let service = signedInAdminService()
        service.grantAccessAlreadyExisted = false
        let viewModel = makeViewModel(service)
        await viewModel.refresh()

        XCTAssertTrue(viewModel.isAdmin)
        viewModel.newAccessEmail = "new@example.com"
        XCTAssertTrue(viewModel.canGrantAccess)

        await viewModel.grantAccess()

        XCTAssertEqual(service.grantAccessCallCount, 1)
        XCTAssertEqual(service.grantAccessEmail, "new@example.com")
        XCTAssertEqual(service.grantAccessRegionId, "us-sanjose-1")
        XCTAssertEqual(viewModel.successText, "User access granted: new@example.com")
        XCTAssertEqual(viewModel.newAccessEmail, "")
    }

    func testGrantAccessReportsExistingAccount() async {
        let service = signedInAdminService()
        service.grantAccessAlreadyExisted = true
        let viewModel = makeViewModel(service)
        await viewModel.refresh()
        viewModel.newAccessEmail = "existing@example.com"

        await viewModel.grantAccess()

        XCTAssertEqual(service.grantAccessCallCount, 1)
        XCTAssertEqual(viewModel.successText, "Existing account granted access: existing@example.com")
    }

    func testGrantAccessBlockedForNonAdmin() async {
        let service = signedInService()
        service.userRole = "user"
        service.accessRole = "user"
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let viewModel = makeViewModel(service)
        await viewModel.refresh()
        viewModel.newAccessEmail = "new@example.com"

        XCTAssertFalse(viewModel.canGrantAccess)

        await viewModel.grantAccess()

        XCTAssertEqual(service.grantAccessCallCount, 0)
        XCTAssertNotNil(viewModel.errorText)
    }

    func testGrantAccessBlockedForEmptyEmail() async {
        let service = signedInAdminService()
        let viewModel = makeViewModel(service)
        await viewModel.refresh()
        viewModel.newAccessEmail = "   "

        XCTAssertFalse(viewModel.canGrantAccess)

        await viewModel.grantAccess()

        XCTAssertEqual(service.grantAccessCallCount, 0)
        XCTAssertNotNil(viewModel.errorText)
    }

    func testAdminRefreshLoadsAllClients() async {
        let service = signedInAdminService()
        service.ownedClients = [
            TestFixtures.client("mine", regionId: "us-sanjose-1", ownerUid: "admin-uid", ownerEmail: "admin@example.com"),
            TestFixtures.client("theirs", regionId: "us-sanjose-1", ownerUid: "user-uid", ownerEmail: "user@example.com"),
        ]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()

        XCTAssertEqual(service.fetchOwnedClientsCallCount, 0)
        XCTAssertEqual(service.fetchAllClientsCallCount, 1)
        XCTAssertEqual(viewModel.filteredClientOptions.map(\.client.clientId), ["mine", "theirs"])
        XCTAssertEqual(viewModel.filteredClientOptions.last?.client.ownerEmail, "user@example.com")
    }

    func testAdminDeleteUsesSelectedClientOwnerUid() async throws {
        let service = signedInAdminService()
        service.currentUser = AuthenticatedUser(uid: "admin-uid", email: "admin@example.com")
        service.ownedClients = [
            TestFixtures.client("theirs", regionId: "us-sanjose-1", ownerUid: "user-uid", ownerEmail: "user@example.com")
        ]
        let viewModel = makeViewModel(service)
        await viewModel.refresh()

        viewModel.selectedClientId = "theirs"
        let option = try XCTUnwrap(viewModel.filteredClientOptions.first { $0.client.clientId == "theirs" })
        await viewModel.deleteClient(option)

        XCTAssertEqual(service.deleteClientCallCount, 1)
        XCTAssertEqual(service.deleteClientUserId, "user-uid")
    }

    func testDeleteClientDeletesCapturedOptionNotDriftedSelection() async throws {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [
            TestFixtures.client("a", regionId: "us-sanjose-1"),
            TestFixtures.client("b", regionId: "us-sanjose-1"),
        ]
        let viewModel = makeViewModel(service)
        await viewModel.refresh()

        // Capture the option for "a" (as the confirm alert would), then let the
        // selection drift to "b" before confirming.
        let pending = try XCTUnwrap(
            viewModel.displayedClientOptions.first { $0.client.clientId == "a" }
        )
        viewModel.selectedClientId = "b"

        await viewModel.deleteClient(pending)

        // The captured "a" is deleted, not the currently-selected "b".
        XCTAssertEqual(service.deleteClientCallCount, 1)
        XCTAssertEqual(service.deleteClientClientId, "a")
        // A non-matching selection is left intact.
        XCTAssertEqual(viewModel.selectedClientId, "b")
    }

    func testDeleteClientBlockedWhileConnectedToItsConfig() async throws {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let viewModel = makeViewModel(
            service,
            installedSnapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")],
            tunnelStatus: .connected
        )
        await viewModel.refresh()
        await waitForLocalState(viewModel)

        let option = try XCTUnwrap(
            viewModel.displayedClientOptions.first { $0.client.clientId == "c1" }
        )
        await viewModel.deleteClient(option)

        // A connected config cannot be deleted: the DELETE response would be
        // blackholed by the tunnel it removes.
        XCTAssertEqual(service.deleteClientCallCount, 0)
        XCTAssertEqual(viewModel.errorText, CloudGatewayViewModel.activeConfigDeleteMessage)
    }

    func testDeleteClientAllowsOptimisticallyDisconnectingConfig() async throws {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let viewModel = makeViewModel(
            service,
            installedSnapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")],
            tunnelStatus: .disconnecting
        )
        await viewModel.refresh()
        await waitForLocalState(viewModel)

        let option = try XCTUnwrap(viewModel.displayedClientOptions.first)
        await viewModel.deleteClient(option)

        XCTAssertEqual(service.deleteClientCallCount, 1)
    }

    func testDeleteClientOnlyBlocksTheTargetActiveProfile() async throws {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [
            TestFixtures.client("target", regionId: "us-sanjose-1"),
            TestFixtures.client("other", regionId: "us-sanjose-1")
        ]
        let tunnelManager = FakeTunnelManager()
        await tunnelManager.setStatus(.disconnected, for: "target")
        await tunnelManager.setStatus(.connected, for: "other")
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(snapshots: [
                    TestFixtures.snapshot("target", regionId: "us-sanjose-1"),
                    TestFixtures.snapshot("other", regionId: "us-sanjose-1")
                ]),
                secretStore: FakeConfigSecretStore()
            )
        )
        await viewModel.refresh()

        let option = try XCTUnwrap(
            viewModel.displayedClientOptions.first { $0.client.clientId == "target" }
        )
        await viewModel.deleteClient(option)

        XCTAssertEqual(service.deleteClientCallCount, 1)
        XCTAssertNil(viewModel.errorText)
    }

    func testDeleteUninstalledClientNotBlockedByAnotherActiveTunnel() async throws {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [
            TestFixtures.client("target", regionId: "us-sanjose-1"),
            TestFixtures.client("other", regionId: "us-sanjose-1")
        ]
        let tunnelManager = FakeTunnelManager()
        // Only "other" is installed on this device and it is connected. "target"
        // has no local tunnel, so it is absent from allInstalledStatuses().
        await tunnelManager.setStatus(.connected, for: "other")
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(snapshots: [
                    TestFixtures.snapshot("other", regionId: "us-sanjose-1")
                ]),
                secretStore: FakeConfigSecretStore()
            )
        )
        await viewModel.refresh()

        let option = try XCTUnwrap(
            viewModel.displayedClientOptions.first { $0.client.clientId == "target" }
        )
        await viewModel.deleteClient(option)

        // Deleting a client with no local tunnel must not be blocked just
        // because an unrelated tunnel is connected.
        XCTAssertEqual(service.deleteClientCallCount, 1)
        XCTAssertNil(viewModel.errorText)
    }

    func testSyncSelectedRegionCapturesResult() async {
        let service = signedInAdminService()
        let viewModel = makeViewModel(service)
        await viewModel.refresh()

        await viewModel.syncSelectedRegion()

        XCTAssertEqual(service.syncRegionCallCount, 1)
        XCTAssertEqual(viewModel.syncResult?.regionId, "us-sanjose-1")
        // logText now surfaces the API's peer-sync audit log verbatim.
        XCTAssertTrue(viewModel.syncResult?.logText.contains("CloudGateway peer sync audit log") == true)

        viewModel.dismissSyncResult()

        XCTAssertNil(viewModel.syncResult)
    }

    func testSyncCompletionCannotPublishPreviousUsersAuditLog() async {
        let service = signedInAdminService()
        let viewModel = makeViewModel(service)
        await viewModel.refresh()
        let syncGate = AsyncTestGate()
        service.syncRegionGate = syncGate

        let staleSync = Task { await viewModel.syncSelectedRegion() }
        await waitUntil { service.syncRegionCallCount == 1 }
        service.emitAuthState(AuthenticatedUser(uid: "u2", email: "b@example.com"))
        await waitUntil { viewModel.signedInUid == "u2" }
        await syncGate.open()
        await staleSync.value
        await waitUntil { !viewModel.isWorking && viewModel.signedInUid == "u2" }

        XCTAssertNil(viewModel.syncResult)
        XCTAssertEqual(viewModel.signedInEmail, "b@example.com")
    }

    // MARK: - Dedup (the fetchRegions-once fix)

    func testRefreshFetchesRegionsExactlyOnce() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()

        XCTAssertEqual(service.fetchRegionsCallCount, 1)
        XCTAssertEqual(service.addCapacityCallCount, 1)
        XCTAssertNil(viewModel.errorText)
        XCTAssertEqual(viewModel.selectedRegionId, "us-sanjose-1")
    }

    // MARK: - Sign-out branching

    func testRefreshSignsOutWhenAccessDenied() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.checkAccessError = CloudGatewayAppError.accessDenied("nope")
        let viewModel = makeViewModel(service)

        await viewModel.refresh()

        XCTAssertEqual(service.signOutCallCount, 1)
        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertNotNil(viewModel.errorText)
        // The forced sign-out populates guest state directly (the auth listener is
        // not relied on), so the guest dashboard is not left empty.
        XCTAssertEqual(viewModel.appMode, .guest)
        XCTAssertEqual(viewModel.regions.map(\.regionId), ["us-sanjose-1"])
    }

    func testRefreshKeepsSessionOnTransientAPIError() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.fetchOwnedClientsError = CloudGatewayAppError.invalidAPIResponse
        let viewModel = makeViewModel(service)

        await viewModel.refresh()

        XCTAssertEqual(service.signOutCallCount, 0)
        XCTAssertTrue(viewModel.isSignedIn)
        XCTAssertNotNil(viewModel.errorText)
    }

    func testRefreshIgnoresCancellationError() async {
        let service = signedInService()
        service.fetchRegionsError = CancellationError()
        let viewModel = makeViewModel(service)

        await viewModel.refresh()

        XCTAssertNil(viewModel.errorText)
        XCTAssertNil(viewModel.staleText)
    }

    // MARK: - Provider sign-in

    func testAppleSignInLoadsProvisionedUser() async {
        let service = MockGatewayService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))]
        let viewModel = makeViewModel(service)

        await viewModel.completeAppleSignIn(idToken: "tok", rawNonce: "nonce")

        XCTAssertEqual(service.signInWithAppleCallCount, 1)
        XCTAssertEqual(viewModel.appMode, .signedIn)
        XCTAssertTrue(viewModel.isSignedIn)
        XCTAssertEqual(service.signOutCallCount, 0)
        XCTAssertNil(viewModel.errorText)
    }

    func testGoogleSignInLoadsProvisionedUser() async {
        let service = MockGatewayService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))]
        let viewModel = makeViewModel(service)

        await viewModel.signInWithGoogle()

        XCTAssertEqual(service.signInWithGoogleCallCount, 1)
        XCTAssertEqual(viewModel.appMode, .signedIn)
        XCTAssertTrue(viewModel.isSignedIn)
        XCTAssertEqual(service.signOutCallCount, 0)
    }

    func testAppleSignInSignsOutUnprovisionedUser() async {
        let service = MockGatewayService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.checkAccessError = CloudGatewayAppError.accessDenied("Request access to continue.")
        let viewModel = makeViewModel(service)

        await viewModel.completeAppleSignIn(idToken: "tok", rawNonce: "nonce")

        XCTAssertEqual(service.signInWithAppleCallCount, 1)
        XCTAssertEqual(service.signOutCallCount, 1)
        XCTAssertEqual(viewModel.appMode, .guest)
        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertNotNil(viewModel.errorText)
        // Guest state is populated by the forced sign-out itself, not by a later
        // auth-state callback, so the dashboard shows regions immediately.
        XCTAssertEqual(viewModel.regions.map(\.regionId), ["us-sanjose-1"])
    }

    func testGoogleSignInSwallowsCancellation() async {
        let service = MockGatewayService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.signInWithGoogleError = CloudGatewayAppError.cancelled
        let viewModel = makeViewModel(service)

        await viewModel.signInWithGoogle()

        XCTAssertEqual(service.signInWithGoogleCallCount, 1)
        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertNil(viewModel.errorText)
        XCTAssertEqual(service.signOutCallCount, 0)
    }

    func testGoogleSignInSurfacesRealError() async {
        let service = MockGatewayService()
        service.signInWithGoogleError = CloudGatewayAppError.invalidAPIResponse
        let viewModel = makeViewModel(service)

        await viewModel.signInWithGoogle()

        XCTAssertEqual(service.signInWithGoogleCallCount, 1)
        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertNotNil(viewModel.errorText)
    }

    // MARK: - Account linking

    func testAccountLinkingShowsOnlyMissingProviders() async {
        let service = signedInService()
        service.providerIdsValue = ["google.com"]
        service.enabledRegions = [TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.missingLinkProviders, [.password, .apple])
        XCTAssertTrue(viewModel.canLinkAnotherProvider)
    }

    func testAccountLinkingHidesWhenAllProvidersLinked() async {
        let service = signedInService()
        service.providerIdsValue = ["password", "google.com", "apple.com"]
        service.enabledRegions = [TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()

        XCTAssertTrue(viewModel.missingLinkProviders.isEmpty)
        XCTAssertFalse(viewModel.canLinkAnotherProvider)
    }

    func testMissingLinkProvidersFollowLinkOrder() async {
        let service = signedInService()
        // Only email & password linked -> the two missing providers must be
        // offered Apple before Google per the link-ordering standard.
        service.providerIdsValue = ["password"]
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.missingLinkProviders, [.apple, .google])
    }

    func testAccountDeleteReauthPrefersAppleThenGoogleThenPassword() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        // No refresh(): currentProviderIds reads the service live, so each case
        // below reflects the freshly-set provider set.
        let viewModel = makeViewModel(service)

        service.providerIdsValue = ["password", "google.com", "apple.com"]
        XCTAssertEqual(viewModel.accountDeleteReauthMethod, .apple)

        service.providerIdsValue = ["password", "google.com"]
        XCTAssertEqual(viewModel.accountDeleteReauthMethod, .google)

        service.providerIdsValue = ["password"]
        XCTAssertEqual(viewModel.accountDeleteReauthMethod, .password)
    }

    func testLinkEmailPasswordTrimsEmailButNotPassword() async {
        let service = signedInService()
        service.providerIdsValue = ["google.com"]
        service.enabledRegions = [TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()
        viewModel.linkEmail = " linked@example.com "
        viewModel.linkPassword = " password123 "
        await viewModel.linkEmailPassword()

        XCTAssertEqual(service.linkEmailPasswordCallCount, 1)
        XCTAssertEqual(service.linkEmail, "linked@example.com")
        // Email is trimmed; the password is passed through verbatim.
        XCTAssertEqual(service.linkPassword, " password123 ")
        XCTAssertEqual(viewModel.appMode, .signedIn)
        XCTAssertEqual(viewModel.successText, "Email and password was linked to your account.")
        XCTAssertNil(viewModel.errorText)
    }

    func testLinkProviderAlreadyUsedDoesNotMerge() async {
        let service = signedInService()
        service.providerIdsValue = ["google.com"]
        service.enabledRegions = [TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))]
        service.linkAppleError = CloudGatewayAppError.credentialAlreadyInUse
        let viewModel = makeViewModel(service)

        await viewModel.refresh()
        await viewModel.linkApple(idToken: "tok", rawNonce: "nonce")

        XCTAssertEqual(service.linkAppleCallCount, 1)
        XCTAssertEqual(viewModel.errorText, CloudGatewayAppError.credentialAlreadyInUse.localizedDescription)
        XCTAssertNil(viewModel.successText)
    }

    func testLinkWithGoogleReauthenticatesAndRetriesForRecentLogin() async {
        let service = signedInService()
        service.providerIdsValue = ["google.com"]
        service.enabledRegions = [TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))]
        service.linkAppleErrors = [CloudGatewayAppError.requiresRecentLogin]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()
        await viewModel.linkApple(idToken: "tok", rawNonce: "nonce")

        XCTAssertEqual(service.reauthenticateWithGoogleCallCount, 1)
        XCTAssertEqual(service.linkAppleCallCount, 2)
        // Linking recovery must not disconnect the existing Google grant.
        XCTAssertEqual(service.reauthenticateWithGoogleRevokeValues, [false])
    }

    func testAppleLinkRecoveryCannotResumeAgainstReplacementUser() async {
        let service = signedInService()
        service.providerIdsValue = ["apple.com"]
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.linkGoogleError = CloudGatewayAppError.requiresRecentLogin
        let viewModel = makeViewModel(service)
        await viewModel.refresh()

        await viewModel.linkGoogle()
        XCTAssertEqual(viewModel.pendingLinkProvider, .google)
        service.linkGoogleError = nil
        let reauthGate = AsyncTestGate()
        service.reauthenticateWithAppleGate = reauthGate

        let staleRecovery = Task {
            await viewModel.completeAccountLinkAppleReauth(
                idToken: "tok",
                rawNonce: "nonce",
                authorizationCode: "code"
            )
        }
        await waitUntil { service.reauthenticateWithAppleCallCount == 1 }
        service.emitAuthState(AuthenticatedUser(uid: "u2", email: "b@example.com"))
        await waitUntil { viewModel.signedInUid == "u2" }
        await reauthGate.open()
        await staleRecovery.value
        await waitUntil { !viewModel.isWorking && viewModel.signedInUid == "u2" }

        XCTAssertEqual(service.linkGoogleCallCount, 1)
        XCTAssertNil(viewModel.successText)
        XCTAssertNil(viewModel.pendingLinkProvider)
    }

    func testDeleteAccountWithGoogleRevokesGrant() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let viewModel = makeViewModel(service)

        await viewModel.deleteAccountWithGoogle()

        // Account deletion must disconnect the Google grant.
        XCTAssertEqual(service.reauthenticateWithGoogleRevokeValues, [true])
        XCTAssertEqual(service.deleteAccountCallCount, 1)
    }

    func testDeleteAccountWithAppleRevokesGrant() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let viewModel = makeViewModel(service)

        await viewModel.deleteAccountWithApple(idToken: "tok", rawNonce: "nonce", authorizationCode: "code")

        // Account deletion must revoke the Apple grant.
        XCTAssertEqual(service.reauthenticateWithAppleRevokeValues, [true])
        XCTAssertEqual(service.deleteAccountCallCount, 1)
    }

    func testDeleteAccountBlockedWhileConnected() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let viewModel = makeViewModel(
            service,
            installedSnapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")],
            tunnelStatus: .connected
        )
        await viewModel.refresh()
        await waitForLocalState(viewModel)

        await viewModel.deleteAccountWithGoogle()

        // Account deletion removes every peer, so an active tunnel blocks it and
        // no reauth/delete request is made.
        XCTAssertEqual(service.deleteAccountCallCount, 0)
        XCTAssertEqual(service.reauthenticateWithGoogleRevokeValues, [])
        XCTAssertEqual(viewModel.errorText, CloudGatewayViewModel.activeAccountDeleteMessage)
    }

    func testDeleteAccountBlocksUncachedActiveProfile() async {
        let service = signedInService()
        let tunnelManager = FakeTunnelManager()
        await tunnelManager.setStatus(.connected, for: "uncached")
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(),
                secretStore: FakeConfigSecretStore()
            )
        )

        await viewModel.deleteAccountWithGoogle()

        XCTAssertEqual(service.deleteAccountCallCount, 0)
        XCTAssertEqual(viewModel.errorText, CloudGatewayViewModel.activeAccountDeleteMessage)
    }

    func testDeleteAccountRemovesUncachedProfileAfterSuccessfulDeletion() async {
        let service = signedInService()
        let tunnelManager = FakeTunnelManager()
        await tunnelManager.setStatus(.disconnected, for: "uncached")
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(),
                secretStore: FakeConfigSecretStore()
            )
        )

        await viewModel.deleteAccountWithGoogle()

        XCTAssertEqual(service.deleteAccountCallCount, 1)
        let statuses = try? await tunnelManager.allInstalledStatuses()
        XCTAssertTrue(statuses?.isEmpty ?? false)
    }

    // MARK: - Capacity gating

    func testCreateDisabledWhenSelectedRegionAtCapacity() async {
        let service = signedInService()
        service.enabledRegions = [
            TestFixtures.region("us-full-1", capacity: .known(limit: 1, allocated: 1))
        ]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.selectedRegionId, "us-full-1")
        XCTAssertTrue(viewModel.createDisabled)
    }

    func testCreateDisabledWhenSelectedRegionCapacityUnknown() async {
        let service = signedInService()
        service.enabledRegions = [
            TestFixtures.region("us-unknown-1", capacity: .unknown)
        ]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()

        XCTAssertTrue(viewModel.createDisabled)

        await viewModel.createClient()

        XCTAssertEqual(service.createClientCallCount, 0)
    }

    func testCreateDisabledWhenSelectedRegionCapacityMissing() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-missing-1")]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()

        XCTAssertTrue(viewModel.createDisabled)
    }

    func testCreateEnabledWhenCapacityAvailable() async {
        let service = signedInService()
        service.enabledRegions = [
            TestFixtures.region("us-open-1", capacity: .known(limit: 10, allocated: 1))
        ]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()

        XCTAssertTrue(viewModel.createDisabled)
        viewModel.newClientName = "John's iPhone"

        XCTAssertFalse(viewModel.createDisabled)
    }

    // MARK: - Selection ensure / prune

    func testSignInReplacesGuestDefaultWithFirstRegionContainingConfig() async {
        let service = MockGatewayService()
        service.enabledRegions = [
            TestFixtures.region("us-sanjose-1", displayOrder: 10),
            TestFixtures.region("us-ashburn-1", displayOrder: 20),
        ]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-ashburn-1")]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()
        XCTAssertEqual(viewModel.selectedRegionId, "us-sanjose-1")

        viewModel.email = "user@example.com"
        viewModel.password = "password"
        await viewModel.signIn()

        XCTAssertEqual(viewModel.selectedRegionId, "us-ashburn-1")
    }

    func testSelectedRegionDefaultsToFirstAndIsPreservedAcrossRefresh() async {
        let service = signedInService()
        service.enabledRegions = [
            TestFixtures.region("us-sanjose-1", displayOrder: 10),
            TestFixtures.region("us-ashburn-1", displayOrder: 20),
        ]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()
        XCTAssertEqual(viewModel.selectedRegionId, "us-sanjose-1")

        viewModel.selectedRegionId = "us-ashburn-1"
        await viewModel.refresh()
        XCTAssertEqual(viewModel.selectedRegionId, "us-ashburn-1")
    }

    func testStaleSelectedClientIsPrunedWhenNoLongerReturned() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let viewModel = makeViewModel(service)

        await viewModel.refresh()
        viewModel.selectedClientId = "c1"
        XCTAssertTrue(viewModel.filteredClientOptions.contains { $0.client.clientId == "c1" })

        service.ownedClients = []
        await viewModel.refresh()

        XCTAssertNil(viewModel.selectedClientId)
        XCTAssertFalse(viewModel.filteredClientOptions.contains { $0.client.clientId == "c1" })
    }

    func testInstalledMissingRemoteClientRemainsManageable() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = []
        let viewModel = makeViewModel(
            service,
            installedSnapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")],
            tunnelStatus: .disconnected
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.selectedClientId, "c1")
        XCTAssertFalse(viewModel.filteredClientOptions.contains { $0.client.clientId == "c1" })
        XCTAssertEqual(viewModel.installedSnapshots.first { $0.clientId == "c1" }?.clientId, "c1")
        XCTAssertNotNil(viewModel.staleText)
    }

    func testStartTunnelMissingFromSettingsShowsRefreshGuidanceAndClearsCardWarning() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let tunnelManager = FakeTunnelManager()
        await tunnelManager.setStatus(.disconnected, for: "c1")
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(snapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")]),
                secretStore: FakeConfigSecretStore()
            )
        )

        await viewModel.refresh()
        guard let option = viewModel.filteredClientOptions.first else {
            XCTFail("Expected an installed client option.")
            return
        }
        XCTAssertTrue(viewModel.isInstalled(option))

        await tunnelManager.setStatus(nil, for: "c1")
        await tunnelManager.setStartError(CloudGatewayVPNError.missingInstalledTunnel)
        await viewModel.startTunnel(for: option)

        XCTAssertEqual(
            viewModel.errorText,
            "The VPN profile is no longer installed on this device. Refresh, then you can install the config again."
        )
        XCTAssertFalse(viewModel.isInstalled(option))
        XCTAssertNil(viewModel.staleText(for: option))
    }

    func testStopTunnelMissingFromSettingsShowsRefreshGuidanceAndClearsCardWarning() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let tunnelManager = FakeTunnelManager()
        await tunnelManager.setStatus(.connected, for: "c1")
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(snapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")]),
                secretStore: FakeConfigSecretStore()
            )
        )

        await viewModel.refresh()
        guard let option = viewModel.filteredClientOptions.first else {
            XCTFail("Expected an installed client option.")
            return
        }
        XCTAssertTrue(viewModel.isInstalled(option))

        await tunnelManager.setStatus(nil, for: "c1")
        await tunnelManager.setStopError(CloudGatewayVPNError.missingInstalledTunnel)
        await viewModel.stopTunnel(for: option)

        XCTAssertEqual(
            viewModel.errorText,
            "The VPN profile is no longer installed on this device. Refresh, then you can install the config again."
        )
        XCTAssertFalse(viewModel.isInstalled(option))
        XCTAssertNil(viewModel.staleText(for: option))
    }

    func testSwitchTunnelMissingActiveTunnelFromSettingsShowsRefreshGuidanceAndClearsCardWarning() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [
            TestFixtures.client("c1", regionId: "us-sanjose-1"),
            TestFixtures.client("c2", regionId: "us-sanjose-1"),
        ]
        let tunnelManager = FakeTunnelManager()
        await tunnelManager.setStatus(.connected, for: "c1")
        await tunnelManager.setStatus(.disconnected, for: "c2")
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(snapshots: [
                    TestFixtures.snapshot("c1", regionId: "us-sanjose-1"),
                    TestFixtures.snapshot("c2", regionId: "us-sanjose-1"),
                ]),
                secretStore: FakeConfigSecretStore()
            )
        )

        await viewModel.refresh()
        guard let activeOption = viewModel.filteredClientOptions.first(where: { $0.client.clientId == "c1" }),
              let nextOption = viewModel.filteredClientOptions.first(where: { $0.client.clientId == "c2" }) else {
            XCTFail("Expected installed client options.")
            return
        }
        XCTAssertTrue(viewModel.isInstalled(activeOption))
        XCTAssertTrue(viewModel.isInstalled(nextOption))

        await tunnelManager.setStatus(nil, for: "c1")
        await tunnelManager.setStopError(CloudGatewayVPNError.missingInstalledTunnel)
        await viewModel.switchTunnel(to: nextOption)

        XCTAssertEqual(
            viewModel.errorText,
            "The VPN profile is no longer installed on this device. Refresh, then you can install the config again."
        )
        XCTAssertFalse(viewModel.isInstalled(activeOption))
        XCTAssertTrue(viewModel.isInstalled(nextOption))
        XCTAssertNil(viewModel.staleText(for: activeOption))
    }

    func testSwitchTunnelMissingTargetTunnelFromSettingsShowsRefreshGuidanceAndClearsCardWarning() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [
            TestFixtures.client("c1", regionId: "us-sanjose-1"),
            TestFixtures.client("c2", regionId: "us-sanjose-1"),
        ]
        let tunnelManager = FakeTunnelManager()
        await tunnelManager.setStatus(.connected, for: "c1")
        await tunnelManager.setStatus(.disconnected, for: "c2")
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(snapshots: [
                    TestFixtures.snapshot("c1", regionId: "us-sanjose-1"),
                    TestFixtures.snapshot("c2", regionId: "us-sanjose-1"),
                ]),
                secretStore: FakeConfigSecretStore()
            )
        )

        await viewModel.refresh()
        guard let activeOption = viewModel.filteredClientOptions.first(where: { $0.client.clientId == "c1" }),
              let nextOption = viewModel.filteredClientOptions.first(where: { $0.client.clientId == "c2" }) else {
            XCTFail("Expected installed client options.")
            return
        }
        XCTAssertTrue(viewModel.isInstalled(activeOption))
        XCTAssertTrue(viewModel.isInstalled(nextOption))

        await tunnelManager.setStatus(nil, for: "c2")
        await tunnelManager.setStartError(CloudGatewayVPNError.missingInstalledTunnel)
        await viewModel.switchTunnel(to: nextOption)

        XCTAssertEqual(
            viewModel.errorText,
            "The VPN profile is no longer installed on this device. Refresh, then you can install the config again."
        )
        XCTAssertTrue(viewModel.isInstalled(activeOption))
        XCTAssertFalse(viewModel.isInstalled(nextOption))
        XCTAssertNil(viewModel.staleText(for: nextOption))
    }

    func testConnectingClientCountsAsActiveTunnel() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let viewModel = makeViewModel(
            service,
            installedSnapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")],
            tunnelStatus: .connecting
        )

        await viewModel.refresh()

        // A still-connecting client must be treated as the active tunnel so that
        // switching to another client stops it first on this single-tunnel provider.
        XCTAssertEqual(viewModel.activeTunnelClient?.client.clientId, "c1")
    }

    // MARK: - Create flow

    func testCreateClientResetsNameAndReloads() async {
        let service = signedInService()
        service.enabledRegions = [
            TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))
        ]
        let viewModel = makeViewModel(service)
        await viewModel.refresh()

        viewModel.newClientName = "  Laptop  "
        await viewModel.createClient()

        XCTAssertEqual(service.createClientCallCount, 1)
        XCTAssertEqual(service.createClientName, "Laptop")
        XCTAssertEqual(viewModel.newClientName, "")
        XCTAssertNil(viewModel.errorText)
        // The created client is merged in ahead of the (here empty) fetched list, so it
        // must remain visible after the reload - guards mergeClients' existing-override.
        XCTAssertTrue(viewModel.filteredClientOptions.contains { $0.client.clientId == "created-1" })
        XCTAssertEqual(viewModel.successText, "Laptop was created.")
    }

    func testInstallFromCloudReloadsRemoteStateBeforeInstall() async {
        let service = signedInService()
        service.enabledRegions = [
            TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))
        ]
        service.ownedClients = [TestFixtures.client("phone", regionId: "us-sanjose-1")]
        let viewModel = makeViewModel(service)
        await viewModel.refresh()

        guard let staleOption = viewModel.filteredClientOptions.first else {
            XCTFail("Expected a client option.")
            return
        }

        service.ownedClients = [
            CloudGatewayClient(
                clientId: "phone",
                clientName: "Renamed phone",
                regionId: "us-sanjose-1",
                status: .active,
                wireGuardConfig: TestFixtures.usableConfig + "\n# refreshed",
                ownerUid: "u1",
                ownerEmail: "a@b.com"
            )
        ]

        await viewModel.installFromCloud(staleOption)

        XCTAssertEqual(service.fetchOwnedClientsCallCount, 2)
        XCTAssertEqual(viewModel.installedSnapshots.first?.clientName, "Renamed phone")
        XCTAssertNil(viewModel.successText)
    }

    func testCreateClientRequiresDisplayNameBeforeServiceCall() async {
        let service = signedInService()
        service.enabledRegions = [
            TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))
        ]
        let viewModel = makeViewModel(service)
        await viewModel.refresh()

        viewModel.newClientName = "   "
        await viewModel.createClient()

        XCTAssertEqual(service.createClientCallCount, 0)
        XCTAssertNotNil(viewModel.errorText)
        XCTAssertTrue(viewModel.createDisabled)
    }

    func testDismissMessagesClearsErrorAndSuccess() async {
        let service = signedInService()
        service.enabledRegions = [
            TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))
        ]
        let viewModel = makeViewModel(service)
        await viewModel.refresh()

        viewModel.newClientName = "Phone"
        await viewModel.createClient()
        XCTAssertNotNil(viewModel.successText)

        service.createClientError = CloudGatewayAppError.invalidAPIResponse
        viewModel.newClientName = "Laptop"
        await viewModel.createClient()
        XCTAssertNotNil(viewModel.errorText)

        viewModel.dismissMessages()

        XCTAssertNil(viewModel.errorText)
        XCTAssertNil(viewModel.successText)
    }

    func testDeleteDisabledForRemovedClients() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let viewModel = makeViewModel(service)
        let option = CloudGatewayClientOption(
            client: TestFixtures.client("removed-1", regionId: "us-sanjose-1", status: .removed),
            region: TestFixtures.region("us-sanjose-1")
        )

        await viewModel.refresh()

        XCTAssertTrue(viewModel.deleteDisabled(for: option))
    }

    func testDeleteAccountReauthenticatesAndForcesFreshToken() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let viewModel = makeViewModel(service)
        viewModel.deleteAccountPassword = " password "

        await viewModel.deleteAccountWithPassword()

        XCTAssertEqual(service.reauthenticateWithPasswordCallCount, 1)
        // The password is passed through verbatim, never trimmed.
        XCTAssertEqual(service.reauthenticatePassword, " password ")
        XCTAssertEqual(service.idTokenForceRefreshValues, [true])
        XCTAssertEqual(service.deleteAccountCallCount, 1)
        XCTAssertEqual(service.signOutCallCount, 1)
        XCTAssertEqual(viewModel.deleteAccountPassword, "")
        XCTAssertEqual(viewModel.appMode, .guest)
        XCTAssertFalse(viewModel.isSignedIn)
    }

    func testDeleteAccountCannotTargetReplacementUserAfterReauthentication() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let reauthGate = AsyncTestGate()
        service.reauthenticateWithPasswordGate = reauthGate
        let viewModel = makeViewModel(service)
        await viewModel.refresh()
        viewModel.deleteAccountPassword = "password"

        let staleDeletion = Task { await viewModel.deleteAccountWithPassword() }
        await waitUntil { service.reauthenticateWithPasswordCallCount == 1 }
        service.emitAuthState(AuthenticatedUser(uid: "u2", email: "b@example.com"))
        await waitUntil { viewModel.signedInUid == "u2" }
        await reauthGate.open()
        await staleDeletion.value
        await waitUntil { !viewModel.isWorking && viewModel.signedInUid == "u2" }

        // The aborted deletion must never fetch a fresh (forceRefresh) delete
        // token; the replacement user's own reload may still fetch a normal token.
        XCTAssertFalse(service.idTokenForceRefreshValues.contains(true))
        XCTAssertEqual(service.deleteAccountCallCount, 0)
        XCTAssertEqual(service.signOutCallCount, 0)
        XCTAssertEqual(service.currentUser?.uid, "u2")
    }

    // MARK: - Mid-operation user-swap races

    func testCreateClientCannotPublishStaleClientUnderReplacementUser() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))]
        let viewModel = makeViewModel(service)
        await viewModel.refresh()
        viewModel.newClientName = "Phone"
        let createGate = AsyncTestGate()
        service.createClientGate = createGate

        let staleCreate = Task { await viewModel.createClient() }
        await waitUntil { service.createClientCallCount == 1 }
        service.emitAuthState(AuthenticatedUser(uid: "u2", email: "b@example.com"))
        await waitUntil { viewModel.signedInUid == "u2" }
        await createGate.open()
        await staleCreate.value
        await waitUntil { !viewModel.isWorking && viewModel.signedInUid == "u2" }

        XCTAssertNil(viewModel.successText)
        XCTAssertEqual(viewModel.signedInEmail, "b@example.com")
        XCTAssertFalse(viewModel.clientOptions.map(\.client.clientId).contains("created-1"))
    }

    // Mirrors the stale-swap fences above (createClient/deleteClient/installFromCloud)
    // but drives the offline path instead of a plain gate: the post-create reload goes
    // offline and falls into loadRemoteStateMarkingUnavailable/applyRemoteRefreshUnavailable,
    // which re-reads the local cache. A user swap arriving while that offline path is
    // paused on the cache read must stop it from publishing u1's stale offline fallback
    // (and the flag that marks it) under u2's session.
    func testCreateClientOfflineReloadCannotApplyStaleOfflineStateUnderReplacementUser() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1", capacity: .known(limit: 10, allocated: 1))]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let cache = FakeConfigCache(snapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")])
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                // A status fallback so c1 (and any other cached snapshot) reads as
                // installed; otherwise refreshStatus prunes it from installedSnapshots
                // immediately and the fence has nothing to protect.
                tunnelManager: FakeTunnelManager(status: .disconnected),
                cache: cache,
                secretStore: FakeConfigSecretStore()
            )
        )
        await viewModel.refresh()
        viewModel.newClientName = "Phone"
        let loadCountBeforeCreate = await cache.loadRequests()

        // The create call itself succeeds; it's the reload after it that goes offline.
        // Keep fetchRegionsError active permanently (never reset it below) so u2's own
        // auto-refresh also goes offline instead of succeeding and overwriting whatever
        // u1's fenced (or unfenced) write left behind - that overwrite is what let the
        // old version of this test pass even with the fence deleted.
        service.fetchRegionsError = URLError(.notConnectedToInternet)
        let cacheGate = AsyncTestGate()
        await cache.setLoadGate(cacheGate)
        let staleCreate = Task { await viewModel.createClient() }
        await waitUntil { service.createClientCallCount == 1 }
        // Paused inside applyRemoteRefreshUnavailable's configManager.loadLocalState();
        // FakeConfigCache.load() has already captured u1's local cache (c1 installed)
        // before it started waiting on the gate.
        await waitForCacheLoads(cache, count: loadCountBeforeCreate + 1)

        // u2's own local cache has no installed configs (a genuinely distinct local
        // state, not a rename of u1's). This is safe to set while u1's read is
        // paused because that read already captured its own snapshot above; only
        // reads that start after this point observe the new value.
        await cache.setSnapshots([])
        service.ownedClients = [TestFixtures.client("user-b-client", regionId: "us-sanjose-1")]
        service.emitAuthState(AuthenticatedUser(uid: "u2", email: "b@example.com"))
        await waitUntil { viewModel.signedInUid == "u2" }

        await cacheGate.open()
        await staleCreate.value
        // Wait for u2's own offline fallback to actually finish (not just for
        // isWorking to have blipped false between u1's task ending and u2's own
        // reload starting): remoteRefreshUnavailable only flips true once some
        // applyRemoteRefreshUnavailable call has reached apply(), which - given
        // u2's auto-refresh is also offline - only happens once u2's own run
        // completes.
        await waitUntil {
            !viewModel.isWorking && viewModel.signedInUid == "u2" && viewModel.remoteRefreshUnavailable
        }

        XCTAssertNil(viewModel.successText)
        XCTAssertEqual(viewModel.signedInEmail, "b@example.com")
        // u2's own offline fallback ran (its auto-refresh is offline too), so this
        // is expected regardless of the fence - it is not what this test proves.
        XCTAssertTrue(viewModel.remoteRefreshUnavailable)
        // u2 genuinely has nothing installed locally. If u1's fenced write ever
        // reached configManager.markRemoteRefreshUnavailable() with u1's stale
        // (c1-installed) local state, it would stamp a stale-offline label for c1
        // into the shared config-manager state; that label would survive u2's own
        // (empty-cache) offline fallback, since markRemoteRefreshUnavailable only
        // adds labels for currently-installed snapshots and never clears stale
        // ones for snapshots that vanished. So c1 carrying a stale label here can
        // only happen if the fence failed to stop u1's write.
        XCTAssertTrue(viewModel.installedSnapshots.isEmpty)
        let c1Option = CloudGatewayClientOption(
            client: TestFixtures.client("c1", regionId: "us-sanjose-1"),
            region: TestFixtures.region("us-sanjose-1")
        )
        XCTAssertNil(viewModel.staleText(for: c1Option))
    }

    func testDeleteClientCannotRemoveProfileUnderReplacementUser() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let viewModel = makeViewModel(
            service,
            installedSnapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")],
            tunnelStatus: .disconnected
        )
        await viewModel.refresh()
        guard let option = viewModel.clientOptions.first(where: { $0.client.clientId == "c1" }) else {
            XCTFail("expected an installed c1 option")
            return
        }
        let deleteGate = AsyncTestGate()
        service.deleteClientGate = deleteGate

        let staleDelete = Task { await viewModel.deleteClient(option) }
        await waitUntil { service.deleteClientCallCount == 1 }
        service.emitAuthState(AuthenticatedUser(uid: "u2", email: "b@example.com"))
        await waitUntil { viewModel.signedInUid == "u2" }
        await deleteGate.open()
        await staleDelete.value
        await waitUntil { !viewModel.isWorking && viewModel.signedInUid == "u2" }

        XCTAssertNil(viewModel.successText)
        // The gated delete captured c1, but the fence must stop the config removal
        // from applying, so the installed profile survives under the new session.
        XCTAssertEqual(service.deleteClientClientId, "c1")
        XCTAssertTrue(viewModel.installedSnapshots.map(\.clientId).contains("c1"))
    }

    func testGrantAccessCannotPublishStaleSuccessUnderReplacementUser() async {
        let service = signedInAdminService()
        let viewModel = makeViewModel(service)
        await viewModel.refresh()
        viewModel.newAccessEmail = "new@example.com"
        let grantGate = AsyncTestGate()
        service.grantAccessGate = grantGate

        let staleGrant = Task { await viewModel.grantAccess() }
        await waitUntil { service.grantAccessCallCount == 1 }
        service.emitAuthState(AuthenticatedUser(uid: "u2", email: "b@example.com"))
        await waitUntil { viewModel.signedInUid == "u2" }
        await grantGate.open()
        await staleGrant.value
        await waitUntil { !viewModel.isWorking && viewModel.signedInUid == "u2" }

        XCTAssertNil(viewModel.successText)
        XCTAssertEqual(viewModel.signedInEmail, "b@example.com")
    }

    func testInstallFromCloudCannotApplyStaleInstallUnderReplacementUser() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let tunnelManager = FakeTunnelManager()
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(),
                secretStore: FakeConfigSecretStore()
            )
        )
        await viewModel.refresh()
        guard let option = viewModel.clientOptions.first(where: { $0.client.clientId == "c1" }) else {
            XCTFail("expected a usable c1 option")
            return
        }
        let installGate = AsyncTestGate()
        await tunnelManager.setInstallGate(installGate)

        let staleInstall = Task { await viewModel.installFromCloud(option) }
        var installRequestsSeen = false
        for _ in 0..<1_000 {
            if await tunnelManager.installRequests() >= 1 {
                installRequestsSeen = true
                break
            }
            await Task.yield()
        }
        if !installRequestsSeen {
            XCTFail("timed out waiting for install request")
        }
        // Gate the replacement user's own reload so it cannot overwrite the state
        // we are asserting on before we open the install gate.
        let replacementRefreshGate = AsyncTestGate()
        service.fetchRegionsGate = replacementRefreshGate
        service.emitAuthState(AuthenticatedUser(uid: "u2", email: "b@example.com"))
        await waitUntil { viewModel.signedInUid == "u2" }
        await installGate.open()
        await staleInstall.value
        // Wait until the replacement user's reload is parked at its region fetch.
        await waitUntil { service.fetchRegionsCallCount == 3 }

        // The stale install completed on-device, but the fence must stop its local
        // result from being selected/applied under the replacement session.
        XCTAssertTrue(viewModel.installedSnapshots.isEmpty)
        XCTAssertNil(viewModel.selectedClientId)

        await replacementRefreshGate.open()
        await waitUntil { !viewModel.isWorking && viewModel.signedInUid == "u2" }
    }

    func testAccountDeleteCleanupProceedsWhenCurrentUserBecomesNil() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        let viewModel = makeViewModel(
            service,
            installedSnapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")],
            tunnelStatus: .disconnected
        )
        await viewModel.refresh()
        await waitUntil { viewModel.installedSnapshots.map(\.clientId) == ["c1"] }
        viewModel.deleteAccountPassword = "password"

        await viewModel.deleteAccountWithPassword()

        // deleteAccount drops the current user to nil server-side; the nil branch of
        // ensureNoReplacementUser must still let local profile cleanup finish.
        XCTAssertEqual(service.deleteAccountCallCount, 1)
        XCTAssertEqual(service.signOutCallCount, 1)
        XCTAssertEqual(viewModel.appMode, .guest)
        XCTAssertTrue(viewModel.installedSnapshots.isEmpty)
    }

    func testAccountDeleteCleanupAbortsWhenReplacementUserAppears() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.deleteAccountClearsCurrentUser = false
        let viewModel = makeViewModel(
            service,
            installedSnapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")],
            tunnelStatus: .disconnected
        )
        await viewModel.refresh()
        await waitUntil { viewModel.installedSnapshots.map(\.clientId) == ["c1"] }
        viewModel.deleteAccountPassword = "password"
        let deleteGate = AsyncTestGate()
        service.deleteAccountGate = deleteGate

        let staleDelete = Task { await viewModel.deleteAccountWithPassword() }
        await waitUntil { service.deleteAccountCallCount == 1 }
        service.emitAuthState(AuthenticatedUser(uid: "u2", email: "b@example.com"))
        await waitUntil { viewModel.signedInUid == "u2" }
        await deleteGate.open()
        await staleDelete.value
        await waitUntil { !viewModel.isWorking && viewModel.signedInUid == "u2" }

        // A replacement user (not nil) must abort the post-deletion cleanup: the
        // stale flow must not remove the new session's profile or sign it out.
        XCTAssertEqual(service.signOutCallCount, 0)
        XCTAssertEqual(service.currentUser?.uid, "u2")
        XCTAssertTrue(viewModel.installedSnapshots.map(\.clientId).contains("c1"))
    }

    func testDeferredAuthReloadRunsOnceAndSkipsWhenUserUnchanged() async {
        let service = signedInAdminService()
        let viewModel = makeViewModel(service)
        await viewModel.refresh()
        let baselineFetches = service.fetchRegionsCallCount

        // Re-emitting the current signed-in user must not trigger another reload.
        service.emitAuthState(AuthenticatedUser(uid: "u1", email: "a@b.com"))
        await waitUntil { !viewModel.isWorking }
        XCTAssertEqual(service.fetchRegionsCallCount, baselineFetches)

        // A swap while work is in-flight defers exactly one reload for the new
        // user, fired once the in-flight operation completes (no busy-polling).
        let syncGate = AsyncTestGate()
        service.syncRegionGate = syncGate
        let staleSync = Task { await viewModel.syncSelectedRegion() }
        await waitUntil { service.syncRegionCallCount == 1 }
        service.emitAuthState(AuthenticatedUser(uid: "u2", email: "b@example.com"))
        await waitUntil { viewModel.signedInUid == "u2" }
        await syncGate.open()
        await staleSync.value
        await waitUntil { !viewModel.isWorking && viewModel.signedInUid == "u2" }

        XCTAssertEqual(service.fetchRegionsCallCount, baselineFetches + 1)
    }

    // MARK: - Role resolution

    func testRoleFallsBackToAccessRoleWhenFirestoreRoleUnavailable() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.userRole = nil            // Firestore lookup yields nothing
        service.accessRole = "admin"      // API access-check role is authoritative fallback
        let viewModel = makeViewModel(service)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.role, "admin")
        XCTAssertTrue(viewModel.canSyncSelectedRegion)
    }

    func testFirestoreRoleOverridesAccessRole() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.userRole = "user"
        service.accessRole = "admin"
        let viewModel = makeViewModel(service)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.role, "user")
        XCTAssertFalse(viewModel.canSyncSelectedRegion)
    }

    // MARK: - Runtime configuration

    func testKeychainAccessGroupResolverAcceptsExpandedValue() throws {
        let accessGroup = try CloudGatewayRuntimeConfiguration.keychainAccessGroup(
            "CRQWDQ7QQR.com.gocloudlaunch.gateway"
        )

        XCTAssertEqual(accessGroup, "CRQWDQ7QQR.com.gocloudlaunch.gateway")
    }

    func testKeychainAccessGroupResolverRejectsMissingEmptyAndUnexpandedValues() {
        XCTAssertThrowsError(try CloudGatewayRuntimeConfiguration.keychainAccessGroup(nil))
        XCTAssertThrowsError(try CloudGatewayRuntimeConfiguration.keychainAccessGroup(""))
        XCTAssertThrowsError(try CloudGatewayRuntimeConfiguration.keychainAccessGroup("$(CLOUDGATEWAY_KEYCHAIN_ACCESS_GROUP)"))
    }

    func testRegionalAPIURLBuilderNormalizesAndRejectsInvalidRegionIds() throws {
        let url = try CloudGatewayAPIURLBuilder.regionalAPIURL(
            originHost: "gocloudlaunch.com",
            regionId: " WWW.US-SANJOSE-1 ",
            path: "/clients/"
        )

        XCTAssertEqual(url.absoluteString, "https://us-sanjose-1.gocloudlaunch.com/api/clients")
        XCTAssertThrowsError(try CloudGatewayAPIURLBuilder.regionalAPIURL(
            originHost: "gocloudlaunch.com",
            regionId: "us east",
            path: "clients"
        ))
        XCTAssertThrowsError(try CloudGatewayAPIURLBuilder.regionalAPIURL(
            originHost: "gocloudlaunch.com",
            regionId: "a/b",
            path: "clients"
        ))
        XCTAssertThrowsError(try CloudGatewayAPIURLBuilder.regionalAPIURL(
            originHost: "gocloudlaunch.com",
            regionId: "us-sanjose-1.gocloudlaunch.com",
            path: "clients"
        ))
    }

    func testValidatedClientIdAcceptsSafeCharsetAndRejectsPathInjection() throws {
        XCTAssertEqual(try CloudGatewayAPIURLBuilder.validatedClientId("Client_123-abc"), "Client_123-abc")

        for unsafe in ["a/b", "../account", "id?x=1", "id#frag", "has space", ""] {
            XCTAssertThrowsError(try CloudGatewayAPIURLBuilder.validatedClientId(unsafe))
        }
    }

    // MARK: - Remote warning scope

    func testLocalTunnelFailureDoesNotMarkInstalledConfigStale() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let tunnelManager = FakeTunnelManager()
        await tunnelManager.setStatus(.disconnected, for: "c1")
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(snapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")]),
                secretStore: FakeConfigSecretStore()
            )
        )

        await viewModel.refresh()
        guard let option = viewModel.filteredClientOptions.first else {
            XCTFail("Expected an installed client option.")
            return
        }

        await tunnelManager.setStartError(CloudGatewayAppError.accessDenied("Local VPN failure."))
        await viewModel.startTunnel(for: option)

        XCTAssertEqual(viewModel.errorText, "Local VPN failure.")
        XCTAssertNil(viewModel.staleText(for: option))
    }

    func testRemoteRefreshFailureMarksInstalledConfigStale() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let viewModel = makeViewModel(
            service,
            installedSnapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")],
            tunnelStatus: .disconnected
        )

        await viewModel.refresh()
        guard let option = viewModel.filteredClientOptions.first else {
            XCTFail("Expected an installed client option.")
            return
        }

        service.fetchRegionsError = CloudGatewayAppError.invalidAPIResponse
        await viewModel.refresh()

        XCTAssertNotNil(viewModel.staleText(for: option))
    }

    func testOfflineColdLaunchSurfacesCachedInstalledConfigAsToggleableRow() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        // No prior successful load: the remote list is never populated.
        service.fetchRegionsError = URLError(.notConnectedToInternet)
        let viewModel = makeViewModel(
            service,
            installedSnapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")],
            tunnelStatus: .connected
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.appMode, .signedIn)
        XCTAssertEqual(viewModel.regions.map(\.regionId), ["us-sanjose-1"])
        XCTAssertEqual(viewModel.selectedRegionId, "us-sanjose-1")
        XCTAssertTrue(viewModel.isUsingOfflineRegionFallback)
        // The remote client list is empty offline, but the cached install still shows.
        XCTAssertTrue(viewModel.filteredClientOptions.isEmpty)
        guard let row = viewModel.displayedClientOptions.first(where: { $0.client.clientId == "c1" }) else {
            XCTFail("Expected the cached installed config to surface as a row.")
            return
        }
        XCTAssertEqual(viewModel.displayedClientOptions.count, 1)
        XCTAssertNil(row.client.wireGuardConfig)
        XCTAssertTrue(viewModel.isInstalled(row))
        // Not a spurious "Update Available" for a config we cannot diff offline.
        XCTAssertNil(viewModel.installStateLabel(for: row))
        // The running tunnel is visible and controllable without connectivity.
        XCTAssertTrue(viewModel.toggleIsOn(for: row))
        XCTAssertFalse(viewModel.toggleDisabled(for: row))

        await viewModel.stopTunnel(for: row)

        XCTAssertFalse(viewModel.toggleIsOn(for: row))
        XCTAssertTrue(viewModel.displayedClientOptions.contains { $0.client.clientId == "c1" })
    }

    func testOfflineRegionSelectionKeepsSelectedClientInSelectedRegion() async {
        let service = signedInService()
        service.fetchRegionsError = URLError(.notConnectedToInternet)
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: FakeTunnelManager(status: .disconnected),
                cache: FakeConfigCache(snapshots: [
                    TestFixtures.snapshot("california-client", regionId: "us-sanjose-1"),
                    TestFixtures.snapshot("chicago-client", regionId: "us-chicago-1"),
                ]),
                secretStore: FakeConfigSecretStore()
            )
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.selectedRegionId, "us-chicago-1")
        XCTAssertEqual(viewModel.selectedClientId, "chicago-client")

        viewModel.selectRegion("us-sanjose-1")

        XCTAssertEqual(viewModel.selectedClientId, "california-client")
        XCTAssertEqual(viewModel.displayedClientOptions.map(\.client.clientId), ["california-client"])
    }

    func testOfflineCachedActiveTunnelIsStoppedBeforeStartingAnotherCachedTunnel() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        service.fetchRegionsError = URLError(.notConnectedToInternet)
        let tunnelManager = FakeTunnelManager()
        await tunnelManager.setStatus(.connected, for: "c1")
        await tunnelManager.setStatus(.disconnected, for: "c2")
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(snapshots: [
                    TestFixtures.snapshot("c1", regionId: "us-sanjose-1"),
                    TestFixtures.snapshot("c2", regionId: "us-sanjose-1"),
                ]),
                secretStore: FakeConfigSecretStore()
            )
        )

        await viewModel.refresh()
        guard let nextRow = viewModel.displayedClientOptions.first(where: { $0.client.clientId == "c2" }) else {
            XCTFail("Expected the second cached config to surface as a row.")
            return
        }

        XCTAssertEqual(viewModel.activeTunnelClient?.client.clientId, "c1")

        await viewModel.switchTunnel(to: nextRow)

        let stopRequests = await tunnelManager.stopRequests()
        XCTAssertEqual(stopRequests, ["c1"])
        XCTAssertTrue(viewModel.toggleIsOn(for: nextRow))
    }

    func testOfflineCachedActiveTunnelIsFoundAcrossRegionsBeforeSwitching() async {
        let service = signedInService()
        service.enabledRegions = [
            TestFixtures.region("us-sanjose-1"),
            TestFixtures.region("us-ashburn-1"),
        ]
        service.fetchRegionsError = URLError(.notConnectedToInternet)
        let tunnelManager = FakeTunnelManager()
        await tunnelManager.setStatus(.connected, for: "c1")
        await tunnelManager.setStatus(.disconnected, for: "c2")
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: tunnelManager,
                cache: FakeConfigCache(snapshots: [
                    TestFixtures.snapshot("c1", regionId: "us-sanjose-1"),
                    TestFixtures.snapshot("c2", regionId: "us-ashburn-1"),
                ]),
                secretStore: FakeConfigSecretStore()
            )
        )

        await viewModel.refresh()
        viewModel.selectedRegionId = "us-ashburn-1"
        guard let nextRow = viewModel.displayedClientOptions.first(where: { $0.client.clientId == "c2" }) else {
            XCTFail("Expected the second region's cached config to surface as a row.")
            return
        }

        XCTAssertEqual(viewModel.activeTunnelClient?.client.clientId, "c1")

        await viewModel.switchTunnel(to: nextRow)

        let stopRequests = await tunnelManager.stopRequests()
        XCTAssertEqual(stopRequests, ["c1"])
        XCTAssertTrue(viewModel.toggleIsOn(for: nextRow))
    }

    func testCachedInstalledConfigDoesNotLeakIntoOtherRegions() async {
        let service = signedInService()
        service.enabledRegions = [
            TestFixtures.region("us-sanjose-1", displayOrder: 10),
            TestFixtures.region("us-ashburn-1", displayOrder: 20),
        ]
        service.ownedClients = [TestFixtures.client("c1", regionId: "us-sanjose-1")]
        let viewModel = makeViewModel(
            service,
            installedSnapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")],
            tunnelStatus: .disconnected
        )

        await viewModel.refresh()
        // Switch to a region that holds none of the user's clients.
        viewModel.selectedRegionId = "us-ashburn-1"

        XCTAssertTrue(viewModel.displayedClientOptions.isEmpty)
    }

    func testCachedInstalledConfigDoesNotGhostWhenOnlineAndClientRemovedRemotely() async {
        let service = signedInService()
        service.enabledRegions = [TestFixtures.region("us-sanjose-1")]
        // Remote refresh succeeds but the client is gone (deleted/revoked); only
        // the stale local install snapshot remains.
        service.ownedClients = []
        let viewModel = makeViewModel(
            service,
            installedSnapshots: [TestFixtures.snapshot("c1", regionId: "us-sanjose-1")],
            tunnelStatus: .disconnected
        )

        await viewModel.refresh()

        // Online and refresh succeeded, so the removed client must not linger.
        XCTAssertFalse(viewModel.remoteRefreshUnavailable)
        XCTAssertTrue(viewModel.displayedClientOptions.isEmpty)
    }
}

private final class WeakBox<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private final class FakeNotificationAuthorizer: CloudGatewayNotificationAuthorizing {
    private(set) var authorizationRequestCount = 0
    private(set) var undeterminedAuthorizationRequestCount = 0

    func requestAuthorization() {
        authorizationRequestCount += 1
    }

    func requestAuthorizationIfUndetermined() {
        undeterminedAuthorizationRequestCount += 1
    }
}
