import { fireEvent, render, screen, waitFor } from "@testing-library/react";

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
        getIdToken: jest.fn().mockResolvedValue("firebase-token"),
    };

    beforeEach(() => {
        jest.clearAllMocks();
        user.getIdToken.mockResolvedValue("firebase-token");
        const { onAuthStateChanged, signInWithEmailAndPassword, signInWithGoogle, signOut } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { fetchOciRegions, useOciRegionsStore } = require("../../stores/ociRegionsStore");
        onAuthStateChanged.mockImplementation((_auth: unknown, callback: (user: unknown) => void) => {
            setTimeout(() => callback(null), 0);
            return () => undefined;
        });
        signInWithEmailAndPassword.mockReset();
        signInWithGoogle.mockReset();
        signOut.mockReset().mockResolvedValue(undefined);
        checkAccountAccess.mockReset();
        fetchOciRegions.mockReset().mockResolvedValue(undefined);
        useOciRegionsStore.getState.mockReturnValue({
            ociRegions: [{ regionId: "us-sanjose-1", enabled: true }],
            error: null,
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

        fireEvent.click(screen.getByRole("button", { name: /Continue with Google/ }));

        await waitFor(() => {
            expect(fetchOciRegions).toHaveBeenCalledWith("firebase-token");
            expect(checkAccountAccess).toHaveBeenCalledWith(
                "firebase-token",
                [{ regionId: "us-sanjose-1", enabled: true }],
            );
            expect(mockNavigate).toHaveBeenCalledWith("/home", { replace: true });
        });
    });

    it("signs out and shows the backend message when access is not provisioned", async () => {
        const { signInWithGoogle, signOut } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
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

        fireEvent.click(screen.getByRole("button", { name: /Continue with Google/ }));

        await waitFor(() => {
            expect(signOut).toHaveBeenCalled();
            expect(screen.getByText(message)).toBeTruthy();
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
            expect(screen.getByText("Your account is disabled. Contact an admin for access to CloudGateway.")).toBeTruthy();
        });
    });
});
