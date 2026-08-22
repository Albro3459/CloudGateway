import React from "react";
import { Activity, ArrowLeft, Home, Info, RefreshCw } from "lucide-react";
import { useNavigate } from "react-router-dom";

import { ThemeToggle } from "./ThemeToggle";

type AppNavProps = {
    subtitle?: string | null;
    showAbout?: boolean;
    homePath?: string;
    back?: boolean;
    onRefresh?: () => void;
    refreshDisabled?: boolean;
    refreshing?: boolean;
    // Admin-only link into the Server Health page; omit for non-admins so the
    // affordance never renders rather than rendering disabled.
    serverHealthPath?: string;
    children?: React.ReactNode;
};

const navButtonClasses = "flex h-10 w-10 shrink-0 cursor-pointer items-center justify-center rounded-lg bg-nav-btn text-accent transition hover:bg-nav-btn-hover focus:outline-none focus:ring-2 focus:ring-white/80 disabled:cursor-not-allowed disabled:text-content-disabled";

export const AppNav: React.FC<AppNavProps> = ({
    subtitle,
    showAbout = false,
    homePath,
    back = false,
    onRefresh,
    refreshDisabled = false,
    refreshing = false,
    serverHealthPath,
    children,
}) => {
    const navigate = useNavigate();

    // On a direct entry or bookmark there is no in-app history entry, so
    // navigate(-1) would leave CloudGateway entirely. React Router stamps its
    // own index onto the history state, which is absent for the first entry.
    const goBack = () => {
        const historyIndex = (window.history.state as { idx?: number } | null)?.idx;
        if (typeof historyIndex === "number" && historyIndex > 0) {
            navigate(-1);
            return;
        }
        navigate(homePath || "/");
    };

    return (
        <nav className="fixed left-0 top-0 z-40 w-full border-b border-edge-faint bg-nav shadow-md">
            <div className="mx-auto flex min-h-[68px] w-full max-w-7xl items-center gap-3 px-4 py-3 sm:px-6">
                <div className="min-w-0 flex-1">
                    <div className="truncate text-base font-semibold text-white">CloudGateway</div>
                    {subtitle && (
                        <div className="truncate text-xs text-white/75">{subtitle}</div>
                    )}
                </div>

                <div className="flex shrink-0 items-center gap-2">
                    {back && (
                        <button
                            type="button"
                            onClick={goBack}
                            className={navButtonClasses}
                            aria-label="Go back"
                            title="Go back"
                        >
                            <ArrowLeft size={19} aria-hidden="true" />
                        </button>
                    )}
                    {showAbout && (
                        <button
                            type="button"
                            onClick={() => navigate("/about")}
                            className={navButtonClasses}
                            aria-label="About"
                            title="About"
                        >
                            <Info size={19} aria-hidden="true" />
                        </button>
                    )}
                    {onRefresh && (
                        <button
                            type="button"
                            onClick={onRefresh}
                            className={`${navButtonClasses} hidden sm:flex`}
                            aria-label="Refresh"
                            title="Refresh"
                            disabled={refreshDisabled}
                        >
                            <RefreshCw className={refreshing ? "animate-spin" : ""} size={19} aria-hidden="true" />
                        </button>
                    )}
                    {serverHealthPath && (
                        <button
                            type="button"
                            onClick={() => navigate(serverHealthPath)}
                            className={navButtonClasses}
                            aria-label="Server Health"
                            title="Server Health"
                        >
                            <Activity size={19} aria-hidden="true" />
                        </button>
                    )}
                    <ThemeToggle />
                    {homePath && (
                        <button
                            type="button"
                            onClick={() => navigate(homePath)}
                            className={navButtonClasses}
                            aria-label="Home"
                            title="Home"
                        >
                            <Home size={19} aria-hidden="true" />
                        </button>
                    )}
                    {children}
                </div>
            </div>
        </nav>
    );
};
