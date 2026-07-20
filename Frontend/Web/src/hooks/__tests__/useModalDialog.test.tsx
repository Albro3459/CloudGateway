import { fireEvent, render, screen } from "@testing-library/react";
import { useState } from "react";
import { useModalDialog } from "../useModalDialog";

const Harness = ({ onClose }: { onClose: () => void }) => {
    const [open, setOpen] = useState(false);
    const close = () => {
        setOpen(false);
        onClose();
    };
    const ref = useModalDialog<HTMLDivElement>(open, close);

    return (
        <div>
            <button onClick={() => setOpen(true)}>Open</button>
            {open && (
                <div ref={ref} role="dialog" aria-modal="true" aria-label="Test dialog" tabIndex={-1}>
                    <button>First</button>
                    <button>Second</button>
                </div>
            )}
        </div>
    );
};

describe("useModalDialog", () => {
    it("moves focus into the dialog on open", () => {
        render(<Harness onClose={jest.fn()} />);
        fireEvent.click(screen.getByRole("button", { name: "Open" }));
        expect(document.activeElement).toBe(screen.getByRole("button", { name: "First" }));
    });

    it("closes on Escape", () => {
        const onClose = jest.fn();
        render(<Harness onClose={onClose} />);
        fireEvent.click(screen.getByRole("button", { name: "Open" }));
        fireEvent.keyDown(document, { key: "Escape" });
        expect(onClose).toHaveBeenCalledTimes(1);
        expect(screen.queryByRole("dialog")).toBeNull();
    });

    it("restores focus to the opener on close", () => {
        render(<Harness onClose={jest.fn()} />);
        const opener = screen.getByRole("button", { name: "Open" });
        opener.focus();
        fireEvent.click(opener);
        fireEvent.keyDown(document, { key: "Escape" });
        expect(document.activeElement).toBe(opener);
    });

    it("wraps focus at the trap boundaries with Tab", () => {
        render(<Harness onClose={jest.fn()} />);
        fireEvent.click(screen.getByRole("button", { name: "Open" }));
        const last = screen.getByRole("button", { name: "Second" });
        last.focus();
        fireEvent.keyDown(document, { key: "Tab" });
        expect(document.activeElement).toBe(screen.getByRole("button", { name: "First" }));
    });
});
