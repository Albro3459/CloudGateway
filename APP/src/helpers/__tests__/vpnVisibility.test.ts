import { filterVisibleVPNClients, getClientKey } from "../vpnVisibility";
import { VPN_STATUS, VPNStatus } from "../vpnStatus";

const baseClient = (clientId: string, status: VPNStatus) => ({
    userID: "user-1",
    region: "us-sanjose-1",
    clientId,
    status,
});

describe("vpnVisibility", () => {
    it("shows creating, active, and failed clients on initial load but hides removed", () => {
        const clients = [
            baseClient("creating-client", VPN_STATUS.CREATING),
            baseClient("active-client", VPN_STATUS.ACTIVE),
            baseClient("failed-client", VPN_STATUS.FAILED),
            baseClient("removed-client", VPN_STATUS.REMOVED),
        ];

        expect(filterVisibleVPNClients(clients, new Set()).map(client => client.clientId)).toEqual([
            "creating-client",
            "active-client",
            "failed-client",
        ]);
    });

    it("keeps a same-session removed client visible until browser refresh", () => {
        const removedClient = baseClient("removed-client", VPN_STATUS.REMOVED);
        const sessionRemovedClientKeys = new Set([getClientKey(removedClient)]);

        expect(filterVisibleVPNClients([removedClient], sessionRemovedClientKeys)).toEqual([removedClient]);
        expect(filterVisibleVPNClients([removedClient], new Set())).toEqual([]);
    });
});
