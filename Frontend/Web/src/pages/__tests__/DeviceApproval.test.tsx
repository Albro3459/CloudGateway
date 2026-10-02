import React from "react";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";

let mockAuthCallback: ((user: unknown) => void) | undefined;
let mockCurrentUser: unknown = null;
let mockRouteSearch = "";
const mockNavigate = jest.fn();

jest.mock("react-router-dom", () => ({
    useLocation: () => ({ search: mockRouteSearch }),
    useNavigate: () => mockNavigate,
}), { virtual: true });

jest.mock("../../firebase", () => ({
    auth: { get currentUser() { return mockCurrentUser; } },
    onAuthStateChanged: jest.fn((_auth, callback) => {
        mockAuthCallback = callback;
        callback(mockCurrentUser);
        return () => undefined;
    }),
}));

jest.mock("../../helpers/deviceAuthHelper", () => ({
    ...jest.requireActual("../../helpers/deviceAuthHelper"),
    verifyDeviceRequest: jest.fn(),
    decideDeviceRequest: jest.fn(),
}));

describe("DeviceApproval", () => {
    const route = "/auth/code?deviceRequestId=abcdef0123456789abcdef0123456789&userCode=000042";
    const user = {
        uid: "account-1",
        email: "person@example.com",
        getIdToken: jest.fn().mockResolvedValue("firebase-token"),
    };

    const renderApproval = (path = route, strictMode = false) => {
        const { default: DeviceApproval } = require("../DeviceApproval");
        mockRouteSearch = path.includes("?") ? path.slice(path.indexOf("?")) : "";
        return render(strictMode ? <React.StrictMode><DeviceApproval /></React.StrictMode> : <DeviceApproval />);
    };

    beforeEach(() => {
        jest.clearAllMocks();
        mockRouteSearch = "";
        mockCurrentUser = user;
        user.getIdToken.mockResolvedValue("firebase-token");
        const { onAuthStateChanged } = require("../../firebase");
        onAuthStateChanged.mockImplementation((_auth: unknown, callback: (user: unknown) => void) => {
            mockAuthCallback = callback;
            callback(mockCurrentUser);
            return jest.fn();
        });
        const { verifyDeviceRequest, decideDeviceRequest } = require("../../helpers/deviceAuthHelper");
        verifyDeviceRequest.mockResolvedValue({ success: true, data: {
            deviceName: "Unverified laptop",
            userCode: "000042",
            state: "pending",
            expiresAt: "2026-10-01T10:00:00Z",
        } });
        decideDeviceRequest.mockResolvedValue({ success: true, data: { state: "approved" } });
    });

    it("requires an explicit approve click and ignores duplicate clicks", async () => {
        const { decideDeviceRequest } = require("../../helpers/deviceAuthHelper");
        renderApproval();

        await screen.findByText("Unverified laptop");
        expect(screen.getByText("person@example.com")).toBeTruthy();
        expect(decideDeviceRequest).not.toHaveBeenCalled();

        const approveButton = screen.getByRole("button", { name: "Approve device" });
        fireEvent.click(approveButton);
        fireEvent.click(approveButton);
        await waitFor(() => expect(decideDeviceRequest).toHaveBeenCalledWith(
            "abcdef0123456789abcdef0123456789", "000042", "approve", "firebase-token",
        ));
        expect(decideDeviceRequest).toHaveBeenCalledTimes(1);
        expect(await screen.findByText("Device approved. You can return to it now.")).toBeTruthy();
    });

    it("sends an explicit deny decision", async () => {
        const { decideDeviceRequest } = require("../../helpers/deviceAuthHelper");
        decideDeviceRequest.mockResolvedValue({ success: true, data: { state: "denied" } });
        renderApproval();
        await screen.findByText("Unverified laptop");

        fireEvent.click(screen.getByRole("button", { name: "Deny device" }));

        await waitFor(() => expect(decideDeviceRequest).toHaveBeenCalledWith(
            "abcdef0123456789abcdef0123456789", "000042", "deny", "firebase-token",
        ));
        expect(await screen.findByText("This device request was denied.")).toBeTruthy();
    });

    it.each([
        ["denied", "This device request was denied."],
        ["consumed", "This device request has already been used."],
    ])("shows terminal verification state %s", async (state, message) => {
        const { verifyDeviceRequest } = require("../../helpers/deviceAuthHelper");
        verifyDeviceRequest.mockResolvedValue({ success: true, data: {
            deviceName: "Laptop", userCode: "000042", state, expiresAt: "2026-10-01T10:00:00Z",
        } });
        renderApproval();
        expect(await screen.findByText(message)).toBeTruthy();
        expect(screen.queryByRole("button", { name: "Approve device" })).toBeNull();
    });

    it.each([
        ["DEVICE_AUTH_INVALID", 400, "invalid", "This device request is invalid or can no longer be changed."],
        ["DEVICE_AUTH_EXPIRED", 410, "expired", "This device request has expired. Start again on the device."],
        ["DEVICE_AUTH_THROTTLED", 429, "throttled", "Too many attempts. Wait before trying again."],
        ["DEVICE_AUTH_UNAVAILABLE", 503, undefined, "Unable to verify the device request. Try again later."],
    ])("shows the API error state %s", async (errorCode, status, _state, message) => {
        const { verifyDeviceRequest } = require("../../helpers/deviceAuthHelper");
        verifyDeviceRequest.mockResolvedValue({ success: false, error: "API error", errorCode, status, retryAfter: "15" });
        renderApproval();
        expect(await screen.findByText(message)).toBeTruthy();
        if (status === 429) expect(screen.getByText("Try again after 15.")).toBeTruthy();
    });

    it("rejects malformed route parameters before contacting the API", async () => {
        const { verifyDeviceRequest } = require("../../helpers/deviceAuthHelper");
        renderApproval("/auth/code?deviceRequestId=bad&userCode=1");
        expect(await screen.findByText("This device request is invalid or can no longer be changed.")).toBeTruthy();
        expect(verifyDeviceRequest).not.toHaveBeenCalled();
    });

    it("hides prior verification and rejects its action after a route change", async () => {
        const { default: DeviceApproval } = require("../DeviceApproval");
        const { verifyDeviceRequest, decideDeviceRequest } = require("../../helpers/deviceAuthHelper");
        const { onAuthStateChanged } = require("../../firebase");
        onAuthStateChanged.mockImplementation((_auth: unknown, callback: (user: unknown) => void) => {
            mockAuthCallback = callback;
            return jest.fn();
        });
        const rendered = renderApproval();
        expect(screen.getByRole("status").textContent).toContain("Checking");
        expect(verifyDeviceRequest).not.toHaveBeenCalled();

        await act(async () => mockAuthCallback?.(user));
        await screen.findByText("Unverified laptop");
        const oldApproveButton = screen.getByRole("button", { name: "Approve device" });
        mockRouteSearch = "?deviceRequestId=0123456789abcdef0123456789abcdef&userCode=000077";
        rendered.rerender(<DeviceApproval />);

        expect(screen.queryByText("Unverified laptop")).toBeNull();
        expect(screen.queryByRole("button", { name: "Approve device" })).toBeNull();
        expect(screen.getByText("000077")).toBeTruthy();
        fireEvent.click(oldApproveButton);
        expect(decideDeviceRequest).not.toHaveBeenCalled();
    });

    it("stays safe under StrictMode effect replay", async () => {
        const { verifyDeviceRequest, decideDeviceRequest } = require("../../helpers/deviceAuthHelper");
        renderApproval(route, true);

        await screen.findByText("Unverified laptop");
        expect(verifyDeviceRequest).toHaveBeenCalledTimes(1);
        expect(decideDeviceRequest).not.toHaveBeenCalled();
    });

    it("ignores a late verification from the account that was replaced", async () => {
        const { verifyDeviceRequest } = require("../../helpers/deviceAuthHelper");
        let resolveOld!: (result: unknown) => void;
        const oldRequest = new Promise(resolve => { resolveOld = resolve; });
        const newUser = { uid: "account-2", email: "new@example.com", getIdToken: jest.fn().mockResolvedValue("new-token") };
        verifyDeviceRequest
            .mockReturnValueOnce(oldRequest)
            .mockResolvedValueOnce({ success: true, data: {
                deviceName: "Current device", userCode: "000042", state: "pending", expiresAt: "2026-10-01T10:00:00Z",
            } });
        renderApproval();
        await waitFor(() => expect(verifyDeviceRequest).toHaveBeenCalledTimes(1));

        mockCurrentUser = newUser;
        await act(async () => mockAuthCallback?.(newUser));
        expect(await screen.findByText("Current device")).toBeTruthy();
        await act(async () => resolveOld({ success: true, data: {
            deviceName: "Old device", userCode: "000042", state: "pending", expiresAt: "2026-10-01T10:00:00Z",
        } }));

        expect(screen.queryByText("Old device")).toBeNull();
        expect(screen.getByText("new@example.com")).toBeTruthy();
    });

    it("ignores a verification response after sign-out", async () => {
        const { verifyDeviceRequest } = require("../../helpers/deviceAuthHelper");
        let resolveVerification!: (result: unknown) => void;
        verifyDeviceRequest.mockReturnValueOnce(new Promise(resolve => { resolveVerification = resolve; }));
        renderApproval();
        await waitFor(() => expect(verifyDeviceRequest).toHaveBeenCalledTimes(1));

        mockCurrentUser = null;
        await act(async () => mockAuthCallback?.(null));
        await act(async () => resolveVerification({ success: true, data: {
            deviceName: "Stale device", userCode: "000042", state: "pending", expiresAt: "2026-10-01T10:00:00Z",
        } }));

        expect(screen.queryByText("Stale device")).toBeNull();
        expect(mockNavigate).toHaveBeenCalledWith("/login", {
            replace: true,
            state: { returnTo: "/auth/code?deviceRequestId=abcdef0123456789abcdef0123456789&userCode=000042" },
        });
    });

    it("ignores a late approval response after the account changes", async () => {
        const { decideDeviceRequest, verifyDeviceRequest } = require("../../helpers/deviceAuthHelper");
        let resolveDecision!: (result: unknown) => void;
        const pendingDecision = new Promise(resolve => { resolveDecision = resolve; });
        decideDeviceRequest.mockReturnValueOnce(pendingDecision);
        const newUser = { uid: "account-2", email: "new@example.com", getIdToken: jest.fn().mockResolvedValue("new-token") };
        verifyDeviceRequest.mockResolvedValue({ success: true, data: {
            deviceName: "Current device", userCode: "000042", state: "pending", expiresAt: "2026-10-01T10:00:00Z",
        } });
        renderApproval();
        await screen.findByText("Current device");
        fireEvent.click(screen.getByRole("button", { name: "Approve device" }));
        await waitFor(() => expect(decideDeviceRequest).toHaveBeenCalledTimes(1));

        mockCurrentUser = newUser;
        await act(async () => mockAuthCallback?.(newUser));
        await screen.findByText("Current device");
        await act(async () => resolveDecision({ success: true, data: { state: "approved" } }));

        expect(screen.getByText("new@example.com")).toBeTruthy();
        expect(screen.queryByText("Device approved. You can return to it now.")).toBeNull();
    });

    it("ignores an approval response after unmount", async () => {
        const { decideDeviceRequest } = require("../../helpers/deviceAuthHelper");
        let resolveDecision!: (result: unknown) => void;
        decideDeviceRequest.mockReturnValueOnce(new Promise(resolve => { resolveDecision = resolve; }));
        const rendered = renderApproval();
        await screen.findByText("Unverified laptop");
        fireEvent.click(screen.getByRole("button", { name: "Approve device" }));
        await waitFor(() => expect(decideDeviceRequest).toHaveBeenCalledTimes(1));
        rendered.unmount();

        await act(async () => resolveDecision({ success: true, data: { state: "approved" } }));
        expect(mockNavigate).not.toHaveBeenCalled();
    });
});
