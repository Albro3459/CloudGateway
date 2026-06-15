import React, { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import type { User } from "firebase/auth";
import { auth, onAuthStateChanged, sendPasswordResetEmail, signInWithEmailAndPassword, signInWithGoogle, signOut } from "../firebase";
import { checkAccountAccess } from "../helpers/APIHelper";
import packageJson from "../../package.json";
import { ThemeToggle } from "../components/ThemeToggle";
import { NoRegionsMessage, SUPPORT_EMAIL } from "../components/NoRegionsMessage";
import { fetchOciRegions, useOciRegionsStore } from "../stores/ociRegionsStore";

const Login: React.FC = () => {
    const navigate = useNavigate();
    
    const [email, setEmail] = useState("");
    const [password, setPassword] = useState("");
    const [error, setError] = useState<React.ReactNode>();
    const [success, setSuccess] = useState<string | null>();
    const manualSignInRef = useRef(false);

    const getAuthErrorCode = (err: unknown) => (
        err && typeof err === "object" && "code" in err
            ? (err as { code?: string }).code
            : null
    );

    const getDisabledAccountMessage = () => (
        "Your account is disabled. Contact an admin for access to CloudGateway."
    );

    const getNoRegionsMessage = () => <NoRegionsMessage />;

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
            return "An account already exists for this email. Sign in with email and password first.";
        }
        if (code === "auth/user-disabled") {
            return getDisabledAccountMessage();
        }

        return "Unable to sign in with Google.";
    };

    const navigateProvisionedUser = useCallback(async (user: User, showAccessError = false) => {
        try {
            const token = await user.getIdToken();
            await fetchOciRegions(token, true);
            const { ociRegions, error: regionsError } = useOciRegionsStore.getState();

            if (regionsError) {
                throw new Error(regionsError);
            }

            if (!ociRegions?.length) {
                await signOut(auth);
                if (showAccessError) {
                    setError(getNoRegionsMessage());
                }
                return;
            }

            const access = await checkAccountAccess(token, ociRegions);
            if (!access.success) {
                await signOut(auth);
                if (showAccessError) {
                    setError(
                        access.errorCode === "USER_NOT_PROVISIONED"
                            ? access.error
                            : "Unable to verify account access. Please try again.",
                    );
                }
                return;
            }
        } catch {
            await signOut(auth);
            if (showAccessError) {
                setError("Unable to verify account access. Please try again.");
            }
            return;
        }

        navigate("/home", { replace: true });
    }, [navigate]);

    const handleLogin = async (e: React.FormEvent) => {
        e.preventDefault();
        manualSignInRef.current = true;
        try {
            if (!email.includes('@') || !email.includes('.')) {
                setError("Not a valid email.");
                return;
            }
            if (!password.trim().length) {
                setError("Password is required.");
                return;
            }

            const result = await signInWithEmailAndPassword(auth, email, password);
            await navigateProvisionedUser(result.user, true);
        } catch (err) {
            setError(getAuthErrorCode(err) === "auth/user-disabled" ? getDisabledAccountMessage() : "Invalid email or password.");
        } finally {
            manualSignInRef.current = false;
        }
    };

    const handleGoogleLogin = async () => {
        setError(null);
        setSuccess(null);
        manualSignInRef.current = true;

        try {
            const result = await signInWithGoogle();
            await navigateProvisionedUser(result.user, true);
        } catch (err) {
            const message = getGoogleSignInError(err);
            if (message) {
                setError(message);
            }
        } finally {
            manualSignInRef.current = false;
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
        let cancelled = false;
        const unsubscribe = onAuthStateChanged(auth, (user) => {
            const fetchUserData = async () => {
                if (user && !cancelled && !manualSignInRef.current) {
                    await navigateProvisionedUser(user, true);
                }
            };
            fetchUserData();
        });
        return () => {
            cancelled = true;
            unsubscribe();
        };
    }, [navigateProvisionedUser]);

    return (
        <div className="flex flex-col items-center justify-center min-h-screen bg-page px-4">
        {/* Navbar */}
        <nav className="w-full bg-nav text-white p-4 shadow-md fixed top-0 left-0 flex justify-center items-center px-6">
            <button 
                onClick={() => navigate("/about", { replace: true })} 
                className="cursor-pointer bg-nav-btn text-accent hover:bg-nav-btn-hover px-4 py-2 rounded-lg transition absolute left-6"
            >
                About
            </button>
            <h1 className="text-xl font-semibold align-self-center">CloudGateway</h1>
            <div className="absolute right-6">
                <ThemeToggle />
            </div>
        </nav>

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
                    <input
                        id="password"
                        name="password"
                        type="password"
                        autoComplete="current-password"
                        className="w-full p-3 border border-edge bg-inset text-content rounded-lg focus:ring-2 focus:ring-focus focus:outline-none"
                        placeholder="Enter your password"
                        value={password}
                        onChange={(x) => setPassword(x.target.value)}
                    />
                </div>

                <button
                    type="submit"
                    className="cursor-pointer w-full bg-primary text-white p-3 rounded-lg hover:bg-primary-hover transition"
                >
                    Login
                </button>

                <div className="my-4 flex items-center gap-3 text-xs text-content-faint">
                    <div className="h-px flex-1 bg-edge-subtle"></div>
                    <span>or</span>
                    <div className="h-px flex-1 bg-edge-subtle"></div>
                </div>

                <button
                    type="button"
                    onClick={handleGoogleLogin}
                    className="flex w-full cursor-pointer items-center justify-center gap-3 rounded-lg border border-edge bg-inset p-3 text-content transition hover:bg-inset-strong"
                >
                    <span className="text-lg font-semibold text-accent">G</span>
                    Continue with Google
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
                </div>
            </form>
        </div>
        <span className="fixed bottom-2 right-3 text-xs text-content-faint">
            v{packageJson?.version || '0.0.0'}
        </span>
        </div>
    );
};

export default Login;
