import CloudGatewayMacIPC
import Foundation

public enum CloudGatewayMacManagedUpdateFailure: String, Error, Codable, Sendable {
    case disconnectRequired, initialSetupRequired, approvalRequired, restartRequired, invalidBundle
    case storageUnavailable, configUnavailable, signInRequired, accessDenied, networkUnavailable, busy, timeout
    case stopTimedOut, activationFailed, readinessFailed, superseded, reconnectSuppressed, observationUnavailable
    case confirmationExpired, targetChanged, vpnFailed
}

public enum CloudGatewayMacExtensionActivationEvent: Equatable, Sendable {
    case approvalRequired, restartRequired, completed, failed(Int)
}

public struct CloudGatewayMacManagedUpdateStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case prepared, stopping, activating, approvalRequired, restartRequired, checkingReadiness
        case reconnecting, completed, failed, superseded
    }

    public let id: UUID
    public let phase: Phase
    public let target: CloudGatewayMacBuildIdentity
    public let identifier: String?
    public let reconnect: Bool
    public let error: CloudGatewayMacManagedUpdateFailure?
    public let warning: CloudGatewayMacManagedUpdateFailure?

    public init(id: UUID, phase: Phase, target: CloudGatewayMacBuildIdentity, identifier: String? = nil,
                reconnect: Bool = false, error: CloudGatewayMacManagedUpdateFailure? = nil,
                warning: CloudGatewayMacManagedUpdateFailure? = nil) {
        self.id = id
        self.phase = phase
        self.target = target
        self.identifier = identifier
        self.reconnect = reconnect
        self.error = error
        self.warning = warning
    }

    var isTerminal: Bool { phase == .completed || phase == .failed || phase == .superseded }

    var operation: CloudGatewayMacControllerOperation {
        .init(id: id, state: phase == .prepared ? .accepted : phase == .completed ? .completed
              : phase == .superseded ? .unknown : phase == .failed ? .failed : .running,
              failure: phase == .failed ? .commandFailed : phase == .superseded ? .outcomeUnknown : nil)
    }

    func validate() throws {
        try target.validate()
        guard identifier.map(CloudGatewayMacControllerProtocol.validIdentifier) ?? true,
              error == nil || isTerminal else { throw CloudGatewayMacControllerFailure.invalidRequest }
    }
}
