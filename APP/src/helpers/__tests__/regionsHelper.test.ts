import { getRegionCapacityLabel, isRegionAtCapacity, parseRegionDocument, sortRegions, Region } from "../regionsHelper";

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
            capacityLimit: 10,
            healthStatus: "ok",
        });

        expect(region).toMatchObject({
            value: "us-sanjose-1",
            regionId: "us-sanjose-1",
            name: "San Jose",
            displayName: "San Jose",
            enabled: true,
            wireguardEndpointIpv4: "1.2.3.4",
            wireguardEndpointIpv6: "2001:db8::1",
            wireguardEndpointHostname: "wg.us-sanjose-1.example.com",
            wireguardPort: 51821,
            wireguardDnsIpv4: "10.0.0.1",
            wireguardDnsIpv6: "fd42:42:42::1",
            wireguardPublicKey: "public-key",
            capacityLimit: 10,
            displayOrder: 1000,
            healthStatus: "ok",
        });
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

    it("formats allocated regional capacity", () => {
        const region = parseRegionDocument("us-sanjose-1", {
            displayName: "San Jose",
            enabled: true,
            capacityLimit: 20,
        });

        expect(getRegionCapacityLabel(region)).toBe("");
        expect(isRegionAtCapacity(region)).toBe(false);

        const withCapacity = {
            ...region!,
            capacity: {
                limit: 20,
                allocated: 20,
                available: 0,
            },
        };

        expect(getRegionCapacityLabel(withCapacity)).toBe("20 / 20 used");
        expect(isRegionAtCapacity(withCapacity)).toBe(true);
    });
});
