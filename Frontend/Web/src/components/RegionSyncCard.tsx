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

    const {
        added, updated, removed, noChanges, log, syncedAt,
        meshEnabled, meshApplied, meshAdded, meshUpdated = 0, meshRemoved, meshSkipped, meshRoutesAdded, meshRoutesRemoved, meshPeers,
    } = result.data;

    return (
        <div className="rounded-lg border border-edge-subtle bg-card p-4 shadow-sm">
            <div className="flex flex-wrap items-center justify-between gap-2">
                <h3 className="font-semibold text-content">{title}</h3>
                <div className="flex items-center gap-2">
                    <span className={`rounded-md px-2 py-1 text-xs ${
                        meshEnabled ? "bg-success-soft text-success-strong" : "bg-inset text-content-muted"
                    }`}>
                        {meshEnabled ? "Mesh enabled" : "Mesh disabled"}
                    </span>
                    <span className="text-xs text-content-muted">{new Date(syncedAt).toLocaleString()}</span>
                </div>
            </div>

            <div className="mt-3 flex flex-wrap gap-2">
                <Count label="Added" value={added} />
                <Count label="Updated" value={updated} />
                <Count label="Removed" value={removed} />
            </div>

            <div className="mt-2 flex flex-wrap gap-2">
                <Count label="Mesh applied" value={meshApplied} />
                <Count label="Mesh added" value={meshAdded} />
                <Count label="Mesh updated" value={meshUpdated} />
                <Count label="Mesh removed" value={meshRemoved} />
                <Count label="Mesh skipped" value={meshSkipped} />
                <Count label="Routes added" value={meshRoutesAdded} />
                <Count label="Routes removed" value={meshRoutesRemoved} />
            </div>

            {noChanges && (
                <p className="mt-2 text-sm text-content-muted">No changes were required.</p>
            )}

            {meshPeers.length > 0 && (
                <div className="mt-3 flex flex-wrap gap-2">
                    {meshPeers.map((peer) => (
                        <span
                            key={peer.regionId}
                            className={`rounded-md border px-2 py-1 text-xs ${
                                peer.status === "applied"
                                    ? "border-success-soft-edge bg-success-soft text-success-strong"
                                    : "border-warning-soft-edge bg-warning-soft text-warning-strong"
                            }`}
                        >
                            {peer.regionId}: {peer.status}{peer.reasonCode ? ` (${peer.reasonCode})` : ""}
                        </span>
                    ))}
                </div>
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
