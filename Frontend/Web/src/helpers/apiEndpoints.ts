type LocationLike = Pick<Location, "hostname" | "host">;

const API_ORIGIN = (process.env.REACT_APP_API_ORIGIN || "").replace(/\/+$/, "");

const normalizeApiPath = (path: string) => path.replace(/^\/+/, "");

const isLocalDevHostname = (hostname: string) => {
    const normalized = hostname.toLowerCase();

    return normalized === "localhost"
        || normalized === "127.0.0.1"
        || normalized === "::1"
        || normalized.endsWith(".localhost")
        || normalized.endsWith(".local");
};

const getWindowLocation = (): LocationLike => {
    if (typeof window === "undefined") {
        return { hostname: "localhost", host: "localhost" } as LocationLike;
    }

    return window.location;
};

const getFrontendOriginHost = (location: LocationLike = getWindowLocation()) => (
    isLocalDevHostname(location.hostname) ? location.host : location.hostname
);

export const getApiOriginOverride = () => API_ORIGIN;

export const buildRegionalApiEndpoint = (
    regionId: string,
    path: string,
    location: LocationLike = getWindowLocation(),
) => {
    if (!regionId.trim()) {
        throw new Error("regionId is required for regional API calls");
    }

    const apiPath = normalizeApiPath(path);
    if (API_ORIGIN) {
        return `${API_ORIGIN}/api/${apiPath}`;
    }

    return `https://${regionId}.${getFrontendOriginHost(location)}/api/${apiPath}`;
};

export const buildApexApiEndpoint = (
    path: string,
    location: LocationLike = getWindowLocation(),
) => {
    const apiPath = normalizeApiPath(path);
    if (API_ORIGIN) {
        return `${API_ORIGIN}/api/${apiPath}`;
    }

    return `https://api.${getFrontendOriginHost(location)}/api/${apiPath}`;
};

export type ApiRegionOption = {
    regionId?: string;
    enabled?: boolean;
    displayOrder?: number;
};

export const getFirstEnabledRegionId = (regions: ApiRegionOption[] | null | undefined) => {
    const sortedRegions = [...(regions || [])]
        .filter(region => region.enabled !== false && region.regionId)
        .sort((a, b) => {
            const displayOrderA = typeof a.displayOrder === "number" ? a.displayOrder : 1000;
            const displayOrderB = typeof b.displayOrder === "number" ? b.displayOrder : 1000;

            if (displayOrderA !== displayOrderB) {
                return displayOrderA - displayOrderB;
            }

            return (a.regionId || "").localeCompare(b.regionId || "");
        });

    return sortedRegions[0]?.regionId || null;
};

export const buildCreateUserApiEndpoint = (
    regions: ApiRegionOption[] | null | undefined,
    location: LocationLike = getWindowLocation(),
) => {
    if (API_ORIGIN) {
        return `${API_ORIGIN}/api/users`;
    }

    const regionId = getFirstEnabledRegionId(regions);
    if (!regionId) {
        throw new Error("No enabled regions are available for user creation");
    }

    return buildRegionalApiEndpoint(regionId, "users", location);
};

export const buildAccessCheckApiEndpoint = (
    regions: ApiRegionOption[] | null | undefined,
    location: LocationLike = getWindowLocation(),
) => {
    void regions;
    return buildApexApiEndpoint("auth/check-access", location);
};
