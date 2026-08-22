jest.mock("../../helpers/APIHelper", () => ({
    fetchRegions: jest.fn(),
    getRegionCapacity: jest.fn(),
}));

type Deferred<T> = {
    promise: Promise<T>;
    resolve: (value: T) => void;
    reject: (error: Error) => void;
};

const deferred = <T,>(): Deferred<T> => {
    let resolve!: (value: T) => void;
    let reject!: (error: Error) => void;
    const promise = new Promise<T>((promiseResolve, promiseReject) => {
        resolve = promiseResolve;
        reject = promiseReject;
    });

    return { promise, resolve, reject };
};

const successfulRegions = (regionId = "us-sanjose-1") => ({
    success: true,
    data: {
        regions: [
            {
                regionId,
                displayName: regionId,
                displayOrder: 1,
            },
        ],
    },
});

const successfulCapacity = (regionId: string, allocatedClientCount: number) => ({
    success: true,
    data: {
        regionId,
        capacityLimit: 20,
        allocatedClientCount,
    },
});

describe("ociRegionsStore", () => {
    beforeEach(() => {
        jest.clearAllMocks();
        jest.resetModules();
    });

    const mockRegions = () => {
        const { fetchRegions } = require("../../helpers/APIHelper");
        fetchRegions.mockResolvedValue(successfulRegions());
    };

    it("merges matching regional capacity responses", async () => {
        mockRegions();
        const { getRegionCapacity } = require("../../helpers/APIHelper");
        getRegionCapacity.mockResolvedValue(successfulCapacity("us-sanjose-1", 8));
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
        getRegionCapacity.mockResolvedValue(successfulCapacity("us-ashburn-1", 20));
        const { fetchOciRegions, useOciRegionsStore } = require("../ociRegionsStore");

        await fetchOciRegions("firebase-token", true);

        expect(useOciRegionsStore.getState().ociRegions?.[0].regionId).toBe("us-sanjose-1");
        expect(useOciRegionsStore.getState().ociRegions?.[0].capacity).toEqual({ status: "unknown" });
    });

    it("dedupes simultaneous fetches for the same token", async () => {
        const regions = deferred<unknown>();
        const { fetchRegions, getRegionCapacity } = require("../../helpers/APIHelper");
        fetchRegions.mockReturnValue(regions.promise);
        getRegionCapacity.mockResolvedValue(successfulCapacity("us-sanjose-1", 7));
        const { fetchOciRegions, useOciRegionsStore } = require("../ociRegionsStore");

        const firstFetch = fetchOciRegions("token-a", true);
        const secondFetch = fetchOciRegions("token-a", true);

        expect(secondFetch).toBe(firstFetch);
        expect(fetchRegions).toHaveBeenCalledTimes(1);

        regions.resolve(successfulRegions());
        await firstFetch;

        expect(getRegionCapacity).toHaveBeenCalledTimes(1);
        expect(getRegionCapacity).toHaveBeenCalledWith("us-sanjose-1", "token-a");
        expect(useOciRegionsStore.getState().ociRegions?.[0].capacity).toEqual({
            status: "known",
            limit: 20,
            allocated: 7,
        });
    });

    it("isolates overlapping fetches for different tokens", async () => {
        const tokenARegions = deferred<unknown>();
        const tokenBRegions = deferred<unknown>();
        const { fetchRegions, getRegionCapacity } = require("../../helpers/APIHelper");
        fetchRegions
            .mockReturnValueOnce(tokenARegions.promise)
            .mockReturnValueOnce(tokenBRegions.promise);
        getRegionCapacity.mockImplementation((regionId: string, token: string) => (
            Promise.resolve(successfulCapacity(regionId, token === "token-a" ? 3 : 11))
        ));
        const { fetchOciRegions, useOciRegionsStore } = require("../ociRegionsStore");

        const tokenAFetch = fetchOciRegions("token-a", true);
        const tokenBFetch = fetchOciRegions("token-b", true);

        tokenBRegions.resolve(successfulRegions());
        await tokenBFetch;

        expect(useOciRegionsStore.getState().ociRegions?.[0].capacity).toEqual({
            status: "known",
            limit: 20,
            allocated: 11,
        });

        tokenARegions.resolve(successfulRegions());
        await tokenAFetch;

        expect(fetchRegions).toHaveBeenCalledTimes(2);
        expect(getRegionCapacity).toHaveBeenCalledWith("us-sanjose-1", "token-a");
        expect(getRegionCapacity).toHaveBeenCalledWith("us-sanjose-1", "token-b");
        expect(useOciRegionsStore.getState().ociRegions?.[0].capacity).toEqual({
            status: "known",
            limit: 20,
            allocated: 11,
        });
    });

    it("suppresses stale success after clear and allows an immediate refetch", async () => {
        const staleRegions = deferred<unknown>();
        const freshRegions = deferred<unknown>();
        const { fetchRegions, getRegionCapacity } = require("../../helpers/APIHelper");
        fetchRegions
            .mockReturnValueOnce(staleRegions.promise)
            .mockReturnValueOnce(freshRegions.promise);
        getRegionCapacity.mockImplementation((regionId: string, token: string) => (
            Promise.resolve(successfulCapacity(regionId, token === "token-a" ? 4 : 12))
        ));
        const { fetchOciRegions, useOciRegionsStore } = require("../ociRegionsStore");

        const staleFetch = fetchOciRegions("token-a", true);
        useOciRegionsStore.getState().clearOciRegions();
        const freshFetch = fetchOciRegions("token-b", true);

        expect(fetchRegions).toHaveBeenCalledTimes(2);
        expect(useOciRegionsStore.getState().loading).toBe(true);

        freshRegions.resolve(successfulRegions());
        await freshFetch;

        expect(useOciRegionsStore.getState().ociRegions?.[0].capacity).toEqual({
            status: "known",
            limit: 20,
            allocated: 12,
        });

        staleRegions.resolve(successfulRegions());
        await staleFetch;

        expect(useOciRegionsStore.getState().ociRegions?.[0].capacity).toEqual({
            status: "known",
            limit: 20,
            allocated: 12,
        });
        expect(useOciRegionsStore.getState().error).toBeNull();
    });

    it("suppresses stale error after clear and allows an immediate refetch", async () => {
        const staleRegions = deferred<unknown>();
        const freshRegions = deferred<unknown>();
        const { fetchRegions, getRegionCapacity } = require("../../helpers/APIHelper");
        fetchRegions
            .mockReturnValueOnce(staleRegions.promise)
            .mockReturnValueOnce(freshRegions.promise);
        getRegionCapacity.mockResolvedValue(successfulCapacity("us-sanjose-1", 15));
        const { fetchOciRegions, useOciRegionsStore } = require("../ociRegionsStore");

        const staleFetch = fetchOciRegions("token-a", true);
        useOciRegionsStore.getState().clearOciRegions();
        const freshFetch = fetchOciRegions("token-b", true);

        freshRegions.resolve(successfulRegions());
        await freshFetch;

        staleRegions.resolve({ success: false, error: "stale failure" });
        await staleFetch;

        expect(fetchRegions).toHaveBeenCalledTimes(2);
        expect(useOciRegionsStore.getState().error).toBeNull();
        expect(useOciRegionsStore.getState().loading).toBe(false);
        expect(useOciRegionsStore.getState().ociRegions?.[0].capacity).toEqual({
            status: "known",
            limit: 20,
            allocated: 15,
        });
    });
});
