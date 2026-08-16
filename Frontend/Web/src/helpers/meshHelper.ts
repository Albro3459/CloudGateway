// Pure derivation logic for the admin Server Health page: parses `Mesh/*`
// documents (the durable, last-applied state) and combines them with region
// docs to build link rows, pending state, staleness, and warnings. No
// Firestore I/O here so this stays cheaply unit-testable; see
// firebaseDbHelper.ts for the reads/writes that feed it.

import { dateOrNull, stringOrNull } from "./coerce";
import {
    isValidEndpointHostname,
    isValidMeshEndpointPort,
    isValidMeshNetworkV4,
    isValidMeshNetworkV6,
    isValidWireGuardPublicKey,
    networksOverlap,
} from "./meshValidation";
import { Region } from "./regionsHelper";

type MeshPeerStatus = "applied" | "skipped-overlap" | "skipped-incomplete";

type MeshPeerEntry = {
    endpointHostname: string | null;
    endpointPort?: number | null;
    publicKey: string | null;
    allowedNetworkV4: string | null;
    allowedNetworkV6: string | null;
    status: MeshPeerStatus;
    reasonCode?: string | null;
    appliedAt: Date | null;
};

export type MeshDoc = {
    regionId: string;
    meshEnabled: boolean;
    updatedAt: Date | null;
    peers: Record<string, MeshPeerEntry>;
};

// regionId -> that region's last-written Mesh doc, or null when none exists
// (the region has never completed a sync pass).
export type MeshDocsById = Map<string, MeshDoc | null>;

const parseMeshPeerStatus = (value: unknown): MeshPeerStatus | null => (
    value === "applied" || value === "skipped-overlap" || value === "skipped-incomplete" ? value : null
);

const numberOrNull = (value: unknown): number | null => (
    isValidMeshEndpointPort(value) ? value : null
);

const isValidEndpointPort = (value: number | null | undefined): value is number => (
    isValidMeshEndpointPort(value)
);

const parseMeshPeerEntry = (data: unknown): MeshPeerEntry | null => {
    if (!data || typeof data !== "object") return null;
    const entry = data as Record<string, unknown>;
    const status = parseMeshPeerStatus(entry.status);
    if (!status) return null;

    const parsed: MeshPeerEntry = {
        endpointHostname: stringOrNull(entry.endpointHostname),
        endpointPort: numberOrNull(entry.endpointPort),
        publicKey: stringOrNull(entry.publicKey),
        allowedNetworkV4: stringOrNull(entry.allowedNetworkV4),
        allowedNetworkV6: stringOrNull(entry.allowedNetworkV6),
        status,
        reasonCode: stringOrNull(entry.reasonCode),
        appliedAt: dateOrNull(entry.appliedAt),
    };

    // Skipped-incomplete is deliberately status-first. Its empty fields are
    // useful operator evidence and must survive parsing. Applied and overlap
    // snapshots require the complete current metadata, including endpointPort.
    if (status === "skipped-incomplete") return parsed;
    if (
        !parsed.endpointHostname
        || !isValidEndpointHostname(parsed.endpointHostname)
        || !isValidEndpointPort(parsed.endpointPort)
        || !parsed.publicKey
        || !isValidWireGuardPublicKey(parsed.publicKey)
        || !parsed.allowedNetworkV4
        || !isValidMeshNetworkV4(parsed.allowedNetworkV4)
        || !parsed.allowedNetworkV6
        || !isValidMeshNetworkV6(parsed.allowedNetworkV6)
    ) {
        return null;
    }

    return parsed;
};

export const parseMeshDocument = (regionId: string, data: Record<string, unknown>): MeshDoc => {
    const rawPeers = data.peers && typeof data.peers === "object" ? data.peers as Record<string, unknown> : {};
    const peers: Record<string, MeshPeerEntry> = {};

    for (const [peerRegionId, rawEntry] of Object.entries(rawPeers)) {
        const entry = parseMeshPeerEntry(rawEntry);
        if (entry) {
            peers[peerRegionId] = entry;
        }
    }

    return {
        regionId,
        meshEnabled: data.meshEnabled === true,
        updatedAt: dateOrNull(data.updatedAt),
        peers,
    };
};

// A region is pending when its desired flag (Regions.meshEnabled) disagrees
// with what its host last applied (Mesh.meshEnabled), or it wants in but has
// never synced (no Mesh doc yet). A disabled region has no operational server
// and is not a Sync All target, so its own Mesh doc can never be reconciled -
// reporting it as pending would be a warning nothing can clear.
export const isRegionMeshPending = (region: Region, meshDoc: MeshDoc | null | undefined): boolean => {
    if (region.enabled !== true) return false;
    const desired = region.meshEnabled === true;
    if (!meshDoc) return desired;
    return desired !== meshDoc.meshEnabled;
};

export type MeshLinkStatus = "both-applied" | "one-sided" | "not-synced" | "stale";

export type MeshLinkRow = {
    regionAId: string;
    regionBId: string;
    status: MeshLinkStatus;
    pending: boolean;
    // Status of the peer entry each side recorded for the other direction;
    // null means that side has no entry for the peer at all (not just skipped).
    aToB: MeshPeerStatus | null;
    bToA: MeshPeerStatus | null;
    aToBCurrent: boolean;
    bToACurrent: boolean;
    aToBStale: boolean;
    bToAStale: boolean;
};

const peerFor = (meshDoc: MeshDoc | null | undefined, peerRegionId: string): MeshPeerEntry | null => (
    meshDoc?.peers[peerRegionId] ?? null
);

type MeshSnapshot = {
    publicKey: string | null;
    endpointHostname: string | null;
    endpointPort: number | null;
    allowedNetworkV4: string | null;
    allowedNetworkV6: string | null;
};

const getRegionMeshSnapshot = (region: Region): MeshSnapshot => ({
    publicKey: region.wireguardPublicKey ?? null,
    endpointHostname: region.wireguardEndpointHostname ?? null,
    endpointPort: region.wireguardPort ?? null,
    allowedNetworkV4: region.tunnelNetworkV4 ?? null,
    allowedNetworkV6: region.tunnelNetworkV6 ?? null,
});

const hasCompleteMeshSnapshot = (region: Region): boolean => {
    const snapshot = getRegionMeshSnapshot(region);
    return Boolean(
        isValidWireGuardPublicKey(snapshot.publicKey)
        && isValidEndpointHostname(snapshot.endpointHostname)
        && isValidMeshNetworkV4(snapshot.allowedNetworkV4)
        && isValidMeshNetworkV6(snapshot.allowedNetworkV6)
        && isValidEndpointPort(snapshot.endpointPort)
    );
};

const snapshotsEqual = (entry: MeshPeerEntry, snapshot: MeshSnapshot): boolean => (
    entry.publicKey === snapshot.publicKey
    && entry.endpointHostname === snapshot.endpointHostname
    && entry.endpointPort === snapshot.endpointPort
    && entry.allowedNetworkV4 === snapshot.allowedNetworkV4
    && entry.allowedNetworkV6 === snapshot.allowedNetworkV6
);

const isCurrentAppliedPeer = (entry: MeshPeerEntry | null | undefined, region: Region): boolean => (
    entry?.status === "applied"
    && typeof entry.endpointPort === "number"
    && snapshotsEqual(entry, getRegionMeshSnapshot(region))
);

const isStaleAppliedPeer = (entry: MeshPeerEntry | null, region: Region): boolean => (
    entry?.status === "applied" && !isCurrentAppliedPeer(entry, region)
);

const hasValidSnapshotField = (region: Region, field: keyof MeshSnapshot): boolean => {
    const snapshot = getRegionMeshSnapshot(region);
    const value = snapshot[field];
    if (field === "publicKey") return isValidWireGuardPublicKey(value);
    if (field === "endpointHostname") return isValidEndpointHostname(value);
    if (field === "endpointPort") return isValidMeshEndpointPort(value);
    if (field === "allowedNetworkV4") return isValidMeshNetworkV4(value);
    if (field === "allowedNetworkV6") return isValidMeshNetworkV6(value);
    return false;
};

// The backend scopes duplicate-key detection and cross-candidate overlap to
// enabled regions, so scope them here too even when the caller passes the
// unfiltered region list (Server Health renders disabled regions as well).
const hasDuplicatePublicKey = (region: Region, regions: Region[]): boolean => {
    const key = region.wireguardPublicKey;
    return isValidWireGuardPublicKey(key)
        && regions.filter(candidate => candidate.enabled === true
            && isValidWireGuardPublicKey(candidate.wireguardPublicKey)
            && candidate.wireguardPublicKey === key).length > 1;
};

const isReasonStillPresent = (
    entry: MeshPeerEntry,
    targetRegion: Region,
    sourceRegion: Region,
    regions: Region[],
): boolean => {
    switch (entry.reasonCode) {
        case "missing-public-key":
            return !targetRegion.wireguardPublicKey;
        case "invalid-public-key":
            return !hasValidSnapshotField(targetRegion, "publicKey");
        case "missing-endpoint-hostname":
            return !targetRegion.wireguardEndpointHostname;
        case "invalid-endpoint-hostname":
            return !hasValidSnapshotField(targetRegion, "endpointHostname");
        case "invalid-endpoint-port":
            return !hasValidSnapshotField(targetRegion, "endpointPort");
        case "missing-network-v4":
            return !targetRegion.tunnelNetworkV4;
        case "invalid-network-v4":
            return !hasValidSnapshotField(targetRegion, "allowedNetworkV4");
        case "missing-network-v6":
            return !targetRegion.tunnelNetworkV6;
        case "invalid-network-v6":
            return !hasValidSnapshotField(targetRegion, "allowedNetworkV6");
        case "outside-aggregate":
            return !hasValidSnapshotField(targetRegion, "allowedNetworkV4")
                || !hasValidSnapshotField(targetRegion, "allowedNetworkV6");
        case "duplicate-public-key":
            return hasDuplicatePublicKey(targetRegion, regions);
        case "local-network-invalid":
            // The host's local-network configuration is not represented in
            // Region Firestore fields, so only a later sync can clear this
            // persistent configuration failure.
            return true;
        case "overlap-local":
            return networksOverlap(targetRegion.tunnelNetworkV4 ?? "", sourceRegion.tunnelNetworkV4 ?? "")
                || networksOverlap(targetRegion.tunnelNetworkV6 ?? "", sourceRegion.tunnelNetworkV6 ?? "");
        case "overlap-candidate":
            return regions.some(candidate => (
                candidate.regionId !== sourceRegion.regionId
                && candidate.regionId !== targetRegion.regionId
                && candidate.enabled === true
                && candidate.meshEnabled === true
                && (networksOverlap(targetRegion.tunnelNetworkV4 ?? "", candidate.tunnelNetworkV4 ?? "")
                    || networksOverlap(targetRegion.tunnelNetworkV6 ?? "", candidate.tunnelNetworkV6 ?? ""))
            ));
        default:
            // Unrecognized reason code: assume the reason still persists rather than
            // clearing a warning we don't know how to re-check.
            return true;
    }
};

const isDirectionPending = (
    entry: MeshPeerEntry | null,
    targetRegion: Region,
    sourceRegion: Region,
    regions: Region[],
): boolean => {
    if (!entry) return hasCompleteMeshSnapshot(targetRegion);
    if (entry.status === "applied") return !isCurrentAppliedPeer(entry, targetRegion);
    if (entry.reasonCode && isReasonStillPresent(entry, targetRegion, sourceRegion, regions)) return false;
    if (!entry.reasonCode && hasCompleteMeshSnapshot(targetRegion)) {
        return !snapshotsEqual(entry, getRegionMeshSnapshot(targetRegion));
    }
    return true;
};

// One row per unordered region pair (a graph's links, not a per-region list),
// so an asymmetric failure ("one-sided") is visible instead of being rendered
// twice from opposite sides.
export const buildMeshLinkRows = (regions: Region[], meshDocs: MeshDocsById): MeshLinkRow[] => {
    const rows: MeshLinkRow[] = [];

    for (let i = 0; i < regions.length; i++) {
        for (let j = i + 1; j < regions.length; j++) {
            const a = regions[i];
            const b = regions[j];
            const meshDocA = meshDocs.get(a.regionId) ?? null;
            const meshDocB = meshDocs.get(b.regionId) ?? null;
            const entryA = peerFor(meshDocA, b.regionId);
            const entryB = peerFor(meshDocB, a.regionId);
            const aToB = entryA?.status ?? null;
            const bToA = entryB?.status ?? null;
            const aToBCurrent = isCurrentAppliedPeer(entryA, b);
            const bToACurrent = isCurrentAppliedPeer(entryB, a);
            const aToBStale = isStaleAppliedPeer(entryA, b);
            const bToAStale = isStaleAppliedPeer(entryB, a);

            let status: MeshLinkStatus;
            if (aToBStale || bToAStale) {
                status = "stale";
            } else if (aToBCurrent && bToACurrent) {
                status = "both-applied";
            } else if (aToBCurrent || bToACurrent) {
                status = "one-sided";
            } else {
                status = "not-synced";
            }

            // A link is only desired when both sides are live mesh members;
            // a disabled region is dead, so its peers must come down even
            // though its meshEnabled flag may still read true.
            const bothMeshDesired = a.enabled === true && b.enabled === true
                && a.meshEnabled === true && b.meshEnabled === true;
            const membershipPending = isRegionMeshPending(a, meshDocA) || isRegionMeshPending(b, meshDocB);
            // Only a live host runs a sync pass, so only a live host's own
            // stale entry is something Sync All can still reconcile.
            const removalPending = !bothMeshDesired && (
                (a.enabled === true && entryA?.status === "applied")
                || (b.enabled === true && entryB?.status === "applied")
            );
            const desiredDirectionPending = bothMeshDesired && (
                isDirectionPending(entryA, b, a, regions) || isDirectionPending(entryB, a, b, regions)
            );

            rows.push({
                regionAId: a.regionId,
                regionBId: b.regionId,
                status,
                pending: membershipPending || removalPending || desiredDirectionPending,
                aToB,
                bToA,
                aToBCurrent,
                bToACurrent,
                aToBStale,
                bToAStale,
            });
        }
    }

    return rows;
};

// True when a toggle or a missing/unsynced link means Sync All would still
// change something on some host.
export const hasAnyMeshPending = (regions: Region[], meshDocs: MeshDocsById): boolean => {
    if (regions.some(region => isRegionMeshPending(region, meshDocs.get(region.regionId) ?? null))) {
        return true;
    }
    return buildMeshLinkRows(regions, meshDocs).some(row => row.pending);
};

export type MeshWarning = {
    // The region whose host recorded the skip (i.e. that region's own sync
    // pass judged `peerRegionId` unsafe to apply).
    regionId: string;
    peerRegionId: string;
    status: Extract<MeshPeerStatus, "skipped-overlap" | "skipped-incomplete">;
    endpointHostname: string | null;
    endpointPort: number | null;
    publicKey: string | null;
    allowedNetworkV4: string | null;
    allowedNetworkV6: string | null;
    reasonCode: string | null;
    appliedAt: Date | null;
};

// Per-region judgments (a claimed CIDR overlapping another region's, or an
// incomplete peer doc) that don't belong on a link row.
export const collectMeshWarnings = (meshDocs: MeshDocsById): MeshWarning[] => {
    const warnings: MeshWarning[] = [];

    for (const meshDoc of meshDocs.values()) {
        if (!meshDoc) continue;

        for (const [peerRegionId, entry] of Object.entries(meshDoc.peers)) {
            if (entry.status !== "skipped-overlap" && entry.status !== "skipped-incomplete") continue;

            warnings.push({
                regionId: meshDoc.regionId,
                peerRegionId,
                status: entry.status,
                endpointHostname: entry.endpointHostname,
                endpointPort: entry.endpointPort ?? null,
                publicKey: entry.publicKey,
                allowedNetworkV4: entry.allowedNetworkV4,
                allowedNetworkV6: entry.allowedNetworkV6,
                reasonCode: entry.reasonCode ?? null,
                appliedAt: entry.appliedAt,
            });
        }
    }

    return warnings;
};

export type MeshStaleness = "unknown" | "fresh" | "stale";

// Manual-first sync (no timer), so this only flags "this hasn't run
// recently" for operator awareness - it is not a health/error signal.
export const MESH_STALE_THRESHOLD_MS = 24 * 60 * 60 * 1000;

export const getMeshStaleness = (updatedAt: Date | null, now: Date = new Date()): MeshStaleness => {
    if (!updatedAt) return "unknown";
    return now.getTime() - updatedAt.getTime() > MESH_STALE_THRESHOLD_MS ? "stale" : "fresh";
};
