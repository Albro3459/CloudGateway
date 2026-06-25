import { VPN_STATUS, VPNStatus } from "./vpnStatus";

type VPNClientKeyFields = {
    userID: string;
    region: string | null;
    clientId: string;
};

type VPNClientVisibilityFields = VPNClientKeyFields & {
    status: VPNStatus;
};

const LOAD_VISIBLE_STATUSES: VPNStatus[] = [
    VPN_STATUS.CREATING,
    VPN_STATUS.ACTIVE,
    VPN_STATUS.FAILED,
];

export const getClientKey = (entry: VPNClientKeyFields) => (
    `${entry.userID}:${entry.region || ""}:${entry.clientId}`
);

export const shouldShowVPNClient = (
    entry: VPNClientVisibilityFields,
    sessionRemovedClientKeys: Set<string>,
) => (
    LOAD_VISIBLE_STATUSES.includes(entry.status)
    || (
        entry.status === VPN_STATUS.REMOVED
        && sessionRemovedClientKeys.has(getClientKey(entry))
    )
);

export const filterVisibleVPNClients = <T extends VPNClientVisibilityFields>(
    entries: T[],
    sessionRemovedClientKeys: Set<string>,
) => entries.filter(entry => shouldShowVPNClient(entry, sessionRemovedClientKeys));
