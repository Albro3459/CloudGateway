import React, { useMemo, useState } from "react";
import { Download, QrCode, Trash2, Copy } from "lucide-react";

import { CopyableValue } from "./CopyableValue";
import { getRegionName, Region } from "../helpers/regionsHelper";
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
    lastErrorCode: string | null;
    lastErrorMessage: string | null;
};

type VPNTableData = {
    data: VPNTableEntry[] | null;
    isAdmin: boolean;
    regions: Region[] | null;
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
            return "bg-green-100 text-green-800 border-green-200";
        case VPN_STATUS.CREATING:
            return "bg-yellow-100 text-yellow-800 border-yellow-200";
        case VPN_STATUS.FAILED:
            return "bg-red-100 text-red-800 border-red-200";
        case VPN_STATUS.REMOVED:
            return "bg-gray-900 text-white border-gray-900";
        default:
            return "bg-gray-100 text-gray-700 border-gray-200";
    }
};

const canShowConfig = (entry: VPNTableEntry) => (
    entry.status === VPN_STATUS.ACTIVE && !!entry.wireguardConfig
);

const canRemove = (entry: VPNTableEntry) => entry.status !== VPN_STATUS.REMOVED;

const sortedData = (data: VPNTableEntry[], sortField: string | null, sortAsc: boolean, regions: Region[] | null) => {
    return [...data].sort((a, b) => {
        if (!sortField) return 0;

        let aVal = a[sortField as keyof VPNTableEntry];
        let bVal = b[sortField as keyof VPNTableEntry];

        if (sortField === "region") {
            aVal = getRegionName(a.region, regions);
            bVal = getRegionName(b.region, regions);
        } else {
            aVal = aVal || "";
            bVal = bVal || "";
        }

        return sortAsc
            ? String(aVal).localeCompare(String(bVal))
            : String(bVal).localeCompare(String(aVal));
    });
};

type VPNTableRowData = {
    entry: VPNTableEntry;
    isAdmin: boolean;
    regions: Region[] | null;
    selected: boolean;
    onSelectionChange: (entry: VPNTableEntry, selected: boolean) => void;
    onQRCodeClick: (entry: VPNTableEntry) => void;
    onDownloadConfig: (entry: VPNTableEntry) => void;
};

const VPNTableRow: React.FC<VPNTableRowData> = ({
    entry,
    isAdmin,
    regions,
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
        <tr className="border-b border-gray-100 hover:bg-gray-50">
            <td className="px-3 py-4 text-center align-middle">
                <input
                    type="checkbox"
                    checked={selected}
                    disabled={!removeAvailable}
                    onChange={(e) => onSelectionChange(entry, e.target.checked)}
                    aria-label={`Select ${entry.clientName || entry.clientId} for removal`}
                    className="h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500 disabled:cursor-not-allowed disabled:opacity-40"
                />
            </td>
            <td className="px-3 py-3 align-middle">
                <div className="font-medium text-gray-900">{entry.clientName || "Unnamed client"}</div>
                <div className="mt-1 font-mono text-xs text-gray-500">{entry.clientId}</div>
            </td>
            {isAdmin && (
                <td className="px-3 py-3 align-middle">
                    <div className="text-sm text-gray-900">{entry.ownerEmail || entry.email || "Unknown user"}</div>
                    <div className="mt-1 font-mono text-xs text-gray-500">{entry.ownerUid || entry.userID}</div>
                </td>
            )}
            <td className="px-3 py-3 text-center align-middle">{getRegionName(entry.region, regions) || "Unknown"}</td>
            <td className="px-3 py-3 text-center align-middle">
                <span className={`inline-flex items-center rounded-full border px-2.5 py-1 text-xs font-medium ${getStatusBadgeClasses(entry.status)}`}>
                    {formatVPNStatus(entry.status)}
                </span>
                {entry.status === VPN_STATUS.FAILED && entry.lastErrorMessage && (
                    <div className="mx-auto mt-1 max-w-44 text-xs text-red-700">{entry.lastErrorMessage}</div>
                )}
            </td>
            <td className="px-3 py-3 text-center align-middle">
                <CopyableValue value={entry.assignedTunnelIpv4} label={`${entry.clientName || entry.clientId} tunnel IPv4`} />
            </td>
            <td className="px-3 py-3 text-center align-middle">
                <CopyableValue value={entry.assignedTunnelIpv6} label={`${entry.clientName || entry.clientId} tunnel IPv6`} />
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
                        className={configAvailable ? "rounded p-1.5 text-blue-600 hover:bg-blue-50 hover:text-blue-800 focus:outline-none focus:ring-2 focus:ring-blue-500" : "cursor-not-allowed rounded p-1.5 text-gray-300"}
                        aria-label={`Show QR code for ${entry.clientName || entry.clientId}`}
                        title={configAvailable ? "Show QR code" : "Config not available"}
                    >
                        <QrCode size={18} />
                    </button>
                    <button
                        type="button"
                        onClick={() => configAvailable && onDownloadConfig(entry)}
                        disabled={!configAvailable}
                        className={configAvailable ? "rounded p-1.5 text-blue-600 hover:bg-blue-50 hover:text-blue-800 focus:outline-none focus:ring-2 focus:ring-blue-500" : "cursor-not-allowed rounded p-1.5 text-gray-300"}
                        aria-label={`Download config for ${entry.clientName || entry.clientId}`}
                        title={configAvailable ? "Download config" : "Config not available"}
                    >
                        <Download size={18} />
                    </button>
                    <button
                        type="button"
                        onClick={copyConfig}
                        disabled={!entry.wireguardConfig}
                        className={entry.wireguardConfig ? "rounded p-1.5 text-blue-600 hover:bg-blue-50 hover:text-blue-800 focus:outline-none focus:ring-2 focus:ring-blue-500" : "cursor-not-allowed rounded p-1.5 text-gray-300"}
                        aria-label={`Copy config for ${entry.clientName || entry.clientId}`}
                        title={entry.wireguardConfig ? "Copy config" : "Config not available"}
                    >
                        <Copy size={18} />
                    </button>
                </div>
                <div className={`mt-1 text-center text-xs ${entry.wireguardConfig ? "text-gray-500" : "text-gray-400"}`}>
                    {configCopied ? "Copied" : entry.wireguardConfig ? "Stored" : "No config"}
                </div>
            </td>
        </tr>
    );
};

export const VPNTable: React.FC<VPNTableData> = ({
    data,
    isAdmin,
    regions,
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
    const [sortField, setSortField] = useState<string | null>("clientName");
    const [sortAsc, setSortAsc] = useState(true);
    const selectedCount = selectedClientKeys.size;
    const colSpan = isAdmin ? 9 : 8;

    const rows = useMemo(() => (
        data ? sortedData(data, sortField, sortAsc, regions) : null
    ), [data, sortField, sortAsc, regions]);

    const handleSort = (field: string) => {
        if (sortField === field) {
            setSortAsc(!sortAsc);
        } else {
            setSortField(field);
            setSortAsc(true);
        }
    };

    return (
        <div className="mt-6 w-full max-w-7xl rounded-lg bg-white p-4 shadow-lg md:p-6">
            <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                <div>
                    <h2 className="text-xl font-semibold text-gray-900">VPN Clients</h2>
                    <p className="mt-1 text-sm text-gray-500">{activeRegionName}</p>
                </div>
                <button
                    type="button"
                    onClick={() => setShowConfirm(true)}
                    disabled={selectedCount === 0 || removing}
                    className={`inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2 text-sm font-medium transition ${
                        selectedCount > 0 && !removing
                            ? "cursor-pointer bg-red-600 text-white hover:bg-red-700"
                            : "cursor-not-allowed bg-gray-300 text-gray-500"
                    }`}
                >
                    <Trash2 size={16} />
                    Remove Selected
                    {selectedCount > 0 ? ` (${selectedCount})` : ""}
                </button>
            </div>

            {showConfirm && (
                <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
                    <div className="w-full max-w-sm rounded-lg bg-white p-6 text-center shadow-lg">
                        <h3 className="mb-3 text-lg font-semibold">Confirm Removal</h3>
                        <p className="mb-6 text-sm text-gray-600">
                            Remove {selectedCount} selected client{selectedCount === 1 ? "" : "s"} from {activeRegionName}?
                        </p>
                        <div className="flex justify-center gap-3">
                            <button
                                type="button"
                                onClick={() => setShowConfirm(false)}
                                className="rounded-lg bg-gray-200 px-4 py-2 text-gray-800 transition hover:bg-gray-300"
                            >
                                Cancel
                            </button>
                            <button
                                type="button"
                                onClick={() => {
                                    setShowConfirm(false);
                                    onRemoveSelected();
                                }}
                                className="rounded-lg bg-red-600 px-4 py-2 text-white transition hover:bg-red-700"
                            >
                                Remove
                            </button>
                        </div>
                    </div>
                </div>
            )}

            <div className="overflow-x-auto">
                <table className="min-w-full text-left text-sm text-gray-700">
                    <thead className="border-b border-gray-200 text-gray-900">
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
                                onClick={() => handleSort("region")}
                            >
                                Region
                            </th>
                            <th
                                className="cursor-pointer px-3 py-2 text-center"
                                onClick={() => handleSort("status")}
                            >
                                Status
                            </th>
                            <th className="px-3 py-2 text-center">Tunnel IPv4</th>
                            <th className="px-3 py-2 text-center">Tunnel IPv6</th>
                            <th className="px-3 py-2 text-center">Endpoint</th>
                            <th className="px-3 py-2 text-center">Config</th>
                        </tr>
                    </thead>
                    <tbody>
                        {data === null && (
                            <tr className="border-b border-gray-100">
                                {Array.from({ length: colSpan }).map((_, index) => (
                                    <td key={index} className="px-3 py-4">
                                        <div className="mx-auto h-4 w-24 animate-pulse rounded bg-gray-200" />
                                    </td>
                                ))}
                            </tr>
                        )}
                        {data?.length === 0 && (
                            <tr>
                                <td colSpan={colSpan} className="px-4 py-8 text-center text-gray-500">
                                    No VPN clients in this region.
                                </td>
                            </tr>
                        )}
                        {rows && rows.length > 0 && rows.map((entry) => (
                            <VPNTableRow
                                key={getClientKey(entry)}
                                entry={entry}
                                isAdmin={isAdmin}
                                regions={regions}
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
