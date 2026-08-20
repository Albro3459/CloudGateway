import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { saveAs } from "file-saver";
import { Eye, EyeOff, KeyRound, Link, LogOut, RefreshCw, Trash2, UserCircle, UserPlus, X } from "lucide-react";
import QRCode from "qrcode";
import packageJson from "../../package.json";

import { createAdminUser, createClient, deleteAccount, deleteClient } from "../helpers/APIHelper";
import type { ApiHelperFailure } from "../helpers/APIHelper";
import { appleProvider, auth, EmailAuthProvider, googleProvider, linkWithCredential, linkWithPopup, onAuthStateChanged, reauthenticateWithCredential, reauthenticateWithPopup } from "../firebase";
import { getEnabledRegions, getRegionCapacityLabel, getRegionName, isRegionAtCapacity, isRegionCapacityKnown, resolveActiveRegionId } from "../helpers/regionsHelper";
import { getUserRole } from "../helpers/usersHelper";

import { CopyableValue } from "../components/CopyableValue";
import { NoRegionsMessage, SUPPORT_EMAIL } from "../components/AccessMessages";
import { AppNav } from "../components/AppNav";
import { SyncRegionsConfirmModal } from "../components/SyncRegionsConfirmModal";
import { VPNTable, VPNTableEntry } from "../components/VPNTable";
import { getUsersVPNs, logout, VPNData } from "../helpers/firebaseDbHelper";
import { User } from "firebase/auth";
import { fetchOciRegions, useOciRegionsStore } from "../stores/ociRegionsStore";
import { VPN_STATUS } from "../helpers/vpnStatus";
import { filterVisibleVPNClients, getClientKey } from "../helpers/vpnVisibility";
import { stripCidr } from "../helpers/ipHelper";
import { useModalDialog } from "../hooks/useModalDialog";

type Banner = {
    type: "error" | "success";
    message: string;
};

const PULL_REFRESH_THRESHOLD = 72;
const PULL_REFRESH_MAX_DISTANCE = 96;
// Link order per the provider-ordering standard: email & password, Apple, Google.
const ALL_AUTH_PROVIDER_IDS = ["password", "apple.com", "google.com"] as const;

type AuthProviderId = typeof ALL_AUTH_PROVIDER_IDS[number];

type CurrentSession<TInput> = {
    authGeneration: number;
    uid: string;
    user: User;
    token: string | null;
    input: TInput;
};

type DeleteAccountInput = {
    password: string;
    providerIds: string[];
};

type LinkProviderInput = {
    providerId: AuthProviderId;
    email: string;
    password: string;
    currentPassword: string;
    providerIds: string[];
};

const getProviderLabel = (providerId: AuthProviderId) => {
    if (providerId === "password") return "Email and password";
    if (providerId === "apple.com") return "Apple";
    return "Google";
};

const Home: React.FC = () => {
    const navigate = useNavigate();

    const [loading, setLoading] = useState(false);
    const [banner, setBanner] = useState<Banner | null>(null);
    const [accountMenuOpen, setAccountMenuOpen] = useState(false);
    const [deleteAccountModalOpen, setDeleteAccountModalOpen] = useState(false);
    const [deleteAccountPassword, setDeleteAccountPassword] = useState("");
    const [deleteAccountError, setDeleteAccountError] = useState<string | null>(null);
    const [deletingAccount, setDeletingAccount] = useState(false);
    const [linkedProviderIds, setLinkedProviderIds] = useState<string[]>([]);
    const [linkAccountModalOpen, setLinkAccountModalOpen] = useState(false);
    const [linkEmail, setLinkEmail] = useState("");
    const [linkPassword, setLinkPassword] = useState("");
    const [showLinkPassword, setShowLinkPassword] = useState(false);
    const [linkCurrentPassword, setLinkCurrentPassword] = useState("");
    const [linkingProviderId, setLinkingProviderId] = useState<AuthProviderId | null>(null);
    const [linkError, setLinkError] = useState<string | null>(null);
    const [linkRequiresPasswordReauth, setLinkRequiresPasswordReauth] = useState(false);

    const [role, setRole] = useState<string | null>(null);
    const [jwtToken, setJwtToken] = useState<string | null>(null);
    const [grantAccessModalOpen, setGrantAccessModalOpen] = useState(false);
    const [grantAccessEmail, setGrantAccessEmail] = useState("");
    const [grantingAccess, setGrantingAccess] = useState(false);
    const [grantAccessError, setGrantAccessError] = useState<string | null>(null);
    const [grantAccessSuccess, setGrantAccessSuccess] = useState<string | null>(null);
    const [syncRegionsModalOpen, setSyncRegionsModalOpen] = useState(false);

    const { ociRegions, loading: regionsLoading, error: regionsError } = useOciRegionsStore();
    const enabledRegions = useMemo(() => getEnabledRegions(ociRegions), [ociRegions]);
    const initialRegionsLoading = ociRegions === null && !regionsError;

    const [activeRegionId, setActiveRegionId] = useState("");
    const selectedRegion = enabledRegions.find(r => r.regionId === activeRegionId) || null;
    const selectedRegionCapacityKnown = isRegionCapacityKnown(selectedRegion);
    const selectedRegionFull = isRegionAtCapacity(selectedRegion);
    const selectedRegionCreationBlocked = !selectedRegionCapacityKnown || selectedRegionFull;

    const [clientName, setClientName] = useState("");
    const [VPNTableEntries, setVPNTableEntries] = useState<VPNTableEntry[] | null>(null);
    const [selectedClientKeys, setSelectedClientKeys] = useState<Set<string>>(new Set());
    const [vpnRegion, setVpnRegion] = useState<string | null>(null);
    const [activeConfigClientName, setActiveConfigClientName] = useState<string | null>(null);
    const [activeConfigEndpoint, setActiveConfigEndpoint] = useState<string | null>(null);
    const [activeConfigTunnelIp, setActiveConfigTunnelIp] = useState<string | null>(null);
    const [configData, setConfigData] = useState<string | null>(null);
    const [configCopied, setConfigCopied] = useState(false);
    const [pullDistance, setPullDistance] = useState(0);
    const [pullRefreshing, setPullRefreshing] = useState(false);
    const canvasRef = useRef<HTMLCanvasElement | null>(null);
    const accountMenuRef = useRef<HTMLDivElement | null>(null);
    const sessionRemovedClientKeys = useRef<Set<string>>(new Set());
    const pullStartY = useRef<number | null>(null);
    const activePullPointerId = useRef<number | null>(null);
    const pullDistanceRef = useRef(0);
    const authGenerationRef = useRef(0);
    const authUidRef = useRef<string | null>(null);
    const mountedRef = useRef(false);

    const isCurrentAuth = useCallback((authGeneration: number, uid: string) => (
        mountedRef.current
        && authGenerationRef.current === authGeneration
        && authUidRef.current === uid
    ), []);

    const getCurrentSession = useCallback(<TInput,>(
        input: TInput,
        options?: { requireToken?: boolean },
    ): CurrentSession<TInput> | null => {
        const user = auth.currentUser;
        const uid = user?.uid;
        const authGeneration = authGenerationRef.current;

        if (!user || !uid || !isCurrentAuth(authGeneration, uid)) {
            return null;
        }
        if (options?.requireToken && !jwtToken) {
            return null;
        }

        return { authGeneration, uid, user, token: jwtToken, input };
    }, [isCurrentAuth, jwtToken]);

    const isCurrentSession = useCallback((session: CurrentSession<unknown>) => (
        isCurrentAuth(session.authGeneration, session.uid)
        && auth.currentUser === session.user
    ), [isCurrentAuth]);

    const activeRegionName = selectedRegion
        ? getRegionName(selectedRegion.regionId, ociRegions)
        : "No region selected";

    const showRegionTabs = enabledRegions.length > 1;

    const activeRegionEntries = useMemo(() => {
        if (VPNTableEntries === null || !activeRegionId) return null;

        return VPNTableEntries.filter(vpn => vpn.region === activeRegionId);
    }, [VPNTableEntries, activeRegionId]);

    const showBanner = (type: Banner["type"], message: string) => {
        setBanner({ type, message });
    };

    const refreshLinkedProviderIds = (user: User | null | undefined = auth.currentUser) => {
        setLinkedProviderIds(user?.providerData?.map(provider => provider.providerId) || []);
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

    const fillVPNs = useCallback(async (user: User, authGeneration: number, uid: string) => {
        const gen = ++vpnFetchGen.current;
        if (isCurrentAuth(authGeneration, uid)) {
            setVPNTableEntries(null);
        }
        try {
            const VPNs: VPNData[] = await getUsersVPNs(user);
            if (
                gen <= vpnAppliedGen.current
                || !isCurrentAuth(authGeneration, uid)
            ) return;
            vpnAppliedGen.current = gen;
            setVPNTableEntries(filterVisibleVPNClients(VPNs, sessionRemovedClientKeys.current));
        } catch (error) {
            if (
                gen <= vpnAppliedGen.current
                || !isCurrentAuth(authGeneration, uid)
            ) return;
            vpnAppliedGen.current = gen;
            showBanner("error", "Error loading VPN clients");
            console.error("Error loading VPN clients:", error);
            setVPNTableEntries([]);
        }
    }, [isCurrentAuth]);

    // Refreshes the table in place, without the loading skeleton or an error banner.
    const refreshVPNs = useCallback(async (user: User) => {
        const authGeneration = authGenerationRef.current;
        const uid = user.uid;
        const gen = ++vpnFetchGen.current;
        try {
            const VPNs: VPNData[] = await getUsersVPNs(user);
            if (
                gen <= vpnAppliedGen.current
                || !isCurrentAuth(authGeneration, uid)
            ) return;
            vpnAppliedGen.current = gen;
            setVPNTableEntries(filterVisibleVPNClients(VPNs, sessionRemovedClientKeys.current));
        } catch (error) {
            console.error("Error refreshing VPN clients:", error);
        }
    }, [isCurrentAuth]);

    const refreshDashboard = useCallback(async () => {
        const user = auth.currentUser;
        const authGeneration = authGenerationRef.current;
        const uid = user?.uid;
        if (!user || !uid || pullRefreshing || !isCurrentAuth(authGeneration, uid)) {
            resetPull();
            return;
        }

        setPullRefreshing(true);
        try {
            await Promise.all([
                refreshVPNs(user),
                jwtToken && isCurrentAuth(authGeneration, uid)
                    ? fetchOciRegions(jwtToken, true)
                    : Promise.resolve(),
            ]);
        } finally {
            if (isCurrentAuth(authGeneration, uid)) setPullRefreshing(false);
            resetPull();
        }
    }, [isCurrentAuth, jwtToken, pullRefreshing, refreshVPNs, resetPull]);

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

    const openGrantAccessModal = () => {
        setGrantAccessEmail("");
        setGrantAccessError(null);
        setGrantAccessSuccess(null);
        setGrantAccessModalOpen(true);
    };

    const closeGrantAccessModal = () => {
        if (grantingAccess) return;
        setGrantAccessModalOpen(false);
    };

    const handleGrantAccess = async (event: React.FormEvent) => {
        event.preventDefault();
        (document.activeElement as HTMLElement | null)?.blur();
        const email = grantAccessEmail.trim();

        if (!jwtToken) {
            setGrantAccessError("Your session is not ready. Try again in a moment.");
            return;
        }
        if (!email.includes("@") || !email.includes(".")) {
            setGrantAccessError("Enter a valid email address.");
            return;
        }
        if (!enabledRegions.length) {
            setGrantAccessError("No enabled regions are available.");
            return;
        }

        const session = getCurrentSession({ email, enabledRegions }, { requireToken: true });
        if (!session || !session.token) {
            setGrantAccessError("Your session is not ready. Try again in a moment.");
            return;
        }

        setGrantingAccess(true);
        setGrantAccessError(null);
        setGrantAccessSuccess(null);
        try {
            const result = await createAdminUser(
                { email: session.input.email },
                session.token,
                session.input.enabledRegions,
            );
            if (!isCurrentSession(session)) return;
            if (!result.success) {
                setGrantAccessError(result.error || "Unable to grant access.");
                return;
            }

            setGrantAccessEmail("");
            setGrantAccessSuccess(result.data.alreadyExisted
                ? `${session.input.email} already has CloudGateway access.`
                : `${session.input.email} now has CloudGateway access.`);
        } catch (error) {
            if (!isCurrentSession(session)) return;
            console.error("Error granting user access:", error);
            setGrantAccessError("Unable to grant access.");
        } finally {
            if (isCurrentSession(session)) setGrantingAccess(false);
        }
    };

    const openSyncRegionsModal = () => {
        setSyncRegionsModalOpen(true);
    };

    const closeSyncRegionsModal = () => {
        setSyncRegionsModalOpen(false);
    };

    // Mesh changes are all-region, so confirming here never runs the sync
    // itself - it hands off to Server Health (via navigation state) so the
    // fan-out survives the route change instead of racing it.
    const confirmSyncRegions = () => {
        setSyncRegionsModalOpen(false);
        navigate("/server-health", { state: { runSync: true } });
    };

    const closeDeleteAccountModal = () => {
        if (deletingAccount) {
            return;
        }
        setDeleteAccountModalOpen(false);
        setDeleteAccountPassword("");
        setDeleteAccountError(null);
    };

    const closeLinkAccountModal = () => {
        if (linkingProviderId) {
            return;
        }
        setLinkAccountModalOpen(false);
        setLinkEmail("");
        setLinkPassword("");
        setShowLinkPassword(false);
        setLinkCurrentPassword("");
        setLinkError(null);
        setLinkRequiresPasswordReauth(false);
    };

    const currentProviderIds = () => linkedProviderIds;

    // Password reauth is the fallback only when neither Apple nor Google is
    // linked, matching the reauth-ordering standard (email & password last).
    const requiresPasswordReauth =
        !currentProviderIds().includes("apple.com")
        && !currentProviderIds().includes("google.com")
        && currentProviderIds().includes("password");
    const missingProviderIds = ALL_AUTH_PROVIDER_IDS.filter(providerId => !linkedProviderIds.includes(providerId));
    const canLinkAnotherProvider = missingProviderIds.length > 0;

    const reauthenticateForAccountDeletion = async (session: CurrentSession<DeleteAccountInput>) => {
        const { user } = session;

        // Reauth order per the standard: Apple, then Google, then email &
        // password last (for convenience when other providers are linked).
        const providers = session.input.providerIds;
        if (providers.includes("apple.com")) {
            await reauthenticateWithPopup(user, appleProvider);
            return;
        }

        if (providers.includes("google.com")) {
            await reauthenticateWithPopup(user, googleProvider);
            return;
        }

        if (providers.includes("password")) {
            const email = user.email;
            if (!email || !session.input.password) {
                throw new Error("Enter your password to delete your account");
            }
            const credential = EmailAuthProvider.credential(email, session.input.password);
            await reauthenticateWithCredential(user, credential);
            return;
        }

        throw new Error("Sign in again before deleting this account");
    };

    const handleDeleteAccount = async () => {
        const session = getCurrentSession({
            password: deleteAccountPassword,
            providerIds: currentProviderIds(),
        });
        if (!session) {
            setDeleteAccountError("No account is signed in.");
            return;
        }

        setDeletingAccount(true);
        setDeleteAccountError(null);
        try {
            await reauthenticateForAccountDeletion(session);
            if (!isCurrentSession(session)) return;

            const token = await session.user.getIdToken(true);
            if (!isCurrentSession(session)) return;

            const response = await deleteAccount(token);
            if (!isCurrentSession(session)) return;
            if (!response.success) {
                setDeleteAccountError(response.error || "Unable to delete account.");
                return;
            }
            closeDeleteAccountModal();
            if (isCurrentSession(session)) {
                await logout(navigate);
            }
        } catch (error) {
            if (!isCurrentSession(session)) return;
            const code = getAuthErrorCode(error);
            if (code !== "auth/popup-closed-by-user" && code !== "auth/cancelled-popup-request") {
                setDeleteAccountError(getDeleteAccountErrorMessage(error));
            }
        } finally {
            if (isCurrentSession(session)) setDeletingAccount(false);
        }
    };

    const getDeleteAccountErrorMessage = (error: unknown) => {
        const code = getAuthErrorCode(error);

        if (code === "auth/wrong-password" || code === "auth/invalid-credential") {
            return "That password is incorrect.";
        }
        if (code === "auth/requires-recent-login") {
            return "Please sign in again, then retry deleting your account.";
        }
        if (code === "auth/popup-blocked") {
            return "Allow popups for this site, then try again.";
        }
        if (code === "auth/too-many-requests") {
            return "Too many attempts. Wait a moment and try again.";
        }
        if (code === "auth/network-request-failed") {
            return "Network error. Check your connection and try again.";
        }

        return "Unable to delete your account. Try again or contact support.";
    };

    const getLinkErrorMessage = (error: unknown) => {
        const code = error && typeof error === "object" && "code" in error
            ? (error as { code?: string }).code
            : null;

        if (code === "auth/credential-already-in-use" || code === "auth/email-already-in-use") {
            return "That sign-in method is already used by another CloudGateway account. Sign in with that account directly or contact support.";
        }
        if (code === "auth/provider-already-linked") {
            return "That sign-in method is already linked to this account.";
        }
        if (code === "auth/popup-blocked") {
            return "Allow popups for this site, then try again.";
        }
        if (code === "auth/invalid-email") {
            return "Enter a valid email address.";
        }
        if (code === "auth/weak-password") {
            return "Enter a stronger password.";
        }
        if (code === "auth/wrong-password" || code === "auth/invalid-credential") {
            return "The current password is incorrect.";
        }

        return "Unable to link that sign-in method. Try again or contact support.";
    };

    const getAuthErrorCode = (error: unknown) => (
        error && typeof error === "object" && "code" in error
            ? (error as { code?: string }).code
            : null
    );

    const reauthenticateForAccountLinking = async (session: CurrentSession<LinkProviderInput>) => {
        const { user } = session;

        // Reauth order per the standard: Apple, then Google, then password last.
        const providers = session.input.providerIds;
        if (providers.includes("apple.com")) {
            await reauthenticateWithPopup(user, appleProvider);
            return true;
        }

        if (providers.includes("google.com")) {
            await reauthenticateWithPopup(user, googleProvider);
            return true;
        }

        if (providers.includes("password")) {
            const email = user.email;
            if (!email || !session.input.currentPassword) {
                if (isCurrentSession(session)) {
                    setLinkRequiresPasswordReauth(true);
                    setLinkError("Enter your current password, then try again.");
                }
                return false;
            }
            const credential = EmailAuthProvider.credential(email, session.input.currentPassword);
            await reauthenticateWithCredential(user, credential);
            return true;
        }

        throw new Error("Sign in again before linking another sign-in method");
    };

    const linkProvider = async (session: CurrentSession<LinkProviderInput>) => {
        const { providerId, email, password } = session.input;

        if (providerId === "google.com") {
            await linkWithPopup(session.user, googleProvider);
            return;
        }

        if (providerId === "apple.com") {
            await linkWithPopup(session.user, appleProvider);
            return;
        }

        if (!email.trim() || !password) {
            throw new Error("Enter an email address and password to link.");
        }

        const credential = EmailAuthProvider.credential(email.trim(), password);
        await linkWithCredential(session.user, credential);
    };

    const handleLinkProvider = async (providerId: AuthProviderId, retried = false) => {
        if (linkingProviderId) {
            return;
        }

        const session = getCurrentSession({
            providerId,
            email: linkEmail,
            password: linkPassword,
            currentPassword: linkCurrentPassword,
            providerIds: currentProviderIds(),
        });
        if (!session) {
            setLinkError("No account is signed in");
            return;
        }

        setLinkingProviderId(providerId);
        setLinkError(null);
        try {
            if (linkRequiresPasswordReauth) {
                const reauthenticated = await reauthenticateForAccountLinking(session);
                if (!isCurrentSession(session) || !reauthenticated) return;
            }

            await linkProvider(session);
            if (!isCurrentSession(session)) return;

            await session.user.reload();
            if (!isCurrentSession(session)) return;

            refreshLinkedProviderIds(session.user);
            closeLinkAccountModal();
            showBanner("success", `${getProviderLabel(providerId)} was linked to your account.`);
        } catch (error) {
            if (!isCurrentSession(session)) return;
            const code = getAuthErrorCode(error);
            if (code === "auth/popup-closed-by-user" || code === "auth/cancelled-popup-request") {
                return;
            }
            if (code === "auth/requires-recent-login" && !retried) {
                try {
                    const reauthenticated = await reauthenticateForAccountLinking(session);
                    if (!isCurrentSession(session)) return;
                    if (reauthenticated) {
                        setLinkingProviderId(null);
                        await handleLinkProvider(providerId, true);
                    }
                } catch (reauthError) {
                    if (!isCurrentSession(session)) return;
                    const reauthCode = getAuthErrorCode(reauthError);
                    if (reauthCode !== "auth/popup-closed-by-user" && reauthCode !== "auth/cancelled-popup-request") {
                        setLinkError(getLinkErrorMessage(reauthError));
                    }
                }
                return;
            }
            setLinkError(error instanceof Error && !code ? error.message : getLinkErrorMessage(error));
            if (code === "auth/provider-already-linked") {
                await session.user.reload();
                if (!isCurrentSession(session)) return;
                refreshLinkedProviderIds(session.user);
            }
        } finally {
            if (isCurrentSession(session)) setLinkingProviderId(null);
        }
    };

    const handleCreateClient = async (e: React.FormEvent) => {
        e.preventDefault();
        (document.activeElement as HTMLElement | null)?.blur();

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
        if (!selectedRegionCapacityKnown) {
            showBanner("error", `Capacity for ${activeRegionName} is unavailable. Try again in a moment.`);
            return;
        }
        if (selectedRegionFull) {
            showBanner("error", `${activeRegionName} is currently full. Choose another region.`);
            return;
        }

        const trimmedClientName = clientName.trim();
        if (!trimmedClientName) {
            showBanner("error", "Enter a display name, for example John's iPhone.");
            return;
        }

        const session = getCurrentSession({
            regionId: activeRegionId,
            clientName: trimmedClientName,
            activeRegionName,
        }, { requireToken: true });
        if (!session || !session.token) {
            showBanner("error", "You must be signed in to create a client");
            return;
        }

        setLoading(true);
        setBanner(null);

        try {
            const response = await createClient({
                regionId: session.input.regionId,
                clientName: session.input.clientName,
            }, session.token);
            if (!isCurrentSession(session)) return;

            if (!response.success) {
                showBanner("error", response.error || "Unable to create client");
                if (isCurrentSession(session) && (response.errorCode === "CAPACITY_REACHED" || response.errorCode === "LIMIT_REACHED")) {
                    await fetchOciRegions(session.token, true);
                }
                if (isCurrentSession(session)) {
                    await refreshVPNs(session.user);
                }
                return;
            }

            setClientName("");
            showBanner("success", `${response.data.clientName || "Client"} was created in ${session.input.activeRegionName}.`);
            if (isCurrentSession(session)) {
                await Promise.all([
                    refreshVPNs(session.user),
                    fetchOciRegions(session.token, true),
                ]);
            }
        } catch (error) {
            if (!isCurrentSession(session)) return;
            showBanner("error", "Error creating client");
            console.error("Error creating client:", error);
            if (isCurrentSession(session)) {
                await refreshVPNs(session.user);
            }
        } finally {
            if (isCurrentSession(session)) setLoading(false);
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

        const session = getCurrentSession({
            activeRegionId,
            activeRegionName,
            selectedEntries,
        }, { requireToken: true });
        if (!session || !session.token) {
            showBanner("error", "You must be signed in to remove clients");
            return;
        }
        const token = session.token;

        setLoading(true);
        setBanner(null);
        session.input.selectedEntries.forEach(entry => sessionRemovedClientKeys.current.add(getClientKey(entry)));

        try {
            const results = await Promise.all(session.input.selectedEntries.map(entry => (
                deleteClient(entry.clientId, {
                    userId: entry.ownerUid || entry.userID,
                    regionId: session.input.activeRegionId,
                }, token)
            )));
            if (!isCurrentSession(session)) return;
            const failedResults = results.filter((result): result is ApiHelperFailure => !result.success);

            clearSelectedClients();
            if (isCurrentSession(session)) {
                await Promise.all([
                    refreshVPNs(session.user),
                    fetchOciRegions(session.token, true),
                ]);
            }
            if (!isCurrentSession(session)) return;

            if (failedResults.length) {
                const firstFailure = failedResults[0];
                showBanner("error", firstFailure.error || `${failedResults.length} client removals failed`);
                return;
            }

            showBanner("success", `${session.input.selectedEntries.length} client${session.input.selectedEntries.length === 1 ? "" : "s"} removed from ${session.input.activeRegionName}.`);
        } catch (error) {
            if (!isCurrentSession(session)) return;
            showBanner("error", "Error removing clients");
            console.error("Error removing clients:", error);
        } finally {
            if (isCurrentSession(session)) setLoading(false);
        }
    };

    const handleQRcode = useCallback((vpn: VPNTableEntry) => {
        if (!vpn.wireguardConfig) {
            showBanner("error", "Config not available for QR code.");
            return;
        }

        setActiveConfigEndpoint(vpn.serverEndpointHostname || vpn.serverEndpointIpv4 || vpn.ipv4);
        setActiveConfigTunnelIp(stripCidr(vpn.assignedTunnelIpv4));
        setVpnRegion(vpn.region);
        setActiveConfigClientName(vpn.clientName || vpn.clientId);
        setConfigData(vpn.wireguardConfig);
        setConfigCopied(false);
    }, []);

    const closeConfigModal = () => {
        setConfigData(null);
        setActiveConfigEndpoint(null);
        setActiveConfigTunnelIp(null);
        setVpnRegion(null);
        setActiveConfigClientName(null);
    };

    // Dialog a11y for the hand-rolled overlays: focus trap, focus restore, and
    // Escape-to-close. The close handlers already no-op while their operation is
    // in flight, so Escape is safe to wire directly.
    const linkAccountModalRef = useModalDialog<HTMLDivElement>(linkAccountModalOpen, closeLinkAccountModal);
    const configModalRef = useModalDialog<HTMLDivElement>(!!configData, closeConfigModal);
    const deleteAccountModalRef = useModalDialog<HTMLDivElement>(deleteAccountModalOpen, closeDeleteAccountModal);
    const grantAccessModalRef = useModalDialog<HTMLDivElement>(grantAccessModalOpen, closeGrantAccessModal);

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
        mountedRef.current = true;
        const unsubscribe = onAuthStateChanged(auth, (user) => {
            const authGeneration = ++authGenerationRef.current;
            const uid = user?.uid || null;
            authUidRef.current = uid;
            ++vpnFetchGen.current;
            vpnAppliedGen.current = vpnFetchGen.current;
            sessionRemovedClientKeys.current.clear();
            setLinkedProviderIds([]);
            setJwtToken(null);
            setRole(null);
            setBanner(null);
            setLoading(false);
            setAccountMenuOpen(false);
            setGrantAccessModalOpen(false);
            setGrantAccessEmail("");
            setGrantAccessError(null);
            setGrantAccessSuccess(null);
            setSyncRegionsModalOpen(false);
            setDeleteAccountModalOpen(false);
            setDeleteAccountPassword("");
            setDeleteAccountError(null);
            setLinkAccountModalOpen(false);
            setLinkEmail("");
            setLinkPassword("");
            setLinkCurrentPassword("");
            setLinkError(null);
            setLinkRequiresPasswordReauth(false);
            setLinkingProviderId(null);
            setClientName("");
            setVPNTableEntries(null);
            setSelectedClientKeys(new Set());
            setActiveRegionId("");
            setConfigData(null);
            setConfigCopied(false);
            setActiveConfigClientName(null);
            setActiveConfigEndpoint(null);
            setActiveConfigTunnelIp(null);
            setVpnRegion(null);
            setPullDistance(0);
            setPullRefreshing(false);

            const isCurrent = () => (
                !!uid && isCurrentAuth(authGeneration, uid)
            );
            const fetchUserData = async () => {
                if (user && uid) {
                    setLinkedProviderIds(user.providerData?.map(provider => provider.providerId) || []);
                    void fillVPNs(user, authGeneration, uid);
                    const token: string | null = await user.getIdToken();
                    if (!isCurrent()) return;
                    setJwtToken(token);
                    const userRole = await getUserRole(user);
                    if (!isCurrent()) return;
                    setRole(userRole);
                    void fetchOciRegions(token, true);
                } else if (!user && mountedRef.current && !auth.currentUser) {
                    // Same teardown as the explicit logout path: the previous
                    // account's region list must not survive the sign-out.
                    useOciRegionsStore.getState().clearOciRegions();
                    navigate("/", { replace: true });
                }
            };
            void fetchUserData();
        });
        const generationAtCleanup = authGenerationRef;
        return () => {
            mountedRef.current = false;
            ++generationAtCleanup.current;
            authUidRef.current = null;
            unsubscribe();
        };
    }, [navigate, fillVPNs, isCurrentAuth]);

    useEffect(() => {
        if (!enabledRegions.length) {
            if (activeRegionId) {
                setActiveRegionId("");
                clearSelectedClients();
            }
            return;
        }

        // Keep a still-valid selection so a refresh doesn't clobber a manual pick.
        if (activeRegionId && enabledRegions.some(region => region.regionId === activeRegionId)) {
            return;
        }

        // Wait for the VPN list before preselecting so we can land on the first
        // region (in display order) that actually has a config for the user.
        if (VPNTableEntries === null) return;

        const regionIdsWithConfig = new Set(
            VPNTableEntries.map(entry => entry.region).filter((region): region is string => !!region)
        );
        setActiveRegionId(resolveActiveRegionId(enabledRegions, regionIdsWithConfig));
        clearSelectedClients();
    }, [enabledRegions, activeRegionId, VPNTableEntries]);

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

    // Close the account menu on an outside click or Escape.
    useEffect(() => {
        if (!accountMenuOpen) return;

        const handlePointerDown = (event: MouseEvent) => {
            if (accountMenuRef.current && !accountMenuRef.current.contains(event.target as Node)) {
                setAccountMenuOpen(false);
            }
        };
        const handleKeyDown = (event: KeyboardEvent) => {
            if (event.key === "Escape") {
                setAccountMenuOpen(false);
            }
        };

        document.addEventListener("mousedown", handlePointerDown);
        document.addEventListener("keydown", handleKeyDown);
        return () => {
            document.removeEventListener("mousedown", handlePointerDown);
            document.removeEventListener("keydown", handleKeyDown);
        };
    }, [accountMenuOpen]);

    const createDisabled = !clientName.trim() || !activeRegionId || !selectedRegion || selectedRegionCreationBlocked || regionsLoading || VPNTableEntries === null || loading;
    const removeDisabled = loading || regionsLoading;

    return (
        <div
            data-testid="dashboard-page"
            className="flex min-h-screen touch-pan-y flex-col items-center overscroll-y-contain bg-page px-4 pb-20 pt-24"
            onPointerDown={handlePullStart}
            onPointerMove={handlePullMove}
            onPointerUp={handlePullEnd}
            onPointerCancel={resetPull}
        >
            <AppNav
                subtitle={auth.currentUser?.email || "Signed in"}
                showAbout
                onRefresh={() => void refreshDashboard()}
                refreshDisabled={loading || pullRefreshing}
                refreshing={pullRefreshing}
                serverHealthPath={role === "admin" ? "/server-health" : undefined}
            >
                <div className="relative" ref={accountMenuRef}>
                    <button
                        type="button"
                        onClick={() => setAccountMenuOpen(open => !open)}
                        className="flex h-10 w-10 cursor-pointer items-center justify-center rounded-lg bg-nav-btn text-accent transition hover:bg-nav-btn-hover focus:outline-none focus:ring-2 focus:ring-white/80"
                        aria-label="Account"
                        aria-expanded={accountMenuOpen}
                    >
                        <UserCircle size={22} aria-hidden="true" />
                    </button>
                    {accountMenuOpen && (
                        <div className="absolute right-0 mt-2 w-64 rounded-lg border border-edge bg-card py-2 text-content shadow-lg">
                            <div className="border-b border-edge-faint px-4 pb-2 text-xs text-content-muted sm:hidden">
                                {auth.currentUser?.email}
                            </div>
                            <button
                                type="button"
                                onClick={async () => {
                                    const session = getCurrentSession({ operation: "logout" });
                                    setAccountMenuOpen(false);
                                    // Before the auth observer's first callback there is no
                                    // resolvable session yet, but a restored user is already
                                    // signed in - logout must not be a dead button there.
                                    if ((session && isCurrentSession(session)) || auth.currentUser) {
                                        await logout(navigate);
                                    }
                                }}
                                className="flex w-full items-center gap-2 px-4 py-2 text-left text-sm transition hover:bg-inset"
                            >
                                <LogOut size={16} aria-hidden="true" />
                                Logout
                            </button>
                            {canLinkAnotherProvider && (
                                <button
                                    type="button"
                                    onClick={() => {
                                        setAccountMenuOpen(false);
                                        setLinkAccountModalOpen(true);
                                    }}
                                    className="flex w-full items-center gap-2 px-4 py-2 text-left text-sm transition hover:bg-inset"
                                >
                                    <Link size={16} aria-hidden="true" />
                                    Link another sign-in method
                                </button>
                            )}
                            <button
                                type="button"
                                onClick={() => {
                                    setAccountMenuOpen(false);
                                    setDeleteAccountModalOpen(true);
                                }}
                                className="flex w-full items-center gap-2 px-4 py-2 text-left text-sm text-danger-content transition hover:bg-danger-soft"
                            >
                                <Trash2 size={16} aria-hidden="true" />
                                Delete Account
                            </button>
                        </div>
                    )}
                </div>
            </AppNav>

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
                <div className="mb-4 w-full max-w-7xl rounded-lg border border-edge-faint bg-card p-4 shadow-lg md:p-6">
                    <h2 className="text-xl font-semibold text-content">Admin</h2>
                    <p className="mt-1 text-sm text-content-muted">Manage regions and user access.</p>
                    <div className="mt-4 grid gap-3 sm:grid-cols-2">
                        <button
                            type="button"
                            onClick={openSyncRegionsModal}
                            disabled={regionsLoading || !enabledRegions.length}
                            className="flex w-full cursor-pointer items-center justify-center gap-2 rounded-lg bg-primary p-3 text-sm font-semibold text-white transition hover:bg-primary-hover disabled:cursor-not-allowed disabled:bg-disabled disabled:text-content-disabled"
                        >
                            <RefreshCw size={18} aria-hidden="true" />
                            Sync All Regions
                        </button>
                        <button
                            type="button"
                            onClick={openGrantAccessModal}
                            className="flex w-full cursor-pointer items-center justify-center gap-2 rounded-lg bg-primary p-3 text-sm font-semibold text-white transition hover:bg-primary-hover"
                        >
                            <UserPlus size={18} aria-hidden="true" />
                            Grant User Access
                        </button>
                    </div>
                </div>
            )}

            <div className="w-full max-w-7xl rounded-lg bg-card p-4 shadow-lg md:p-6">
                <div className="flex flex-col gap-4">
                    <div>
                        <h2 className="text-xl font-semibold text-content">VPN Dashboard</h2>
                        <p className="mt-1 text-sm text-content-muted">
                            {role === "admin"
                                ? "View and remove clients across users. New clients are created only for your account."
                                : "Create and remove your VPN clients."}
                        </p>
                    </div>

                    <form onSubmit={handleCreateClient} className="flex w-full max-w-xl flex-col gap-3 sm:flex-row sm:items-end">
                        <label className="flex min-w-0 flex-1 flex-col text-sm font-medium text-content-secondary sm:w-64">
                            Client display name
                            <input
                                value={clientName}
                                onChange={(e) => setClientName(e.target.value)}
                                maxLength={80}
                                placeholder="ex: John's iPhone"
                                required
                                className="mt-1 w-full rounded-lg border border-edge-subtle bg-inset p-3 text-content focus:border-focus focus:outline-none focus:ring-2 focus:ring-focus-soft"
                            />
                        </label>
                        <button
                            type="submit"
                            disabled={createDisabled}
                                className={`rounded-lg px-5 py-3 text-sm font-medium transition ${
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
                                const isActive = region.regionId === activeRegionId;
                                const capacityLabel = getRegionCapacityLabel(region);
                                const regionFull = isRegionAtCapacity(region);
                                const regionCapacityKnown = isRegionCapacityKnown(region);

                                return (
                                    <button
                                        key={region.regionId}
                                        type="button"
                                        onClick={() => selectRegion(region.regionId)}
                                        className={`rounded-lg border px-4 py-2 text-left text-sm transition focus:outline-none focus:ring-2 focus:ring-focus ${
                                            isActive
                                                ? "border-primary bg-primary-soft text-accent"
                                                : "border-edge-subtle bg-card text-content-secondary hover:border-primary-soft-edge hover:bg-primary-soft"
                                        }`}
                                        aria-pressed={isActive}
                                    >
                                        <span className="block font-medium">{region.displayName}</span>
                                        {capacityLabel && (
                                            <span className={regionFull || !regionCapacityKnown ? "block text-xs text-danger-content" : "block text-xs text-content-muted"}>
                                                {capacityLabel}
                                            </span>
                                        )}
                                    </button>
                                );
                            })}
                        </div>
                    ) : selectedRegion ? (
                        <div className="flex flex-wrap items-center gap-3 text-sm text-content-secondary">
                            <span className="font-medium">{selectedRegion.displayName}</span>
                            {selectedRegionCapacityKnown && (
                                <span className={selectedRegionFull ? "text-danger-content" : "text-content-muted"}>
                                    {selectedRegionFull
                                        ? `${selectedRegion.displayName} is currently full`
                                        : getRegionCapacityLabel(selectedRegion)}
                                </span>
                            )}
                        </div>
                    ) : null}

                    {selectedRegion && !selectedRegionCapacityKnown && (
                        <p className="mt-3 text-sm text-danger-content">
                            Capacity for {activeRegionName} is unavailable. Try again in a moment.
                        </p>
                    )}
                    {selectedRegionFull && (
                        <p className="mt-3 text-sm text-danger-content">
                            {activeRegionName} is currently full. Choose another region before creating a client.
                        </p>
                    )}
                    {role && role !== "admin" && (
                        <div className="mt-3 text-xs">
                            <a
                                href={`mailto:${SUPPORT_EMAIL}`}
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
                removing={removeDisabled}
                activeRegionName={activeRegionName}
            />

            {grantAccessModalOpen && (
                <div
                    className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
                    onClick={closeGrantAccessModal}
                >
                    <div
                        ref={grantAccessModalRef}
                        role="dialog"
                        aria-modal="true"
                        aria-labelledby="grant-access-modal-title"
                        tabIndex={-1}
                        className="relative w-full max-w-md rounded-lg border border-edge-faint bg-card p-6 text-left shadow-lg focus:outline-none"
                        onClick={(event) => event.stopPropagation()}
                    >
                        <button
                            type="button"
                            onClick={closeGrantAccessModal}
                            disabled={grantingAccess}
                            className="absolute right-3 top-3 flex h-9 w-9 items-center justify-center rounded-lg text-content-muted transition hover:bg-inset hover:text-content disabled:cursor-not-allowed"
                            aria-label="Close grant user access"
                        >
                            <X size={20} aria-hidden="true" />
                        </button>
                        <div className="pr-10">
                            <h3 id="grant-access-modal-title" className="text-2xl font-semibold text-content">Grant User Access</h3>
                            <p className="mt-2 text-sm text-content-muted">
                                Invite someone to sign in and create CloudGateway VPN clients.
                            </p>
                        </div>

                        {grantAccessError && (
                            <div className="mt-4 rounded-lg border border-danger-soft-edge bg-danger-soft px-4 py-3 text-sm text-danger-content">
                                {grantAccessError}
                            </div>
                        )}
                        {grantAccessSuccess && (
                            <div className="mt-4 rounded-lg border border-success-soft-edge bg-success-soft px-4 py-3 text-sm text-success-strong">
                                {grantAccessSuccess}
                            </div>
                        )}

                        <form onSubmit={handleGrantAccess} className="mt-5">
                            {/* The grant already happened, so an empty email field
                                would read as a second invite waiting to be sent. */}
                            {!grantAccessSuccess && (
                                <label className="block text-sm font-medium text-content-secondary">
                                    Email
                                    <input
                                        type="email"
                                        value={grantAccessEmail}
                                        onChange={(event) => setGrantAccessEmail(event.target.value)}
                                        autoComplete="email"
                                        placeholder="user@example.com"
                                        disabled={grantingAccess}
                                        className="mt-1 w-full rounded-lg border border-edge bg-inset p-3 text-content focus:border-focus focus:outline-none focus:ring-2 focus:ring-focus-soft"
                                    />
                                </label>
                            )}
                            <div className="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
                                <button
                                    type="button"
                                    onClick={closeGrantAccessModal}
                                    disabled={grantingAccess}
                                    className="rounded-lg bg-inset-strong px-5 py-3 text-sm font-semibold text-content-secondary transition hover:bg-inset-strong-hover disabled:cursor-not-allowed"
                                >
                                    {grantAccessSuccess ? "Done" : "Cancel"}
                                </button>
                                {!grantAccessSuccess && (
                                    <button
                                        type="submit"
                                        disabled={grantingAccess || !grantAccessEmail.trim() || regionsLoading}
                                        className="rounded-lg bg-primary px-5 py-3 text-sm font-semibold text-white transition hover:bg-primary-hover disabled:cursor-not-allowed disabled:bg-disabled disabled:text-content-disabled"
                                    >
                                        {grantingAccess ? "Granting..." : "Grant Access"}
                                    </button>
                                )}
                            </div>
                        </form>
                    </div>
                </div>
            )}

            <SyncRegionsConfirmModal
                open={syncRegionsModalOpen}
                regions={enabledRegions.map(region => ({ regionId: region.regionId, displayName: region.displayName }))}
                onConfirm={confirmSyncRegions}
                onClose={closeSyncRegionsModal}
            />

            {linkAccountModalOpen && (
                <div
                    className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
                    onClick={closeLinkAccountModal}
                >
                    <div
                        ref={linkAccountModalRef}
                        role="dialog"
                        aria-modal="true"
                        aria-labelledby="link-account-modal-title"
                        tabIndex={-1}
                        className="relative w-full max-w-lg rounded-lg bg-card p-6 text-left shadow-lg focus:outline-none"
                        onClick={(event) => event.stopPropagation()}
                    >
                        <button
                            onClick={closeLinkAccountModal}
                            className="absolute right-3 top-2 text-lg font-bold text-content-muted hover:text-content"
                            aria-label="Close link sign-in method"
                            disabled={!!linkingProviderId}
                        >
                            x
                        </button>
                        <h3 id="link-account-modal-title" className="mb-3 text-2xl font-semibold text-content">Link Sign-In Method</h3>
                        <div className="space-y-2 text-sm text-content-secondary">
                            <p>Choose a provider to link to your CloudGateway account.</p>
                            <p>The provider account you link to cannot have an existing CloudGateway account.</p>
                        </div>

                        {linkError && (
                            <div className="mt-4 rounded-lg bg-danger-soft px-4 py-3 text-sm text-danger-content">
                                {linkError}
                            </div>
                        )}

                        {linkRequiresPasswordReauth && (
                            <label className="mt-4 block text-sm font-medium text-content-secondary">
                                Current password
                                <input
                                    value={linkCurrentPassword}
                                    onChange={(event) => setLinkCurrentPassword(event.target.value)}
                                    type="password"
                                    autoComplete="current-password"
                                    className="mt-1 w-full rounded-lg border border-edge bg-inset p-3 text-content focus:border-focus focus:outline-none focus:ring-2 focus:ring-focus-soft"
                                    disabled={!!linkingProviderId}
                                />
                            </label>
                        )}

                        <div className="mt-5 space-y-3">
                            {missingProviderIds.includes("password") && (
                                <div className="rounded-lg border border-edge-subtle p-4">
                                    <div className="flex items-start gap-3 pr-8">
                                        <KeyRound className="mt-0.5 text-accent" size={18} aria-hidden="true" />
                                        <div className="min-w-0 flex-1">
                                            <h4 className="font-medium text-content">Email and password</h4>
                                            <div className="mt-3 grid gap-3">
                                                <label className="block text-sm font-medium text-content-secondary">
                                                    Email
                                                    <input
                                                        value={linkEmail}
                                                        onChange={(event) => setLinkEmail(event.target.value)}
                                                        type="email"
                                                        autoComplete="email"
                                                        className="mt-1 w-full rounded-lg border border-edge bg-inset p-3 text-content focus:border-focus focus:outline-none focus:ring-2 focus:ring-focus-soft"
                                                        disabled={!!linkingProviderId}
                                                    />
                                                </label>
                                                <label className="block text-sm font-medium text-content-secondary">
                                                    New password
                                                    <div className="relative mt-1">
                                                        <input
                                                            value={linkPassword}
                                                            onChange={(event) => setLinkPassword(event.target.value)}
                                                            type={showLinkPassword ? "text" : "password"}
                                                            autoComplete="new-password"
                                                            className="w-full rounded-lg border border-edge bg-inset p-3 pr-12 text-content focus:border-focus focus:outline-none focus:ring-2 focus:ring-focus-soft"
                                                            disabled={!!linkingProviderId}
                                                        />
                                                        <button
                                                            type="button"
                                                            aria-label={showLinkPassword ? "Hide password" : "Show password"}
                                                            onClick={() => setShowLinkPassword((visible) => !visible)}
                                                            className="absolute inset-y-0 right-0 flex w-12 items-center justify-center text-content-muted transition hover:text-content-secondary disabled:cursor-not-allowed disabled:text-content-disabled"
                                                            disabled={!!linkingProviderId}
                                                        >
                                                            {showLinkPassword ? <EyeOff size={20} aria-hidden="true" /> : <Eye size={20} aria-hidden="true" />}
                                                        </button>
                                                    </div>
                                                </label>
                                                <button
                                                    type="button"
                                                    onClick={() => void handleLinkProvider("password")}
                                                    className="w-full cursor-pointer rounded-lg bg-primary p-3 text-sm font-medium text-white transition hover:bg-primary-hover disabled:cursor-not-allowed disabled:bg-disabled disabled:text-content-disabled"
                                                    disabled={!!linkingProviderId || !linkEmail.trim() || !linkPassword}
                                                >
                                                    {linkingProviderId === "password" ? "Linking..." : "Link email and password"}
                                                </button>
                                            </div>
                                        </div>
                                    </div>
                                </div>
                            )}

                            {missingProviderIds.includes("apple.com") && (
                                <button
                                    type="button"
                                    onClick={() => void handleLinkProvider("apple.com")}
                                    className="flex w-full cursor-pointer items-center justify-center gap-3 rounded-lg border border-edge bg-inset p-3 text-content transition hover:bg-inset-strong disabled:cursor-not-allowed disabled:opacity-60"
                                    disabled={!!linkingProviderId}
                                >
                                    <svg viewBox="0 0 384 512" aria-hidden="true" className="h-[18px] w-[18px] shrink-0 fill-current">
                                        <path d="M318.7 268.7c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141.2 4 184.8 4 273.5q0 39.3 14.4 81.2c12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.7 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-91.9zm-56.6-164.2c27.3-32.4 24.8-61.9 24-72.5-24.1 1.4-52 16.4-67.9 34.9-17.5 19.8-27.8 44.3-25.6 71.9 26.1 2 49.9-11.4 69.5-34.3z" />
                                    </svg>
                                    {linkingProviderId === "apple.com" ? "Linking..." : "Link Apple"}
                                </button>
                            )}

                            {missingProviderIds.includes("google.com") && (
                                <button
                                    type="button"
                                    onClick={() => void handleLinkProvider("google.com")}
                                    className="flex w-full cursor-pointer items-center justify-center gap-3 rounded-lg border border-edge bg-inset p-3 text-content transition hover:bg-inset-strong disabled:cursor-not-allowed disabled:opacity-60"
                                    disabled={!!linkingProviderId}
                                >
                                    <svg viewBox="0 0 48 48" aria-hidden="true" className="h-[18px] w-[18px] shrink-0">
                                        <path fill="#4285F4" d="M45.12 24.5c0-1.56-.14-3.06-.4-4.5H24v8.51h11.84c-.51 2.75-2.06 5.08-4.39 6.64v5.52h7.11c4.16-3.83 6.56-9.47 6.56-16.17z" />
                                        <path fill="#34A853" d="M24 46c5.94 0 10.92-1.97 14.56-5.33l-7.11-5.52c-1.97 1.32-4.49 2.1-7.45 2.1-5.73 0-10.58-3.87-12.31-9.07H4.34v5.7C7.96 41.07 15.4 46 24 46z" />
                                        <path fill="#FBBC05" d="M11.69 28.18c-.44-1.32-.69-2.73-.69-4.18s.25-2.86.69-4.18v-5.7H4.34C2.85 17.09 2 20.45 2 24s.85 6.91 2.34 9.88l7.35-5.7z" />
                                        <path fill="#EA4335" d="M24 10.75c3.23 0 6.13 1.11 8.41 3.29l6.31-6.31C34.91 4.18 29.93 2 24 2 15.4 2 7.96 6.93 4.34 14.12l7.35 5.7c1.73-5.2 6.58-9.07 12.31-9.07z" />
                                    </svg>
                                    {linkingProviderId === "google.com" ? "Linking..." : "Link Google"}
                                </button>
                            )}
                        </div>
                    </div>
                </div>
            )}

            {configData && (
                <div
                    className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
                    onClick={closeConfigModal}
                >
                    <div
                        ref={configModalRef}
                        role="dialog"
                        aria-modal="true"
                        aria-labelledby="config-modal-title"
                        tabIndex={-1}
                        className="relative w-full max-w-md rounded-lg bg-card p-6 text-center shadow-lg focus:outline-none"
                        onClick={(event) => event.stopPropagation()}
                    >
                        <button
                            onClick={closeConfigModal}
                            className="absolute right-3 top-2 text-lg font-bold text-content-muted hover:text-content"
                            aria-label="Close QR code"
                        >
                            x
                        </button>
                        <h3 id="config-modal-title" className="mb-2 text-2xl font-semibold">VPN QR Code</h3>
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
                        {activeConfigTunnelIp && (
                            <p className="flex items-center justify-center gap-1 pt-1 text-content-secondary">
                                Tunnel IP: <CopyableValue value={activeConfigTunnelIp} label={`${activeConfigClientName || "client"} tunnel IP`} />
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

            {deleteAccountModalOpen && (
                <div
                    className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
                    onClick={closeDeleteAccountModal}
                >
                    <div
                        ref={deleteAccountModalRef}
                        role="dialog"
                        aria-modal="true"
                        aria-labelledby="delete-account-modal-title"
                        tabIndex={-1}
                        className="relative w-full max-w-md rounded-lg bg-card p-6 text-left shadow-lg focus:outline-none"
                        onClick={(event) => event.stopPropagation()}
                    >
                        <button
                            onClick={closeDeleteAccountModal}
                            className="absolute right-3 top-2 text-lg font-bold text-content-muted hover:text-content"
                            aria-label="Close delete account"
                            disabled={deletingAccount}
                        >
                            x
                        </button>
                        <h3 id="delete-account-modal-title" className="mb-3 text-2xl font-semibold text-content">Delete Account?</h3>
                        <p className="text-sm text-content-secondary">
                            This will permanently delete your CloudGateway account, VPN clients, stored VPN configuration data, and access records. This cannot be undone.
                        </p>
                        {requiresPasswordReauth && (
                            <label className="mt-4 block text-sm font-medium text-content-secondary">
                                Password
                                <input
                                    value={deleteAccountPassword}
                                    onChange={(event) => setDeleteAccountPassword(event.target.value)}
                                    type="password"
                                    autoComplete="current-password"
                                    className="mt-1 w-full rounded-lg border border-edge bg-inset p-3 text-content focus:border-focus focus:outline-none focus:ring-2 focus:ring-focus-soft"
                                    disabled={deletingAccount}
                                />
                            </label>
                        )}
                        {deleteAccountError && (
                            <div className="mt-4 rounded-lg bg-danger-soft px-4 py-3 text-sm text-danger-content">
                                {deleteAccountError}
                            </div>
                        )}
                        <div className="mt-5 flex flex-col gap-3 sm:flex-row">
                            <button
                                type="button"
                                onClick={closeDeleteAccountModal}
                                className="flex-1 cursor-pointer rounded-lg bg-inset-strong p-3 text-content-secondary transition hover:bg-inset-strong-hover disabled:cursor-not-allowed disabled:bg-disabled disabled:text-content-disabled"
                                disabled={deletingAccount}
                            >
                                Cancel
                            </button>
                            <button
                                type="button"
                                onClick={handleDeleteAccount}
                                className="flex-1 cursor-pointer rounded-lg bg-danger p-3 text-white transition hover:bg-danger-strong disabled:cursor-not-allowed disabled:bg-disabled disabled:text-content-disabled"
                                disabled={deletingAccount || (requiresPasswordReauth && !deleteAccountPassword)}
                            >
                                {deletingAccount ? "Deleting..." : "Delete Account"}
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
