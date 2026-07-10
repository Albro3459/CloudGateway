import { stripCidr } from "../ipHelper";

describe("stripCidr", () => {
    it("strips a trailing CIDR prefix", () => {
        expect(stripCidr("10.0.0.2/32")).toBe("10.0.0.2");
        expect(stripCidr("fd42:42:42::2/128")).toBe("fd42:42:42::2");
    });

    it("returns the value unchanged when there is no prefix", () => {
        expect(stripCidr("10.0.0.2")).toBe("10.0.0.2");
    });

    it("returns null for empty values", () => {
        expect(stripCidr(null)).toBeNull();
        expect(stripCidr(undefined)).toBeNull();
        expect(stripCidr("")).toBeNull();
    });
});
