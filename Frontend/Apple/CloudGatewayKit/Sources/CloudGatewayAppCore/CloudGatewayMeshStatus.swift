import Foundation

/// Direct port of `Frontend/Web/src/helpers/meshHelper.ts`. Keep in lockstep with that file.
///
/// `[String: CloudGatewayMeshDoc]` plays the role of the web's `Map<regionId, MeshDoc | null>`:
/// an absent key here is the TS `null` case (a region that has never completed a sync pass).
public enum CloudGatewayMeshPeerStatus: String, Equatable, Sendable {
    case applied = "applied"
    case skippedOverlap = "skipped-overlap"
    case skippedIncomplete = "skipped-incomplete"
}

public struct CloudGatewayMeshPeerEntry: Equatable, Sendable {
    public let endpointHostname: String?
    public let endpointPort: Int?
    public let publicKey: String?
    public let allowedNetworkV4: String?
    public let allowedNetworkV6: String?
    public let status: CloudGatewayMeshPeerStatus
    public let reasonCode: String?
    public let appliedAt: Date?

    public init(
        endpointHostname: String?, endpointPort: Int?, publicKey: String?,
        allowedNetworkV4: String?, allowedNetworkV6: String?,
        status: CloudGatewayMeshPeerStatus, reasonCode: String?, appliedAt: Date?
    ) {
        self.endpointHostname = endpointHostname
        self.endpointPort = endpointPort
        self.publicKey = publicKey
        self.allowedNetworkV4 = allowedNetworkV4
        self.allowedNetworkV6 = allowedNetworkV6
        self.status = status
        self.reasonCode = reasonCode
        self.appliedAt = appliedAt
    }
}

public struct CloudGatewayMeshDoc: Equatable, Sendable {
    public let regionId: String
    public let meshEnabled: Bool
    public let updatedAt: Date?
    public let peers: [String: CloudGatewayMeshPeerEntry]

    public init(regionId: String, meshEnabled: Bool, updatedAt: Date?, peers: [String: CloudGatewayMeshPeerEntry]) {
        self.regionId = regionId
        self.meshEnabled = meshEnabled
        self.updatedAt = updatedAt
        self.peers = peers
    }
}

public struct CloudGatewayMeshRegion: Equatable, Sendable, Identifiable {
    public var id: String { regionId }
    public let regionId: String
    public let displayName: String
    public let enabled: Bool
    public let displayOrder: Int
    public let meshEnabled: Bool
    public let wireguardPublicKey: String?
    public let wireguardEndpointHostname: String?
    public let wireguardPort: Int?
    public let tunnelNetworkV4: String?
    public let tunnelNetworkV6: String?

    public init(
        regionId: String, displayName: String, enabled: Bool, displayOrder: Int,
        meshEnabled: Bool, wireguardPublicKey: String?, wireguardEndpointHostname: String?,
        wireguardPort: Int?, tunnelNetworkV4: String?, tunnelNetworkV6: String?
    ) {
        self.regionId = regionId
        self.displayName = displayName
        self.enabled = enabled
        self.displayOrder = displayOrder
        self.meshEnabled = meshEnabled
        self.wireguardPublicKey = wireguardPublicKey
        self.wireguardEndpointHostname = wireguardEndpointHostname
        self.wireguardPort = wireguardPort
        self.tunnelNetworkV4 = tunnelNetworkV4
        self.tunnelNetworkV6 = tunnelNetworkV6
    }
}

public enum CloudGatewayMeshLinkStatus: Equatable, Sendable {
    case bothApplied, oneSided, notSynced, stale
}

public struct CloudGatewayMeshLinkRow: Equatable, Sendable, Identifiable {
    public var id: String { "\(regionAId)-\(regionBId)" }
    public let regionAId: String
    public let regionBId: String
    public let status: CloudGatewayMeshLinkStatus
    public let pending: Bool
    // Status of the peer entry each side recorded for the other direction;
    // nil means that side has no entry for the peer at all (not just skipped).
    public let aToB: CloudGatewayMeshPeerStatus?
    public let bToA: CloudGatewayMeshPeerStatus?
    public let aToBCurrent: Bool
    public let bToACurrent: Bool
    public let aToBStale: Bool
    public let bToAStale: Bool
}

/// The web's `MeshWarning` also carries the skipped peer's snapshot fields, but neither
/// dashboard renders them - the reason code is what an operator acts on. They are omitted
/// here rather than carried dead; `Mesh/*` still holds them if a future surface needs them.
public struct CloudGatewayMeshWarning: Equatable, Sendable, Identifiable {
    public var id: String { "\(regionId)-\(peerRegionId)" }
    public let regionId: String
    public let peerRegionId: String
    public let status: CloudGatewayMeshPeerStatus // only .skippedOverlap / .skippedIncomplete
    public let reasonCode: String?
    /// When the recording host wrote this skip. Rendered so an operator can tell a skip that
    /// survived the last sync from one left over by a host that has not run since.
    public let appliedAt: Date?
}

public enum CloudGatewayMeshStaleness: Equatable, Sendable {
    case unknown, fresh, stale
}

public enum CloudGatewayMeshStatus {
    // Manual-first sync (no timer), so this only flags "this hasn't run
    // recently" for operator awareness - it is not a health/error signal.
    public static let meshStaleThreshold: TimeInterval = 24 * 60 * 60

    // A region is pending when its desired flag (Regions.meshEnabled) disagrees
    // with what its host last applied (Mesh.meshEnabled), or it wants in but has
    // never synced (no Mesh doc yet). A disabled region has no operational server
    // and is not a Sync All target, so its own Mesh doc can never be reconciled -
    // reporting it as pending would be a warning nothing can clear.
    public static func isRegionMeshPending(region: CloudGatewayMeshRegion, meshDoc: CloudGatewayMeshDoc?) -> Bool {
        guard region.enabled else { return false }
        let desired = region.meshEnabled
        guard let meshDoc else { return desired }
        return desired != meshDoc.meshEnabled
    }

    // One row per unordered region pair (a graph's links, not a per-region list),
    // so an asymmetric failure ("one-sided") is visible instead of being rendered
    // twice from opposite sides. Iterates `regions` by index in the given order
    // (caller passes them sorted), pairing i < j.
    public static func buildMeshLinkRows(
        regions: [CloudGatewayMeshRegion],
        meshDocs: [String: CloudGatewayMeshDoc]
    ) -> [CloudGatewayMeshLinkRow] {
        var rows: [CloudGatewayMeshLinkRow] = []

        for i in 0..<regions.count {
            for j in (i + 1)..<regions.count {
                let a = regions[i]
                let b = regions[j]
                let meshDocA = meshDocs[a.regionId]
                let meshDocB = meshDocs[b.regionId]
                let entryA = peerFor(meshDocA, b.regionId)
                let entryB = peerFor(meshDocB, a.regionId)
                let aToBCurrent = isCurrentAppliedPeer(entryA, b)
                let bToACurrent = isCurrentAppliedPeer(entryB, a)
                let aToBStale = isStaleAppliedPeer(entryA, b)
                let bToAStale = isStaleAppliedPeer(entryB, a)

                let status: CloudGatewayMeshLinkStatus
                if aToBStale || bToAStale {
                    status = .stale
                } else if aToBCurrent && bToACurrent {
                    status = .bothApplied
                } else if aToBCurrent || bToACurrent {
                    status = .oneSided
                } else {
                    status = .notSynced
                }

                // A link is only desired when both sides are live mesh members;
                // a disabled region is dead, so its peers must come down even
                // though its meshEnabled flag may still read true.
                let bothMeshDesired = a.enabled && b.enabled && a.meshEnabled && b.meshEnabled
                let membershipPending = isRegionMeshPending(region: a, meshDoc: meshDocA)
                    || isRegionMeshPending(region: b, meshDoc: meshDocB)
                // Only a live host runs a sync pass, so only a live host's own
                // stale entry is something Sync All can still reconcile.
                let removalPending = !bothMeshDesired && (
                    (a.enabled && entryA?.status == .applied) || (b.enabled && entryB?.status == .applied)
                )
                let desiredDirectionPending = bothMeshDesired && (
                    isDirectionPending(entryA, b, a, regions) || isDirectionPending(entryB, a, b, regions)
                )

                rows.append(CloudGatewayMeshLinkRow(
                    regionAId: a.regionId,
                    regionBId: b.regionId,
                    status: status,
                    pending: membershipPending || removalPending || desiredDirectionPending,
                    aToB: entryA?.status,
                    bToA: entryB?.status,
                    aToBCurrent: aToBCurrent,
                    bToACurrent: bToACurrent,
                    aToBStale: aToBStale,
                    bToAStale: bToAStale
                ))
            }
        }

        return rows
    }

    // True when a toggle or a missing/unsynced link means Sync All would still
    // change something on some host.
    public static func hasAnyMeshPending(
        regions: [CloudGatewayMeshRegion],
        meshDocs: [String: CloudGatewayMeshDoc]
    ) -> Bool {
        if regions.contains(where: { isRegionMeshPending(region: $0, meshDoc: meshDocs[$0.regionId]) }) {
            return true
        }
        return buildMeshLinkRows(regions: regions, meshDocs: meshDocs).contains { $0.pending }
    }

    // Per-region judgments (a claimed CIDR overlapping another region's, or an
    // incomplete peer doc) that don't belong on a link row.
    //
    // Swift `Dictionary` iteration order is unspecified (unlike the web's Map
    // insertion order), so the result is sorted by (regionId, peerRegionId)
    // ascending for a deterministic UI.
    public static func collectMeshWarnings(_ meshDocs: [String: CloudGatewayMeshDoc]) -> [CloudGatewayMeshWarning] {
        var warnings: [CloudGatewayMeshWarning] = []

        for meshDoc in meshDocs.values {
            for (peerRegionId, entry) in meshDoc.peers {
                guard entry.status == .skippedOverlap || entry.status == .skippedIncomplete else { continue }
                warnings.append(CloudGatewayMeshWarning(
                    regionId: meshDoc.regionId,
                    peerRegionId: peerRegionId,
                    status: entry.status,
                    reasonCode: entry.reasonCode,
                    appliedAt: entry.appliedAt
                ))
            }
        }

        return warnings.sorted { lhs, rhs in
            lhs.regionId != rhs.regionId ? lhs.regionId < rhs.regionId : lhs.peerRegionId < rhs.peerRegionId
        }
    }

    public static func meshStaleness(updatedAt: Date?, now: Date = Date()) -> CloudGatewayMeshStaleness {
        guard let updatedAt else { return .unknown }
        return now.timeIntervalSince(updatedAt) > meshStaleThreshold ? .stale : .fresh
    }

    // MARK: - Private helpers

    private struct MeshSnapshot {
        let publicKey: String?
        let endpointHostname: String?
        let endpointPort: Int?
        let allowedNetworkV4: String?
        let allowedNetworkV6: String?
    }

    private enum MeshSnapshotField {
        case publicKey, endpointHostname, endpointPort, allowedNetworkV4, allowedNetworkV6
    }

    private static func peerFor(_ meshDoc: CloudGatewayMeshDoc?, _ peerRegionId: String) -> CloudGatewayMeshPeerEntry? {
        meshDoc?.peers[peerRegionId]
    }

    private static func getRegionMeshSnapshot(_ region: CloudGatewayMeshRegion) -> MeshSnapshot {
        MeshSnapshot(
            publicKey: region.wireguardPublicKey,
            endpointHostname: region.wireguardEndpointHostname,
            endpointPort: region.wireguardPort,
            allowedNetworkV4: region.tunnelNetworkV4,
            allowedNetworkV6: region.tunnelNetworkV6
        )
    }

    private static func hasCompleteMeshSnapshot(_ region: CloudGatewayMeshRegion) -> Bool {
        let snapshot = getRegionMeshSnapshot(region)
        return CloudGatewayMeshValidation.isValidWireGuardPublicKey(snapshot.publicKey)
            && CloudGatewayMeshValidation.isValidEndpointHostname(snapshot.endpointHostname)
            && CloudGatewayMeshValidation.isValidMeshNetworkV4(snapshot.allowedNetworkV4)
            && CloudGatewayMeshValidation.isValidMeshNetworkV6(snapshot.allowedNetworkV6)
            && CloudGatewayMeshValidation.isValidMeshEndpointPort(snapshot.endpointPort)
    }

    private static func snapshotsEqual(_ entry: CloudGatewayMeshPeerEntry, _ snapshot: MeshSnapshot) -> Bool {
        entry.publicKey == snapshot.publicKey
            && entry.endpointHostname == snapshot.endpointHostname
            && entry.endpointPort == snapshot.endpointPort
            && entry.allowedNetworkV4 == snapshot.allowedNetworkV4
            && entry.allowedNetworkV6 == snapshot.allowedNetworkV6
    }

    private static func isCurrentAppliedPeer(_ entry: CloudGatewayMeshPeerEntry?, _ region: CloudGatewayMeshRegion) -> Bool {
        guard let entry, entry.status == .applied, entry.endpointPort != nil else { return false }
        return snapshotsEqual(entry, getRegionMeshSnapshot(region))
    }

    private static func isStaleAppliedPeer(_ entry: CloudGatewayMeshPeerEntry?, _ region: CloudGatewayMeshRegion) -> Bool {
        guard let entry, entry.status == .applied else { return false }
        return !isCurrentAppliedPeer(entry, region)
    }

    private static func hasValidSnapshotField(_ region: CloudGatewayMeshRegion, _ field: MeshSnapshotField) -> Bool {
        let snapshot = getRegionMeshSnapshot(region)
        switch field {
        case .publicKey: return CloudGatewayMeshValidation.isValidWireGuardPublicKey(snapshot.publicKey)
        case .endpointHostname: return CloudGatewayMeshValidation.isValidEndpointHostname(snapshot.endpointHostname)
        case .endpointPort: return CloudGatewayMeshValidation.isValidMeshEndpointPort(snapshot.endpointPort)
        case .allowedNetworkV4: return CloudGatewayMeshValidation.isValidMeshNetworkV4(snapshot.allowedNetworkV4)
        case .allowedNetworkV6: return CloudGatewayMeshValidation.isValidMeshNetworkV6(snapshot.allowedNetworkV6)
        }
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.isEmpty ?? true
    }

    // The backend scopes duplicate-key detection and cross-candidate overlap to
    // enabled regions, so scope them here too even when the caller passes the
    // unfiltered region list (Server Health renders disabled regions as well).
    private static func hasDuplicatePublicKey(_ region: CloudGatewayMeshRegion, _ regions: [CloudGatewayMeshRegion]) -> Bool {
        guard let key = region.wireguardPublicKey, CloudGatewayMeshValidation.isValidWireGuardPublicKey(key) else {
            return false
        }
        return regions.filter {
            $0.enabled && CloudGatewayMeshValidation.isValidWireGuardPublicKey($0.wireguardPublicKey) && $0.wireguardPublicKey == key
        }.count > 1
    }

    private static func isReasonStillPresent(
        _ entry: CloudGatewayMeshPeerEntry,
        _ targetRegion: CloudGatewayMeshRegion,
        _ sourceRegion: CloudGatewayMeshRegion,
        _ regions: [CloudGatewayMeshRegion]
    ) -> Bool {
        switch entry.reasonCode {
        case "missing-public-key":
            return isBlank(targetRegion.wireguardPublicKey)
        case "invalid-public-key":
            return !hasValidSnapshotField(targetRegion, .publicKey)
        case "missing-endpoint-hostname":
            return isBlank(targetRegion.wireguardEndpointHostname)
        case "invalid-endpoint-hostname":
            return !hasValidSnapshotField(targetRegion, .endpointHostname)
        case "invalid-endpoint-port":
            return !hasValidSnapshotField(targetRegion, .endpointPort)
        case "missing-network-v4":
            return isBlank(targetRegion.tunnelNetworkV4)
        case "invalid-network-v4":
            return !hasValidSnapshotField(targetRegion, .allowedNetworkV4)
        case "missing-network-v6":
            return isBlank(targetRegion.tunnelNetworkV6)
        case "invalid-network-v6":
            return !hasValidSnapshotField(targetRegion, .allowedNetworkV6)
        case "outside-aggregate":
            return !hasValidSnapshotField(targetRegion, .allowedNetworkV4) || !hasValidSnapshotField(targetRegion, .allowedNetworkV6)
        case "duplicate-public-key":
            return hasDuplicatePublicKey(targetRegion, regions)
        case "local-network-invalid":
            // The host's local-network configuration is not represented in
            // Region Firestore fields, so only a later sync can clear this
            // persistent configuration failure.
            return true
        case "overlap-local":
            return CloudGatewayMeshValidation.networksOverlap(targetRegion.tunnelNetworkV4 ?? "", sourceRegion.tunnelNetworkV4 ?? "")
                || CloudGatewayMeshValidation.networksOverlap(targetRegion.tunnelNetworkV6 ?? "", sourceRegion.tunnelNetworkV6 ?? "")
        case "overlap-candidate":
            return regions.contains { candidate in
                candidate.regionId != sourceRegion.regionId
                    && candidate.regionId != targetRegion.regionId
                    && candidate.enabled
                    && candidate.meshEnabled
                    && (CloudGatewayMeshValidation.networksOverlap(targetRegion.tunnelNetworkV4 ?? "", candidate.tunnelNetworkV4 ?? "")
                        || CloudGatewayMeshValidation.networksOverlap(targetRegion.tunnelNetworkV6 ?? "", candidate.tunnelNetworkV6 ?? ""))
            }
        default:
            return hasCompleteMeshSnapshot(targetRegion) && !snapshotsEqual(entry, getRegionMeshSnapshot(targetRegion))
        }
    }

    private static func isDirectionPending(
        _ entry: CloudGatewayMeshPeerEntry?,
        _ targetRegion: CloudGatewayMeshRegion,
        _ sourceRegion: CloudGatewayMeshRegion,
        _ regions: [CloudGatewayMeshRegion]
    ) -> Bool {
        guard let entry else { return hasCompleteMeshSnapshot(targetRegion) }
        if entry.status == .applied { return !isCurrentAppliedPeer(entry, targetRegion) }
        if !isBlank(entry.reasonCode), isReasonStillPresent(entry, targetRegion, sourceRegion, regions) { return false }
        if isBlank(entry.reasonCode), hasCompleteMeshSnapshot(targetRegion) {
            return !snapshotsEqual(entry, getRegionMeshSnapshot(targetRegion))
        }
        return true
    }
}
