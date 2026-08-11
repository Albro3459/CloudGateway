import {
    buildMeshLinkRows,
    collectMeshWarnings,
    getMeshStaleness,
    hasAnyMeshPending,
    isRegionMeshPending,
    MESH_STALE_THRESHOLD_MS,
    MeshDoc,
    MeshDocsById,
    parseMeshDocument,
} from "../meshHelper";
import { Region } from "../regionsHelper";

const region = (regionId: string, meshEnabled: boolean): Region => ({
    regionId,
    displayName: regionId,
    enabled: true,
    displayOrder: 1000,
    meshEnabled,
});

const appliedPeer = (overrides: Partial<MeshDoc["peers"][string]> = {}) => ({
    endpointHostname: "wg.example.com",
    publicKey: "public-key",
    allowedNetworkV4: "10.0.1.0/24",
    allowedNetworkV6: "fd42:42:42:1::/64",
    status: "applied" as const,
    appliedAt: null,
    ...overrides,
});

describe("meshHelper", () => {
    describe("parseMeshDocument", () => {
        it("parses peer entries and drops incomplete ones", () => {
            const doc = parseMeshDocument("us-sanjose-1", {
                meshEnabled: true,
                updatedAt: new Date("2026-01-01T00:00:00Z"),
                peers: {
                    "us-chicago-1": {
                        endpointHostname: "wg.us-chicago-1.example.com",
                        publicKey: "chicago-key",
                        allowedNetworkV4: "10.0.1.0/24",
                        allowedNetworkV6: "fd42:42:42:1::/64",
                        status: "applied",
                        appliedAt: new Date("2026-01-01T00:00:00Z"),
                    },
                    "us-dallas-1": {
                        // Missing publicKey - should be dropped rather than crash rendering.
                        endpointHostname: "wg.us-dallas-1.example.com",
                        status: "applied",
                    },
                },
            });

            expect(doc.regionId).toBe("us-sanjose-1");
            expect(doc.meshEnabled).toBe(true);
            expect(doc.updatedAt).toEqual(new Date("2026-01-01T00:00:00Z"));
            expect(Object.keys(doc.peers)).toEqual(["us-chicago-1"]);
            expect(doc.peers["us-chicago-1"].status).toBe("applied");
        });

        it("defaults meshEnabled false and peers empty when fields are missing", () => {
            const doc = parseMeshDocument("us-sanjose-1", {});

            expect(doc.meshEnabled).toBe(false);
            expect(doc.peers).toEqual({});
            expect(doc.updatedAt).toBeNull();
        });
    });

    describe("isRegionMeshPending", () => {
        it("is pending when the desired flag disagrees with the last-applied flag", () => {
            const r = region("us-sanjose-1", true);
            const meshDoc = parseMeshDocument("us-sanjose-1", { meshEnabled: false, peers: {} });

            expect(isRegionMeshPending(r, meshDoc)).toBe(true);
        });

        it("is pending when enabled but no Mesh doc exists yet", () => {
            expect(isRegionMeshPending(region("us-sanjose-1", true), null)).toBe(true);
        });

        it("is not pending when disabled and there is no Mesh doc", () => {
            expect(isRegionMeshPending(region("us-sanjose-1", false), null)).toBe(false);
        });

        it("is not pending when the flags agree", () => {
            const meshDoc = parseMeshDocument("us-sanjose-1", { meshEnabled: true, peers: {} });
            expect(isRegionMeshPending(region("us-sanjose-1", true), meshDoc)).toBe(false);
        });
    });

    describe("buildMeshLinkRows", () => {
        it("marks a link both-applied when each side recorded the other as applied", () => {
            const regions = [region("us-sanjose-1", true), region("us-chicago-1", true)];
            const meshDocs: MeshDocsById = new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", { meshEnabled: true, peers: { "us-chicago-1": appliedPeer() } })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", { meshEnabled: true, peers: { "us-sanjose-1": appliedPeer() } })],
            ]);

            const rows = buildMeshLinkRows(regions, meshDocs);

            expect(rows).toHaveLength(1);
            expect(rows[0]).toMatchObject({
                regionAId: "us-sanjose-1",
                regionBId: "us-chicago-1",
                status: "both-applied",
                pending: false,
            });
        });

        it("marks a link one-sided when only one side applied, without erroring the whole link", () => {
            const regions = [region("us-sanjose-1", true), region("us-dallas-1", true)];
            const meshDocs: MeshDocsById = new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", { meshEnabled: true, peers: { "us-dallas-1": appliedPeer() } })],
                ["us-dallas-1", null],
            ]);

            const rows = buildMeshLinkRows(regions, meshDocs);

            expect(rows[0].status).toBe("one-sided");
            expect(rows[0].aToB).toBe("applied");
            expect(rows[0].bToA).toBeNull();
            // us-dallas-1 wants in but has never synced - the region itself is
            // pending, which makes the link pending too.
            expect(rows[0].pending).toBe(true);
        });

        it("marks a link not-synced when neither side has an applied entry", () => {
            const regions = [region("us-sanjose-1", false), region("us-chicago-1", false)];
            const meshDocs: MeshDocsById = new Map();

            const rows = buildMeshLinkRows(regions, meshDocs);

            expect(rows[0].status).toBe("not-synced");
            expect(rows[0].pending).toBe(false);
        });

        it("is pending when both sides are enabled but a peer entry is absent, even if neither region itself is pending", () => {
            const regions = [region("us-sanjose-1", true), region("us-chicago-1", true)];
            const meshDocs: MeshDocsById = new Map([
                // Both regions already report meshEnabled true (not region-pending),
                // but San Jose's doc has no entry for Chicago yet.
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", { meshEnabled: true, peers: {} })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", { meshEnabled: true, peers: { "us-sanjose-1": appliedPeer() } })],
            ]);

            const rows = buildMeshLinkRows(regions, meshDocs);

            expect(rows[0].pending).toBe(true);
        });

        it("does not treat a skipped (present but not applied) entry as a missing/pending entry", () => {
            const regions = [region("us-sanjose-1", true), region("us-chicago-1", true)];
            const meshDocs: MeshDocsById = new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", {
                    meshEnabled: true,
                    peers: { "us-chicago-1": appliedPeer({ status: "skipped-overlap" }) },
                })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", { meshEnabled: true, peers: { "us-sanjose-1": appliedPeer() } })],
            ]);

            const rows = buildMeshLinkRows(regions, meshDocs);

            expect(rows[0].status).toBe("one-sided");
            expect(rows[0].pending).toBe(false);
        });

        it("builds one row per pair for more than two regions", () => {
            const regions = [region("a", false), region("b", false), region("c", false)];
            const rows = buildMeshLinkRows(regions, new Map());

            expect(rows.map(row => `${row.regionAId}-${row.regionBId}`)).toEqual(["a-b", "a-c", "b-c"]);
        });
    });

    describe("hasAnyMeshPending", () => {
        it("is true when a lone enabled region has never synced (no pairs to form a link)", () => {
            const regions = [region("us-sanjose-1", true)];
            expect(hasAnyMeshPending(regions, new Map())).toBe(true);
        });

        it("is false when nothing is pending", () => {
            const regions = [region("us-sanjose-1", false)];
            expect(hasAnyMeshPending(regions, new Map())).toBe(false);
        });
    });

    describe("collectMeshWarnings", () => {
        it("collects skipped-overlap and skipped-incomplete entries, not applied ones", () => {
            const meshDocs: MeshDocsById = new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", {
                    meshEnabled: true,
                    peers: {
                        "us-chicago-1": appliedPeer(),
                        "us-dallas-1": appliedPeer({ status: "skipped-overlap" }),
                    },
                })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", {
                    meshEnabled: true,
                    peers: { "us-dallas-1": appliedPeer({ status: "skipped-incomplete" }) },
                })],
            ]);

            const warnings = collectMeshWarnings(meshDocs);

            expect(warnings).toHaveLength(2);
            expect(warnings).toEqual(expect.arrayContaining([
                expect.objectContaining({ regionId: "us-sanjose-1", peerRegionId: "us-dallas-1", status: "skipped-overlap" }),
                expect.objectContaining({ regionId: "us-chicago-1", peerRegionId: "us-dallas-1", status: "skipped-incomplete" }),
            ]));
        });
    });

    describe("getMeshStaleness", () => {
        it("is unknown when there is no updatedAt", () => {
            expect(getMeshStaleness(null)).toBe("unknown");
        });

        it("is fresh within the threshold and stale beyond it", () => {
            const now = new Date("2026-01-02T00:00:00Z");
            const justInside = new Date(now.getTime() - MESH_STALE_THRESHOLD_MS + 1000);
            const justOutside = new Date(now.getTime() - MESH_STALE_THRESHOLD_MS - 1000);

            expect(getMeshStaleness(justInside, now)).toBe("fresh");
            expect(getMeshStaleness(justOutside, now)).toBe("stale");
        });
    });
});
