import React, { useCallback, useEffect } from "react";
import { useNavigate, useLocation } from "react-router-dom";
import { FontAwesomeIcon } from '@fortawesome/react-fontawesome'
import { faHouse } from "@fortawesome/free-solid-svg-icons"; // Home icon
import { auth, onAuthStateChanged } from "../firebase";
import { logout } from "../helpers/firebaseDbHelper";
import { ThemeToggle } from "../components/ThemeToggle";

interface CreateUserSuccessState {
    email: string | null;
    password: string | null;
}

const CreateUserSuccess: React.FC = () => {
    const navigate = useNavigate();

    const location = useLocation();
    const { 
        email,
        password,
    } = (location.state || {}) as Partial<CreateUserSuccessState>;

    const userExists = useCallback(() => {
        return (
            email && password &&
            email.length > 0 && password.length > 0
        );
      }, [email, password]);

    useEffect(() => {
        if (!userExists()
        ) {
            navigate("/Home", { replace: true });
        }
    }, [userExists, navigate]);

    useEffect(() => {
        const unsubscribe = onAuthStateChanged(auth, (user) => {
            const fetchUserData = async () => {
                if (user) {
                } else {
                    await logout(navigate);
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
                <FontAwesomeIcon 
                    icon={faHouse} 
                    onClick={() => navigate("/home")}
                    className="text-2xl cursor-pointer absolute left-6" 
                />
                <h1 className="text-xl font-semibold align-self-center">Success</h1>
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

            <div className="bg-card p-6 xs:p-8 rounded-2xl shadow-lg w-full max-w-sm text-center">
                <h2 className="text-2xl font-semibold mb-4">{userExists() ? "Created User 🎉" : "Failed to Create User ❌"}</h2>

                {userExists() ? (
                    <p className="text-content-secondary">
                    User{" "}
                    { <b>{email}</b>} has been created.
                    </p>
                ) : (
                    <p className="text-content-secondary">No user was created.</p>
                )}

                {userExists() && (
                    <p className="pt-1 text-content-secondary">
                    Password: <b>{password}</b>
                    </p>
                )}
                </div>

        </div>
    );
};

export default CreateUserSuccess;
