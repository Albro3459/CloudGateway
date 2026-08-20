import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { RefreshCw } from "lucide-react";

import { auth, onAuthStateChanged } from "../firebase";
import { runRegionsSync } from "../helpers/APIHelper";
import type { RegionSyncResult } from "../helpers/APIHelper";
import { getAllRegionDocs, getMeshDocs, getPolicyDocs, setRegionMeshEnabled } from "../helpers/firebaseDbHelper";
import { getEnabledRegions, Region, sortRegions } from "../helpers/regionsHelper";
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
import { buildPolicyStatusRows, PolicyDocsById, PolicyRegionState } from "../helpers/policyHelper";

import { AppNav } from "../components/AppNav";
import { CopyableValue } from "../components/CopyableValue";
import { RegionSyncCard } from "../components/RegionSyncCard";
import { SyncRegionsConfirmModal } from "../components/SyncRegionsConfirmModal";

type Banner = {
    type: "error" | "success";
    message: string;
};

type NavigationState = {
    runSync?: boolean;
};

const MESH_WRITES_PENDING_HELP = "Waiting for mesh membership changes to save before syncing.";

type ToggleOverride = {
    enabled: boolean;
    revision: number;
};

type ClearOverride = {
    regionId: string;
    revision: number;
};

const regionLabel = (regionId: string, names: Map<string, string>): string => (
    names.get(regionId) || regionId
);

const linkRowClasses = (status: MeshLinkStatus): string => {
    if (status === "both-applied") return "border-success-soft-edge bg-success-soft text-success-strong";
    if (status === "stale") return "border-danger-soft-edge bg-danger-soft text-danger-content";
    if (status === "one-sided") return "border-warning-soft-edge bg-warning-soft text-warning-strong";
    return "border-edge-subtle bg-inset text-content-secondary";
};

// Drift and "unreadable" both get the more alarming danger treatment: drift
// is an integrity signal (the fleet's maps disagree) and an unreadable doc
// means client isolation status cannot be confirmed at all, unlike
// "never-synced" which just means the region hasn't completed a first pass.
// "disabled" gets the same neutral treatment as "never-synced": the region
// is intentionally excluded from comparison, not in a bad state.
const policyRowClasses = (state: PolicyRegionState): string => {
    if (state === "ok") return "border-success-soft-edge bg-success-soft text-success-strong";
    if (state === "drifted") return "border-danger-soft-edge bg-danger-soft text-danger-content";
    if (state === "unreadable") return "border-danger-soft-edge bg-danger-soft text-danger-content";
    return "border-edge-subtle bg-inset text-content-secondary";
};

const policyStateLabel = (state: PolicyRegionState): string => {
    if (state === "ok") return "OK";
    if (state === "drifted") return "Drifted";
    if (state === "unreadable") return "Unreadable";
    if (state === "disabled") return "Disabled";
    return "Never synced";
};

const sideLabel = (name: string, row: MeshLinkRow, side: "a" | "b"): string => {
    const stale = side === "a" ? row.aToBStale : row.bToAStale;
    const current = side === "a" ? row.aToBCurrent : row.bToACurrent;
    const status = side === "a" ? row.aToB : row.bToA;
    if (stale) return `${name} stale`;
    if (current) return `${name} applied`;
    return status ? `${name} ${status}` : `${name} not synced`;
};

const formatLinkRowLabel = (row: MeshLinkRow, names: Map<string, string>): string => {
    const aName = regionLabel(row.regionAId, names);
    const bName = regionLabel(row.regionBId, names);

    if (row.status === "both-applied") {
        return `${aName} ↔ ${bName} · both applied`;
    }
    if (row.status === "stale") {
        return `${aName} ↔ ${bName} · stale · ${sideLabel(aName, row, "a")}, ${sideLabel(bName, row, "b")}`;
    }
    if (row.status === "one-sided") {
        return `${aName} ↔ ${bName} · one-sided · ${sideLabel(aName, row, "a")}, ${sideLabel(bName, row, "b")}`;
    }
    return `${aName} ↔ ${bName} · not synced`;
};

const formatWarningReason = (status: "skipped-overlap" | "skipped-incomplete", reasonCode: string | null): string => {
    const reasons: Record<string, string> = {
        "invalid-endpoint-port": "endpoint port is invalid",
        "duplicate-public-key": "public key is duplicated by another region",
        "missing-public-key": "public key is missing",
        "invalid-public-key": "public key is invalid",
        "missing-endpoint-hostname": "endpoint hostname is missing",
        "invalid-endpoint-hostname": "endpoint hostname is invalid",
        "missing-network-v4": "tunnel IPv4 network is missing",
        "invalid-network-v4": "tunnel IPv4 network is invalid",
        "missing-network-v6": "tunnel IPv6 network is missing",
        "invalid-network-v6": "tunnel IPv6 network is invalid",
        "outside-aggregate": "tunnel network is outside the mesh aggregate",
        "local-network-invalid": "regional host local-network configuration rejects this tunnel network",
        "overlap-local": "claimed subnet overlaps the local region",
        "overlap-candidate": "claimed subnet overlaps another region",
    };
    if (reasonCode && reasons[reasonCode]) return reasons[reasonCode];
    return status === "skipped-overlap"
        ? "claimed subnet overlaps another region"
        : "mesh peer was skipped because required metadata is incomplete or invalid";
};

// Admin-only Server Health page: mesh membership toggles, link status derived
// from Mesh/* (durable, last-applied), account-scoped ACL status derived from
// Policy/* (observability-only, written after each region's policy reconcile
// pass), and per-region client-peer sync results (ephemeral, from the sync
// response). Reads/writes Regions, Mesh, and Policy directly from Firestore
// rather than through the API, since the API's /regions summary never
// carried mesh or policy fields.
const ServerHealth: React.FC = () => {
    const navigate = useNavigate();
    const location = useLocation();

    const [role, setRole] = useState<string | null>(null);
    const [jwtToken, setJwtToken] = useState<string | null>(null);
    const [banner, setBanner] = useState<Banner | null>(null);

    const [regions, setRegions] = useState<Region[] | null>(null);
    const [meshDocs, setMeshDocs] = useState<MeshDocsById>(new Map());
    const [policyDocs, setPolicyDocs] = useState<PolicyDocsById>(new Map());
    // Distinguishes "the Policy collection read itself failed" from "every
    // region legitimately has no Policy doc yet". Collapsing the two into one
    // empty map would render every region as never-synced during an outage,
    // which is a stronger and wrong claim than "status unknown right now".
    const [policyLoadFailed, setPolicyLoadFailed] = useState(false);
    const [dataLoading, setDataLoading] = useState(false);

    const [togglingRegionIds, setTogglingRegionIds] = useState<Set<string>>(new Set());
    // Presentation state above; the durable-write barrier below. togglingRegionIds
    // is cleared by auth lifecycle code (and by a superseded toggle) while a
    // Firestore write can still be unresolved, so it is not a barrier on its own.
    const [pendingMeshWriteCount, setPendingMeshWriteCount] = useState(0);

    const [syncModalOpen, setSyncModalOpen] = useState(false);
    const [syncing, setSyncing] = useState(false);
    const [syncResults, setSyncResults] = useState<RegionSyncResult[] | null>(null);
    const [syncError, setSyncError] = useState<string | null>(null);
    // A Sync All confirmed on Home must not be dropped when this page's own
    // Firestore load fails, so the run-now signal is held here until the data
    // it needs is available instead of being consumed by a one-shot effect.
    const [pendingRunSync, setPendingRunSync] = useState(false);

    const autoRunHandled = useRef(false);
    const mountedRef = useRef(false);
    const authGenerationRef = useRef(0);
    // undefined until the observer's first callback; null once signed out.
    const authSubjectRef = useRef<string | null | undefined>(undefined);
    const loadGenerationRef = useRef(0);
    // Unresolved setRegionMeshEnabled writes, keyed by region: Sync All must not
    // call a regional API while one is outstanding, because the optimistic
    // regions state already shows the new value while the host still reads the
    // old Firestore document.
    const pendingMeshWritesRef = useRef(new Map<string, Promise<boolean>>());
    // Latest committed regions/token for work that resumes after awaiting that
    // barrier, so a sync never targets a pre-barrier snapshot.
    const regionsRef = useRef<Region[] | null>(null);
    const jwtTokenRef = useRef<string | null>(null);
    const nextToggleRevisionRef = useRef(0);
    const toggleRevisionsRef = useRef(new Map<string, number>());
    const overridesRef = useRef(new Map<string, ToggleOverride>());

    const isCurrent = useCallback((authGeneration: number, loadGeneration?: number): boolean => (
        mountedRef.current
        && authGenerationRef.current === authGeneration
        && (loadGeneration === undefined || loadGenerationRef.current === loadGeneration)
    ), []);

    useEffect(() => {
        regionsRef.current = regions;
    }, [regions]);

    useEffect(() => {
        jwtTokenRef.current = jwtToken;
    }, [jwtToken]);

    // Registers a mesh-membership write for the barrier below. The tracked
    // promise never rejects (false means the write failed) and retires itself
    // before any awaiter resumes, so the registry cannot leak an entry.
    const trackMeshWrite = (regionId: string, write: Promise<void>): void => {
        const tracked: Promise<boolean> = write.then(() => true, () => false).finally(() => {
            if (pendingMeshWritesRef.current.get(regionId) === tracked) {
                pendingMeshWritesRef.current.delete(regionId);
                setPendingMeshWriteCount(pendingMeshWritesRef.current.size);
            }
        });
        pendingMeshWritesRef.current.set(regionId, tracked);
        setPendingMeshWriteCount(pendingMeshWritesRef.current.size);
    };

    // Resolves once no mesh-membership write from this session is unresolved.
    // Loops because a write can start while an earlier batch is being awaited.
    // false means at least one awaited write failed: the fleet is not in the
    // state the operator confirmed, so the sync intent is dropped.
    const awaitPendingMeshWrites = useCallback(async (): Promise<boolean> => {
        let allSucceeded = true;
        while (pendingMeshWritesRef.current.size > 0) {
            const settled = await Promise.all(Array.from(pendingMeshWritesRef.current.values()));
            if (settled.some(succeeded => !succeeded)) allSucceeded = false;
        }
        return allSucceeded;
    }, []);

    // Every region doc is rendered, including disabled ones: a disabled region
    // can still have a live peer installed on another host, and dropping it
    // from the page would make that stale peer unobservable. Only the sync
    // fan-out itself stays scoped to enabled regions.
    const allRegions = useMemo(() => regions ?? [], [regions]);
    const enabledRegions = useMemo(() => getEnabledRegions(regions), [regions]);
    const regionDisplayNames = useMemo(() => (
        new Map(allRegions.map(region => [region.regionId, region.displayName]))
    ), [allRegions]);
    const meshRegionLabels = useMemo(() => (
        new Map(allRegions.map(region => [
            region.regionId,
            region.enabled === true ? region.displayName : `${region.displayName} (disabled)`,
        ]))
    ), [allRegions]);
    const linkRows = useMemo(() => buildMeshLinkRows(allRegions, meshDocs), [allRegions, meshDocs]);
    const warnings = useMemo(() => collectMeshWarnings(meshDocs), [meshDocs]);
    const anyPending = useMemo(() => hasAnyMeshPending(allRegions, meshDocs), [allRegions, meshDocs]);
    const policyRows = useMemo(() => buildPolicyStatusRows(allRegions, policyDocs), [allRegions, policyDocs]);
    // Only the write registry gates Sync All. togglingRegionIds stays set for the
    // toggle's confirming read as well, and a sync is allowed to supersede that
    // read - what it must never do is run while the write itself is unresolved.
    const meshWritesPending = pendingMeshWriteCount > 0;

    const loadServerHealthData = useCallback(async (clearOverride?: ClearOverride): Promise<boolean> => {
        const loadGeneration = ++loadGenerationRef.current;
        const authGeneration = authGenerationRef.current;
        if (!mountedRef.current) return false;

        setDataLoading(true);
        try {
            // Policy/* is a separate, purely observational feed (account-scoped
            // ACL client isolation). A failure to read it must not blank the
            // Mesh cards or the rest of the page, so it is caught locally rather
            // than left to fail the Promise.all and take Regions/Mesh down with
            // it. The catch also has to carry a failed flag rather than just an
            // empty map: an empty PolicyDocsById is indistinguishable from every
            // region legitimately having no Policy doc yet, and collapsing a
            // fetch failure into that would render every region as "never
            // synced" during an outage instead of "status unknown".
            const policyPromise = getPolicyDocs().then(
                (docs) => ({ docs, failed: false }),
                (error): { docs: PolicyDocsById; failed: boolean } => {
                    console.error("Error loading policy data:", error);
                    return { docs: new Map(), failed: true };
                },
            );
            const [regionDocs, mesh, policyResult] = await Promise.all([
                getAllRegionDocs(),
                getMeshDocs(),
                policyPromise,
            ]);

            if (clearOverride) {
                // Retire this confirming read's own override as soon as it
                // resolves, whether or not it is still the load that gets to
                // render below. A later load (e.g. Sync All calling this same
                // function) can supersede this one before it resolves; if
                // retirement only ran on the rendering path, a superseded
                // confirming read would orphan its override and pin
                // meshEnabled client-side for the rest of the session.
                const activeOverride = overridesRef.current.get(clearOverride.regionId);
                if (activeOverride?.revision === clearOverride.revision) {
                    // This read started after the write landed, so its value is
                    // authoritative even when it disagrees — another admin may
                    // have flipped the same flag from another tab. Retiring the
                    // overlay regardless is what stops a stale one pinning the
                    // page for the rest of the session.
                    overridesRef.current.delete(clearOverride.regionId);
                }
            }

            if (!isCurrent(authGeneration, loadGeneration)) return false;

            const overlaidRegions = sortRegions(regionDocs).map(region => {
                const override = overridesRef.current.get(region.regionId);
                return override ? { ...region, meshEnabled: override.enabled } : region;
            });
            setRegions(overlaidRegions);
            setMeshDocs(mesh);
            setPolicyDocs(policyResult.docs);
            setPolicyLoadFailed(policyResult.failed);
            return true;
        } catch (error) {
            console.error("Error loading server health data:", error);
            if (clearOverride) {
                // The confirming read is the only thing that ever retires an
                // override. If it fails the override must expire anyway, or the
                // tab pins a stale meshEnabled for the whole auth generation
                // and can report "nothing pending" for a link that is not.
                const activeOverride = overridesRef.current.get(clearOverride.regionId);
                if (activeOverride?.revision === clearOverride.revision) {
                    overridesRef.current.delete(clearOverride.regionId);
                }
            }
            if (isCurrent(authGeneration, loadGeneration)) {
                setBanner({ type: "error", message: "Unable to load server health data." });
            }
            return false;
        } finally {
            if (isCurrent(authGeneration, loadGeneration)) {
                setDataLoading(false);
            }
        }
    }, [isCurrent]);

    const runSync = useCallback(async (regionIds: string[], token: string) => {
        const authGeneration = authGenerationRef.current;
        if (!mountedRef.current) return;
        setSyncing(true);
        setSyncError(null);
        try {
            const results = await runRegionsSync(regionIds, token);
            if (!isCurrent(authGeneration)) return;
            setSyncResults(results);
            // Mesh/* is durable state written by each host during its own sync
            // pass, so re-read it once the fan-out settles rather than trusting
            // the ephemeral response shape for link rendering.
            await loadServerHealthData();
        } catch (error) {
            console.error("Error syncing regions:", error);
            if (isCurrent(authGeneration)) setSyncError("Unable to sync regions.");
        } finally {
            if (isCurrent(authGeneration)) setSyncing(false);
        }
    }, [isCurrent, loadServerHealthData]);

    const handleToggleMesh = async (region: Region) => {
        if (!mountedRef.current) return;
        // The control is disabled for these, but the attribute alone does not
        // stop a synthetic change event, and Sync All could never apply it.
        if (region.enabled !== true) return;
        const next = region.meshEnabled !== true;
        const revision = ++nextToggleRevisionRef.current;
        const authGeneration = authGenerationRef.current;
        const previousValue = region.meshEnabled === true;
        toggleRevisionsRef.current.set(region.regionId, revision);
        overridesRef.current.set(region.regionId, { enabled: next, revision });
        // Any refresh already in flight must not commit over this optimistic
        // intent. The next accepted snapshot overlays the active override.
        ++loadGenerationRef.current;
        setTogglingRegionIds(prev => new Set(prev).add(region.regionId));
        setBanner(null);
        setRegions(prev => (prev ? prev.map(r => (r.regionId === region.regionId ? { ...r, meshEnabled: next } : r)) : prev));

        const isCurrentToggle = (): boolean => (
            isCurrent(authGeneration)
            && toggleRevisionsRef.current.get(region.regionId) === revision
        );

        try {
            // Started inside the try so a synchronous throw still rolls the
            // optimistic value back and clears the toggling flag.
            const write = setRegionMeshEnabled(region.regionId, next);
            trackMeshWrite(region.regionId, write);
            await write;
            if (!isCurrentToggle()) return;
            await loadServerHealthData({ regionId: region.regionId, revision });
        } catch (error) {
            console.error("Error updating mesh membership:", error);
            if (!isCurrentToggle()) return;
            overridesRef.current.delete(region.regionId);
            setRegions(prev => (prev
                ? prev.map(r => (r.regionId === region.regionId ? { ...r, meshEnabled: previousValue } : r))
                : prev));
            setBanner({ type: "error", message: `Unable to update ${region.displayName}.` });
            await loadServerHealthData();
        } finally {
            if (isCurrentToggle()) {
                setTogglingRegionIds(prev => {
                    const updated = new Set(prev);
                    updated.delete(region.regionId);
                    return updated;
                });
            }
        }
    };

    // The one entry point for a confirmed Sync All, used by this page's modal and
    // by the Home-originated pendingRunSync path. UI gating does not protect the
    // latter, so the barrier has to live here rather than on the button.
    const startConfirmedSync = useCallback(async (token: string) => {
        const subject = authSubjectRef.current;
        const writesSucceeded = await awaitPendingMeshWrites();
        if (!mountedRef.current) return;
        // A same-user observer callback bumps the auth generation without ending
        // the session, so it must not cancel a confirmed run; a real subject
        // change or sign-out must.
        if (authSubjectRef.current !== subject || (auth.currentUser?.uid ?? null) !== subject) return;
        if (!writesSucceeded) {
            setBanner({
                type: "error",
                message: "A mesh membership change did not save, so nothing was synced. Review the regions and sync again.",
            });
            return;
        }
        // A write that started while the barrier was draining.
        if (pendingMeshWritesRef.current.size > 0) return;
        // Same subject, so a token captured before the barrier still belongs to
        // this session; the refreshed one is preferred when the observer has
        // already published it.
        const currentToken = jwtTokenRef.current ?? token;
        // Only the acknowledged post-barrier membership decides the targets.
        await runSync(getEnabledRegions(regionsRef.current).map(region => region.regionId), currentToken);
    }, [awaitPendingMeshWrites, runSync]);

    const confirmSync = () => {
        setSyncModalOpen(false);
        if (!jwtToken) {
            // The modal is already closed by the time this runs, so this has to
            // land on the page banner rather than inside the dialog.
            setBanner({ type: "error", message: "Your session is not ready. Try again in a moment." });
            return;
        }
        void startConfirmedSync(jwtToken);
    };

    useEffect(() => {
        mountedRef.current = true;
        const authGenerationRefForCleanup = authGenerationRef;
        const loadGenerationRefForCleanup = loadGenerationRef;
        const unsubscribe = onAuthStateChanged(auth, (user) => {
            if (!mountedRef.current) return;
            const authGeneration = ++authGenerationRef.current;
            ++loadGenerationRef.current;
            toggleRevisionsRef.current.clear();
            overridesRef.current.clear();

            // Firebase delivers the first callback asynchronously, after the
            // effects that armed a Home-confirmed run. Only a real change of
            // subject retires that intent, so the first callback for the same
            // user cannot swallow it.
            const previousSubject = authSubjectRef.current;
            const subject = user?.uid ?? null;
            const subjectChanged = previousSubject !== undefined && previousSubject !== subject;
            authSubjectRef.current = subject;
            if (subjectChanged) autoRunHandled.current = false;

            // Reset all session-scoped controls and ephemeral results before
            // loading the new auth generation. Stale async work is rejected by
            // isCurrent and cannot restore the previous session's state.
            setRole(null);
            setJwtToken(null);
            setBanner(null);
            setRegions(null);
            setMeshDocs(new Map());
            setPolicyDocs(new Map());
            setPolicyLoadFailed(false);
            setDataLoading(false);
            setTogglingRegionIds(new Set());
            setSyncModalOpen(false);
            setSyncing(false);
            setSyncResults(null);
            setSyncError(null);
            if (subjectChanged) setPendingRunSync(false);

            const fetchUserData = async () => {
                if (!user) {
                    if (isCurrent(authGeneration) && !auth.currentUser) navigate("/", { replace: true });
                    return;
                }

                const userRole = await getUserRole(user);
                if (!isCurrent(authGeneration)) return;
                setRole(userRole);
                if (userRole !== "admin") {
                    navigate("/home", { replace: true });
                    return;
                }

                const token = await user.getIdToken();
                if (!isCurrent(authGeneration)) return;
                setJwtToken(token);
                await loadServerHealthData();
            };
            void fetchUserData();
        });
        return () => {
            mountedRef.current = false;
            ++authGenerationRefForCleanup.current;
            ++loadGenerationRefForCleanup.current;
            unsubscribe();
        };
    }, [navigate, isCurrent, loadServerHealthData]);

    // Home passes a "run now" signal via navigation state instead of starting
    // the fan-out itself, so the request survives the route change instead of
    // racing it. The signal is moved into state immediately and the navigation
    // state is cleared so a refresh or back-navigation doesn't re-trigger it.
    useEffect(() => {
        if (autoRunHandled.current) return;
        const state = location.state as NavigationState | null;
        if (!state?.runSync) return;

        autoRunHandled.current = true;
        navigate(location.pathname, { replace: true, state: {} });
        setPendingRunSync(true);
    }, [location, navigate]);

    // Held separately from the signal above so a failed Firestore load only
    // delays the confirmed run instead of discarding it. The unavailable card
    // says so explicitly, and a successful retry starts it.
    useEffect(() => {
        if (!pendingRunSync || !jwtToken || regions === null) return;
        setPendingRunSync(false);
        void startConfirmedSync(jwtToken);
    }, [pendingRunSync, jwtToken, regions, startConfirmedSync]);

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

            {regions === null ? (
                <div className="mb-4 w-full max-w-7xl rounded-lg bg-card p-6 text-sm text-content-muted shadow-lg">
                    {dataLoading ? "Loading server health data..." : (
                        <>
                            <p>Server health data is unavailable.</p>
                            {pendingRunSync && (
                                <p className="mt-2 text-warning-strong">
                                    The Sync All Regions you confirmed has not run yet. It starts as soon as region data loads.
                                </p>
                            )}
                            {/* The nav Refresh button is hidden below sm and this
                                page has no pull-to-refresh, so retry has to live
                                in the card itself. */}
                            <button
                                type="button"
                                onClick={() => void loadServerHealthData()}
                                className="mt-3 cursor-pointer rounded-lg bg-primary px-5 py-3 text-sm font-semibold text-white transition hover:bg-primary-hover"
                            >
                                Try again
                            </button>
                        </>
                    )}
                </div>
            ) : (
                <>
            <div className="mb-4 w-full max-w-7xl rounded-lg bg-card p-4 shadow-lg md:p-6">
                <div className="flex flex-wrap items-center justify-between gap-3">
                    <div>
                        <h2 className="text-xl font-semibold text-content">Server Health</h2>
                        <p className="mt-1 text-sm text-content-muted">Mesh membership, link status, and client peer sync per region.</p>
                        <p className="mt-1 text-xs text-content-muted">Mesh status reflects durable configuration snapshots only; it does not prove a handshake or traffic reachability.</p>
                    </div>
                    <button
                        type="button"
                        onClick={() => setSyncModalOpen(true)}
                        // Deliberately not gated on dataLoading: the fan-out does
                        // not depend on the read, and greying the page's primary
                        // action out on every background refresh is unexplainable.
                        // Unsaved mesh membership is different: syncing then would
                        // send the regional APIs a membership Firestore has not
                        // acknowledged yet.
                        disabled={syncing || !enabledRegions.length || meshWritesPending}
                        title={meshWritesPending
                            ? MESH_WRITES_PENDING_HELP
                            : (enabledRegions.length ? undefined : "No enabled regions to sync.")}
                        className={`flex cursor-pointer items-center justify-center gap-2 rounded-lg px-5 py-3 text-sm font-semibold text-white transition hover:bg-primary-hover disabled:cursor-not-allowed disabled:bg-disabled disabled:text-content-disabled ${
                            anyPending ? "bg-primary ring-2 ring-warning-strong" : "bg-primary"
                        }`}
                    >
                        <RefreshCw className={syncing ? "animate-spin" : ""} size={18} aria-hidden="true" />
                        {syncing ? "Syncing..." : "Sync All Regions"}
                    </button>
                </div>
                {meshWritesPending && (
                    <p role="status" className="mt-2 text-xs text-content-muted">{MESH_WRITES_PENDING_HELP}</p>
                )}
                {anyPending && (
                    <p className="mt-2 text-sm text-warning-strong">Pending mesh changes - run Sync All Regions to apply them.</p>
                )}
            </div>

            <div className="mb-4 w-full max-w-7xl rounded-lg bg-card p-4 shadow-lg md:p-6">
                <h3 className="text-sm font-semibold uppercase tracking-wide text-content-secondary">Mesh membership</h3>
                <div className="mt-3 flex flex-wrap gap-3">
                    {allRegions.map((region) => {
                        const meshDoc = meshDocs.get(region.regionId) ?? null;
                        const pending = isRegionMeshPending(region, meshDoc);
                        const staleness = getMeshStaleness(meshDoc?.updatedAt ?? null);
                        const disabled = region.enabled !== true;
                        const toggling = togglingRegionIds.has(region.regionId);
                        const stateId = `mesh-state-${region.regionId}`;
                        const pendingId = `mesh-pending-${region.regionId}`;
                        const freshnessId = `mesh-freshness-${region.regionId}`;
                        // aria-label wins the accessible name, so the pending and
                        // freshness text has to be attached as a description or a
                        // screen reader never hears the part that matters.
                        const describedBy = [
                            disabled ? stateId : null,
                            pending ? pendingId : null,
                            freshnessId,
                        ].filter(Boolean).join(" ");

                        return (
                            <label
                                key={region.regionId}
                                className="flex items-center gap-3 rounded-lg border border-edge-faint bg-inset px-3 py-2 text-sm text-content"
                            >
                                <input
                                    type="checkbox"
                                    checked={region.meshEnabled === true}
                                    onChange={() => void handleToggleMesh(region)}
                                    // Sync All only targets enabled regions, so a
                                    // toggle here could never be applied.
                                    disabled={toggling || disabled}
                                    className="h-4 w-4 accent-primary"
                                    aria-label={`Mesh enabled for ${region.displayName}`}
                                    aria-describedby={describedBy}
                                    aria-busy={toggling}
                                />
                                <span>
                                    <span className="block font-medium">{region.displayName}</span>
                                    {disabled && (
                                        <span id={stateId} className="mt-1 inline-block rounded bg-inset-strong px-1.5 py-0.5 text-xs font-semibold text-content-secondary">
                                            Disabled
                                        </span>
                                    )}
                                    {pending && (
                                        <span id={pendingId} className="block text-xs text-warning-strong">Pending</span>
                                    )}
                                    <span id={freshnessId} className="block text-xs text-content-muted">
                                        {meshDoc?.updatedAt
                                            ? `Last applied ${meshDoc.updatedAt.toLocaleString()}${staleness === "stale" ? " (stale)" : ""}`
                                            : "Never synced"}
                                    </span>
                                </span>
                            </label>
                        );
                    })}
                    {!allRegions.length && (
                        <p className="text-sm text-content-muted">No regions.</p>
                    )}
                </div>
            </div>

            <div className="mb-4 w-full max-w-7xl rounded-lg bg-card p-4 shadow-lg md:p-6">
                <h3 className="text-xl font-semibold text-content">Mesh</h3>
                {linkRows.length === 0 ? (
                    <p className="mt-2 text-sm text-content-muted">Add another region to form mesh links.</p>
                ) : (
                    <ul className="mt-3 space-y-2">
                        {linkRows.map((row) => (
                            <li
                                key={`${row.regionAId}-${row.regionBId}`}
                                className={`rounded-lg border px-3 py-2 text-sm ${linkRowClasses(row.status)}`}
                            >
                                {formatLinkRowLabel(row, meshRegionLabels)}
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
                                    {regionLabel(warning.regionId, meshRegionLabels)} skipped {regionLabel(warning.peerRegionId, meshRegionLabels)}: {formatWarningReason(warning.status, warning.reasonCode)}{warning.reasonCode ? ` [${warning.reasonCode}]` : ""}
                                </li>
                            ))}
                        </ul>
                    </div>
                )}
            </div>

            <div className="mb-4 w-full max-w-7xl rounded-lg bg-card p-4 shadow-lg md:p-6">
                <h3 className="text-xl font-semibold text-content">Client isolation</h3>
                <p className="mt-1 text-xs text-content-muted">
                    Account-scoped ACL status, read back from each region&apos;s live nftables map. Row counts and
                    hashes only - never uids, emails, client names, or addresses. Drift is visible without running
                    a sync.
                </p>
                <p className="mt-1 text-xs text-content-muted">
                    This dashboard has no role mutation. A trusted out-of-band <code>UserRoles</code> edit only
                    reaches the fleet after an admin runs Sync All Regions.
                </p>
                {policyLoadFailed ? (
                    // A collection-level read failure gets its own card rather than
                    // falling through to the per-region grid: with no docs to work
                    // from, every row would render "Never synced", which asserts a
                    // fleet state we don't actually know and looks nothing like an
                    // outage.
                    <div className="mt-3 rounded-lg border border-danger-soft-edge bg-danger-soft px-4 py-3 text-sm text-danger-content">
                        Unable to load client isolation status. This is a read failure, not a report that no
                        region has completed a policy reconcile.
                    </div>
                ) : (
                    <div className="mt-3 flex flex-wrap gap-3">
                        {policyRows.map((row) => (
                            <div
                                key={row.regionId}
                                className={`min-w-64 rounded-lg border px-3 py-2 text-sm ${policyRowClasses(row.state)}`}
                            >
                                <div className="flex items-center justify-between gap-2">
                                    <span className="font-medium">{regionLabel(row.regionId, regionDisplayNames)}</span>
                                    <span className="text-xs font-semibold uppercase tracking-wide">{policyStateLabel(row.state)}</span>
                                </div>
                                {row.state === "disabled" && (
                                    <p className="mt-1 text-xs">Region disabled - excluded from the fleet comparison.</p>
                                )}
                                {row.state === "never-synced" && (
                                    <p className="mt-1 text-xs">No policy reconcile has completed for this region yet.</p>
                                )}
                                {row.state === "unreadable" && (
                                    <p className="mt-1 text-xs">Policy status could not be read for this region.</p>
                                )}
                                {row.state === "drifted" && (
                                    <p className="mt-1 text-xs">
                                        {row.driftedV4 && row.driftedV6
                                            ? "IPv4 and IPv6 maps differ from the fleet."
                                            : row.driftedV4
                                                ? "IPv4 map differs from the fleet."
                                                : "IPv6 map differs from the fleet."}
                                    </p>
                                )}
                                {row.doc && (
                                    <>
                                        <p className="mt-1 text-xs">{row.doc.rowCount ?? "-"} rows</p>
                                        <p className="text-xs">
                                            {row.doc.updatedAt ? `Last applied ${row.doc.updatedAt.toLocaleString()}` : "-"}
                                        </p>
                                        <div className="mt-2 flex flex-wrap gap-2">
                                            <CopyableValue
                                                value={row.doc.mapHashV4}
                                                label={`${regionLabel(row.regionId, regionDisplayNames)} comprehensive IPv4 policy hash`}
                                                className="max-w-[9rem]"
                                            />
                                            <CopyableValue
                                                value={row.doc.mapHashV6}
                                                label={`${regionLabel(row.regionId, regionDisplayNames)} comprehensive IPv6 policy hash`}
                                                className="max-w-[9rem]"
                                            />
                                        </div>
                                    </>
                                )}
                            </div>
                        ))}
                        {!policyRows.length && (
                            <p className="text-sm text-content-muted">No regions.</p>
                        )}
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
                onConfirm={confirmSync}
                onClose={() => setSyncModalOpen(false)}
                confirmDisabled={meshWritesPending}
                confirmDisabledReason={MESH_WRITES_PENDING_HELP}
            />
                </>
            )}
        </div>
    );
};

export default ServerHealth;
