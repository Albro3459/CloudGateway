// Pure derivation logic for the admin Server Health page's account-scoped
// ACL (client isolation) status: parses `Policy/*` documents (observability
// only, written by each region's host after a policy reconcile pass) and
// derives per-region drift/staleness. No Firestore I/O here so this stays
// cheaply unit-testable; see firebaseDbHelper.ts for the read that feeds it.
//
// The hashes describe what a region's host actually read back from live
// nftables, not what it intended to apply, so they must be trusted as-is:
// there is no "expected" value to validate against, only agreement across
// the fleet. See TODO/account-scoped-acl.md ("Firestore model").

import { dateOrNull, stringOrNull } from "./coerce";
import { Region } from "./regionsHelper";

const numberOrNull = (value: unknown): number | null => (
    typeof value === "number" && Number.isFinite(value) ? value : null
);

export type PolicyDoc = {
    regionId: string;
    mapHashV4: string | null;
    mapHashV6: string | null;
    rowCount: number | null;
    appliedSequence: number | null;
    // Max updatedAt across the applied snapshot; legitimately null before a
    // region's first reconcile pass has ever applied anything.
    dataVintage: Date | null;
    updatedAt: Date | null;
};

// regionId -> that region's last-written Policy doc, or null when none
// exists (the region has never completed a reconcile pass), mirroring
// MeshDocsById.
export type PolicyDocsById = Map<string, PolicyDoc | null>;

// Defensive by design: a malformed or partially-written doc must never throw
// while rendering. Missing/invalid fields come back null rather than a
// fabricated default, so isPolicyDocUsable below can tell "wrote garbage"
// apart from "wrote zero rows".
export const parsePolicyDocument = (regionId: string, data: Record<string, unknown>): PolicyDoc => ({
    regionId,
    mapHashV4: stringOrNull(data.mapHashV4),
    mapHashV6: stringOrNull(data.mapHashV6),
    rowCount: numberOrNull(data.rowCount),
    appliedSequence: numberOrNull(data.appliedSequence),
    dataVintage: dateOrNull(data.dataVintage),
    updatedAt: dateOrNull(data.updatedAt),
});

// A doc is usable for comparison once its identity fields are all present.
// dataVintage is deliberately excluded: it is legitimately null before any
// snapshot has ever been applied (an empty map is a valid boot state, see
// account-scoped-acl.md's "Filter design" notes), so a null vintage alone
// must not read as corruption.
const isPolicyDocUsable = (doc: PolicyDoc): boolean => (
    doc.mapHashV4 !== null && doc.mapHashV6 !== null && doc.rowCount !== null && doc.updatedAt !== null
);

export type PolicyRegionState = "ok" | "drifted" | "stale" | "never-synced" | "unreadable";

export type PolicyStatusRow = {
    regionId: string;
    doc: PolicyDoc | null;
    state: PolicyRegionState;
    driftedV4: boolean;
    driftedV6: boolean;
    stale: boolean;
};

// The value shared by a strict majority (>50%) of comparable regions, or
// null when no single value clears that bar.
const majorityValue = (values: string[]): string | null => {
    if (values.length === 0) return null;

    const counts = new Map<string, number>();
    for (const value of values) {
        counts.set(value, (counts.get(value) ?? 0) + 1);
    }

    let winner: string | null = null;
    let winnerCount = 0;
    for (const [value, count] of counts) {
        if (count > winnerCount) {
            winner = value;
            winnerCount = count;
        }
    }

    return winnerCount * 2 > values.length ? winner : null;
};

// Consensus rule, deliberate: maps are identical fleet-wide by design (see
// account-scoped-acl.md), so a hash that a strict majority of comparable
// regions agree on is treated as "the fleet value" and anyone else is
// drifted. When there is no strict majority - an even split, or every region
// disagrees - there is no basis for picking one side as correct, and
// silently crowning a plurality winner would hide a real problem behind an
// arbitrary tie-break. So every comparable region is flagged drifted
// instead: the ambiguity itself is the signal. A lone comparable region has
// no peers to differ from and can never be drifted.
const isDrifted = (value: string, allValues: string[]): boolean => {
    if (allValues.length < 2) return false;
    const majority = majorityValue(allValues);
    return majority === null || value !== majority;
};

export type PolicyStaleness = "unknown" | "fresh" | "stale";

// Unlike Mesh's getMeshStaleness (measured against wall-clock "now"), policy
// reconciles are event-driven with no timer (account-scoped-acl.md,
// "Refresh model"), so an idle fleet with no recent client changes would
// have every dataVintage look old against "now" despite every region being
// perfectly in sync with each other. Comparing a region's dataVintage
// against its peers' freshest instead isolates the region that is actually
// behind the rest of the fleet, which is what "STALE" means here.
export const POLICY_STALE_THRESHOLD_MS = 24 * 60 * 60 * 1000;

export const getPolicyStaleness = (
    dataVintage: Date | null,
    peerMaxVintage: Date | null,
): PolicyStaleness => {
    if (!dataVintage) return "unknown";
    if (!peerMaxVintage) return "fresh"; // no peer to lag behind
    return peerMaxVintage.getTime() - dataVintage.getTime() > POLICY_STALE_THRESHOLD_MS ? "stale" : "fresh";
};

// One row per region, in the given order, never throwing on a missing or
// malformed doc. Drift/staleness are computed only across regions whose docs
// are usable; a region with no doc or an unreadable one gets its own
// explicit failure state instead of quietly dropping out of the comparison.
export const buildPolicyStatusRows = (regions: Region[], policyDocs: PolicyDocsById): PolicyStatusRow[] => {
    const usable = regions
        .map(region => ({ regionId: region.regionId, doc: policyDocs.get(region.regionId) ?? null }))
        .filter((entry): entry is { regionId: string; doc: PolicyDoc } => entry.doc !== null && isPolicyDocUsable(entry.doc));

    const allV4 = usable.map(entry => entry.doc.mapHashV4 as string);
    const allV6 = usable.map(entry => entry.doc.mapHashV6 as string);

    return regions.map((region): PolicyStatusRow => {
        const doc = policyDocs.get(region.regionId) ?? null;

        if (!doc) {
            return { regionId: region.regionId, doc: null, state: "never-synced", driftedV4: false, driftedV6: false, stale: false };
        }
        if (!isPolicyDocUsable(doc)) {
            return { regionId: region.regionId, doc, state: "unreadable", driftedV4: false, driftedV6: false, stale: false };
        }

        const driftedV4 = isDrifted(doc.mapHashV4 as string, allV4);
        const driftedV6 = isDrifted(doc.mapHashV6 as string, allV6);

        const peerVintages = usable
            .filter(entry => entry.regionId !== region.regionId && entry.doc.dataVintage)
            .map(entry => (entry.doc.dataVintage as Date).getTime());
        const peerMaxVintage = peerVintages.length ? new Date(Math.max(...peerVintages)) : null;
        const stale = getPolicyStaleness(doc.dataVintage, peerMaxVintage) === "stale";

        const state: PolicyRegionState = driftedV4 || driftedV6 ? "drifted" : stale ? "stale" : "ok";

        return { regionId: region.regionId, doc, state, driftedV4, driftedV6, stale };
    });
};
