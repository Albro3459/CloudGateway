import React, { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { auth, onAuthStateChanged, sendPasswordResetEmail, signInWithEmailAndPassword } from "../firebase";
import packageJson from "../../package.json";
import { ThemeToggle } from "../components/ThemeToggle";

const Login: React.FC = () => {
    const navigate = useNavigate();
    
    const [email, setEmail] = useState("");
    const [password, setPassword] = useState("");
    const [error, setError] = useState<string | null>();
    const [success, setSuccess] = useState<string | null>();

    const handleLogin = async (e: React.FormEvent) => {
        e.preventDefault();
        try {
            if (!email.includes('@') || !email.includes('.')) {
                setError("Not a valid email.");
                return;
            }
            if (!password.trim().length) {
                setError("Password is required.");
                return;
            }

            await signInWithEmailAndPassword(auth, email, password);
            navigate("/home", { replace: true });
        } catch (err) {
            setError("Invalid email or password.");
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
        const unsubscribe = onAuthStateChanged(auth, (user) => {
            const fetchUserData = async () => {
                if (user) {
                    navigate("/home", { replace: true });
                }
            };
            fetchUserData();
        });
        return () => unsubscribe();
    }, [navigate]);

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
                className="ml-4 font-bold hover:text-inset-strong transition"
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
                    href="mailto:Brodsky.Alex22@gmail.com"
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
