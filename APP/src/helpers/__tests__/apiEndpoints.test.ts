describe("apiEndpoints", () => {
    const originalApiOrigin = process.env.REACT_APP_API_ORIGIN;

    afterEach(() => {
        jest.resetModules();
        process.env.REACT_APP_API_ORIGIN = originalApiOrigin;
    });

    it("uses REACT_APP_API_ORIGIN for local/dev override", async () => {
        jest.resetModules();
        process.env.REACT_APP_API_ORIGIN = "https://api.example.test/";
        const { buildRegionalApiEndpoint } = require("../apiEndpoints");

        expect(buildRegionalApiEndpoint("us-sanjose-1", "/clients", {
            hostname: "localhost",
            host: "localhost:3000",
        })).toBe("https://api.example.test/api/clients");
    });

    it("derives production regional URLs from the current frontend host", async () => {
        jest.resetModules();
        process.env.REACT_APP_API_ORIGIN = "";
        const { buildRegionalApiEndpoint } = require("../apiEndpoints");

        expect(buildRegionalApiEndpoint("us-sanjose-1", "clients", {
            hostname: "gocloudlaunch.com",
            host: "gocloudlaunch.com:443",
        })).toBe("https://us-sanjose-1.gocloudlaunch.com/api/clients");
    });

    it("preserves ports for localhost derived URLs", async () => {
        jest.resetModules();
        process.env.REACT_APP_API_ORIGIN = "";
        const { buildRegionalApiEndpoint } = require("../apiEndpoints");

        expect(buildRegionalApiEndpoint("us-sanjose-1", "health", {
            hostname: "localhost",
            host: "localhost:3000",
        })).toBe("https://us-sanjose-1.localhost:3000/api/health");
    });

    it("uses REACT_APP_API_ORIGIN for user creation without requiring regions", async () => {
        jest.resetModules();
        process.env.REACT_APP_API_ORIGIN = "https://api.example.test";
        const { buildCreateUserApiEndpoint } = require("../apiEndpoints");

        expect(buildCreateUserApiEndpoint([], {
            hostname: "localhost",
            host: "localhost:3000",
        })).toBe("https://api.example.test/api/users");
    });

    it("uses REACT_APP_API_ORIGIN for access checks without requiring regions", async () => {
        jest.resetModules();
        process.env.REACT_APP_API_ORIGIN = "https://api.example.test";
        const { buildAccessCheckApiEndpoint } = require("../apiEndpoints");

        expect(buildAccessCheckApiEndpoint([], {
            hostname: "localhost",
            host: "localhost:3000",
        })).toBe("https://api.example.test/api/auth/check-access");
    });

    it("selects first enabled region for global user creation", async () => {
        jest.resetModules();
        process.env.REACT_APP_API_ORIGIN = "";
        const { buildCreateUserApiEndpoint } = require("../apiEndpoints");

        expect(buildCreateUserApiEndpoint([
            { regionId: "us-sanjose-1", enabled: true },
            { regionId: "eu-frankfurt-1", enabled: true, displayOrder: 10 },
            { regionId: "us-ashburn-1", enabled: false, displayOrder: 1 },
        ], {
            hostname: "gocloudlaunch.com",
            host: "gocloudlaunch.com",
        })).toBe("https://eu-frankfurt-1.gocloudlaunch.com/api/users");
    });

    it("selects first enabled region for access checks", async () => {
        jest.resetModules();
        process.env.REACT_APP_API_ORIGIN = "";
        const { buildAccessCheckApiEndpoint } = require("../apiEndpoints");

        expect(buildAccessCheckApiEndpoint([
            { regionId: "us-sanjose-1", enabled: true },
            { regionId: "eu-frankfurt-1", enabled: true, displayOrder: 10 },
            { regionId: "us-ashburn-1", enabled: false, displayOrder: 1 },
        ], {
            hostname: "gocloudlaunch.com",
            host: "gocloudlaunch.com",
        })).toBe("https://eu-frankfurt-1.gocloudlaunch.com/api/auth/check-access");
    });
});

export {};
