import React, { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { getIdToken, onAuthStateChanged } from "firebase/auth";
import { auth } from "../firebase";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faHouse } from "@fortawesome/free-solid-svg-icons";
import { runRegionsSync, type RegionSyncResult } from "../helpers/APIHelper";
import { getUserRole } from "../helpers/usersHelper";
import { logout } from "../helpers/firebaseDbHelper";
import { fetchOciRegions, useOciRegionsStore } from "../stores/ociRegionsStore";
import { ThemeToggle } from "../components/ThemeToggle";
import { NoRegionsMessage } from "../components/AccessMessages";
import { RegionSyncCard } from "../components/RegionSyncCard";

const SyncRegions: React.FC = () => {
    const navigate = useNavigate();
    const [jwtToken, setJwtToken] = useState<string | null>(null);
    const { ociRegions, loading: regionsLoading, error: regionsError } = useOciRegionsStore();

    const [selected, setSelected] = useState<Set<string>>(new Set());
    const [syncing, setSyncing] = useState(false);
    const [results, setResults] = useState<RegionSyncResult[] | null>(null);
    const [errorMessage, setErrorMessage] = useState<React.ReactNode>(null);

    useEffect(() => {
        const unsubscribe = onAuthStateChanged(auth, (user) => {
            const fetchUserData = async () => {
                if (user) {
                    const role = await getUserRole(user);
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

    const regions = useMemo(() => ociRegions ?? [], [ociRegions]);
    const displayNameById = useMemo(() => {
        const map = new Map<string, string>();
        regions.forEach((region) => map.set(region.regionId, region.displayName));
        return map;
    }, [regions]);

    const allSelected = regions.length > 0 && selected.size === regions.length;
    const syncDisabled = syncing || regionsLoading || selected.size === 0;

    const toggleRegion = (regionId: string) => {
        setSelected((current) => {
            const next = new Set(current);
            if (next.has(regionId)) {
                next.delete(regionId);
            } else {
                next.add(regionId);
            }
            return next;
        });
    };

    const toggleAll = () => {
        setSelected((current) => (
            current.size === regions.length ? new Set() : new Set(regions.map((region) => region.regionId))
        ));
    };

    const handleSync = async () => {
        setErrorMessage(null);
        setResults(null);

        if (!jwtToken) {
            setErrorMessage("Error: JWT token not found");
            return;
        }
        if (regionsLoading) {
            setErrorMessage("Regions are still loading");
            return;
        }
        if (regionsError) {
            setErrorMessage(regionsError);
            return;
        }
        if (!regions.length) {
            setErrorMessage(<NoRegionsMessage />);
            return;
        }
        if (selected.size === 0) {
            setErrorMessage("Select at least one region to sync.");
            return;
        }

        setSyncing(true);
        const syncResults = await runRegionsSync([...selected], jwtToken);
        setResults(syncResults);
        setSyncing(false);
    };

    return (
        <div className="flex flex-col items-center min-h-screen bg-page px-4">
            <nav className="w-full bg-nav text-white p-4 shadow-md fixed top-0 left-0 flex justify-center items-center px-6 z-40">
                <FontAwesomeIcon
                    icon={faHouse}
                    onClick={() => navigate("/home")}
                    className="text-2xl cursor-pointer absolute left-6"
                />
                <h1 className="text-xl font-semibold align-self-center">Sync Region Clients</h1>
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

            {errorMessage && (
                <div className="fixed top-20 w-full flex justify-center z-50">
                    <div className="px-6 py-3 rounded-xl shadow-md w-full max-w-md flex justify-between items-center bg-danger text-white">
                        <span className="text-sm">{errorMessage}</span>
                        <button
                            className="ml-4 font-bold hover:text-white/70 transition"
                            onClick={() => setErrorMessage(null)}
                        >
                            ✕
                        </button>
                    </div>
                </div>
            )}

            <div className="w-full max-w-2xl mt-24 mb-10">
                <div className="bg-card p-6 rounded-2xl shadow-lg">
                    <h2 className="text-xl font-semibold text-content">Select regions to sync</h2>
                    <p className="mt-1 text-sm text-content-muted">
                        Each region reconciles its live WireGuard peers against Firebase and returns a
                        downloadable audit log. Sync is safe to re-run.
                    </p>

                    {(regionsLoading && !regions.length) && (
                        <p className="mt-4 text-sm text-content-muted">Loading regions...</p>
                    )}

                    {regions.length > 0 && (
                        <div className="mt-4">
                            <label className="flex items-center gap-2 border-b border-edge-faint pb-2 text-sm font-medium text-content-secondary">
                                <input type="checkbox" checked={allSelected} onChange={toggleAll} />
                                Select all
                            </label>
                            <div className="mt-2 flex flex-col gap-2">
                                {regions.map((region) => (
                                    <label key={region.regionId} className="flex items-center gap-2 text-sm text-content">
                                        <input
                                            type="checkbox"
                                            checked={selected.has(region.regionId)}
                                            onChange={() => toggleRegion(region.regionId)}
                                        />
                                        {region.displayName} <span className="text-content-muted">({region.regionId})</span>
                                    </label>
                                ))}
                            </div>
                        </div>
                    )}

                    <button
                        type="button"
                        onClick={handleSync}
                        disabled={syncDisabled}
                        className={`mt-5 w-full rounded-lg p-3 text-sm font-medium transition ${
                            !syncDisabled
                                ? "cursor-pointer bg-primary text-white hover:bg-primary-hover"
                                : "cursor-not-allowed bg-disabled text-content-disabled"
                        }`}
                    >
                        {syncing
                            ? "Syncing..."
                            : regionsLoading
                                ? "Loading regions..."
                                : selected.size > 0
                                ? `Sync ${selected.size} region${selected.size === 1 ? "" : "s"}`
                                : "Sync regions"}
                    </button>
                </div>

                {results && (
                    <div className="mt-6 flex flex-col gap-3">
                        {results.map(({ regionId, result }) => (
                            <RegionSyncCard
                                key={regionId}
                                regionId={regionId}
                                displayName={displayNameById.get(regionId)}
                                result={result}
                            />
                        ))}
                    </div>
                )}
            </div>

            {syncing && (
                <div className="fixed inset-0 w-full h-full bg-black/50 flex items-center justify-center z-50">
                    <div className="border-t-4 border-white border-solid rounded-full w-16 h-16 animate-spin"></div>
                </div>
            )}
        </div>
    );
};

export default SyncRegions;
