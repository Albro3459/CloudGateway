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
    wireguardEndpointHostname: "wg.example.com",
    wireguardPort: 51820,
    wireguardPublicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    tunnelNetworkV4: "10.0.1.0/24",
    tunnelNetworkV6: "fd42:42:42:1::/64",
});

const appliedPeer = (overrides: Partial<MeshDoc["peers"][string]> = {}) => ({
    endpointHostname: "wg.example.com",
    endpointPort: 51820,
    publicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    allowedNetworkV4: "10.0.1.0/24",
    allowedNetworkV6: "fd42:42:42:1::/64",
    status: "applied" as const,
    reasonCode: null,
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
                        endpointPort: 51820,
                        publicKey: "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=",
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

        it("retains backend-shaped skipped-incomplete entries with empty metadata", () => {
            const doc = parseMeshDocument("us-sanjose-1", {
                meshEnabled: true,
                peers: {
                    "us-chicago-1": {
                        status: "skipped-incomplete",
                        reasonCode: "invalid-endpoint-port",
                    },
                },
            });

            expect(doc.peers["us-chicago-1"]).toMatchObject({
                status: "skipped-incomplete",
                endpointHostname: null,
                endpointPort: null,
                publicKey: null,
                allowedNetworkV4: null,
                allowedNetworkV6: null,
                reasonCode: "invalid-endpoint-port",
            });
        });

        it("drops applied entries without the current endpointPort snapshot", () => {
            const legacyPeer = {
                endpointHostname: "wg.example.com",
                publicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                allowedNetworkV4: "10.0.1.0/24",
                allowedNetworkV6: "fd42:42:42:1::/64",
                status: "applied" as const,
            };
            const doc = parseMeshDocument("us-sanjose-1", {
                peers: { "us-chicago-1": legacyPeer },
            });

            expect(doc.peers["us-chicago-1"]).toBeUndefined();
        });

        it("preserves future reason codes instead of dropping entries", () => {
            const doc = parseMeshDocument("us-sanjose-1", {
                peers: {
                    "us-chicago-1": appliedPeer({ status: "skipped-incomplete", reasonCode: "future-reason" }),
                },
            });

            expect(doc.peers["us-chicago-1"].reasonCode).toBe("future-reason");
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

        it("is never pending for a disabled region", () => {
            // A disabled region has no operational server and is not a Sync All
            // target, so its own Mesh doc can never be reconciled.
            const disabled = { ...region("us-chicago-1", true), enabled: false };
            const meshDoc = parseMeshDocument("us-chicago-1", { meshEnabled: false, peers: {} });

            expect(isRegionMeshPending(disabled, null)).toBe(false);
            expect(isRegionMeshPending(disabled, meshDoc)).toBe(false);
        });
    });

    describe("buildMeshLinkRows", () => {
        it("does not treat an applied entry without endpointPort as current state", () => {
            const regions = [region("us-sanjose-1", true), region("us-chicago-1", true)];
            const legacy = appliedPeer({ endpointPort: undefined });
            const rows = buildMeshLinkRows(regions, new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", { meshEnabled: true, peers: { "us-chicago-1": legacy } })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", { meshEnabled: true, peers: { "us-sanjose-1": appliedPeer() } })],
            ]));

            expect(rows[0]).toMatchObject({ status: "one-sided", pending: true, aToBStale: false });
        });

        it.each([
            ["public key", { publicKey: "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=" }],
            ["hostname", { endpointHostname: "other.example.com" }],
            ["port", { endpointPort: 51821 }],
            ["tunnel v4", { allowedNetworkV4: "10.0.2.0/24" }],
            ["tunnel v6", { allowedNetworkV6: "fd42:42:42:2::/64" }],
        ])("marks an applied snapshot stale when %s changes", (_label, mismatch) => {
            const regions = [region("us-sanjose-1", true), region("us-chicago-1", true)];
            const rows = buildMeshLinkRows(regions, new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", { meshEnabled: true, peers: { "us-chicago-1": appliedPeer(mismatch) } })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", { meshEnabled: true, peers: { "us-sanjose-1": appliedPeer() } })],
            ]));

            expect(rows[0].status).toBe("stale");
            expect(rows[0].pending).toBe(true);
        });

        it("does not classify a dropped legacy direction as stale", () => {
            const regions = [region("us-sanjose-1", true), region("us-chicago-1", true)];
            const rows = buildMeshLinkRows(regions, new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", { meshEnabled: true, peers: { "us-chicago-1": appliedPeer({ endpointPort: undefined }) } })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", { meshEnabled: true, peers: { "us-sanjose-1": appliedPeer() } })],
            ]));

            expect(rows[0].status).toBe("one-sided");
        });

        it("marks an applied entry pending when mesh membership is disabled", () => {
            const regions = [region("us-sanjose-1", false), region("us-chicago-1", true)];
            const rows = buildMeshLinkRows(regions, new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", { meshEnabled: false, peers: { "us-chicago-1": appliedPeer() } })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", { meshEnabled: true, peers: { "us-sanjose-1": appliedPeer() } })],
            ]));

            expect(rows[0].pending).toBe(true);
        });

        it("does not keep pending a persistent identical invalid skip", () => {
            const invalidRegion = (regionId: string) => ({
                ...region(regionId, true),
                wireguardEndpointHostname: null,
                wireguardPort: null,
                wireguardPublicKey: null,
                tunnelNetworkV4: null,
                tunnelNetworkV6: null,
            });
            const regions = [invalidRegion("us-sanjose-1"), invalidRegion("us-chicago-1")];
            const invalid = { status: "skipped-incomplete" as const, reasonCode: "invalid-endpoint-port" };
            const rows = buildMeshLinkRows(regions, new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", { meshEnabled: true, peers: { "us-chicago-1": invalid } })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", { meshEnabled: true, peers: { "us-sanjose-1": invalid } })],
            ]));

            expect(rows[0].status).toBe("not-synced");
            expect(rows[0].pending).toBe(false);
        });

        it("keeps local-network-invalid as a persistent configuration failure", () => {
            const regions = [region("us-sanjose-1", true), region("us-chicago-1", true)];
            const localNetworkInvalid = {
                ...appliedPeer(),
                status: "skipped-incomplete" as const,
                reasonCode: "local-network-invalid",
            };
            const rows = buildMeshLinkRows(regions, new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", { meshEnabled: true, peers: { "us-chicago-1": localNetworkInvalid } })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", { meshEnabled: true, peers: { "us-sanjose-1": appliedPeer() } })],
            ]));

            expect(rows[0].pending).toBe(false);
        });

        it("treats an unrecognized reason code as a persistent failure, not pending", () => {
            // The reason-code enum is closed, but a future/unrecognized code must default
            // to "still present" rather than flip-flopping off snapshot equality.
            const regions = [region("us-sanjose-1", true), region("us-chicago-1", true)];
            const futureReason = {
                ...appliedPeer(),
                status: "skipped-incomplete" as const,
                reasonCode: "future-reason",
            };
            const rows = buildMeshLinkRows(regions, new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", { meshEnabled: true, peers: { "us-chicago-1": futureReason } })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", { meshEnabled: true, peers: { "us-sanjose-1": appliedPeer() } })],
            ]));

            expect(rows[0].pending).toBe(false);
        });

        it.each([
            ["missing public key", { wireguardPublicKey: null }, { publicKey: null, reasonCode: "missing-public-key" }],
            ["invalid public key", { wireguardPublicKey: null }, { publicKey: null, reasonCode: "invalid-public-key" }],
            ["missing hostname", { wireguardEndpointHostname: null }, { endpointHostname: null, reasonCode: "missing-endpoint-hostname" }],
            ["invalid hostname", { wireguardEndpointHostname: null }, { endpointHostname: null, reasonCode: "invalid-endpoint-hostname" }],
            ["invalid port", { wireguardPort: null }, { endpointPort: null, reasonCode: "invalid-endpoint-port" }],
            ["invalid IPv4 network", { tunnelNetworkV4: null }, { allowedNetworkV4: null, reasonCode: "invalid-network-v4" }],
            ["invalid IPv6 network", { tunnelNetworkV6: null }, { allowedNetworkV6: null, reasonCode: "invalid-network-v6" }],
        ])("does not mark unchanged backend-shaped %s as pending", (_label, regionOverrides, peerOverrides) => {
            const invalidRegion = (regionId: string) => ({
                ...region(regionId, true),
                ...regionOverrides,
            });
            const regions = [invalidRegion("us-sanjose-1"), invalidRegion("us-chicago-1")];
            const skippedPeer = {
                ...appliedPeer(),
                ...peerOverrides,
                status: "skipped-incomplete" as const,
            };
            const rows = buildMeshLinkRows(regions, new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", { meshEnabled: true, peers: { "us-chicago-1": skippedPeer } })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", { meshEnabled: true, peers: { "us-sanjose-1": skippedPeer } })],
            ]));

            expect(rows[0].pending).toBe(false);
        });

        it.each([
            ["zero", 0],
            ["negative", -1],
            ["above the maximum", 65536],
            ["non-integer", 51820.5],
            ["missing", undefined],
            ["null", null],
            ["malformed", "not-a-port"],
            ["NaN", Number.NaN],
        ] as const)("does not mark an invalid %s endpoint port as pending", (_label, wireguardPort) => {
            const invalidPort = wireguardPort as unknown as Region["wireguardPort"];
            const peerEndpointPort = typeof wireguardPort === "number" && Number.isFinite(wireguardPort)
                ? wireguardPort
                : null;
            const invalidRegion = (regionId: string) => ({
                ...region(regionId, true),
                wireguardPort: invalidPort,
            });
            const skippedPeer = {
                ...appliedPeer({ endpointPort: peerEndpointPort }),
                status: "skipped-incomplete" as const,
                reasonCode: "invalid-endpoint-port",
            };
            const regions = [invalidRegion("us-sanjose-1"), invalidRegion("us-chicago-1")];
            const rows = buildMeshLinkRows(regions, new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", { meshEnabled: true, peers: { "us-chicago-1": skippedPeer } })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", { meshEnabled: true, peers: { "us-sanjose-1": skippedPeer } })],
            ]));

            expect(rows[0].pending).toBe(false);
        });

        it("marks a repaired valid endpoint port pending until sync applies it", () => {
            const regions = [region("us-sanjose-1", true), region("us-chicago-1", true)];
            const invalidPort = {
                ...appliedPeer({ endpointPort: 0 }),
                status: "skipped-incomplete" as const,
                reasonCode: "invalid-endpoint-port",
            };
            const pendingDocs = new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", { meshEnabled: true, peers: { "us-chicago-1": invalidPort } })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", { meshEnabled: true, peers: { "us-sanjose-1": appliedPeer() } })],
            ]);

            expect(buildMeshLinkRows(regions, pendingDocs)[0].pending).toBe(true);

            const syncedDocs = new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", { meshEnabled: true, peers: { "us-chicago-1": appliedPeer() } })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", { meshEnabled: true, peers: { "us-sanjose-1": appliedPeer() } })],
            ]);

            expect(buildMeshLinkRows(regions, syncedDocs)[0].pending).toBe(false);
        });

        it("marks one-sided current application pending when both regions are enabled", () => {
            const regions = [region("us-sanjose-1", true), region("us-chicago-1", true)];
            const rows = buildMeshLinkRows(regions, new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", { meshEnabled: true, peers: { "us-chicago-1": appliedPeer() } })],
                ["us-chicago-1", parseMeshDocument("us-chicago-1", { meshEnabled: true, peers: {} })],
            ]));

            expect(rows[0]).toMatchObject({ status: "one-sided", pending: true });
        });

        it("preserves diagnostic reason codes in warnings", () => {
            const doc = parseMeshDocument("us-sanjose-1", {
                meshEnabled: true,
                peers: {
                    "us-chicago-1": { status: "skipped-incomplete", reasonCode: "duplicate-public-key" },
                },
            });

            expect(collectMeshWarnings(new Map([["us-sanjose-1", doc]]))[0].reasonCode).toBe("duplicate-public-key");
        });

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

        it("keeps an unchanged skipped direction visible without marking it pending", () => {
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

        it("marks a live host's peer for a disabled region as pending removal", () => {
            const regions = [
                region("us-sanjose-1", true),
                { ...region("us-chicago-1", true), enabled: false },
            ];
            const rows = buildMeshLinkRows(regions, new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", {
                    meshEnabled: true,
                    peers: { "us-chicago-1": appliedPeer() },
                })],
            ]));

            expect(rows[0].pending).toBe(true);
            expect(rows[0].status).toBe("one-sided");
        });

        it("does not mark a dead host's own stale peer as pending", () => {
            // Only a live host runs a sync pass, so nothing can reconcile an
            // entry that lives in a disabled region's own Mesh doc.
            const regions = [
                { ...region("us-sanjose-1", true), enabled: false },
                { ...region("us-chicago-1", true), enabled: false },
            ];
            const rows = buildMeshLinkRows(regions, new Map([
                ["us-sanjose-1", parseMeshDocument("us-sanjose-1", {
                    meshEnabled: true,
                    peers: { "us-chicago-1": appliedPeer() },
                })],
            ]));

            expect(rows[0].pending).toBe(false);
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
