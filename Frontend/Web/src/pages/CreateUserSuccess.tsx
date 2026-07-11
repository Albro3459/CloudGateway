import React, { useCallback, useEffect } from "react";
import { useNavigate, useLocation } from "react-router-dom";
import { auth, onAuthStateChanged } from "../firebase";
import { logout } from "../helpers/firebaseDbHelper";
import { AppNav } from "../components/AppNav";

interface CreateUserSuccessState {
    email: string | null;
    alreadyExisted: boolean;
}

const CreateUserSuccess: React.FC = () => {
    const navigate = useNavigate();

    const location = useLocation();
    const { 
        email,
    } = (location.state || {}) as Partial<CreateUserSuccessState>;
    const websiteOrigin = window.location.origin;

    const userExists = useCallback(() => {
        return (
            email &&
            email.length > 0
        );
      }, [email]);

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
            <AppNav subtitle="User Access" homePath="/home" />

            <div className="bg-card p-6 xs:p-8 rounded-2xl shadow-lg w-full max-w-sm text-center">
                <h2 className="text-2xl font-semibold mb-4">{userExists() ? "User Has Access" : "Failed to Grant Access"}</h2>

                {userExists() ? (
                    <div className="space-y-3 text-content-secondary">
                    <p>Email: <b>{email}</b></p>
                    <p>Website: <b>{websiteOrigin}</b></p>
                    <p>They can sign in with Google, or open the website and choose Reset password for this email.</p>
                    </div>
                ) : (
                    <p className="text-content-secondary">Access was not granted.</p>
                )}
                </div>

        </div>
    );
};

export default CreateUserSuccess;
