jest.mock("firebase/firestore", () => ({
    collection: jest.fn(),
    getDocs: jest.fn(),
    getFirestore: jest.fn(),
    query: jest.fn((...args) => args),
    where: jest.fn(),
}));

jest.mock("../../helpers/APIHelper", () => ({
    getRegionCapacity: jest.fn(),
}));

describe("ociRegionsStore", () => {
    beforeEach(() => {
        jest.clearAllMocks();
        jest.resetModules();
    });

    const mockRegionDocs = () => {
        const { getDocs } = require("firebase/firestore");
        getDocs.mockResolvedValue({
            docs: [
                {
                    id: "us-sanjose-1",
                    data: () => ({
                        displayName: "San Jose",
                        enabled: true,
                        displayOrder: 1,
                        capacityLimit: 20,
                    }),
                },
            ],
        });
    };

    it("merges matching regional capacity responses", async () => {
        mockRegionDocs();
        const { getRegionCapacity } = require("../../helpers/APIHelper");
        getRegionCapacity.mockResolvedValue({
            success: true,
            data: {
                regionId: "us-sanjose-1",
                capacityLimit: 20,
                allocatedClientCount: 8,
                availableClientCount: 12,
            },
        });
        const { fetchOciRegions, useOciRegionsStore } = require("../ociRegionsStore");

        await fetchOciRegions("firebase-token", true);

        expect(useOciRegionsStore.getState().ociRegions).toMatchObject([
            {
                regionId: "us-sanjose-1",
                capacity: {
                    limit: 20,
                    allocated: 8,
                    available: 12,
                },
            },
        ]);
    });

    it("ignores mismatched regional capacity responses", async () => {
        mockRegionDocs();
        const { getRegionCapacity } = require("../../helpers/APIHelper");
        getRegionCapacity.mockResolvedValue({
            success: true,
            data: {
                regionId: "us-ashburn-1",
                capacityLimit: 20,
                allocatedClientCount: 20,
                availableClientCount: 0,
            },
        });
        const { fetchOciRegions, useOciRegionsStore } = require("../ociRegionsStore");

        await fetchOciRegions("firebase-token", true);

        expect(useOciRegionsStore.getState().ociRegions?.[0].regionId).toBe("us-sanjose-1");
        expect(useOciRegionsStore.getState().ociRegions?.[0].capacity).toBeUndefined();
    });
});
