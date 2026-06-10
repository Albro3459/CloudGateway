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

    it("rejects unknown statuses", () => {
        expect(normalizeVPNStatus("unknown")).toBeNull();
        expect(normalizeVPNStatus(null)).toBeNull();
    });
});
