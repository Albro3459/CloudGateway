// Pure derivation logic for the admin Server Health page's account-scoped
// ACL (client isolation) status: parses `Policy/*` documents (observability
// only, written by each region's host after a policy reconcile pass) and
// derives per-region drift state. No Firestore I/O here so this stays
// cheaply unit-testable; see firebaseDbHelper.ts for the read that feeds it.
//
// mapHashV4/mapHashV6 are comprehensive live-policy hashes covering every
// authorization-bearing nftables object per address family (cg_tunnel,
// cg_infra, cg_admin, cg_slot, cg_pairs), not only the slot map, so they
// describe what a region's host actually read back from live nftables after
// applying, not what it intended to apply. They must be trusted as-is: there
// is no "expected" value to validate against, only agreement across the
// fleet. See docs/access-control-list.md ("Dashboard Status").

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
    updatedAt: dateOrNull(data.updatedAt),
});

// A doc is usable for comparison once its identity fields are all present.
// An empty map is a valid boot state (see account-scoped-acl.md), so a
// rowCount of zero alone must not read as corruption - only a missing field
// does.
const isPolicyDocUsable = (doc: PolicyDoc): boolean => (
    doc.mapHashV4 !== null && doc.mapHashV6 !== null && doc.rowCount !== null && doc.updatedAt !== null
);

export type PolicyRegionState = "ok" | "drifted" | "disabled" | "never-synced" | "unreadable";

export type PolicyStatusRow = {
    regionId: string;
    doc: PolicyDoc | null;
    state: PolicyRegionState;
    driftedV4: boolean;
    driftedV6: boolean;
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
// account-scoped-acl.md), so among enabled regions a hash that a strict
// majority of comparable regions agree on is treated as "the fleet value"
// and anyone else is drifted. When there is no strict majority - an even
// split, or every region disagrees - there is no basis for picking one side
// as correct, and silently crowning a plurality winner would hide a real
// problem behind an arbitrary tie-break. So every comparable region is
// flagged drifted instead: the ambiguity itself is the signal. A lone
// comparable region has no peers to differ from and can never be drifted.
const isDrifted = (value: string, allValues: string[]): boolean => {
    if (allValues.length < 2) return false;
    const majority = majorityValue(allValues);
    return majority === null || value !== majority;
};

// One row per region, in the given order, never throwing on a missing or
// malformed doc. Comparison and drift are computed only among enabled
// regions with a usable doc: a disabled region's host still exists and its
// doc values still render when present, but it never joins the comparison
// and can never be drifted or make another region drift. Among enabled
// regions, one with no doc or an unreadable one gets its own explicit
// failure state instead of quietly dropping out of the comparison.
export const buildPolicyStatusRows = (regions: Region[], policyDocs: PolicyDocsById): PolicyStatusRow[] => {
    const usable = regions
        .filter(region => region.enabled === true)
        .map(region => ({ regionId: region.regionId, doc: policyDocs.get(region.regionId) ?? null }))
        .filter((entry): entry is { regionId: string; doc: PolicyDoc } => entry.doc !== null && isPolicyDocUsable(entry.doc));

    const allV4 = usable.map(entry => entry.doc.mapHashV4 as string);
    const allV6 = usable.map(entry => entry.doc.mapHashV6 as string);

    return regions.map((region): PolicyStatusRow => {
        const doc = policyDocs.get(region.regionId) ?? null;

        if (region.enabled !== true) {
            return { regionId: region.regionId, doc, state: "disabled", driftedV4: false, driftedV6: false };
        }
        if (!doc) {
            return { regionId: region.regionId, doc: null, state: "never-synced", driftedV4: false, driftedV6: false };
        }
        if (!isPolicyDocUsable(doc)) {
            return { regionId: region.regionId, doc, state: "unreadable", driftedV4: false, driftedV6: false };
        }

        const driftedV4 = isDrifted(doc.mapHashV4 as string, allV4);
        const driftedV6 = isDrifted(doc.mapHashV6 as string, allV6);
        const state: PolicyRegionState = driftedV4 || driftedV6 ? "drifted" : "ok";

        return { regionId: region.regionId, doc, state, driftedV4, driftedV6 };
    });
};
