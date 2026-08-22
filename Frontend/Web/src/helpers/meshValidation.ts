const HOSTNAME_LABEL = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/;

export const isValidWireGuardPublicKey = (value: unknown): value is string => {
    if (typeof value !== "string" || !/^[A-Za-z0-9+/]{43}=$/.test(value)) return false;
    try {
        return atob(value).length === 32;
    } catch {
        return false;
    }
};

const parseIPv4 = (value: string): number[] | null => {
    const parts = value.split(".");
    if (parts.length !== 4) return null;
    const octets = parts.map(part => {
        if (!/^\d{1,3}$/.test(part) || (part.length > 1 && part.startsWith("0"))) return -1;
        const parsed = Number(part);
        return parsed >= 0 && parsed <= 255 ? parsed : -1;
    });
    return octets.some(octet => octet < 0) ? null : octets;
};

const parseIPv6 = (value: string): number[] | null => {
    if (!value || value.includes(".")) return null;
    const halves = value.split("::");
    if (halves.length > 2) return null;

    const parseHalf = (half: string): number[] | null => {
        if (!half) return [];
        const parts = half.split(":");
        if (parts.some(part => !/^[0-9A-Fa-f]{1,4}$/.test(part))) return null;
        return parts.map(part => Number.parseInt(part, 16));
    };

    const left = parseHalf(halves[0]);
    const right = parseHalf(halves.length === 2 ? halves[1] : "");
    if (!left || !right) return null;
    if (halves.length === 1) return left.length === 8 ? left : null;
    const gap = 8 - left.length - right.length;
    if (gap < 1) return null;
    return [...left, ...Array.from({ length: gap }, () => 0), ...right];
};

const formatIPv6Canonical = (words: number[]): string => {
    const parts = words.map(word => word.toString(16));
    let bestStart = -1;
    let bestLength = 0;
    for (let start = 0; start < words.length;) {
        if (words[start] !== 0) {
            start += 1;
            continue;
        }
        let end = start;
        while (end < words.length && words[end] === 0) end += 1;
        if (end - start > bestLength) {
            bestStart = start;
            bestLength = end - start;
        }
        start = end;
    }
    if (bestLength < 2) return parts.join(":");
    const left = parts.slice(0, bestStart).join(":");
    const right = parts.slice(bestStart + bestLength).join(":");
    return `${left}::${right}`;
};

export const isValidEndpointHostname = (value: unknown): value is string => {
    if (typeof value !== "string" || value.length === 0 || value.length > 253) return false;
    const ipv4 = parseIPv4(value);
    if (ipv4) return true;
    const ipv6 = parseIPv6(value);
    if (ipv6) return true;
    return value.split(".").every(label => HOSTNAME_LABEL.test(label));
};

export const isValidMeshNetworkSyntaxV4 = (value: unknown): value is string => {
    if (typeof value !== "string") return false;
    const parts = value.split("/");
    if (parts.length !== 2 || parts[1] !== "24") return false;
    const octets = parseIPv4(parts[0]);
    return Boolean(octets && octets[3] === 0 && parts[0] === octets.join("."));
};

export const isValidMeshNetworkV4 = (value: unknown): value is string => {
    if (!isValidMeshNetworkSyntaxV4(value)) return false;
    const octets = parseIPv4(value.split("/")[0]);
    return Boolean(octets && octets[0] === 10 && octets[1] === 0);
};

export const isValidMeshNetworkSyntaxV6 = (value: unknown): value is string => {
    if (typeof value !== "string") return false;
    const parts = value.split("/");
    if (parts.length !== 2 || parts[1] !== "64") return false;
    const words = parseIPv6(parts[0]);
    if (!words || formatIPv6Canonical(words) !== parts[0]) return false;
    return words[4] === 0 && words[5] === 0 && words[6] === 0 && words[7] === 0;
};

export const isValidMeshNetworkV6 = (value: unknown): value is string => {
    if (!isValidMeshNetworkSyntaxV6(value)) return false;
    const words = parseIPv6(value.split("/")[0]);
    return Boolean(words && words[0] === 0xfd42 && words[1] === 0x42 && words[2] === 0x42);
};

export const isValidMeshEndpointPort = (value: unknown): value is number => (
    typeof value === "number"
    && Number.isInteger(value)
    && value >= 1
    && value <= 65535
);

export const networksOverlap = (a: string, b: string): boolean => {
    if (isValidMeshNetworkV4(a) && isValidMeshNetworkV4(b)) {
        const aThird = Number(a.split(".")[2]);
        const bThird = Number(b.split(".")[2]);
        return aThird === bThird;
    }
    if (isValidMeshNetworkV6(a) && isValidMeshNetworkV6(b)) {
        const aWords = parseIPv6(a.split("/")[0]);
        const bWords = parseIPv6(b.split("/")[0]);
        return Boolean(aWords && bWords && aWords.slice(0, 4).every((word, index) => word === bWords[index]));
    }
    return false;
};
