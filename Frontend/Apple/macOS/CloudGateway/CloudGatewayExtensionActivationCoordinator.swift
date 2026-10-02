import CloudGatewayMacCore
import CloudGatewayMacIPC
import Foundation
import SystemExtensions

final class CloudGatewayExtensionActivationCoordinator: NSObject, OSSystemExtensionRequestDelegate {
    var onStatusChange: ((CloudGatewayMacSetupState) -> Void)?
    private(set) var state = CloudGatewayMacSetupState.required {
        didSet { onStatusChange?(state) }
    }
    private var request: OSSystemExtensionRequest?
    private var readinessTask: Task<Void, Never>?

    func refreshReadiness() {
        guard request == nil, readinessTask == nil, state.canRefreshReadiness else { return }
        state = .checkingConnection
        readinessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let teamIdentifier = Bundle.main.object(forInfoDictionaryKey: "CloudGatewayTeamIdentifier") as? String ?? ""
                let client = try CloudGatewayMacXPCSecretClient(teamIdentifier: teamIdentifier)
                try await client.ping()
                state = .ready
            } catch {
                state = .required
            }
            readinessTask = nil
        }
    }

    func activate() {
        guard request == nil, state.canActivate else { return }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            state = .unavailable
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: "com.gocloudlaunch.gateway.tunnel.macos",
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
            refreshReadiness()
        case .willCompleteAfterReboot:
            state = .awaitingRestart
        @unknown default:
            state = .required
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        guard self.request === request else { return }
        self.request = nil
        state = .failed(code: (error as NSError).code)
    }
}
