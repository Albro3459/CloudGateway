import Foundation

/// Pure `[String: Any]` -> model mapping for `Regions/*` (mesh-relevant fields only) and `Mesh/*`
/// documents. No Firebase import: the repository converts `Timestamp` -> `Date` recursively before
/// calling this, so every date value this mapper sees is already a `Date`.
///
/// Ports `parseRegionDocument` (`regionsHelper.ts`) and `parseMeshDocument` / `parseMeshPeerEntry`
/// (`meshHelper.ts`). Coercion matches `Frontend/Web/src/helpers/coerce.ts`.
public enum CloudGatewayFirestoreMeshMapper {
    /// nil when the doc has no usable displayName / regionId (web `parseRegionDocument` returns null).
    public static func meshRegion(documentId: String, data: [String: Any]) -> CloudGatewayMeshRegion? {
        guard !documentId.isEmpty, let displayName = string(data["displayName"]) else { return nil }
        return CloudGatewayMeshRegion(
            regionId: documentId,
            displayName: displayName,
            enabled: isTrue(data["enabled"]),
            displayOrder: displayOrder(data["displayOrder"], defaultValue: 1000),
            meshEnabled: isTrue(data["meshEnabled"]),
            wireguardPublicKey: string(data["wireguardPublicKey"]),
            wireguardEndpointHostname: string(data["wireguardEndpointHostname"]),
            wireguardPort: meshPort(data["wireguardPort"]),
            tunnelNetworkV4: string(data["tunnelNetworkV4"]),
            tunnelNetworkV6: string(data["tunnelNetworkV6"])
        )
    }

    /// Always succeeds; unparseable peer entries are dropped (web `parseMeshDocument`).
    public static func meshDoc(documentId: String, data: [String: Any]) -> CloudGatewayMeshDoc {
        let rawPeers = data["peers"] as? [String: Any] ?? [:]
        var peers: [String: CloudGatewayMeshPeerEntry] = [:]
        for (peerRegionId, rawEntry) in rawPeers {
            if let entry = meshPeerEntry(rawEntry) {
                peers[peerRegionId] = entry
            }
        }

        return CloudGatewayMeshDoc(
            regionId: documentId,
            meshEnabled: isTrue(data["meshEnabled"]),
            updatedAt: date(data["updatedAt"]),
            peers: peers
        )
    }

    // MARK: - Private helpers

    private static func meshPeerEntry(_ raw: Any?) -> CloudGatewayMeshPeerEntry? {
        guard let entry = raw as? [String: Any] else { return nil }
        guard let statusRaw = entry["status"] as? String, let status = CloudGatewayMeshPeerStatus(rawValue: statusRaw) else {
            return nil
        }

        let endpointHostname = string(entry["endpointHostname"])
        let endpointPort = meshPort(entry["endpointPort"])
        let publicKey = string(entry["publicKey"])
        let allowedNetworkV4 = string(entry["allowedNetworkV4"])
        let allowedNetworkV6 = string(entry["allowedNetworkV6"])
        let reasonCode = string(entry["reasonCode"])
        let appliedAt = date(entry["appliedAt"])

        // Skipped-incomplete is deliberately status-first. Its empty fields are
        // useful operator evidence and must survive parsing. Applied and overlap
        // snapshots require the complete current metadata, including endpointPort.
        if status == .skippedIncomplete {
            return CloudGatewayMeshPeerEntry(
                endpointHostname: endpointHostname, endpointPort: endpointPort, publicKey: publicKey,
                allowedNetworkV4: allowedNetworkV4, allowedNetworkV6: allowedNetworkV6,
                status: status, reasonCode: reasonCode, appliedAt: appliedAt
            )
        }

        guard let endpointHostname, CloudGatewayMeshValidation.isValidEndpointHostname(endpointHostname),
              CloudGatewayMeshValidation.isValidMeshEndpointPort(endpointPort),
              let publicKey, CloudGatewayMeshValidation.isValidWireGuardPublicKey(publicKey),
              let allowedNetworkV4, CloudGatewayMeshValidation.isValidMeshNetworkV4(allowedNetworkV4),
              let allowedNetworkV6, CloudGatewayMeshValidation.isValidMeshNetworkV6(allowedNetworkV6) else {
            return nil
        }

        return CloudGatewayMeshPeerEntry(
            endpointHostname: endpointHostname, endpointPort: endpointPort, publicKey: publicKey,
            allowedNetworkV4: allowedNetworkV4, allowedNetworkV6: allowedNetworkV6,
            status: status, reasonCode: reasonCode, appliedAt: appliedAt
        )
    }

    /// TS `stringOrNull` returns the ORIGINAL untrimmed value when its trimmed form is non-empty.
    /// Deliberately not `CloudGatewayFirestoreClientMapper.string`, which trims: matching
    /// `stringOrNull` byte-for-byte keeps "current snapshot" comparisons (mesh peer entry vs.
    /// region field) identical between the web and iOS ports.
    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private static func displayOrder(_ value: Any?, defaultValue: Int) -> Int {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return integer(number.doubleValue) ?? defaultValue
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let parsed = Double(trimmed) {
                return integer(parsed) ?? defaultValue
            }
        }
        return defaultValue
    }

    /// Firestore bridges both real booleans and plain numbers to `NSNumber`, and on Apple
    /// platforms `NSNumber as? Bool` spuriously succeeds for non-boolean numeric values. Only a
    /// `CFBoolean`-backed `NSNumber` is trusted, matching the web's strict `=== true` check.
    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    /// Rejects non-integral values (a Firestore `Double` like `51820.5`) and real booleans, since
    /// both can bridge through `NSNumber` alongside legitimate integer ports.
    private static func meshPort(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.truncatingRemainder(dividingBy: 1) == 0, let port = integer(double) else { return nil }
        return CloudGatewayMeshValidation.isValidMeshEndpointPort(port) ? port : nil
    }

    /// `Int(_: Double)` traps on NaN, infinity, and anything outside `Int`'s range, so a corrupt
    /// Firestore number must be rejected before the conversion rather than after it.
    private static func integer(_ value: Double) -> Int? {
        guard value.isFinite,
              value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    private static func date(_ value: Any?) -> Date? {
        value as? Date
    }
}
