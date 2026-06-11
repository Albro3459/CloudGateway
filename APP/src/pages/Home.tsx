import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { saveAs } from "file-saver";
import QRCode from "qrcode";

import { createClient, deleteClient } from "../helpers/APIHelper";
import { auth, onAuthStateChanged } from "../firebase";
import { getRegionCapacityLabel, getRegionName, isRegionAtCapacity, Region } from "../helpers/regionsHelper";
import { getUserRole } from "../helpers/usersHelper";

import { CopyableValue } from "../components/CopyableValue";
import { VPNTable, VPNTableEntry } from "../components/VPNTable";
import { getUsersVPNs, logout, VPNData } from "../helpers/firebaseDbHelper";
import { User } from "firebase/auth";
import { fetchOciRegions, useOciRegionsStore } from "../stores/ociRegionsStore";
import { VPN_STATUS } from "../helpers/vpnStatus";

type Banner = {
    type: "error" | "success";
    message: string;
};

const getEnabledRegions = (regions: Region[] | null) => (
    (regions || []).filter(region => region.enabled !== false)
);

const getClientKey = (entry: VPNTableEntry) => (
    `${entry.userID}:${entry.region || ""}:${entry.clientId}`
);

const Home: React.FC = () => {
    const navigate = useNavigate();

    const [loading, setLoading] = useState(false);
    const [banner, setBanner] = useState<Banner | null>(null);

    const [role, setRole] = useState<string | null>(null);
    const [jwtToken, setJwtToken] = useState<string | null>(null);

    const { ociRegions, loading: regionsLoading, error: regionsError } = useOciRegionsStore();
    const enabledRegions = useMemo(() => getEnabledRegions(ociRegions), [ociRegions]);

    const [activeRegionId, setActiveRegionId] = useState("");
    const selectedRegion = enabledRegions.find(r => r.value === activeRegionId) || null;
    const selectedRegionFull = isRegionAtCapacity(selectedRegion);

    const [clientName, setClientName] = useState("");
    const [VPNTableEntries, setVPNTableEntries] = useState<VPNTableEntry[] | null>(null);
    const [selectedClientKeys, setSelectedClientKeys] = useState<Set<string>>(new Set());
    const [vpnRegion, setVpnRegion] = useState<string | null>(null);
    const [activeConfigClientName, setActiveConfigClientName] = useState<string | null>(null);
    const [IP, setIP] = useState<string | null>(null);
    const [configData, setConfigData] = useState<string | null>(null);
    const [configCopied, setConfigCopied] = useState(false);
    const canvasRef = useRef<HTMLCanvasElement | null>(null);

    const activeRegionName = selectedRegion
        ? getRegionName(selectedRegion.value, ociRegions)
        : "No region selected";

    const showRegionTabs = enabledRegions.length > 1;

    const activeRegionEntries = useMemo(() => {
        if (VPNTableEntries === null) return null;
        if (!activeRegionId) return [];

        return VPNTableEntries.filter(vpn => vpn.region === activeRegionId);
    }, [VPNTableEntries, activeRegionId]);

    const showBanner = (type: Banner["type"], message: string) => {
        setBanner({ type, message });
    };

    const clearSelectedClients = () => {
        setSelectedClientKeys(new Set());
    };

    const selectRegion = (regionId: string) => {
        setActiveRegionId(regionId);
        clearSelectedClients();
        setBanner(null);
    };

    const fillVPNs = useCallback(async (user: User) => {
        setVPNTableEntries(null);
        try {
            const VPNs: VPNData[] = await getUsersVPNs(user);
            setVPNTableEntries(VPNs);
        } catch (error) {
            showBanner("error", "Error loading VPN clients");
            console.error("Error loading VPN clients:", error);
            setVPNTableEntries([]);
        }
    }, []);

    const handleCreateNewAccount = () => {
        if (role === "admin") {
            navigate("/create-user", { replace: true });
        }
    };

    const handleCreateClient = async (e: React.FormEvent) => {
        e.preventDefault();

        if (!jwtToken) {
            showBanner("error", "Error: JWT token not found");
            return;
        }
        if (!auth.currentUser) {
            showBanner("error", "You must be signed in to create a client");
            return;
        }
        if (!activeRegionId || !selectedRegion) {
            showBanner("error", "Select a region");
            return;
        }
        if (selectedRegionFull) {
            showBanner("error", `${activeRegionName} is currently full. Choose another region.`);
            return;
        }

        setLoading(true);
        setBanner(null);

        try {
            const trimmedClientName = clientName.trim();
            const response = await createClient({
                regionId: activeRegionId,
                ...(trimmedClientName ? { clientName: trimmedClientName } : {}),
            }, jwtToken);

            if (!response.success) {
                showBanner("error", response.error || "Unable to create client");
                if (response.errorCode === "CAPACITY_REACHED" || response.errorCode === "LIMIT_REACHED") {
                    await fetchOciRegions(jwtToken, true);
                }
                await fillVPNs(auth.currentUser);
                return;
            }

            setClientName("");
            showBanner("success", `${response.data.clientName || "Client"} was created in ${activeRegionName}.`);
            await Promise.all([
                fillVPNs(auth.currentUser),
                fetchOciRegions(jwtToken, true),
            ]);
        } catch (error) {
            showBanner("error", "Error creating client");
            console.error("Error creating client:", error);
            await fillVPNs(auth.currentUser);
        } finally {
            setLoading(false);
        }
    };

    const handleSelectionChange = (entry: VPNTableEntry, selected: boolean) => {
        if (entry.status === VPN_STATUS.REMOVED) return;

        setSelectedClientKeys(prev => {
            const updated = new Set(prev);
            const key = getClientKey(entry);

            if (selected) {
                updated.add(key);
            } else {
                updated.delete(key);
            }

            return updated;
        });
    };

    const handleRemoveSelected = async () => {
        if (!jwtToken) {
            showBanner("error", "Error: JWT token not found");
            return;
        }
        if (!auth.currentUser) {
            showBanner("error", "You must be signed in to remove clients");
            return;
        }
        if (!activeRegionId) {
            showBanner("error", "Select a region");
            return;
        }

        const selectedEntries = (activeRegionEntries || []).filter(entry => selectedClientKeys.has(getClientKey(entry)));
        if (!selectedEntries.length) {
            showBanner("error", "No clients selected");
            return;
        }

        setLoading(true);
        setBanner(null);

        try {
            const results = await Promise.all(selectedEntries.map(entry => (
                deleteClient(entry.clientId, {
                    userId: entry.ownerUid || entry.userID,
                    regionId: activeRegionId,
                }, jwtToken)
            )));
            const failedResults = results.filter(result => !result.success);

            clearSelectedClients();
            await Promise.all([
                fillVPNs(auth.currentUser),
                fetchOciRegions(jwtToken, true),
            ]);

            if (failedResults.length) {
                const firstFailure = failedResults[0];
                showBanner("error", firstFailure.error || `${failedResults.length} client removals failed`);
                return;
            }

            showBanner("success", `${selectedEntries.length} client${selectedEntries.length === 1 ? "" : "s"} removed from ${activeRegionName}.`);
        } catch (error) {
            showBanner("error", "Error removing clients");
            console.error("Error removing clients:", error);
        } finally {
            setLoading(false);
        }
    };

    const handleQRcode = useCallback((vpn: VPNTableEntry) => {
        if (!vpn.wireguardConfig) {
            showBanner("error", "Config not available for QR code.");
            return;
        }

        setIP(vpn.assignedTunnelIpv4 || vpn.serverEndpointIpv4 || vpn.ipv4);
        setVpnRegion(vpn.region);
        setActiveConfigClientName(vpn.clientName || vpn.clientId);
        setConfigData(vpn.wireguardConfig);
        setConfigCopied(false);
    }, []);

    const handleDownloadConfig = (vpn: VPNTableEntry) => {
        if (!vpn.wireguardConfig) {
            showBanner("error", "Config not available for download.");
            return;
        }

        const blob = new Blob([vpn.wireguardConfig], { type: "text/plain;charset=utf-8" });
        saveAs(blob, `${vpn.clientName || vpn.clientId || "wireguard"}.conf`);
    };

    const handleDownloadActiveConfig = () => {
        if (configData) {
            const blob = new Blob([configData], { type: "text/plain;charset=utf-8" });
            saveAs(blob, `${activeConfigClientName || "wireguard"}.conf`);
        }
    };

    const handleCopyActiveConfig = async () => {
        if (!configData) return;

        try {
            await navigator.clipboard.writeText(configData);
            setConfigCopied(true);
            window.setTimeout(() => setConfigCopied(false), 1400);
        } catch (error) {
            showBanner("error", "Unable to copy config");
            console.error("Unable to copy config:", error);
        }
    };

    useEffect(() => {
        if (configData && canvasRef.current) {
            QRCode.toCanvas(canvasRef.current, configData, {
                width: 250,
            }, (error) => {
                if (error) console.error("QR Code generation failed:", error);
            });
        }
    }, [configData]);

    useEffect(() => {
        const unsubscribe = onAuthStateChanged(auth, (user) => {
            const fetchUserData = async () => {
                if (user) {
                    void fillVPNs(user);
                    const token: string | null = await user.getIdToken();
                    setJwtToken(token);
                    setRole(await getUserRole(user));

                    void fetchOciRegions(token, true);
                } else {
                    await logout(navigate);
                }
            };
            void fetchUserData();
        });
        return () => unsubscribe();
    }, [navigate, fillVPNs]);

    useEffect(() => {
        if (!enabledRegions.length) {
            if (activeRegionId) {
                setActiveRegionId("");
                clearSelectedClients();
            }
            return;
        }

        if (!activeRegionId || !enabledRegions.some(region => region.value === activeRegionId)) {
            setActiveRegionId(enabledRegions[0].value);
            clearSelectedClients();
        }
    }, [enabledRegions, activeRegionId]);

    useEffect(() => {
        if (!activeRegionEntries) return;

        setSelectedClientKeys(prev => {
            const availableKeys = new Set(activeRegionEntries.map(entry => getClientKey(entry)));
            const selectedKeys = Array.from(prev).filter(key => availableKeys.has(key));

            if (selectedKeys.length === prev.size) {
                return prev;
            }

            return new Set(selectedKeys);
        });
    }, [activeRegionEntries]);

    const createDisabled = !activeRegionId || !selectedRegion || selectedRegionFull || regionsLoading || VPNTableEntries === null || loading;

    return (
        <div className="flex min-h-screen flex-col items-center bg-gray-100 px-4 pb-20 pt-24">
            <nav className="fixed left-0 top-0 z-40 flex w-full items-center justify-center bg-blue-600 p-4 px-6 text-white shadow-md">
                <button
                    onClick={() => navigate("/about")}
                    className="absolute left-6 cursor-pointer rounded-lg bg-gray-300 px-4 py-2 text-blue-600 transition hover:bg-gray-100"
                >
                    About
                </button>
                <h1 className="text-xl font-semibold">CloudGateway</h1>
                <button
                    onClick={async () => await logout(navigate)}
                    className="absolute right-6 cursor-pointer rounded-lg bg-gray-300 px-4 py-2 text-blue-600 transition hover:bg-gray-100"
                >
                    Logout
                </button>
            </nav>

            {banner && (
                <div className="fixed top-20 z-50 flex w-full justify-center px-4">
                    <div className={`flex w-full max-w-lg items-center justify-between rounded-lg px-5 py-3 text-white shadow-md ${
                        banner.type === "error" ? "bg-red-500" : "bg-green-600"
                    }`}>
                        <span className="text-sm">{banner.message}</span>
                        <button
                            className="ml-4 font-bold transition hover:text-gray-200"
                            onClick={() => setBanner(null)}
                            aria-label="Dismiss message"
                        >
                            x
                        </button>
                    </div>
                </div>
            )}

            {role === "admin" && (
                <div className="mb-4 w-full max-w-md">
                    <button
                        onClick={handleCreateNewAccount}
                        className="w-full cursor-pointer rounded-lg bg-blue-600 p-3 text-white transition hover:bg-blue-700"
                    >
                        Create Test Account
                    </button>
                </div>
            )}

            <div className="w-full max-w-7xl rounded-lg bg-white p-4 shadow-lg md:p-6">
                <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
                    <div>
                        <h2 className="text-xl font-semibold text-gray-900">Shared VPN Dashboard</h2>
                        <p className="mt-1 text-sm text-gray-500">
                            {role === "admin"
                                ? "View and remove clients across users. New clients are created only for your account."
                                : "Create and remove your VPN clients."}
                        </p>
                    </div>

                    <form onSubmit={handleCreateClient} className="flex w-full flex-col gap-3 sm:flex-row lg:w-auto">
                        <label className="flex min-w-0 flex-1 flex-col text-sm font-medium text-gray-700 lg:w-64">
                            Client display name
                            <input
                                value={clientName}
                                onChange={(e) => setClientName(e.target.value)}
                                maxLength={80}
                                placeholder="Optional"
                                className="mt-1 w-full rounded-lg border border-gray-200 bg-gray-50 p-3 text-gray-800 focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-100"
                            />
                        </label>
                        <button
                            type="submit"
                            disabled={createDisabled}
                            className={`rounded-lg px-5 py-3 text-sm font-medium transition sm:self-end ${
                                !createDisabled
                                    ? "cursor-pointer bg-blue-600 text-white hover:bg-blue-700"
                                    : "cursor-not-allowed bg-gray-300 text-gray-500"
                            }`}
                        >
                            Create Client
                        </button>
                    </form>
                </div>

                <div className="mt-5 border-t border-gray-100 pt-4">
                    {regionsLoading && (
                        <p className="text-sm text-gray-500">Loading regions...</p>
                    )}
                    {regionsError && (
                        <p className="text-sm text-red-600">{regionsError}</p>
                    )}
                    {!regionsLoading && !enabledRegions.length && (
                        <p className="text-sm text-red-600">No enabled regions are available.</p>
                    )}
                    {showRegionTabs ? (
                        <div className="flex flex-wrap gap-2">
                            {enabledRegions.map(region => {
                                const isActive = region.value === activeRegionId;
                                const capacityLabel = getRegionCapacityLabel(region);
                                const regionFull = isRegionAtCapacity(region);

                                return (
                                    <button
                                        key={region.value}
                                        type="button"
                                        onClick={() => selectRegion(region.value)}
                                        className={`rounded-lg border px-4 py-2 text-left text-sm transition focus:outline-none focus:ring-2 focus:ring-blue-500 ${
                                            isActive
                                                ? "border-blue-600 bg-blue-50 text-blue-700"
                                                : "border-gray-200 bg-white text-gray-700 hover:border-blue-200 hover:bg-blue-50"
                                        }`}
                                        aria-pressed={isActive}
                                    >
                                        <span className="block font-medium">{region.name}</span>
                                        {capacityLabel && (
                                            <span className={regionFull ? "block text-xs text-red-600" : "block text-xs text-gray-500"}>
                                                {capacityLabel}
                                            </span>
                                        )}
                                    </button>
                                );
                            })}
                        </div>
                    ) : selectedRegion ? (
                        <div className="flex flex-wrap items-center gap-3 text-sm text-gray-700">
                            <span className="font-medium">{selectedRegion.name}</span>
                            {selectedRegion.capacity && (
                                <span className={selectedRegionFull ? "text-red-600" : "text-gray-500"}>
                                    {selectedRegionFull
                                        ? `${selectedRegion.name} is currently full`
                                        : getRegionCapacityLabel(selectedRegion)}
                                </span>
                            )}
                        </div>
                    ) : null}

                    {selectedRegionFull && (
                        <p className="mt-3 text-sm text-red-600">
                            {activeRegionName} is currently full. Choose another region before creating a client.
                        </p>
                    )}
                    {role && role !== "admin" && (
                        <div className="mt-3 text-xs">
                            <a
                                href="mailto:Brodsky.Alex22@gmail.com"
                                className="text-blue-600 underline hover:text-blue-800"
                            >
                                Email me to request a region
                            </a>
                        </div>
                    )}
                </div>
            </div>

            <VPNTable
                data={activeRegionEntries}
                isAdmin={role === "admin"}
                regions={ociRegions}
                selectedClientKeys={selectedClientKeys}
                getClientKey={getClientKey}
                onSelectionChange={handleSelectionChange}
                onRemoveSelected={handleRemoveSelected}
                onQRCodeClick={handleQRcode}
                onDownloadConfig={handleDownloadConfig}
                removing={loading}
                activeRegionName={activeRegionName}
            />

            {configData && (
                <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
                    <div className="relative w-full max-w-md rounded-lg bg-white p-6 text-center shadow-lg">
                        <button
                            onClick={() => {
                                setConfigData(null);
                                setIP(null);
                                setVpnRegion(null);
                                setActiveConfigClientName(null);
                            }}
                            className="absolute right-3 top-2 text-lg font-bold text-gray-500 hover:text-black"
                            aria-label="Close QR code"
                        >
                            x
                        </button>
                        <h3 className="mb-2 text-2xl font-semibold">VPN QR Code</h3>
                        {activeConfigClientName && (
                            <p className="pt-1 text-gray-700">
                                Client: <b>{activeConfigClientName}</b>
                            </p>
                        )}
                        {vpnRegion && (
                            <p className="pt-1 text-gray-700">
                                Region: <b>{getRegionName(vpnRegion, ociRegions)}</b>
                            </p>
                        )}
                        {IP && (
                            <p className="flex items-center justify-center gap-1 pt-1 text-gray-700">
                                Address: <CopyableValue value={IP} label={`${activeConfigClientName || "client"} address`} />
                            </p>
                        )}
                        <canvas ref={canvasRef} className="mx-auto mt-2" />
                        <div className="mt-4 flex flex-col gap-3 sm:flex-row">
                            <button
                                onClick={handleCopyActiveConfig}
                                className="flex-1 cursor-pointer rounded-lg bg-gray-200 p-3 text-gray-800 transition hover:bg-gray-300"
                            >
                                {configCopied ? "Copied" : "Copy Config"}
                            </button>
                            <button
                                onClick={handleDownloadActiveConfig}
                                className="flex-1 cursor-pointer rounded-lg bg-blue-600 p-3 text-white transition hover:bg-blue-700"
                            >
                                Download Config
                            </button>
                        </div>
                    </div>
                </div>
            )}

            {loading && (
                <div className="fixed inset-0 z-50 flex h-full w-full items-center justify-center bg-black/50">
                    <div className="h-16 w-16 animate-spin rounded-full border-t-4 border-solid border-white"></div>
                </div>
            )}
        </div>
    );
};

export default Home;
