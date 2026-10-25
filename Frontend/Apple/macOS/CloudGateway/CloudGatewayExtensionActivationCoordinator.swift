import CloudGatewayKit
import CloudGatewayMacCore
import CloudGatewayMacControllerIPC
import CloudGatewayMacIPC
import Foundation
import NetworkExtension
import SystemExtensions

@MainActor
final class CloudGatewayExtensionActivationCoordinator: NSObject, OSSystemExtensionRequestDelegate {
    nonisolated private static let extensionIdentifier = "com.gocloudlaunch.gateway.tunnel.macos"
    private let installedURL: URL
    private let teamIdentifier: String
    private let appIdentity: CloudGatewayMacBuildIdentity
    private let delegateQueue = DispatchQueue(label: "com.gocloudlaunch.gateway.extension-activation")
    private var request: OSSystemExtensionRequest?
    private var attemptId: UUID?
    private var target: CloudGatewayMacBuildIdentity?
    private var onEvent: (@MainActor (CloudGatewayMacExtensionActivationEvent) -> Void)?

    init(installedURL: URL, teamIdentifier: String, appIdentity: CloudGatewayMacBuildIdentity) {
        self.installedURL = installedURL
        self.teamIdentifier = teamIdentifier
        self.appIdentity = appIdentity
    }

    var isPending: Bool { attemptId != nil }

    func activate(attemptId: UUID, target: CloudGatewayMacBuildIdentity,
                  onEvent: @escaping @MainActor (CloudGatewayMacExtensionActivationEvent) -> Void) -> Bool {
        guard !isPending, verifiedTarget(target) else { return false }
        self.attemptId = attemptId
        self.target = target
        self.onEvent = onEvent
        Task { [self] in
            do {
                let idle: Bool = try await CloudGatewayMacInventoryRequest.read { complete in
                    NETunnelProviderManager.loadAllFromPreferences { managers, error in
                        if let error { complete(.failure(error)) }
                        else { complete(.success(managers.map(Self.areIdle) == true)) }
                    }
                    return {}
                }
                guard self.attemptId == attemptId else { return }
                guard idle, verifiedTarget(target) else {
                    finish(.failed(-1))
                    return
                }
                let request = OSSystemExtensionRequest.activationRequest(
                    forExtensionWithIdentifier: Self.extensionIdentifier, queue: delegateQueue
                )
                request.delegate = self
                self.request = request
                OSSystemExtensionManager.shared.submitRequest(request)
            } catch {
                guard self.attemptId == attemptId else { return }
                finish(.failed((error as NSError).code))
            }
        }
        return true
    }

    private func verifiedTarget(_ target: CloudGatewayMacBuildIdentity) -> Bool {
        let canonical = URL(fileURLWithPath: "/Applications/CloudGateway.app")
        guard installedURL.standardizedFileURL == canonical,
              installedURL.resolvingSymlinksInPath() == canonical,
              let running = try? CloudGatewayMacSignedBundle.running(
                teamIdentifier: teamIdentifier, bundleIdentifier: CloudGatewayMacControllerProtocol.appBundleIdentifier
              ), running == appIdentity,
              let installed = try? CloudGatewayMacSignedBundle.installed(
                at: installedURL, teamIdentifier: teamIdentifier,
                bundleIdentifier: CloudGatewayMacControllerProtocol.appBundleIdentifier
              ), installed == appIdentity,
              let bundled = try? CloudGatewayMacSignedBundle.installed(
                at: installedURL.appendingPathComponent(
                    "Contents/Library/SystemExtensions/\(Self.extensionIdentifier).systemextension"
                ), teamIdentifier: teamIdentifier, bundleIdentifier: Self.extensionIdentifier
              ) else { return false }
        return bundled == target
    }

    private func ownsVerifiedRequest(_ request: OSSystemExtensionRequest) -> Bool {
        guard self.request === request, let target else { return false }
        return verifiedTarget(target)
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor [self] in
            guard self.request === request else { return }
            onEvent?(ownsVerifiedRequest(request) ? .approvalRequired : .failed(-1))
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        let matches = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                ownsVerifiedRequest(request) && replacement.bundleIdentifier == Self.extensionIdentifier
                    && replacement.bundleVersion == target?.build
                    && replacement.bundleShortVersion == target?.version
            }
        }
        guard matches else { return .cancel }
        // Keep the main queue free for NetworkExtension's preferences completion
        let check = ExtensionReplacementCheck()
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            check.finish(isIdle: error == nil && managers.map(Self.areIdle) == true)
        }
        guard check.wait() else { return .cancel }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { ownsVerifiedRequest(request) ? .replace : .cancel }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor [self] in
            guard self.request === request else { return }
            guard ownsVerifiedRequest(request) else { finish(.failed(-1)); return }
            switch result {
            case .completed: finish(.completed)
            case .willCompleteAfterReboot: finish(.restartRequired)
            @unknown default: finish(.failed(-1))
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor [self] in
            guard self.request === request else { return }
            finish(.failed((error as NSError).code))
        }
    }

    private func finish(_ event: CloudGatewayMacExtensionActivationEvent) {
        let callback = onEvent
        request = nil
        attemptId = nil
        target = nil
        onEvent = nil
        callback?(event)
    }

    nonisolated private static func areIdle(_ managers: [NETunnelProviderManager]) -> Bool {
        let statuses = managers.filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == extensionIdentifier
        }.map { manager -> CloudGatewayTunnelStatus in
            switch manager.connection.status {
            case .invalid: .invalid
            case .disconnected: .disconnected
            default: .connected
            }
        }
        return CloudGatewayMacSetupState.canReplaceExtension(isCurrentBuild: true, ownedTunnelStatuses: statuses)
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
