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
    onConfirm: () => void;
    onClose: () => void;
    // Server Health blocks confirmation while a mesh-membership write is still
    // unresolved; Home has no such writes and leaves both unset.
    confirmDisabled?: boolean;
    confirmDisabledReason?: string;
};

// Reused by Home (confirm -> navigate to Server Health, which owns the
// actual fetch) and by the Server Health page itself (confirm -> run the
// fan-out in place). Mesh changes are inherently all-region, so this always
// lists every enabled region - there is no per-region selection.
// Both call sites close this before the run starts, so progress and errors
// belong to the page, not to the modal.
export const SyncRegionsConfirmModal: React.FC<SyncRegionsConfirmModalProps> = ({
    open,
    regions,
    onConfirm,
    onClose,
    confirmDisabled = false,
    confirmDisabledReason,
}) => {
    const modalRef = useModalDialog<HTMLDivElement>(open, onClose);

    if (!open) return null;

    return (
        <div
            className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
            onClick={onClose}
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
                            Reconciles client peers and mesh links across every enabled region. Regions you left unchecked are synced too: their cross-region peers and routes are removed.
                        </p>
                    </div>
                    <button
                        type="button"
                        onClick={onClose}
                        className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg text-content-muted transition hover:bg-inset hover:text-content"
                        aria-label="Close sync all regions"
                    >
                        <X size={20} aria-hidden="true" />
                    </button>
                </div>

                <div className="min-h-0 flex-1 overflow-y-auto p-6">
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

                {confirmDisabled && confirmDisabledReason && (
                    <p role="status" className="border-t border-edge-faint px-6 pt-4 text-sm text-content-muted">
                        {confirmDisabledReason}
                    </p>
                )}

                <div className="flex flex-col-reverse gap-3 border-t border-edge-faint bg-card p-4 sm:flex-row sm:justify-end sm:px-6">
                    <button
                        type="button"
                        onClick={onClose}
                        className="rounded-lg bg-inset-strong px-5 py-3 text-sm font-semibold text-content-secondary transition hover:bg-inset-strong-hover"
                    >
                        Cancel
                    </button>
                    <button
                        type="button"
                        onClick={onConfirm}
                        disabled={regions.length === 0 || confirmDisabled}
                        title={confirmDisabled ? confirmDisabledReason : undefined}
                        className="flex items-center justify-center gap-2 rounded-lg bg-primary px-5 py-3 text-sm font-semibold text-white transition hover:bg-primary-hover disabled:cursor-not-allowed disabled:bg-disabled disabled:text-content-disabled"
                    >
                        <RefreshCw size={17} aria-hidden="true" />
                        {`Sync ${regions.length} region${regions.length === 1 ? "" : "s"}`}
                    </button>
                </div>
            </div>
        </div>
    );
};
