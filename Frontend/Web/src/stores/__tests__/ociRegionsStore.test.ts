jest.mock("../../helpers/APIHelper", () => ({
    fetchRegions: jest.fn(),
    getRegionCapacity: jest.fn(),
}));

describe("ociRegionsStore", () => {
    beforeEach(() => {
        jest.clearAllMocks();
        jest.resetModules();
    });

    const mockRegions = () => {
        const { fetchRegions } = require("../../helpers/APIHelper");
        fetchRegions.mockResolvedValue({
            success: true,
            data: {
                regions: [
                    {
                        regionId: "us-sanjose-1",
                        displayName: "San Jose",
                        displayOrder: 1,
                    },
                ],
            },
        });
    };

    it("merges matching regional capacity responses", async () => {
        mockRegions();
        const { getRegionCapacity } = require("../../helpers/APIHelper");
        getRegionCapacity.mockResolvedValue({
            success: true,
            data: {
                regionId: "us-sanjose-1",
                capacityLimit: 20,
                allocatedClientCount: 8,
            },
        });
        const { fetchOciRegions, useOciRegionsStore } = require("../ociRegionsStore");

        await fetchOciRegions("firebase-token", true);

        expect(useOciRegionsStore.getState().ociRegions).toMatchObject([
            {
                regionId: "us-sanjose-1",
                capacity: {
                    status: "known",
                    limit: 20,
                    allocated: 8,
                },
            },
        ]);
    });

    it("ignores mismatched regional capacity responses", async () => {
        mockRegions();
        const { getRegionCapacity } = require("../../helpers/APIHelper");
        getRegionCapacity.mockResolvedValue({
            success: true,
            data: {
                regionId: "us-ashburn-1",
                capacityLimit: 20,
                allocatedClientCount: 20,
            },
        });
        const { fetchOciRegions, useOciRegionsStore } = require("../ociRegionsStore");

        await fetchOciRegions("firebase-token", true);

        expect(useOciRegionsStore.getState().ociRegions?.[0].regionId).toBe("us-sanjose-1");
        expect(useOciRegionsStore.getState().ociRegions?.[0].capacity).toEqual({ status: "unknown" });
    });
});
