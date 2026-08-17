import {
    buildPolicyStatusRows,
    getPolicyStaleness,
    parsePolicyDocument,
    POLICY_STALE_THRESHOLD_MS,
    PolicyDoc,
    PolicyDocsById,
} from "../policyHelper";
import { Region } from "../regionsHelper";

const region = (regionId: string): Region => ({
    regionId,
    displayName: regionId,
    enabled: true,
    displayOrder: 1000,
    meshEnabled: true,
    wireguardEndpointHostname: "wg.example.com",
    wireguardPort: 51820,
    wireguardPublicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    tunnelNetworkV4: "10.0.1.0/24",
    tunnelNetworkV6: "fd42:42:42:1::/64",
});

const policyDoc = (regionId: string, overrides: Partial<PolicyDoc> = {}): PolicyDoc => ({
    regionId,
    mapHashV4: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    mapHashV6: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    rowCount: 3,
    appliedSequence: 1,
    dataVintage: new Date("2026-01-01T00:00:00Z"),
    updatedAt: new Date("2026-01-01T00:00:00Z"),
    ...overrides,
});

describe("policyHelper", () => {
    describe("parsePolicyDocument", () => {
        it("parses a well-formed doc", () => {
            const doc = parsePolicyDocument("us-sanjose-1", {
                mapHashV4: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                mapHashV6: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                rowCount: 12,
                appliedSequence: 4,
                dataVintage: new Date("2026-01-01T00:00:00Z"),
                updatedAt: new Date("2026-01-02T00:00:00Z"),
            });

            expect(doc).toEqual({
                regionId: "us-sanjose-1",
                mapHashV4: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                mapHashV6: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                rowCount: 12,
                appliedSequence: 4,
                dataVintage: new Date("2026-01-01T00:00:00Z"),
                updatedAt: new Date("2026-01-02T00:00:00Z"),
            });
        });

        it("never throws on a malformed or partial doc, coercing bad fields to null", () => {
            const doc = parsePolicyDocument("us-sanjose-1", {
                mapHashV4: 12345,
                mapHashV6: undefined,
                rowCount: "not-a-number",
                appliedSequence: Number.NaN,
                dataVintage: "not-a-date",
                // updatedAt missing entirely
            });

            expect(doc).toEqual({
                regionId: "us-sanjose-1",
                mapHashV4: null,
                mapHashV6: null,
                rowCount: null,
                appliedSequence: null,
                dataVintage: null,
                updatedAt: null,
            });
        });

        it("treats an empty object as a fully null doc rather than throwing", () => {
            expect(() => parsePolicyDocument("us-sanjose-1", {})).not.toThrow();
            expect(parsePolicyDocument("us-sanjose-1", {}).regionId).toBe("us-sanjose-1");
        });
    });

    describe("buildPolicyStatusRows", () => {
        it("marks a region ok when its hashes match a clear fleet majority", () => {
            const regions = [region("us-sanjose-1"), region("us-chicago-1"), region("us-dallas-1")];
            const docs: PolicyDocsById = new Map([
                ["us-sanjose-1", policyDoc("us-sanjose-1")],
                ["us-chicago-1", policyDoc("us-chicago-1")],
                ["us-dallas-1", policyDoc("us-dallas-1", { mapHashV4: "cccccccccccccccccccccccccccccccc" })],
            ]);

            const rows = buildPolicyStatusRows(regions, docs);

            expect(rows.find(r => r.regionId === "us-sanjose-1")).toMatchObject({ state: "ok", driftedV4: false, driftedV6: false });
            expect(rows.find(r => r.regionId === "us-chicago-1")).toMatchObject({ state: "ok", driftedV4: false, driftedV6: false });
        });

        it("flags the minority region as drifted against a clear majority", () => {
            const regions = [region("us-sanjose-1"), region("us-chicago-1"), region("us-dallas-1")];
            const docs: PolicyDocsById = new Map([
                ["us-sanjose-1", policyDoc("us-sanjose-1")],
                ["us-chicago-1", policyDoc("us-chicago-1")],
                ["us-dallas-1", policyDoc("us-dallas-1", { mapHashV4: "cccccccccccccccccccccccccccccccc" })],
            ]);

            const rows = buildPolicyStatusRows(regions, docs);

            const dallas = rows.find(r => r.regionId === "us-dallas-1");
            expect(dallas).toMatchObject({ state: "drifted", driftedV4: true, driftedV6: false });
        });

        it("flags every comparable region as drifted when there is no strict majority (even split)", () => {
            const regions = [region("us-sanjose-1"), region("us-chicago-1")];
            const docs: PolicyDocsById = new Map([
                ["us-sanjose-1", policyDoc("us-sanjose-1", { mapHashV4: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" })],
                ["us-chicago-1", policyDoc("us-chicago-1", { mapHashV4: "cccccccccccccccccccccccccccccccc" })],
            ]);

            const rows = buildPolicyStatusRows(regions, docs);

            expect(rows.find(r => r.regionId === "us-sanjose-1")).toMatchObject({ state: "drifted", driftedV4: true });
            expect(rows.find(r => r.regionId === "us-chicago-1")).toMatchObject({ state: "drifted", driftedV4: true });
        });

        it("flags every comparable region as drifted when every region disagrees (three-way split)", () => {
            const regions = [region("us-sanjose-1"), region("us-chicago-1"), region("us-dallas-1")];
            const docs: PolicyDocsById = new Map([
                ["us-sanjose-1", policyDoc("us-sanjose-1", { mapHashV4: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" })],
                ["us-chicago-1", policyDoc("us-chicago-1", { mapHashV4: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" })],
                ["us-dallas-1", policyDoc("us-dallas-1", { mapHashV4: "cccccccccccccccccccccccccccccccc" })],
            ]);

            const rows = buildPolicyStatusRows(regions, docs);

            expect(rows.every(r => r.state === "drifted")).toBe(true);
        });

        it("never marks a lone comparable region as drifted, since it has no peers to differ from", () => {
            const regions = [region("us-sanjose-1")];
            const docs: PolicyDocsById = new Map([["us-sanjose-1", policyDoc("us-sanjose-1")]]);

            const rows = buildPolicyStatusRows(regions, docs);

            expect(rows[0]).toMatchObject({ state: "ok", driftedV4: false, driftedV6: false });
        });

        it("marks a region stale when its dataVintage lags peers beyond the threshold", () => {
            const regions = [region("us-sanjose-1"), region("us-chicago-1")];
            const fresh = new Date("2026-01-02T00:00:00Z");
            const lagging = new Date(fresh.getTime() - POLICY_STALE_THRESHOLD_MS - 1000);
            const docs: PolicyDocsById = new Map([
                ["us-sanjose-1", policyDoc("us-sanjose-1", { dataVintage: fresh, updatedAt: fresh })],
                ["us-chicago-1", policyDoc("us-chicago-1", { dataVintage: lagging, updatedAt: lagging })],
            ]);

            const rows = buildPolicyStatusRows(regions, docs);

            expect(rows.find(r => r.regionId === "us-chicago-1")).toMatchObject({ state: "stale", stale: true });
            expect(rows.find(r => r.regionId === "us-sanjose-1")).toMatchObject({ state: "ok", stale: false });
        });

        it("does not mark a region stale when it is within the threshold of its peers", () => {
            const regions = [region("us-sanjose-1"), region("us-chicago-1")];
            const fresh = new Date("2026-01-02T00:00:00Z");
            const justInside = new Date(fresh.getTime() - POLICY_STALE_THRESHOLD_MS + 1000);
            const docs: PolicyDocsById = new Map([
                ["us-sanjose-1", policyDoc("us-sanjose-1", { dataVintage: fresh, updatedAt: fresh })],
                ["us-chicago-1", policyDoc("us-chicago-1", { dataVintage: justInside, updatedAt: justInside })],
            ]);

            const rows = buildPolicyStatusRows(regions, docs);

            expect(rows.find(r => r.regionId === "us-chicago-1")).toMatchObject({ state: "ok", stale: false });
        });

        it("renders a region with no Policy doc as never-synced, not a crash or a failure", () => {
            const regions = [region("us-sanjose-1")];
            const docs: PolicyDocsById = new Map([["us-sanjose-1", null]]);

            const rows = buildPolicyStatusRows(regions, docs);

            expect(rows[0]).toMatchObject({ state: "never-synced", doc: null, driftedV4: false, driftedV6: false, stale: false });
        });

        it("renders a region missing entirely from the docs map as never-synced", () => {
            const regions = [region("us-sanjose-1")];
            const docs: PolicyDocsById = new Map();

            const rows = buildPolicyStatusRows(regions, docs);

            expect(rows[0]).toMatchObject({ state: "never-synced", doc: null });
        });

        it("renders a doc missing identity fields as unreadable rather than comparing it", () => {
            const regions = [region("us-sanjose-1"), region("us-chicago-1")];
            const docs: PolicyDocsById = new Map([
                ["us-sanjose-1", policyDoc("us-sanjose-1", { mapHashV4: null })],
                ["us-chicago-1", policyDoc("us-chicago-1")],
            ]);

            const rows = buildPolicyStatusRows(regions, docs);

            const sanJose = rows.find(r => r.regionId === "us-sanjose-1");
            expect(sanJose).toMatchObject({ state: "unreadable", driftedV4: false, driftedV6: false });
            // The unreadable doc must not count toward the comparable set for
            // the other region's drift check.
            const chicago = rows.find(r => r.regionId === "us-chicago-1");
            expect(chicago).toMatchObject({ state: "ok", driftedV4: false });
        });

        it("does not treat a null dataVintage alone as corruption before any snapshot has applied", () => {
            const regions = [region("us-sanjose-1")];
            const docs: PolicyDocsById = new Map([
                ["us-sanjose-1", policyDoc("us-sanjose-1", { dataVintage: null })],
            ]);

            const rows = buildPolicyStatusRows(regions, docs);

            expect(rows[0].state).not.toBe("unreadable");
        });
    });

    describe("getPolicyStaleness", () => {
        it("is unknown when there is no dataVintage", () => {
            expect(getPolicyStaleness(null, new Date("2026-01-01T00:00:00Z"))).toBe("unknown");
        });

        it("is fresh when there is no peer to lag behind", () => {
            expect(getPolicyStaleness(new Date("2020-01-01T00:00:00Z"), null)).toBe("fresh");
        });

        it("is fresh within the threshold and stale beyond it", () => {
            const peerMax = new Date("2026-01-02T00:00:00Z");
            const justInside = new Date(peerMax.getTime() - POLICY_STALE_THRESHOLD_MS + 1000);
            const justOutside = new Date(peerMax.getTime() - POLICY_STALE_THRESHOLD_MS - 1000);

            expect(getPolicyStaleness(justInside, peerMax)).toBe("fresh");
            expect(getPolicyStaleness(justOutside, peerMax)).toBe("stale");
        });
    });
});
