import { buildAccessCheckApiEndpoint, buildApexApiEndpoint, buildCreateUserApiEndpoint, buildRegionalApiEndpoint } from "./apiEndpoints";
import type { ApiRegionOption } from "./apiEndpoints";

type FastApiError = {
    code?: string;
    message?: string;
    requestId?: string;
};

type FastApiErrorResponse = {
    error?: FastApiError | string;
};

export type ApiHelperSuccess<T> = {
    success: true;
    data: T;
};

export type ApiHelperFailure = {
    success: false;
    error: string;
    errorCode?: string;
    requestId?: string;
    status?: number;
    data?: unknown;
};

export type ApiHelperResult<T> = ApiHelperSuccess<T> | ApiHelperFailure;

export type CreateClientRequest = {
    regionId: string;
    clientName?: string;
};

export type CreateClientResponse = {
    clientId: string;
    regionId: string;
    clientName: string;
    status: string;
    assignedTunnelIpv4: string;
    assignedTunnelIpv6: string;
    serverEndpointIpv4: string;
    wireguardConfig: string;
};

export type DeleteClientRequest = {
    userId: string;
    regionId: string;
};

export type DeleteClientResponse = {
    userId: string;
    clientId: string;
    regionId: string;
    status: string;
};

export type CreateUserRequest = {
    email: string;
};

export type CreateUserResponse = {
    userId: string;
    email: string;
    role: string;
    alreadyExisted: boolean;
};

export type AccessCheckResponse = {
    userId: string;
    email?: string | null;
    role: string;
};

export type RegionCapacityResponse = {
    regionId: string;
    capacityLimit: number;
    allocatedClientCount: number;
};

export type RegionSummary = {
    regionId: string;
    displayName: string;
    displayOrder: number;
};

export type RegionsResponse = {
    regions: RegionSummary[];
};

export type RegionSyncResponse = {
    regionId: string;
    syncedAt: string;
    added: number;
    updated: number;
    removed: number;
    noChanges: boolean;
    log: string;
};

export type RegionSyncResult = {
    regionId: string;
    result: ApiHelperResult<RegionSyncResponse>;
};

const parseApiResponse = async (response: Response) => {
    const responseText = await response.text();
    if (!responseText) {
        return null;
    }

    try {
        return JSON.parse(responseText);
    } catch {
        return responseText;
    }
};

const getFastApiError = (result: unknown) => {
    if (!result || typeof result !== "object" || !("error" in result)) {
        return null;
    }

    const error = (result as FastApiErrorResponse).error;
    if (typeof error === "string" && error) {
        return { message: error };
    }

    if (error && typeof error === "object") {
        return {
            code: typeof error.code === "string" ? error.code : undefined,
            message: typeof error.message === "string" ? error.message : undefined,
            requestId: typeof error.requestId === "string" ? error.requestId : undefined,
        };
    }

    return null;
};

const getApiFailure = (result: unknown, status: number): ApiHelperFailure => {
    const apiError = getFastApiError(result);
    if (apiError) {
        return {
            success: false,
            error: apiError.message || apiError.code || `Error ${status}`,
            errorCode: apiError.code,
            requestId: apiError.requestId,
            status,
            data: result,
        };
    }

    return {
        success: false,
        error: typeof result === "string" && result ? result : `Error ${status}`,
        status,
        data: result,
    };
};

const authHeaders = (token: string) => {
    const headers = new Headers();
    headers.append("Authorization", `Bearer ${token}`);
    headers.append("Content-Type", "application/json");

    return headers;
};

const sendJsonRequest = async <TResponse>(
    endpoint: string,
    token: string,
    method: "GET" | "POST" | "DELETE",
    body?: unknown,
): Promise<ApiHelperResult<TResponse>> => {
    try {
        const response = await fetch(endpoint, {
            method,
            headers: authHeaders(token),
            ...(body === undefined ? {} : { body: JSON.stringify(body) }),
            redirect: "follow",
        });
        const result = await parseApiResponse(response);

        if (!response.ok) {
            return getApiFailure(result, response.status);
        }

        return {
            success: true,
            data: result as TResponse,
        };
    } catch (error) {
        return {
            success: false,
            error: error instanceof Error ? error.message : "Unknown API Error",
        };
    }
};

const sendUnauthenticatedGet = async <TResponse>(
    endpoint: string,
): Promise<ApiHelperResult<TResponse>> => {
    try {
        const response = await fetch(endpoint, {
            method: "GET",
            redirect: "follow",
        });
        const result = await parseApiResponse(response);

        if (!response.ok) {
            return getApiFailure(result, response.status);
        }

        return {
            success: true,
            data: result as TResponse,
        };
    } catch (error) {
        return {
            success: false,
            error: error instanceof Error ? error.message : "Unknown API Error",
        };
    }
};

export const fetchRegions = (): Promise<ApiHelperResult<RegionsResponse>> => (
    sendUnauthenticatedGet<RegionsResponse>(buildApexApiEndpoint("regions"))
);

export const getRegionCapacity = (
    regionId: string,
    token: string,
): Promise<ApiHelperResult<RegionCapacityResponse>> => {
    try {
        return sendJsonRequest<RegionCapacityResponse>(
            buildRegionalApiEndpoint(regionId, "capacity"),
            token,
            "GET",
        );
    } catch (error) {
        return Promise.resolve({
            success: false,
            error: error instanceof Error ? error.message : "Unknown API Error",
        });
    }
};

export const createClient = (
    request: CreateClientRequest,
    token: string,
): Promise<ApiHelperResult<CreateClientResponse>> => {
    try {
        return sendJsonRequest<CreateClientResponse>(
            buildRegionalApiEndpoint(request.regionId, "clients"),
            token,
            "POST",
            {
                regionId: request.regionId,
                ...(request.clientName ? { clientName: request.clientName } : {}),
            },
        );
    } catch (error) {
        return Promise.resolve({
            success: false,
            error: error instanceof Error ? error.message : "Unknown API Error",
        });
    }
};

export const deleteClient = (
    clientId: string,
    request: DeleteClientRequest,
    token: string,
): Promise<ApiHelperResult<DeleteClientResponse>> => {
    try {
        return sendJsonRequest<DeleteClientResponse>(
            buildRegionalApiEndpoint(request.regionId, `clients/${encodeURIComponent(clientId)}`),
            token,
            "DELETE",
            {
                userId: request.userId,
                regionId: request.regionId,
            },
        );
    } catch (error) {
        return Promise.resolve({
            success: false,
            error: error instanceof Error ? error.message : "Unknown API Error",
        });
    }
};

export const createAdminUser = (
    request: CreateUserRequest,
    token: string,
    regions: ApiRegionOption[] | null | undefined,
): Promise<ApiHelperResult<CreateUserResponse>> => {
    try {
        return sendJsonRequest<CreateUserResponse>(
            buildCreateUserApiEndpoint(regions),
            token,
            "POST",
            {
                email: request.email,
            },
        );
    } catch (error) {
        return Promise.resolve({
            success: false,
            error: error instanceof Error ? error.message : "Unknown API Error",
        });
    }
};

export const runRegionSync = (
    regionId: string,
    token: string,
): Promise<ApiHelperResult<RegionSyncResponse>> => {
    try {
        return sendJsonRequest<RegionSyncResponse>(
            buildRegionalApiEndpoint(regionId, "admin/sync"),
            token,
            "POST",
            { regionId },
        );
    } catch (error) {
        return Promise.resolve({
            success: false,
            error: error instanceof Error ? error.message : "Unknown API Error",
        });
    }
};

// Fans out one independent sync request per region. Each regional API syncs
// only its own region; one region failing does not abort the others.
export const runRegionsSync = async (
    regionIds: string[],
    token: string,
): Promise<RegionSyncResult[]> => {
    const settled = await Promise.allSettled(
        regionIds.map((regionId) => runRegionSync(regionId, token)),
    );

    return regionIds.map((regionId, index) => {
        const outcome = settled[index];
        if (outcome.status === "fulfilled") {
            return { regionId, result: outcome.value };
        }

        return {
            regionId,
            result: {
                success: false,
                error: outcome.reason instanceof Error ? outcome.reason.message : "Unknown API Error",
            },
        };
    });
};

export const checkAccountAccess = (
    token: string,
    regions: ApiRegionOption[] | null | undefined,
): Promise<ApiHelperResult<AccessCheckResponse>> => {
    try {
        return sendJsonRequest<AccessCheckResponse>(
            buildAccessCheckApiEndpoint(regions),
            token,
            "POST",
            {},
        );
    } catch (error) {
        return Promise.resolve({
            success: false,
            error: error instanceof Error ? error.message : "Unknown API Error",
        });
    }
};
