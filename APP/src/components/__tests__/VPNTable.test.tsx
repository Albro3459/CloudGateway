import React from "react";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";

import { VPNTable, VPNTableEntry } from "../VPNTable";
import { VPN_STATUS } from "../../helpers/vpnStatus";

const getClientKey = (entry: VPNTableEntry) => `${entry.userID}:${entry.region || ""}:${entry.clientId}`;

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
    lastErrorCode: null,
    lastErrorMessage: null,
    ...overrides,
});

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

        render(
            <VPNTable
                data={[
                    activeEntry,
                    baseEntry({ clientId: "client-creating", clientName: "Tablet", status: VPN_STATUS.CREATING }),
                    baseEntry({ clientId: "client-failed", clientName: "Router", status: VPN_STATUS.FAILED, lastErrorMessage: "Apply failed" }),
                    removedEntry,
                ]}
                isAdmin={true}
                regions={[{
                    name: "California",
                    displayName: "California",
                    value: "us-sanjose-1",
                    regionId: "us-sanjose-1",
                    enabled: true,
                    displayOrder: 1,
                }]}
                selectedClientKeys={new Set([getClientKey(activeEntry)])}
                getClientKey={getClientKey}
                onSelectionChange={onSelectionChange}
                onRemoveSelected={onRemoveSelected}
                onQRCodeClick={jest.fn()}
                onDownloadConfig={jest.fn()}
                removing={false}
                activeRegionName="California"
            />
        );

        expect(screen.getByText("Active")).toBeTruthy();
        expect(screen.getByText("Creating")).toBeTruthy();
        expect(screen.getByText("Failed")).toBeTruthy();
        expect(screen.getByText("Removed")).toBeTruthy();
        expect(screen.getByText("Apply failed")).toBeTruthy();

        fireEvent.click(screen.getAllByLabelText(/Copy Laptop server endpoint/)[0]);
        await waitFor(() => expect(navigator.clipboard.writeText).toHaveBeenCalledWith("wg.us-sanjose-1.example.com"));
        await waitFor(() => expect(screen.getByText("Copied")).toBeTruthy());

        const removedCheckbox = screen.getByLabelText("Select Old phone for removal") as HTMLInputElement;
        expect(removedCheckbox.disabled).toBe(true);

        fireEvent.click(screen.getByText("Remove Selected (1)"));
        fireEvent.click(screen.getByText("Remove"));
        expect(onRemoveSelected).toHaveBeenCalledTimes(1);
    });
});
