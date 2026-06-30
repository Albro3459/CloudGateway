// Triggers a browser download of a region's plaintext sync audit log.

const pad = (value: number) => String(value).padStart(2, "0");

const timestampForFilename = (syncedAt: string): string => {
    const date = new Date(syncedAt);
    const valid = !Number.isNaN(date.getTime()) ? date : new Date();

    return (
        `${valid.getFullYear()}${pad(valid.getMonth() + 1)}${pad(valid.getDate())}`
        + `-${pad(valid.getHours())}${pad(valid.getMinutes())}${pad(valid.getSeconds())}`
    );
};

export const buildSyncLogFilename = (regionId: string, syncedAt: string): string => (
    `sync_log_${regionId}_${timestampForFilename(syncedAt)}.log`
);

export const downloadSyncLog = (regionId: string, log: string, syncedAt: string): void => {
    const blob = new Blob([log], { type: "text/plain" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = buildSyncLogFilename(regionId, syncedAt);
    document.body.appendChild(anchor);
    anchor.click();
    document.body.removeChild(anchor);
    URL.revokeObjectURL(url);
};
