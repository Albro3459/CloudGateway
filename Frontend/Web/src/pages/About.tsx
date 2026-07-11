import React, { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { auth, onAuthStateChanged } from "../firebase";
import packageJson from "../../package.json";
import { AppNav } from "../components/AppNav";

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
            <AppNav subtitle="About" homePath={email ? "/home" : "/"} />
    
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
                    <span> |   </span>
                    <button
                        type="button"
                        onClick={() => navigate("/privacy")}
                        className="cursor-pointer text-xs text-accent underline hover:text-accent-strong"
                        >
                        Privacy
                    </button>
                </div>
                <p className="text-content-secondary mb-4">
                    Create secure <b>WireGuard VPN</b> clients on shared CloudGateway servers across
                    multiple regions, ready for both IPv4 and IPv6.
                </p>
                <p className="text-content-secondary mb-4">
                    Every config comes with built-in ad blocking and encrypted DNS to keep your
                    browsing private.
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
