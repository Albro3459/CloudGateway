import React from "react";
import { Moon, Sun } from "lucide-react";

import { useThemeStore } from "../stores/themeStore";

export const ThemeToggle: React.FC = () => {
    const { theme, toggleTheme } = useThemeStore();
    const isDark = theme === "dark";
    const label = isDark ? "Switch to light mode" : "Switch to dark mode";
    const Icon = isDark ? Sun : Moon;

    return (
        <button
            type="button"
            onClick={toggleTheme}
            className="flex h-10 w-10 shrink-0 cursor-pointer items-center justify-center rounded-lg bg-nav-btn text-accent transition hover:bg-nav-btn-hover focus:outline-none focus:ring-2 focus:ring-white/80"
            aria-label={label}
            title={label}
        >
            <Icon size={18} aria-hidden="true" />
        </button>
    );
};
