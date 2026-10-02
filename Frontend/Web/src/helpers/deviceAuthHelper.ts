import { buildApexApiEndpoint } from "./apiEndpoints";
import { sendJsonRequest } from "./APIHelper";
import type { ApiHelperResult } from "./APIHelper";

export type DeviceAuthState = "pending" | "approved" | "denied" | "consumed";

export type DeviceVerification = {
    deviceName: string | null;
    userCode: string;
    state: DeviceAuthState;
    expiresAt: string;
};

export type DeviceDecision = {
    state: "approved" | "denied";
};

export type DeviceApprovalRoute = {
    deviceRequestId: string;
    userCode: string;
    path: string;
};

const requestIdPattern = /^[a-f0-9]{32}$/;
const userCodePattern = /^\d{6}$/;

export const parseDeviceApprovalRoute = (rawPath: unknown): DeviceApprovalRoute | null => {
    if (typeof rawPath !== "string") return null;
    const [pathname, rawQuery, ...extra] = rawPath.split("?");
    if (pathname !== "/auth/code" || !rawQuery || extra.length > 0) return null;

    const params = new URLSearchParams(rawQuery);
    if ([...params.keys()].length !== 2) return null;
    const deviceRequestId = params.get("deviceRequestId");
    const userCode = params.get("userCode");
    if (!deviceRequestId || !requestIdPattern.test(deviceRequestId)) return null;
    if (!userCode || !userCodePattern.test(userCode)) return null;

    return {
        deviceRequestId,
        userCode,
        path: `/auth/code?deviceRequestId=${deviceRequestId}&userCode=${userCode}`,
    };
};

const isRecord = (value: unknown): value is Record<string, unknown> => (
    Boolean(value) && typeof value === "object" && !Array.isArray(value)
);

const postDeviceAuth = async <TResponse>(
    path: "device/verify" | "device/approve",
    token: string,
    body: Record<string, string>,
): Promise<ApiHelperResult<TResponse>> => sendJsonRequest<TResponse>(
    buildApexApiEndpoint(path),
    token,
    "POST",
    body,
);

const isDeviceAuthState = (value: unknown): value is DeviceAuthState => (
    value === "pending" || value === "approved" || value === "denied" || value === "consumed"
);

const parseDeviceVerification = (value: unknown, expectedCode: string): DeviceVerification | null => {
    if (!isRecord(value)) return null;
    if (value.deviceName !== null && typeof value.deviceName !== "string") return null;
    if (value.userCode !== expectedCode || !isDeviceAuthState(value.state)) return null;
    if (typeof value.expiresAt !== "string" || Number.isNaN(Date.parse(value.expiresAt))) return null;
    return {
        deviceName: value.deviceName,
        userCode: value.userCode,
        state: value.state,
        expiresAt: value.expiresAt,
    };
};

export const verifyDeviceRequest = async (
    deviceRequestId: string,
    userCode: string,
    token: string,
): Promise<ApiHelperResult<DeviceVerification>> => {
    const result = await postDeviceAuth<unknown>("device/verify", token, { deviceRequestId, userCode });
    if (!result.success) return result;
    const verification = parseDeviceVerification(result.data, userCode);
    return verification
        ? { success: true, data: verification }
        : { success: false, error: "The device authorization service returned an invalid response.", errorCode: "INCOMPATIBLE_RESPONSE" };
};

export const decideDeviceRequest = async (
    deviceRequestId: string,
    userCode: string,
    decision: "approve" | "deny",
    token: string,
): Promise<ApiHelperResult<DeviceDecision>> => {
    const result = await postDeviceAuth<unknown>("device/approve", token, { deviceRequestId, userCode, decision });
    if (!result.success) return result;
    if (!isRecord(result.data) || result.data.state !== (decision === "approve" ? "approved" : "denied")) {
        return { success: false, error: "The device authorization service returned an invalid response.", errorCode: "INCOMPATIBLE_RESPONSE" };
    }
    return { success: true, data: { state: result.data.state as "approved" | "denied" } };
};
