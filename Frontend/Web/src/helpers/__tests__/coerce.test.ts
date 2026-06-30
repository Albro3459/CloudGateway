import { numberOrDefault } from "../coerce";

describe("coerce", () => {
    it("returns finite numbers", () => {
        expect(numberOrDefault(12, 3)).toBe(12);
        expect(numberOrDefault(0, 3)).toBe(0);
    });

    it("parses non-empty numeric strings", () => {
        expect(numberOrDefault("12", 3)).toBe(12);
        expect(numberOrDefault(" 12.5 ", 3)).toBe(12.5);
    });

    it("returns fallback for non-numeric values", () => {
        expect(numberOrDefault(null, 3)).toBe(3);
        expect(numberOrDefault(undefined, 3)).toBe(3);
        expect(numberOrDefault("", 3)).toBe(3);
        expect(numberOrDefault("   ", 3)).toBe(3);
        expect(numberOrDefault(true, 3)).toBe(3);
        expect(numberOrDefault({}, 3)).toBe(3);
        expect(numberOrDefault(Number.NaN, 3)).toBe(3);
        expect(numberOrDefault(Number.POSITIVE_INFINITY, 3)).toBe(3);
    });
});
