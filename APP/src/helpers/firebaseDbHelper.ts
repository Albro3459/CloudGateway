import { User } from "firebase/auth";
import { auth, signOut } from "../firebase";
import { getFirestore, collection, getDocs } from "firebase/firestore";
import { NavigateFunction } from "react-router-dom";

import { getUserRole } from "./usersHelper";
import { normalizeVPNStatus, VPN_STATUS, VPNStatus } from "./vpnStatus";
import { useOciRegionsStore } from "../stores/ociRegionsStore";

export const logout = async (navigate: NavigateFunction) => {
    useOciRegionsStore.getState().clearOciRegions();
    await signOut(auth);
    navigate("/", { replace: true });
};

export type VPNData = {
    userID: string;
    email: string | null;
    region: string | null;
    instanceID: string;
    ipv4: string | null;
    status: VPNStatus;
    wireguardConfig: string | null;
}

export const getUsersVPNs = async (user: User): Promise<VPNData[]> => {

    if (await getUserRole(user) === "admin") {
        return await getAdminVPNs(user);
    }

    return await getVPNs(user.uid, user.email);
};

const getVPNs = async (userID: string, email: string | null): Promise<VPNData[]> => {
    try {
        if (!email) {
            console.warn("Email null for user: " + userID);
            return [];
        }

        const db = getFirestore();
        const userRef = collection(db, "Users", userID, "Regions");
        const regionSnapshots = await getDocs(userRef);

        const vpnData: VPNData[] = [];

        for (const regionDoc of regionSnapshots.docs) {
            const regionID = regionDoc.id;
            const instancesRef = collection(db, "Users", userID, "Regions", regionID, "Instances");
            const instanceSnapshots = await getDocs(instancesRef);

            instanceSnapshots.forEach((instanceDoc) => {
                const { ipv4, status: rawStatus, wireguardConfig } = instanceDoc.data();
                const status = normalizeVPNStatus(rawStatus);
                if (status && status !== VPN_STATUS.TERMINATED) {
                    vpnData.push({
                        userID: userID,
                        email: email,
                        region: regionID,
                        instanceID: instanceDoc.id,
                        ipv4: ipv4 || null,
                        status: status,
                        wireguardConfig: wireguardConfig || null,
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

const getAdminVPNs = async (user: User): Promise<VPNData[]> => {
    try {        
        if (await getUserRole(user) !== "admin") {
            console.warn("Not an admin. Cannot fetch VPNs for admin.");
            return [];
        }

        const db = getFirestore();
        const usersSnapshot = await getDocs(collection(db, "Users"));

        let vpnData: VPNData[] = [];

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
