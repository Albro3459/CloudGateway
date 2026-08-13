import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";

const mockNavigate = jest.fn();

jest.mock("react-router-dom", () => ({
    useNavigate: () => mockNavigate,
}), { virtual: true });

jest.mock("../../firebase", () => ({
    auth: {},
    onAuthStateChanged: jest.fn((_auth, callback) => {
        setTimeout(() => callback(null), 0);
        return () => undefined;
    }),
    sendPasswordResetEmail: jest.fn(),
    signInWithEmailAndPassword: jest.fn(),
    signInWithGoogle: jest.fn(),
    signInWithApple: jest.fn(),
    signOut: jest.fn().mockResolvedValue(undefined),
}));

jest.mock("../../helpers/APIHelper", () => ({
    checkAccountAccess: jest.fn(),
}));

jest.mock("../../stores/ociRegionsStore", () => {
    const mockUseOciRegionsStore = Object.assign(jest.fn(), {
        getState: jest.fn(() => ({
            ociRegions: [{ regionId: "us-sanjose-1", enabled: true }],
            error: null,
        })),
    });

    return {
        fetchOciRegions: jest.fn().mockResolvedValue(undefined),
        useOciRegionsStore: mockUseOciRegionsStore,
    };
});

describe("Login", () => {
    const user = {
        uid: "user-old",
        getIdToken: jest.fn().mockResolvedValue("firebase-token"),
    };
    let authCallback: ((user: unknown) => void) | undefined;

    beforeEach(() => {
        jest.clearAllMocks();
        user.getIdToken.mockResolvedValue("firebase-token");
        const { onAuthStateChanged, signInWithEmailAndPassword, signInWithGoogle, signInWithApple, signOut } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { fetchOciRegions, useOciRegionsStore } = require("../../stores/ociRegionsStore");
        onAuthStateChanged.mockImplementation((_auth: unknown, callback: (user: unknown) => void) => {
            authCallback = callback;
            return () => undefined;
        });
        signInWithEmailAndPassword.mockReset();
        signInWithGoogle.mockReset();
        signInWithApple.mockReset();
        signOut.mockReset().mockResolvedValue(undefined);
        checkAccountAccess.mockReset();
        fetchOciRegions.mockReset().mockResolvedValue(undefined);
        useOciRegionsStore.getState.mockReturnValue({
            ociRegions: [{ regionId: "us-sanjose-1", enabled: true }],
            error: null,
        });
    });

    it("ignores a stale provisioning result after a newer auth generation", async () => {
        const { signInWithEmailAndPassword, signOut } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        const newerUser = { uid: "user-new", getIdToken: jest.fn().mockResolvedValue("new-token") };
        let resolveAccess!: (value: { success: boolean; data?: unknown; error?: string }) => void;
        const pendingAccess = new Promise<{ success: boolean; data?: unknown; error?: string }>(resolve => {
            resolveAccess = resolve;
        });

        signInWithEmailAndPassword.mockResolvedValue({ user });
        checkAccountAccess.mockReturnValue(pendingAccess);

        render(<Login />);
        await act(async () => authCallback?.(null));
        fireEvent.change(screen.getByPlaceholderText("Enter your email"), {
            target: { value: "user@example.com" },
        });
        fireEvent.change(screen.getByPlaceholderText("Enter your password"), {
            target: { value: "Password1!" },
        });
        fireEvent.click(screen.getByRole("button", { name: "Login" }));
        await waitFor(() => expect(checkAccountAccess).toHaveBeenCalledWith("firebase-token", null));

        await act(async () => authCallback?.(newerUser));
        await act(async () => {
            resolveAccess({ success: false, error: "stale provisioning failure" });
            await pendingAccess;
        });

        expect(signOut).not.toHaveBeenCalled();
        expect(mockNavigate).not.toHaveBeenCalledWith("/home", { replace: true });
        expect(screen.queryByText("stale provisioning failure")).toBeNull();
    });

    it("keeps a manual sign-in alive when the auth observer repeats the same UID", async () => {
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { fetchOciRegions } = require("../../stores/ociRegionsStore");
        const { default: Login } = require("../Login");
        let resolveAccess!: (value: { success: boolean; data?: unknown; error?: string }) => void;
        const pendingAccess = new Promise<{ success: boolean; data?: unknown; error?: string }>(resolve => {
            resolveAccess = resolve;
        });
        signInWithEmailAndPassword.mockResolvedValue({ user });
        checkAccountAccess.mockReturnValue(pendingAccess);

        render(<Login />);
        fireEvent.change(screen.getByPlaceholderText("Enter your email"), {
            target: { value: "user@example.com" },
        });
        fireEvent.change(screen.getByPlaceholderText("Enter your password"), {
            target: { value: "Password1!" },
        });
        fireEvent.click(screen.getByRole("button", { name: "Login" }));
        await waitFor(() => expect(checkAccountAccess).toHaveBeenCalledWith("firebase-token", null));

        await act(async () => authCallback?.(user));
        await act(async () => {
            resolveAccess({ success: true, data: { userId: user.uid } });
            await pendingAccess;
        });

        await waitFor(() => {
            expect(fetchOciRegions).toHaveBeenCalledWith("firebase-token", true);
            expect(mockNavigate).toHaveBeenCalledWith("/home", { replace: true });
        });
    });

    it("checks backend access after Google sign-in before navigating home", async () => {
        const { signInWithGoogle } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { fetchOciRegions } = require("../../stores/ociRegionsStore");
        const { default: Login } = require("../Login");

        signInWithGoogle.mockResolvedValue({ user });
        checkAccountAccess.mockResolvedValue({
            success: true,
            data: { userId: "user-1", email: "user@example.com", role: "user" },
        });

        render(<Login />);

        fireEvent.click(screen.getByRole("button", { name: /Sign in with Google/ }));

        await waitFor(() => {
            expect(checkAccountAccess).toHaveBeenCalledWith("firebase-token", null);
            expect(fetchOciRegions).toHaveBeenCalledWith("firebase-token", true);
            expect(mockNavigate).toHaveBeenCalledWith("/home", { replace: true });
        });

        // The apex access check must run before any regional capacity fetch.
        expect(checkAccountAccess.mock.invocationCallOrder[0])
            .toBeLessThan(fetchOciRegions.mock.invocationCallOrder[0]);
    });

    it("shows a loading indicator through email sign-in and access checks", async () => {
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");

        let resolveSignIn: (value: { user: typeof user }) => void = () => undefined;
        signInWithEmailAndPassword.mockReturnValue(new Promise((resolve) => {
            resolveSignIn = resolve;
        }));
        checkAccountAccess.mockResolvedValue({
            success: true,
            data: { userId: "user-1", email: "user@example.com", role: "user" },
        });

        render(<Login />);

        fireEvent.change(screen.getByPlaceholderText("Enter your email"), {
            target: { value: "user@example.com" },
        });
        fireEvent.change(screen.getByPlaceholderText("Enter your password"), {
            target: { value: "Password1!" },
        });
        fireEvent.click(screen.getByRole("button", { name: "Login" }));

        expect(screen.getByRole("status").textContent).toContain("Signing in...");
        expect(screen.getAllByRole("button", { name: "Signing in..." })[0].hasAttribute("disabled")).toBe(true);

        resolveSignIn({ user });

        await waitFor(() => {
            expect(checkAccountAccess).toHaveBeenCalledWith("firebase-token", null);
            expect(mockNavigate).toHaveBeenCalledWith("/home", { replace: true });
        });
        expect(screen.queryByRole("status")).toBeNull();
    });

    it("signs out and shows the backend message when access is not provisioned", async () => {
        const { signInWithGoogle, signOut } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { fetchOciRegions } = require("../../stores/ociRegionsStore");
        const { default: Login } = require("../Login");

        const message = "Your account does not have access to CloudGateway. Your account has been disabled until an admin grants access.";
        signInWithGoogle.mockResolvedValue({ user });
        checkAccountAccess.mockResolvedValue({
            success: false,
            errorCode: "USER_NOT_PROVISIONED",
            error: message,
            status: 403,
        });

        render(<Login />);

        fireEvent.click(screen.getByRole("button", { name: /Sign in with Google/ }));

        await waitFor(() => {
            expect(signOut).toHaveBeenCalled();
            expect(screen.getByText(message)).toBeTruthy();
            expect(mockNavigate).not.toHaveBeenCalledWith("/home", { replace: true });
        });

        // An unprovisioned user is rejected before any capacity call, which is
        // what keeps the specific message from degrading to a generic failure.
        expect(fetchOciRegions).not.toHaveBeenCalled();
    });

    it("signs out and shows a region message when no regions are available", async () => {
        const { signInWithGoogle, signOut } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { useOciRegionsStore } = require("../../stores/ociRegionsStore");
        const { default: Login } = require("../Login");

        signInWithGoogle.mockResolvedValue({ user });
        checkAccountAccess.mockResolvedValue({
            success: true,
            data: { userId: "user-1", email: "user@example.com", role: "user" },
        });
        useOciRegionsStore.getState.mockReturnValue({
            ociRegions: [],
            error: null,
        });

        render(<Login />);

        fireEvent.click(screen.getByRole("button", { name: /Sign in with Google/ }));

        await waitFor(() => {
            expect(signOut).toHaveBeenCalled();
            expect(checkAccountAccess).toHaveBeenCalledWith("firebase-token", null);
            expect(screen.getByText(/No enabled regions are available\./)).toBeTruthy();
            expect(screen.getByRole("link", { name: "Contact an admin" }).getAttribute("href"))
                .toBe("mailto:Brodsky.Alex22@gmail.com");
            expect(mockNavigate).not.toHaveBeenCalledWith("/home", { replace: true });
        });
    });

    it("checks backend access after Apple sign-in before navigating home", async () => {
        const { signInWithApple } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { fetchOciRegions } = require("../../stores/ociRegionsStore");
        const { default: Login } = require("../Login");

        signInWithApple.mockResolvedValue({ user });
        checkAccountAccess.mockResolvedValue({
            success: true,
            data: { userId: "user-1", email: "user@example.com", role: "user" },
        });

        render(<Login />);

        fireEvent.click(screen.getByRole("button", { name: /Sign in with Apple/ }));

        await waitFor(() => {
            expect(checkAccountAccess).toHaveBeenCalledWith("firebase-token", null);
            expect(fetchOciRegions).toHaveBeenCalledWith("firebase-token", true);
            expect(mockNavigate).toHaveBeenCalledWith("/home", { replace: true });
        });

        expect(checkAccountAccess.mock.invocationCallOrder[0])
            .toBeLessThan(fetchOciRegions.mock.invocationCallOrder[0]);
    });

    it("signs out and shows the backend message when Apple access is not provisioned", async () => {
        const { signInWithApple, signOut } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");

        const message = "Your account does not have access to CloudGateway. Your account has been disabled until an admin grants access.";
        signInWithApple.mockResolvedValue({ user });
        checkAccountAccess.mockResolvedValue({
            success: false,
            errorCode: "USER_NOT_PROVISIONED",
            error: message,
            status: 403,
        });

        render(<Login />);

        fireEvent.click(screen.getByRole("button", { name: /Sign in with Apple/ }));

        await waitFor(() => {
            expect(signOut).toHaveBeenCalled();
            expect(screen.getByText(message)).toBeTruthy();
            expect(mockNavigate).not.toHaveBeenCalledWith("/home", { replace: true });
        });
    });

    it("stays silent when the Apple sign-in popup is closed by the user", async () => {
        const { signInWithApple } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");

        signInWithApple.mockRejectedValue({ code: "auth/popup-closed-by-user" });

        render(<Login />);

        fireEvent.click(screen.getByRole("button", { name: /Sign in with Apple/ }));

        await waitFor(() => {
            expect(signInWithApple).toHaveBeenCalled();
        });
        expect(checkAccountAccess).not.toHaveBeenCalled();
        expect(screen.queryByText(/Unable to sign in with Apple\./)).toBeNull();
        expect(mockNavigate).not.toHaveBeenCalledWith("/home", { replace: true });
    });

    it("shows an error when Apple sign-in fails unexpectedly", async () => {
        const { signInWithApple } = require("../../firebase");
        const { default: Login } = require("../Login");

        signInWithApple.mockRejectedValue({ code: "auth/internal-error" });

        render(<Login />);

        fireEvent.click(screen.getByRole("button", { name: /Sign in with Apple/ }));

        await waitFor(() => {
            expect(screen.getByText(/Unable to sign in with Apple\./)).toBeTruthy();
            expect(mockNavigate).not.toHaveBeenCalledWith("/home", { replace: true });
        });
    });

    it("shows a disabled-account message for Firebase disabled-user sign-in errors", async () => {
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { default: Login } = require("../Login");

        signInWithEmailAndPassword.mockRejectedValue({ code: "auth/user-disabled" });

        render(<Login />);

        fireEvent.change(screen.getByPlaceholderText("Enter your email"), {
            target: { value: "disabled@example.com" },
        });
        fireEvent.change(screen.getByPlaceholderText("Enter your password"), {
            target: { value: "Password1!" },
        });
        fireEvent.click(screen.getByRole("button", { name: "Login" }));

        await waitFor(() => {
            expect(screen.getByText(/Your account is disabled\./)).toBeTruthy();
            expect(screen.getByRole("link", { name: "Contact an admin" }).getAttribute("href"))
                .toBe("mailto:Brodsky.Alex22@gmail.com");
        });
    });
});
