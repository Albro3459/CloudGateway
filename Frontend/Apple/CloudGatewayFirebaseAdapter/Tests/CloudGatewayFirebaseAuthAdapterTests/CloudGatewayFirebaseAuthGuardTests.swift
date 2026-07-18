import CloudGatewayAppCore
import Foundation
import Testing
@testable import CloudGatewayFirebaseAuthAdapter

// Drives the mid-flight user-swap guard directly at the adapter boundary via the
// internal `CloudGatewayFirebaseGuardedUser` seam, so the guard is proven without
// a live `FirebaseAuth.Auth`. The facade tests only exercise a re-implemented
// guard in a fake, which left the adapter's own guard unverified.

private let googleCredentials = CloudGatewayGoogleCredentials(idToken: "tok", accessToken: "acc")

@MainActor
private final class FakeGuardedUser: CloudGatewayFirebaseGuardedUser {
    let uid: String
    var linkError: Error?
    var reauthError: Error?
    private(set) var linkCallCount = 0
    private(set) var reauthCallCount = 0
    let linkResult: AuthenticatedUser

    init(uid: String) {
        self.uid = uid
        linkResult = AuthenticatedUser(uid: uid, email: "google@example.com")
    }

    func linkGoogle(_ credentials: CloudGatewayGoogleCredentials) async throws -> AuthenticatedUser {
        linkCallCount += 1
        if let linkError { throw linkError }
        return linkResult
    }

    func reauthenticateGoogle(_ credentials: CloudGatewayGoogleCredentials) async throws {
        reauthCallCount += 1
        if let reauthError { throw reauthError }
    }
}

@MainActor
@Test func guardedLinkGoogleProceedsWhenExpectedUserMatches() async throws {
    let user = FakeGuardedUser(uid: "u1")

    let result = try await CloudGatewayFirebaseAuthAdapter.guardedLinkGoogle(
        currentUser: user,
        credentials: googleCredentials,
        expectedUserId: "u1"
    )

    #expect(result == user.linkResult)
    #expect(user.linkCallCount == 1)
}

@MainActor
@Test func guardedLinkGoogleRejectsSwappedUserWithoutLinking() async {
    let user = FakeGuardedUser(uid: "u2")

    await #expect(throws: CancellationError.self) {
        _ = try await CloudGatewayFirebaseAuthAdapter.guardedLinkGoogle(
            currentUser: user,
            credentials: googleCredentials,
            expectedUserId: "u1"
        )
    }
    #expect(user.linkCallCount == 0)
}

@MainActor
@Test func guardedLinkGoogleReportsMissingCurrentUser() async {
    await expectMissingCurrentUser {
        _ = try await CloudGatewayFirebaseAuthAdapter.guardedLinkGoogle(
            currentUser: nil,
            credentials: googleCredentials,
            expectedUserId: "u1"
        )
    }
}

@MainActor
@Test func guardedLinkGoogleMapsFirebaseLinkErrors() async {
    let user = FakeGuardedUser(uid: "u1")
    user.linkError = NSError(domain: "FIRAuthErrorDomain", code: 17015)

    do {
        _ = try await CloudGatewayFirebaseAuthAdapter.guardedLinkGoogle(
            currentUser: user,
            credentials: googleCredentials,
            expectedUserId: "u1"
        )
        Issue.record("expected providerAlreadyLinked")
    } catch let error as CloudGatewayAppError {
        guard case .providerAlreadyLinked = error else {
            Issue.record("unexpected CloudGatewayAppError: \(error)")
            return
        }
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(user.linkCallCount == 1)
}

@MainActor
@Test func guardedReauthenticateGoogleProceedsWhenExpectedUserMatches() async throws {
    let user = FakeGuardedUser(uid: "u1")

    try await CloudGatewayFirebaseAuthAdapter.guardedReauthenticateGoogle(
        currentUser: user,
        credentials: googleCredentials,
        expectedUserId: "u1"
    )

    #expect(user.reauthCallCount == 1)
}

@MainActor
@Test func guardedReauthenticateGoogleRejectsSwappedUserWithoutReauthenticating() async {
    let user = FakeGuardedUser(uid: "u2")

    await #expect(throws: CancellationError.self) {
        try await CloudGatewayFirebaseAuthAdapter.guardedReauthenticateGoogle(
            currentUser: user,
            credentials: googleCredentials,
            expectedUserId: "u1"
        )
    }
    #expect(user.reauthCallCount == 0)
}

@MainActor
@Test func guardedReauthenticateGoogleReportsMissingCurrentUser() async {
    await expectMissingCurrentUser {
        try await CloudGatewayFirebaseAuthAdapter.guardedReauthenticateGoogle(
            currentUser: nil,
            credentials: googleCredentials,
            expectedUserId: "u1"
        )
    }
}

private func expectMissingCurrentUser(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("expected missingCurrentUser")
    } catch let error as CloudGatewayAppError {
        guard case .missingCurrentUser = error else {
            Issue.record("unexpected CloudGatewayAppError: \(error)")
            return
        }
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
