import { fireEvent, render, screen, within } from "@testing-library/react";

import { AppNav } from "../AppNav";

jest.mock("react-router-dom", () => ({
    useNavigate: () => jest.fn(),
}), { virtual: true });

describe("Mac app download", () => {
    it.each(["public", "signed in"])("confirms the download from the %s navbar", state => {
        render(<AppNav subtitle={state === "signed in" ? "user@example.com" : undefined} showAbout />);
        expect(screen.queryByRole("dialog")).toBeNull();
        expect(screen.queryByRole("link", { name: "Download for Mac" })).toBeNull();

        fireEvent.click(screen.getByRole("button", { name: "Download Mac app" }));
        const dialog = screen.getByRole("dialog", { name: "Download CloudGateway for Mac" });
        expect(within(dialog).getByText("Requires macOS 26 or later and an Apple silicon Mac.")).toBeTruthy();
        const link = within(dialog).getByRole("link", { name: "Download for Mac" });
        expect(link.getAttribute("href")).toBe("https://github.com/Albro3459/CloudGateway/releases/download/macos-v1.0.0-build.2/CloudGateway-1.0.0-2-arm64.dmg");
        expect(dialog.closest("nav")).toBeNull();

        fireEvent.click(link);
        expect(screen.queryByRole("dialog")).toBeNull();
    });

    it("dismisses without downloading and restores keyboard focus", () => {
        render(<AppNav />);
        const opener = screen.getByRole("button", { name: "Download Mac app" });
        opener.focus();
        fireEvent.click(opener);
        fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
        expect(screen.queryByRole("dialog")).toBeNull();
        expect(document.activeElement).toBe(opener);

        fireEvent.click(opener);
        fireEvent.keyDown(document, { key: "Escape" });
        expect(screen.queryByRole("dialog")).toBeNull();
        expect(document.activeElement).toBe(opener);
    });

    it("keeps keyboard focus inside the dialog and closes from the backdrop", () => {
        render(<AppNav />);
        fireEvent.click(screen.getByRole("button", { name: "Download Mac app" }));
        const close = screen.getByRole("button", { name: "Close Mac app download" });
        expect(document.activeElement).toBe(close);
        fireEvent.keyDown(document, { key: "Tab", shiftKey: true });
        expect(document.activeElement).toBe(screen.getByRole("link", { name: "Download for Mac" }));

        const dialog = screen.getByRole("dialog");
        fireEvent.click(dialog);
        expect(screen.getByRole("dialog")).toBeTruthy();
        fireEvent.click(dialog.parentElement!);
        expect(screen.queryByRole("dialog")).toBeNull();
    });

    it("does not trigger dashboard pull-to-refresh through the portal", () => {
        const onPointer = jest.fn();
        render(
            <div onPointerDown={onPointer} onPointerMove={onPointer} onPointerUp={onPointer} onPointerCancel={onPointer}>
                <AppNav />
            </div>
        );
        fireEvent.click(screen.getByRole("button", { name: "Download Mac app" }));
        const dialog = screen.getByRole("dialog");
        fireEvent.pointerDown(dialog, { clientY: 20 });
        fireEvent.pointerMove(dialog, { clientY: 220 });
        fireEvent.pointerUp(dialog, { clientY: 220 });
        fireEvent.pointerCancel(dialog);
        expect(onPointer).not.toHaveBeenCalled();
    });
});
