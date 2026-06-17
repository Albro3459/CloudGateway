import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { saveAs } from "file-saver";
import QRCode from "qrcode";
import packageJson from "../../package.json";

import { createClient, deleteClient } from "../helpers/APIHelper";
import type { ApiHelperFailure } from "../helpers/APIHelper";
import { auth, onAuthStateChanged } from "../firebase";
import { getRegionCapacityLabel, getRegionName, isRegionAtCapacity, Region } from "../helpers/regionsHelper";
import { getUserRole } from "../helpers/usersHelper";

import { CopyableValue } from "../components/CopyableValue";
import { NoRegionsMessage } from "../components/AccessMessages";
import { ThemeToggle } from "../components/ThemeToggle";
import { VPNTable, VPNTableEntry } from "../components/VPNTable";
import { getUsersVPNs, logout, VPNData } from "../helpers/firebaseDbHelper";
import { User } from "firebase/auth";
import { fetchOciRegions, useOciRegionsStore } from "../stores/ociRegionsStore";
import { VPN_STATUS } from "../helpers/vpnStatus";
import { filterVisibleVPNClients, getClientKey } from "../helpers/vpnVisibility";

type Banner = {
    type: "error" | "success";
    message: string;
};

const PULL_REFRESH_THRESHOLD = 72;
const PULL_REFRESH_MAX_DISTANCE = 96;

const getEnabledRegions = (regions: Region[] | null) => (
    (regions || []).filter(region => region.enabled !== false)
);

const Home: React.FC = () => {
    const navigate = useNavigate();

    const [loading, setLoading] = useState(false);
    const [banner, setBanner] = useState<Banner | null>(null);

    const [role, setRole] = useState<string | null>(null);
    const [jwtToken, setJwtToken] = useState<string | null>(null);

    const { ociRegions, loading: regionsLoading, error: regionsError } = useOciRegionsStore();
    const enabledRegions = useMemo(() => getEnabledRegions(ociRegions), [ociRegions]);
    const initialRegionsLoading = ociRegions === null && !regionsError;

    const [activeRegionId, setActiveRegionId] = useState("");
    const selectedRegion = enabledRegions.find(r => r.value === activeRegionId) || null;
    const selectedRegionFull = isRegionAtCapacity(selectedRegion);

    const [clientName, setClientName] = useState("");
    const [VPNTableEntries, setVPNTableEntries] = useState<VPNTableEntry[] | null>(null);
    const [selectedClientKeys, setSelectedClientKeys] = useState<Set<string>>(new Set());
    const [vpnRegion, setVpnRegion] = useState<string | null>(null);
    const [activeConfigClientName, setActiveConfigClientName] = useState<string | null>(null);
    const [activeConfigEndpoint, setActiveConfigEndpoint] = useState<string | null>(null);
    const [configData, setConfigData] = useState<string | null>(null);
    const [configCopied, setConfigCopied] = useState(false);
    const [pullDistance, setPullDistance] = useState(0);
    const [pullRefreshing, setPullRefreshing] = useState(false);
    const canvasRef = useRef<HTMLCanvasElement | null>(null);
    const sessionRemovedClientKeys = useRef<Set<string>>(new Set());
    const pullStartY = useRef<number | null>(null);
    const activePullPointerId = useRef<number | null>(null);
    const pullDistanceRef = useRef(0);

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

    const updatePullDistance = (distance: number) => {
        pullDistanceRef.current = distance;
        setPullDistance(distance);
    };

    const resetPull = useCallback(() => {
        pullStartY.current = null;
        activePullPointerId.current = null;
        updatePullDistance(0);
    }, []);

    // A fetch only applies if nothing newer has already applied, so a slow poll
    // can't overwrite newer data and an awaited refresh can't be invalidated by
    // an in-flight poll that may never land.
    const vpnFetchGen = useRef(0);
    const vpnAppliedGen = useRef(0);

    const fillVPNs = useCallback(async (user: User) => {
        const gen = ++vpnFetchGen.current;
        setVPNTableEntries(null);
        try {
            const VPNs: VPNData[] = await getUsersVPNs(user);
            if (gen <= vpnAppliedGen.current) return;
            vpnAppliedGen.current = gen;
            setVPNTableEntries(filterVisibleVPNClients(VPNs, sessionRemovedClientKeys.current));
        } catch (error) {
            if (gen <= vpnAppliedGen.current) return;
            vpnAppliedGen.current = gen;
            showBanner("error", "Error loading VPN clients");
            console.error("Error loading VPN clients:", error);
            setVPNTableEntries([]);
        }
    }, []);

    // Refreshes the table in place, without the loading skeleton or an error banner.
    const refreshVPNs = useCallback(async (user: User) => {
        const gen = ++vpnFetchGen.current;
        try {
            const VPNs: VPNData[] = await getUsersVPNs(user);
            if (gen <= vpnAppliedGen.current) return;
            vpnAppliedGen.current = gen;
            setVPNTableEntries(filterVisibleVPNClients(VPNs, sessionRemovedClientKeys.current));
        } catch (error) {
            console.error("Error refreshing VPN clients:", error);
        }
    }, []);

    const refreshDashboard = useCallback(async () => {
        if (!auth.currentUser || pullRefreshing) {
            resetPull();
            return;
        }

        setPullRefreshing(true);
        try {
            await Promise.all([
                refreshVPNs(auth.currentUser),
                jwtToken ? fetchOciRegions(jwtToken, true) : Promise.resolve(),
            ]);
        } finally {
            setPullRefreshing(false);
            resetPull();
        }
    }, [jwtToken, pullRefreshing, refreshVPNs, resetPull]);

    const handlePullStart = (event: React.PointerEvent<HTMLDivElement>) => {
        if (
            event.button > 0 ||
            loading ||
            pullRefreshing ||
            configData ||
            window.scrollY > 0
        ) {
            return;
        }

        pullStartY.current = event.clientY;
        activePullPointerId.current = event.pointerId;
    };

    const handlePullMove = (event: React.PointerEvent<HTMLDivElement>) => {
        if (pullStartY.current === null || activePullPointerId.current !== event.pointerId) return;
        if (window.scrollY > 0) {
            resetPull();
            return;
        }

        const delta = event.clientY - pullStartY.current;
        if (delta <= 0) {
            updatePullDistance(0);
            return;
        }

        event.preventDefault();
        updatePullDistance(Math.min(delta * 0.55, PULL_REFRESH_MAX_DISTANCE));
    };

    const handlePullEnd = (event: React.PointerEvent<HTMLDivElement>) => {
        if (pullStartY.current === null || activePullPointerId.current !== event.pointerId) return;

        if (pullDistanceRef.current >= PULL_REFRESH_THRESHOLD) {
            void refreshDashboard();
            return;
        }

        resetPull();
    };

    const handleCreateNewAccount = () => {
        if (role === "admin") {
            navigate("/create-user", { replace: true });
        }
    };

    const handleSyncRegions = () => {
        if (role === "admin") {
            navigate("/sync-regions");
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
                await refreshVPNs(auth.currentUser);
                return;
            }

            setClientName("");
            showBanner("success", `${response.data.clientName || "Client"} was created in ${activeRegionName}.`);
            await Promise.all([
                refreshVPNs(auth.currentUser),
                fetchOciRegions(jwtToken, true),
            ]);
        } catch (error) {
            showBanner("error", "Error creating client");
            console.error("Error creating client:", error);
            await refreshVPNs(auth.currentUser);
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
        selectedEntries.forEach(entry => sessionRemovedClientKeys.current.add(getClientKey(entry)));

        try {
            const results = await Promise.all(selectedEntries.map(entry => (
                deleteClient(entry.clientId, {
                    userId: entry.ownerUid || entry.userID,
                    regionId: activeRegionId,
                }, jwtToken)
            )));
            const failedResults = results.filter((result): result is ApiHelperFailure => !result.success);

            clearSelectedClients();
            await Promise.all([
                refreshVPNs(auth.currentUser),
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

        setActiveConfigEndpoint(vpn.serverEndpointHostname || vpn.serverEndpointIpv4 || vpn.ipv4);
        setVpnRegion(vpn.region);
        setActiveConfigClientName(vpn.clientName || vpn.clientId);
        setConfigData(vpn.wireguardConfig);
        setConfigCopied(false);
    }, []);

    const closeConfigModal = () => {
        setConfigData(null);
        setActiveConfigEndpoint(null);
        setVpnRegion(null);
        setActiveConfigClientName(null);
    };

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

    // Poll Firestore while a create/remove is running so the table shows
    // status transitions (creating -> active, active -> removed) live.
    useEffect(() => {
        if (!loading) return;

        const interval = window.setInterval(() => {
            if (auth.currentUser) {
                void refreshVPNs(auth.currentUser);
            }
        }, 2000);
        return () => window.clearInterval(interval);
    }, [loading, refreshVPNs]);

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
        <div
            data-testid="dashboard-page"
            className="flex min-h-screen touch-pan-y flex-col items-center overscroll-y-contain bg-page px-4 pb-20 pt-24"
            onPointerDown={handlePullStart}
            onPointerMove={handlePullMove}
            onPointerUp={handlePullEnd}
            onPointerCancel={resetPull}
        >
            <nav className="fixed left-0 top-0 z-40 flex w-full items-center justify-center bg-nav p-4 px-6 text-white shadow-md">
                <button
                    onClick={() => navigate("/about")}
                    className="absolute left-6 cursor-pointer rounded-lg bg-nav-btn px-4 py-2 text-accent transition hover:bg-nav-btn-hover"
                >
                    About
                </button>
                <h1 className="text-xl font-semibold">CloudGateway</h1>
                <div className="absolute right-6 flex items-center gap-3">
                    <ThemeToggle />
                    <button
                        onClick={async () => await logout(navigate)}
                        className="cursor-pointer rounded-lg bg-nav-btn px-4 py-2 text-accent transition hover:bg-nav-btn-hover"
                    >
                        Logout
                    </button>
                </div>
            </nav>

            {(pullDistance > 0 || pullRefreshing) && (
                <div
                    className="fixed top-20 z-50 rounded-full bg-card px-4 py-2 text-sm font-medium text-content shadow-md"
                    style={{ transform: `translateY(${pullRefreshing ? 0 : Math.min(pullDistance, PULL_REFRESH_THRESHOLD)}px)` }}
                    role="status"
                    aria-live="polite"
                >
                    {pullRefreshing ? "Refreshing..." : pullDistance >= PULL_REFRESH_THRESHOLD ? "Release to refresh" : "Pull to refresh"}
                </div>
            )}

            {banner && (
                <div className="fixed top-20 z-50 flex w-full justify-center px-4">
                    <div className={`flex w-full max-w-lg items-center justify-between rounded-lg px-5 py-3 text-white shadow-md ${
                        banner.type === "error" ? "bg-danger" : "bg-success"
                    }`}>
                        <span className="text-sm">{banner.message}</span>
                        <button
                            className="ml-4 font-bold transition hover:text-white/70"
                            onClick={() => setBanner(null)}
                            aria-label="Dismiss message"
                        >
                            x
                        </button>
                    </div>
                </div>
            )}

            {role === "admin" && (
                <div className="mb-4 flex w-full max-w-md flex-col gap-2 sm:flex-row">
                    <button
                        onClick={handleCreateNewAccount}
                        className="w-full cursor-pointer rounded-lg bg-primary p-3 text-white transition hover:bg-primary-hover"
                    >
                        Create Test Account
                    </button>
                    <button
                        onClick={handleSyncRegions}
                        className="w-full cursor-pointer rounded-lg bg-primary p-3 text-white transition hover:bg-primary-hover"
                    >
                        Sync Region Clients
                    </button>
                </div>
            )}

            <div className="w-full max-w-7xl rounded-lg bg-card p-4 shadow-lg md:p-6">
                <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
                    <div>
                        <h2 className="text-xl font-semibold text-content">VPN Dashboard</h2>
                        <p className="mt-1 text-sm text-content-muted">
                            {role === "admin"
                                ? "View and remove clients across users. New clients are created only for your account."
                                : "Create and remove your VPN clients."}
                        </p>
                    </div>

                    <form onSubmit={handleCreateClient} className="flex w-full flex-col gap-3 sm:flex-row lg:w-auto">
                        <label className="flex min-w-0 flex-1 flex-col text-sm font-medium text-content-secondary lg:w-64">
                            Client display name
                            <input
                                value={clientName}
                                onChange={(e) => setClientName(e.target.value)}
                                maxLength={80}
                                placeholder="Optional"
                                className="mt-1 w-full rounded-lg border border-edge-subtle bg-inset p-3 text-content focus:border-focus focus:outline-none focus:ring-2 focus:ring-focus-soft"
                            />
                        </label>
                        <button
                            type="submit"
                            disabled={createDisabled}
                            className={`rounded-lg px-5 py-3 text-sm font-medium transition sm:self-end ${
                                !createDisabled
                                    ? "cursor-pointer bg-primary text-white hover:bg-primary-hover"
                                    : "cursor-not-allowed bg-disabled text-content-disabled"
                            }`}
                        >
                            Create Client
                        </button>
                    </form>
                </div>

                <div className="mt-5 border-t border-edge-faint pt-4">
                    {(regionsLoading || initialRegionsLoading) && (
                        <p className="text-sm text-content-muted">Loading regions...</p>
                    )}
                    {regionsError && (
                        <p className="text-sm text-danger-content">{regionsError}</p>
                    )}
                    {!regionsLoading && ociRegions !== null && !enabledRegions.length && (
                        <p className="text-sm text-danger-content"><NoRegionsMessage /></p>
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
                                        className={`rounded-lg border px-4 py-2 text-left text-sm transition focus:outline-none focus:ring-2 focus:ring-focus ${
                                            isActive
                                                ? "border-primary bg-primary-soft text-accent"
                                                : "border-edge-subtle bg-card text-content-secondary hover:border-primary-soft-edge hover:bg-primary-soft"
                                        }`}
                                        aria-pressed={isActive}
                                    >
                                        <span className="block font-medium">{region.name}</span>
                                        {capacityLabel && (
                                            <span className={regionFull ? "block text-xs text-danger-content" : "block text-xs text-content-muted"}>
                                                {capacityLabel}
                                            </span>
                                        )}
                                    </button>
                                );
                            })}
                        </div>
                    ) : selectedRegion ? (
                        <div className="flex flex-wrap items-center gap-3 text-sm text-content-secondary">
                            <span className="font-medium">{selectedRegion.name}</span>
                            {selectedRegion.capacity && (
                                <span className={selectedRegionFull ? "text-danger-content" : "text-content-muted"}>
                                    {selectedRegionFull
                                        ? `${selectedRegion.name} is currently full`
                                        : getRegionCapacityLabel(selectedRegion)}
                                </span>
                            )}
                        </div>
                    ) : null}

                    {selectedRegionFull && (
                        <p className="mt-3 text-sm text-danger-content">
                            {activeRegionName} is currently full. Choose another region before creating a client.
                        </p>
                    )}
                    {role && role !== "admin" && (
                        <div className="mt-3 text-xs">
                            <a
                                href="mailto:Brodsky.Alex22@gmail.com"
                                className="text-accent underline hover:text-accent-strong"
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
                <div
                    className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
                    onClick={closeConfigModal}
                >
                    <div
                        className="relative w-full max-w-md rounded-lg bg-card p-6 text-center shadow-lg"
                        onClick={(event) => event.stopPropagation()}
                    >
                        <button
                            onClick={closeConfigModal}
                            className="absolute right-3 top-2 text-lg font-bold text-content-muted hover:text-content"
                            aria-label="Close QR code"
                        >
                            x
                        </button>
                        <h3 className="mb-2 text-2xl font-semibold">VPN QR Code</h3>
                        {activeConfigClientName && (
                            <p className="pt-1 text-content-secondary">
                                Client: <b>{activeConfigClientName}</b>
                            </p>
                        )}
                        {vpnRegion && (
                            <p className="pt-1 text-content-secondary">
                                Region: <b>{getRegionName(vpnRegion, ociRegions)}</b>
                            </p>
                        )}
                        {activeConfigEndpoint && (
                            <p className="flex items-center justify-center gap-1 pt-1 text-content-secondary">
                                Endpoint: <CopyableValue value={activeConfigEndpoint} label={`${activeConfigClientName || "client"} endpoint`} />
                            </p>
                        )}
                        <canvas ref={canvasRef} className="mx-auto mt-2" />
                        <div className="mt-4 flex flex-col gap-3 sm:flex-row">
                            <button
                                onClick={handleCopyActiveConfig}
                                className="flex-1 cursor-pointer rounded-lg bg-inset-strong p-3 text-content-secondary transition hover:bg-inset-strong-hover"
                            >
                                {configCopied ? "Copied" : "Copy Config"}
                            </button>
                            <button
                                onClick={handleDownloadActiveConfig}
                                className="flex-1 cursor-pointer rounded-lg bg-primary p-3 text-white transition hover:bg-primary-hover"
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
            <span className="fixed bottom-2 right-3 text-xs text-content-faint">
                v{packageJson?.version || '0.0.0'}
            </span>
        </div>
    );
};

export default Home;
