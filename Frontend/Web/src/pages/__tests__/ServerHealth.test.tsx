import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { Region } from "../../helpers/regionsHelper";
import type { MeshDoc } from "../../helpers/meshHelper";
import type { RegionSyncResponse } from "../../helpers/APIHelper";

const mockNavigate = jest.fn();
let mockLocation: { pathname: string; state: unknown } = { pathname: "/server-health", state: null };

jest.mock("react-router-dom", () => ({
    useNavigate: () => mockNavigate,
    useLocation: () => mockLocation,
}), { virtual: true });

const mockUser = {
    uid: "admin-1",
    email: "admin@example.com",
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
    runRegionsSync: jest.fn(),
}));

jest.mock("../../helpers/firebaseDbHelper", () => ({
    getAllRegionDocs: jest.fn(),
    getMeshDocs: jest.fn(),
    logout: jest.fn(),
    setRegionMeshEnabled: jest.fn(),
}));

jest.mock("../../helpers/usersHelper", () => ({
    getUserRole: jest.fn(),
}));

jest.mock("../../components/ThemeToggle", () => ({
    ThemeToggle: () => <button type="button">Theme</button>,
}));

const region = (regionId: string, displayName: string, meshEnabled: boolean, displayOrder = 1): Region => ({
    regionId,
    displayName,
    enabled: true,
    displayOrder,
    meshEnabled,
    wireguardEndpointHostname: "wg.example.com",
    wireguardPort: 51820,
    wireguardPortPresent: true,
    wireguardPublicKey: "public-key",
    tunnelNetworkV4: "10.0.1.0/24",
    tunnelNetworkV6: "fd42:42:42:1::/64",
});

const meshPeer = (overrides: Partial<MeshDoc["peers"][string]> = {}) => ({
    endpointHostname: "wg.example.com",
    endpointPort: 51820,
    publicKey: "public-key",
    allowedNetworkV4: "10.0.1.0/24",
    allowedNetworkV6: "fd42:42:42:1::/64",
    status: "applied" as const,
    reasonCode: null,
    appliedAt: null,
    ...overrides,
});

const meshDoc = (regionId: string, overrides: Partial<MeshDoc> = {}): MeshDoc => ({
    regionId,
    meshEnabled: true,
    updatedAt: null,
    peers: {},
    ...overrides,
});

const syncResponse = (regionId: string, overrides: Partial<RegionSyncResponse> = {}): RegionSyncResponse => ({
    regionId,
    syncedAt: "2026-08-10T00:00:00Z",
    added: 1,
    updated: 0,
    removed: 0,
    noChanges: false,
    log: "sync log",
    meshUpdated: 0,
    meshEnabled: true,
    meshApplied: 1,
    meshAdded: 1,
    meshRemoved: 0,
    meshSkipped: 0,
    meshRoutesAdded: 1,
    meshRoutesRemoved: 0,
    meshPeers: [],
    ...overrides,
});

const deferred = <T,>() => {
    let resolve!: (value: T | PromiseLike<T>) => void;
    let reject!: (reason?: unknown) => void;
    const promise = new Promise<T>((resolvePromise, rejectPromise) => {
        resolve = resolvePromise;
        reject = rejectPromise;
    });
    return { promise, resolve, reject };
};

describe("ServerHealth", () => {
    beforeEach(() => {
        jest.clearAllMocks();
        mockLocation = { pathname: "/server-health", state: null };
        mockUser.getIdToken.mockResolvedValue("firebase-token");

        const { auth, onAuthStateChanged } = require("../../firebase");
        const { getUserRole } = require("../../helpers/usersHelper");
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");

        auth.currentUser = mockUser;
        onAuthStateChanged.mockImplementation((_auth: unknown, callback: (user: unknown) => void) => {
            callback(mockUser);
            return () => undefined;
        });
        getUserRole.mockResolvedValue("admin");
        getAllRegionDocs.mockResolvedValue([]);
        getMeshDocs.mockResolvedValue(new Map());
        setRegionMeshEnabled.mockResolvedValue(undefined);
        runRegionsSync.mockResolvedValue([]);
    });

    it("renders durable last-applied mesh state from Mesh/* docs without running a sync", async () => {
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", true, 1),
            region("us-chicago-1", "Chicago", true, 2),
            region("us-dallas-1", "Dallas", true, 3),
        ]);
        getMeshDocs.mockResolvedValue(new Map([
            ["us-sanjose-1", meshDoc("us-sanjose-1", {
                peers: {
                    "us-chicago-1": meshPeer(),
                    "us-dallas-1": meshPeer(),
                },
            })],
            ["us-chicago-1", meshDoc("us-chicago-1", {
                peers: { "us-sanjose-1": meshPeer() },
            })],
            ["us-dallas-1", null],
        ]));

        render(<ServerHealth />);

        expect(await screen.findByText("San Jose ↔ Chicago · both applied")).toBeTruthy();
        expect(screen.getByText("San Jose ↔ Dallas · one-sided · San Jose applied, Dallas not synced")).toBeTruthy();
        expect(screen.getByText("Chicago ↔ Dallas · not synced")).toBeTruthy();
        expect(runRegionsSync).not.toHaveBeenCalled();
    });

    it("runs the sync fan-out on mount when Home hands off a run-now signal, then renders results", async () => {
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", true, 1),
            region("us-chicago-1", "Chicago", true, 2),
        ]);
        getMeshDocs.mockResolvedValue(new Map());
        runRegionsSync.mockResolvedValue([
            { regionId: "us-sanjose-1", result: { success: true, data: syncResponse("us-sanjose-1") } },
            { regionId: "us-chicago-1", result: { success: true, data: syncResponse("us-chicago-1") } },
        ]);

        render(<ServerHealth />);

        await waitFor(() => expect(runRegionsSync).toHaveBeenCalledWith(
            ["us-sanjose-1", "us-chicago-1"],
            "firebase-token",
        ));
        // The run-now signal is cleared from navigation state so a refresh or
        // back-navigation doesn't re-trigger the fan-out.
        expect(mockNavigate).toHaveBeenCalledWith("/server-health", { replace: true, state: {} });
        expect(await screen.findByText("San Jose (us-sanjose-1)")).toBeTruthy();
        expect(screen.getByText("Chicago (us-chicago-1)")).toBeTruthy();
    });

    it("writes a meshEnabled toggle to Firestore and marks the affected link pending", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);

        // Neither region wants in yet, so nothing is pending before the toggle.
        expect(await screen.findByText("San Jose ↔ Chicago · not synced")).toBeTruthy();

        const checkbox = screen.getByLabelText("Mesh enabled for San Jose");
        fireEvent.click(checkbox);

        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));
        // San Jose now wants in but has no Mesh doc yet, so both the region
        // and the San Jose <-> Chicago link row read as pending.
        expect(await screen.findAllByText("Pending")).toHaveLength(1);
        expect(screen.getByText("San Jose ↔ Chicago · not synced")).toBeTruthy();
        expect(screen.getByText("(pending)")).toBeTruthy();
    });

    it("keeps optimistic toggle intent when a stale refresh resolves afterward", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        const initialRegions = [
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ];
        getAllRegionDocs.mockResolvedValue(initialRegions);
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);
        const checkbox = await screen.findByLabelText("Mesh enabled for San Jose");
        const staleRegions = deferred<Region[]>();
        getAllRegionDocs.mockImplementationOnce(() => staleRegions.promise);
        getMeshDocs.mockResolvedValueOnce(new Map());
        fireEvent.click(screen.getByLabelText("Refresh"));
        fireEvent.click(checkbox);

        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));
        await act(async () => {
            staleRegions.resolve(initialRegions);
            await staleRegions.promise;
        });

        expect((screen.getByLabelText("Mesh enabled for San Jose") as HTMLInputElement).checked).toBe(true);
    });

    it("keeps a newer region toggle intact when an older toggle fails later", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        let authoritativeRegions = [
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ];
        const firstToggle = deferred<void>();
        const secondToggle = deferred<void>();
        getAllRegionDocs.mockImplementation(() => Promise.resolve(authoritativeRegions));
        getMeshDocs.mockResolvedValue(new Map());
        setRegionMeshEnabled
            .mockImplementationOnce(() => firstToggle.promise)
            .mockImplementationOnce(() => secondToggle.promise);

        render(<ServerHealth />);
        await screen.findByLabelText("Mesh enabled for San Jose");
        fireEvent.click(screen.getByLabelText("Mesh enabled for San Jose"));
        fireEvent.click(screen.getByLabelText("Mesh enabled for Chicago"));

        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledTimes(2));
        authoritativeRegions = [
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", true, 2),
        ];
        await act(async () => {
            secondToggle.resolve();
            await secondToggle.promise;
        });
        await waitFor(() => expect((screen.getByLabelText("Mesh enabled for Chicago") as HTMLInputElement).checked).toBe(true));

        await act(async () => {
            firstToggle.reject(new Error("older toggle failed"));
            await firstToggle.promise.catch(() => undefined);
        });

        await waitFor(() => {
            expect((screen.getByLabelText("Mesh enabled for San Jose") as HTMLInputElement).checked).toBe(false);
            expect((screen.getByLabelText("Mesh enabled for Chicago") as HTMLInputElement).checked).toBe(true);
        });
    });

    it("surfaces a partial sync failure inline without blocking the rest of the page", async () => {
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", true, 1),
            region("us-chicago-1", "Chicago", true, 2),
        ]);
        getMeshDocs.mockResolvedValue(new Map());
        runRegionsSync.mockResolvedValue([
            { regionId: "us-sanjose-1", result: { success: true, data: syncResponse("us-sanjose-1") } },
            { regionId: "us-chicago-1", result: { success: false, error: "Unable to reach us-chicago-1." } },
        ]);

        render(<ServerHealth />);

        expect(await screen.findByText("San Jose (us-sanjose-1)")).toBeTruthy();
        expect(screen.getByText("Chicago (us-chicago-1)")).toBeTruthy();
        expect(screen.getByText("Failed")).toBeTruthy();
        expect(screen.getByText("Unable to reach us-chicago-1.")).toBeTruthy();
        // A single region failing inside the fan-out isn't a page-level error:
        // the top-level sync error banner should stay unset.
        expect(screen.queryByText("Unable to sync regions.")).toBeNull();
    });

    it("redirects non-admins away from the page", async () => {
        const { getUserRole } = require("../../helpers/usersHelper");
        const { getAllRegionDocs } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getUserRole.mockResolvedValue("user");

        render(<ServerHealth />);

        await waitFor(() => expect(mockNavigate).toHaveBeenCalledWith("/home", { replace: true }));
        expect(screen.queryByText("Mesh membership")).toBeNull();
        expect(getAllRegionDocs).not.toHaveBeenCalled();
    });
});
