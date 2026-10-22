import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation

public enum CloudGatewayMacControllerFailure: String, Error, Codable, Sendable {
    case invalidRequest, incompatibleVersion, unavailable, timeout, busy, rejected, outcomeUnknown, extensionAttemptChanged, preparationExpired, commandFailed, authCleanupFailed
}

public struct CloudGatewayMacControllerRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable {
        case prepareExtensionUpdate, extensionUpdateStarted, extensionUpdateApproval, extensionUpdateRestart, extensionUpdateFinished, extensionUpdateFailed
        case lifecycle, status, operation, confirmOperation, snapshot, menuWillOpen, refresh, signIn, cancelSignIn, signOut, connect, turnOff, prepareClient, createClient
    }

    public let controlVersion: Int?
    public let schemaVersion: Int
    public let protocolVersion: Int
    public let appVersion: String
    public let appBuild: String
    public let buildIdentity: CloudGatewayMacBuildIdentity?
    public let id: UUID
    public let action: Action
    public let identifier: String?
    public let regionId: String?
    public let clientName: String?
    public let contextId: UUID?

    public init(
        action: Action,
        id: UUID = UUID(),
        identifier: String? = nil,
        regionId: String? = nil,
        clientName: String? = nil,
        contextId: UUID? = nil,
        appVersion: String = "",
        appBuild: String = "",
        buildIdentity: CloudGatewayMacBuildIdentity? = nil
    ) {
        controlVersion = CloudGatewayMacControllerProtocol.controlVersion
        schemaVersion = CloudGatewayMacControllerProtocol.protocolVersion
        protocolVersion = CloudGatewayMacControllerProtocol.protocolVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.buildIdentity = buildIdentity
        self.id = id
        self.action = action
        self.identifier = identifier
        self.regionId = regionId
        self.clientName = clientName
        self.contextId = contextId
    }
}

public struct CloudGatewayMacControllerReply: Codable, Equatable, Sendable {
    public struct Creation: Codable, Equatable, Sendable {
        public let id: UUID
        public let regions: [CloudGatewayRegion]

        public init(id: UUID, regions: [CloudGatewayRegion]) {
            self.id = id
            self.regions = regions.map {
                CloudGatewayRegion(
                    regionId: $0.regionId, displayName: ControllerDisplayText.normalize($0.displayName, bytes: 1024),
                    enabled: $0.enabled, displayOrder: $0.displayOrder, capacity: $0.capacity
                )
            }
        }
    }

    public internal(set) var schemaVersion: Int
    public internal(set) var protocolVersion: Int
    public internal(set) var appVersion: String
    public internal(set) var appBuild: String
    public internal(set) var instanceId: UUID?
    public internal(set) var controlVersion: Int?
    public let state: CloudGatewayMacControllerState?
    public let status: CloudGatewayMacControllerStatus?
    public let operation: CloudGatewayMacControllerOperation?
    public let accepted: Bool?
    public let creation: Creation?
    public let error: CloudGatewayMacControllerFailure?
    public let operationId: UUID?
    public let lifecycle: CloudGatewayMacControllerLifecycle?
    public let extensionTarget: CloudGatewayMacBuildIdentity?

    public init(
        state: CloudGatewayMacControllerState? = nil,
        status: CloudGatewayMacControllerStatus? = nil,
        operation: CloudGatewayMacControllerOperation? = nil,
        accepted: Bool? = nil,
        creation: Creation? = nil,
        error: CloudGatewayMacControllerFailure? = nil,
        operationId: UUID? = nil,
        lifecycle: CloudGatewayMacControllerLifecycle? = nil,
        extensionTarget: CloudGatewayMacBuildIdentity? = nil
    ) {
        schemaVersion = CloudGatewayMacControllerProtocol.protocolVersion
        protocolVersion = CloudGatewayMacControllerProtocol.protocolVersion
        appVersion = ""
        appBuild = ""
        instanceId = nil
        controlVersion = CloudGatewayMacControllerProtocol.controlVersion
        self.state = state
        self.status = status
        self.operation = operation
        self.accepted = accepted
        self.creation = creation
        self.error = error
        self.operationId = operationId
        self.lifecycle = lifecycle
        self.extensionTarget = extensionTarget
    }
}

public enum CloudGatewayMacControllerProtocol {
    public static let protocolVersion = 1
    public static let controlVersion = 1
    public static let machServiceName = "com.gocloudlaunch.gateway.macos.controller"
    public static let appBundleIdentifier = "com.gocloudlaunch.gateway.macos"
    public static let requestBytes = 64 * 1024
    public static let replyBytes = 1024 * 1024
    static let maximumConnections = 32
    static let maximumRequests = 64
    static let maximumClientRequests = 8

    static func validateVersion(_ version: String, build: String) throws {
        guard boundedText(version, bytes: 128), boundedText(build, bytes: 128) else {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
    }

    static func validate(
        _ request: CloudGatewayMacControllerRequest, appVersion: String, appBuild: String,
        buildIdentity: CloudGatewayMacBuildIdentity? = nil
    ) throws {
        let compatible = request.action.isCompatibleControl && (request.controlVersion == controlVersion || (request.action == .lifecycle && request.controlVersion == nil && request.schemaVersion == protocolVersion && request.protocolVersion == protocolVersion))
        guard request.action.isCompatibleControl ? compatible : (request.schemaVersion == protocolVersion && request.protocolVersion == protocolVersion) else {
            throw CloudGatewayMacControllerFailure.incompatibleVersion
        }
        try validateVersion(request.appVersion, build: request.appBuild)
        if let identity = request.buildIdentity { try validateBuildIdentity(identity) }
        if let buildIdentity { try validateBuildIdentity(buildIdentity) }
        if !request.action.isCompatibleControl {
            guard request.appVersion == appVersion, request.appBuild == appBuild,
                  buildIdentity == nil || request.buildIdentity == buildIdentity else {
                throw CloudGatewayMacControllerFailure.incompatibleVersion
            }
        }
        switch request.action {
        case .operation, .confirmOperation, .extensionUpdateStarted, .extensionUpdateApproval, .extensionUpdateRestart, .extensionUpdateFinished, .extensionUpdateFailed:
            guard request.contextId != nil, request.identifier == nil, request.regionId == nil, request.clientName == nil else {
                throw CloudGatewayMacControllerFailure.invalidRequest
            }
        case .connect:
            guard let identifier = request.identifier, validIdentifier(identifier),
                  request.regionId == nil, request.clientName == nil, request.contextId == nil else {
                throw CloudGatewayMacControllerFailure.invalidRequest
            }
        case .createClient:
            guard request.identifier == nil, let regionId = request.regionId, validComponent(regionId),
                  let name = request.clientName, boundedText(name, bytes: 320), name.unicodeScalars.count <= 80,
                  name == name.trimmingCharacters(in: .whitespacesAndNewlines), request.contextId != nil else {
                throw CloudGatewayMacControllerFailure.invalidRequest
            }
        default:
            guard request.identifier == nil, request.regionId == nil,
                  request.clientName == nil, request.contextId == nil else {
                throw CloudGatewayMacControllerFailure.invalidRequest
            }
        }
    }

    static func decodeRequest(
        _ data: Data, appVersion: String, appBuild: String, buildIdentity: CloudGatewayMacBuildIdentity? = nil
    ) throws -> CloudGatewayMacControllerRequest {
        guard data.count <= requestBytes,
              let request = try? JSONDecoder().decode(CloudGatewayMacControllerRequest.self, from: data) else {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
        try validate(request, appVersion: appVersion, appBuild: appBuild, buildIdentity: buildIdentity)
        return request
    }

    static func encodeRequest(
        _ request: CloudGatewayMacControllerRequest, appVersion: String, appBuild: String,
        buildIdentity: CloudGatewayMacBuildIdentity? = nil
    ) throws -> Data {
        guard request.schemaVersion == protocolVersion, request.protocolVersion == protocolVersion,
              request.action.isCompatibleControl || request.appVersion.isEmpty || request.appVersion == appVersion,
              request.action.isCompatibleControl || request.appBuild.isEmpty || request.appBuild == appBuild else {
            throw CloudGatewayMacControllerFailure.incompatibleVersion
        }
        if !request.appVersion.isEmpty, !boundedText(request.appVersion, bytes: 128) {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
        if !request.appBuild.isEmpty, !boundedText(request.appBuild, bytes: 128) {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
        let envelope = CloudGatewayMacControllerRequest(
            action: request.action, id: request.id, identifier: request.identifier,
            regionId: request.regionId, clientName: request.clientName, contextId: request.contextId,
            appVersion: appVersion, appBuild: appBuild, buildIdentity: buildIdentity ?? request.buildIdentity
        )
        try validate(envelope, appVersion: appVersion, appBuild: appBuild)
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= requestBytes else { throw CloudGatewayMacControllerFailure.invalidRequest }
        return data
    }

    static func encodeReply(
        _ reply: CloudGatewayMacControllerReply, appVersion: String, appBuild: String, instanceId: UUID,
        action: CloudGatewayMacControllerRequest.Action = .snapshot
    ) -> Data {
        guard (try? validateVersion(appVersion, build: appBuild)) != nil else { return Data() }
        var envelope = reply
        envelope.schemaVersion = protocolVersion
        envelope.protocolVersion = protocolVersion
        envelope.appVersion = appVersion
        envelope.appBuild = appBuild
        envelope.instanceId = instanceId
        if (try? validateReplyContent(envelope, action: action)) != nil,
           let data = try? JSONEncoder().encode(envelope), data.count <= replyBytes {
            return data
        }
        envelope = CloudGatewayMacControllerReply(error: .invalidRequest)
        envelope.appVersion = appVersion
        envelope.appBuild = appBuild
        envelope.instanceId = instanceId
        // Validated version strings and a fixed failure always fit the envelope bound
        return (try? JSONEncoder().encode(envelope)) ?? Data()
    }

    static func decodeReply(
        _ data: Data, appVersion: String, appBuild: String,
        action: CloudGatewayMacControllerRequest.Action = .snapshot
    ) throws -> CloudGatewayMacControllerReply {
        guard data.count <= replyBytes,
              let reply = try? JSONDecoder().decode(CloudGatewayMacControllerReply.self, from: data) else {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
        let compatible = action.isCompatibleControl && (reply.controlVersion == controlVersion || (action == .lifecycle && reply.controlVersion == nil && reply.schemaVersion == protocolVersion && reply.protocolVersion == protocolVersion))
        guard action.isCompatibleControl ? compatible : (reply.schemaVersion == protocolVersion && reply.protocolVersion == protocolVersion
              && reply.appVersion == appVersion && reply.appBuild == appBuild) else {
            throw CloudGatewayMacControllerFailure.incompatibleVersion
        }
        try validateVersion(reply.appVersion, build: reply.appBuild)
        guard reply.instanceId != nil else { throw CloudGatewayMacControllerFailure.invalidRequest }
        try validateReplyContent(reply, action: action)
        return reply
    }

    private static func validateReplyContent(
        _ reply: CloudGatewayMacControllerReply, action: CloudGatewayMacControllerRequest.Action
    ) throws {
        if reply.error != nil {
            guard reply.state == nil, reply.status == nil, reply.operation == nil, reply.accepted == nil, reply.creation == nil,
                  reply.operationId == nil, reply.lifecycle == nil, reply.extensionTarget == nil else {
                throw CloudGatewayMacControllerFailure.invalidRequest
            }
        }
        if action == .lifecycle {
            guard reply.state == nil, reply.status == nil, reply.operation == nil, reply.accepted == nil, reply.creation == nil, reply.operationId == nil,
                  reply.extensionTarget == nil,
                  reply.lifecycle != nil || reply.error != nil else {
                throw CloudGatewayMacControllerFailure.invalidRequest
            }
            try reply.lifecycle?.validate()
        } else if reply.lifecycle != nil {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
        if let target = reply.extensionTarget {
            guard action == .prepareExtensionUpdate, reply.accepted == true, reply.operationId != nil else {
                throw CloudGatewayMacControllerFailure.invalidRequest
            }
            try validateBuildIdentity(target)
        }
        if let status = reply.status {
            guard action.isCompatibleControl else { throw CloudGatewayMacControllerFailure.invalidRequest }
            try status.validate()
        }
        if let operation = reply.operation { try operation.validate() }
        if action.isCompatibleControl && action != .lifecycle {
            guard reply.state == nil, reply.creation == nil, reply.extensionTarget == nil else {
                throw CloudGatewayMacControllerFailure.invalidRequest
            }
        }
        try reply.state?.validate()
        if let creation = reply.creation {
            var identifiers = Set<String>()
            guard creation.regions.count <= 256, creation.regions.allSatisfy({
                validComponent($0.regionId) && identifiers.insert($0.regionId).inserted
                    && boundedText($0.displayName, bytes: 1024) && validCapacity($0.capacity)
            }) else { throw CloudGatewayMacControllerFailure.invalidRequest }
        }
    }

    private static func validCapacity(_ capacity: CloudGatewayRegionCapacity?) -> Bool {
        guard let capacity else { return true }
        switch capacity.status {
        case .unknown: return capacity.limit == nil && capacity.allocated == nil
        case .known:
            guard let limit = capacity.limit, let allocated = capacity.allocated else { return false }
            return limit >= 0 && allocated >= 0
        }
    }

    static func boundedText(_ value: String, bytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= bytes && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func validComponent(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return !value.isEmpty && value.utf8.count <= 256 && value != "." && value != ".."
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func validIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return value.utf8.count <= 1024 && parts.count == 3 && parts.allSatisfy { validComponent(String($0)) }
    }

    static func validChallenge(code: String, url: URL) -> Bool {
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }),
              url.absoluteString.utf8.count <= 2048,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "gocloudlaunch.com",
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil,
              components.path == "/", components.query == nil,
              let fragment = components.fragment else { return false }
        let prefix = "/auth/code?deviceRequestId="
        let suffix = "&userCode=\(code)"
        guard fragment.hasPrefix(prefix), fragment.hasSuffix(suffix) else { return false }
        let requestId = String(fragment.dropFirst(prefix.count).dropLast(suffix.count))
        return requestId.utf8.count == 32 && requestId.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

extension CloudGatewayMacControllerRequest.Action {
    public var isCompatibleControl: Bool {
        switch self {
        case .lifecycle, .status, .turnOff, .confirmOperation, .operation: true
        default: false
        }
    }

    var requiresConfirmation: Bool {
        switch self {
        case .signIn, .cancelSignIn, .signOut, .connect, .turnOff, .createClient: true
        default: false
        }
    }
}
