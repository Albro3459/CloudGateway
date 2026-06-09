import { DEPLOY_API_PATH, SECURE_GET_API_PATH } from "./apiEndpoints";

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

const getApiErrorMessage = (result: unknown, status: number) => {
    if (result && typeof result === "object" && "error" in result) {
        const error = (result as { error?: unknown }).error;
        if (typeof error === "string" && error) {
            return error;
        }
    }

    if (typeof result === "string" && result) {
        return result;
    }

    return `Error ${status}`;
};

export const SecureGetRegionsHelper = async (token: string) => {
    try {
        const myHeaders = new Headers();
        myHeaders.append("Authorization", `Bearer ${token}`);
        myHeaders.append("Content-Type", "application/json");

        const raw = JSON.stringify({ "requested": "regions" });

        const requestOptions: RequestInit = {
            method: "POST",
            headers: myHeaders,
            body: raw,
            redirect: "follow"
        };

        const response = await fetch(SECURE_GET_API_PATH, requestOptions);
        const result = await parseApiResponse(response);

        if (!response.ok) {
            return {
                success: false,
                error: getApiErrorMessage(result, response.status),
                data: result
            };
        }

        return {
            success: true,
            data: result
        };
        
    } catch (error) {
        console.error("Secure Get Regions API Error:", error);
        return {
            success: false,
            error: error instanceof Error ? error.message : "Unknown Secure Get Regions API Error"
        };
    }
};

export const SecureGetWireguardConfigHelper = async (public_ipv4: string, token: string) => {
    try {
        const myHeaders = new Headers();
        myHeaders.append("Authorization", `Bearer ${token}`);
        myHeaders.append("Content-Type", "application/json");

        const raw = JSON.stringify({
            "requested": "config",
            "ip_addresses": {
                "public_ipv4": public_ipv4
            }
        });

        const requestOptions: RequestInit = {
            method: "POST",
            headers: myHeaders,
            body: raw,
            redirect: "follow"
        };

        const response = await fetch(SECURE_GET_API_PATH, requestOptions);
        const result = await parseApiResponse(response);

        if (!response.ok) {
            return {
                success: false,
                error: getApiErrorMessage(result, response.status),
                data: result
            };
        }

        return {
            success: true,
            data: result
        };
        
    } catch (error) {
        console.error("Secure Get Config API Error:", error);
        return {
            success: false,
            error: error instanceof Error ? error.message : "Unknown Secure Get Config API Error"
        };
    }
};


export type Targets = {
    [userID: string]: {
      [region: string]: string[]; // Array of instance IDs
    };
};

export enum ACTION {
    DEPLOY = "deploy",
    TERMINATE = "terminate"
}

export const VPNdeployHelper = async (action: ACTION, targets: Targets | null, email: string | null, region: string | null, token: string, overrideExistingVpn = false) => {
    try {
        const myHeaders = new Headers();
        myHeaders.append("Authorization", `Bearer ${token}`);
        myHeaders.append("Content-Type", "application/json");

        const raw = JSON.stringify({
            "action": action,
            "targets": targets,
            "email" : email,
            "region": region,
            "override_existing_vpn": overrideExistingVpn,
        });

        const requestOptions: RequestInit = {
            method: "POST",
            headers: myHeaders,
            body: raw,
            redirect: "follow"
        };

        const response = await fetch(DEPLOY_API_PATH, requestOptions);
        const result = await parseApiResponse(response);

        if (!response.ok) {
            return {
                success: false,
                error: getApiErrorMessage(result, response.status),
                data: result
            };
        }

        return {
            success: true,
            data: result
        };
        
    } catch (error) {
        console.error("Deploy API Error:", error);
        return {
            success: false,
            error: error instanceof Error ? error.message : "Unknown Deploy API Error"
        };
    }
};
