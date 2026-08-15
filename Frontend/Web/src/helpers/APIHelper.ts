import { buildAccessCheckApiEndpoint, buildApexApiEndpoint, buildCreateUserApiEndpoint, buildRegionalApiEndpoint } from "./apiEndpoints";
import type { ApiRegionOption } from "./apiEndpoints";
import {
    isValidEndpointHostname,
    isValidMeshEndpointPort,
    isValidMeshNetworkSyntaxV4,
    isValidMeshNetworkSyntaxV6,
    isValidMeshNetworkV4,
    isValidMeshNetworkV6,
} from "./meshValidation";

type FastApiError = {
    code?: string;
    message?: string;
    requestId?: string;
};

type FastApiErrorResponse = {
    error?: FastApiError | string;
};

type ApiHelperSuccess<T> = {
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
    failureType?: "incompatible-response";
};

type IncompatibleResponseFailure = ApiHelperFailure & {
    success: false;
    failureType: "incompatible-response";
    errorCode: "INCOMPATIBLE_RESPONSE";
};

export type ApiHelperResult<T> = ApiHelperSuccess<T> | ApiHelperFailure;

export type CreateClientRequest = {
    regionId: string;
    clientName: string;
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

export type DeleteAccountResponse = {
    userId: string;
    deletedClientCount: number;
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

type RegionSummary = {
    regionId: string;
    displayName: string;
    displayOrder: number;
};

export type RegionsResponse = {
    regions: RegionSummary[];
};

type RegionSyncMeshPeerStatus = "applied" | "skipped-overlap" | "skipped-incomplete";
type RegionSyncMeshPeerReasonCode =
    | "missing-public-key"
    | "invalid-public-key"
    | "missing-endpoint-hostname"
    | "invalid-endpoint-hostname"
    | "invalid-endpoint-port"
    | "missing-network-v4"
    | "invalid-network-v4"
    | "missing-network-v6"
    | "invalid-network-v6"
    | "outside-aggregate"
    | "duplicate-public-key"
    | "local-network-invalid"
    | "overlap-local"
    | "overlap-candidate";

type RegionSyncMeshPeer = {
    regionId: string;
    status: RegionSyncMeshPeerStatus;
    endpointHostname?: string;
    endpointPort?: number | null;
    allowedNetworkV4?: string;
    allowedNetworkV6?: string;
    reasonCode?: RegionSyncMeshPeerReasonCode | null;
};

export type RegionSyncResponse = {
    regionId: string;
    syncedAt: string;
    added: number;
    updated: number;
    removed: number;
    noChanges: boolean;
    log: string;
    meshUpdated: number;
    meshEnabled: boolean;
    meshApplied: number;
    meshAdded: number;
    meshRemoved: number;
    meshSkipped: number;
    meshRoutesAdded: number;
    meshRoutesRemoved: number;
    // null when the region predates the field: unknown, not a failure. Regions
    // are deployed independently, so a newer dashboard routinely talks to a
    // host that has not been reinstalled yet.
    meshStatusWritten: boolean | null;
    meshPeers: RegionSyncMeshPeer[];
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

type SendJsonRequestOptions = {
    timeoutMs?: number;
};

const sendJsonRequest = async <TResponse>(
    endpoint: string,
    token: string,
    method: "GET" | "POST" | "DELETE",
    body?: unknown,
    options: SendJsonRequestOptions = {},
): Promise<ApiHelperResult<TResponse>> => {
    const controller = options.timeoutMs === undefined ? null : new AbortController();
    const timeoutId = options.timeoutMs === undefined
        ? undefined
        : setTimeout(() => controller?.abort(), options.timeoutMs);

    try {
        const response = await fetch(endpoint, {
            method,
            headers: authHeaders(token),
            ...(body === undefined ? {} : { body: JSON.stringify(body) }),
            redirect: "follow",
            ...(controller ? { signal: controller.signal } : {}),
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
        if (controller?.signal.aborted) {
            return {
                success: false,
                error: "Regional API request timed out.",
            };
        }
        return {
            success: false,
            error: error instanceof Error ? error.message : "Unknown API Error",
        };
    } finally {
        if (timeoutId !== undefined) clearTimeout(timeoutId);
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

export const deleteAccount = (
    token: string,
): Promise<ApiHelperResult<DeleteAccountResponse>> => (
    sendJsonRequest<DeleteAccountResponse>(
        buildApexApiEndpoint("account"),
        token,
        "DELETE",
    )
);

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

const regionSyncReasonCodes = new Set<RegionSyncMeshPeerReasonCode>([
    "missing-public-key",
    "invalid-public-key",
    "missing-endpoint-hostname",
    "invalid-endpoint-hostname",
    "invalid-endpoint-port",
    "missing-network-v4",
    "invalid-network-v4",
    "missing-network-v6",
    "invalid-network-v6",
    "outside-aggregate",
    "duplicate-public-key",
    "local-network-invalid",
    "overlap-local",
    "overlap-candidate",
]);

const isRecord = (value: unknown): value is Record<string, unknown> => (
    Boolean(value) && typeof value === "object" && !Array.isArray(value)
);

const hasOwn = (value: Record<string, unknown>, key: string): boolean => (
    Object.prototype.hasOwnProperty.call(value, key)
);

const isNonEmptyString = (value: unknown): value is string => (
    typeof value === "string" && value.trim() !== ""
);

const isNonNegativeInteger = (value: unknown): value is number => (
    typeof value === "number" && Number.isFinite(value) && Number.isInteger(value) && value >= 0
);

const parseReasonCode = (value: unknown): RegionSyncMeshPeerReasonCode | null | undefined => {
    if (value === undefined) return undefined;
    if (value === null) return null;
    return typeof value === "string" && regionSyncReasonCodes.has(value as RegionSyncMeshPeerReasonCode)
        ? value as RegionSyncMeshPeerReasonCode
        : null;
};

const parseRequiredMeshPeer = (
    value: unknown,
    status: "applied" | "skipped-overlap",
): RegionSyncMeshPeer | null => {
    if (!isRecord(value) || !isNonEmptyString(value.regionId)) return null;
    if (
        !isValidEndpointHostname(value.endpointHostname)
        || !isValidMeshEndpointPort(value.endpointPort)
        || !isValidMeshNetworkV4(value.allowedNetworkV4)
        || !isValidMeshNetworkV6(value.allowedNetworkV6)
    ) {
        return null;
    }

    const reasonCode = parseReasonCode(value.reasonCode);
    if (
        (value.reasonCode !== undefined && value.reasonCode !== null && reasonCode === null)
        || (status === "skipped-overlap" && typeof reasonCode !== "string")
    ) return null;

    return {
        regionId: value.regionId,
        status,
        endpointHostname: value.endpointHostname,
        endpointPort: value.endpointPort,
        allowedNetworkV4: value.allowedNetworkV4,
        allowedNetworkV6: value.allowedNetworkV6,
        ...(reasonCode === undefined ? {} : { reasonCode }),
    };
};

const parseOptionalNonBlankField = <TValue>(
    value: unknown,
    isValid: (fieldValue: unknown) => fieldValue is TValue,
): TValue | null | undefined => {
    if (value === undefined || value === null || (typeof value === "string" && value.trim() === "")) {
        return undefined;
    }
    return isValid(value) ? value : null;
};

const parseIncompleteMeshPeer = (value: Record<string, unknown>): RegionSyncMeshPeer | null => {
    if (!isNonEmptyString(value.regionId)) return null;
    const reasonCode = parseReasonCode(value.reasonCode);
    if (!reasonCode) return null;

    const endpointHostname = parseOptionalNonBlankField(value.endpointHostname, isValidEndpointHostname);
    const endpointPort = parseOptionalNonBlankField(value.endpointPort, isValidMeshEndpointPort);
    const allowedNetworkV4 = parseOptionalNonBlankField(value.allowedNetworkV4, isValidMeshNetworkSyntaxV4);
    const allowedNetworkV6 = parseOptionalNonBlankField(value.allowedNetworkV6, isValidMeshNetworkSyntaxV6);
    if (
        endpointHostname === null
        || endpointPort === null
        || allowedNetworkV4 === null
        || allowedNetworkV6 === null
    ) {
        return null;
    }

    return {
        regionId: value.regionId,
        status: "skipped-incomplete",
        ...(endpointHostname === undefined ? {} : { endpointHostname }),
        ...(endpointPort === undefined ? {} : { endpointPort }),
        ...(allowedNetworkV4 === undefined ? {} : { allowedNetworkV4 }),
        ...(allowedNetworkV6 === undefined ? {} : { allowedNetworkV6 }),
        reasonCode,
    };
};

const parseRegionSyncResponse = (value: unknown): RegionSyncResponse | null => {
    if (!isRecord(value)) return null;

    const requiredFields = [
        "regionId", "syncedAt", "added", "updated", "removed", "noChanges", "log", "meshUpdated",
        "meshEnabled", "meshApplied", "meshAdded", "meshRemoved", "meshSkipped", "meshRoutesAdded",
        "meshRoutesRemoved", "meshPeers",
    ];
    if (requiredFields.some(field => !hasOwn(value, field))) return null;
    if (
        !isNonEmptyString(value.regionId)
        || !isNonEmptyString(value.syncedAt)
        || Number.isNaN(Date.parse(value.syncedAt))
        || typeof value.log !== "string"
        || typeof value.noChanges !== "boolean"
        || typeof value.meshEnabled !== "boolean"
    ) {
        return null;
    }

    const counterFields = [
        "added", "updated", "removed", "meshUpdated", "meshApplied", "meshAdded", "meshRemoved",
        "meshSkipped", "meshRoutesAdded", "meshRoutesRemoved",
    ];
    if (counterFields.some(field => !isNonNegativeInteger(value[field]))) return null;
    if (!Array.isArray(value.meshPeers)) return null;
    // Deliberately not in requiredFields: absent means an older regional API, which
    // must stay compatible. A present non-boolean is still a malformed response.
    if (hasOwn(value, "meshStatusWritten") && typeof value.meshStatusWritten !== "boolean") return null;

    const meshPeers: RegionSyncMeshPeer[] = [];
    for (const rawPeer of value.meshPeers) {
        if (!isRecord(rawPeer)) return null;
        const peer = rawPeer.status === "applied"
            ? parseRequiredMeshPeer(rawPeer, "applied")
            : rawPeer.status === "skipped-overlap"
                ? parseRequiredMeshPeer(rawPeer, "skipped-overlap")
                : rawPeer.status === "skipped-incomplete"
                    ? parseIncompleteMeshPeer(rawPeer)
                    : null;
        if (!peer) return null;
        meshPeers.push(peer);
    }

    return {
        regionId: value.regionId,
        syncedAt: value.syncedAt,
        added: value.added as number,
        updated: value.updated as number,
        removed: value.removed as number,
        noChanges: value.noChanges,
        log: value.log,
        meshUpdated: value.meshUpdated as number,
        meshEnabled: value.meshEnabled,
        meshApplied: value.meshApplied as number,
        meshAdded: value.meshAdded as number,
        meshRemoved: value.meshRemoved as number,
        meshSkipped: value.meshSkipped as number,
        meshRoutesAdded: value.meshRoutesAdded as number,
        meshRoutesRemoved: value.meshRoutesRemoved as number,
        meshStatusWritten: typeof value.meshStatusWritten === "boolean" ? value.meshStatusWritten : null,
        meshPeers,
    };
};

const incompatibleResponse = (regionId: string, data: unknown): IncompatibleResponseFailure => ({
    success: false,
    failureType: "incompatible-response",
    errorCode: "INCOMPATIBLE_RESPONSE",
    error: `Incompatible admin sync response from ${regionId}.`,
    data,
});

export const REGION_SYNC_TIMEOUT_MS = 45_000;

const runRegionSync = async (
    regionId: string,
    token: string,
): Promise<ApiHelperResult<RegionSyncResponse>> => {
    try {
        const result = await sendJsonRequest<RegionSyncResponse>(
            buildRegionalApiEndpoint(regionId, "admin/sync"),
            token,
            "POST",
            { regionId },
            { timeoutMs: REGION_SYNC_TIMEOUT_MS },
        );
        if (!result.success) return result;
        const response = parseRegionSyncResponse(result.data);
        if (!response || response.regionId !== regionId) return incompatibleResponse(regionId, result.data);
        return { success: true, data: response };
    } catch (error) {
        return {
            success: false,
            error: error instanceof Error ? error.message : "Unknown API Error",
        };
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
