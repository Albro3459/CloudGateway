import React, { useState } from "react";
import { QrCode } from "lucide-react";
import { Targets } from "../helpers/APIHelper";
import { TOGGLE } from "../pages/Home";
import { getRegionName, Region } from "../helpers/regionsHelper";
import { formatVPNStatus, VPN_STATUS, VPNStatus } from "../helpers/vpnStatus";

export type VPNTableEntry = {
    userID: string;
    email: string | null;
    region: string | null;
    instanceID: string;
    ipv4: string | null;
    status: VPNStatus;
    wireguardConfig: string | null;
};

type VPNTableData = {
    data: VPNTableEntry[] | null;
    isAdmin: boolean;
    regions: Region[] | null;
    targets: Targets;
    toggleTarget: (toggle: TOGGLE, userID: string, region: string | null, instanceID: string) => void;
    actionFunc: (targets: Targets) => void;
    onQRCodeClick: (entry: VPNTableEntry) => void;
};

const getStatusBadgeClasses = (status: VPNStatus) => {
    switch (status) {
        case VPN_STATUS.RUNNING:
            return "bg-green-100 text-green-800 border-green-200";
        case VPN_STATUS.PENDING:
            return "bg-yellow-100 text-yellow-800 border-yellow-200";
        case VPN_STATUS.FAILED:
            return "bg-red-100 text-red-800 border-red-200";
        case VPN_STATUS.TERMINATED:
            return "bg-red-950 text-red-50 border-red-950";
        default:
            return "bg-gray-100 text-gray-700 border-gray-200";
    }
};

const canShowConfig = (entry: VPNTableEntry) => (
    entry.status === VPN_STATUS.RUNNING && !!entry.ipv4 && !!entry.wireguardConfig
);

const sortedData = (data: VPNTableEntry[], sortField: string | null, sortAsc: boolean, regions: Region[] | null) => {
    return [...data].sort((a, b) => {
        if (!sortField) return 0;
        
        let aVal = a[sortField as keyof VPNTableEntry];
        let bVal = b[sortField as keyof VPNTableEntry];

        if (sortField === "region") {
            aVal = getRegionName(aVal, regions);
            bVal = getRegionName(bVal, regions);
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
    targets: Targets;
    toggleTarget: (toggle: TOGGLE, userID: string, region: string | null, instanceID: string) => void;
    onQRCodeClick: (entry: VPNTableEntry) => void;
};

const VPNTableRow: React.FC<VPNTableRowData> = ({ entry, isAdmin, regions, targets, toggleTarget, onQRCodeClick }) => {
    const configAvailable = canShowConfig(entry);

    return (
        <tr className="border-b border-gray-100 hover:bg-gray-50">
            {isAdmin &&
                <>
                    <td className="px-4 py-4 flex justify-center items-center">
                    <input
                        type="checkbox"
                        checked={targets?.[entry.userID]?.[entry.region || ""]?.includes(entry.instanceID) || false}
                        onChange={(e) => toggleTarget(e.target.checked ? TOGGLE.ADD : TOGGLE.REMOVE, entry.userID, entry.region, entry.instanceID) }
                    />
                    </td>
                    <td className="px-4 py-2 text-center">{entry.email || "Null"}</td>
                </>
            }
            <td className="px-4 py-2 text-center">{getRegionName(entry.region, regions) || "Null"}</td>
            <td className="px-4 py-2 text-center">{entry.ipv4 || "-"}</td>
            <td className="px-4 py-2 text-center">
                <span className={`inline-flex items-center rounded-full border px-2.5 py-1 text-xs font-medium ${getStatusBadgeClasses(entry.status)}`}>
                    {formatVPNStatus(entry.status)}
                </span>
            </td>
            <td className="px-4 py-2 flex justify-center">
                <button
                    onClick={() => configAvailable && onQRCodeClick(entry)}
                    disabled={!configAvailable}
                    className={configAvailable ? "text-blue-600 hover:text-blue-800" : "text-gray-300 cursor-not-allowed"}
                >
                    <QrCode size={20} />
                </button>
            </td>
        </tr>
    );
};

export const VPNTable: React.FC<VPNTableData> = ({ data, isAdmin, regions, targets, toggleTarget, actionFunc, onQRCodeClick }) => {

    const [showConfirm, setShowConfirm] = useState(false);
    const colSpan = isAdmin ? 6 : 4;

    const [sortField, setSortField] = useState<string | null>("region");
    const [sortAsc, setSortAsc] = useState(true);

    const handleSort = (field: string) => {
        if (sortField === field) {
            setSortAsc(!sortAsc);
        } else {
            setSortField(field);
            setSortAsc(true);
        }
    };

    return (
        <div className="bg-white mt-8 p-6 rounded-2xl shadow-lg w-full max-w-4xl relative">
            <div className="text-center relative mb-4 mt-2">
                <h2 className="text-2xl font-semibold">VPN Instances</h2>
                {isAdmin && targets && Object.keys(targets).length > 0 && (
                <>
                    <button
                        onClick={() => setShowConfirm(true)}
                        className="absolute top-0 right-0 p-2 rounded-lg transition cursor-pointer bg-red-600 text-white hover:bg-red-700"
                    >
                        Terminate
                    </button>

                    {showConfirm && (
                        <div className="fixed inset-0 z-50 bg-black/50 flex items-center justify-center">
                            <div className="bg-white p-6 rounded-xl shadow-lg max-w-sm w-full text-center">
                                <h3 className="text-lg font-semibold mb-4">
                                    Confirm Termination
                                </h3>
                                <p className="mb-6 text-sm text-gray-600">
                                    Are you sure you want to terminate the selected instances?
                                </p>
                                <div className="flex justify-center gap-4">
                                    <button
                                        onClick={() => {
                                            actionFunc(targets);
                                            setShowConfirm(false);
                                        }}
                                        className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 transition"
                                    >
                                        Yes, Terminate
                                    </button>
                                    <button
                                        onClick={() => setShowConfirm(false)}
                                        className="px-4 py-2 bg-gray-300 text-gray-800 rounded-lg hover:bg-gray-400 transition"
                                    >
                                        Cancel
                                    </button>
                                </div>
                            </div>
                        </div>
                    )}
                </>
            )}

            </div>
            
            <div className="overflow-x-auto">
                <table className="min-w-full text-sm text-left text-gray-700">
                    <thead className="border-b border-gray-200 text-gray-900">
                        <tr>
                            {isAdmin &&
                                <>
                                    <th className="px-4 py-2 text-center">Terminate</th>
                                    <th 
                                        className="px-4 py-2 text-center"
                                        onClick={() => handleSort("email")}
                                    >
                                        User
                                    </th>
                                </>
                            }
                            <th 
                                className="px-4 py-2 text-center"
                                onClick={() => handleSort("region")}
                            >
                                Region
                            </th>
                            <th className="px-4 py-2 text-center">Address</th>
                            <th className="px-4 py-2 text-center">Status</th>
                            <th className="px-4 py-2 text-center">Config</th>
                        </tr>
                    </thead>
                    <tbody>
                        {data === null && (
                            <tr className="border-b border-gray-100">
                                {isAdmin && (
                                    <>
                                        <td className="px-4 py-4"><div className="h-4 w-4 rounded bg-gray-200 animate-pulse mx-auto" /></td>
                                        <td className="px-4 py-4"><div className="h-4 w-32 rounded bg-gray-200 animate-pulse mx-auto" /></td>
                                    </>
                                )}
                                <td className="px-4 py-4"><div className="h-4 w-24 rounded bg-gray-200 animate-pulse mx-auto" /></td>
                                <td className="px-4 py-4"><div className="h-4 w-28 rounded bg-gray-200 animate-pulse mx-auto" /></td>
                                <td className="px-4 py-4"><div className="h-4 w-20 rounded bg-gray-200 animate-pulse mx-auto" /></td>
                                <td className="px-4 py-4"><div className="h-5 w-5 rounded bg-gray-200 animate-pulse mx-auto" /></td>
                            </tr>
                        )}
                        {data?.length === 0 && (
                            <tr>
                                <td colSpan={colSpan} className="px-4 py-8 text-center text-gray-500">
                                    {isAdmin ? "No active VPN instances." : "No VPN instances yet."}
                                </td>
                            </tr>
                        )}
                        {data && data.length > 0 && sortedData(data, sortField, sortAsc, regions).map((entry) => (
                            <VPNTableRow
                                key={entry.instanceID}
                                entry={entry}
                                isAdmin={isAdmin}
                                regions={regions}
                                targets={targets}
                                toggleTarget={toggleTarget}
                                onQRCodeClick={onQRCodeClick}
                            />
                        ))}
                    </tbody>
                </table>
            </div>
        </div>
    );
};
