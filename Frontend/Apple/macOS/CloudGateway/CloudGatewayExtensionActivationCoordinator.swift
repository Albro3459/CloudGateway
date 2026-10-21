import CloudGatewayMacCore
import CloudGatewayMacControllerIPC
import CloudGatewayMacIPC
import Foundation
import SystemExtensions

final class CloudGatewayExtensionActivationCoordinator: NSObject, OSSystemExtensionRequestDelegate {
    private static let extensionIdentifier = "com.gocloudlaunch.gateway.tunnel.macos"
    var onStatusChange: ((CloudGatewayMacSetupState) -> Void)?
    var onActivationComplete: (() -> Void)?
    private(set) var state = CloudGatewayMacSetupState.required {
        didSet { onStatusChange?(state) }
    }
    private var request: OSSystemExtensionRequest?
    private var hasLocalActivationFailure = false

    private var bundledVersion: CloudGatewayMacExtensionVersion? {
        let url = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/SystemExtensions/\(Self.extensionIdentifier).systemextension"
        )
        guard let info = Bundle(url: url)?.infoDictionary else { return nil }
        return CloudGatewayMacExtensionVersion(infoDictionary: info)
    }

    func updateReadiness(_ readiness: CloudGatewayMacControllerView.SetupState) {
        guard request == nil, state.canRefreshReadiness else { return }
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
        state = next
    }

    func resetActivationFailure() {
        guard hasLocalActivationFailure else { return }
        hasLocalActivationFailure = false
        state = .checkingConnection
    }

    func activate() {
        guard request == nil, state.canActivate else { return }
        hasLocalActivationFailure = false
        guard bundledVersion != nil else {
            state = .invalidBundle
            return
        }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            state = .unavailable
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        self.request = request
        state = .activating
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard self.request === request else { return }
        state = .awaitingApproval
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        self.request === request ? .replace : .cancel
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard self.request === request else { return }
        self.request = nil
        switch result {
        case .completed:
            state = .checkingConnection
            onActivationComplete?()
        case .willCompleteAfterReboot:
            state = .awaitingRestart
        @unknown default:
            state = .required
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        guard self.request === request else { return }
        self.request = nil
        hasLocalActivationFailure = true
        state = .failed(code: (error as NSError).code)
    }
}
