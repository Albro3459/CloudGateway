import React, { useMemo, useState } from "react";
import { Download, QrCode, Trash2, Copy } from "lucide-react";

import { CopyableValue } from "./CopyableValue";
import { formatVPNStatus, VPN_STATUS, VPNStatus } from "../helpers/vpnStatus";

export type VPNTableEntry = {
    userID: string;
    email: string | null;
    region: string | null;
    ipv4: string | null;
    status: VPNStatus;
    wireguardConfig: string | null;
    ownerUid: string;
    ownerEmail: string | null;
    clientId: string;
    clientName: string | null;
    regionId: string | null;
    assignedTunnelIpv4: string | null;
    assignedTunnelIpv6: string | null;
    serverEndpointIpv4: string | null;
    serverEndpointHostname: string | null;
    serverPublicKey: string | null;
    clientPublicKey: string | null;
    createdAt: Date | null;
    lastErrorCode: string | null;
    lastErrorMessage: string | null;
};

type VPNTableData = {
    data: VPNTableEntry[] | null;
    isAdmin: boolean;
    selectedClientKeys: Set<string>;
    getClientKey: (entry: VPNTableEntry) => string;
    onSelectionChange: (entry: VPNTableEntry, selected: boolean) => void;
    onRemoveSelected: () => void;
    onQRCodeClick: (entry: VPNTableEntry) => void;
    onDownloadConfig: (entry: VPNTableEntry) => void;
    removing: boolean;
    activeRegionName: string;
};

const getStatusBadgeClasses = (status: VPNStatus) => {
    switch (status) {
        case VPN_STATUS.ACTIVE:
            return "bg-success-soft text-success-strong border-success-soft-edge";
        case VPN_STATUS.CREATING:
            return "bg-warning-soft text-warning-strong border-warning-soft-edge";
        case VPN_STATUS.FAILED:
            return "bg-danger-soft text-danger-strong border-danger-soft-edge";
        case VPN_STATUS.REMOVED:
            return "bg-neutral-strong text-white border-neutral-strong";
        default:
            return "bg-inset text-content-secondary border-edge-subtle";
    }
};

const canShowConfig = (entry: VPNTableEntry) => (
    entry.status === VPN_STATUS.ACTIVE && !!entry.wireguardConfig
);

const canRemove = (entry: VPNTableEntry) => entry.status !== VPN_STATUS.REMOVED;

const formatCreatedAt = (createdAt: Date | null) => {
    if (!createdAt) return "Unknown";

    return new Intl.DateTimeFormat(undefined, {
        year: "numeric",
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit",
    }).format(createdAt);
};

const getCreatedAtTime = (entry: VPNTableEntry) => entry.createdAt?.getTime() || 0;

const sortByCreatedAt = (a: VPNTableEntry, b: VPNTableEntry, sortAsc: boolean) => {
    const result = getCreatedAtTime(a) - getCreatedAtTime(b);
    return sortAsc ? result : -result;
};

const sortedData = (data: VPNTableEntry[], sortField: string | null, sortAsc: boolean, isAdmin: boolean) => {
    return [...data].sort((a, b) => {
        if (!sortField) return 0;

        if (sortField === "default") {
            if (!isAdmin) return sortByCreatedAt(a, b, false);

            const userResult = String(a.ownerEmail || a.email || "").localeCompare(String(b.ownerEmail || b.email || ""));
            return userResult || sortByCreatedAt(a, b, false);
        }

        if (sortField === "createdAt") {
            return sortByCreatedAt(a, b, sortAsc);
        }

        let aVal = a[sortField as keyof VPNTableEntry];
        let bVal = b[sortField as keyof VPNTableEntry];

        aVal = aVal || "";
        bVal = bVal || "";

        return sortAsc
            ? String(aVal).localeCompare(String(bVal))
            : String(bVal).localeCompare(String(aVal));
    });
};

type VPNTableRowData = {
    entry: VPNTableEntry;
    isAdmin: boolean;
    selected: boolean;
    onSelectionChange: (entry: VPNTableEntry, selected: boolean) => void;
    onQRCodeClick: (entry: VPNTableEntry) => void;
    onDownloadConfig: (entry: VPNTableEntry) => void;
};

const VPNTableRow: React.FC<VPNTableRowData> = ({
    entry,
    isAdmin,
    selected,
    onSelectionChange,
    onQRCodeClick,
    onDownloadConfig,
}) => {
    const configAvailable = canShowConfig(entry);
    const removeAvailable = canRemove(entry);
    const [configCopied, setConfigCopied] = useState(false);

    const copyConfig = async () => {
        if (!entry.wireguardConfig) return;

        try {
            await navigator.clipboard.writeText(entry.wireguardConfig);
            setConfigCopied(true);
            window.setTimeout(() => setConfigCopied(false), 1400);
        } catch (error) {
            console.error("Unable to copy WireGuard config:", error);
        }
    };

    return (
        <tr className="border-b border-edge-faint hover:bg-inset">
            <td className="px-3 py-4 text-center align-middle">
                <input
                    type="checkbox"
                    checked={selected}
                    disabled={!removeAvailable}
                    onChange={(e) => onSelectionChange(entry, e.target.checked)}
                    aria-label={`Select ${entry.clientName || entry.clientId} for removal`}
                    className="h-4 w-4 rounded border-edge text-primary focus:ring-focus disabled:cursor-not-allowed disabled:opacity-40"
                />
            </td>
            <td className="px-3 py-3 align-middle">
                <div className="font-medium text-content">{entry.clientName || "Unnamed client"}</div>
                <div className="mt-1 font-mono text-xs text-content-muted">{entry.clientId}</div>
            </td>
            {isAdmin && (
                <td className="px-3 py-3 align-middle">
                    <div className="text-sm text-content">{entry.ownerEmail || entry.email || "Unknown user"}</div>
                    <div className="mt-1 font-mono text-xs text-content-muted">{entry.ownerUid || entry.userID}</div>
                </td>
            )}
            <td className="px-3 py-3 text-center align-middle">{formatCreatedAt(entry.createdAt)}</td>
            <td className="px-3 py-3 text-center align-middle">
                <span className={`inline-flex items-center rounded-full border px-2.5 py-1 text-xs font-medium ${getStatusBadgeClasses(entry.status)}`}>
                    {formatVPNStatus(entry.status)}
                </span>
                {entry.status === VPN_STATUS.FAILED && entry.lastErrorMessage && (
                    <div className="mx-auto mt-1 max-w-44 text-xs text-danger-content">{entry.lastErrorMessage}</div>
                )}
            </td>
            <td className="px-3 py-3 text-center align-middle">
                <CopyableValue
                    value={entry.serverEndpointHostname || entry.serverEndpointIpv4 || entry.ipv4}
                    label={`${entry.clientName || entry.clientId} server endpoint`}
                />
            </td>
            <td className="px-3 py-3 align-middle">
                <div className="flex items-center justify-center gap-2">
                    <button
                        type="button"
                        onClick={() => configAvailable && onQRCodeClick(entry)}
                        disabled={!configAvailable}
                        className={configAvailable ? "rounded p-1.5 text-accent hover:bg-primary-soft hover:text-accent-strong focus:outline-none focus:ring-2 focus:ring-focus" : "cursor-not-allowed rounded p-1.5 text-content-disabled"}
                        aria-label={`Show QR code for ${entry.clientName || entry.clientId}`}
                        title={configAvailable ? "Show QR code" : "Config not available"}
                    >
                        <QrCode size={18} />
                    </button>
                    <button
                        type="button"
                        onClick={() => configAvailable && onDownloadConfig(entry)}
                        disabled={!configAvailable}
                        className={configAvailable ? "rounded p-1.5 text-accent hover:bg-primary-soft hover:text-accent-strong focus:outline-none focus:ring-2 focus:ring-focus" : "cursor-not-allowed rounded p-1.5 text-content-disabled"}
                        aria-label={`Download config for ${entry.clientName || entry.clientId}`}
                        title={configAvailable ? "Download config" : "Config not available"}
                    >
                        <Download size={18} />
                    </button>
                    <button
                        type="button"
                        onClick={copyConfig}
                        disabled={!entry.wireguardConfig}
                        className={entry.wireguardConfig ? "rounded p-1.5 text-accent hover:bg-primary-soft hover:text-accent-strong focus:outline-none focus:ring-2 focus:ring-focus" : "cursor-not-allowed rounded p-1.5 text-content-disabled"}
                        aria-label={`Copy config for ${entry.clientName || entry.clientId}`}
                        title={entry.wireguardConfig ? "Copy config" : "Config not available"}
                    >
                        <Copy size={18} />
                    </button>
                </div>
                <div className={`mt-1 text-center text-xs ${entry.wireguardConfig ? "text-content-muted" : "text-content-faint"}`}>
                    {configCopied ? "Copied" : entry.wireguardConfig ? "Stored" : "No config"}
                </div>
            </td>
        </tr>
    );
};

export const VPNTable: React.FC<VPNTableData> = ({
    data,
    isAdmin,
    selectedClientKeys,
    getClientKey,
    onSelectionChange,
    onRemoveSelected,
    onQRCodeClick,
    onDownloadConfig,
    removing,
    activeRegionName,
}) => {
    const [showConfirm, setShowConfirm] = useState(false);
    const [sortField, setSortField] = useState<string | null>("default");
    const [sortAsc, setSortAsc] = useState(false);
    const selectedCount = selectedClientKeys.size;
    const colSpan = isAdmin ? 7 : 6;

    const rows = useMemo(() => (
        data ? sortedData(data, sortField, sortAsc, isAdmin) : null
    ), [data, sortField, sortAsc, isAdmin]);

    const handleSort = (field: string) => {
        if (sortField === field) {
            setSortAsc(!sortAsc);
        } else {
            setSortField(field);
            setSortAsc(true);
        }
    };

    return (
        <div className="mt-6 w-full max-w-7xl rounded-lg bg-card p-4 shadow-lg md:p-6">
            <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                <div>
                    <h2 className="text-xl font-semibold text-content">VPN Clients</h2>
                    <p className="mt-1 text-sm text-content-muted">{activeRegionName}</p>
                </div>
                <button
                    type="button"
                    onClick={() => setShowConfirm(true)}
                    disabled={selectedCount === 0 || removing}
                    className={`inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2 text-sm font-medium transition ${
                        selectedCount > 0 && !removing
                            ? "cursor-pointer bg-danger-btn text-white hover:bg-danger-btn-hover"
                            : "cursor-not-allowed bg-disabled text-content-disabled"
                    }`}
                >
                    <Trash2 size={16} />
                    Remove Selected
                    {selectedCount > 0 ? ` (${selectedCount})` : ""}
                </button>
            </div>

            {showConfirm && (
                <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
                    <div className="w-full max-w-sm rounded-lg bg-card p-6 text-center shadow-lg">
                        <h3 className="mb-3 text-lg font-semibold">Confirm Removal</h3>
                        <p className="mb-6 text-sm text-content-secondary">
                            Remove {selectedCount} selected client{selectedCount === 1 ? "" : "s"} from {activeRegionName}?
                        </p>
                        <div className="flex justify-center gap-3">
                            <button
                                type="button"
                                onClick={() => setShowConfirm(false)}
                                className="rounded-lg bg-inset-strong px-4 py-2 text-content-secondary transition hover:bg-inset-strong-hover"
                            >
                                Cancel
                            </button>
                            <button
                                type="button"
                                onClick={() => {
                                    setShowConfirm(false);
                                    onRemoveSelected();
                                }}
                                className="rounded-lg bg-danger-btn px-4 py-2 text-white transition hover:bg-danger-btn-hover"
                            >
                                Remove
                            </button>
                        </div>
                    </div>
                </div>
            )}

            <div className="overflow-x-auto">
                <table className="min-w-full text-left text-sm text-content-secondary">
                    <thead className="border-b border-edge-subtle text-content">
                        <tr>
                            <th className="px-3 py-2 text-center">Select</th>
                            <th
                                className="cursor-pointer px-3 py-2"
                                onClick={() => handleSort("clientName")}
                            >
                                Client
                            </th>
                            {isAdmin && (
                                <th
                                    className="cursor-pointer px-3 py-2"
                                    onClick={() => handleSort("ownerEmail")}
                                >
                                    User
                                </th>
                            )}
                            <th
                                className="cursor-pointer px-3 py-2 text-center"
                                onClick={() => handleSort("createdAt")}
                            >
                                Created
                            </th>
                            <th
                                className="cursor-pointer px-3 py-2 text-center"
                                onClick={() => handleSort("status")}
                            >
                                Status
                            </th>
                            <th className="px-3 py-2 text-center">Endpoint</th>
                            <th className="px-3 py-2 text-center">Config</th>
                        </tr>
                    </thead>
                    <tbody>
                        {data === null && (
                            <tr className="border-b border-edge-faint">
                                {Array.from({ length: colSpan }).map((_, index) => (
                                    <td key={index} className="px-3 py-4">
                                        <div className="mx-auto h-4 w-24 animate-pulse rounded bg-inset-strong" />
                                    </td>
                                ))}
                            </tr>
                        )}
                        {data?.length === 0 && (
                            <tr>
                                <td colSpan={colSpan} className="px-4 py-8 text-center text-content-muted">
                                    No VPN clients in this region.
                                </td>
                            </tr>
                        )}
                        {rows && rows.length > 0 && rows.map((entry) => (
                            <VPNTableRow
                                key={getClientKey(entry)}
                                entry={entry}
                                isAdmin={isAdmin}
                                selected={selectedClientKeys.has(getClientKey(entry))}
                                onSelectionChange={onSelectionChange}
                                onQRCodeClick={onQRCodeClick}
                                onDownloadConfig={onDownloadConfig}
                            />
                        ))}
                    </tbody>
                </table>
            </div>
        </div>
    );
};
