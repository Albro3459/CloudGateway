import React from "react";
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";

import { VPNTable, VPNTableEntry } from "../VPNTable";
import { VPN_STATUS } from "../../helpers/vpnStatus";

const getClientKey = (entry: VPNTableEntry) => `${entry.userID}:${entry.region || ""}:${entry.clientId}`;
const newerCreatedAt = new Date("2025-06-15T14:30:00Z");
const olderCreatedAt = new Date("2025-06-14T08:15:00Z");

const formatCreatedAt = (createdAt: Date) => new Intl.DateTimeFormat(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
}).format(createdAt);

const baseEntry = (overrides: Partial<VPNTableEntry>): VPNTableEntry => ({
    userID: "user-1",
    email: "user@example.com",
    region: "us-sanjose-1",
    ipv4: "203.0.113.10",
    status: VPN_STATUS.ACTIVE,
    wireguardConfig: "[Interface]\nPrivateKey = key",
    ownerUid: "user-1",
    ownerEmail: "user@example.com",
    clientId: "client-1",
    clientName: "Laptop",
    regionId: "us-sanjose-1",
    assignedTunnelIpv4: "10.0.0.2/32",
    assignedTunnelIpv6: "fd42:42:42::2/128",
    serverEndpointIpv4: "203.0.113.10",
    serverEndpointHostname: "wg.us-sanjose-1.example.com",
    serverPublicKey: "server-key",
    clientPublicKey: "client-key",
    createdAt: olderCreatedAt,
    lastErrorCode: null,
    lastErrorMessage: null,
    ...overrides,
});

const renderVPNTable = (props: {
    data: VPNTableEntry[];
    isAdmin: boolean;
    selectedClientKeys?: Set<string>;
    onSelectionChange?: jest.Mock;
    onRemoveSelected?: jest.Mock;
}) => (
    render(
        <VPNTable
            data={props.data}
            isAdmin={props.isAdmin}
            selectedClientKeys={props.selectedClientKeys || new Set()}
            getClientKey={getClientKey}
            onSelectionChange={props.onSelectionChange || jest.fn()}
            onRemoveSelected={props.onRemoveSelected || jest.fn()}
            onQRCodeClick={jest.fn()}
            onDownloadConfig={jest.fn()}
            removing={false}
            activeRegionName="San Jose"
        />
    )
);

const getBodyRows = () => screen.getAllByRole("row").slice(1);

describe("VPNTable", () => {
    beforeEach(() => {
        Object.assign(navigator, {
            clipboard: {
                writeText: jest.fn().mockResolvedValue(undefined),
            },
        });
    });

    it("renders client states, copies shown endpoints, and removes selected clients", async () => {
        const activeEntry = baseEntry({});
        const removedEntry = baseEntry({
            clientId: "client-removed",
            clientName: "Old phone",
            status: VPN_STATUS.REMOVED,
            wireguardConfig: null,
        });
        const onSelectionChange = jest.fn();
        const onRemoveSelected = jest.fn();

        renderVPNTable({
            data: [
                activeEntry,
                baseEntry({ clientId: "client-creating", clientName: "Tablet", status: VPN_STATUS.CREATING }),
                baseEntry({ clientId: "client-failed", clientName: "Router", status: VPN_STATUS.FAILED, lastErrorMessage: "Apply failed" }),
                removedEntry,
            ],
            isAdmin: true,
            selectedClientKeys: new Set([getClientKey(activeEntry)]),
            onSelectionChange,
            onRemoveSelected,
        });

        expect(screen.getByText("Active")).toBeTruthy();
        expect(screen.getByText("Creating")).toBeTruthy();
        expect(screen.getByText("Failed")).toBeTruthy();
        expect(screen.getByText("Removed")).toBeTruthy();
        expect(screen.getByText("Apply failed")).toBeTruthy();
        expect(screen.queryByText("Region")).toBeNull();
        expect(screen.getByText("Created")).toBeTruthy();
        expect(screen.getAllByText(formatCreatedAt(olderCreatedAt)).length).toBeGreaterThan(0);
        expect(screen.queryByText("Stored")).toBeNull();
        expect(screen.queryByText("No config")).toBeNull();

        fireEvent.click(screen.getByLabelText("Copy config for Laptop"));
        await waitFor(() => expect(navigator.clipboard.writeText).toHaveBeenCalledWith("[Interface]\nPrivateKey = key"));
        expect(await screen.findByText("Copied")).toBeTruthy();
        await waitFor(() => expect(screen.queryByLabelText("Copy config for Laptop")).toBeNull());

        fireEvent.click(screen.getAllByLabelText(/Copy Laptop server endpoint/)[0]);
        await waitFor(() => expect(navigator.clipboard.writeText).toHaveBeenCalledWith("wg.us-sanjose-1.example.com"));

        const removedCheckbox = screen.getByLabelText("Select Old phone for removal") as HTMLInputElement;
        expect(removedCheckbox.disabled).toBe(true);

        fireEvent.click(screen.getByText("Remove Selected (1)"));
        fireEvent.click(screen.getByText("Remove"));
        expect(onRemoveSelected).toHaveBeenCalledTimes(1);
    });

    it("sorts admins by user, then newest created date first", () => {
        renderVPNTable({
            data: [
                baseEntry({ clientId: "client-c", clientName: "Charlie", ownerEmail: "b@example.com", email: "b@example.com", createdAt: new Date("2026-01-01T10:00:00Z") }),
                baseEntry({ clientId: "client-a-old", clientName: "Alpha old", ownerEmail: "a@example.com", email: "a@example.com", createdAt: olderCreatedAt }),
                baseEntry({ clientId: "client-a-new", clientName: "Alpha new", ownerEmail: "a@example.com", email: "a@example.com", createdAt: newerCreatedAt }),
            ],
            isAdmin: true,
        });

        const rows = getBodyRows();
        expect(rows[0].textContent).toContain("Alpha new");
        expect(rows[1].textContent).toContain("Alpha old");
        expect(rows[2].textContent).toContain("Charlie");
    });

    it("sorts non-admins by newest created date first without a user column", () => {
        renderVPNTable({
            data: [
                baseEntry({ clientId: "client-old", clientName: "Old client", createdAt: olderCreatedAt }),
                baseEntry({ clientId: "client-new", clientName: "New client", createdAt: newerCreatedAt }),
            ],
            isAdmin: false,
        });

        expect(screen.queryByText("User")).toBeNull();
        expect(screen.queryByText("Region")).toBeNull();
        expect(screen.queryByText("user@example.com")).toBeNull();

        const rows = getBodyRows();
        expect(within(rows[0]).getByText("New client")).toBeTruthy();
        expect(within(rows[1]).getByText("Old client")).toBeTruthy();
        expect(screen.getByText(formatCreatedAt(newerCreatedAt))).toBeTruthy();
    });
});
