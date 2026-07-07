import CloudGatewayKit
import XCTest

@MainActor
final class CloudGatewayViewModelTests: XCTestCase {
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
        tunnelStatus: GatewayTunnelStatus
    ) -> CloudGatewayViewModel {
        CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: FakeTunnelManager(status: tunnelStatus),
                cache: FakeConfigCache(snapshots: installedSnapshots),
                secretStore: FakeConfigSecretStore()
            )
        )
    }

    private func signedInService() -> MockGatewayService {
        let service = MockGatewayService()
        service.currentUser = AuthenticatedUser(uid: "u1", email: "a@b.com")
        return service
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
        viewModel.selectedClientId = option.client.clientId
        await viewModel.install(option)

        XCTAssertEqual(viewModel.appMode, .signedIn)
        XCTAssertFalse(viewModel.installedSnapshots.isEmpty)
        XCTAssertNotNil(viewModel.visibleInstalledSnapshot)
        XCTAssertNotNil(viewModel.visibleTunnelStatus)

        await viewModel.signOut()

        XCTAssertEqual(viewModel.appMode, .guest)
        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertFalse(viewModel.installedSnapshots.isEmpty)
        XCTAssertNil(viewModel.visibleInstalledSnapshot)
        XCTAssertNil(viewModel.visibleTunnelStatus)
        XCTAssertTrue(viewModel.startDisabled)
        XCTAssertTrue(viewModel.stopDisabled)
        XCTAssertTrue(viewModel.removeTunnelDisabled)
    }

    func testSignInMapsRawFirebaseCredentialErrorsToGenericMessage() async {
        XCTAssertEqual(
            CloudGatewayFirebaseAuthErrorCode.signInError(forRawCode: 17004)?.localizedDescription,
            "Invalid email or password."
        )

        let service = MockGatewayService()
        service.signInError = CloudGatewayFirebaseAuthErrorCode.signInError(forRawCode: 17004)
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

    func testAdminDeleteUsesSelectedClientOwnerUid() async {
        let service = signedInAdminService()
        service.currentUser = AuthenticatedUser(uid: "admin-uid", email: "admin@example.com")
        service.ownedClients = [
            TestFixtures.client("theirs", regionId: "us-sanjose-1", ownerUid: "user-uid", ownerEmail: "user@example.com")
        ]
        let viewModel = makeViewModel(service)
        await viewModel.refresh()

        viewModel.selectedClientId = "theirs"
        await viewModel.deleteSelectedClient()

        XCTAssertEqual(service.deleteClientCallCount, 1)
        XCTAssertEqual(service.deleteClientUserId, "user-uid")
    }

    func testSyncSelectedRegionCapturesResult() async {
        let service = signedInAdminService()
        let viewModel = makeViewModel(service)
        await viewModel.refresh()

        await viewModel.syncSelectedRegion()

        XCTAssertEqual(service.syncRegionCallCount, 1)
        XCTAssertEqual(viewModel.syncResult?.summary, "us-sanjose-1: +1 ~0 -0")
        XCTAssertEqual(viewModel.syncResult?.regionId, "us-sanjose-1")
        // logText now surfaces the API's peer-sync audit log verbatim.
        XCTAssertTrue(viewModel.syncResult?.logText.contains("CloudGateway peer sync audit log") == true)

        viewModel.dismissSyncResult()

        XCTAssertNil(viewModel.syncResult)
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

    func testLinkEmailPasswordTrimsInputsAndKeepsUserSignedIn() async {
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
        XCTAssertEqual(service.linkPassword, "password123")
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
        XCTAssertNotNil(viewModel.selectedClientOption)

        service.ownedClients = []
        await viewModel.refresh()

        XCTAssertNil(viewModel.selectedClientId)
        XCTAssertNil(viewModel.selectedClientOption)
    }

    func testInstalledMissingRemoteClientRemainsManageableAndCannotStart() async {
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
        XCTAssertNil(viewModel.selectedClientOption)
        XCTAssertEqual(viewModel.visibleInstalledSnapshot?.clientId, "c1")
        XCTAssertTrue(viewModel.startDisabled)
        XCTAssertFalse(viewModel.removeTunnelDisabled)
        XCTAssertNotNil(viewModel.staleText)
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
        // must remain visible after the reload — guards mergeClients' existing-override.
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
        XCTAssertEqual(service.reauthenticatePassword, "password")
        XCTAssertEqual(service.idTokenForceRefreshValues, [true])
        XCTAssertEqual(service.deleteAccountCallCount, 1)
        XCTAssertEqual(service.signOutCallCount, 1)
        XCTAssertEqual(viewModel.deleteAccountPassword, "")
        XCTAssertEqual(viewModel.appMode, .guest)
        XCTAssertFalse(viewModel.isSignedIn)
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
}
