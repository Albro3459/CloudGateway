import {
    isValidEndpointHostname,
    isValidMeshEndpointPort,
    isValidMeshNetworkSyntaxV4,
    isValidMeshNetworkSyntaxV6,
    isValidMeshNetworkV4,
    isValidMeshNetworkV6,
    isValidWireGuardPublicKey,
    networksOverlap,
} from "../meshValidation";

describe("meshValidation", () => {
    it("accepts only decoded 32-byte WireGuard keys", () => {
        expect(isValidWireGuardPublicKey("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" )).toBe(true);
        expect(isValidWireGuardPublicKey("public-key")).toBe(false);
        expect(isValidWireGuardPublicKey("!".repeat(43) + "=")).toBe(false);
    });

    it("validates hostnames and IP endpoints", () => {
        expect(isValidEndpointHostname("wg.example.com")).toBe(true);
        expect(isValidEndpointHostname("192.0.2.1")).toBe(true);
        expect(isValidEndpointHostname("2001:db8::1")).toBe(true);
        expect(isValidEndpointHostname("-bad.example.com")).toBe(false);
        expect(isValidEndpointHostname("bad-.example.com")).toBe(false);
    });

    it("validates canonical aggregate mesh networks", () => {
        expect(isValidMeshNetworkV4("10.0.1.0/24")).toBe(true);
        expect(isValidMeshNetworkV4("10.1.1.0/24")).toBe(false);
        expect(isValidMeshNetworkV4("10.0.1.1/24")).toBe(false);
        expect(isValidMeshNetworkV6("fd42:42:42:1::/64")).toBe(true);
        expect(isValidMeshNetworkV6("fd42:42:43:1::/64")).toBe(false);
        expect(isValidMeshNetworkV6("FD42:42:42:1::/64")).toBe(false);
    });

    it("validates canonical /24 and /64 network syntax independently from mesh aggregates", () => {
        expect(isValidMeshNetworkSyntaxV4("192.0.2.0/24")).toBe(true);
        expect(isValidMeshNetworkV4("192.0.2.0/24")).toBe(false);
        expect(isValidMeshNetworkSyntaxV4("192.0.2.1/24")).toBe(false);
        expect(isValidMeshNetworkSyntaxV4("192.0.2.0/25")).toBe(false);
        expect(isValidMeshNetworkSyntaxV4("192.000.2.0/24")).toBe(false);
        expect(isValidMeshNetworkSyntaxV6("2001:db8:1:2::/64")).toBe(true);
        expect(isValidMeshNetworkV6("2001:db8:1:2::/64")).toBe(false);
        expect(isValidMeshNetworkSyntaxV6("2001:db8:1:2::1/64")).toBe(false);
        expect(isValidMeshNetworkSyntaxV6("2001:0db8:1:2::/64")).toBe(false);
        expect(isValidMeshNetworkSyntaxV6("2001:db8:1:2::/63")).toBe(false);
    });

    it("validates ports and overlap", () => {
        expect(isValidMeshEndpointPort(51820)).toBe(true);
        expect(isValidMeshEndpointPort("51820")).toBe(false);
        expect(isValidMeshEndpointPort(51820.5)).toBe(false);
        expect(networksOverlap("10.0.1.0/24", "10.0.1.0/24")).toBe(true);
        expect(networksOverlap("10.0.1.0/24", "10.0.2.0/24")).toBe(false);
        expect(networksOverlap("fd42:42:42:1::/64", "fd42:42:42:1::/64")).toBe(true);
    });
});
