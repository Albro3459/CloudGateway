import { fireEvent, render, screen, waitFor } from "@testing-library/react";

const mockNavigate = jest.fn();

jest.mock("react-router-dom", () => ({
    useNavigate: () => mockNavigate,
}), { virtual: true });

const mockUser = {
    uid: "user-1",
    email: "user@example.com",
    getIdToken: jest.fn().mockResolvedValue("firebase-token"),
};

jest.mock("../../firebase", () => ({
    auth: { currentUser: mockUser },
    onAuthStateChanged: jest.fn((_auth, callback) => {
        callback(mockUser);
        return () => undefined;
    }),
}));

jest.mock("../../helpers/APIHelper", () => ({
    createClient: jest.fn(),
    deleteClient: jest.fn(),
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
        name: "San Jose",
        displayName: "San Jose",
        value: "us-sanjose-1",
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
            name: "San Jose",
            displayName: "San Jose",
            value: "us-sanjose-1",
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
