import CloudGatewayKit
import CloudGatewayMacCore
import Foundation

public struct CloudGatewayMacControllerState: Codable, Equatable, Sendable {
    public enum Freshness: String, Codable, Sendable {
        case unavailable, refreshing, current, cached
    }

    public struct Client: Codable, Equatable, Sendable {
        public let identifier: String
        public let clientId: String
        public let regionId: String
        public let regionName: String
        public let regionOrder: Int
        public let clientName: String
        public let ownerLabel: String?
        public let internalIp: String?
        public var connectionUrl: String? = nil
        public let cloudState: CloudGatewayClientStatus
        public let eligibility: CloudGatewayMacClientEligibility
        public let isInstalled: Bool
        public let source: CloudGatewayMacInventorySource
        public let readAt: Date
        public let updatedAt: Date?
        public let status: CloudGatewayMacControllerView.TunnelStatus?

        public var isEligible: Bool { eligibility == .eligible }
    }

    public struct Profile: Codable, Equatable, Sendable {
        public let identifier: String?
        public let status: CloudGatewayMacControllerView.TunnelStatus
    }

    public let accountId: String?
    public let auth: CloudGatewayMacControllerView.BrowserState
    public let login: CloudGatewayMacLoginStatus?
    public let hasRetainedSession: Bool
    public let isRestoringSession: Bool
    public let isAuthSettling: Bool
    public let accessAuthorized: Bool
    public let access: CloudGatewayMacAccessState
    public let credentials: CloudGatewayMacCredentialEvidence
    public let inventory: Freshness
    public let clients: [Client]
    public let installedIdentifiers: [String]
    public let observedProfiles: [Profile]
    public let observationAvailable: Bool
    public let profilesObservedAt: Date?
    public let commandInFlight: Bool
    public let selectedIdentifier: String?
    public let setup: CloudGatewayMacControllerView.SetupState
    public let canUpdateExtension: Bool
    public let creationAllowed: Bool
    public let errorMessage: String?

    public init(snapshot: CloudGatewayMacControllerSnapshot, setupState: CloudGatewayMacSetupState,
                canUpdateExtension: Bool) {
        let accountId = snapshot.domain.accountId
        self.accountId = accountId
        auth = .init(snapshot.browserState)
        login = snapshot.login
        hasRetainedSession = snapshot.domain.hasRetainedSession
        isRestoringSession = snapshot.isRestoringSession
        isAuthSettling = snapshot.isAuthSettling
        accessAuthorized = snapshot.domain.accessAuthorized
        access = snapshot.domain.access
        credentials = snapshot.domain.credentials
        inventory = Freshness(rawValue: snapshot.domain.inventoryFreshness.rawValue) ?? .unavailable
        clients = snapshot.domain.clients.filter { Self.belongs($0.identifier, to: accountId) }.map { client in
            Client(identifier: client.identifier, clientId: client.clientId, regionId: client.regionId,
                   regionName: ControllerDisplayText.normalize(client.regionName, bytes: 1024),
                   regionOrder: client.regionOrder,
                   clientName: ControllerDisplayText.normalize(client.clientName, bytes: 2048),
                   ownerLabel: client.ownerLabel.map { ControllerDisplayText.normalize($0, bytes: 1024) },
                   internalIp: client.internalIp.flatMap(Self.tunnelIPv4),
                   connectionUrl: client.connectionUrl.map { ControllerDisplayText.normalize($0, bytes: 1024) },
                   cloudState: client.cloudState, eligibility: client.eligibility, isInstalled: client.isInstalled,
                   source: client.source, readAt: client.readAt, updatedAt: client.updatedAt,
                   status: client.status.map(CloudGatewayMacControllerView.TunnelStatus.init))
        }
        installedIdentifiers = snapshot.domain.installedIdentifiers.filter { Self.belongs($0, to: accountId) }
        observedProfiles = snapshot.domain.observedProfiles.map {
            Profile(identifier: Self.belongs($0.identifier, to: accountId) ? $0.identifier : nil,
                    status: .init($0.status))
        }
        observationAvailable = snapshot.domain.observationIsFresh
        profilesObservedAt = snapshot.domain.profilesObservedAt
        commandInFlight = snapshot.domain.commandInFlight
        selectedIdentifier = snapshot.lastSelectedIdentifier.flatMap { Self.belongs($0, to: accountId) ? $0 : nil }
        setup = .init(setupState)
        self.canUpdateExtension = canUpdateExtension
        creationAllowed = snapshot.canCreateClient
        errorMessage = ControllerVisibleError.sanitize(snapshot.errorMessage)
    }

    public var status: CloudGatewayMacControllerStatus {
        let phase: CloudGatewayMacControllerStatus.Phase
        if observedProfiles.contains(where: { $0.status == .connecting }) { phase = .connecting }
        else if observedProfiles.contains(where: { $0.status == .disconnecting }) { phase = .disconnecting }
        else if observedProfiles.contains(where: { $0.status == .connected || $0.status == .reasserting }) { phase = .connected }
        else { phase = .disconnected }
        return .init(hasActiveTunnel: observedProfiles.contains { $0.status == .connected || $0.status == .reasserting },
              needsStop: observedProfiles.contains { $0.status != .invalid && $0.status != .disconnected },
              observationAvailable: observationAvailable, phase: phase)
    }

    func validate() throws {
        let bounds = CloudGatewayMacControllerProtocol.self
        let installed = Set(installedIdentifiers)
        guard accountId.map(bounds.validComponent) ?? true,
              clients.count <= 4096, installedIdentifiers.count <= 4096, observedProfiles.count <= 4096,
              Set(clients.map(\.regionId)).count <= 256,
              clients.allSatisfy({ Self.belongs($0.identifier, to: accountId)
                  && $0.identifier.split(separator: "/").last == Substring($0.clientId)
                  && bounds.validComponent($0.regionId) && $0.identifier.split(separator: "/")[1] == $0.regionId
                  && bounds.boundedText($0.clientName, bytes: 2048) && bounds.boundedText($0.regionName, bytes: 1024)
                  && ($0.ownerLabel.map { bounds.boundedText($0, bytes: 1024) } ?? true)
                  && ($0.internalIp.map(bounds.validIPv4) ?? true)
                  && ($0.connectionUrl.map { bounds.boundedText($0, bytes: 1024) } ?? true)
                  && $0.isInstalled == installed.contains($0.identifier) && ($0.source == .cloud || $0.isInstalled) }),
              Set(clients.map(\.identifier)).count == clients.count,
              installedIdentifiers.allSatisfy({ Self.belongs($0, to: accountId) }),
              installed.count == installedIdentifiers.count,
              observedProfiles.allSatisfy({ $0.identifier.map { Self.belongs($0, to: accountId) } ?? true }),
              selectedIdentifier.map({ Self.belongs($0, to: accountId) }) ?? true,
              errorMessage.map({ bounds.boundedText($0, bytes: 2048) && ControllerVisibleError.sanitize($0) == $0 }) ?? true else {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
        if case .waitingForApproval(let code, let url) = auth {
            guard accountId == nil, bounds.validChallenge(code: code, url: url) else {
                throw CloudGatewayMacControllerFailure.invalidRequest
            }
        }
        if auth == .signedIn, accountId == nil { throw CloudGatewayMacControllerFailure.invalidRequest }
    }

    private static func tunnelIPv4(_ value: String) -> String? {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let first = parts.first,
              CloudGatewayMacControllerProtocol.validIPv4(String(first)) else { return nil }
        if parts.count == 2 {
            let prefix = parts[1]
            guard (1...2).contains(prefix.utf8.count), prefix.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(prefix), (0...32).contains(length) else { return nil }
        }
        return String(first)
    }

    static func belongs(_ identifier: String, to accountId: String?) -> Bool {
        guard let accountId else { return false }
        return CloudGatewayMacControllerProtocol.validIdentifier(identifier) && identifier.hasPrefix("\(accountId)/")
    }
}
