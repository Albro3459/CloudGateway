// Pure derivation logic for the admin Server Health page: parses `Mesh/*`
// documents (the durable, last-applied state) and combines them with region
// docs to build link rows, pending state, staleness, and warnings. No
// Firestore I/O here so this stays cheaply unit-testable; see
// firebaseDbHelper.ts for the reads/writes that feed it.

import { dateOrNull, stringOrNull } from "./coerce";
import { Region } from "./regionsHelper";

type MeshPeerStatus = "applied" | "skipped-overlap" | "skipped-incomplete";

type MeshPeerEntry = {
    endpointHostname: string;
    publicKey: string;
    allowedNetworkV4: string;
    allowedNetworkV6: string;
    status: MeshPeerStatus;
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

const parseMeshPeerEntry = (data: unknown): MeshPeerEntry | null => {
    if (!data || typeof data !== "object") return null;
    const entry = data as Record<string, unknown>;

    const status = parseMeshPeerStatus(entry.status);
    const endpointHostname = stringOrNull(entry.endpointHostname);
    const publicKey = stringOrNull(entry.publicKey);
    const allowedNetworkV4 = stringOrNull(entry.allowedNetworkV4);
    const allowedNetworkV6 = stringOrNull(entry.allowedNetworkV6);
    if (!status || !endpointHostname || !publicKey || !allowedNetworkV4 || !allowedNetworkV6) {
        return null;
    }

    return {
        endpointHostname,
        publicKey,
        allowedNetworkV4,
        allowedNetworkV6,
        status,
        appliedAt: dateOrNull(entry.appliedAt),
    };
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
// never synced (no Mesh doc yet).
export const isRegionMeshPending = (region: Region, meshDoc: MeshDoc | null | undefined): boolean => {
    const desired = region.meshEnabled === true;
    if (!meshDoc) return desired;
    return desired !== meshDoc.meshEnabled;
};

export type MeshLinkStatus = "both-applied" | "one-sided" | "not-synced";

export type MeshLinkRow = {
    regionAId: string;
    regionBId: string;
    status: MeshLinkStatus;
    pending: boolean;
    // Status of the peer entry each side recorded for the other direction;
    // null means that side has no entry for the peer at all (not just skipped).
    aToB: MeshPeerStatus | null;
    bToA: MeshPeerStatus | null;
};

const peerStatusFor = (meshDoc: MeshDoc | null | undefined, peerRegionId: string): MeshPeerStatus | null => (
    meshDoc?.peers[peerRegionId]?.status ?? null
);

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
            const aToB = peerStatusFor(meshDocA, b.regionId);
            const bToA = peerStatusFor(meshDocB, a.regionId);
            const aApplied = aToB === "applied";
            const bApplied = bToA === "applied";

            let status: MeshLinkStatus;
            if (aApplied && bApplied) {
                status = "both-applied";
            } else if (aApplied || bApplied) {
                status = "one-sided";
            } else {
                status = "not-synced";
            }

            const bothEnabled = a.meshEnabled === true && b.meshEnabled === true;
            const missingEitherEntry = bothEnabled && (aToB === null || bToA === null);

            rows.push({
                regionAId: a.regionId,
                regionBId: b.regionId,
                status,
                pending: isRegionMeshPending(a, meshDocA) || isRegionMeshPending(b, meshDocB) || missingEitherEntry,
                aToB,
                bToA,
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
    endpointHostname: string;
    allowedNetworkV4: string;
    allowedNetworkV6: string;
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
                allowedNetworkV4: entry.allowedNetworkV4,
                allowedNetworkV6: entry.allowedNetworkV6,
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
