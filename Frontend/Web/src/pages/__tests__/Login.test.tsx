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
        // Only the stale attempt's own check resolves. The newer account's
        // observer event is legitimately handed back once the stale attempt
        // retires, so its check is left pending to keep this test about the
        // stale result alone.
        checkAccountAccess.mockImplementation((token: string) => (
            token === "firebase-token" ? pendingAccess : new Promise(() => undefined)
        ));

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

    it("navigates a completed Apple sign-in past the same cross-tab race", async () => {
        // Same pin as the Google case, for the third provider on the shared path.
        const { signInWithApple } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        const otherTabUser = { uid: "user-other-tab", getIdToken: jest.fn().mockResolvedValue("other-tab-token") };
        let resolveSignIn!: (value: { user: typeof user }) => void;
        const pendingSignIn = new Promise<{ user: typeof user }>(resolve => {
            resolveSignIn = resolve;
        });
        signInWithApple.mockReturnValue(pendingSignIn);
        checkAccountAccess.mockResolvedValue({
            success: true,
            data: { userId: user.uid, email: "user@example.com", role: "user" },
        });

        render(<Login />);
        await emitAuth(null);
        fireEvent.click(screen.getByRole("button", { name: /Sign in with Apple/ }));
        await waitFor(() => expect(signInWithApple).toHaveBeenCalled());

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

    it("supersedes an in-flight manual attempt when a second one starts before it resolves", async () => {
        // A second manual attempt beginning while an earlier one is still
        // awaiting its provider promise must retire the earlier one outright:
        // it must not navigate, and its later settling (here a rejection) must
        // not overwrite the newer attempt's error or signingIn state.
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        let rejectFirst!: (reason: unknown) => void;
        const pendingFirst = new Promise<{ user: typeof user }>((_resolve, reject) => {
            rejectFirst = reject;
        });
        let resolveSecond!: (value: { user: typeof user }) => void;
        const pendingSecond = new Promise<{ user: typeof user }>(resolve => {
            resolveSecond = resolve;
        });
        signInWithEmailAndPassword.mockReturnValueOnce(pendingFirst).mockReturnValueOnce(pendingSecond);
        checkAccountAccess.mockResolvedValue({
            success: true,
            data: { userId: user.uid, email: "user@example.com", role: "user" },
        });

        const { container } = render(<Login />);
        await emitAuth(null);
        fillCredentials();
        const form = container.querySelector("form")!;

        // The Login button disables itself once the first attempt sets
        // signingIn, so a second click can't reach handleLogin; submitting the
        // form directly models the same overlapping-attempt race at the level
        // the ref state has to survive.
        fireEvent.submit(form);
        await waitFor(() => expect(signInWithEmailAndPassword).toHaveBeenCalledTimes(1));

        fireEvent.submit(form);
        await waitFor(() => expect(signInWithEmailAndPassword).toHaveBeenCalledTimes(2));

        setCurrentUser(user);
        await act(async () => {
            resolveSecond({ user });
            await pendingSecond;
        });
        await waitFor(() => expect(homeNavigations()).toHaveLength(1));

        await act(async () => {
            rejectFirst({ code: "auth/wrong-password" });
            await pendingFirst.catch(() => undefined);
        });

        expect(homeNavigations()).toHaveLength(1);
        expect(screen.queryByText("Invalid email or password.")).toBeNull();
    });

    it("does not let a superseded attempt's own completion strand the newer sign-in", async () => {
        // The older attempt resolves for a different account after the newer one
        // has started. Its uid and its invalidation belong to a retired attempt,
        // so writing them into the shared attempt state would reject the newer
        // sign-in that Firebase reports as current - the same stranding the
        // stale observer snapshot used to cause.
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        const staleUser = { uid: "user-stale", getIdToken: jest.fn().mockResolvedValue("stale-token") };
        let resolveFirst!: (value: { user: typeof staleUser }) => void;
        const pendingFirst = new Promise<{ user: typeof staleUser }>(resolve => {
            resolveFirst = resolve;
        });
        let resolveSecond!: (value: { user: typeof user }) => void;
        const pendingSecond = new Promise<{ user: typeof user }>(resolve => {
            resolveSecond = resolve;
        });
        signInWithEmailAndPassword.mockReturnValueOnce(pendingFirst).mockReturnValueOnce(pendingSecond);
        checkAccountAccess.mockResolvedValue({
            success: true,
            data: { userId: user.uid, email: "user@example.com", role: "user" },
        });

        const { container } = render(<Login />);
        await emitAuth(null);
        fillCredentials();
        const form = container.querySelector("form")!;

        fireEvent.submit(form);
        await waitFor(() => expect(signInWithEmailAndPassword).toHaveBeenCalledTimes(1));
        fireEvent.submit(form);
        await waitFor(() => expect(signInWithEmailAndPassword).toHaveBeenCalledTimes(2));

        // Firebase's current user is the newer attempt's account by the time the
        // retired attempt settles.
        setCurrentUser(user);
        await act(async () => {
            resolveFirst({ user: staleUser });
            await pendingFirst;
        });
        await act(async () => {
            resolveSecond({ user });
            await pendingSecond;
        });

        await waitFor(() => expect(homeNavigations()).toHaveLength(1));
        expect(checkAccountAccess).not.toHaveBeenCalledWith("stale-token", null);
    });

    // A manual attempt owns the session while it runs, so an observer event that
    // lands mid-attempt is deferred rather than acted on. These pin the handoff
    // back: the deferred event must be provisioned when the attempt retires
    // without having handled that account, and dropped in every other case.
    it("provisions an observer account deferred while a manual attempt was in flight, once that attempt fails", async () => {
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { fetchOciRegions } = require("../../stores/ociRegionsStore");
        const { default: Login } = require("../Login");
        const otherTabUser = { uid: "user-other-tab", getIdToken: jest.fn().mockResolvedValue("other-tab-token") };
        let rejectSignIn!: (reason: unknown) => void;
        const pendingSignIn = new Promise<{ user: typeof user }>((_resolve, reject) => {
            rejectSignIn = reject;
        });
        signInWithEmailAndPassword.mockReturnValue(pendingSignIn);
        checkAccountAccess.mockResolvedValue({
            success: true,
            data: { userId: otherTabUser.uid, email: "other@example.com", role: "user" },
        });

        render(<Login />);
        await emitAuth(null);
        fillCredentials();
        fireEvent.click(screen.getByRole("button", { name: "Login" }));
        await waitFor(() => expect(signInWithEmailAndPassword).toHaveBeenCalled());

        // Another tab signs in while this attempt still owns the session.
        await emitAuth(otherTabUser);
        expect(checkAccountAccess).not.toHaveBeenCalled();

        await act(async () => {
            rejectSignIn({ code: "auth/wrong-password" });
            await pendingSignIn.catch(() => undefined);
        });

        // The attempt is retired and Firebase still reports the observed
        // account, so that session is real and nothing else will provision it.
        await waitFor(() => expect(fetchOciRegions).toHaveBeenCalledWith("other-tab-token", true));
        await waitFor(() => expect(homeNavigations()).toHaveLength(1));
    });

    it("provisions the observed account when the manual attempt is refused because Firebase reports that account as current", async () => {
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
            data: { userId: otherTabUser.uid, email: "other@example.com", role: "user" },
        });

        render(<Login />);
        await emitAuth(null);
        fillCredentials();
        fireEvent.click(screen.getByRole("button", { name: "Login" }));
        await waitFor(() => expect(signInWithEmailAndPassword).toHaveBeenCalled());

        await emitAuth(otherTabUser);
        // This attempt's own user is no longer current, so it is correctly
        // refused - which is exactly when the deferred event has to take over.
        await act(async () => {
            resolveSignIn({ user });
            await pendingSignIn;
        });

        await waitFor(() => expect(homeNavigations()).toHaveLength(1));
        expect(checkAccountAccess).toHaveBeenCalledWith("other-tab-token", null);
        expect(checkAccountAccess).not.toHaveBeenCalledWith("firebase-token", null);
    });

    it("resumes only the newest deferred observer account", async () => {
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        const firstTabUser = { uid: "user-first-tab", getIdToken: jest.fn().mockResolvedValue("first-tab-token") };
        const secondTabUser = { uid: "user-second-tab", getIdToken: jest.fn().mockResolvedValue("second-tab-token") };
        let rejectSignIn!: (reason: unknown) => void;
        const pendingSignIn = new Promise<{ user: typeof user }>((_resolve, reject) => {
            rejectSignIn = reject;
        });
        signInWithEmailAndPassword.mockReturnValue(pendingSignIn);
        checkAccountAccess.mockResolvedValue({
            success: true,
            data: { userId: secondTabUser.uid, email: "second@example.com", role: "user" },
        });

        render(<Login />);
        await emitAuth(null);
        fillCredentials();
        fireEvent.click(screen.getByRole("button", { name: "Login" }));
        await waitFor(() => expect(signInWithEmailAndPassword).toHaveBeenCalled());

        // Two events land during the attempt; only the last one describes the
        // session that actually exists when the attempt retires.
        await emitAuth(firstTabUser);
        await emitAuth(secondTabUser);
        await act(async () => {
            rejectSignIn({ code: "auth/wrong-password" });
            await pendingSignIn.catch(() => undefined);
        });

        await waitFor(() => expect(checkAccountAccess).toHaveBeenCalledWith("second-tab-token", null));
        expect(checkAccountAccess).not.toHaveBeenCalledWith("first-tab-token", null);
        expect(homeNavigations()).toHaveLength(1);
    });

    it("does not resume a deferred observer account that signed out before the attempt retired", async () => {
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        const otherTabUser = { uid: "user-other-tab", getIdToken: jest.fn().mockResolvedValue("other-tab-token") };
        let rejectSignIn!: (reason: unknown) => void;
        const pendingSignIn = new Promise<{ user: typeof user }>((_resolve, reject) => {
            rejectSignIn = reject;
        });
        signInWithEmailAndPassword.mockReturnValue(pendingSignIn);
        checkAccountAccess.mockResolvedValue({ success: true, data: { userId: otherTabUser.uid } });

        render(<Login />);
        await emitAuth(null);
        fillCredentials();
        fireEvent.click(screen.getByRole("button", { name: "Login" }));
        await waitFor(() => expect(signInWithEmailAndPassword).toHaveBeenCalled());

        await emitAuth(otherTabUser);
        // The sign-out is itself the newest event, so it cancels the deferred
        // account rather than queueing behind it.
        await emitAuth(null);
        await act(async () => {
            rejectSignIn({ code: "auth/wrong-password" });
            await pendingSignIn.catch(() => undefined);
        });

        expect(checkAccountAccess).not.toHaveBeenCalled();
        expect(homeNavigations()).toHaveLength(0);
    });

    it("does not resume a deferred observer account after the component unmounts", async () => {
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        const otherTabUser = { uid: "user-other-tab", getIdToken: jest.fn().mockResolvedValue("other-tab-token") };
        let rejectSignIn!: (reason: unknown) => void;
        const pendingSignIn = new Promise<{ user: typeof user }>((_resolve, reject) => {
            rejectSignIn = reject;
        });
        signInWithEmailAndPassword.mockReturnValue(pendingSignIn);
        checkAccountAccess.mockResolvedValue({ success: true, data: { userId: otherTabUser.uid } });

        const { unmount } = render(<Login />);
        await emitAuth(null);
        fillCredentials();
        fireEvent.click(screen.getByRole("button", { name: "Login" }));
        await waitFor(() => expect(signInWithEmailAndPassword).toHaveBeenCalled());

        await emitAuth(otherTabUser);
        unmount();
        await act(async () => {
            rejectSignIn({ code: "auth/wrong-password" });
            await pendingSignIn.catch(() => undefined);
        });

        expect(checkAccountAccess).not.toHaveBeenCalled();
        expect(homeNavigations()).toHaveLength(0);
    });

    it("hands a deferred observer account back from a Google attempt too, not just the password path", async () => {
        // All three providers retire through the same tail, so a closed Google
        // popup leaves the observed session provisioned exactly like a failed
        // password attempt does.
        const { signInWithGoogle } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        const otherTabUser = { uid: "user-other-tab", getIdToken: jest.fn().mockResolvedValue("other-tab-token") };
        let rejectSignIn!: (reason: unknown) => void;
        const pendingSignIn = new Promise<{ user: typeof user }>((_resolve, reject) => {
            rejectSignIn = reject;
        });
        signInWithGoogle.mockReturnValue(pendingSignIn);
        checkAccountAccess.mockResolvedValue({
            success: true,
            data: { userId: otherTabUser.uid, email: "other@example.com", role: "user" },
        });

        render(<Login />);
        await emitAuth(null);
        fireEvent.click(screen.getByRole("button", { name: /Sign in with Google/ }));
        await waitFor(() => expect(signInWithGoogle).toHaveBeenCalled());

        await emitAuth(otherTabUser);
        await act(async () => {
            rejectSignIn({ code: "auth/popup-closed-by-user" });
            await pendingSignIn.catch(() => undefined);
        });

        await waitFor(() => expect(homeNavigations()).toHaveLength(1));
        expect(checkAccountAccess).toHaveBeenCalledWith("other-tab-token", null);
    });

    it("does not provision twice when the deferred event is the completed attempt's own account", async () => {
        // The observer's copy of a successful manual sign-in is not a second
        // session to provision: the attempt already ran the access checks and
        // navigated for that uid.
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
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

        await emitAuth(user);
        await act(async () => {
            resolveSignIn({ user });
            await pendingSignIn;
        });

        await waitFor(() => expect(homeNavigations()).toHaveLength(1));
        expect(checkAccountAccess).toHaveBeenCalledTimes(1);
    });

    it("does not show the sign-in error when a valid deferred account is about to take over", async () => {
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        const otherTabUser = { uid: "user-other-tab", getIdToken: jest.fn().mockResolvedValue("other-tab-token") };
        let rejectSignIn!: (reason: unknown) => void;
        const pendingSignIn = new Promise<{ user: typeof user }>((_resolve, reject) => {
            rejectSignIn = reject;
        });
        signInWithEmailAndPassword.mockReturnValue(pendingSignIn);
        checkAccountAccess.mockResolvedValue({
            success: true,
            data: { userId: otherTabUser.uid, email: "other@example.com", role: "user" },
        });

        render(<Login />);
        await emitAuth(null);
        fillCredentials();
        fireEvent.click(screen.getByRole("button", { name: "Login" }));
        await waitFor(() => expect(signInWithEmailAndPassword).toHaveBeenCalled());

        await emitAuth(otherTabUser);
        await act(async () => {
            rejectSignIn({ code: "auth/wrong-password" });
            await pendingSignIn.catch(() => undefined);
        });

        // The operator ends up on Home as the observed account, so flashing a
        // credential error for the attempt that lost the race is just noise.
        expect(screen.queryByText("Invalid email or password.")).toBeNull();
        await waitFor(() => expect(homeNavigations()).toHaveLength(1));
        expect(screen.queryByText("Invalid email or password.")).toBeNull();
    });

    it("still shows the sign-in error when no deferred account exists", async () => {
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { default: Login } = require("../Login");
        signInWithEmailAndPassword.mockRejectedValue({ code: "auth/wrong-password" });

        render(<Login />);
        await emitAuth(null);
        fillCredentials();
        fireEvent.click(screen.getByRole("button", { name: "Login" }));

        expect(await screen.findByText("Invalid email or password.")).toBeTruthy();
        expect(homeNavigations()).toHaveLength(0);
    });

    it("still shows the sign-in error when the deferred account is no longer current", async () => {
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        const otherTabUser = { uid: "user-other-tab", getIdToken: jest.fn().mockResolvedValue("other-tab-token") };
        const thirdUser = { uid: "user-third", getIdToken: jest.fn().mockResolvedValue("third-token") };
        let rejectSignIn!: (reason: unknown) => void;
        const pendingSignIn = new Promise<{ user: typeof user }>((_resolve, reject) => {
            rejectSignIn = reject;
        });
        signInWithEmailAndPassword.mockReturnValue(pendingSignIn);

        render(<Login />);
        await emitAuth(null);
        fillCredentials();
        fireEvent.click(screen.getByRole("button", { name: "Login" }));
        await waitFor(() => expect(signInWithEmailAndPassword).toHaveBeenCalled());

        await emitAuth(otherTabUser);
        // Firebase moves on before the deferred event can be acted on, so
        // nothing takes over and the failure is the real outcome.
        setCurrentUser(thirdUser);
        await act(async () => {
            rejectSignIn({ code: "auth/wrong-password" });
            await pendingSignIn.catch(() => undefined);
        });

        expect(await screen.findByText("Invalid email or password.")).toBeTruthy();
        expect(checkAccountAccess).not.toHaveBeenCalled();
        expect(homeNavigations()).toHaveLength(0);
    });

    it("still shows the sign-in error when the deferred account signed out", async () => {
        const { signInWithEmailAndPassword } = require("../../firebase");
        const { default: Login } = require("../Login");
        const otherTabUser = { uid: "user-other-tab", getIdToken: jest.fn().mockResolvedValue("other-tab-token") };
        let rejectSignIn!: (reason: unknown) => void;
        const pendingSignIn = new Promise<{ user: typeof user }>((_resolve, reject) => {
            rejectSignIn = reject;
        });
        signInWithEmailAndPassword.mockReturnValue(pendingSignIn);

        render(<Login />);
        await emitAuth(null);
        fillCredentials();
        fireEvent.click(screen.getByRole("button", { name: "Login" }));
        await waitFor(() => expect(signInWithEmailAndPassword).toHaveBeenCalled());

        await emitAuth(otherTabUser);
        await emitAuth(null);
        await act(async () => {
            rejectSignIn({ code: "auth/wrong-password" });
            await pendingSignIn.catch(() => undefined);
        });

        expect(await screen.findByText("Invalid email or password.")).toBeTruthy();
        expect(homeNavigations()).toHaveLength(0);
    });

    it("suppresses the Apple error the same way when a valid deferred account takes over", async () => {
        const { signInWithApple } = require("../../firebase");
        const { checkAccountAccess } = require("../../helpers/APIHelper");
        const { default: Login } = require("../Login");
        const otherTabUser = { uid: "user-other-tab", getIdToken: jest.fn().mockResolvedValue("other-tab-token") };
        let rejectSignIn!: (reason: unknown) => void;
        const pendingSignIn = new Promise<{ user: typeof user }>((_resolve, reject) => {
            rejectSignIn = reject;
        });
        signInWithApple.mockReturnValue(pendingSignIn);
        checkAccountAccess.mockResolvedValue({
            success: true,
            data: { userId: otherTabUser.uid, email: "other@example.com", role: "user" },
        });

        render(<Login />);
        await emitAuth(null);
        fireEvent.click(screen.getByRole("button", { name: /Sign in with Apple/ }));
        await waitFor(() => expect(signInWithApple).toHaveBeenCalled());

        await emitAuth(otherTabUser);
        await act(async () => {
            rejectSignIn({ code: "auth/internal-error" });
            await pendingSignIn.catch(() => undefined);
        });

        expect(screen.queryByText("Unable to sign in with Apple.")).toBeNull();
        await waitFor(() => expect(homeNavigations()).toHaveLength(1));
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
