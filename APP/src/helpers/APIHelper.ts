import { buildAccessCheckApiEndpoint, buildCreateUserApiEndpoint, buildRegionalApiEndpoint } from "./apiEndpoints";
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
    method: "POST" | "DELETE",
    body: unknown,
): Promise<ApiHelperResult<TResponse>> => {
    try {
        const response = await fetch(endpoint, {
            method,
            headers: authHeaders(token),
            body: JSON.stringify(body),
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
