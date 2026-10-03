import { decideDeviceRequest, parseDeviceApprovalRoute, verifyDeviceRequest } from "../deviceAuthHelper";

describe("device approval route", () => {
    it("accepts only the internal route with a 32 digit lowercase hex ID and six digit code", () => {
        expect(parseDeviceApprovalRoute("/auth/code?deviceRequestId=abcdef0123456789abcdef0123456789&userCode=000042"))
            .toEqual({
                deviceRequestId: "abcdef0123456789abcdef0123456789",
                userCode: "000042",
                path: "/auth/code?deviceRequestId=abcdef0123456789abcdef0123456789&userCode=000042",
            });
    });

    it.each([
        "https://attacker.example/",
        "//attacker.example/",
        "/home",
        "/auth/code?deviceRequestId=ABCDEF0123456789ABCDEF0123456789&userCode=000042",
        "/auth/code?deviceRequestId=abcdef0123456789abcdef0123456789&userCode=42",
        "/auth/code?deviceRequestId=abcdef0123456789abcdef0123456789&userCode=000042&next=/home",
    ])("rejects unsafe or malformed return path %s", path => {
        expect(parseDeviceApprovalRoute(path)).toBeNull();
    });
});

describe("device authorization API helpers", () => {
    afterEach(() => jest.restoreAllMocks());

    it("sends only the request ID and code when verifying, with the Firebase bearer token", async () => {
        const response = {
            ok: true,
            text: async () => JSON.stringify({ deviceName: "Laptop", userCode: "000042", state: "pending", expiresAt: "2026-10-01T10:00:00Z" }),
        } as Response;
        const fetchMock = jest.spyOn(global, "fetch").mockResolvedValue(response);

        const result = await verifyDeviceRequest("abcdef0123456789abcdef0123456789", "000042", "firebase-token");

        expect(result.success).toBe(true);
        expect(fetchMock.mock.calls[0][0]).toMatch(/\/api\/device\/verify$/);
        const request = fetchMock.mock.calls[0][1];
        const headers = new Headers(request?.headers);
        expect(request?.method).toBe("POST");
        expect(headers.get("Authorization")).toBe("Bearer firebase-token");
        expect(headers.get("Content-Type")).toBe("application/json");
        expect(request?.body).toBe(JSON.stringify({ deviceRequestId: "abcdef0123456789abcdef0123456789", userCode: "000042" }));
    });

    it("sends a decision only through the explicit decision helper and keeps throttle timing", async () => {
        const response = {
            ok: false,
            status: 429,
            headers: new Headers({ "Retry-After": "12" }),
            text: async () => JSON.stringify({ error: { code: "DEVICE_AUTH_THROTTLED", message: "Wait" } }),
        } as Response;
        const fetchMock = jest.spyOn(global, "fetch").mockResolvedValue(response);

        const result = await decideDeviceRequest("abcdef0123456789abcdef0123456789", "000042", "approve", "firebase-token");

        expect(result).toMatchObject({ success: false, errorCode: "DEVICE_AUTH_THROTTLED", status: 429, retryAfter: "12" });
        expect(fetchMock).toHaveBeenCalledWith(
            expect.stringMatching(/\/api\/device\/approve$/),
            expect.objectContaining({ body: JSON.stringify({
                deviceRequestId: "abcdef0123456789abcdef0123456789",
                userCode: "000042",
                decision: "approve",
            }) }),
        );
    });

    it("handles error mocks without response headers", async () => {
        const response = {
            ok: false,
            status: 400,
            text: async () => JSON.stringify({ error: { code: "DEVICE_AUTH_INVALID", message: "Invalid" } }),
        } as unknown as Response;
        jest.spyOn(global, "fetch").mockResolvedValue(response);

        await expect(verifyDeviceRequest("abcdef0123456789abcdef0123456789", "000042", "firebase-token"))
            .resolves.toMatchObject({ success: false, errorCode: "DEVICE_AUTH_INVALID", status: 400 });
    });
});
