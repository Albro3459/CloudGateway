export const VPN_STATUS = {
    FAILED: "failed",
    PENDING: "pending",
    RUNNING: "running",
    TERMINATED: "terminated",
} as const;

export type VPNStatus = typeof VPN_STATUS[keyof typeof VPN_STATUS];

const VPN_STATUS_VALUES = Object.values(VPN_STATUS) as VPNStatus[];

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
