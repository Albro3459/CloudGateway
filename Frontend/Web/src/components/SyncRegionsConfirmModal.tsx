import React from "react";
import { RefreshCw, X } from "lucide-react";

import { useModalDialog } from "../hooks/useModalDialog";

type SyncRegionsConfirmModalRegion = {
    regionId: string;
    displayName: string;
};

type SyncRegionsConfirmModalProps = {
    open: boolean;
    regions: SyncRegionsConfirmModalRegion[];
    syncing: boolean;
    error?: string | null;
    onConfirm: () => void;
    onClose: () => void;
};

// Reused by Home (confirm -> navigate to Server Health, which owns the
// actual fetch) and by the Server Health page itself (confirm -> run the
// fan-out in place). Mesh changes are inherently all-region, so this always
// lists every enabled region - there is no per-region selection.
export const SyncRegionsConfirmModal: React.FC<SyncRegionsConfirmModalProps> = ({
    open,
    regions,
    syncing,
    error,
    onConfirm,
    onClose,
}) => {
    const modalRef = useModalDialog<HTMLDivElement>(open, onClose);

    if (!open) return null;

    return (
        <div
            className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
            onClick={syncing ? undefined : onClose}
        >
            <div
                ref={modalRef}
                role="dialog"
                aria-modal="true"
                aria-labelledby="sync-all-regions-modal-title"
                tabIndex={-1}
                className="flex max-h-[calc(100vh-2rem)] w-full max-w-lg flex-col overflow-hidden rounded-lg border border-edge-faint bg-card text-left shadow-lg focus:outline-none"
                onClick={(event) => event.stopPropagation()}
            >
                <div className="flex items-start justify-between gap-4 border-b border-edge-faint p-6">
                    <div>
                        <h3 id="sync-all-regions-modal-title" className="text-2xl font-semibold text-content">Sync All Regions</h3>
                        <p className="mt-2 text-sm text-content-muted">
                            Reconciles client peers and mesh links across every enabled region. A region left out of the mesh still gets synced, so leaving is applied too.
                        </p>
                    </div>
                    <button
                        type="button"
                        onClick={onClose}
                        disabled={syncing}
                        className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg text-content-muted transition hover:bg-inset hover:text-content disabled:cursor-not-allowed"
                        aria-label="Close sync all regions"
                    >
                        <X size={20} aria-hidden="true" />
                    </button>
                </div>

                <div className="min-h-0 flex-1 overflow-y-auto p-6">
                    {error && (
                        <div className="mb-4 rounded-lg border border-danger-soft-edge bg-danger-soft px-4 py-3 text-sm text-danger-content">
                            {error}
                        </div>
                    )}

                    <ul className="grid gap-2 sm:grid-cols-2">
                        {regions.map((region) => (
                            <li
                                key={region.regionId}
                                className="rounded-lg border border-edge-faint bg-inset p-3 text-sm text-content"
                            >
                                <span className="block font-medium">{region.displayName}</span>
                                <span className="block truncate text-xs text-content-muted">{region.regionId}</span>
                            </li>
                        ))}
                    </ul>
                    {regions.length === 0 && (
                        <p className="text-sm text-content-muted">No enabled regions to sync.</p>
                    )}
                </div>

                <div className="flex flex-col-reverse gap-3 border-t border-edge-faint bg-card p-4 sm:flex-row sm:justify-end sm:px-6">
                    <button
                        type="button"
                        onClick={onClose}
                        disabled={syncing}
                        className="rounded-lg bg-inset-strong px-5 py-3 text-sm font-semibold text-content-secondary transition hover:bg-inset-strong-hover disabled:cursor-not-allowed"
                    >
                        Cancel
                    </button>
                    <button
                        type="button"
                        onClick={onConfirm}
                        disabled={syncing || regions.length === 0}
                        className="flex items-center justify-center gap-2 rounded-lg bg-primary px-5 py-3 text-sm font-semibold text-white transition hover:bg-primary-hover disabled:cursor-not-allowed disabled:bg-disabled disabled:text-content-disabled"
                    >
                        <RefreshCw className={syncing ? "animate-spin" : ""} size={17} aria-hidden="true" />
                        {syncing
                            ? "Syncing..."
                            : `Sync ${regions.length} region${regions.length === 1 ? "" : "s"}`}
                    </button>
                </div>
            </div>
        </div>
    );
};
