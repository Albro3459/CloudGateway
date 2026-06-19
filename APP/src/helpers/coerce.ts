// Shared value-coercion helpers for parsing Firestore document fields.

export const stringOrNull = (value: unknown): string | null => (
    typeof value === "string" && value.trim() ? value : null
);

export const numberOrDefault = (value: unknown, fallback: number): number => {
    if (typeof value === "number") {
        return Number.isFinite(value) ? value : fallback;
    }

    if (typeof value === "string" && value.trim() !== "") {
        const parsed = Number(value);
        return Number.isFinite(parsed) ? parsed : fallback;
    }

    return fallback;
};

export const dateOrNull = (value: unknown): Date | null => {
    if (value instanceof Date) return value;
    if (typeof value === "string" || typeof value === "number") {
        const date = new Date(value);
        return Number.isNaN(date.getTime()) ? null : date;
    }
    if (value && typeof value === "object" && "toDate" in value && typeof value.toDate === "function") {
        const date = value.toDate();
        return date instanceof Date && !Number.isNaN(date.getTime()) ? date : null;
    }

    return null;
};
