import React, { useCallback, useEffect, useRef, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import type { User } from "firebase/auth";
import { auth, onAuthStateChanged } from "../firebase";
import { decideDeviceRequest, parseDeviceApprovalRoute, verifyDeviceRequest } from "../helpers/deviceAuthHelper";
import type { DeviceAuthState, DeviceVerification } from "../helpers/deviceAuthHelper";

type ViewState = "loading" | "signed-out" | "ready" | "submitting" | "approved" | "denied" | "expired" | "consumed" | "throttled" | "invalid" | "error";
type Decision = "approve" | "deny";
type VerifiedContext = {
    routePath: string;
    userId: string;
    verification: DeviceVerification;
};

const getFailureState = (errorCode: string | undefined, status: number | undefined): ViewState => {
    if (errorCode?.startsWith("DEVICE_AUTH_")) {
        if (errorCode === "DEVICE_AUTH_EXPIRED" || status === 410) return "expired";
        if (errorCode === "DEVICE_AUTH_DENIED") return "denied";
        if (errorCode === "DEVICE_AUTH_CONSUMED") return "consumed";
        if (errorCode === "DEVICE_AUTH_THROTTLED" || status === 429) return "throttled";
        if (errorCode === "DEVICE_AUTH_INVALID" || errorCode === "DEVICE_AUTH_CONFLICT") return "invalid";
        if (errorCode === "DEVICE_AUTH_UNAVAILABLE" || status === 503) return "error";
    }
    if (status === 410) return "expired";
    if (status === 429) return "throttled";
    if (status === 400 || status === 409) return "invalid";
    return "error";
};

const stateMessage: Record<ViewState, string> = {
    loading: "Checking this device request…",
    "signed-out": "Sign in to verify the device request.",
    ready: "Review the details, then choose whether to approve this device.",
    submitting: "Saving your decision…",
    approved: "Device approved. You can return to it now.",
    denied: "This device request was denied.",
    expired: "This device request has expired. Start again on the device.",
    consumed: "This device request has already been used.",
    throttled: "Too many attempts. Wait before trying again.",
    invalid: "This device request is invalid or can no longer be changed.",
    error: "Unable to verify the device request. Try again later.",
};

const getDeviceState = (state: DeviceAuthState): ViewState => {
    if (state === "approved") return "approved";
    if (state === "denied") return "denied";
    if (state === "consumed") return "consumed";
    return "ready";
};

const isTopLevelWindow = (): boolean => {
    try {
        return typeof window !== "undefined" && window.top === window;
    } catch {
        return false;
    }
};

const DeviceApprovalPage: React.FC = () => {
    const navigate = useNavigate();
    const location = useLocation();
    const route = parseDeviceApprovalRoute(`/auth/code${location.search}`);
    const deviceRequestId = route?.deviceRequestId;
    const userCode = route?.userCode;
    const approvalPath = route?.path;
    const [viewState, setViewState] = useState<ViewState>(route ? "loading" : "invalid");
    const [viewPath, setViewPath] = useState<string | null>(route?.path || null);
    const [verifiedContext, setVerifiedContext] = useState<VerifiedContext | null>(null);
    const [user, setUser] = useState<User | null>(null);
    const [retryAfter, setRetryAfter] = useState<string | null>(null);
    const generationRef = useRef(0);
    const mountedRef = useRef(false);
    const submittingRef = useRef(false);
    const routeRef = useRef(route);
    const userRef = useRef(user);
    const verifiedContextRef = useRef(verifiedContext);
    const viewStateRef = useRef(viewState);
    routeRef.current = route;
    userRef.current = user;
    verifiedContextRef.current = verifiedContext;
    viewStateRef.current = viewState;
    const invalidateGeneration = useCallback(() => { generationRef.current += 1; }, []);

    useEffect(() => {
        mountedRef.current = true;
        let active = true;
        let observedUid: string | null | undefined;
        const unsubscribe = onAuthStateChanged(auth, (nextUser) => {
            if (!active) return;
            const nextUid = nextUser?.uid || null;
            if (observedUid === nextUid) return;
            observedUid = nextUid;
            const generation = ++generationRef.current;
            setUser(nextUser);
            setViewPath(approvalPath || null);
            setVerifiedContext(null);
            setRetryAfter(null);
            submittingRef.current = false;

            if (!deviceRequestId || !userCode || !approvalPath) {
                setViewState("invalid");
                return;
            }
            if (!nextUser) {
                setViewState("signed-out");
                navigate("/login", { replace: true, state: { returnTo: approvalPath } });
                return;
            }

            setViewState("loading");
            void (async () => {
                try {
                    const token = await nextUser.getIdToken();
                    if (
                        !active
                        || !mountedRef.current
                        || generationRef.current !== generation
                        || routeRef.current?.path !== approvalPath
                        || auth.currentUser?.uid !== nextUid
                    ) return;
                    const result = await verifyDeviceRequest(deviceRequestId, userCode, token);
                    if (
                        !active
                        || !mountedRef.current
                        || generationRef.current !== generation
                        || routeRef.current?.path !== approvalPath
                        || auth.currentUser?.uid !== nextUid
                    ) return;
                    if (!result.success) {
                        setRetryAfter(result.retryAfter || null);
                        setViewState(getFailureState(result.errorCode, result.status));
                        return;
                    }
                    setVerifiedContext({ routePath: approvalPath, userId: nextUid, verification: result.data });
                    setViewState(getDeviceState(result.data.state));
                } catch {
                    if (
                        active
                        && mountedRef.current
                        && generationRef.current === generation
                        && routeRef.current?.path === approvalPath
                        && auth.currentUser?.uid === nextUid
                    ) setViewState("error");
                }
            })();
        });

        return () => {
            active = false;
            mountedRef.current = false;
            invalidateGeneration();
            unsubscribe();
        };
    }, [navigate, location.search, deviceRequestId, userCode, approvalPath, invalidateGeneration]);

    const submitDecision = async (decision: Decision) => {
        const activeRoute = routeRef.current;
        const activeUser = userRef.current;
        const activeContext = verifiedContextRef.current;
        if (
            !activeRoute
            || !activeUser
            || !activeContext
            || activeContext.routePath !== activeRoute.path
            || activeContext.userId !== activeUser.uid
            || auth.currentUser?.uid !== activeUser.uid
            || viewStateRef.current !== "ready"
            || submittingRef.current
        ) return;
        submittingRef.current = true;
        const generation = generationRef.current;
        const routePath = activeRoute.path;
        const uid = activeUser.uid;
        const isCurrentAction = () => (
            mountedRef.current
            && generationRef.current === generation
            && routeRef.current?.path === routePath
            && userRef.current?.uid === uid
            && auth.currentUser?.uid === uid
        );
        setViewState("submitting");
        setRetryAfter(null);
        try {
            const token = await activeUser.getIdToken();
            if (!isCurrentAction()) return;
            const result = await decideDeviceRequest(activeRoute.deviceRequestId, activeRoute.userCode, decision, token);
            if (!isCurrentAction()) return;
            if (!result.success) {
                setRetryAfter(result.retryAfter || null);
                setViewState(getFailureState(result.errorCode, result.status));
                submittingRef.current = false;
                return;
            }
            setViewState(result.data.state === "approved" ? "approved" : "denied");
        } catch {
            if (isCurrentAction()) {
                setViewState("error");
                submittingRef.current = false;
            }
        }
    };

    const isCurrentVerification = Boolean(
        route
        && user
        && auth.currentUser?.uid === user.uid
        && verifiedContext?.routePath === route.path
        && verifiedContext.userId === user.uid,
    );
    const visibleViewState: ViewState = !route
        ? "invalid"
        : (viewPath !== route.path || (user && auth.currentUser?.uid !== user.uid))
            ? "loading"
            : viewState;
    const canDecide = isCurrentVerification && visibleViewState === "ready";
    const currentVerification = isCurrentVerification ? verifiedContext?.verification || null : null;

    return (
        <main className="flex min-h-screen items-center justify-center bg-page px-4 py-12">
            <section className="w-full max-w-lg rounded-2xl bg-card p-8 shadow-lg" aria-busy={visibleViewState === "loading" || visibleViewState === "submitting"}>
                <h1 className="mb-2 text-2xl font-semibold text-primary">Authorize a device</h1>
                <p role="status" className="mb-6 text-sm text-content-secondary">{stateMessage[visibleViewState]}</p>

                {user && auth.currentUser?.uid === user.uid && <p className="mb-4 text-sm text-content">Signed in as <strong>{user.email || user.uid}</strong></p>}
                {route && <p className="mb-4 text-sm text-content">Code: <strong className="font-mono tracking-widest">{route.userCode}</strong></p>}
                {currentVerification && (
                    <div className="mb-6 rounded-xl bg-inset p-4 text-sm text-content">
                        <p>Device: <strong>{currentVerification.deviceName || "Unspecified device"}</strong> <span className="text-content-secondary">(unverified description)</span></p>
                        <p className="mt-2">Request status: {currentVerification.state}</p>
                        <p className="mt-1">Expires: {new Date(currentVerification.expiresAt).toLocaleString()}</p>
                    </div>
                )}

                {canDecide && (
                    <div>
                        <p className="mb-4 text-sm text-content-secondary">Only approve if you started this request and this code matches the code on your device.</p>
                        <div className="flex gap-3">
                            <button type="button" className="rounded-lg bg-primary px-4 py-2 text-white" onClick={() => void submitDecision("approve")}>
                                Approve device
                            </button>
                            <button type="button" className="rounded-lg border border-edge px-4 py-2 text-content" onClick={() => void submitDecision("deny")}>
                                Deny device
                            </button>
                        </div>
                    </div>
                )}

                {visibleViewState === "throttled" && retryAfter && <p className="mt-3 text-sm text-content-secondary">Try again after {retryAfter}.</p>}
                {visibleViewState === "signed-out" && <button type="button" className="mt-2 rounded-lg bg-primary px-4 py-2 text-white" onClick={() => route && navigate("/login", { state: { returnTo: route.path } })}>Go to sign in</button>}
            </section>
        </main>
    );
};

const DeviceApproval: React.FC = () => {
    if (!isTopLevelWindow()) {
        return <p role="status">Open this page directly to authorize a device.</p>;
    }
    return <DeviceApprovalPage />;
};

export default DeviceApproval;
