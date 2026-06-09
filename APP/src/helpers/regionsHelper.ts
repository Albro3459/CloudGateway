export const oci_regions: Region[] = [
    { name: "California", value: "us-sanjose-1" },
];

export type RegionCapacity = {
    limit: number;
    active: number;
    available: number;
}

export type Region = {
    name: string;
    value: string;
    enabled?: boolean;
    capacity?: RegionCapacity;
}

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
