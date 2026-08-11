import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { RefreshCw } from "lucide-react";

import { auth, onAuthStateChanged } from "../firebase";
import { runRegionsSync } from "../helpers/APIHelper";
import type { RegionSyncResult } from "../helpers/APIHelper";
import { getAllRegionDocs, getMeshDocs, logout, setRegionMeshEnabled } from "../helpers/firebaseDbHelper";
import { getEnabledRegions, Region } from "../helpers/regionsHelper";
import { getUserRole } from "../helpers/usersHelper";
import {
    buildMeshLinkRows,
    collectMeshWarnings,
    getMeshStaleness,
    hasAnyMeshPending,
    isRegionMeshPending,
    MeshDocsById,
    MeshLinkRow,
    MeshLinkStatus,
} from "../helpers/meshHelper";

import { AppNav } from "../components/AppNav";
import { RegionSyncCard } from "../components/RegionSyncCard";
import { SyncRegionsConfirmModal } from "../components/SyncRegionsConfirmModal";

type Banner = {
    type: "error" | "success";
    message: string;
};

type NavigationState = {
    runSync?: boolean;
};

const regionLabel = (regionId: string, names: Map<string, string>): string => (
    names.get(regionId) || regionId
);

const linkRowClasses = (status: MeshLinkStatus): string => {
    if (status === "both-applied") return "border-success-soft-edge bg-success-soft text-success-strong";
    if (status === "one-sided") return "border-warning-soft-edge bg-warning-soft text-warning-strong";
    return "border-edge-subtle bg-inset text-content-secondary";
};

const sideLabel = (name: string, status: MeshLinkRow["aToB"]): string => (
    status === "applied" ? `${name} applied` : `${name} not synced`
);

const formatLinkRowLabel = (row: MeshLinkRow, names: Map<string, string>): string => {
    const aName = regionLabel(row.regionAId, names);
    const bName = regionLabel(row.regionBId, names);

    if (row.status === "both-applied") {
        return `${aName} ↔ ${bName} · both applied`;
    }
    if (row.status === "one-sided") {
        return `${aName} ↔ ${bName} · one-sided · ${sideLabel(aName, row.aToB)}, ${sideLabel(bName, row.bToA)}`;
    }
    return `${aName} ↔ ${bName} · not synced`;
};

const formatWarningReason = (status: "skipped-overlap" | "skipped-incomplete"): string => (
    status === "skipped-overlap" ? "claimed subnet overlaps another region" : "region doc is missing required mesh fields"
);

// Admin-only Server Health page: mesh membership toggles, link status derived
// from Mesh/* (durable, last-applied), and per-region client-peer sync
// results (ephemeral, from the sync response). Reads/writes Regions and
// Mesh directly from Firestore rather than through the API, since the API's
// /regions summary never carried mesh fields.
const ServerHealth: React.FC = () => {
    const navigate = useNavigate();
    const location = useLocation();

    const [role, setRole] = useState<string | null>(null);
    const [jwtToken, setJwtToken] = useState<string | null>(null);
    const [banner, setBanner] = useState<Banner | null>(null);

    const [regions, setRegions] = useState<Region[] | null>(null);
    const [meshDocs, setMeshDocs] = useState<MeshDocsById>(new Map());
    const [dataLoading, setDataLoading] = useState(false);

    const [togglingRegionIds, setTogglingRegionIds] = useState<Set<string>>(new Set());

    const [syncModalOpen, setSyncModalOpen] = useState(false);
    const [syncing, setSyncing] = useState(false);
    const [syncResults, setSyncResults] = useState<RegionSyncResult[] | null>(null);
    const [syncError, setSyncError] = useState<string | null>(null);

    const autoRunHandled = useRef(false);

    const enabledRegions = useMemo(() => getEnabledRegions(regions), [regions]);
    const regionDisplayNames = useMemo(() => (
        new Map(enabledRegions.map(region => [region.regionId, region.displayName]))
    ), [enabledRegions]);
    const linkRows = useMemo(() => buildMeshLinkRows(enabledRegions, meshDocs), [enabledRegions, meshDocs]);
    const warnings = useMemo(() => collectMeshWarnings(meshDocs), [meshDocs]);
    const anyPending = useMemo(() => hasAnyMeshPending(enabledRegions, meshDocs), [enabledRegions, meshDocs]);

    const loadServerHealthData = useCallback(async () => {
        setDataLoading(true);
        try {
            const [regionDocs, mesh] = await Promise.all([getAllRegionDocs(), getMeshDocs()]);
            setRegions(regionDocs);
            setMeshDocs(mesh);
        } catch (error) {
            console.error("Error loading server health data:", error);
            setBanner({ type: "error", message: "Unable to load server health data." });
        } finally {
            setDataLoading(false);
        }
    }, []);

    const runSync = useCallback(async (regionIds: string[], token: string) => {
        setSyncing(true);
        setSyncError(null);
        try {
            const results = await runRegionsSync(regionIds, token);
            setSyncResults(results);
            // Mesh/* is durable state written by each host during its own sync
            // pass, so re-read it once the fan-out settles rather than trusting
            // the ephemeral response shape for link rendering.
            await loadServerHealthData();
        } catch (error) {
            console.error("Error syncing regions:", error);
            setSyncError("Unable to sync regions.");
        } finally {
            setSyncing(false);
        }
    }, [loadServerHealthData]);

    const handleToggleMesh = async (region: Region) => {
        const next = region.meshEnabled !== true;
        setTogglingRegionIds(prev => new Set(prev).add(region.regionId));
        setBanner(null);
        setRegions(prev => (prev ? prev.map(r => (r.regionId === region.regionId ? { ...r, meshEnabled: next } : r)) : prev));

        try {
            await setRegionMeshEnabled(region.regionId, next);
        } catch (error) {
            console.error("Error updating mesh membership:", error);
            setBanner({ type: "error", message: `Unable to update ${region.displayName}.` });
            setRegions(prev => (prev ? prev.map(r => (r.regionId === region.regionId ? { ...r, meshEnabled: !next } : r)) : prev));
        } finally {
            setTogglingRegionIds(prev => {
                const updated = new Set(prev);
                updated.delete(region.regionId);
                return updated;
            });
        }
    };

    const confirmSync = () => {
        setSyncModalOpen(false);
        if (!jwtToken) {
            setSyncError("Your session is not ready. Try again in a moment.");
            return;
        }
        void runSync(enabledRegions.map(region => region.regionId), jwtToken);
    };

    useEffect(() => {
        const unsubscribe = onAuthStateChanged(auth, (user) => {
            const fetchUserData = async () => {
                if (!user) {
                    await logout(navigate);
                    return;
                }

                const userRole = await getUserRole(user);
                setRole(userRole);
                if (userRole !== "admin") {
                    navigate("/home", { replace: true });
                    return;
                }

                setJwtToken(await user.getIdToken());
                await loadServerHealthData();
            };
            void fetchUserData();
        });
        return () => unsubscribe();
    }, [navigate, loadServerHealthData]);

    // Home passes a "run now" signal via navigation state instead of starting
    // the fan-out itself, so the request survives the route change instead of
    // racing it. Runs once data is ready, then clears the signal so a refresh
    // or back-navigation doesn't re-trigger it.
    useEffect(() => {
        if (autoRunHandled.current) return;
        const state = location.state as NavigationState | null;
        if (!state?.runSync) return;
        if (!jwtToken || regions === null) return;

        autoRunHandled.current = true;
        navigate(location.pathname, { replace: true, state: {} });
        void runSync(enabledRegions.map(region => region.regionId), jwtToken);
    }, [location, jwtToken, regions, enabledRegions, navigate, runSync]);

    if (role !== "admin") {
        return (
            <div className="flex min-h-screen flex-col items-center bg-page px-4 pt-24">
                <AppNav subtitle="Server Health" homePath="/home" />
                <p className="mt-16 text-sm text-content-muted">Loading...</p>
            </div>
        );
    }

    return (
        <div className="flex min-h-screen flex-col items-center bg-page px-4 pb-20 pt-24">
            <AppNav
                subtitle="Server Health"
                homePath="/home"
                back
                onRefresh={() => void loadServerHealthData()}
                refreshDisabled={dataLoading}
                refreshing={dataLoading}
            />

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

            <div className="mb-4 w-full max-w-7xl rounded-lg bg-card p-4 shadow-lg md:p-6">
                <div className="flex flex-wrap items-center justify-between gap-3">
                    <div>
                        <h2 className="text-xl font-semibold text-content">Server Health</h2>
                        <p className="mt-1 text-sm text-content-muted">Mesh membership, link status, and client peer sync per region.</p>
                    </div>
                    <button
                        type="button"
                        onClick={() => setSyncModalOpen(true)}
                        disabled={syncing || dataLoading || !enabledRegions.length}
                        className={`flex cursor-pointer items-center justify-center gap-2 rounded-lg px-5 py-3 text-sm font-semibold text-white transition hover:bg-primary-hover disabled:cursor-not-allowed disabled:bg-disabled disabled:text-content-disabled ${
                            anyPending ? "bg-primary ring-2 ring-warning-strong" : "bg-primary"
                        }`}
                    >
                        <RefreshCw className={syncing ? "animate-spin" : ""} size={18} aria-hidden="true" />
                        {syncing ? "Syncing..." : "Sync All Regions"}
                    </button>
                </div>
                {anyPending && (
                    <p className="mt-2 text-sm text-warning-strong">Pending mesh changes - run Sync All Regions to apply them.</p>
                )}
            </div>

            <div className="mb-4 w-full max-w-7xl rounded-lg bg-card p-4 shadow-lg md:p-6">
                <h3 className="text-sm font-semibold uppercase tracking-wide text-content-secondary">Mesh membership</h3>
                <div className="mt-3 flex flex-wrap gap-3">
                    {enabledRegions.map((region) => {
                        const meshDoc = meshDocs.get(region.regionId) ?? null;
                        const pending = isRegionMeshPending(region, meshDoc);
                        const staleness = getMeshStaleness(meshDoc?.updatedAt ?? null);

                        return (
                            <label
                                key={region.regionId}
                                className="flex items-center gap-3 rounded-lg border border-edge-faint bg-inset px-3 py-2 text-sm text-content"
                            >
                                <input
                                    type="checkbox"
                                    checked={region.meshEnabled === true}
                                    onChange={() => void handleToggleMesh(region)}
                                    disabled={togglingRegionIds.has(region.regionId)}
                                    className="h-4 w-4 accent-primary"
                                    aria-label={`Mesh enabled for ${region.displayName}`}
                                />
                                <span>
                                    <span className="block font-medium">{region.displayName}</span>
                                    {pending && (
                                        <span className="block text-xs text-warning-strong">Pending</span>
                                    )}
                                    <span className="block text-xs text-content-muted">
                                        {meshDoc?.updatedAt
                                            ? `Last applied ${meshDoc.updatedAt.toLocaleString()}${staleness === "stale" ? " (stale)" : ""}`
                                            : "Never synced"}
                                    </span>
                                </span>
                            </label>
                        );
                    })}
                    {!enabledRegions.length && (
                        <p className="text-sm text-content-muted">No enabled regions.</p>
                    )}
                </div>
            </div>

            <div className="mb-4 w-full max-w-7xl rounded-lg bg-card p-4 shadow-lg md:p-6">
                <h3 className="text-xl font-semibold text-content">Mesh</h3>
                {linkRows.length === 0 ? (
                    <p className="mt-2 text-sm text-content-muted">Add another enabled region to form mesh links.</p>
                ) : (
                    <ul className="mt-3 space-y-2">
                        {linkRows.map((row) => (
                            <li
                                key={`${row.regionAId}-${row.regionBId}`}
                                className={`rounded-lg border px-3 py-2 text-sm ${linkRowClasses(row.status)}`}
                            >
                                {formatLinkRowLabel(row, regionDisplayNames)}
                                {row.pending && <span className="ml-2 text-xs italic">(pending)</span>}
                            </li>
                        ))}
                    </ul>
                )}

                {warnings.length > 0 && (
                    <div className="mt-4 rounded-lg border border-warning-soft-edge bg-warning-soft p-3">
                        <h4 className="text-sm font-semibold text-warning-strong">Warnings</h4>
                        <ul className="mt-2 space-y-1 text-sm text-warning-strong">
                            {warnings.map((warning, index) => (
                                <li key={`${warning.regionId}-${warning.peerRegionId}-${index}`}>
                                    {regionLabel(warning.regionId, regionDisplayNames)} skipped {regionLabel(warning.peerRegionId, regionDisplayNames)}: {formatWarningReason(warning.status)}
                                </li>
                            ))}
                        </ul>
                    </div>
                )}
            </div>

            <div className="mb-4 w-full max-w-7xl rounded-lg bg-card p-4 shadow-lg md:p-6">
                <h3 className="text-xl font-semibold text-content">Client peer sync</h3>
                {syncError && (
                    <div className="mt-3 rounded-lg border border-danger-soft-edge bg-danger-soft px-4 py-3 text-sm text-danger-content">
                        {syncError}
                    </div>
                )}
                {!syncResults ? (
                    <p className="mt-2 text-sm text-content-muted">Run Sync All Regions to see live results.</p>
                ) : (
                    <div className="mt-3 space-y-3">
                        {syncResults.map(({ regionId, result }) => (
                            <RegionSyncCard
                                key={regionId}
                                regionId={regionId}
                                displayName={regionDisplayNames.get(regionId)}
                                result={result}
                            />
                        ))}
                    </div>
                )}
            </div>

            <SyncRegionsConfirmModal
                open={syncModalOpen}
                regions={enabledRegions.map(region => ({ regionId: region.regionId, displayName: region.displayName }))}
                syncing={syncing}
                error={syncError}
                onConfirm={confirmSync}
                onClose={() => setSyncModalOpen(false)}
            />
        </div>
    );
};

export default ServerHealth;
