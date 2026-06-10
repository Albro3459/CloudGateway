export const oci_regions: Region[] = [
    { name: "California", displayName: "California", value: "us-sanjose-1", regionId: "us-sanjose-1", enabled: true, displayOrder: 1000 },
];

export type RegionCapacity = {
    limit: number;
    active: number;
    available: number;
}

export type Region = {
    name: string;
    value: string;
    regionId: string;
    displayName: string;
    enabled?: boolean;
    wireguardEndpointIpv4?: string | null;
    wireguardEndpointIpv6?: string | null;
    wireguardPort?: number;
    wireguardDnsIpv4?: string | null;
    wireguardDnsIpv6?: string | null;
    wireguardPublicKey?: string | null;
    capacityLimit?: number;
    activeClientCount?: number;
    displayOrder: number;
    healthStatus?: string | null;
    capacity?: RegionCapacity;
}

const numberOrDefault = (value: unknown, fallback: number) => {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
};

const stringOrNull = (value: unknown) => typeof value === "string" && value.trim()
    ? value
    : null;

export const parseRegionDocument = (regionId: string, data: Record<string, unknown>): Region | null => {
    const displayName = stringOrNull(data.displayName);
    if (!regionId || !displayName) {
        return null;
    }

    const capacityLimit = Math.max(0, numberOrDefault(data.capacityLimit, 0));
    const activeClientCount = Math.max(0, numberOrDefault(data.activeClientCount, 0));

    return {
        name: displayName,
        value: regionId,
        regionId,
        displayName,
        enabled: data.enabled === true,
        wireguardEndpointIpv4: stringOrNull(data.wireguardEndpointIpv4),
        wireguardEndpointIpv6: stringOrNull(data.wireguardEndpointIpv6),
        wireguardPort: numberOrDefault(data.wireguardPort, 51820),
        wireguardDnsIpv4: stringOrNull(data.wireguardDnsIpv4),
        wireguardDnsIpv6: stringOrNull(data.wireguardDnsIpv6),
        wireguardPublicKey: stringOrNull(data.wireguardPublicKey),
        capacityLimit,
        activeClientCount,
        displayOrder: numberOrDefault(data.displayOrder, 1000),
        healthStatus: stringOrNull(data.healthStatus),
        capacity: {
            limit: capacityLimit,
            active: activeClientCount,
            available: Math.max(0, capacityLimit - activeClientCount),
        },
    };
};

export const sortRegions = (regions: Region[]) => (
    [...regions].sort((a, b) => {
        if (a.displayOrder !== b.displayOrder) {
            return a.displayOrder - b.displayOrder;
        }

        return a.regionId.localeCompare(b.regionId);
    })
);

export const getRegionName = (region: string | null, regions: Region[] | null = oci_regions): string => {
    if (!region) return '';
    return (regions || oci_regions).find(r => r.value === region)?.name || region;
};

export const isRegionAtCapacity = (region: Region | null | undefined): boolean => {
    if (!region?.capacity) return false;
    return region.capacity.active >= region.capacity.limit;
};

export const getRegionCapacityLabel = (region: Region | null | undefined): string => {
    if (!region?.capacity) return "";
    return `${region.capacity.active} / ${region.capacity.limit} used`;
};
