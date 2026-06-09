import React, { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faHouse } from "@fortawesome/free-solid-svg-icons"; // Home icon
import { auth, onAuthStateChanged } from "../firebase";
import { logout } from "../helpers/firebaseDbHelper";
import packageJson from "../../package.json";

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
        <div className="flex flex-col items-center justify-center min-h-screen bg-gray-100 px-4">
            {/* Navbar */}
            <nav className="w-full bg-blue-600 text-white p-4 shadow-md fixed top-0 left-0 flex justify-center items-center px-6">
                <FontAwesomeIcon 
                    icon={faHouse} 
                    onClick={() => navigate("/home")}
                    className="text-2xl cursor-pointer absolute left-6" 
                />
                <h1 className="text-xl font-semibold align-self-center">About</h1>
                {email && email.length > 0 &&            
                    <button 
                        onClick={async () => await logout(navigate)} 
                        className="cursor-pointer bg-gray-300 text-blue-600 hover:bg-gray-100 px-4 py-2 rounded-lg transition absolute right-6"
                    >
                        Logout
                    </button>
                }
            </nav>
    
            {/* About Section */}
            <div className="bg-white p-6 md:p-8 rounded-2xl shadow-lg w-full max-w-xl text-center mx-4">
                <h2 className="text-2xl font-semibold mb-2">What is CloudLaunch?</h2>
                <div className="ps-2 text-sm mb-2">
                    <b>Created by: </b>Alex Brodsky 
                    <br></br>
                    <a
                        href="https://github.com/Albro3459/CloudLaunch/"
                        className="text-xs text-blue-600 underline hover:text-blue-800"
                        >
                        GitHub
                    </a>
                    <span> |   </span>
                    <a
                        href="https://www.linkedin.com/in/brodsky-alex22/"
                        className="text-xs text-blue-600 underline hover:text-blue-800"
                        >
                        LinkedIn
                    </a>
                    <span> |   </span>
                    <a
                        href="mailto:Brodsky.Alex22@gmail.com"
                        className="text-xs text-blue-600 underline hover:text-blue-800"
                        >
                        Email
                    </a>
                </div>
                <p className="text-gray-700 mb-4">
                    Instantly deploy a secure <b>WireGuard VPN</b> on an <b>AWS EC2</b> instance in the region of your choice, 
                    pre-configured with IPv4, IPv6, and DNS.
                </p>
                <p className="text-gray-700 mb-4">
                    The entire deployment process is automated using <b>AWS Lambda</b>, ensuring a fast, efficient, 
                    and hassle-free setup.
                </p>
                <p className="text-gray-700 mb-4">
                    Generate your VPN configuration instantly, scan a QR code, or download the .conf file for easy setup on 
                    your devices. All in just a few clicks.
                </p>
                <p className="text-gray-700">
                    <b>Secure, simple, and instant.</b> Your personal cloud VPN, deployed on demand.
                </p>
            </div>
            <span className="fixed bottom-2 right-3 text-xs text-gray-400">
                v{packageJson?.version || '0.0.0'}
            </span>
        </div>
    );    
};

export default About;
