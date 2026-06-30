import React, { useState } from "react";
import type { ApiHelperResult, RegionSyncResponse } from "../helpers/APIHelper";
import { downloadSyncLog } from "../helpers/syncLog";

type RegionSyncCardProps = {
    regionId: string;
    displayName?: string;
    result: ApiHelperResult<RegionSyncResponse>;
};

const Count: React.FC<{ label: string; value: number }> = ({ label, value }) => (
    <span className="rounded-md bg-inset px-2 py-1 text-sm text-content-secondary">
        {label}: <span className="font-semibold text-content">{value}</span>
    </span>
);

export const RegionSyncCard: React.FC<RegionSyncCardProps> = ({ regionId, displayName, result }) => {
    const [showLog, setShowLog] = useState(false);
    const title = displayName ? `${displayName} (${regionId})` : regionId;

    if (!result.success) {
        return (
            <div className="rounded-lg border border-danger bg-card p-4 shadow-sm">
                <div className="flex flex-wrap items-center justify-between gap-2">
                    <h3 className="font-semibold text-content">{title}</h3>
                    <span className="rounded-md bg-danger px-2 py-1 text-sm text-white">Failed</span>
                </div>
                <p className="mt-2 text-sm text-danger">{result.error}</p>
                {result.requestId && (
                    <p className="mt-1 text-xs text-content-muted">Request ID: {result.requestId}</p>
                )}
            </div>
        );
    }

    const { added, updated, removed, noChanges, log, syncedAt } = result.data;

    return (
        <div className="rounded-lg border border-edge-subtle bg-card p-4 shadow-sm">
            <div className="flex flex-wrap items-center justify-between gap-2">
                <h3 className="font-semibold text-content">{title}</h3>
                <span className="text-xs text-content-muted">{new Date(syncedAt).toLocaleString()}</span>
            </div>

            <div className="mt-3 flex flex-wrap gap-2">
                <Count label="Added" value={added} />
                <Count label="Updated" value={updated} />
                <Count label="Removed" value={removed} />
            </div>

            {noChanges && (
                <p className="mt-2 text-sm text-content-muted">No changes were required.</p>
            )}

            <div className="mt-3 flex flex-wrap gap-2">
                <button
                    type="button"
                    onClick={() => setShowLog((value) => !value)}
                    className="cursor-pointer rounded-lg border border-edge-subtle px-3 py-2 text-sm text-content transition hover:bg-inset"
                    aria-expanded={showLog}
                >
                    {showLog ? "Hide log" : "View log"}
                </button>
                <button
                    type="button"
                    onClick={() => downloadSyncLog(regionId, log, syncedAt)}
                    className="cursor-pointer rounded-lg bg-primary px-3 py-2 text-sm text-white transition hover:bg-primary-hover"
                >
                    Download .log
                </button>
            </div>

            {showLog && (
                <pre className="mt-3 max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-lg border border-edge-faint bg-inset p-3 text-xs text-content-secondary">
                    {log}
                </pre>
            )}
        </div>
    );
};
