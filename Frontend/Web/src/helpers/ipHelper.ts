// Strips a trailing CIDR prefix (e.g. "10.0.0.2/32" -> "10.0.0.2") for display.
export const stripCidr = (value: string | null | undefined): string | null => {
    if (!value) return null;
    return value.split("/")[0];
};
