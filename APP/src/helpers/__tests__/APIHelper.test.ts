describe("APIHelper", () => {
    const originalApiOrigin = process.env.REACT_APP_API_ORIGIN;
    const mockFetch = jest.fn();

    const mockJsonResponse = (body: unknown, ok = true, status = ok ? 200 : 400) => ({
        ok,
        status,
        text: jest.fn().mockResolvedValue(JSON.stringify(body)),
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
            displayName: "Test User",
        }, "firebase-token", [
            { regionId: "us-sanjose-1", enabled: true, displayOrder: 20 },
        ]);
        const request = mockFetch.mock.calls[0][1] as RequestInit;

        expect(mockFetch).toHaveBeenCalledWith("https://api.example.test/api/users", expect.any(Object));
        expect(request.method).toBe("POST");
        expect((request.headers as Headers).get("Authorization")).toBe("Bearer firebase-token");
        expect(JSON.parse(request.body as string)).toEqual({
            email: "user@example.com",
            displayName: "Test User",
        });
        expect(result).toEqual({ success: true, data: responseBody });
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

    it("checks account access through the regional auth endpoint", async () => {
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
