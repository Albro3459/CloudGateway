const VPN_CLIENT_STATUS = {
    CREATING: "creating",
    ACTIVE: "active",
    FAILED: "failed",
    REMOVED: "removed",
} as const;

export const VPN_STATUS = Object.defineProperties(VPN_CLIENT_STATUS, {
    PENDING: { value: VPN_CLIENT_STATUS.CREATING },
    RUNNING: { value: VPN_CLIENT_STATUS.ACTIVE },
    TERMINATED: { value: VPN_CLIENT_STATUS.REMOVED },
}) as typeof VPN_CLIENT_STATUS & {
    PENDING: typeof VPN_CLIENT_STATUS.CREATING;
    RUNNING: typeof VPN_CLIENT_STATUS.ACTIVE;
    TERMINATED: typeof VPN_CLIENT_STATUS.REMOVED;
};

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

const LEGACY_VPN_STATUS_MAP: Record<string, VPNStatus> = {
    pending: VPN_STATUS.CREATING,
    running: VPN_STATUS.ACTIVE,
    terminated: VPN_STATUS.REMOVED,
};

export const normalizeVPNStatus = (status: unknown): VPNStatus | null => {
    if (typeof status !== "string") {
        return null;
    }

    const normalizedStatus = status.trim().toLowerCase();
    if (normalizedStatus in LEGACY_VPN_STATUS_MAP) {
        return LEGACY_VPN_STATUS_MAP[normalizedStatus];
    }

    return VPN_STATUS_VALUES.includes(normalizedStatus as VPNStatus)
        ? normalizedStatus as VPNStatus
        : null;
};

export const formatVPNStatus = (status: VPNStatus) => {
    return status[0].toUpperCase() + status.slice(1);
};
