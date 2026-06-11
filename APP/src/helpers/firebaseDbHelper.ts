import { User } from "firebase/auth";
import { auth, signOut } from "../firebase";
import { getFirestore, collection, getDocs } from "firebase/firestore";
import { NavigateFunction } from "react-router-dom";

import { getUserRole } from "./usersHelper";
import { normalizeVPNStatus, VPNStatus } from "./vpnStatus";
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
    lastErrorCode: string | null;
    lastErrorMessage: string | null;
}

export type VPNData = VPNClientData;

const stringOrNull = (value: unknown) => typeof value === "string" && value.trim()
    ? value
    : null;

export const getUsersVPNs = async (user: User): Promise<VPNClientData[]> => {

    if (await getUserRole(user) === "admin") {
        return await getAdminVPNs(user);
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
                const data = instanceDoc.data();
                const {
                    status: rawStatus,
                    wireguardConfig,
                    assignedTunnelIpv4,
                    assignedTunnelIpv6,
                    serverEndpointIpv4,
                    serverEndpointHostname,
                    serverPublicKey,
                    clientPublicKey,
                    clientName,
                    lastErrorCode,
                    lastErrorMessage,
                } = data;
                const status = normalizeVPNStatus(rawStatus);
                if (status) {
                    const clientId = stringOrNull(data.clientId) || instanceDoc.id;
                    const regionId = stringOrNull(data.regionId) || regionID;
                    const ownerEmail = stringOrNull(data.ownerEmail) || email;

                    vpnData.push({
                        userID: userID,
                        email: ownerEmail,
                        region: regionId,
                        ipv4: stringOrNull(serverEndpointIpv4) || stringOrNull(data.ipv4) || null,
                        status: status,
                        wireguardConfig: stringOrNull(wireguardConfig),
                        ownerUid: stringOrNull(data.ownerUid) || userID,
                        ownerEmail,
                        clientId,
                        clientName: stringOrNull(clientName),
                        regionId,
                        assignedTunnelIpv4: stringOrNull(assignedTunnelIpv4),
                        assignedTunnelIpv6: stringOrNull(assignedTunnelIpv6),
                        serverEndpointIpv4: stringOrNull(serverEndpointIpv4),
                        serverEndpointHostname: stringOrNull(serverEndpointHostname),
                        serverPublicKey: stringOrNull(serverPublicKey),
                        clientPublicKey: stringOrNull(clientPublicKey),
                        lastErrorCode: stringOrNull(lastErrorCode),
                        lastErrorMessage: stringOrNull(lastErrorMessage),
                    });
                }
            });
        }

        return vpnData;

    } catch (error) {
        console.warn("Error fetching VPNs:", error);
        return [];
    }
};

const getAdminVPNs = async (user: User): Promise<VPNClientData[]> => {
    try {        
        if (await getUserRole(user) !== "admin") {
            console.warn("Not an admin. Cannot fetch VPNs for admin.");
            return [];
        }

        const db = getFirestore();
        const usersSnapshot = await getDocs(collection(db, "Users"));

        let vpnData: VPNClientData[] = [];

        // for (const userDoc of usersSnapshot.docs) {
        //     vpnData.push(...await getVPNs(userDoc.id, userDoc.data().email))
        // }

        // Same thing but this parallelizes to increase efficiency
        vpnData = (await Promise.all(
            usersSnapshot.docs.map(userDoc => getVPNs(userDoc.id, userDoc.data().email))
        )).flat();

        return vpnData;

    } catch (error) {
        console.warn("Error fetching VPNs for admin:", error);
        return [];
    }
}
