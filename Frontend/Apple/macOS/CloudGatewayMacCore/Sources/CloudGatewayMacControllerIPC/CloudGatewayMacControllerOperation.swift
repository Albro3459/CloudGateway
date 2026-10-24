import CloudGatewayMacCore
import Foundation

public struct CloudGatewayMacControllerOperation: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case accepted, running, completed, failed, unknown
    }

    public let id: UUID
    public let state: State
    public let failure: CloudGatewayMacControllerFailure?
    public let warning: CloudGatewayMacCommandWarning?

    public init(id: UUID, state: State, failure: CloudGatewayMacControllerFailure? = nil,
                warning: CloudGatewayMacCommandWarning? = nil) {
        self.id = id
        self.state = state
        self.failure = failure
        self.warning = warning
    }

    func validate() throws {
        guard failure == nil || state == .failed || state == .unknown else {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
    }
}

// This small contract remains readable while normal controller protocols change
public struct CloudGatewayMacControllerStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case disconnected, connecting, connected, disconnecting
    }

    public let phase: Phase
    public let hasActiveTunnel: Bool
    public let needsStop: Bool
    public let observationAvailable: Bool

    public init(hasActiveTunnel: Bool, needsStop: Bool, observationAvailable: Bool, phase: Phase? = nil) {
        self.phase = phase ?? (hasActiveTunnel ? .connected : needsStop ? .connecting : .disconnected)
        self.hasActiveTunnel = hasActiveTunnel
        self.needsStop = needsStop
        self.observationAvailable = observationAvailable
    }

    func validate() throws {
        guard (!hasActiveTunnel || needsStop),
              phase != .connected || hasActiveTunnel,
              phase == .disconnected || needsStop else { throw CloudGatewayMacControllerFailure.invalidRequest }
    }
}

// Operation keeps its original cases so older clients can still read lookups
extension CloudGatewayMacCommandOutcome {
    var state: CloudGatewayMacControllerOperation.State {
        switch self {
        case .startRequested, .alreadyActive, .completed: .completed
        // An unconfirmed stop may still finish, so compatible clients see it as uncertain
        case .failed(.stopTimedOut), .unknown, .expired: .unknown
        case .failed: .failed
        }
    }

    var identifier: String? {
        switch self {
        case .startRequested(let identifier, _), .alreadyActive(let identifier, _): identifier
        default: nil
        }
    }
}
