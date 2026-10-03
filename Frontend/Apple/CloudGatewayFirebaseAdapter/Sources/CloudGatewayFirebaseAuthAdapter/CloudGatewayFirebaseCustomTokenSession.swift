#if os(macOS)
import CloudGatewayAppCore
import Foundation

@MainActor
protocol CloudGatewayFirebaseCustomTokenBackend {
    var currentUser: AuthenticatedUser? { get }
    func signIn(customToken: String) async throws -> AuthenticatedUser
    func signOut() throws
}

@MainActor
protocol CloudGatewayFirebaseExchangeMarker: AnyObject {
    var isUnsettled: Bool { get set }
}

@MainActor
final class CloudGatewayFirebaseDefaultsExchangeMarker: CloudGatewayFirebaseExchangeMarker {
    private let key = "CloudGateway.customTokenExchangeUnsettled"

    var isUnsettled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@MainActor
final class CloudGatewayFirebaseCustomTokenSession {
    private let backend: any CloudGatewayFirebaseCustomTokenBackend
    private let marker: any CloudGatewayFirebaseExchangeMarker
    private var generation = UUID()
    private var exchangeIsPending = false
    private var shouldSuppressSession = false

    init(backend: any CloudGatewayFirebaseCustomTokenBackend, marker: any CloudGatewayFirebaseExchangeMarker) {
        self.backend = backend
        self.marker = marker
        if marker.isUnsettled {
            shouldSuppressSession = true
            do {
                try backend.signOut()
                marker.isUnsettled = false
                shouldSuppressSession = false
            } catch {}
        }
    }

    var currentUser: AuthenticatedUser? {
        shouldSuppressSession || exchangeIsPending ? nil : backend.currentUser
    }

    var isSettling: Bool { exchangeIsPending || shouldSuppressSession }

    func signIn(customToken: String) async throws -> AuthenticatedUser {
        guard !isSettling else { throw CloudGatewayDeviceAuthError.unavailable }
        guard !customToken.isEmpty, customToken.utf8.count <= 16_384 else {
            throw CloudGatewayDeviceAuthError.invalidResponse
        }
        try Task.checkCancellation()
        let attempt = UUID()
        generation = attempt
        exchangeIsPending = true
        marker.isUnsettled = true
        let result: Result<AuthenticatedUser, any Error>
        do { result = .success(try await backend.signIn(customToken: customToken)) }
        catch { result = .failure(error) }
        exchangeIsPending = false
        guard generation == attempt, !Task.isCancelled else {
            shouldSuppressSession = true
            do {
                try backend.signOut()
                marker.isUnsettled = false
                shouldSuppressSession = false
            } catch {
                throw CloudGatewayDeviceAuthError.unavailable
            }
            throw CancellationError()
        }
        switch result {
        case .success(let user):
            marker.isUnsettled = false
            return user
        case .failure:
            shouldSuppressSession = true
            do {
                try backend.signOut()
                marker.isUnsettled = false
                shouldSuppressSession = false
            } catch {
                throw CloudGatewayDeviceAuthError.unavailable
            }
            throw CloudGatewayDeviceAuthError.unavailable
        }
    }

    func cancel() throws {
        guard exchangeIsPending else { return }
        try signOut()
    }

    func signOut() throws {
        generation = UUID()
        shouldSuppressSession = true
        marker.isUnsettled = true
        do {
            try backend.signOut()
            marker.isUnsettled = exchangeIsPending
            shouldSuppressSession = false
        } catch {
            throw CloudGatewayDeviceAuthError.unavailable
        }
    }
}
#endif
