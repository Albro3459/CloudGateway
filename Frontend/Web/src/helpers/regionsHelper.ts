import { numberOrDefault, stringOrNull } from "./coerce";

export type RegionCapacity = {
    status: "known";
    limit: number;
    allocated: number;
} | {
    status: "unknown";
};

export type Region = {
    regionId: string;
    displayName: string;
    enabled?: boolean;
    wireguardEndpointIpv4?: string | null;
    wireguardEndpointIpv6?: string | null;
    wireguardEndpointHostname?: string | null;
    wireguardPort?: number;
    wireguardDnsIpv4?: string | null;
    wireguardDnsIpv6?: string | null;
    wireguardPublicKey?: string | null;
    displayOrder: number;
    healthStatus?: string | null;
    capacity?: RegionCapacity;
}

export const parseRegionDocument = (regionId: string, data: Record<string, unknown>): Region | null => {
    const displayName = stringOrNull(data.displayName);
    if (!regionId || !displayName) {
        return null;
    }

    return {
        regionId: regionId,
        displayName: displayName,
        enabled: data.enabled === true,
        wireguardEndpointIpv4: stringOrNull(data.wireguardEndpointIpv4),
        wireguardEndpointIpv6: stringOrNull(data.wireguardEndpointIpv6),
        wireguardEndpointHostname: stringOrNull(data.wireguardEndpointHostname),
        wireguardPort: numberOrDefault(data.wireguardPort, 51820),
        wireguardDnsIpv4: stringOrNull(data.wireguardDnsIpv4),
        wireguardDnsIpv6: stringOrNull(data.wireguardDnsIpv6),
        wireguardPublicKey: stringOrNull(data.wireguardPublicKey),
        displayOrder: numberOrDefault(data.displayOrder, 1000),
        healthStatus: stringOrNull(data.healthStatus),
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

// Preselect a region on load: walk the enabled regions in display order and
// pick the first one that has a config for the current user, falling back to
// the first region when the user has none anywhere. `enabledRegions` is
// expected in display order (callers filter a sorted list). Returns "" only
// when there are no regions, which check-access would already have blocked.
export const resolveActiveRegionId = (
    enabledRegions: Region[],
    regionIdsWithConfig: Set<string>
): string => {
    if (!enabledRegions.length) return "";
    const withConfig = enabledRegions.find(region => regionIdsWithConfig.has(region.regionId));
    return (withConfig ?? enabledRegions[0]).regionId;
};

export const getRegionName = (region: string | null, regions: Region[] | null): string => {
    if (!region) return '';
    return regions?.find(r => r.regionId === region)?.displayName || region;
};

export const isRegionAtCapacity = (region: Region | null | undefined): boolean => {
    if (!region?.capacity || region.capacity.status !== "known") return false;
    return region.capacity.allocated >= region.capacity.limit;
};

export const isRegionCapacityKnown = (region: Region | null | undefined): boolean => (
    region?.capacity?.status === "known"
);

export const getRegionCapacityLabel = (region: Region | null | undefined): string => {
    if (!region?.capacity || region.capacity.status !== "known") return "Capacity unavailable";
    return `${region.capacity.allocated} / ${region.capacity.limit} used`;
};
