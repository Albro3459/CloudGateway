import Foundation

/// Direct port of `Frontend/Web/src/helpers/policyHelper.ts`. Keep in lockstep with that file.
///
/// `Policy/*` documents are observability-only, written by each region's host after a policy
/// reconcile pass. `mapHashV4`/`mapHashV6` are comprehensive live-policy hashes covering every
/// authorization-bearing nftables object per address family (cg_tunnel, cg_infra, cg_admin,
/// cg_slot, cg_pairs), not only the slot map, so they describe what a region's host actually read
/// back from live nftables after applying, not what it intended to apply. They must be trusted
/// as-is: there is no "expected" value to validate against, only agreement across the fleet. See
/// `docs/access-control-list.md` ("Dashboard Status").
///
/// `[String: CloudGatewayPolicyDoc]` plays the role of the web's `Map<regionId, PolicyDoc | null>`:
/// an absent key here is the TS `null` case (a region that has never completed a reconcile pass).
public struct CloudGatewayPolicyDoc: Equatable, Sendable {
    // periphery:ignore - carried to mirror the web PolicyDoc (and CloudGatewayMeshDoc) shape and
    // compared via synthesized Equatable. The UI reads CloudGatewayPolicyStatusRow.regionId, which
    // covers the never-synced case where there is no doc at all, so this is never read directly.
    public let regionId: String
    public let mapHashV4: String?
    public let mapHashV6: String?
    public let rowCount: Int?
    public let updatedAt: Date?

    public init(regionId: String, mapHashV4: String?, mapHashV6: String?, rowCount: Int?, updatedAt: Date?) {
        self.regionId = regionId
        self.mapHashV4 = mapHashV4
        self.mapHashV6 = mapHashV6
        self.rowCount = rowCount
        self.updatedAt = updatedAt
    }
}

public enum CloudGatewayPolicyRegionState: Equatable, Sendable {
    case ok, drifted, disabled, neverSynced, unreadable
}

public struct CloudGatewayPolicyStatusRow: Equatable, Sendable, Identifiable {
    public var id: String { regionId }
    public let regionId: String
    public let doc: CloudGatewayPolicyDoc?
    public let state: CloudGatewayPolicyRegionState
    public let driftedV4: Bool
    public let driftedV6: Bool
}

public enum CloudGatewayPolicyStatus {
    // One row per region, in the given order, never throwing on a missing or malformed doc.
    // Comparison and drift are computed only among enabled regions with a usable doc: a disabled
    // region's host still exists and its doc values still render when present, but it never joins
    // the comparison and can never be drifted or make another region drift. Among enabled regions,
    // one with no doc or an unreadable one gets its own explicit failure state instead of quietly
    // dropping out of the comparison.
    public static func buildPolicyStatusRows(
        regions: [CloudGatewayMeshRegion],
        policyDocs: [String: CloudGatewayPolicyDoc]
    ) -> [CloudGatewayPolicyStatusRow] {
        let usable = regions
            .filter { $0.enabled }
            .compactMap { region -> CloudGatewayPolicyDoc? in
                guard let doc = policyDocs[region.regionId], isPolicyDocUsable(doc) else { return nil }
                return doc
            }

        // compactMap rather than force-unwrap: isPolicyDocUsable already guarantees both
        // hashes are present, so this drops nothing, and the derivation stays trap-free
        // if that predicate ever changes.
        let allV4 = usable.compactMap(\.mapHashV4)
        let allV6 = usable.compactMap(\.mapHashV6)

        return regions.map { region in
            let doc = policyDocs[region.regionId]

            if !region.enabled {
                return CloudGatewayPolicyStatusRow(regionId: region.regionId, doc: doc, state: .disabled, driftedV4: false, driftedV6: false)
            }
            guard let doc else {
                return CloudGatewayPolicyStatusRow(regionId: region.regionId, doc: nil, state: .neverSynced, driftedV4: false, driftedV6: false)
            }
            guard isPolicyDocUsable(doc), let hashV4 = doc.mapHashV4, let hashV6 = doc.mapHashV6 else {
                return CloudGatewayPolicyStatusRow(regionId: region.regionId, doc: doc, state: .unreadable, driftedV4: false, driftedV6: false)
            }

            let driftedV4 = isDrifted(value: hashV4, allValues: allV4)
            let driftedV6 = isDrifted(value: hashV6, allValues: allV6)
            let state: CloudGatewayPolicyRegionState = driftedV4 || driftedV6 ? .drifted : .ok
            return CloudGatewayPolicyStatusRow(regionId: region.regionId, doc: doc, state: state, driftedV4: driftedV4, driftedV6: driftedV6)
        }
    }

    // MARK: - Private helpers

    // A doc is usable for comparison once its identity fields are all present. An empty map is a
    // valid boot state (see account-scoped-acl.md), so a rowCount of zero alone must not read as
    // corruption - only a missing field does.
    private static func isPolicyDocUsable(_ doc: CloudGatewayPolicyDoc) -> Bool {
        doc.mapHashV4 != nil && doc.mapHashV6 != nil && doc.rowCount != nil && doc.updatedAt != nil
    }

    // The value shared by a strict majority (>50%) of comparable regions, or nil when no single
    // value clears that bar. Swift `Dictionary` iteration order is unspecified where the TS `Map`
    // is insertion-ordered, but this is not a divergence: a winner is only returned when it clears
    // a strict majority, and a strict majority is unique, so no sort is needed here (unlike
    // `collectMeshWarnings`).
    private static func majorityValue(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }

        var counts: [String: Int] = [:]
        for value in values {
            counts[value, default: 0] += 1
        }

        var winner: String?
        var winnerCount = 0
        for (value, count) in counts where count > winnerCount {
            winner = value
            winnerCount = count
        }

        return winnerCount * 2 > values.count ? winner : nil
    }

    // Consensus rule, deliberate: maps are identical fleet-wide by design (see
    // account-scoped-acl.md), so among enabled regions a hash that a strict majority of comparable
    // regions agree on is treated as "the fleet value" and anyone else is drifted. When there is no
    // strict majority - an even split, or every region disagrees - there is no basis for picking
    // one side as correct, and silently crowning a plurality winner would hide a real problem
    // behind an arbitrary tie-break. So every comparable region is flagged drifted instead: the
    // ambiguity itself is the signal. A lone comparable region has no peers to differ from and can
    // never be drifted.
    private static func isDrifted(value: String, allValues: [String]) -> Bool {
        guard allValues.count >= 2 else { return false }
        let majority = majorityValue(allValues)
        return majority == nil || value != majority
    }
}
