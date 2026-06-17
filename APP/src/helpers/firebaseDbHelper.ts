import { User } from "firebase/auth";
import { auth, signOut } from "../firebase";
import { collection, collectionGroup, getDocs, getFirestore } from "firebase/firestore";
import { NavigateFunction } from "react-router-dom";

import { getUserRole } from "./usersHelper";
import { normalizeVPNStatus, VPNStatus } from "./vpnStatus";
import { dateOrNull, stringOrNull } from "./coerce";
import { useOciRegionsStore } from "../stores/ociRegionsStore";

export const logout = async (navigate: NavigateFunction) => {
    useOciRegionsStore.getState().clearOciRegions();
    await signOut(auth);
    navigate("/", { replace: true });
};

export type VPNClientData = {
    userID: string;
    email: string | null;
    region: string | null;
    ipv4: string | null;
    status: VPNStatus;
    wireguardConfig: string | null;
    ownerUid: string;
    ownerEmail: string | null;
    clientId: string;
    clientName: string | null;
    regionId: string | null;
    assignedTunnelIpv4: string | null;
    assignedTunnelIpv6: string | null;
    serverEndpointIpv4: string | null;
    serverEndpointHostname: string | null;
    serverPublicKey: string | null;
    clientPublicKey: string | null;
    createdAt: Date | null;
    lastErrorCode: string | null;
    lastErrorMessage: string | null;
}

export type VPNData = VPNClientData;

// Builds a table row from a raw Instance doc. The caller supplies the
// authoritative owner email (auth user, or the Users doc for admins); the
// denormalized ownerEmail is only a fallback. Owner identity and region fall
// back to the document path when the denormalized fields are missing.
const toVPNClientData = (
    data: Record<string, any>,
    instanceId: string,
    userID: string,
    email: string | null,
    regionFallback: string | null = null,
): VPNClientData | null => {
    const status = normalizeVPNStatus(data.status);
    if (!status) {
        return null;
    }

    const clientId = stringOrNull(data.clientId) || instanceId;
    const regionId = stringOrNull(data.regionId) || regionFallback;
    const ownerUid = stringOrNull(data.ownerUid) || userID;
    const ownerEmail = email || stringOrNull(data.ownerEmail);

    return {
        userID: ownerUid,
        email: ownerEmail,
        region: regionId,
        ipv4: stringOrNull(data.serverEndpointIpv4) || stringOrNull(data.ipv4) || null,
        status,
        wireguardConfig: stringOrNull(data.wireguardConfig),
        ownerUid,
        ownerEmail,
        clientId,
        clientName: stringOrNull(data.clientName),
        regionId,
        assignedTunnelIpv4: stringOrNull(data.assignedTunnelIpv4),
        assignedTunnelIpv6: stringOrNull(data.assignedTunnelIpv6),
        serverEndpointIpv4: stringOrNull(data.serverEndpointIpv4),
        serverEndpointHostname: stringOrNull(data.serverEndpointHostname),
        serverPublicKey: stringOrNull(data.serverPublicKey),
        clientPublicKey: stringOrNull(data.clientPublicKey),
        createdAt: dateOrNull(data.createdAt),
        lastErrorCode: stringOrNull(data.lastErrorCode),
        lastErrorMessage: stringOrNull(data.lastErrorMessage),
    };
};

export const getUsersVPNs = async (user: User): Promise<VPNClientData[]> => {

    if (await getUserRole(user) === "admin") {
        return await getAdminVPNs();
    }

    return await getVPNs(user.uid, user.email);
};

const getVPNs = async (userID: string, email: string | null): Promise<VPNClientData[]> => {
    try {
        if (!email) {
            console.warn("Email null for user: " + userID);
            return [];
        }

        const db = getFirestore();
        const userRef = collection(db, "Users", userID, "Regions");
        const regionSnapshots = await getDocs(userRef);

        const vpnData: VPNClientData[] = [];

        for (const regionDoc of regionSnapshots.docs) {
            const regionID = regionDoc.id;
            const instancesRef = collection(db, "Users", userID, "Regions", regionID, "Instances");
            const instanceSnapshots = await getDocs(instancesRef);

            instanceSnapshots.forEach((instanceDoc) => {
                const entry = toVPNClientData(instanceDoc.data(), instanceDoc.id, userID, email, regionID);
                if (entry) {
                    vpnData.push(entry);
                }
            });
        }

        return vpnData;

    } catch (error) {
        console.warn("Error fetching VPNs:", error);
        return [];
    }
};

// Admins read every client in one collection-group query rather than fanning
// out a per-user/per-region read. Owner emails come from the authoritative
// Users docs (one parallel list query), not the denormalized ownerEmail field.
const getAdminVPNs = async (): Promise<VPNClientData[]> => {
    try {
        const db = getFirestore();
        const [usersSnapshot, instanceSnapshots] = await Promise.all([
            getDocs(collection(db, "Users")),
            getDocs(collectionGroup(db, "Instances")),
        ]);

        const emailByUid = new Map<string, string | null>();
        usersSnapshot.forEach((userDoc) => {
            emailByUid.set(userDoc.id, stringOrNull(userDoc.data().email));
        });

        const vpnData: VPNClientData[] = [];
        instanceSnapshots.forEach((instanceDoc) => {
            const regionDocRef = instanceDoc.ref.parent.parent;
            const userDocRef = regionDocRef?.parent?.parent;
            const data = instanceDoc.data();
            const ownerUid = stringOrNull(data.ownerUid) || userDocRef?.id || "";
            const entry = toVPNClientData(
                data,
                instanceDoc.id,
                ownerUid,
                emailByUid.get(ownerUid) ?? null,
                regionDocRef?.id ?? null,
            );
            if (entry) {
                vpnData.push(entry);
            }
        });

        return vpnData;

    } catch (error) {
        console.warn("Error fetching VPNs for admin:", error);
        return [];
    }
}
