import React, { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import type { User } from "firebase/auth";
import { Eye, EyeOff } from "lucide-react";
import { auth, onAuthStateChanged, sendPasswordResetEmail, signInWithApple, signInWithEmailAndPassword, signInWithGoogle, signOut } from "../firebase";
import { checkAccountAccess } from "../helpers/APIHelper";
import packageJson from "../../package.json";
import { AppNav } from "../components/AppNav";
import { DisabledAccountMessage, NoRegionsMessage, SUPPORT_EMAIL } from "../components/AccessMessages";
import { fetchOciRegions, useOciRegionsStore } from "../stores/ociRegionsStore";

const Login: React.FC = () => {
    const navigate = useNavigate();
    
    const [email, setEmail] = useState("");
    const [password, setPassword] = useState("");
    const [showPassword, setShowPassword] = useState(false);
    const [error, setError] = useState<React.ReactNode>();
    const [success, setSuccess] = useState<string | null>();
    const [signingIn, setSigningIn] = useState(false);
    const mountedRef = useRef(false);
    // Single source of truth for the manual-attempt/auth-observer coordination
    // below. Invariants:
    // - manualSignIn is true only while a handleLogin/Google/Apple attempt is
    //   in flight, end to end (including the awaited navigateProvisionedUser).
    // - manualAttempt is bumped once per attempt start; a captured attempt id
    //   is "current" only while it still equals this value.
    // - manualUserUid is null until the in-flight attempt's sign-in promise
    //   resolves, then holds that attempt's uid for the rest of the attempt.
    // - manualStartGeneration snapshots authGeneration when the attempt began,
    //   so the attempt can detect an auth-state change that raced ahead of it.
    // - manualInvalidated is set once a competing auth-state change (the
    //   observer, or a same-flow uid mismatch) has invalidated the in-flight
    //   attempt; once set it stays set for that attempt.
    // - authGeneration is bumped on every onAuthStateChanged fire and once
    //   more on effect cleanup/unmount, so a stale observer closure can detect
    //   it has been superseded.
    // - authUid mirrors the uid most recently reported by onAuthStateChanged
    //   (null when signed out).
    // This is one stable ref object whose fields are mutated in place; it is
    // never replaced, so closures that captured the ref always observe the
    // latest values through attemptStateRef.current.
    const attemptStateRef = useRef({
        manualSignIn: false,
        manualAttempt: 0,
        manualUserUid: null as string | null,
        manualStartGeneration: 0,
        manualInvalidated: false,
        authGeneration: 0,
        authUid: null as string | null,
    });

    const getAuthErrorCode = (err: unknown) => (
        err && typeof err === "object" && "code" in err
            ? (err as { code?: string }).code
            : null
    );

    const getDisabledAccountMessage = () => <DisabledAccountMessage />;

    const getNoRegionsMessage = () => <NoRegionsMessage />;

    const getAppleSignInError = (err: unknown) => {
        const code = err && typeof err === "object" && "code" in err
            ? (err as { code?: string }).code
            : null;

        if (code === "auth/popup-closed-by-user" || code === "auth/cancelled-popup-request") {
            return null;
        }
        if (code === "auth/unauthorized-domain") {
            return "This domain is not authorized for Apple sign-in.";
        }
        if (code === "auth/account-exists-with-different-credential") {
            return "An account already exists for this email. Sign in with a method you've already linked.";
        }
        if (code === "auth/user-disabled") {
            return getDisabledAccountMessage();
        }

        return "Unable to sign in with Apple.";
    };

    const getGoogleSignInError = (err: unknown) => {
        const code = err && typeof err === "object" && "code" in err
            ? (err as { code?: string }).code
            : null;

        if (code === "auth/popup-closed-by-user" || code === "auth/cancelled-popup-request") {
            return null;
        }
        if (code === "auth/unauthorized-domain") {
            return "This domain is not authorized for Google sign-in.";
        }
        if (code === "auth/account-exists-with-different-credential") {
            return "An account already exists for this email. Sign in with a method you've already linked.";
        }
        if (code === "auth/user-disabled") {
            return getDisabledAccountMessage();
        }

        return "Unable to sign in with Google.";
    };

    const navigateProvisionedUser = useCallback(async (
        user: User,
        showAccessError = false,
        isCurrent: () => boolean = () => true,
    ) => {
        try {
            const token = await user.getIdToken();
            if (!isCurrent()) return;

            // Verify apex account access before any regional capacity call. The
            // capacity endpoints disable and revoke unprovisioned users, which
            // would turn a later access check into a generic auth failure and
            // hide the real "not provisioned" reason. The apex check runs on the
            // still-valid token and returns the specific reason. Regions are
            // unused by the endpoint builder, so none are needed here.
            const access = await checkAccountAccess(token, null);
            if (!isCurrent()) return;
            if (!access.success) {
                if (!isCurrent()) return;
                await signOut(auth);
                if (!isCurrent()) return;
                if (showAccessError) {
                    setError(
                        access.errorCode === "USER_NOT_PROVISIONED"
                            ? access.error
                            : "Unable to verify account access. Please try again.",
                    );
                }
                return;
            }

            await fetchOciRegions(token, true);
            if (!isCurrent()) return;
            const { ociRegions, error: regionsError } = useOciRegionsStore.getState();

            if (regionsError) {
                throw new Error(regionsError);
            }

            if (!ociRegions?.length) {
                if (!isCurrent()) return;
                await signOut(auth);
                if (!isCurrent()) return;
                if (showAccessError) {
                    setError(getNoRegionsMessage());
                }
                return;
            }
        } catch {
            if (!isCurrent()) return;
            await signOut(auth);
            if (!isCurrent()) return;
            if (showAccessError) {
                setError("Unable to verify account access. Please try again.");
            }
            return;
        }

        if (isCurrent()) navigate("/home", { replace: true });
    }, [navigate]);

    const beginManualAttempt = () => {
        const attempt = ++attemptStateRef.current.manualAttempt;
        attemptStateRef.current.manualSignIn = true;
        attemptStateRef.current.manualUserUid = null;
        attemptStateRef.current.manualStartGeneration = attemptStateRef.current.authGeneration;
        attemptStateRef.current.manualInvalidated = false;
        return attempt;
    };

    const isCurrentManualAttempt = (attempt: number, uid: string) => (
        mountedRef.current
        && attemptStateRef.current.manualAttempt === attempt
        && !attemptStateRef.current.manualInvalidated
        && attemptStateRef.current.manualUserUid === uid
        && (attemptStateRef.current.authUid === null || attemptStateRef.current.authUid === uid)
        && (
            attemptStateRef.current.authGeneration === attemptStateRef.current.manualStartGeneration
            || attemptStateRef.current.authUid === uid
        )
    );

    const handleLogin = async (e: React.FormEvent) => {
        e.preventDefault();
        const attempt = beginManualAttempt();
        try {
            if (!email.includes('@') || !email.includes('.')) {
                if (mountedRef.current && attemptStateRef.current.manualAttempt === attempt) setError("Not a valid email.");
                return;
            }
            if (!password.length) {
                if (mountedRef.current && attemptStateRef.current.manualAttempt === attempt) setError("Password is required.");
                return;
            }

            setError(null);
            setSuccess(null);
            setSigningIn(true);
            const result = await signInWithEmailAndPassword(auth, email, password);
            attemptStateRef.current.manualUserUid = result.user.uid;
            if (attemptStateRef.current.authUid && attemptStateRef.current.authUid !== result.user.uid) {
                attemptStateRef.current.manualInvalidated = true;
            }
            const isCurrent = () => isCurrentManualAttempt(attempt, result.user.uid);
            await navigateProvisionedUser(result.user, true, isCurrent);
        } catch (err) {
            if (mountedRef.current && attemptStateRef.current.manualAttempt === attempt) {
                setError(getAuthErrorCode(err) === "auth/user-disabled" ? getDisabledAccountMessage() : "Invalid email or password.");
            }
        } finally {
            if (attemptStateRef.current.manualAttempt === attempt) {
                attemptStateRef.current.manualSignIn = false;
                if (mountedRef.current) setSigningIn(false);
            }
        }
    };

    const handleGoogleLogin = async () => {
        setError(null);
        setSuccess(null);
        const attempt = beginManualAttempt();
        setSigningIn(true);

        try {
            const result = await signInWithGoogle();
            attemptStateRef.current.manualUserUid = result.user.uid;
            if (attemptStateRef.current.authUid && attemptStateRef.current.authUid !== result.user.uid) {
                attemptStateRef.current.manualInvalidated = true;
            }
            const isCurrent = () => isCurrentManualAttempt(attempt, result.user.uid);
            await navigateProvisionedUser(result.user, true, isCurrent);
        } catch (err) {
            if (attemptStateRef.current.manualAttempt !== attempt || !mountedRef.current) return;
            const message = getGoogleSignInError(err);
            if (message) {
                setError(message);
            }
        } finally {
            if (attemptStateRef.current.manualAttempt === attempt) {
                attemptStateRef.current.manualSignIn = false;
                if (mountedRef.current) setSigningIn(false);
            }
        }
    };

    const handleAppleLogin = async () => {
        setError(null);
        setSuccess(null);
        const attempt = beginManualAttempt();
        setSigningIn(true);

        try {
            const result = await signInWithApple();
            attemptStateRef.current.manualUserUid = result.user.uid;
            if (attemptStateRef.current.authUid && attemptStateRef.current.authUid !== result.user.uid) {
                attemptStateRef.current.manualInvalidated = true;
            }
            const isCurrent = () => isCurrentManualAttempt(attempt, result.user.uid);
            await navigateProvisionedUser(result.user, true, isCurrent);
        } catch (err) {
            if (attemptStateRef.current.manualAttempt !== attempt || !mountedRef.current) return;
            const message = getAppleSignInError(err);
            if (message) {
                setError(message);
            }
        } finally {
            if (attemptStateRef.current.manualAttempt === attempt) {
                attemptStateRef.current.manualSignIn = false;
                if (mountedRef.current) setSigningIn(false);
            }
        }
    };

    const handlePasswordReset = async () => {
        setError(null);
        setSuccess(null);

        const trimmedEmail = email.trim();
        if (!trimmedEmail.includes('@') || !trimmedEmail.includes('.')) {
            setError("Enter your email first.");
            return;
        }

        const confirmed = window.confirm(`Send a password reset email to ${trimmedEmail}?`);
        if (!confirmed) {
            return;
        }

        try {
            await sendPasswordResetEmail(auth, trimmedEmail);
            setSuccess("Password reset email sent.");
        } catch (err) {
            setError("Unable to send password reset email.");
        }
    };

    useEffect(() => {
        mountedRef.current = true;
        const unsubscribe = onAuthStateChanged(auth, (user) => {
            const uid = user?.uid || null;
            const authGeneration = ++attemptStateRef.current.authGeneration;
            attemptStateRef.current.authUid = uid;
            // Only checkable once the manual attempt knows its own uid. Before the
            // sign-in promise resolves, an observer fire is indistinguishable from
            // this attempt's own completion, so a competing switch in that window is
            // caught instead when the promise resolves (see handleLogin).
            if (attemptStateRef.current.manualSignIn && attemptStateRef.current.manualUserUid && uid !== attemptStateRef.current.manualUserUid) {
                attemptStateRef.current.manualInvalidated = true;
            }
            const isCurrentObserver = () => (
                mountedRef.current
                && attemptStateRef.current.authGeneration === authGeneration
                && attemptStateRef.current.authUid === uid
            );
            const fetchUserData = async () => {
                if (user && isCurrentObserver() && !attemptStateRef.current.manualSignIn) {
                    setSigningIn(true);
                    try {
                        await navigateProvisionedUser(user, true, isCurrentObserver);
                    } finally {
                        if (isCurrentObserver()) setSigningIn(false);
                    }
                }
            };
            void fetchUserData();
        });
        const stateAtCleanup = attemptStateRef;
        return () => {
            mountedRef.current = false;
            ++stateAtCleanup.current.authGeneration;
            unsubscribe();
        };
    }, [navigateProvisionedUser]);

    return (
        <div className="flex min-h-screen flex-col items-center justify-center bg-page px-4" aria-busy={signingIn}>
        <AppNav showAbout />

        {/* {error && <p>{error}</p>} */}
        {/* Error or Success */}
        {(error || success) && (
            <div className="fixed top-20 w-full flex justify-center z-50">
            <div className={`px-6 py-3 rounded-xl shadow-md w-full max-w-md flex justify-between items-center ${
                error ? "bg-danger text-white" : "bg-success text-white"
            }`}>
                <span className="text-sm">
                {error || success}
                </span>
                <button
                className="ml-4 font-bold hover:text-white/70 transition"
                onClick={() => {
                    setError(null);
                    setSuccess(null);
                }}
                >
                ✕
                </button>
            </div>
            </div>
        )}

        {/* Login Form */}
        <div className="bg-card p-6 md:p-8 rounded-2xl shadow-lg w-full max-w-sm mt-10">
            <h2 className="text-2xl font-semibold text-center mb-6">Login</h2>

            <form onSubmit={handleLogin}>
                <div className="mb-4">
                    <label className="block text-content-secondary font-medium mb-2">Email</label>
                    <input
                        id="email"
                        name="email"
                        type="email"
                        autoComplete="username"
                        className="w-full p-3 border border-edge bg-inset text-content rounded-lg focus:ring-2 focus:ring-focus focus:outline-none"
                        placeholder="Enter your email"
                        value={email}
                        onChange={(x) => setEmail(x.target.value)}
                    />
                </div>

                <div className="mb-4">
                    <label className="block text-content-secondary font-medium mb-2">Password</label>
                    <div className="relative">
                        <input
                            id="password"
                            name="password"
                            type={showPassword ? "text" : "password"}
                            autoComplete="current-password"
                            className="w-full rounded-lg border border-edge bg-inset p-3 pr-12 text-content focus:outline-none focus:ring-2 focus:ring-focus"
                            placeholder="Enter your password"
                            value={password}
                            onChange={(x) => setPassword(x.target.value)}
                        />
                        <button
                            type="button"
                            aria-label={showPassword ? "Hide password" : "Show password"}
                            onClick={() => setShowPassword((visible) => !visible)}
                            className="absolute inset-y-0 right-0 flex w-12 items-center justify-center text-content-muted transition hover:text-content-secondary"
                        >
                            {showPassword ? <EyeOff size={20} aria-hidden="true" /> : <Eye size={20} aria-hidden="true" />}
                        </button>
                    </div>
                </div>

                <button
                    type="submit"
                    disabled={signingIn}
                    className={`w-full rounded-lg p-3 text-white transition ${
                        signingIn
                            ? "cursor-not-allowed bg-disabled text-content-disabled"
                            : "cursor-pointer bg-primary hover:bg-primary-hover"
                    }`}
                >
                    {signingIn ? "Signing in..." : "Login"}
                </button>

                <div className="my-4 flex items-center gap-3 text-xs text-content-faint">
                    <div className="h-px flex-1 bg-edge-subtle"></div>
                    <span>or</span>
                    <div className="h-px flex-1 bg-edge-subtle"></div>
                </div>

                <button
                    type="button"
                    onClick={handleAppleLogin}
                    disabled={signingIn}
                    className={`mt-3 flex w-full items-center justify-center gap-3 rounded-lg border border-edge bg-inset p-3 text-content transition ${
                        signingIn ? "cursor-not-allowed opacity-60" : "cursor-pointer hover:bg-inset-strong"
                    }`}
                >
                    <svg viewBox="0 0 384 512" aria-hidden="true" className="h-[18px] w-[18px] shrink-0 fill-current">
                        <path d="M318.7 268.7c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141.2 4 184.8 4 273.5q0 39.3 14.4 81.2c12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.7 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-91.9zm-56.6-164.2c27.3-32.4 24.8-61.9 24-72.5-24.1 1.4-52 16.4-67.9 34.9-17.5 19.8-27.8 44.3-25.6 71.9 26.1 2 49.9-11.4 69.5-34.3z" />
                    </svg>
                    {signingIn ? "Signing in..." : "Sign in with Apple"}
                </button>

                <button
                    type="button"
                    onClick={handleGoogleLogin}
                    disabled={signingIn}
                    className={`mt-3 flex w-full items-center justify-center gap-3 rounded-lg border border-edge bg-inset p-3 text-content transition ${
                        signingIn ? "cursor-not-allowed opacity-60" : "cursor-pointer hover:bg-inset-strong"
                    }`}
                >
                    <svg viewBox="0 0 48 48" aria-hidden="true" className="h-[18px] w-[18px] shrink-0">
                        <path fill="#4285F4" d="M45.12 24.5c0-1.56-.14-3.06-.4-4.5H24v8.51h11.84c-.51 2.75-2.06 5.08-4.39 6.64v5.52h7.11c4.16-3.83 6.56-9.47 6.56-16.17z" />
                        <path fill="#34A853" d="M24 46c5.94 0 10.92-1.97 14.56-5.33l-7.11-5.52c-1.97 1.32-4.49 2.1-7.45 2.1-5.73 0-10.58-3.87-12.31-9.07H4.34v5.7C7.96 41.07 15.4 46 24 46z" />
                        <path fill="#FBBC05" d="M11.69 28.18c-.44-1.32-.69-2.73-.69-4.18s.25-2.86.69-4.18v-5.7H4.34C2.85 17.09 2 20.45 2 24s.85 6.91 2.34 9.88l7.35-5.7z" />
                        <path fill="#EA4335" d="M24 10.75c3.23 0 6.13 1.11 8.41 3.29l6.31-6.31C34.91 4.18 29.93 2 24 2 15.4 2 7.96 6.93 4.34 14.12l7.35 5.7c1.73-5.2 6.58-9.07 12.31-9.07z" />
                    </svg>
                    {signingIn ? "Signing in..." : "Sign in with Google"}
                </button>

                <div className="ps-2 mt-2 text-xs">
                    <button
                    type="button"
                    onClick={handlePasswordReset}
                    className="cursor-pointer text-accent underline hover:text-accent-strong"
                    >
                    Reset password
                    </button>
                    <span> | </span>
                    <a
                    href={`mailto:${SUPPORT_EMAIL}`}
                    className="text-accent underline hover:text-accent-strong"
                    >
                    Email me for a test account
                    </a>
                    <span> | </span>
                    <button
                    type="button"
                    onClick={() => navigate("/privacy")}
                    className="cursor-pointer text-accent underline hover:text-accent-strong"
                    >
                    Privacy
                    </button>
                </div>
            </form>
        </div>
        <span className="fixed bottom-2 right-3 text-xs text-content-faint">
            v{packageJson?.version || '0.0.0'}
        </span>
        {signingIn && (
            <div className="fixed inset-0 z-40 flex items-center justify-center bg-black/50" role="status" aria-live="polite">
                <div className="flex items-center gap-3 rounded-xl border border-edge-subtle bg-card px-5 py-4 text-sm text-content shadow-xl">
                    <span className="h-5 w-5 animate-spin rounded-full border-2 border-edge-subtle border-t-primary" aria-hidden="true" />
                    Signing in...
                </div>
            </div>
        )}
        </div>
    );
};

export default Login;
