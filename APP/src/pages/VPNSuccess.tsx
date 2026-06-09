import React, { useEffect, useRef, useState } from "react";
import { useNavigate, useLocation } from "react-router-dom";
import QRCode from "qrcode";
import { FontAwesomeIcon } from '@fortawesome/react-fontawesome'
import { faHouse } from "@fortawesome/free-solid-svg-icons"; // Home icon
import { saveAs } from "file-saver";
import { auth, onAuthStateChanged } from "../firebase";
import { logout } from "../helpers/firebaseDbHelper";
import { normalizeVPNStatus, VPN_STATUS, VPNStatus } from "../helpers/vpnStatus";

interface VPNSuccessState {
    region: string | null;
    isNew: boolean | null;
    status: VPNStatus | null;
    ip: string | null;
    wireguard_config: string | null;
}

const VPNSuccess: React.FC = () => {
    const navigate = useNavigate();

    const location = useLocation();
    const { region, isNew, status, ip, wireguard_config } = (location.state || {}) satisfies Partial<VPNSuccessState>;
    const normalizedStatus = normalizeVPNStatus(status);
    const hasVPN = !!ip && ip.length > 0;
    const isPending = normalizedStatus === VPN_STATUS.PENDING;
    
    const [configData, setConfigData] = useState<string | null>(null);
    const canvasRef = useRef<HTMLCanvasElement | null>(null);

    useEffect(() => {
        if (hasVPN && wireguard_config) {
            setConfigData(wireguard_config);
        } else {
            setConfigData(null);
        }
    }, [hasVPN, wireguard_config]);

    useEffect(() => {
        if (configData && canvasRef.current) {
            QRCode.toCanvas(canvasRef.current, configData, {
                width: 250,
            }, (error) => {
                if (error) console.error("QR Code generation failed:", error);
            });
        }
    }, [configData]);

    const handleDownload = () => {
        if (hasVPN && configData) {
            const blob = new Blob([configData], { type: "text/plain;charset=utf-8" });
            saveAs(blob, `wireguard.conf`);
        }
    };

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
        <div className="flex flex-col items-center justify-center min-h-screen bg-gray-100 px-4">
            {/* Navbar */}
            <nav className="w-full bg-blue-600 text-white p-4 shadow-md fixed top-0 left-0 flex justify-center items-center px-6">
                <FontAwesomeIcon 
                    icon={faHouse} 
                    onClick={() => navigate("/home")}
                    className="text-2xl cursor-pointer absolute left-6" 
                />
                <h1 className="text-xl font-semibold align-self-center">Success</h1>
                <button 
                onClick={async () => await logout(navigate)} 
                className="cursor-pointer bg-gray-300 text-blue-600 hover:bg-gray-100 px-4 py-2 rounded-lg transition absolute right-6"
                >
                Logout
                </button>
            </nav>

            <div className="bg-white p-6 md:p-8 rounded-2xl shadow-lg w-full max-w-lg text-center">
                <h2 className="text-2xl font-semibold mb-4">
                    {isPending ? (
                        <>
                            Deployment Pending
                        </>
                    ) : isNew ? (
                        <>
                            Deployment  {hasVPN ? "Successful 🎉" : "Failure ❌"}
                        </>
                    ) : (
                        <>
                            {hasVPN ? "Success 🎉" : "Fail ❌"}
                        </>
                    )}
                    
                </h2>

                {isPending ? (
                    <p className="text-gray-700">
                        Your VPN is still being created in <b>{region}</b>. Check the VPN table for status.
                    </p>
                ) : hasVPN ? (
                    <p className="text-gray-700">
                        {isNew ? (
                            <>
                                A VPN has been deployed in <b>{region}</b>.
                            </>
                        ) : (
                            <>
                                A VPN has been found in <b>{region}</b>.
                            </>
                        )}
                    </p>
                ) : (
                    <p className="text-gray-700">No VPN was deployed.</p>
                )}

                {hasVPN && (
                    <p className="pt-1 text-gray-700">
                        IP Address: <b>{ip}</b>
                    </p>
                )}

                {/* QR Code Canvas */}
                {hasVPN && configData && (
                    <>
                        <canvas ref={canvasRef} className="mt-4 mx-auto"></canvas>
                        <button 
                            onClick={handleDownload} 
                            className="cursor-pointer w-full bg-blue-600 text-white p-3 rounded-lg hover:bg-blue-700 transition mt-6"
                        >
                            Download Config
                        </button>
                    </>
                )}
                </div>

        </div>
    );
};

export default VPNSuccess;
