const API_ORIGIN = (process.env.REACT_APP_API_ORIGIN || "").replace(/\/+$/, "");

const buildApiEndpoint = (path: string) => `${API_ORIGIN}${path}`;

export const DEPLOY_API_PATH = buildApiEndpoint("/api/deploy");
export const SECURE_GET_API_PATH = buildApiEndpoint("/api/secureget");
export const CREATE_USER_API_PATH = buildApiEndpoint("/api/createuser");
