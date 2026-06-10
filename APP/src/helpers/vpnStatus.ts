export const VPN_STATUS = {
    CREATING: "creating",
    ACTIVE: "active",
    FAILED: "failed",
    REMOVED: "removed",
} as const;

export type VPNStatus =
    | typeof VPN_STATUS.CREATING
    | typeof VPN_STATUS.ACTIVE
    | typeof VPN_STATUS.FAILED
    | typeof VPN_STATUS.REMOVED;

const VPN_STATUS_VALUES: VPNStatus[] = [
    VPN_STATUS.CREATING,
    VPN_STATUS.ACTIVE,
    VPN_STATUS.FAILED,
    VPN_STATUS.REMOVED,
];

export const normalizeVPNStatus = (status: unknown): VPNStatus | null => {
    if (typeof status !== "string") {
        return null;
    }

    const normalizedStatus = status.trim().toLowerCase();
    return VPN_STATUS_VALUES.includes(normalizedStatus as VPNStatus)
        ? normalizedStatus as VPNStatus
        : null;
};

export const formatVPNStatus = (status: VPNStatus) => {
    return status[0].toUpperCase() + status.slice(1);
};
