import CloudGatewayMacIPC
import Foundation

public struct CloudGatewayMacControllerLifecycle: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case current, draining, invalidInstallation
    }

    public let running: CloudGatewayMacBuildIdentity
    public let installed: CloudGatewayMacBuildIdentity?
    public let state: State

    public init(
        running: CloudGatewayMacBuildIdentity,
        installed: CloudGatewayMacBuildIdentity?,
        state: State
    ) {
        self.running = running
        self.installed = installed
        self.state = state
    }

    func validate() throws {
        try CloudGatewayMacControllerProtocol.validateBuildIdentity(running)
        if let installed { try CloudGatewayMacControllerProtocol.validateBuildIdentity(installed) }
    }
}

extension CloudGatewayMacControllerProtocol {
    static func validateBuildIdentity(_ identity: CloudGatewayMacBuildIdentity) throws {
        try validateVersion(identity.version, build: identity.build)
        let hash = identity.codeHash.utf8
        guard (hash.count == 40 || hash.count == 64), hash.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { throw CloudGatewayMacControllerFailure.invalidRequest }
    }
}
