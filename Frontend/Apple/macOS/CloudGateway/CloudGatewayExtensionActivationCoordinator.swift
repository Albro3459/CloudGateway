import CloudGatewayKit
import CloudGatewayMacCore
import CloudGatewayMacControllerIPC
import CloudGatewayMacIPC
import Foundation
import NetworkExtension
import SystemExtensions

final class CloudGatewayExtensionActivationCoordinator: NSObject, OSSystemExtensionRequestDelegate {
    private static let extensionIdentifier = "com.gocloudlaunch.gateway.tunnel.macos"
    var onStatusChange: (() -> Void)?
    var onAttemptStatusChange: ((UUID, CloudGatewayMacSetupState) -> Void)?
    var isCurrentBuild: (() -> Bool)?
    private(set) var state = CloudGatewayMacSetupState.required {
        didSet {
            if state != oldValue { onStatusChange?() }
            if !applyingReadiness, let attemptId,
               lastReportedAttempt != attemptId || lastReportedState != state {
                lastReportedAttempt = attemptId
                lastReportedState = state
                onAttemptStatusChange?(attemptId, state)
            }
        }
    }
    private let delegateQueue = DispatchQueue(label: "com.gocloudlaunch.gateway.extension-activation")
    private var request: OSSystemExtensionRequest?
    private var attemptId: UUID?
    private var hasLocalActivationFailure = false
    private var applyingReadiness = false
    private var lastReportedAttempt: UUID?
    private var lastReportedState: CloudGatewayMacSetupState?

    private var bundledVersion: CloudGatewayMacExtensionVersion? {
        let url = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/SystemExtensions/\(Self.extensionIdentifier).systemextension"
        )
        let teamIdentifier = Bundle.main.object(forInfoDictionaryKey: "CloudGatewayTeamIdentifier") as? String ?? ""
        guard let identity = try? CloudGatewayMacSignedBundle.installed(
            at: url, teamIdentifier: teamIdentifier, bundleIdentifier: Self.extensionIdentifier
        ) else { return nil }
        return CloudGatewayMacExtensionVersion(infoDictionary: [
            "CFBundleVersion": identity.build, "CFBundleShortVersionString": identity.version
        ], codeHash: identity.codeHash)
    }

    func updateReadiness(_ readiness: CloudGatewayMacControllerView.SetupState) {
        guard request == nil else { return }
        guard !hasLocalActivationFailure || readiness == .ready else { return }
        hasLocalActivationFailure = false
        let next: CloudGatewayMacSetupState
        switch readiness {
        case .required: next = .required
        case .updateRequired: next = .updateRequired
        case .invalidBundle: next = .invalidBundle
        case .activating: next = .activating
        case .awaitingApproval: next = .awaitingApproval
        case .awaitingRestart: next = .awaitingRestart
        case .checkingConnection: next = .checkingConnection
        case .ready: next = .ready
        case .failed(let code): next = .failed(code: code)
        case .unavailable: next = .unavailable
        }
        guard state != next else { return }
        applyingReadiness = true
        defer { applyingReadiness = false }
        state = next
    }

    func resetActivationFailure() {
        guard hasLocalActivationFailure else { return }
        hasLocalActivationFailure = false
        state = .checkingConnection
    }

    func activate(attemptId: UUID, target: CloudGatewayMacBuildIdentity) {
        guard request == nil, self.attemptId == nil else { return }
        self.attemptId = attemptId
        hasLocalActivationFailure = false
        guard isCurrentBuild?() == true else {
            fail(code: -1)
            return
        }
        guard let bundledVersion, bundledVersion.codeHash == target.codeHash,
              bundledVersion.bundleVersion == target.build, bundledVersion.bundleShortVersion == target.version else {
            state = .invalidBundle
            self.attemptId = nil
            return
        }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            state = .unavailable
            self.attemptId = nil
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: delegateQueue
        )
        request.delegate = self
        self.request = request
        state = .activating
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        DispatchQueue.main.async { [self] in
            guard self.request === request else { return }
            state = .awaitingApproval
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        guard DispatchQueue.main.sync(execute: { self.request === request && isCurrentBuild?() == true }) else {
            return .cancel
        }
        // Keep the main queue free for NetworkExtension's preferences completion
        let check = ExtensionReplacementCheck()
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            let statuses = error == nil ? managers?.filter {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.extensionIdentifier
            }.map { manager -> CloudGatewayTunnelStatus in
                switch manager.connection.status {
                case .invalid: .invalid
                case .disconnected: .disconnected
                default: .connected
                }
            } : nil
            check.finish(isIdle: CloudGatewayMacSetupState.canReplaceExtension(
                isCurrentBuild: true, ownedTunnelStatuses: statuses
            ))
        }
        guard check.wait() else { return .cancel }
        return DispatchQueue.main.sync {
            self.request === request && isCurrentBuild?() == true ? .replace : .cancel
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        DispatchQueue.main.async { [self] in
            guard self.request === request else { return }
            self.request = nil
            switch result {
            case .completed:
                state = .checkingConnection
                attemptId = nil
            case .willCompleteAfterReboot:
                state = .awaitingRestart
            @unknown default:
                fail(code: -1)
            }
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        DispatchQueue.main.async { [self] in
            guard self.request === request else { return }
            self.request = nil
            fail(code: (error as NSError).code)
        }
    }

    private func fail(code: Int) {
        hasLocalActivationFailure = true
        state = .failed(code: code)
        attemptId = nil
    }
}

private final class ExtensionReplacementCheck: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isIdle = false

    func finish(isIdle: Bool) {
        lock.lock()
        self.isIdle = isIdle
        lock.unlock()
        semaphore.signal()
    }

    func wait() -> Bool {
        guard semaphore.wait(timeout: .now() + 10) == .success else { return false }
        lock.lock()
        defer { lock.unlock() }
        return isIdle
    }
}
