import React, { useState } from "react";
import { createPortal } from "react-dom";
import { Download, Monitor, X } from "lucide-react";

import { macAppRelease } from "../helpers/macAppRelease";
import { useModalDialog } from "../hooks/useModalDialog";

export const MacAppDownloadButton: React.FC<{ className: string }> = ({ className }) => {
    const [open, setOpen] = useState(false);
    const close = () => setOpen(false);
    const modalRef = useModalDialog<HTMLDivElement>(open, close);

    return (
        <>
            <button
                type="button"
                onClick={() => setOpen(true)}
                className={className}
                aria-label="Download Mac app"
                title="Download Mac app"
                aria-haspopup="dialog"
            >
                <Download size={19} aria-hidden="true" />
            </button>
            {open && createPortal(
                <div
                    className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
                    onClick={close}
                    onPointerDown={event => event.stopPropagation()}
                    onPointerMove={event => event.stopPropagation()}
                    onPointerUp={event => event.stopPropagation()}
                    onPointerCancel={event => event.stopPropagation()}
                >
                    <div
                        ref={modalRef}
                        role="dialog"
                        aria-modal="true"
                        aria-labelledby="mac-app-download-title"
                        aria-describedby="mac-app-download-description"
                        tabIndex={-1}
                        className="max-h-[calc(100vh-2rem)] w-full max-w-md overflow-y-auto rounded-lg border border-edge-faint bg-card text-left shadow-lg focus:outline-none"
                        onClick={event => event.stopPropagation()}
                    >
                        <div className="flex items-start justify-between gap-4 border-b border-edge-faint p-6">
                            <div>
                                <Monitor className="mb-3 text-accent" size={28} aria-hidden="true" />
                                <h3 id="mac-app-download-title" className="text-xl font-semibold text-content">
                                    Download CloudGateway for Mac
                                </h3>
                                <p className="mt-2 text-sm text-content-muted">
                                    Version {macAppRelease.version} · Build {macAppRelease.build}
                                </p>
                            </div>
                            <button
                                type="button"
                                onClick={close}
                                className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg text-content-muted transition hover:bg-inset hover:text-content"
                                aria-label="Close Mac app download"
                            >
                                <X size={20} aria-hidden="true" />
                            </button>
                        </div>
                        <div id="mac-app-download-description" className="space-y-3 p-6 text-sm text-content-secondary">
                            <p>Requires macOS 26 or later and an Apple silicon Mac.</p>
                            <p>Open the downloaded DMG, then drag CloudGateway into Applications. Sign in to your CloudGateway account inside the app.</p>
                        </div>
                        <div className="flex flex-col-reverse gap-3 border-t border-edge-faint p-4 sm:flex-row sm:justify-end sm:px-6">
                            <button
                                type="button"
                                onClick={close}
                                className="rounded-lg bg-inset-strong px-5 py-3 text-sm font-semibold text-content-secondary transition hover:bg-inset-strong-hover"
                            >
                                Cancel
                            </button>
                            <a
                                href={macAppRelease.downloadUrl}
                                onClick={close}
                                className="flex items-center justify-center gap-2 rounded-lg bg-primary px-5 py-3 text-sm font-semibold text-white transition hover:bg-primary-hover"
                            >
                                <Download size={17} aria-hidden="true" />
                                Download for Mac
                            </a>
                        </div>
                    </div>
                </div>,
                document.body,
            )}
        </>
    );
};
