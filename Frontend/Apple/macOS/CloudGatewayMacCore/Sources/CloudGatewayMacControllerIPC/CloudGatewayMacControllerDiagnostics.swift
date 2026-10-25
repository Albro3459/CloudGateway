import CloudGatewayMacCore
import CloudGatewayMacIPC
import Foundation

public struct CloudGatewayMacControllerDiagnostics: Codable, Equatable, Sendable {
    public enum Evidence: String, Codable, Sendable {
        case available, unavailable, invalid, unknown
    }

    public enum ExtensionState: String, Codable, Sendable {
        case ready, enabled, incompatible, replacementBlocked, awaitingApproval, disabled, missing, unknown
    }

    public let runtimeInitialized: Bool
    public let access: CloudGatewayMacAccessState?
    public let credentials: CloudGatewayMacCredentialEvidence?
    public let extensionState: ExtensionState
    public let preferences: Evidence
    public let regionId: String?
    public let setupState: CloudGatewayMacControllerView.SetupState?

    public init(runtimeInitialized: Bool, access: CloudGatewayMacAccessState? = nil,
                credentials: CloudGatewayMacCredentialEvidence? = nil,
                extensionState: ExtensionState = .unknown, preferences: Evidence = .unknown,
                regionId: String? = nil, setupState: CloudGatewayMacControllerView.SetupState? = nil) {
        self.runtimeInitialized = runtimeInitialized
        self.access = access
        self.credentials = credentials
        self.extensionState = extensionState
        self.preferences = preferences
        self.regionId = regionId
        self.setupState = setupState
    }

    func withSetupState(_ state: CloudGatewayMacSetupState) -> Self {
        .init(runtimeInitialized: runtimeInitialized, access: access, credentials: credentials,
              extensionState: extensionState, preferences: preferences, regionId: regionId, setupState: .init(state))
    }

    func validate() throws {
        guard runtimeInitialized || (access == nil && credentials == nil && regionId == nil),
              regionId.map(CloudGatewayMacControllerProtocol.validComponent) ?? true else {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
    }

    public static func extensionReadiness(installed: CloudGatewayMacBuildIdentity,
                                          observed: CloudGatewayMacExtensionVersion?) -> ExtensionState {
        guard let observed else { return .enabled }
        guard observed.bundleVersion == installed.build, observed.bundleShortVersion == installed.version else { return .incompatible }
        // macOS keeps an active extension with the same version numbers, so activation cannot replace it
        return observed.codeHash == installed.codeHash ? .ready : .replacementBlocked
    }
}
