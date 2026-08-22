import Foundation

// `CloudGatewayRegionSyncResponse` (in `CloudGatewayPassiveContracts.swift`) keeps its historical
// `Decodable` conformance, which requires `meshPeers`' element type to be `Decodable` too for automatic
// synthesis. Neither this type nor `CloudGatewayMeshPeerStatus` needs `Decodable` for validation —
// every response is validated through `CloudGatewayRegionSyncParsing.parse(data:requestedRegionId:)` —
// these conformances exist purely so the containing struct's synthesized `init(from:)` compiles.
extension CloudGatewayMeshPeerStatus: Decodable {}

public struct CloudGatewayRegionSyncMeshPeer: Decodable, Equatable, Sendable {
    public let regionId: String
    public let status: CloudGatewayMeshPeerStatus
    public let endpointHostname: String?
    public let endpointPort: Int?
    public let allowedNetworkV4: String?
    public let allowedNetworkV6: String?
    public let reasonCode: String?

    public init(
        regionId: String,
        status: CloudGatewayMeshPeerStatus,
        endpointHostname: String?,
        endpointPort: Int?,
        allowedNetworkV4: String?,
        allowedNetworkV6: String?,
        reasonCode: String?
    ) {
        self.regionId = regionId
        self.status = status
        self.endpointHostname = endpointHostname
        self.endpointPort = endpointPort
        self.allowedNetworkV4 = allowedNetworkV4
        self.allowedNetworkV6 = allowedNetworkV6
        self.reasonCode = reasonCode
    }
}

public struct CloudGatewayRegionSyncOutcome: Equatable, Sendable, Identifiable {
    public enum Result: Equatable, Sendable {
        case success(CloudGatewayRegionSyncResponse)
        case alreadyRunning
        case failure(message: String, requestId: String?, isIncompatibleResponse: Bool)
    }

    public var id: String { regionId }
    public let regionId: String
    public let result: Result

    public init(regionId: String, result: Result) {
        self.regionId = regionId
        self.result = result
    }
}

/// Port of `parseRegionSyncResponse` and friends in `Frontend/Web/src/helpers/APIHelper.ts`
/// (lines ~404-612). Decodes the wire response into a lenient `JSONValue` tree first so absent,
/// explicit-`null`, and wrong-type fields can be told apart exactly like the TS `unknown`-typed
/// parser does, then validates and builds the strict domain model.
public enum CloudGatewayRegionSyncParsing {
    /// Strict parse + `response.regionId == requestedRegionId`. `nil` means an incompatible response.
    public static func parse(data: Data, requestedRegionId: String) -> CloudGatewayRegionSyncResponse? {
        guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              let response = parseRegionSyncResponse(object),
              response.regionId == requestedRegionId else {
            return nil
        }
        return response
    }

    /// ISO8601 with fractional seconds first, then without. Handles `Z` and `+00:00`.
    public static func syncedAtDate(_ value: String) -> Date? {
        fractionalSecondsFormatter.date(from: value) ?? plainFormatter.date(from: value)
    }

    // Built per call rather than cached: ISO8601DateFormatter is not Sendable, and the fan-out
    // parses a handful of responses, so a shared instance would buy nothing worth the unsafety.
    private static var fractionalSecondsFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static var plainFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    // Exact strings from APIHelper.ts `regionSyncReasonCodes`.
    private static let regionSyncReasonCodes: Set<String> = [
        "missing-public-key", "invalid-public-key", "missing-endpoint-hostname",
        "invalid-endpoint-hostname", "invalid-endpoint-port", "missing-network-v4",
        "invalid-network-v4", "missing-network-v6", "invalid-network-v6", "outside-aggregate",
        "duplicate-public-key", "local-network-invalid", "overlap-local", "overlap-candidate",
    ]

    private static func parseRegionSyncResponse(_ dict: [String: JSONValue]) -> CloudGatewayRegionSyncResponse? {
        guard let regionId = nonEmptyString(dict, "regionId") else { return nil }
        guard let syncedAt = nonEmptyString(dict, "syncedAt"), syncedAtDate(syncedAt) != nil else { return nil }
        guard let log = dict.stringValue("log") else { return nil }
        guard let noChanges = dict.boolValue("noChanges") else { return nil }
        guard let meshEnabled = dict.boolValue("meshEnabled") else { return nil }

        guard let added = nonNegativeInt(dict, "added"),
              let updated = nonNegativeInt(dict, "updated"),
              let removed = nonNegativeInt(dict, "removed"),
              let meshUpdated = nonNegativeInt(dict, "meshUpdated"),
              let meshApplied = nonNegativeInt(dict, "meshApplied"),
              let meshAdded = nonNegativeInt(dict, "meshAdded"),
              let meshRemoved = nonNegativeInt(dict, "meshRemoved"),
              let meshSkipped = nonNegativeInt(dict, "meshSkipped"),
              let meshRoutesAdded = nonNegativeInt(dict, "meshRoutesAdded"),
              let meshRoutesRemoved = nonNegativeInt(dict, "meshRoutesRemoved") else {
            return nil
        }

        guard let rawPeers = dict.arrayValue("meshPeers") else { return nil }
        var meshPeers: [CloudGatewayRegionSyncMeshPeer] = []
        for rawPeer in rawPeers {
            guard let peerDict = rawPeer.objectValue, let peer = parsePeer(peerDict) else { return nil }
            meshPeers.append(peer)
        }

        // Deliberately not required: absent means an older regional API, which must stay
        // compatible. A present non-boolean (including explicit null) is still malformed.
        let meshStatusWritten: Bool?
        if dict["meshStatusWritten"] != nil {
            guard let written = dict.boolValue("meshStatusWritten") else { return nil }
            meshStatusWritten = written
        } else {
            meshStatusWritten = nil
        }

        // Same compatibility story for the account-scoped ACL policy fields, matching
        // APIHelper.ts: absent means an older regional API that predates policy sync
        // entirely, unknown and never a failure. A present value of the wrong shape
        // (including explicit null) still rejects the whole response, exactly like
        // meshStatusWritten above. No relationship is enforced among the three - the
        // web parser does not require rowCount only alongside a true policyApplied.
        let policyApplied: Bool?
        if dict["policyApplied"] != nil {
            guard let applied = dict.boolValue("policyApplied") else { return nil }
            policyApplied = applied
        } else {
            policyApplied = nil
        }

        // Reuses nonNegativeInt, which already rejects non-`.int` JSONValues - so a
        // fractional rowCount (decoded as `.double`) is rejected here, unlike the
        // Firestore policy mapper's `Int?` coercion, which has no such host-side
        // guarantee to lean on and so does not enforce non-negativity.
        let policyRowCount: Int?
        if dict["policyRowCount"] != nil {
            guard let rowCount = nonNegativeInt(dict, "policyRowCount") else { return nil }
            policyRowCount = rowCount
        } else {
            policyRowCount = nil
        }

        let policyStatusWritten: Bool?
        if dict["policyStatusWritten"] != nil {
            guard let written = dict.boolValue("policyStatusWritten") else { return nil }
            policyStatusWritten = written
        } else {
            policyStatusWritten = nil
        }

        return CloudGatewayRegionSyncResponse(
            regionId: regionId,
            syncedAt: syncedAt,
            added: added,
            updated: updated,
            removed: removed,
            noChanges: noChanges,
            log: log,
            meshUpdated: meshUpdated,
            meshEnabled: meshEnabled,
            meshApplied: meshApplied,
            meshAdded: meshAdded,
            meshRemoved: meshRemoved,
            meshSkipped: meshSkipped,
            meshRoutesAdded: meshRoutesAdded,
            meshRoutesRemoved: meshRoutesRemoved,
            meshStatusWritten: meshStatusWritten,
            meshPeers: meshPeers,
            policyApplied: policyApplied,
            policyRowCount: policyRowCount,
            policyStatusWritten: policyStatusWritten
        )
    }

    private static func parsePeer(_ dict: [String: JSONValue]) -> CloudGatewayRegionSyncMeshPeer? {
        switch dict.stringValue("status") {
        case CloudGatewayMeshPeerStatus.applied.rawValue:
            return parseRequiredMeshPeer(dict, status: .applied)
        case CloudGatewayMeshPeerStatus.skippedOverlap.rawValue:
            return parseRequiredMeshPeer(dict, status: .skippedOverlap)
        case CloudGatewayMeshPeerStatus.skippedIncomplete.rawValue:
            return parseIncompleteMeshPeer(dict)
        default:
            return nil
        }
    }

    private static func parseRequiredMeshPeer(
        _ dict: [String: JSONValue],
        status: CloudGatewayMeshPeerStatus
    ) -> CloudGatewayRegionSyncMeshPeer? {
        guard let regionId = nonEmptyString(dict, "regionId") else { return nil }

        let endpointHostname = dict.stringValue("endpointHostname")
        let endpointPort = dict.intValue("endpointPort")
        let allowedNetworkV4 = dict.stringValue("allowedNetworkV4")
        let allowedNetworkV6 = dict.stringValue("allowedNetworkV6")
        guard CloudGatewayMeshValidation.isValidEndpointHostname(endpointHostname),
              CloudGatewayMeshValidation.isValidMeshEndpointPort(endpointPort),
              CloudGatewayMeshValidation.isValidMeshNetworkV4(allowedNetworkV4),
              CloudGatewayMeshValidation.isValidMeshNetworkV6(allowedNetworkV6) else {
            return nil
        }

        let reasonCode: String?
        switch parseReasonCode(dict) {
        case .unknownOrInvalid:
            // Present, and neither undefined nor null, but not a known reason code: malformed
            // for every status.
            return nil
        case .absent, .explicitNull:
            // skipped-overlap requires a known reason code; applied does not.
            guard status != .skippedOverlap else { return nil }
            reasonCode = nil
        case .known(let value):
            reasonCode = value
        }

        return CloudGatewayRegionSyncMeshPeer(
            regionId: regionId,
            status: status,
            endpointHostname: endpointHostname,
            endpointPort: endpointPort,
            allowedNetworkV4: allowedNetworkV4,
            allowedNetworkV6: allowedNetworkV6,
            reasonCode: reasonCode
        )
    }

    private static func parseIncompleteMeshPeer(_ dict: [String: JSONValue]) -> CloudGatewayRegionSyncMeshPeer? {
        guard let regionId = nonEmptyString(dict, "regionId") else { return nil }
        guard case .known(let reasonCode) = parseReasonCode(dict) else { return nil }

        let hostname = parseOptionalNonBlankField(
            dict,
            key: "endpointHostname",
            decode: JSONValue.stringOrNil,
            isValid: CloudGatewayMeshValidation.isValidEndpointHostname
        )
        let port = parseOptionalNonBlankField(
            dict,
            key: "endpointPort",
            decode: JSONValue.intOrNil,
            isValid: CloudGatewayMeshValidation.isValidMeshEndpointPort
        )
        let networkV4 = parseOptionalNonBlankField(
            dict,
            key: "allowedNetworkV4",
            decode: JSONValue.stringOrNil,
            isValid: CloudGatewayMeshValidation.isValidMeshNetworkSyntaxV4
        )
        let networkV6 = parseOptionalNonBlankField(
            dict,
            key: "allowedNetworkV6",
            decode: JSONValue.stringOrNil,
            isValid: CloudGatewayMeshValidation.isValidMeshNetworkSyntaxV6
        )
        if case .invalid = hostname { return nil }
        if case .invalid = port { return nil }
        if case .invalid = networkV4 { return nil }
        if case .invalid = networkV6 { return nil }

        return CloudGatewayRegionSyncMeshPeer(
            regionId: regionId,
            status: .skippedIncomplete,
            endpointHostname: hostname.value,
            endpointPort: port.value,
            allowedNetworkV4: networkV4.value,
            allowedNetworkV6: networkV6.value,
            reasonCode: reasonCode
        )
    }

    // MARK: - Reason code

    private enum ReasonCodeParseResult: Equatable {
        case absent
        case explicitNull
        case known(String)
        case unknownOrInvalid
    }

    private static func parseReasonCode(_ dict: [String: JSONValue]) -> ReasonCodeParseResult {
        guard let raw = dict["reasonCode"] else { return .absent }
        if case .null = raw { return .explicitNull }
        if case .string(let value) = raw, regionSyncReasonCodes.contains(value) { return .known(value) }
        return .unknownOrInvalid
    }

    // MARK: - Optional non-blank fields (skipped-incomplete only)

    private enum OptionalFieldResult<T> {
        case omitted
        case invalid
        case value(T)

        var value: T? {
            if case .value(let value) = self { return value }
            return nil
        }
    }

    /// Absent, explicit null, and (for strings) blank all mean "omitted" and are not malformed.
    /// A present, non-blank value must pass `isValid`; if it does not, the whole peer is rejected.
    private static func parseOptionalNonBlankField<T>(
        _ dict: [String: JSONValue],
        key: String,
        decode: (JSONValue) -> T?,
        isValid: (T?) -> Bool
    ) -> OptionalFieldResult<T> {
        guard let raw = dict[key] else { return .omitted }
        if case .null = raw { return .omitted }
        if case .string(let value) = raw, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .omitted
        }
        guard let decoded = decode(raw), isValid(decoded) else { return .invalid }
        return .value(decoded)
    }

    // MARK: - Typed accessors

    private static func nonEmptyString(_ dict: [String: JSONValue], _ key: String) -> String? {
        guard let value = dict.stringValue(key),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func nonNegativeInt(_ dict: [String: JSONValue], _ key: String) -> Int? {
        guard let value = dict.intValue(key), value >= 0 else { return nil }
        return value
    }
}

/// Minimal parsed-JSON tree that preserves the distinction between "key absent", "key present
/// with `null`", and "key present with the wrong type" — the same distinctions TS gets for free
/// from `unknown`. `Int` is only produced for JSON numbers with no fractional part, matching
/// JS `Number.isInteger`.
private enum JSONValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    static func stringOrNil(_ value: JSONValue) -> String? {
        if case .string(let value) = value { return value }
        return nil
    }

    static func intOrNil(_ value: JSONValue) -> Int? {
        if case .int(let value) = value { return value }
        return nil
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func stringValue(_ key: String) -> String? {
        JSONValue.stringOrNil(self[key] ?? .null)
    }

    func intValue(_ key: String) -> Int? {
        JSONValue.intOrNil(self[key] ?? .null)
    }

    func boolValue(_ key: String) -> Bool? {
        if case .bool(let value)? = self[key] { return value }
        return nil
    }

    func arrayValue(_ key: String) -> [JSONValue]? {
        if case .array(let value)? = self[key] { return value }
        return nil
    }
}
