import { normalizeVPNStatus, VPN_STATUS } from "../vpnStatus";

describe("vpnStatus", () => {
    it("normalizes contract client statuses", () => {
        expect(normalizeVPNStatus("creating")).toBe(VPN_STATUS.CREATING);
        expect(normalizeVPNStatus(" ACTIVE ")).toBe(VPN_STATUS.ACTIVE);
        expect(normalizeVPNStatus("failed")).toBe(VPN_STATUS.FAILED);
        expect(normalizeVPNStatus("removed")).toBe(VPN_STATUS.REMOVED);
        expect(Object.values(VPN_STATUS)).toEqual([
            "creating",
            "active",
            "failed",
            "removed",
        ]);
    });

    it("maps legacy deploy statuses to client statuses", () => {
        expect(normalizeVPNStatus("pending")).toBe(VPN_STATUS.CREATING);
        expect(normalizeVPNStatus("running")).toBe(VPN_STATUS.ACTIVE);
        expect(normalizeVPNStatus("terminated")).toBe(VPN_STATUS.REMOVED);
    });

    it("rejects unknown statuses", () => {
        expect(normalizeVPNStatus("deploying")).toBeNull();
        expect(normalizeVPNStatus(null)).toBeNull();
    });
});
