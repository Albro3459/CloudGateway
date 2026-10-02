#if os(macOS)
import CloudGatewayAppCore
import Testing
@testable import CloudGatewayFirebaseAuthAdapter

@MainActor
private final class ExchangeMarker: CloudGatewayFirebaseExchangeMarker {
    var isUnsettled = false
}

@MainActor
private final class CustomTokenBackend: CloudGatewayFirebaseCustomTokenBackend {
    var currentUser: AuthenticatedUser?
    var shouldFailSignOut = false
    var signOutCount = 0
    var signInCount = 0
    var pending: CheckedContinuation<AuthenticatedUser, any Error>?

    func signIn(customToken _: String) async throws -> AuthenticatedUser {
        signInCount += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func complete() {
        let user = AuthenticatedUser(uid: "user-a", email: nil)
        currentUser = user
        let callback = pending
        pending = nil
        callback?.resume(returning: user)
    }

    func fail() {
        let callback = pending
        pending = nil
        callback?.resume(throwing: CloudGatewayDeviceAuthError.offline)
    }

    func signOut() throws {
        signOutCount += 1
        if shouldFailSignOut { throw CloudGatewayDeviceAuthError.unavailable }
        currentUser = nil
    }
}

@MainActor
private func waitForExchange(_ backend: CustomTokenBackend) async {
    for _ in 0..<1000 {
        if backend.pending != nil { return }
        await Task.yield()
    }
    #expect(backend.pending != nil)
}

@Test @MainActor func cancelledSDKExchangeCannotRestorePersistedUser() async throws {
    let backend = CustomTokenBackend()
    let marker = ExchangeMarker()
    let session = CloudGatewayFirebaseCustomTokenSession(backend: backend, marker: marker)
    let exchange = Task { try await session.signIn(customToken: "fixture-token") }
    await waitForExchange(backend)
    try session.signOut()
    #expect(session.currentUser == nil)
    #expect(session.isSettling)
    #expect(marker.isUnsettled)
    await #expect(throws: CloudGatewayDeviceAuthError.unavailable) {
        try await session.signIn(customToken: "second-token")
    }
    backend.complete()
    await #expect(throws: CancellationError.self) { try await exchange.value }
    #expect(backend.currentUser == nil)
    #expect(session.currentUser == nil)
    #expect(backend.signOutCount == 2)
    #expect(!session.isSettling)
    #expect(!marker.isUnsettled)
}

@Test @MainActor func taskCancellationAlsoCleansLateSDKUser() async throws {
    let backend = CustomTokenBackend()
    let session = CloudGatewayFirebaseCustomTokenSession(backend: backend, marker: ExchangeMarker())
    let exchange = Task { try await session.signIn(customToken: "fixture-token") }
    await waitForExchange(backend)
    exchange.cancel()
    backend.complete()
    await #expect(throws: CancellationError.self) { try await exchange.value }
    #expect(backend.currentUser == nil)
    #expect(session.currentUser == nil)
}

@Test @MainActor func failedLateCleanupQuarantinesSessionUntilExplicitSignOut() async throws {
    let backend = CustomTokenBackend()
    let session = CloudGatewayFirebaseCustomTokenSession(backend: backend, marker: ExchangeMarker())
    let exchange = Task { try await session.signIn(customToken: "fixture-token") }
    await waitForExchange(backend)
    try session.cancel()
    backend.shouldFailSignOut = true
    backend.complete()
    await #expect(throws: CloudGatewayDeviceAuthError.unavailable) { try await exchange.value }
    #expect(backend.currentUser != nil)
    #expect(session.currentUser == nil)
    #expect(session.isSettling)
    await #expect(throws: CloudGatewayDeviceAuthError.unavailable) {
        try await session.signIn(customToken: "second-token")
    }
    backend.shouldFailSignOut = false
    try session.signOut()
    #expect(!session.isSettling)
    #expect(backend.currentUser == nil)
}

@Test @MainActor func successfulSDKExchangePublishesUserOnlyAfterSettlement() async throws {
    let backend = CustomTokenBackend()
    let session = CloudGatewayFirebaseCustomTokenSession(backend: backend, marker: ExchangeMarker())
    let exchange = Task { try await session.signIn(customToken: "fixture-token") }
    await waitForExchange(backend)
    #expect(session.currentUser == nil)
    backend.complete()
    let user = try await exchange.value
    #expect(session.currentUser == user)
    #expect(!session.isSettling)
    #expect(backend.signOutCount == 0)
}

@Test @MainActor func unsettledSDKExchangeIsCleanedBeforeSessionRestoration() {
    let backend = CustomTokenBackend()
    backend.currentUser = AuthenticatedUser(uid: "late-user", email: nil)
    let marker = ExchangeMarker()
    marker.isUnsettled = true
    let restored = CloudGatewayFirebaseCustomTokenSession(backend: backend, marker: marker)
    #expect(restored.currentUser == nil)
    #expect(backend.currentUser == nil)
    #expect(!marker.isUnsettled)
    #expect(!restored.isSettling)
}

@Test @MainActor func failedStartupCleanupRetainsMarkerAndHidesPersistedSession() {
    let backend = CustomTokenBackend()
    backend.currentUser = AuthenticatedUser(uid: "late-user", email: nil)
    backend.shouldFailSignOut = true
    let marker = ExchangeMarker()
    marker.isUnsettled = true
    let restored = CloudGatewayFirebaseCustomTokenSession(backend: backend, marker: marker)
    #expect(restored.currentUser == nil)
    #expect(marker.isUnsettled)
    #expect(restored.isSettling)
}

@Test @MainActor func failedSettledSessionSignOutStaysHiddenAcrossRelaunch() async throws {
    let backend = CustomTokenBackend()
    let marker = ExchangeMarker()
    let session = CloudGatewayFirebaseCustomTokenSession(backend: backend, marker: marker)
    let exchange = Task { try await session.signIn(customToken: "fixture-token") }
    await waitForExchange(backend)
    backend.complete()
    _ = try await exchange.value
    backend.shouldFailSignOut = true
    #expect(throws: CloudGatewayDeviceAuthError.unavailable) { try session.signOut() }
    #expect(backend.currentUser != nil)
    #expect(session.currentUser == nil)
    #expect(session.isSettling)
    #expect(marker.isUnsettled)
    let failedRestore = CloudGatewayFirebaseCustomTokenSession(backend: backend, marker: marker)
    #expect(failedRestore.currentUser == nil)
    #expect(marker.isUnsettled)
    backend.shouldFailSignOut = false
    let restored = CloudGatewayFirebaseCustomTokenSession(backend: backend, marker: marker)
    #expect(restored.currentUser == nil)
    #expect(backend.currentUser == nil)
    #expect(!restored.isSettling)
    #expect(!marker.isUnsettled)
}

@Test @MainActor func completedSessionRestoresWithoutUnneededSignOut() {
    let backend = CustomTokenBackend()
    let user = AuthenticatedUser(uid: "user-a", email: nil)
    backend.currentUser = user
    let session = CloudGatewayFirebaseCustomTokenSession(backend: backend, marker: ExchangeMarker())
    #expect(session.currentUser == user)
    #expect(backend.signOutCount == 0)
}

@Test @MainActor func failedSDKExchangeDoesNotPublishUserOrLeaveMarker() async {
    let backend = CustomTokenBackend()
    let marker = ExchangeMarker()
    let session = CloudGatewayFirebaseCustomTokenSession(backend: backend, marker: marker)
    let exchange = Task { try await session.signIn(customToken: "fixture-token") }
    await waitForExchange(backend)
    backend.fail()
    await #expect(throws: CloudGatewayDeviceAuthError.unavailable) { try await exchange.value }
    #expect(session.currentUser == nil)
    #expect(!session.isSettling)
    #expect(!marker.isUnsettled)
}

@Test @MainActor func invalidCustomTokenCannotMutateSDKOrSessionMarker() async {
    let backend = CustomTokenBackend()
    let marker = ExchangeMarker()
    let session = CloudGatewayFirebaseCustomTokenSession(backend: backend, marker: marker)
    await #expect(throws: CloudGatewayDeviceAuthError.invalidResponse) {
        try await session.signIn(customToken: "")
    }
    await #expect(throws: CloudGatewayDeviceAuthError.invalidResponse) {
        try await session.signIn(customToken: String(repeating: "a", count: 16_385))
    }
    #expect(backend.signInCount == 0)
    #expect(!marker.isUnsettled)
}
#endif
