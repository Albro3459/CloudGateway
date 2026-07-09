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
        viewModel.email = "user@example.com"
        viewModel.password = "secret-password"
        await viewModel.install(option)

        XCTAssertEqual(viewModel.appMode, .signedIn)
        XCTAssertFalse(viewModel.installedSnapshots.isEmpty)
        XCTAssertNotNil(viewModel.visibleInstalledSnapshot)
        XCTAssertNotNil(viewModel.visibleTunnelStatus)

        await viewModel.signOut()

        XCTAssertEqual(viewModel.appMode, .guest)
        XCTAssertFalse(viewModel.isSignedIn)
        // Credentials are cleared on sign-out; the email is kept for convenience.
        XCTAssertEqual(viewModel.password, "")
        XCTAssertEqual(viewModel.email, "user@example.com")
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

    func testAdminDeleteUsesSelectedClientOwnerUid() async throws {
        let service = signedInAdminService()
        service.currentUser = AuthenticatedUser(uid: "admin-uid", email: "admin@example.com")
        service.ownedClients = [
            TestFixtures.client("theirs", regionId: "us-sanjose-1", ownerUid: "user-uid", ownerEmail: "user@example.com")
        ]
        let viewModel = makeViewModel(service)
        await viewModel.refresh()

        viewModel.selectedClientId = "theirs"
        let option = try XCTUnwrap(viewModel.selectedClientOption)
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
        await tunnelManager.setStartError(GatewayVPNError.missingInstalledTunnel)
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
        await tunnelManager.setStopError(GatewayVPNError.missingInstalledTunnel)
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
        await tunnelManager.setStopError(GatewayVPNError.missingInstalledTunnel)
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
        await tunnelManager.setStartError(GatewayVPNError.missingInstalledTunnel)
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
