describe("APIHelper", () => {
    const originalApiOrigin = process.env.REACT_APP_API_ORIGIN;
    const mockFetch = jest.fn();

    const mockJsonResponse = (body: unknown, ok = true, status = ok ? 200 : 400) => ({
        ok,
        status,
        text: jest.fn().mockResolvedValue(JSON.stringify(body)),
    });

    const syncResponse = (overrides: Record<string, unknown> = {}) => ({
        regionId: "us-sanjose-1",
        syncedAt: "2026-08-10T00:00:00Z",
        added: 0,
        updated: 0,
        removed: 0,
        noChanges: true,
        log: "sync log",
        meshUpdated: 0,
        meshEnabled: true,
        meshApplied: 0,
        meshAdded: 0,
        meshRemoved: 0,
        meshSkipped: 0,
        meshRoutesAdded: 0,
        meshRoutesRemoved: 0,
        meshPeers: [],
        ...overrides,
    });

    // syncResponse() is the pre-meshStatusWritten/pre-policy wire shape an older
    // region still sends; the parser normalizes the absent fields to null, so
    // parsed results never deep-equal the raw body.
    const parsedSyncResponse = (overrides: Record<string, unknown> = {}) => ({
        ...syncResponse(overrides),
        meshStatusWritten: null,
        policyApplied: null,
        policyRowCount: null,
        policyStatusWritten: null,
    });

    const skippedIncompletePeer = (overrides: Record<string, unknown> = {}) => ({
        regionId: "us-chicago-1",
        status: "skipped-incomplete",
        reasonCode: "outside-aggregate",
        ...overrides,
    });

    beforeEach(() => {
        jest.resetModules();
        process.env.REACT_APP_API_ORIGIN = "https://api.example.test";
        mockFetch.mockReset();
        global.fetch = mockFetch;
    });

    afterEach(() => {
        process.env.REACT_APP_API_ORIGIN = originalApiOrigin;
    });

    it("creates clients through the regional clients endpoint", async () => {
        const responseBody = {
            clientId: "client-1",
            regionId: "us-sanjose-1",
            clientName: "Phone",
            status: "active",
            assignedTunnelIpv4: "10.0.0.2/32",
            assignedTunnelIpv6: "fd42:42:42::2/128",
            serverEndpointIpv4: "1.2.3.4",
            wireguardConfig: "[Interface]",
        };
        mockFetch.mockResolvedValue(mockJsonResponse(responseBody));
        const { createClient } = require("../APIHelper");

        const result = await createClient({ regionId: "us-sanjose-1", clientName: "Phone" }, "firebase-token");
        const request = mockFetch.mock.calls[0][1] as RequestInit;

        expect(mockFetch).toHaveBeenCalledWith("https://api.example.test/api/clients", expect.any(Object));
        expect(request.method).toBe("POST");
        expect((request.headers as Headers).get("Authorization")).toBe("Bearer firebase-token");
        expect(JSON.parse(request.body as string)).toEqual({
            regionId: "us-sanjose-1",
            clientName: "Phone",
        });
        expect(result).toEqual({ success: true, data: responseBody });
    });

    it("deletes clients through the regional client endpoint with user and region body", async () => {
        const responseBody = {
            userId: "user-1",
            clientId: "client/id",
            regionId: "us-sanjose-1",
            status: "removed",
        };
        mockFetch.mockResolvedValue(mockJsonResponse(responseBody));
        const { deleteClient } = require("../APIHelper");

        const result = await deleteClient("client/id", {
            userId: "user-1",
            regionId: "us-sanjose-1",
        }, "firebase-token");
        const request = mockFetch.mock.calls[0][1] as RequestInit;

        expect(mockFetch).toHaveBeenCalledWith("https://api.example.test/api/clients/client%2Fid", expect.any(Object));
        expect(request.method).toBe("DELETE");
        expect((request.headers as Headers).get("Authorization")).toBe("Bearer firebase-token");
        expect(JSON.parse(request.body as string)).toEqual({
            userId: "user-1",
            regionId: "us-sanjose-1",
        });
        expect(result).toEqual({ success: true, data: responseBody });
    });

    it("creates users through the regional users endpoint without region in the request body", async () => {
        const responseBody = {
            userId: "user-1",
            email: "user@example.com",
            role: "user",
        };
        mockFetch.mockResolvedValue(mockJsonResponse(responseBody));
        const { createAdminUser } = require("../APIHelper");

        const result = await createAdminUser({
            email: "user@example.com",
        }, "firebase-token", [
            { regionId: "us-sanjose-1", enabled: true, displayOrder: 20 },
        ]);
        const request = mockFetch.mock.calls[0][1] as RequestInit;

        expect(mockFetch).toHaveBeenCalledWith("https://api.example.test/api/users", expect.any(Object));
        expect(request.method).toBe("POST");
        expect((request.headers as Headers).get("Authorization")).toBe("Bearer firebase-token");
        expect(JSON.parse(request.body as string)).toEqual({
            email: "user@example.com",
        });
        expect(result).toEqual({ success: true, data: responseBody });
    });

    it("fetches regions through the unauthenticated apex endpoint", async () => {
        const responseBody = {
            regions: [
                {
                    regionId: "us-sanjose-1",
                    displayName: "San Jose",
                    displayOrder: 1,
                },
            ],
        };
        mockFetch.mockResolvedValue(mockJsonResponse(responseBody));
        const { fetchRegions } = require("../APIHelper");

        const result = await fetchRegions();
        const request = mockFetch.mock.calls[0][1] as RequestInit;

        expect(mockFetch).toHaveBeenCalledWith("https://api.example.test/api/regions", expect.any(Object));
        expect(request.method).toBe("GET");
        expect(request.headers).toBeUndefined();
        expect(request.body).toBeUndefined();
        expect(result).toEqual({ success: true, data: responseBody });
    });

    it("rejects an admin sync response that omits required meshUpdated", async () => {
        mockFetch.mockResolvedValue(mockJsonResponse({
            regionId: "us-sanjose-1",
            syncedAt: "2026-08-10T00:00:00Z",
            added: 0,
            updated: 0,
            removed: 0,
            noChanges: true,
            log: "sync log",
            meshEnabled: true,
            meshApplied: 1,
            meshAdded: 0,
            meshRemoved: 0,
            meshSkipped: 0,
            meshRoutesAdded: 0,
            meshRoutesRemoved: 0,
            meshPeers: [],
        }));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result).toMatchObject({
            success: false,
            failureType: "incompatible-response",
            errorCode: "INCOMPATIBLE_RESPONSE",
        });
    });

    it("accepts an admin sync response from a region that predates meshStatusWritten", async () => {
        // Regions are installed one at a time, so a newer dashboard must not reject
        // a host that has not been reinstalled yet.
        mockFetch.mockResolvedValue(mockJsonResponse(syncResponse()));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result).toMatchObject({ success: true });
        expect(result[0].result.data.meshStatusWritten).toBeNull();
    });

    it("carries a false meshStatusWritten through as a successful sync", async () => {
        mockFetch.mockResolvedValue(mockJsonResponse(syncResponse({ meshStatusWritten: false })));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result).toMatchObject({ success: true });
        expect(result[0].result.data.meshStatusWritten).toBe(false);
    });

    it("rejects an admin sync response whose meshStatusWritten is not a boolean", async () => {
        mockFetch.mockResolvedValue(mockJsonResponse(syncResponse({ meshStatusWritten: "false" })));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result).toMatchObject({
            success: false,
            failureType: "incompatible-response",
            errorCode: "INCOMPATIBLE_RESPONSE",
        });
    });

    it("accepts an admin sync response from a region that predates account-scoped ACL policy sync", async () => {
        // Regions are installed one at a time, so a newer dashboard must not reject
        // a host that has not been reinstalled yet.
        mockFetch.mockResolvedValue(mockJsonResponse(syncResponse()));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result).toMatchObject({ success: true });
        expect(result[0].result.data.policyApplied).toBeNull();
        expect(result[0].result.data.policyRowCount).toBeNull();
        expect(result[0].result.data.policyStatusWritten).toBeNull();
    });

    it("carries a failed policyApplied through as a successful sync", async () => {
        mockFetch.mockResolvedValue(mockJsonResponse(syncResponse({ policyApplied: false })));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result).toMatchObject({ success: true });
        expect(result[0].result.data.policyApplied).toBe(false);
        expect(result[0].result.data.policyRowCount).toBeNull();
        expect(result[0].result.data.policyStatusWritten).toBeNull();
    });

    it("carries a successful policy pass with rowCount and statusWritten through", async () => {
        mockFetch.mockResolvedValue(mockJsonResponse(syncResponse({
            policyApplied: true,
            policyRowCount: 12,
            policyStatusWritten: true,
        })));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result).toMatchObject({ success: true });
        expect(result[0].result.data.policyApplied).toBe(true);
        expect(result[0].result.data.policyRowCount).toBe(12);
        expect(result[0].result.data.policyStatusWritten).toBe(true);
    });

    it("carries a false policyStatusWritten through as a successful sync", async () => {
        mockFetch.mockResolvedValue(mockJsonResponse(syncResponse({
            policyApplied: true,
            policyRowCount: 12,
            policyStatusWritten: false,
        })));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result).toMatchObject({ success: true });
        expect(result[0].result.data.policyStatusWritten).toBe(false);
    });

    it("rejects an admin sync response whose policyApplied is not a boolean", async () => {
        mockFetch.mockResolvedValue(mockJsonResponse(syncResponse({ policyApplied: "false" })));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result).toMatchObject({
            success: false,
            failureType: "incompatible-response",
            errorCode: "INCOMPATIBLE_RESPONSE",
        });
    });

    it.each([
        ["negative", -1],
        ["fractional", 1.5],
    ])("rejects an admin sync response whose policyRowCount is %s", async (_label, policyRowCount) => {
        mockFetch.mockResolvedValue(mockJsonResponse(syncResponse({
            policyApplied: true,
            policyRowCount,
            policyStatusWritten: true,
        })));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result).toMatchObject({
            success: false,
            failureType: "incompatible-response",
            errorCode: "INCOMPATIBLE_RESPONSE",
        });
    });

    it("rejects an admin sync response whose policyStatusWritten is not a boolean", async () => {
        mockFetch.mockResolvedValue(mockJsonResponse(syncResponse({
            policyApplied: true,
            policyRowCount: 12,
            policyStatusWritten: "true",
        })));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result).toMatchObject({
            success: false,
            failureType: "incompatible-response",
            errorCode: "INCOMPATIBLE_RESPONSE",
        });
    });

    it("rejects an admin sync response for a different region", async () => {
        mockFetch.mockResolvedValue(mockJsonResponse({
            regionId: "us-chicago-1",
            syncedAt: "2026-08-10T00:00:00Z",
            added: 0,
            updated: 0,
            removed: 0,
            noChanges: true,
            log: "sync log",
            meshUpdated: 0,
            meshEnabled: true,
            meshApplied: 0,
            meshAdded: 0,
            meshRemoved: 0,
            meshSkipped: 0,
            meshRoutesAdded: 0,
            meshRoutesRemoved: 0,
            meshPeers: [],
        }));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result).toMatchObject({
            success: false,
            failureType: "incompatible-response",
            errorCode: "INCOMPATIBLE_RESPONSE",
        });
    });

    it("classifies a 409 SYNC_IN_PROGRESS as its own failure type", async () => {
        mockFetch.mockResolvedValue(mockJsonResponse({
            error: { code: "SYNC_IN_PROGRESS", message: "sync already running", requestId: "req-1" },
        }, false, 409));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result).toMatchObject({
            success: false,
            failureType: "sync-in-progress",
            errorCode: "SYNC_IN_PROGRESS",
            requestId: "req-1",
        });
    });

    it("leaves other regional sync failures unclassified", async () => {
        mockFetch.mockResolvedValue(mockJsonResponse({
            error: { code: "REGION_MISMATCH", message: "wrong region", requestId: "req-2" },
        }, false, 400));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result.success).toBe(false);
        expect(result[0].result.failureType).toBeUndefined();
    });

    it("times out one regional sync without blocking another region", async () => {
        jest.useFakeTimers();
        try {
            mockFetch
                .mockImplementationOnce((_endpoint: string, request: RequestInit) => (
                    new Promise((_resolve, reject) => {
                        request.signal?.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")));
                    })
                ))
                .mockResolvedValueOnce(mockJsonResponse(syncResponse({ regionId: "us-chicago-1" })));
            const { runRegionsSync, REGION_SYNC_TIMEOUT_MS } = require("../APIHelper");

            const resultPromise = runRegionsSync(["us-sanjose-1", "us-chicago-1"], "firebase-token");
            jest.advanceTimersByTime(REGION_SYNC_TIMEOUT_MS);
            const results = await resultPromise;

            expect(results[0]).toEqual({
                regionId: "us-sanjose-1",
                result: { success: false, error: "Regional API request timed out." },
            });
            expect(results[1]).toEqual({
                regionId: "us-chicago-1",
                result: { success: true, data: parsedSyncResponse({ regionId: "us-chicago-1" }) },
            });
        } finally {
            jest.useRealTimers();
        }
    });

    it("validates the current admin sync peer shape without requiring a public key", async () => {
        const responseBody = {
            regionId: "us-sanjose-1",
            syncedAt: "2026-08-10T00:00:00Z",
            added: 0,
            updated: 0,
            removed: 0,
            noChanges: false,
            log: "sync log",
            meshUpdated: 1,
            meshEnabled: true,
            meshApplied: 1,
            meshAdded: 1,
            meshRemoved: 0,
            meshSkipped: 0,
            meshRoutesAdded: 2,
            meshRoutesRemoved: 0,
            meshPeers: [{
                regionId: "us-chicago-1",
                status: "applied",
                endpointHostname: "wg.us-chicago-1.example.com",
                endpointPort: 51820,
                allowedNetworkV4: "10.0.1.0/24",
                allowedNetworkV6: "fd42:42:42:1::/64",
            }],
        };
        mockFetch.mockResolvedValue(mockJsonResponse(responseBody));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result).toEqual([{
            regionId: "us-sanjose-1",
            result: {
                success: true,
                data: {
                    ...responseBody,
                    meshStatusWritten: null,
                    policyApplied: null,
                    policyRowCount: null,
                    policyStatusWritten: null,
                },
            },
        }]);
    });

    it.each([
        ["endpoint hostname", { endpointHostname: 123 }],
        ["endpoint port", { endpointPort: "51820" }],
        ["network v4", { allowedNetworkV4: null }],
        ["network v6", { allowedNetworkV6: {} }],
    ])("rejects an applied peer with invalid %s", async (_label, invalidField) => {
        mockFetch.mockResolvedValue(mockJsonResponse({
            regionId: "us-sanjose-1",
            syncedAt: "2026-08-10T00:00:00Z",
            added: 0,
            updated: 0,
            removed: 0,
            noChanges: true,
            log: "sync log",
            meshUpdated: 0,
            meshEnabled: true,
            meshApplied: 1,
            meshAdded: 0,
            meshRemoved: 0,
            meshSkipped: 0,
            meshRoutesAdded: 0,
            meshRoutesRemoved: 0,
            meshPeers: [{
                regionId: "us-chicago-1",
                status: "applied",
                endpointHostname: "wg.us-chicago-1.example.com",
                endpointPort: 51820,
                allowedNetworkV4: "10.0.1.0/24",
                allowedNetworkV6: "fd42:42:42:1::/64",
                ...invalidField,
            }],
        }));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result).toMatchObject({ failureType: "incompatible-response" });
    });

    it("omits absent, null, and blank optional skipped-incomplete peer fields", async () => {
        mockFetch.mockResolvedValue(mockJsonResponse(syncResponse({
            meshSkipped: 3,
            meshPeers: [
                skippedIncompletePeer({ reasonCode: "missing-endpoint-hostname" }),
                skippedIncompletePeer({
                    reasonCode: "invalid-network-v4",
                    endpointHostname: null,
                    endpointPort: null,
                    allowedNetworkV4: null,
                    allowedNetworkV6: null,
                }),
                skippedIncompletePeer({
                    reasonCode: "invalid-network-v6",
                    endpointHostname: "  ",
                    allowedNetworkV4: "",
                    allowedNetworkV6: "\t",
                }),
            ],
        })));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result).toEqual([{ regionId: "us-sanjose-1", result: { success: true, data: parsedSyncResponse({
            meshSkipped: 3,
            meshPeers: [
                { regionId: "us-chicago-1", status: "skipped-incomplete", reasonCode: "missing-endpoint-hostname" },
                { regionId: "us-chicago-1", status: "skipped-incomplete", reasonCode: "invalid-network-v4" },
                { regionId: "us-chicago-1", status: "skipped-incomplete", reasonCode: "invalid-network-v6" },
            ],
        }) } }]);
    });

    it("accepts present nonblank valid skipped-incomplete peer endpoint metadata", async () => {
        mockFetch.mockResolvedValue(mockJsonResponse(syncResponse({
            meshSkipped: 1,
            meshPeers: [skippedIncompletePeer({
                endpointHostname: "2001:db8::1",
                endpointPort: 51820,
                allowedNetworkV4: "192.0.2.0/24",
                allowedNetworkV6: "2001:db8:1:2::/64",
            })],
        })));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result).toEqual([{ regionId: "us-sanjose-1", result: { success: true, data: parsedSyncResponse({
            meshSkipped: 1,
            meshPeers: [skippedIncompletePeer({
                endpointHostname: "2001:db8::1",
                endpointPort: 51820,
                allowedNetworkV4: "192.0.2.0/24",
                allowedNetworkV6: "2001:db8:1:2::/64",
            })],
        }) } }]);
    });

    it.each([
        ["endpoint hostname", { endpointHostname: "bad_hostname.example.com" }],
        ["endpoint port", { endpointPort: 65536 }],
        ["network v4", { allowedNetworkV4: "192.0.2.1/24" }],
        ["network v6", { allowedNetworkV6: "2001:db8:1:2::1/64" }],
    ])("rejects a skipped-incomplete peer with invalid nonblank %s", async (_label, invalidField) => {
        mockFetch.mockResolvedValue(mockJsonResponse(syncResponse({
            meshSkipped: 1,
            meshPeers: [skippedIncompletePeer(invalidField)],
        })));
        const { runRegionsSync } = require("../APIHelper");

        const result = await runRegionsSync(["us-sanjose-1"], "firebase-token");

        expect(result[0].result).toMatchObject({
            success: false,
            failureType: "incompatible-response",
            errorCode: "INCOMPATIBLE_RESPONSE",
        });
    });

    it("returns typed FastAPI error details", async () => {
        mockFetch.mockResolvedValue(mockJsonResponse({
            error: {
                code: "DUPLICATE_EMAIL",
                message: "Email already exists.",
                requestId: "request-1",
            },
        }, false, 409));
        const { createAdminUser } = require("../APIHelper");

        const result = await createAdminUser({
            email: "user@example.com",
        }, "firebase-token", [
            { regionId: "us-sanjose-1", enabled: true },
        ]);

        expect(result).toEqual({
            success: false,
            error: "Email already exists.",
            errorCode: "DUPLICATE_EMAIL",
            requestId: "request-1",
            status: 409,
            data: {
                error: {
                    code: "DUPLICATE_EMAIL",
                    message: "Email already exists.",
                    requestId: "request-1",
                },
            },
        });
    });

    it("checks account access through the apex auth endpoint", async () => {
        const responseBody = {
            userId: "user-1",
            email: "user@example.com",
            role: "user",
        };
        mockFetch.mockResolvedValue(mockJsonResponse(responseBody));
        const { checkAccountAccess } = require("../APIHelper");

        const result = await checkAccountAccess("firebase-token", [
            { regionId: "us-sanjose-1", enabled: true },
        ]);
        const request = mockFetch.mock.calls[0][1] as RequestInit;

        expect(mockFetch).toHaveBeenCalledWith("https://api.example.test/api/auth/check-access", expect.any(Object));
        expect(request.method).toBe("POST");
        expect((request.headers as Headers).get("Authorization")).toBe("Bearer firebase-token");
        expect(JSON.parse(request.body as string)).toEqual({});
        expect(result).toEqual({ success: true, data: responseBody });
    });

    it("fetches regional capacity through the regional capacity endpoint", async () => {
        const responseBody = {
            regionId: "us-sanjose-1",
            capacityLimit: 20,
            allocatedClientCount: 8,
        };
        mockFetch.mockResolvedValue(mockJsonResponse(responseBody));
        const { getRegionCapacity } = require("../APIHelper");

        const result = await getRegionCapacity("us-sanjose-1", "firebase-token");
        const request = mockFetch.mock.calls[0][1] as RequestInit;

        expect(mockFetch).toHaveBeenCalledWith("https://api.example.test/api/capacity", expect.any(Object));
        expect(request.method).toBe("GET");
        expect((request.headers as Headers).get("Authorization")).toBe("Bearer firebase-token");
        expect(request.body).toBeUndefined();
        expect(result).toEqual({ success: true, data: responseBody });
    });

    it("does not call users API when no enabled region exists", async () => {
        jest.resetModules();
        process.env.REACT_APP_API_ORIGIN = "";
        const { createAdminUser } = require("../APIHelper");

        const result = await createAdminUser({
            email: "user@example.com",
        }, "firebase-token", [
            { regionId: "us-sanjose-1", enabled: false },
        ]);

        expect(mockFetch).not.toHaveBeenCalled();
        expect(result).toEqual({
            success: false,
            error: "No enabled regions are available for user creation",
        });
    });
});

export {};
