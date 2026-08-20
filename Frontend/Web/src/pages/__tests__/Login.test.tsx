import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";

const mockNavigate = jest.fn();

jest.mock("react-router-dom", () => ({
    useNavigate: () => mockNavigate,
}), { virtual: true });

jest.mock("../../firebase", () => ({
    // Firebase updates auth.currentUser before a sign-in promise resolves and
    // before an observer callback fires; the manual-attempt completion check
    // reads it as the authority, so the mock has to model it.
    auth: { currentUser: null as unknown },
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

    const setCurrentUser = (signedInUser: unknown) => {
        const { auth } = require("../../firebase");
        auth.currentUser = signedInUser;
    };

    // A resolving provider promise that moves Firebase's current user with it.
    const signInResolvingAs = (signedInUser: unknown) => async () => {
        setCurrentUser(signedInUser);
        return { user: signedInUser };
    };

    const emitAuth = async (signedInUser: unknown) => {
        setCurrentUser(signedInUser);
        await act(async () => authCallback?.(signedInUser));
    };

    const homeNavigations = () => mockNavigate.mock.calls.filter(call => call[0] === "/home");

    beforeEach(() => {
        jest.clearAllMocks();
        setCurrentUser(null);
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

        signInWithEmailAndPassword.mockImplementation(signInResolvingAs(user));
        checkAccountAccess.mockReturnValue(pendingAccess);

        render(<Login />);
        await emitAuth(null);
        fireEvent.change(screen.getByPlaceholderText("Enter your email"), {
            target: { value: "user@example.com" },
        });
        fireEvent.change(screen.getByPlaceholderText("Enter your password"), {
            target: { value: "Password1!" },
        });
        fireEvent.click(screen.getByRole("button", { name: "Login" }));
        await waitFor(() => expect(checkAccountAccess).toHaveBeenCalledWith("firebase-token", null));

        await emitAuth(newerUser);
        await act(async () => {
            resolveAccess({ success: false, error: "stale provisioning failure" });
            await pendingAccess;
        });

        expect(signOut).not.toHaveBeenCalled();
        expect(mockNavigate).not.toHaveBeenCalledWith("/home", { replace: true });
        expect(screen.queryByText("stale provisioning failure")).toBeNull();
    });

    it("navigates after an account switch when the observer fires before the sign-in promise resolves", async () => {
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { fetchOciRegions } = require("../../stores/ociRegionsStore");
        const { default: Login } = require("../Login");
        const newUser = { uid: "user-new", getIdToken: jest.fn().mockResolvedValue("new-token") };
        let resolveSignIn!: (value: { user: typeof newUser }) => void;
        const pendingSignIn = new Promise<{ user: typeof newUser }>(resolve => {
            resolveSignIn = resolve;
        });
        signInWithEmailAndPassword.mockReturnValue(pendingSignIn);
        // The stale session's own auto-navigate fetch (triggered by the
        // observer callback below) must resolve and clear signingIn without
        // navigating, so it doesn't leave the Login button disabled or race
        // the manual attempt's own access check.
        checkAccountAccess.mockImplementation((token: string) => (
            token === "new-token"
                ? Promise.resolve({ success: true, data: { userId: newUser.uid, email: "new@example.com", role: "user" } })
                : Promise.resolve({ success: false, error: "stale session check", errorCode: "OTHER" })
        ));

        render(<Login />);
        // An existing session is signed in before the manual attempt begins.
        await emitAuth(user);

        fireEvent.change(screen.getByPlaceholderText("Enter your email"), {
            target: { value: "new@example.com" },
        });
        fireEvent.change(screen.getByPlaceholderText("Enter your password"), {
            target: { value: "Password1!" },
        });
        fireEvent.click(screen.getByRole("button", { name: "Login" }));

        // The observer delivers the new account before the sign-in promise
        // resolves, which is the exact ordering finding 3 covers: the
        // observer's uid always differs from the uid signed in before the
        // attempt began, for any legitimate account switch.
        await emitAuth(newUser);
        await act(async () => {
            setCurrentUser(newUser);
            resolveSignIn({ user: newUser });
            await pendingSignIn;
        });

        await waitFor(() => {
            expect(fetchOciRegions).toHaveBeenCalledWith("new-token", true);
            expect(mockNavigate).toHaveBeenCalledWith("/home", { replace: true });
        });
    });

    const fillCredentials = (email = "user@example.com") => {
        fireEvent.change(screen.getByPlaceholderText("Enter your email"), { target: { value: email } });
        fireEvent.change(screen.getByPlaceholderText("Enter your password"), { target: { value: "Password1!" } });
    };

    it("navigates a completed sign-in that an unrelated cross-tab auth event raced past", async () => {
        // A cross-tab event moves the observer's snapshot to another account
        // while this tab's sign-in promise is still pending, then Firebase's
        // current user is this attempt's user again by the time it resolves.
        // Rejecting on the stale snapshot stranded the sign-in: the matching
        // observer callback was already consumed, so nothing navigated.
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        const otherTabUser = { uid: "user-other-tab", getIdToken: jest.fn().mockResolvedValue("other-tab-token") };
        let resolveSignIn!: (value: { user: typeof user }) => void;
        const pendingSignIn = new Promise<{ user: typeof user }>(resolve => {
            resolveSignIn = resolve;
        });
        signInWithEmailAndPassword.mockReturnValue(pendingSignIn);
        checkAccountAccess.mockResolvedValue({
            success: true,
            data: { userId: user.uid, email: "user@example.com", role: "user" },
        });

        render(<Login />);
        await emitAuth(null);
        fillCredentials();
        fireEvent.click(screen.getByRole("button", { name: "Login" }));
        await waitFor(() => expect(signInWithEmailAndPassword).toHaveBeenCalled());

        await emitAuth(otherTabUser);
        setCurrentUser(user);
        await act(async () => {
            resolveSignIn({ user });
            await pendingSignIn;
        });

        await waitFor(() => expect(homeNavigations()).toHaveLength(1));
    });

    it("navigates a completed Google sign-in past the same cross-tab race", async () => {
        // Password, Google, and Apple share one completion path; this pins that
        // the provider buttons are not a separate code path with its own rule.
        const { signInWithGoogle } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        const otherTabUser = { uid: "user-other-tab", getIdToken: jest.fn().mockResolvedValue("other-tab-token") };
        let resolveSignIn!: (value: { user: typeof user }) => void;
        const pendingSignIn = new Promise<{ user: typeof user }>(resolve => {
            resolveSignIn = resolve;
        });
        signInWithGoogle.mockReturnValue(pendingSignIn);
        checkAccountAccess.mockResolvedValue({
            success: true,
            data: { userId: user.uid, email: "user@example.com", role: "user" },
        });

        render(<Login />);
        await emitAuth(null);
        fireEvent.click(screen.getByRole("button", { name: /Sign in with Google/ }));
        await waitFor(() => expect(signInWithGoogle).toHaveBeenCalled());

        await emitAuth(otherTabUser);
        setCurrentUser(user);
        await act(async () => {
            resolveSignIn({ user });
            await pendingSignIn;
        });

        await waitFor(() => expect(homeNavigations()).toHaveLength(1));
    });

    it("does not navigate when Firebase switches accounts after the sign-in resolves", async () => {
        // The mirror of the test above: a real later identity change must still
        // cancel the attempt, not merely a stale snapshot.
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        const otherUser = { uid: "user-new", getIdToken: jest.fn().mockResolvedValue("new-token") };
        let resolveAccess!: (value: { success: boolean; data?: unknown }) => void;
        const pendingAccess = new Promise<{ success: boolean; data?: unknown }>(resolve => {
            resolveAccess = resolve;
        });
        signInWithEmailAndPassword.mockImplementation(signInResolvingAs(user));
        checkAccountAccess.mockReturnValue(pendingAccess);

        render(<Login />);
        await emitAuth(null);
        fillCredentials();
        fireEvent.click(screen.getByRole("button", { name: "Login" }));
        await waitFor(() => expect(checkAccountAccess).toHaveBeenCalledWith("firebase-token", null));

        setCurrentUser(otherUser);
        await act(async () => {
            resolveAccess({ success: true, data: { userId: user.uid } });
            await pendingAccess;
        });

        expect(homeNavigations()).toHaveLength(0);
    });

    it("does not navigate when the session signs out mid-provisioning", async () => {
        const { signInWithEmailAndPassword, signOut } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        let resolveAccess!: (value: { success: boolean; data?: unknown }) => void;
        const pendingAccess = new Promise<{ success: boolean; data?: unknown }>(resolve => {
            resolveAccess = resolve;
        });
        signInWithEmailAndPassword.mockImplementation(signInResolvingAs(user));
        checkAccountAccess.mockReturnValue(pendingAccess);

        render(<Login />);
        await emitAuth(null);
        fillCredentials();
        fireEvent.click(screen.getByRole("button", { name: "Login" }));
        await waitFor(() => expect(checkAccountAccess).toHaveBeenCalledWith("firebase-token", null));

        await emitAuth(null);
        await act(async () => {
            resolveAccess({ success: true, data: { userId: user.uid } });
            await pendingAccess;
        });

        expect(homeNavigations()).toHaveLength(0);
        expect(signOut).not.toHaveBeenCalled();
    });

    it("does not navigate after the component unmounts mid-provisioning", async () => {
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        let resolveAccess!: (value: { success: boolean; data?: unknown }) => void;
        const pendingAccess = new Promise<{ success: boolean; data?: unknown }>(resolve => {
            resolveAccess = resolve;
        });
        signInWithEmailAndPassword.mockImplementation(signInResolvingAs(user));
        checkAccountAccess.mockReturnValue(pendingAccess);

        const { unmount } = render(<Login />);
        await emitAuth(null);
        fillCredentials();
        fireEvent.click(screen.getByRole("button", { name: "Login" }));
        await waitFor(() => expect(checkAccountAccess).toHaveBeenCalledWith("firebase-token", null));

        unmount();
        await act(async () => {
            resolveAccess({ success: true, data: { userId: user.uid } });
            await pendingAccess;
        });

        expect(homeNavigations()).toHaveLength(0);
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
        signInWithEmailAndPassword.mockImplementation(signInResolvingAs(user));
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

        await emitAuth(user);
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

        signInWithGoogle.mockImplementation(signInResolvingAs(user));
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

        setCurrentUser(user);
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
        signInWithGoogle.mockImplementation(signInResolvingAs(user));
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

        signInWithGoogle.mockImplementation(signInResolvingAs(user));
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

        signInWithApple.mockImplementation(signInResolvingAs(user));
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
        signInWithApple.mockImplementation(signInResolvingAs(user));
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
