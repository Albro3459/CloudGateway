import React, { useState } from "react";
import { Copy } from "lucide-react";

type CopyableValueProps = {
    value: string | null | undefined;
    label: string;
    className?: string;
};

export const CopyableValue: React.FC<CopyableValueProps> = ({ value, label, className = "" }) => {
    const [copied, setCopied] = useState(false);
    const displayValue = value || "-";
    const canCopy = !!value;

    const copyValue = async () => {
        if (!value) return;

        try {
            await navigator.clipboard.writeText(value);
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1400);
        } catch (error) {
            console.error(`Unable to copy ${label}:`, error);
        }
    };

    return (
        <button
            type="button"
            onClick={copyValue}
            disabled={!canCopy}
            className={`group inline-flex max-w-full items-center justify-center gap-1.5 rounded border border-transparent px-1.5 py-1 font-mono text-xs transition focus:outline-none focus:ring-2 focus:ring-blue-500 ${
                canCopy
                    ? "cursor-pointer text-gray-800 hover:border-blue-200 hover:bg-blue-50 hover:text-blue-700"
                    : "cursor-not-allowed text-gray-400"
            } ${className}`}
            title={canCopy ? `Copy ${label}` : `${label} not available`}
            aria-label={canCopy ? `Copy ${label}: ${value}` : `${label} not available`}
        >
            <span className="truncate">{copied ? "Copied" : displayValue}</span>
            {canCopy && <Copy size={13} className="shrink-0 opacity-60 group-hover:opacity-100" aria-hidden="true" />}
        </button>
    );
};
