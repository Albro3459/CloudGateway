import CloudGatewayKit
import Foundation

public enum CloudGatewayMacControllerFailure: String, Error, Codable, Sendable {
    case invalidRequest, incompatibleVersion, unavailable, timeout, busy, rejected
}

public struct CloudGatewayMacControllerRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable {
        case snapshot, menuWillOpen, refresh, signIn, cancelSignIn, signOut, connect, turnOff, prepareClient, createClient
    }

    public let schemaVersion: Int
    public let protocolVersion: Int
    public let appVersion: String
    public let appBuild: String
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
        appBuild: String = ""
    ) {
        schemaVersion = CloudGatewayMacControllerProtocol.protocolVersion
        protocolVersion = CloudGatewayMacControllerProtocol.protocolVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
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
    public let snapshot: CloudGatewayMacControllerView?
    public let accepted: Bool?
    public let creation: Creation?
    public let error: CloudGatewayMacControllerFailure?
    public let operationId: UUID?

    public init(
        snapshot: CloudGatewayMacControllerView? = nil,
        accepted: Bool? = nil,
        creation: Creation? = nil,
        error: CloudGatewayMacControllerFailure? = nil,
        operationId: UUID? = nil
    ) {
        schemaVersion = CloudGatewayMacControllerProtocol.protocolVersion
        protocolVersion = CloudGatewayMacControllerProtocol.protocolVersion
        appVersion = ""
        appBuild = ""
        instanceId = nil
        self.snapshot = snapshot
        self.accepted = accepted
        self.creation = creation
        self.error = error
        self.operationId = operationId
    }
}

public enum CloudGatewayMacControllerProtocol {
    public static let protocolVersion = 1
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

    static func validate(_ request: CloudGatewayMacControllerRequest, appVersion: String, appBuild: String) throws {
        guard request.schemaVersion == protocolVersion, request.protocolVersion == protocolVersion,
              request.appVersion == appVersion, request.appBuild == appBuild else {
            throw CloudGatewayMacControllerFailure.incompatibleVersion
        }
        switch request.action {
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

    static func decodeRequest(_ data: Data, appVersion: String, appBuild: String) throws -> CloudGatewayMacControllerRequest {
        guard data.count <= requestBytes,
              let request = try? JSONDecoder().decode(CloudGatewayMacControllerRequest.self, from: data) else {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
        try validate(request, appVersion: appVersion, appBuild: appBuild)
        return request
    }

    static func encodeRequest(
        _ request: CloudGatewayMacControllerRequest, appVersion: String, appBuild: String
    ) throws -> Data {
        guard request.schemaVersion == protocolVersion, request.protocolVersion == protocolVersion,
              request.appVersion.isEmpty || request.appVersion == appVersion,
              request.appBuild.isEmpty || request.appBuild == appBuild else {
            throw CloudGatewayMacControllerFailure.incompatibleVersion
        }
        let envelope = CloudGatewayMacControllerRequest(
            action: request.action, id: request.id, identifier: request.identifier,
            regionId: request.regionId, clientName: request.clientName, contextId: request.contextId,
            appVersion: appVersion, appBuild: appBuild
        )
        try validate(envelope, appVersion: appVersion, appBuild: appBuild)
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= requestBytes else { throw CloudGatewayMacControllerFailure.invalidRequest }
        return data
    }

    static func encodeReply(
        _ reply: CloudGatewayMacControllerReply, appVersion: String, appBuild: String, instanceId: UUID
    ) -> Data {
        var envelope = reply
        envelope.schemaVersion = protocolVersion
        envelope.protocolVersion = protocolVersion
        envelope.appVersion = appVersion
        envelope.appBuild = appBuild
        envelope.instanceId = instanceId
        if (try? validateReplyContent(envelope)) != nil,
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

    static func decodeReply(_ data: Data, appVersion: String, appBuild: String) throws -> CloudGatewayMacControllerReply {
        guard data.count <= replyBytes,
              let reply = try? JSONDecoder().decode(CloudGatewayMacControllerReply.self, from: data) else {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
        guard reply.schemaVersion == protocolVersion, reply.protocolVersion == protocolVersion,
              reply.appVersion == appVersion, reply.appBuild == appBuild else {
            throw CloudGatewayMacControllerFailure.incompatibleVersion
        }
        guard reply.instanceId != nil else { throw CloudGatewayMacControllerFailure.invalidRequest }
        try validateReplyContent(reply)
        return reply
    }

    private static func validateReplyContent(_ reply: CloudGatewayMacControllerReply) throws {
        if reply.error != nil {
            guard reply.snapshot == nil, reply.accepted == nil, reply.creation == nil, reply.operationId == nil else {
                throw CloudGatewayMacControllerFailure.invalidRequest
            }
        }
        try reply.snapshot?.validate()
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
