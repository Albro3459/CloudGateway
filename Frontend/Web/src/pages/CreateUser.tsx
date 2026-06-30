import React, { useState, useEffect } from "react";
import { useNavigate } from "react-router-dom";
import { getIdToken, onAuthStateChanged } from "firebase/auth";
import { auth } from "../firebase";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faHouse } from "@fortawesome/free-solid-svg-icons";
import { createAdminUser } from "../helpers/APIHelper";
import { getUserRole } from "../helpers/usersHelper";
import { logout } from "../helpers/firebaseDbHelper";
import { fetchOciRegions, useOciRegionsStore } from "../stores/ociRegionsStore";
import { ThemeToggle } from "../components/ThemeToggle";
import { NoRegionsMessage } from "../components/AccessMessages";

const CreateUser: React.FC = () => {
    const navigate = useNavigate();
    const [jwtToken, setJwtToken] = useState<string | null>(null);
    const { ociRegions, loading: regionsLoading, error: regionsError } = useOciRegionsStore();

    const [email, setEmail] = useState("");

    const [loading, setLoading] = useState(false);
    const [errorMessage, setErrorMessage] = useState<React.ReactNode>(null);
    const [successMessage, setSuccessMessage] = useState<string | null>(null);
    const grantAccessDisabled = !email || loading || regionsLoading;

    useEffect(() => {
        const unsubscribe = onAuthStateChanged(auth, (user) => {
            const fetchUserData = async () => {
                if (user) {
                    const role  = await getUserRole(user);
                    if (role !== "admin") {
                        navigate("/", { replace: true });
                        return;
                    }
                    try {
                        const token = await getIdToken(user);
                        setJwtToken(token);
                        void fetchOciRegions(token, true);
                    } catch (error) {
                        console.error("Error fetching JWT token:", error);
                    }
                } else {
                    await logout(navigate);
                }
            };
            fetchUserData();
        });
        return () => unsubscribe();
    }, [navigate]);

    const handleCreateAccount = async (e: React.FormEvent) => {
        e.preventDefault();
        setLoading(true);
        setErrorMessage(null);
        setSuccessMessage(null);

        try {
            const trimmedEmail = email.trim();

            if (!jwtToken) {
                setLoading(false);
                setErrorMessage("Error: JWT token not found");
                return;
            }
            else {
                if (!trimmedEmail.includes('@') || !trimmedEmail.includes('.')) {
                    setLoading(false);
                    setErrorMessage("Error: Not a valid email.");
                    return;
                }
                if (regionsLoading) {
                    setLoading(false);
                    setErrorMessage("Regions are still loading");
                    return;
                }
                if (regionsError) {
                    setLoading(false);
                    setErrorMessage(regionsError);
                    return;
                }
                if (!ociRegions?.length) {
                    setLoading(false);
                    setErrorMessage(<NoRegionsMessage />);
                    return;
                }
                const result = await createAdminUser({ email: trimmedEmail }, jwtToken, ociRegions);
                setLoading(false);
                if (result.success) {
                    const successText = result.data.alreadyExisted
                        ? `Existing account granted access: ${trimmedEmail}`
                        : `User access granted: ${trimmedEmail}`;
                    setSuccessMessage(successText);
                    setEmail("");
                    navigate("/create-user-success", {
                        replace: true,
                        state: {
                            email: trimmedEmail,
                            alreadyExisted: result.data.alreadyExisted,
                        }
                    });
                }
                else {
                    setErrorMessage(result.error);
                }
            }
        } catch (error: any) {
            console.error("Account creation failed:", error);
            setErrorMessage(error.message || "An error occurred");
        }
    };

    return (
        <div className="flex flex-col items-center justify-center min-h-screen bg-page px-4">
            {/* Navbar */}
            <nav className="w-full bg-nav text-white p-4 shadow-md fixed top-0 left-0 flex justify-center items-center px-6">
                <FontAwesomeIcon 
                    icon={faHouse} 
                    onClick={() => navigate("/home")}
                    className="text-2xl cursor-pointer absolute left-6" 
                />
                <h1 className="text-xl font-semibold align-self-center">Grant User Access</h1>
                <div className="absolute right-6 flex items-center gap-3">
                    <ThemeToggle />
                    <button
                    onClick={async () => await logout(navigate)}
                    className="cursor-pointer bg-nav-btn text-accent hover:bg-nav-btn-hover px-4 py-2 rounded-lg transition"
                    >
                    Logout
                    </button>
                </div>
            </nav>

            {/* Error or Success */}
            {(errorMessage || successMessage) && (
                <div className="fixed top-20 w-full flex justify-center z-50">
                <div className={`px-6 py-3 rounded-xl shadow-md w-full max-w-md flex justify-between items-center ${
                    errorMessage ? "bg-danger text-white" : "bg-success text-white"
                }`}>
                    <span className="text-sm">
                    {errorMessage || successMessage}
                    </span>
                    <button
                    className="ml-4 font-bold hover:text-white/70 transition"
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

            {/* Form */}
            <div className="bg-card p-6 md:p-8 rounded-2xl shadow-lg w-full max-w-md mt-24">
                <h2 className="text-2xl font-semibold text-center mb-6">Grant User Access</h2>

                <form onSubmit={handleCreateAccount}>
                {/* Email */}
                <div className="mb-6">
                    <label className="block text-content-secondary font-medium mb-2">Email</label>
                    <input
                    type="text"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    className="w-full p-3 border border-edge bg-inset text-content rounded-lg focus:ring-2 focus:ring-focus focus:outline-none"
                    placeholder="Email"
                    />
                </div>
                {/* Submit */}
                <button
                    type="submit"
                    className={`w-full p-3 rounded-lg transition ${
                    !grantAccessDisabled
                        ? "cursor-pointer bg-primary text-white hover:bg-primary-hover"
                        : "bg-disabled text-content-disabled cursor-not-allowed"
                    }`}
                    disabled={grantAccessDisabled}
                >
                    {regionsLoading ? "Loading regions..." : "Grant Access"}
                </button>
                </form>
            </div>

            {/* Loading Overlay (Blocks clicks and dims background) */}
            {loading && (
                <div className="fixed inset-0 w-full h-full bg-black/50 flex items-center justify-center z-50">
                <div className="border-t-4 border-white border-solid rounded-full w-16 h-16 animate-spin"></div>
                </div>
            )}
        </div>
    );
};

export default CreateUser;
