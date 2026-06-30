import React, { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faHouse } from "@fortawesome/free-solid-svg-icons"; // Home icon
import { auth, onAuthStateChanged } from "../firebase";
import { logout } from "../helpers/firebaseDbHelper";
import packageJson from "../../package.json";
import { ThemeToggle } from "../components/ThemeToggle";

const About: React.FC = () => {
    const navigate = useNavigate();
    const [email, setEmail] = useState<string | null>(null);

    useEffect(() => {
        const unsubscribe = onAuthStateChanged(auth, (user) => {
            const fetchUserData = async () => {
                if (user) {
                    const email = user.email || "";
                    setEmail(email);
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
                <h1 className="text-xl font-semibold align-self-center">About</h1>
                <div className="absolute right-6 flex items-center gap-3">
                    <ThemeToggle />
                    {email && email.length > 0 &&
                    <button 
                        onClick={async () => await logout(navigate)} 
                        className="cursor-pointer bg-nav-btn text-accent hover:bg-nav-btn-hover px-4 py-2 rounded-lg transition"
                    >
                        Logout
                    </button>
                    }
                </div>
            </nav>
    
            {/* About Section */}
            <div className="bg-card p-6 md:p-8 rounded-2xl shadow-lg w-full max-w-xl text-center mx-4">
                <h2 className="text-2xl font-semibold mb-2">What is CloudGateway?</h2>
                <div className="ps-2 text-sm mb-2">
                    <b>Created by: </b>Alex Brodsky 
                    <br></br>
                    <a
                        href="https://github.com/Albro3459/CloudGateway/"
                        className="text-xs text-accent underline hover:text-accent-strong"
                        >
                        GitHub
                    </a>
                    <span> |   </span>
                    <a
                        href="https://www.linkedin.com/in/brodsky-alex22/"
                        className="text-xs text-accent underline hover:text-accent-strong"
                        >
                        LinkedIn
                    </a>
                    <span> |   </span>
                    <a
                        href="mailto:Brodsky.Alex22@gmail.com"
                        className="text-xs text-accent underline hover:text-accent-strong"
                        >
                        Email
                    </a>
                </div>
                <p className="text-content-secondary mb-4">
                    Create secure <b>WireGuard VPN</b> clients on shared regional CloudGateway servers,
                    pre-configured with IPv4, IPv6, and DNS.
                </p>
                <p className="text-content-secondary mb-4">
                    Each region runs a dedicated FastAPI control plane behind Cloudflare-protected Caddy,
                    with Firebase storing user and client state.
                </p>
                <p className="text-content-secondary mb-4">
                    Generate your VPN configuration instantly, scan a QR code, or download the .conf file for easy setup on 
                    your devices. All in just a few clicks.
                </p>
                <p className="text-content-secondary">
                    <b>Secure, simple, and instant.</b> Your personal VPN clients, managed on demand.
                </p>
            </div>
            <span className="fixed bottom-2 right-3 text-xs text-content-faint">
                v{packageJson?.version || '0.0.0'}
            </span>
        </div>
    );    
};

export default About;
