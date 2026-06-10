describe("apiEndpoints", () => {
    const originalApiOrigin = process.env.REACT_APP_API_ORIGIN;

    afterEach(() => {
        jest.resetModules();
        process.env.REACT_APP_API_ORIGIN = originalApiOrigin;
    });

    it("uses REACT_APP_API_ORIGIN for local/dev override", async () => {
        jest.resetModules();
        process.env.REACT_APP_API_ORIGIN = "http://localhost:8787/";
        const { buildRegionalApiEndpoint } = await import("../apiEndpoints");

        expect(buildRegionalApiEndpoint("us-sanjose-1", "/clients", {
            hostname: "localhost",
            host: "localhost:3000",
        })).toBe("http://localhost:8787/api/clients");
    });

    it("derives production regional URLs from the current frontend host", async () => {
        jest.resetModules();
        process.env.REACT_APP_API_ORIGIN = "";
        const { buildRegionalApiEndpoint } = await import("../apiEndpoints");

        expect(buildRegionalApiEndpoint("us-sanjose-1", "clients", {
            hostname: "gateway.gocloudlaunch.com",
            host: "gateway.gocloudlaunch.com:443",
        })).toBe("https://us-sanjose-1.gateway.gocloudlaunch.com/api/clients");
    });

    it("preserves ports for localhost derived URLs", async () => {
        jest.resetModules();
        process.env.REACT_APP_API_ORIGIN = "";
        const { buildRegionalApiEndpoint } = await import("../apiEndpoints");

        expect(buildRegionalApiEndpoint("us-sanjose-1", "health", {
            hostname: "localhost",
            host: "localhost:3000",
        })).toBe("https://us-sanjose-1.localhost:3000/api/health");
    });

    it("selects first enabled region for global user creation", async () => {
        jest.resetModules();
        process.env.REACT_APP_API_ORIGIN = "";
        const { buildCreateUserApiEndpoint } = await import("../apiEndpoints");

        expect(buildCreateUserApiEndpoint([
            { value: "us-sanjose-1", enabled: true },
            { value: "eu-frankfurt-1", enabled: true, displayOrder: 10 },
            { value: "us-ashburn-1", enabled: false, displayOrder: 1 },
        ], {
            hostname: "gateway.gocloudlaunch.com",
            host: "gateway.gocloudlaunch.com",
        })).toBe("https://eu-frankfurt-1.gateway.gocloudlaunch.com/api/users");
    });
});
