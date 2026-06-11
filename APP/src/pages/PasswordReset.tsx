import React, { useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { confirmPasswordReset, verifyPasswordResetCode } from "firebase/auth";
import { auth, signInWithEmailAndPassword } from "../firebase";
import { validatePassword } from "../helpers/passwordHelper";
import { ThemeToggle } from "../components/ThemeToggle";

const PasswordReset: React.FC = () => {
    const navigate = useNavigate();
    const [searchParams] = useSearchParams();
    const mode = searchParams.get("mode");
    const oobCode = searchParams.get("oobCode");

    const [email, setEmail] = useState("");
    const [password, setPassword] = useState("");
    const [confirmPassword, setConfirmPassword] = useState("");
    const [loading, setLoading] = useState(true);
    const [submitting, setSubmitting] = useState(false);
    const [errorMessage, setErrorMessage] = useState<string | null>(null);
    const [successMessage, setSuccessMessage] = useState<string | null>(null);

    useEffect(() => {
        const verifyCode = async () => {
            if (mode?.trim()?.toLowerCase() !== "resetpassword" || !oobCode) {
                setErrorMessage("Error: Invalid password reset link.");
                setLoading(false);
                return;
            }

            try {
                const resetEmail = await verifyPasswordResetCode(auth, oobCode);
                setEmail(resetEmail);
            } catch (error) {
                setErrorMessage("Error: This password reset link is invalid or expired.");
            } finally {
                setLoading(false);
            }
        };

        verifyCode();
    }, [mode, oobCode]);

    const handleResetPassword = async (e: React.FormEvent) => {
        e.preventDefault();
        setSubmitting(true);
        setErrorMessage(null);
        setSuccessMessage(null);

        try {
            if (!oobCode) {
                setErrorMessage("Error: Invalid password reset link.");
                return;
            }

            const passwordError = validatePassword(password);
            if (passwordError) {
                setErrorMessage(passwordError);
                return;
            }

            if (password !== confirmPassword) {
                setErrorMessage("Error: Passwords don't match");
                return;
            }

            await confirmPasswordReset(auth, oobCode, password);
            await signInWithEmailAndPassword(auth, email, password);
            navigate("/home", { replace: true });
        } catch (error) {
            setErrorMessage("Error: Unable to reset password. Please request a new reset link.");
        } finally {
            setSubmitting(false);
        }
    };

    return (
        <div className="flex flex-col items-center justify-center min-h-screen bg-page px-4">
            <nav className="w-full bg-nav text-white p-4 shadow-md fixed top-0 left-0 flex justify-center items-center px-6">
                <h1 className="text-xl font-semibold align-self-center">CloudGateway</h1>
                <div className="absolute right-6">
                    <ThemeToggle />
                </div>
            </nav>

            {(errorMessage || successMessage) && (
                <div className="fixed top-20 w-full flex justify-center z-50">
                <div className={`px-6 py-3 rounded-xl shadow-md w-full max-w-md flex justify-between items-center ${
                    errorMessage ? "bg-danger text-white" : "bg-success text-white"
                }`}>
                    <span className="text-sm">
                    {errorMessage || successMessage}
                    </span>
                    <button
                    className="ml-4 font-bold hover:text-inset-strong transition"
                    onClick={() => {
                        setErrorMessage(null);
                        setSuccessMessage(null);
                    }}
                    >
                    ✕
                    </button>
                </div>
                </div>
            )}

            <div className="bg-card p-6 md:p-8 rounded-2xl shadow-lg w-full max-w-md mt-24">
                <h2 className="text-2xl font-semibold text-center mb-6">Reset Password</h2>

                {loading ? (
                    <div className="flex justify-center py-6">
                        <div className="border-t-4 border-primary border-solid rounded-full w-12 h-12 animate-spin"></div>
                    </div>
                ) : (
                    <form onSubmit={handleResetPassword}>
                    {email && (
                        <p className="text-sm text-content-secondary mb-6 text-center">
                            Resetting password for <b>{email}</b>
                        </p>
                    )}
                    <div className="mb-6">
                        <label className="block text-content-secondary font-medium mb-2">New Password</label>
                        <input
                        type="password"
                        value={password}
                        onChange={(e) => setPassword(e.target.value)}
                        className="w-full p-3 border border-edge bg-inset text-content rounded-lg focus:ring-2 focus:ring-focus focus:outline-none"
                        placeholder="At least 8 characters"
                        required
                        disabled={!email || submitting}
                        />
                        <p className="mt-2 text-xs text-content-muted">
                        Must include uppercase, lowercase, number, and special character.
                        </p>
                    </div>
                    <div className="mb-6">
                        <label className="block text-content-secondary font-medium mb-2">Confirm Password</label>
                        <input
                        type="password"
                        value={confirmPassword}
                        onChange={(e) => setConfirmPassword(e.target.value)}
                        className="w-full p-3 border border-edge bg-inset text-content rounded-lg focus:ring-2 focus:ring-focus focus:outline-none"
                        placeholder="Passwords Must Match"
                        required
                        disabled={!email || submitting}
                        />
                    </div>

                    <button
                        type="submit"
                        className={`w-full p-3 rounded-lg transition ${
                        email && password && confirmPassword && !submitting
                            ? "cursor-pointer bg-primary text-white hover:bg-primary-hover"
                            : "bg-disabled text-content-disabled cursor-not-allowed"
                        }`}
                        disabled={!email || !password || !confirmPassword || submitting}
                    >
                        {submitting ? "Resetting..." : "Reset Password"}
                    </button>
                    </form>
                )}
            </div>
        </div>
    );
};

export default PasswordReset;
