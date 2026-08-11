import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";

const mockNavigate = jest.fn();

jest.mock("react-router-dom", () => ({
    useNavigate: () => mockNavigate,
}), { virtual: true });

const mockUser = {
    uid: "user-1",
    email: "user@example.com",
    getIdToken: jest.fn().mockResolvedValue("firebase-token"),
    reload: jest.fn().mockResolvedValue(undefined),
    providerData: [{ providerId: "google.com" }],
};

const appleProvider = { providerId: "apple.com" };
const googleProvider = { providerId: "google.com" };

jest.mock("../../firebase", () => ({
    auth: { currentUser: mockUser },
    onAuthStateChanged: jest.fn((_auth, callback) => {
        callback(mockUser);
        return () => undefined;
    }),
    EmailAuthProvider: { credential: jest.fn(() => ({ providerId: "password" })) },
    appleProvider,
    googleProvider,
    linkWithCredential: jest.fn().mockResolvedValue(undefined),
    linkWithPopup: jest.fn().mockResolvedValue(undefined),
    reauthenticateWithCredential: jest.fn().mockResolvedValue(undefined),
    reauthenticateWithPopup: jest.fn().mockResolvedValue(undefined),
}));

jest.mock("../../helpers/APIHelper", () => ({
    createAdminUser: jest.fn(),
    createClient: jest.fn(),
    deleteClient: jest.fn(),
    deleteAccount: jest.fn(),
    runRegionsSync: jest.fn(),
}));

jest.mock("../../helpers/firebaseDbHelper", () => ({
    getUsersVPNs: jest.fn().mockResolvedValue([]),
    logout: jest.fn(),
}));

jest.mock("../../helpers/usersHelper", () => ({
    getUserRole: jest.fn().mockResolvedValue("user"),
}));

jest.mock("../../stores/ociRegionsStore", () => {
    const region = {
        displayName: "San Jose",
        regionId: "us-sanjose-1",
        enabled: true,
        displayOrder: 1,
    };

    return {
        fetchOciRegions: jest.fn().mockResolvedValue(undefined),
        useOciRegionsStore: jest.fn(() => ({
            ociRegions: [region],
            loading: false,
            error: null,
        })),
    };
});

jest.mock("../../components/ThemeToggle", () => ({
    ThemeToggle: () => <button type="button">Theme</button>,
}));

jest.mock("qrcode", () => ({
    toCanvas: jest.fn(),
}));

jest.mock("file-saver", () => ({
    saveAs: jest.fn(),
}));

const firePointer = (
    element: HTMLElement,
    type: "pointerdown" | "pointermove" | "pointerup",
    properties: { button?: number; clientY: number; pointerId: number },
) => {
    const event = new Event(type, { bubbles: true, cancelable: true });
    Object.assign(event, properties);
    fireEvent(element, event);
};

describe("Home pull to refresh", () => {
    const regionStoreState = {
        ociRegions: [{
            displayName: "San Jose",
            regionId: "us-sanjose-1",
            enabled: true,
            displayOrder: 1,
        }],
        loading: false,
        error: null,
    };

    beforeEach(() => {
        jest.clearAllMocks();
        mockUser.getIdToken.mockResolvedValue("firebase-token");
        mockUser.reload.mockResolvedValue(undefined);
        const { auth, onAuthStateChanged } = require("../../firebase");
        const { getUsersVPNs } = require("../../helpers/firebaseDbHelper");
        const { getUserRole } = require("../../helpers/usersHelper");
        const { fetchOciRegions, useOciRegionsStore } = require("../../stores/ociRegionsStore");

        auth.currentUser = mockUser;
        onAuthStateChanged.mockImplementation((_auth: unknown, callback: (user: unknown) => void) => {
            callback(mockUser);
            return () => undefined;
        });
        getUsersVPNs.mockResolvedValue([]);
        getUserRole.mockResolvedValue("user");
        fetchOciRegions.mockResolvedValue(undefined);
        useOciRegionsStore.mockImplementation(() => regionStoreState);
        Object.defineProperty(window, "scrollY", {
            configurable: true,
            value: 0,
        });
    });

    it("refreshes VPNs and regions when dragged down past the threshold", async () => {
        const { getUsersVPNs } = require("../../helpers/firebaseDbHelper");
        const { fetchOciRegions } = require("../../stores/ociRegionsStore");
        const { default: Home } = require("../Home");

        render(<Home />);

        await waitFor(() => expect(getUsersVPNs).toHaveBeenCalledTimes(1));
        await waitFor(() => expect(fetchOciRegions).toHaveBeenCalledTimes(1));

        const dashboard = screen.getByTestId("dashboard-page");

        firePointer(dashboard, "pointerdown", { button: 0, clientY: 0, pointerId: 1 });
        firePointer(dashboard, "pointermove", { clientY: 140, pointerId: 1 });

        expect(screen.getByText("Release to refresh")).toBeTruthy();

        firePointer(dashboard, "pointerup", { clientY: 140, pointerId: 1 });

        await waitFor(() => {
            expect(getUsersVPNs).toHaveBeenCalledTimes(2);
            expect(fetchOciRegions).toHaveBeenCalledTimes(2);
        });
        expect(fetchOciRegions).toHaveBeenLastCalledWith("firebase-token", true);
    });

    it("shows region loading before the first regions fetch resolves", async () => {
        const { useOciRegionsStore } = require("../../stores/ociRegionsStore");
        const { default: Home } = require("../Home");

        useOciRegionsStore.mockImplementation(() => ({
            ociRegions: null,
            loading: false,
            error: null,
        }));

        render(<Home />);

        expect(screen.getByText("Loading regions...")).toBeTruthy();
        expect(screen.queryByText(/No enabled regions are available\./)).toBeNull();
    });

    it("keeps the VPN table loading while VPN data arrives before regions", async () => {
        const { useOciRegionsStore } = require("../../stores/ociRegionsStore");
        const { getUsersVPNs } = require("../../helpers/firebaseDbHelper");
        const { default: Home } = require("../Home");
        let resolveVPNs!: (value: never[]) => void;
        const vpnPromise = new Promise<never[]>(resolve => {
            resolveVPNs = resolve;
        });
        let regionsAvailable = false;

        useOciRegionsStore.mockImplementation(() => ({
            ociRegions: regionsAvailable ? regionStoreState.ociRegions : null,
            loading: false,
            error: null,
        }));
        getUsersVPNs.mockReturnValue(vpnPromise);

        const { rerender } = render(<Home />);
        await waitFor(() => expect(getUsersVPNs).toHaveBeenCalledTimes(1));

        resolveVPNs([]);
        await waitFor(() => expect(screen.queryByText("No VPN clients in this region.")).toBeNull());

        regionsAvailable = true;
        rerender(<Home />);
        await waitFor(() => expect(screen.getAllByText("San Jose").length).toBeGreaterThan(0));
        expect(screen.getByText("No VPN clients in this region.")).toBeTruthy();
    });

    it("shows known region capacity", async () => {
        const { useOciRegionsStore } = require("../../stores/ociRegionsStore");
        const { default: Home } = require("../Home");

        useOciRegionsStore.mockImplementation(() => ({
            ociRegions: [{
                ...regionStoreState.ociRegions[0],
                capacity: {
                    status: "known",
                    limit: 20,
                    allocated: 8,
                },
            }],
            loading: false,
            error: null,
        }));

        render(<Home />);

        expect(await screen.findByText("8 / 20 used")).toBeTruthy();
    });

    it("blocks create when known region capacity is full", async () => {
        const { useOciRegionsStore } = require("../../stores/ociRegionsStore");
        const { default: Home } = require("../Home");

        useOciRegionsStore.mockImplementation(() => ({
            ociRegions: [{
                ...regionStoreState.ociRegions[0],
                capacity: {
                    status: "known",
                    limit: 20,
                    allocated: 20,
                },
            }],
            loading: false,
            error: null,
        }));

        render(<Home />);

        expect(await screen.findByText("San Jose is currently full")).toBeTruthy();
        await waitFor(() => {
            expect((screen.getByRole("button", { name: "Create Client" }) as HTMLButtonElement).disabled).toBe(true);
        });
    });

    it("blocks create when capacity is unavailable", async () => {
        const { default: Home } = require("../Home");

        render(<Home />);

        await waitFor(() => {
            expect((screen.getByRole("button", { name: "Create Client" }) as HTMLButtonElement).disabled).toBe(true);
        });
        expect(await screen.findByText("Capacity for San Jose is unavailable. Try again in a moment.")).toBeTruthy();
        expect(screen.queryByText(/currently full/)).toBeNull();
    });

    it("requires a client display name before creating", async () => {
        const { createClient } = require("../../helpers/APIHelper");
        const { useOciRegionsStore } = require("../../stores/ociRegionsStore");
        const { default: Home } = require("../Home");

        useOciRegionsStore.mockImplementation(() => ({
            ociRegions: [{
                ...regionStoreState.ociRegions[0],
                capacity: {
                    status: "known",
                    limit: 20,
                    allocated: 8,
                },
            }],
            loading: false,
            error: null,
        }));

        render(<Home />);

        const input = await screen.findByLabelText("Client display name");
        expect(input.getAttribute("placeholder")).toBe("ex: John's iPhone");
        expect((screen.getByRole("button", { name: "Create Client" }) as HTMLButtonElement).disabled).toBe(true);
        expect(createClient).not.toHaveBeenCalled();
    });

    it("creates clients with a trimmed required display name", async () => {
        const { createClient } = require("../../helpers/APIHelper");
        const { useOciRegionsStore } = require("../../stores/ociRegionsStore");
        const { default: Home } = require("../Home");

        createClient.mockResolvedValue({
            success: true,
            data: {
                clientId: "client-1",
                regionId: "us-sanjose-1",
                clientName: "John's iPhone",
                status: "active",
                assignedTunnelIpv4: "10.0.0.2/32",
                assignedTunnelIpv6: "fd42:42:42::2/128",
                serverEndpointIpv4: "203.0.113.10",
                wireguardConfig: "[Interface]",
            },
        });
        useOciRegionsStore.mockImplementation(() => ({
            ociRegions: [{
                ...regionStoreState.ociRegions[0],
                capacity: {
                    status: "known",
                    limit: 20,
                    allocated: 8,
                },
            }],
            loading: false,
            error: null,
        }));

        render(<Home />);

        fireEvent.change(await screen.findByLabelText("Client display name"), {
            target: { value: "  John's iPhone  " },
        });
        fireEvent.click(screen.getByRole("button", { name: "Create Client" }));

        await waitFor(() => {
            expect(createClient).toHaveBeenCalledWith(
                { regionId: "us-sanjose-1", clientName: "John's iPhone" },
                "firebase-token",
            );
        });
        expect(await screen.findByText("John's iPhone was created in San Jose.")).toBeTruthy();
    });

    it("does not refresh when the pull is below the threshold", async () => {
        const { getUsersVPNs } = require("../../helpers/firebaseDbHelper");
        const { fetchOciRegions } = require("../../stores/ociRegionsStore");
        const { default: Home } = require("../Home");

        render(<Home />);

        await waitFor(() => expect(getUsersVPNs).toHaveBeenCalledTimes(1));
        await waitFor(() => expect(fetchOciRegions).toHaveBeenCalledTimes(1));

        const dashboard = screen.getByTestId("dashboard-page");

        firePointer(dashboard, "pointerdown", { button: 0, clientY: 0, pointerId: 2 });
        firePointer(dashboard, "pointermove", { clientY: 80, pointerId: 2 });
        firePointer(dashboard, "pointerup", { clientY: 80, pointerId: 2 });

        expect(getUsersVPNs).toHaveBeenCalledTimes(1);
        expect(fetchOciRegions).toHaveBeenCalledTimes(1);
    });

    it("clears the pull indicator when a threshold refresh cannot start", async () => {
        const { auth } = require("../../firebase");
        const { getUsersVPNs } = require("../../helpers/firebaseDbHelper");
        const { fetchOciRegions } = require("../../stores/ociRegionsStore");
        const { default: Home } = require("../Home");

        render(<Home />);

        await waitFor(() => expect(getUsersVPNs).toHaveBeenCalledTimes(1));
        await waitFor(() => expect(fetchOciRegions).toHaveBeenCalledTimes(1));

        const dashboard = screen.getByTestId("dashboard-page");

        firePointer(dashboard, "pointerdown", { button: 0, clientY: 0, pointerId: 4 });
        firePointer(dashboard, "pointermove", { clientY: 140, pointerId: 4 });

        expect(screen.getByText("Release to refresh")).toBeTruthy();

        auth.currentUser = null;
        firePointer(dashboard, "pointerup", { clientY: 140, pointerId: 4 });

        await waitFor(() => expect(screen.queryByText("Release to refresh")).toBeNull());
        expect(getUsersVPNs).toHaveBeenCalledTimes(1);
        expect(fetchOciRegions).toHaveBeenCalledTimes(1);
    });

    it("ignores drag gestures when the page is already scrolled", async () => {
        const { getUsersVPNs } = require("../../helpers/firebaseDbHelper");
        const { fetchOciRegions } = require("../../stores/ociRegionsStore");
        const { default: Home } = require("../Home");

        Object.defineProperty(window, "scrollY", {
            configurable: true,
            value: 24,
        });

        render(<Home />);

        await waitFor(() => expect(getUsersVPNs).toHaveBeenCalledTimes(1));
        await waitFor(() => expect(fetchOciRegions).toHaveBeenCalledTimes(1));

        const dashboard = screen.getByTestId("dashboard-page");

        firePointer(dashboard, "pointerdown", { button: 0, clientY: 0, pointerId: 3 });
        firePointer(dashboard, "pointermove", { clientY: 180, pointerId: 3 });
        firePointer(dashboard, "pointerup", { clientY: 180, pointerId: 3 });

        expect(screen.queryByText("Release to refresh")).toBeNull();
        expect(getUsersVPNs).toHaveBeenCalledTimes(1);
        expect(fetchOciRegions).toHaveBeenCalledTimes(1);
    });
});

describe("Home admin tools", () => {
    beforeEach(() => {
        jest.clearAllMocks();
        mockUser.getIdToken.mockResolvedValue("firebase-token");
        const { auth, onAuthStateChanged } = require("../../firebase");
        const { createAdminUser, runRegionsSync } = require("../../helpers/APIHelper");
        const { getUsersVPNs } = require("../../helpers/firebaseDbHelper");
        const { getUserRole } = require("../../helpers/usersHelper");
        const { fetchOciRegions, useOciRegionsStore } = require("../../stores/ociRegionsStore");

        auth.currentUser = mockUser;
        onAuthStateChanged.mockImplementation((_auth: unknown, callback: (user: unknown) => void) => {
            callback(mockUser);
            return () => undefined;
        });
        getUsersVPNs.mockResolvedValue([]);
        getUserRole.mockResolvedValue("admin");
        fetchOciRegions.mockResolvedValue(undefined);
        createAdminUser.mockResolvedValue({
            success: true,
            data: { userId: "user-2", email: "new@example.com", role: "user", alreadyExisted: false },
        });
        runRegionsSync.mockResolvedValue([]);
        useOciRegionsStore.mockImplementation(() => ({
            ociRegions: [
                { displayName: "San Jose", regionId: "us-sanjose-1", enabled: true, displayOrder: 1 },
                { displayName: "Ashburn", regionId: "us-ashburn-1", enabled: true, displayOrder: 2 },
            ],
            loading: false,
            error: null,
        }));
        Object.defineProperty(window, "scrollY", { configurable: true, value: 0 });
    });

    it("grants user access from the dashboard modal", async () => {
        const { createAdminUser } = require("../../helpers/APIHelper");
        const { default: Home } = require("../Home");

        render(<Home />);
        fireEvent.click(await screen.findByRole("button", { name: "Grant User Access" }));
        fireEvent.change(screen.getByLabelText("Email"), { target: { value: "  new@example.com  " } });
        fireEvent.click(screen.getByRole("button", { name: "Grant Access" }));

        await waitFor(() => expect(createAdminUser).toHaveBeenCalledWith(
            { email: "new@example.com" },
            "firebase-token",
            expect.arrayContaining([expect.objectContaining({ regionId: "us-sanjose-1" })]),
        ));
        expect(await screen.findByText("new@example.com now has CloudGateway access.")).toBeTruthy();
    });

    it("lists every enabled region in the sync modal and hands off to Server Health on confirm", async () => {
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: Home } = require("../Home");

        render(<Home />);
        fireEvent.click(await screen.findByRole("button", { name: "Sync All Regions" }));

        const modal = screen.getByRole("dialog", { name: "Sync All Regions" });
        expect(within(modal).getByText("San Jose")).toBeTruthy();
        expect(within(modal).getByText("Ashburn")).toBeTruthy();

        fireEvent.click(within(modal).getByRole("button", { name: "Sync 2 regions" }));

        // Home hands off to Server Health via navigation state rather than
        // running the fan-out itself, so the sync race doesn't survive a route change.
        expect(mockNavigate).toHaveBeenCalledWith("/server-health", { state: { runSync: true } });
        expect(runRegionsSync).not.toHaveBeenCalled();
    });
});

describe("Home account linking", () => {
    const renderHome = async () => {
        const { getUsersVPNs } = require("../../helpers/firebaseDbHelper");
        const { default: Home } = require("../Home");

        render(<Home />);
        await waitFor(() => expect(getUsersVPNs).toHaveBeenCalled());
    };

    beforeEach(() => {
        jest.clearAllMocks();
        mockUser.getIdToken.mockResolvedValue("firebase-token");
        mockUser.reload.mockResolvedValue(undefined);
        mockUser.providerData = [{ providerId: "google.com" }];
        const { auth, EmailAuthProvider, onAuthStateChanged, linkWithCredential, linkWithPopup, reauthenticateWithCredential, reauthenticateWithPopup } = require("../../firebase");
        const { getUsersVPNs } = require("../../helpers/firebaseDbHelper");
        const { getUserRole } = require("../../helpers/usersHelper");
        const { fetchOciRegions, useOciRegionsStore } = require("../../stores/ociRegionsStore");

        auth.currentUser = mockUser;
        onAuthStateChanged.mockImplementation((_auth: unknown, callback: (user: unknown) => void) => {
            callback(mockUser);
            return () => undefined;
        });
        getUsersVPNs.mockResolvedValue([]);
        getUserRole.mockResolvedValue("user");
        fetchOciRegions.mockResolvedValue(undefined);
        EmailAuthProvider.credential.mockReturnValue({ providerId: "password" });
        linkWithCredential.mockResolvedValue(undefined);
        linkWithPopup.mockResolvedValue(undefined);
        reauthenticateWithCredential.mockResolvedValue(undefined);
        reauthenticateWithPopup.mockResolvedValue(undefined);
        useOciRegionsStore.mockImplementation(() => ({
            ociRegions: [{ displayName: "San Jose", regionId: "us-sanjose-1", enabled: true, displayOrder: 1 }],
            loading: false,
            error: null,
        }));
        Object.defineProperty(window, "scrollY", { configurable: true, value: 0 });
    });

    it("closes the account menu on Escape", async () => {
        await renderHome();

        fireEvent.click(screen.getByRole("button", { name: "Account" }));
        expect(screen.getByRole("button", { name: "Logout" })).toBeTruthy();

        fireEvent.keyDown(document, { key: "Escape" });

        expect(screen.queryByRole("button", { name: "Logout" })).toBeNull();
    });

    it("closes the account menu on an outside click", async () => {
        await renderHome();

        fireEvent.click(screen.getByRole("button", { name: "Account" }));
        expect(screen.getByRole("button", { name: "Logout" })).toBeTruthy();

        fireEvent.mouseDown(document.body);

        expect(screen.queryByRole("button", { name: "Logout" })).toBeNull();
    });

    it("shows only unlinked sign-in methods", async () => {
        await renderHome();

        fireEvent.click(screen.getByRole("button", { name: "Account" }));
        fireEvent.click(screen.getByRole("button", { name: "Link another sign-in method" }));

        expect(screen.getByText("Email and password")).toBeTruthy();
        expect(screen.getByRole("button", { name: /Link Apple/ })).toBeTruthy();
        expect(screen.queryByRole("button", { name: /Link Google/ })).toBeNull();
    });

    it("hides the menu item when every supported method is linked", async () => {
        mockUser.providerData = [
            { providerId: "password" },
            { providerId: "google.com" },
            { providerId: "apple.com" },
        ];

        await renderHome();

        fireEvent.click(screen.getByRole("button", { name: "Account" }));

        expect(screen.queryByRole("button", { name: "Link another sign-in method" })).toBeNull();
    });

    it("links an email and password credential", async () => {
        const { EmailAuthProvider, linkWithCredential } = require("../../firebase");

        await renderHome();

        fireEvent.click(screen.getByRole("button", { name: "Account" }));
        fireEvent.click(screen.getByRole("button", { name: "Link another sign-in method" }));
        fireEvent.change(screen.getByLabelText("Email"), {
            target: { value: "linked@example.com" },
        });
        fireEvent.change(screen.getByLabelText("New password"), {
            target: { value: "new-password-123" },
        });
        fireEvent.click(screen.getByRole("button", { name: "Link email and password" }));

        await waitFor(() => {
            expect(EmailAuthProvider.credential).toHaveBeenCalledWith("linked@example.com", "new-password-123");
            expect(linkWithCredential).toHaveBeenCalledWith(mockUser, { providerId: "password" });
            expect(screen.getByText("Email and password was linked to your account.")).toBeTruthy();
        });
    });

    it("links Google with a popup", async () => {
        mockUser.providerData = [{ providerId: "password" }];
        const { linkWithPopup, googleProvider } = require("../../firebase");

        await renderHome();

        fireEvent.click(screen.getByRole("button", { name: "Account" }));
        fireEvent.click(screen.getByRole("button", { name: "Link another sign-in method" }));
        fireEvent.click(screen.getByRole("button", { name: /Link Google/ }));

        await waitFor(() => {
            expect(linkWithPopup).toHaveBeenCalledWith(mockUser, googleProvider);
            expect(screen.getByText("Google was linked to your account.")).toBeTruthy();
        });
    });

    it("reauthenticates and retries when linking requires a recent sign-in", async () => {
        mockUser.providerData = [{ providerId: "apple.com" }];
        const { appleProvider, googleProvider, linkWithPopup, reauthenticateWithPopup } = require("../../firebase");

        linkWithPopup
            .mockRejectedValueOnce({ code: "auth/requires-recent-login" })
            .mockResolvedValueOnce(undefined);

        await renderHome();

        fireEvent.click(screen.getByRole("button", { name: "Account" }));
        fireEvent.click(screen.getByRole("button", { name: "Link another sign-in method" }));
        fireEvent.click(screen.getByRole("button", { name: /Link Google/ }));

        await waitFor(() => {
            expect(reauthenticateWithPopup).toHaveBeenCalledWith(mockUser, appleProvider);
            expect(linkWithPopup).toHaveBeenLastCalledWith(mockUser, googleProvider);
            expect(linkWithPopup).toHaveBeenCalledTimes(2);
        });
    });

    it("shows a no-merge error when the credential is already used", async () => {
        const { linkWithPopup } = require("../../firebase");

        linkWithPopup.mockRejectedValueOnce({ code: "auth/credential-already-in-use" });

        await renderHome();

        fireEvent.click(screen.getByRole("button", { name: "Account" }));
        fireEvent.click(screen.getByRole("button", { name: "Link another sign-in method" }));
        fireEvent.click(screen.getByRole("button", { name: /Link Apple/ }));

        expect(await screen.findByText("That sign-in method is already used by another CloudGateway account. Sign in with that account directly or contact support.")).toBeTruthy();
    });
});

describe("Home account deletion reauthentication", () => {
    beforeEach(() => {
        jest.clearAllMocks();
        mockUser.getIdToken.mockResolvedValue("firebase-token");
        mockUser.reload.mockResolvedValue(undefined);
        mockUser.providerData = [{ providerId: "google.com" }];
        const { auth, onAuthStateChanged, reauthenticateWithPopup, reauthenticateWithCredential } = require("../../firebase");
        const { getUsersVPNs } = require("../../helpers/firebaseDbHelper");
        const { getUserRole } = require("../../helpers/usersHelper");
        const { deleteAccount } = require("../../helpers/APIHelper");
        const { fetchOciRegions, useOciRegionsStore } = require("../../stores/ociRegionsStore");

        auth.currentUser = mockUser;
        onAuthStateChanged.mockImplementation((_auth: unknown, callback: (user: unknown) => void) => {
            callback(mockUser);
            return () => undefined;
        });
        getUsersVPNs.mockResolvedValue([]);
        getUserRole.mockResolvedValue("user");
        fetchOciRegions.mockResolvedValue(undefined);
        reauthenticateWithPopup.mockResolvedValue(undefined);
        reauthenticateWithCredential.mockResolvedValue(undefined);
        deleteAccount.mockResolvedValue({ success: true });
        useOciRegionsStore.mockImplementation(() => ({
            ociRegions: [{ displayName: "San Jose", regionId: "us-sanjose-1", enabled: true, displayOrder: 1 }],
            loading: false,
            error: null,
        }));
        Object.defineProperty(window, "scrollY", { configurable: true, value: 0 });
    });

    const openDeleteModalAndConfirm = async () => {
        const { getUsersVPNs } = require("../../helpers/firebaseDbHelper");
        const { default: Home } = require("../Home");

        render(<Home />);
        await waitFor(() => expect(getUsersVPNs).toHaveBeenCalled());

        fireEvent.click(screen.getByRole("button", { name: "Account" }));
        fireEvent.click(screen.getByRole("button", { name: "Delete Account" }));
        fireEvent.click(screen.getByRole("button", { name: "Delete Account" }));
    };

    it("reauthenticates Apple users with the Apple provider before deleting", async () => {
        mockUser.providerData = [{ providerId: "apple.com" }];
        const { reauthenticateWithPopup, appleProvider } = require("../../firebase");
        const { deleteAccount } = require("../../helpers/APIHelper");
        const { logout } = require("../../helpers/firebaseDbHelper");

        await openDeleteModalAndConfirm();

        await waitFor(() => {
            expect(reauthenticateWithPopup).toHaveBeenCalledWith(mockUser, appleProvider);
            expect(deleteAccount).toHaveBeenCalledWith("firebase-token");
            expect(logout).toHaveBeenCalled();
        });
    });

    it("reauthenticates Google users with the Google provider before deleting", async () => {
        mockUser.providerData = [{ providerId: "google.com" }];
        const { reauthenticateWithPopup, appleProvider, googleProvider } = require("../../firebase");
        const { deleteAccount } = require("../../helpers/APIHelper");

        await openDeleteModalAndConfirm();

        await waitFor(() => {
            expect(reauthenticateWithPopup).toHaveBeenCalledWith(mockUser, googleProvider);
            expect(deleteAccount).toHaveBeenCalledWith("firebase-token");
        });
        expect(reauthenticateWithPopup).not.toHaveBeenCalledWith(mockUser, appleProvider);
    });

    it("surfaces a failed account deletion inline without logging out", async () => {
        mockUser.providerData = [{ providerId: "google.com" }];
        const { deleteAccount } = require("../../helpers/APIHelper");
        const { logout } = require("../../helpers/firebaseDbHelper");
        deleteAccount.mockResolvedValue({
            success: false,
            error: "Failed to reach regional VPN configuration service.",
        });

        await openDeleteModalAndConfirm();

        expect(
            await screen.findByText("Failed to reach regional VPN configuration service.")
        ).toBeTruthy();
        expect(logout).not.toHaveBeenCalled();
    });

    it("maps a Firebase reauth error to friendly copy inline", async () => {
        mockUser.providerData = [{ providerId: "google.com" }];
        const { reauthenticateWithPopup } = require("../../firebase");
        const { deleteAccount } = require("../../helpers/APIHelper");
        reauthenticateWithPopup.mockRejectedValue({ code: "auth/requires-recent-login" });

        await openDeleteModalAndConfirm();

        expect(
            await screen.findByText("Please sign in again, then retry deleting your account.")
        ).toBeTruthy();
        expect(deleteAccount).not.toHaveBeenCalled();
    });

    it("prefers Apple over Google for deletion reauth when both are linked", async () => {
        mockUser.providerData = [{ providerId: "google.com" }, { providerId: "apple.com" }];
        const { reauthenticateWithPopup, appleProvider, googleProvider } = require("../../firebase");
        const { deleteAccount } = require("../../helpers/APIHelper");

        await openDeleteModalAndConfirm();

        await waitFor(() => {
            expect(reauthenticateWithPopup).toHaveBeenCalledWith(mockUser, appleProvider);
            expect(deleteAccount).toHaveBeenCalledWith("firebase-token");
        });
        expect(reauthenticateWithPopup).not.toHaveBeenCalledWith(mockUser, googleProvider);
    });
});
