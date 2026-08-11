import { getEnabledRegions, getRegionCapacityLabel, isRegionAtCapacity, isRegionCapacityKnown, parseRegionDocument, resolveActiveRegionId, sortRegions, Region } from "../regionsHelper";

describe("regionsHelper", () => {
    it("parses shared VPN region documents", () => {
        const region = parseRegionDocument("us-sanjose-1", {
            displayName: "San Jose",
            enabled: true,
            wireguardEndpointIpv4: "1.2.3.4",
            wireguardEndpointIpv6: "2001:db8::1",
            wireguardEndpointHostname: "wg.us-sanjose-1.example.com",
            wireguardPort: 51821,
            wireguardDnsIpv4: "10.0.0.1",
            wireguardDnsIpv6: "fd42:42:42::1",
            wireguardPublicKey: "public-key",
            healthStatus: "ok",
            tunnelNetworkV4: "10.0.0.0/24",
            tunnelNetworkV6: "fd42:42:42::/64",
            meshEnabled: true,
        });

        expect(region).toMatchObject({
            regionId: "us-sanjose-1",
            displayName: "San Jose",
            enabled: true,
            wireguardEndpointIpv4: "1.2.3.4",
            wireguardEndpointIpv6: "2001:db8::1",
            wireguardEndpointHostname: "wg.us-sanjose-1.example.com",
            wireguardPort: 51821,
            wireguardDnsIpv4: "10.0.0.1",
            wireguardDnsIpv6: "fd42:42:42::1",
            wireguardPublicKey: "public-key",
            displayOrder: 1000,
            healthStatus: "ok",
            tunnelNetworkV4: "10.0.0.0/24",
            tunnelNetworkV6: "fd42:42:42::/64",
            meshEnabled: true,
        });
    });

    it("defaults mesh fields when the region doc omits them", () => {
        const region = parseRegionDocument("us-chicago-1", {
            displayName: "Chicago",
            enabled: true,
        });

        expect(region).toMatchObject({
            tunnelNetworkV4: null,
            tunnelNetworkV6: null,
            meshEnabled: false,
        });
    });

    it("filters out disabled regions", () => {
        const regions = [
            parseRegionDocument("us-sanjose-1", { displayName: "San Jose", enabled: true }),
            parseRegionDocument("us-chicago-1", { displayName: "Chicago", enabled: false }),
            parseRegionDocument("us-dallas-1", { displayName: "Dallas" }),
        ].filter((region): region is Region => region !== null);

        expect(getEnabledRegions(regions).map(region => region.regionId)).toEqual(["us-sanjose-1"]);
        expect(getEnabledRegions(null)).toEqual([]);
    });

    it("sorts regions by display order then region id", () => {
        const regions = [
            parseRegionDocument("us-sanjose-1", { displayName: "San Jose", enabled: true, displayOrder: 2 }),
            parseRegionDocument("us-ashburn-1", { displayName: "Ashburn", enabled: true, displayOrder: 1 }),
            parseRegionDocument("eu-frankfurt-1", { displayName: "Frankfurt", enabled: true, displayOrder: 1 }),
        ].filter((region): region is Region => region !== null);

        expect(sortRegions(regions).map(region => region.regionId)).toEqual([
            "eu-frankfurt-1",
            "us-ashburn-1",
            "us-sanjose-1",
        ]);
    });

    it("preselects the first region with a config in display order", () => {
        const enabledRegions = [
            parseRegionDocument("us-sanjose-1", { displayName: "San Jose", enabled: true, displayOrder: 10 }),
            parseRegionDocument("us-ashburn-1", { displayName: "Ashburn", enabled: true, displayOrder: 20 }),
            parseRegionDocument("us-chicago-1", { displayName: "Chicago", enabled: true, displayOrder: 30 }),
        ].filter((region): region is Region => region !== null);

        // First region has no config; preselect the next region that does.
        expect(resolveActiveRegionId(enabledRegions, new Set(["us-chicago-1", "us-ashburn-1"]))).toBe("us-ashburn-1");

        // No config anywhere falls back to the first region by display order.
        expect(resolveActiveRegionId(enabledRegions, new Set())).toBe("us-sanjose-1");

        // No regions resolves to "" (check-access would have failed already).
        expect(resolveActiveRegionId([], new Set(["us-ashburn-1"]))).toBe("");
    });

    it("formats allocated regional capacity", () => {
        const region = parseRegionDocument("us-sanjose-1", {
            displayName: "San Jose",
            enabled: true,
        });

        expect(getRegionCapacityLabel(region)).toBe("Capacity unavailable");
        expect(isRegionAtCapacity(region)).toBe(false);
        expect(isRegionCapacityKnown(region)).toBe(false);

        const withCapacity = {
            ...region!,
            capacity: {
                status: "known" as const,
                limit: 20,
                allocated: 20,
            },
        };

        expect(getRegionCapacityLabel(withCapacity)).toBe("20 / 20 used");
        expect(isRegionAtCapacity(withCapacity)).toBe(true);
        expect(isRegionCapacityKnown(withCapacity)).toBe(true);
    });
});
