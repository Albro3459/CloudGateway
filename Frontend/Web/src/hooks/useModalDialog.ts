import { useEffect, useRef } from "react";

// Adds dialog behavior to a hand-rolled modal overlay: focus moves into the
// dialog on open, Tab is trapped within it, Escape requests close, and focus is
// restored to the previously focused element on close. Attach the returned ref
// to the dialog container and give it role="dialog"/aria-modal. onClose is read
// through a ref so the effect only re-runs when `open` changes.
export const useModalDialog = <T extends HTMLElement>(
    open: boolean,
    onClose: () => void,
) => {
    const containerRef = useRef<T | null>(null);
    const onCloseRef = useRef(onClose);
    onCloseRef.current = onClose;

    useEffect(() => {
        if (!open) {
            return;
        }

        const previouslyFocused = document.activeElement as HTMLElement | null;
        const container = containerRef.current;

        const focusableElements = () =>
            container
                ? Array.from(
                      container.querySelectorAll<HTMLElement>(
                          'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])',
                      ),
                  )
                : [];

        const initial = focusableElements();
        (initial[0] ?? container)?.focus();

        const handleKeyDown = (event: KeyboardEvent) => {
            if (event.key === "Escape") {
                event.preventDefault();
                onCloseRef.current();
                return;
            }
            if (event.key !== "Tab") {
                return;
            }
            const items = focusableElements();
            if (items.length === 0) {
                event.preventDefault();
                container?.focus();
                return;
            }
            const first = items[0];
            const last = items[items.length - 1];
            const active = document.activeElement as HTMLElement | null;
            if (event.shiftKey && active === first) {
                event.preventDefault();
                last.focus();
            } else if (!event.shiftKey && active === last) {
                event.preventDefault();
                first.focus();
            }
        };

        document.addEventListener("keydown", handleKeyDown, true);
        return () => {
            document.removeEventListener("keydown", handleKeyDown, true);
            previouslyFocused?.focus?.();
        };
    }, [open]);

    return containerRef;
};
