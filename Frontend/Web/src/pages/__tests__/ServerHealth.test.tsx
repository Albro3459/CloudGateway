import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import type { Region } from "../../helpers/regionsHelper";
import type { MeshDoc } from "../../helpers/meshHelper";
import type { RegionSyncResponse } from "../../helpers/APIHelper";

const mockNavigate = jest.fn();
let mockLocation: { pathname: string; state: unknown } = { pathname: "/server-health", state: null };
let authStateCallback: ((user: unknown) => void) | null = null;

jest.mock("react-router-dom", () => ({
    useNavigate: () => mockNavigate,
    useLocation: () => mockLocation,
}), { virtual: true });

const mockUser = {
    uid: "admin-1",
    email: "admin@example.com",
    getIdToken: jest.fn().mockResolvedValue("firebase-token"),
};

// Firebase delivers the first observer callback asynchronously ("the callback
// needs to be called asynchronously per the spec"), so it always lands after
// React has flushed the mount effects. Mocking it synchronously inverts that
// ordering and hides anything the mount effects set up before it.
const deferFirstAuthCallback = (callback: (user: unknown) => void, user: unknown) => {
    void Promise.resolve().then(() => callback(user));
};

jest.mock("../../firebase", () => ({
    auth: { currentUser: mockUser },
    onAuthStateChanged: jest.fn((_auth, callback) => {
        void Promise.resolve().then(() => callback(mockUser));
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

const region = (
    regionId: string,
    displayName: string,
    meshEnabled: boolean,
    displayOrder = 1,
    enabled = true,
): Region => ({
    regionId,
    displayName,
    enabled,
    displayOrder,
    meshEnabled,
    wireguardEndpointHostname: "wg.example.com",
    wireguardPort: 51820,
    wireguardPublicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    tunnelNetworkV4: "10.0.1.0/24",
    tunnelNetworkV6: "fd42:42:42:1::/64",
});

const meshPeer = (overrides: Partial<MeshDoc["peers"][string]> = {}) => ({
    endpointHostname: "wg.example.com",
    endpointPort: 51820,
    publicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
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
    meshStatusWritten: true,
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
        authStateCallback = null;
        onAuthStateChanged.mockImplementation((_auth: unknown, callback: (user: unknown) => void) => {
            authStateCallback = callback;
            deferFirstAuthCallback(callback, mockUser);
            return () => undefined;
        });
        getUserRole.mockResolvedValue("admin");
        getAllRegionDocs.mockResolvedValue([]);
        getMeshDocs.mockResolvedValue(new Map());
        setRegionMeshEnabled.mockResolvedValue(undefined);
        runRegionsSync.mockResolvedValue([]);
    });

    it("shows loading state while the initial Firestore data is pending", async () => {
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        const regionDocs = deferred<Region[]>();
        const meshDocs = deferred<Map<string, MeshDoc | null>>();
        getAllRegionDocs.mockReturnValue(regionDocs.promise);
        getMeshDocs.mockReturnValue(meshDocs.promise);

        render(<ServerHealth />);

        expect(await screen.findByText("Loading server health data...")).toBeTruthy();
        expect(screen.queryByText("No regions.")).toBeNull();
        expect(screen.queryByText("Add another region to form mesh links.")).toBeNull();

        await act(async () => {
            regionDocs.resolve([]);
            meshDocs.resolve(new Map());
            await Promise.all([regionDocs.promise, meshDocs.promise]);
        });
    });

    it("shows a retry state when the initial Firestore load fails", async () => {
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        getAllRegionDocs.mockRejectedValue(new Error("Firestore unavailable"));
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);

        expect(await screen.findByText("Unable to load server health data.")).toBeTruthy();
        expect(screen.getByText("Server health data is unavailable.")).toBeTruthy();
        expect(screen.queryByText("Loading server health data...")).toBeNull();
    });

    it("retries the failed load from the in-card Try again button", async () => {
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        getAllRegionDocs.mockRejectedValueOnce(new Error("Firestore unavailable"));
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);

        // The nav Refresh button is hidden below the sm breakpoint, so the card
        // needs its own retry affordance or a mobile load failure is terminal.
        const retry = await screen.findByRole("button", { name: "Try again" });
        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true)]);
        fireEvent.click(retry);

        expect(await screen.findByText("San Jose")).toBeTruthy();
        expect(screen.queryByText("Server health data is unavailable.")).toBeNull();
    });

    it("keeps a confirmed Sync All outstanding when the initial load fails, then runs it after a retry", async () => {
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        getAllRegionDocs.mockRejectedValueOnce(new Error("Firestore unavailable"));
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);

        expect(await screen.findByText(
            "The Sync All Regions you confirmed has not run yet. It starts as soon as region data loads."
        )).toBeTruthy();
        expect(runRegionsSync).not.toHaveBeenCalled();

        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true)]);
        fireEvent.click(screen.getByRole("button", { name: "Try again" }));

        await waitFor(() => expect(runRegionsSync).toHaveBeenCalledWith(["us-sanjose-1"], "firebase-token"));
    });

    it("keeps a confirmed Sync All when the observer fires again for the same user", async () => {
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        const firstLoad = deferred<Region[]>();
        getAllRegionDocs.mockReturnValueOnce(firstLoad.promise);
        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true)]);
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);

        // The run-now signal is navigation-derived intent from this tab, so an
        // observer callback for the same user must not discard it.
        expect(await screen.findByText("Loading server health data...")).toBeTruthy();
        await act(async () => {
            authStateCallback?.(mockUser);
        });

        await waitFor(() => expect(runRegionsSync).toHaveBeenCalledWith(["us-sanjose-1"], "firebase-token"));
        await act(async () => {
            firstLoad.resolve([]);
            await firstLoad.promise;
        });
    });

    it("discards a confirmed Sync All when a different user takes over the session", async () => {
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        const firstLoad = deferred<Region[]>();
        getAllRegionDocs.mockReturnValueOnce(firstLoad.promise);
        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true)]);
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);

        expect(await screen.findByText("Loading server health data...")).toBeTruthy();
        const otherAdmin = {
            uid: "admin-2",
            email: "other-admin@example.com",
            getIdToken: jest.fn().mockResolvedValue("other-token"),
        };
        await act(async () => {
            authStateCallback?.(otherAdmin);
        });

        // One admin's confirmed fan-out must not fire under another's session.
        expect(await screen.findByText("San Jose")).toBeTruthy();
        expect(runRegionsSync).not.toHaveBeenCalled();
        await act(async () => {
            firstLoad.resolve([]);
            await firstLoad.promise;
        });
    });

    it("recovers syncing state after a regional timeout failure", async () => {
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true)]);
        getMeshDocs.mockResolvedValue(new Map());
        runRegionsSync.mockResolvedValue([{
            regionId: "us-sanjose-1",
            result: { success: false, error: "Regional API request timed out." },
        }]);

        render(<ServerHealth />);

        expect(await screen.findByText("Regional API request timed out.")).toBeTruthy();
        expect((screen.getByRole("button", { name: "Sync All Regions" }) as HTMLButtonElement).disabled).toBe(false);
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

    it("warns when a region reconciled but could not save its mesh status snapshot", async () => {
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true, 1)]);
        getMeshDocs.mockResolvedValue(new Map());
        runRegionsSync.mockResolvedValue([
            {
                regionId: "us-sanjose-1",
                result: { success: true, data: syncResponse("us-sanjose-1", { meshStatusWritten: false }) },
            },
        ]);

        render(<ServerHealth />);

        expect(await screen.findByText(/could not save its mesh status snapshot/)).toBeTruthy();
    });

    it("stays quiet about mesh status for a region that predates the field", async () => {
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true, 1)]);
        getMeshDocs.mockResolvedValue(new Map());
        runRegionsSync.mockResolvedValue([
            {
                regionId: "us-sanjose-1",
                result: { success: true, data: syncResponse("us-sanjose-1", { meshStatusWritten: null }) },
            },
        ]);

        render(<ServerHealth />);

        expect(await screen.findByText("San Jose (us-sanjose-1)")).toBeTruthy();
        expect(screen.queryByText(/could not save its mesh status snapshot/)).toBeNull();
    });

    it("writes a meshEnabled toggle to Firestore and marks the affected link pending", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        // The confirming read has to see the write, or the test would be
        // exercising the cross-tab race instead of the happy path.
        const authoritativeRegions = [
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ];
        getAllRegionDocs.mockImplementation(() => Promise.resolve([...authoritativeRegions]));
        getMeshDocs.mockResolvedValue(new Map());
        setRegionMeshEnabled.mockImplementation(async (regionId: string, meshEnabled: boolean) => {
            const index = authoritativeRegions.findIndex(r => r.regionId === regionId);
            authoritativeRegions[index] = { ...authoritativeRegions[index], meshEnabled };
        });

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
        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", true, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
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

    it("clears syncing when auth generation changes during Sync All", async () => {
        mockLocation = { pathname: "/server-health", state: null };
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        const syncPending = deferred<unknown>();
        const regions = [
            region("us-sanjose-1", "San Jose", true, 1),
            region("us-chicago-1", "Chicago", true, 2),
        ];

        getAllRegionDocs.mockResolvedValue(regions);
        getMeshDocs.mockResolvedValue(new Map());
        runRegionsSync.mockReturnValue(syncPending.promise);

        render(<ServerHealth />);
        const syncButton = await screen.findByRole("button", { name: "Sync All Regions" });
        fireEvent.click(syncButton);
        fireEvent.click(screen.getByRole("button", { name: "Sync 2 regions" }));
        await waitFor(() => expect(runRegionsSync).toHaveBeenCalled());
        expect((screen.getByRole("button", { name: "Syncing..." }) as HTMLButtonElement).disabled).toBe(true);

        await act(async () => {
            authStateCallback?.(mockUser);
        });

        await waitFor(() => {
            expect((screen.getByRole("button", { name: "Sync All Regions" }) as HTMLButtonElement).disabled).toBe(false);
        });
        await act(async () => {
            syncPending.resolve([]);
            await syncPending.promise;
        });
    });

    it("clears toggling state when auth generation changes during a toggle", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        const togglePending = deferred<void>();
        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
        getMeshDocs.mockResolvedValue(new Map());
        setRegionMeshEnabled.mockReturnValue(togglePending.promise);

        render(<ServerHealth />);
        const checkbox = await screen.findByLabelText("Mesh enabled for San Jose") as HTMLInputElement;
        fireEvent.click(checkbox);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));
        expect(checkbox.disabled).toBe(true);

        await act(async () => {
            authStateCallback?.(mockUser);
        });

        await waitFor(() => {
            expect((screen.getByLabelText("Mesh enabled for San Jose") as HTMLInputElement).disabled).toBe(false);
        });
        await act(async () => {
            togglePending.resolve();
            await togglePending.promise;
        });
    });

    it("ignores an older operation that resolves after a new auth generation", async () => {
        mockLocation = { pathname: "/server-health", state: null };
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        const syncPending = deferred<unknown>();

        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true, 1)]);
        getMeshDocs.mockResolvedValue(new Map());
        runRegionsSync.mockReturnValue(syncPending.promise);

        render(<ServerHealth />);
        fireEvent.click(await screen.findByRole("button", { name: "Sync All Regions" }));
        fireEvent.click(screen.getByRole("button", { name: "Sync 1 region" }));
        await waitFor(() => expect(runRegionsSync).toHaveBeenCalled());

        await act(async () => {
            authStateCallback?.(mockUser);
        });
        await waitFor(() => {
            expect((screen.getByRole("button", { name: "Sync All Regions" }) as HTMLButtonElement).disabled).toBe(false);
        });

        await act(async () => {
            syncPending.resolve([{ regionId: "us-sanjose-1", result: { success: false, error: "stale result" } }]);
            await syncPending.promise;
        });

        expect(screen.queryByText("stale result")).toBeNull();
    });

    it("renders an incompatible sync response as an explicit failed card", async () => {
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true, 1)]);
        getMeshDocs.mockResolvedValue(new Map());
        runRegionsSync.mockResolvedValue([{
            regionId: "us-sanjose-1",
            result: {
                success: false,
                failureType: "incompatible-response",
                errorCode: "INCOMPATIBLE_RESPONSE",
                error: "Incompatible admin sync response from us-sanjose-1.",
            },
        }]);

        render(<ServerHealth />);

        expect(await screen.findByText("Incompatible response")).toBeTruthy();
        expect(screen.getByText("The sync result was discarded because the regional API returned an unsupported shape.")).toBeTruthy();
    });

    it("drops a stale optimistic override when the confirming read fails", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        // Authoritative state never changes: the write is what fails to be
        // confirmed, so the optimistic value must not survive the next load.
        const authoritativeRegions = [
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ];
        getAllRegionDocs.mockResolvedValue(authoritativeRegions);
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);
        const checkbox = await screen.findByLabelText("Mesh enabled for San Jose") as HTMLInputElement;
        getAllRegionDocs.mockRejectedValueOnce(new Error("confirming read failed"));
        fireEvent.click(checkbox);

        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));
        expect(await screen.findByText("Unable to load server health data.")).toBeTruthy();

        fireEvent.click(screen.getByLabelText("Refresh"));

        await waitFor(() => expect(
            (screen.getByLabelText("Mesh enabled for San Jose") as HTMLInputElement).checked
        ).toBe(false));
    });

    it("drops the optimistic override when the confirming read disagrees", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        // Another admin flips the same flag back between this tab's write and
        // its confirming read. The read started after the write, so it is the
        // newer truth and the override must not pin the optimistic value.
        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);
        const checkbox = await screen.findByLabelText("Mesh enabled for San Jose") as HTMLInputElement;
        fireEvent.click(checkbox);

        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));
        await waitFor(() => expect(
            (screen.getByLabelText("Mesh enabled for San Jose") as HTMLInputElement).checked
        ).toBe(false));
    });

    it("renders disabled regions with an explicit state and keeps their stale peers visible", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", true, 1),
            region("us-chicago-1", "Chicago", true, 2, false),
        ]);
        getMeshDocs.mockResolvedValue(new Map([
            ["us-sanjose-1", meshDoc("us-sanjose-1", { peers: { "us-chicago-1": meshPeer() } })],
        ]));

        render(<ServerHealth />);

        expect(await screen.findByText("Disabled")).toBeTruthy();
        // San Jose still has Chicago's peer installed even though Chicago is
        // dead, so the link stays on the page and reads as pending removal.
        expect(screen.getByText(
            "San Jose ↔ Chicago (disabled) · one-sided · San Jose applied, Chicago (disabled) not synced"
        )).toBeTruthy();
        expect(screen.getByText("(pending)")).toBeTruthy();
        expect(screen.getByText("Pending mesh changes - run Sync All Regions to apply them.")).toBeTruthy();

        // A disabled region's host is dead and no other region will peer with
        // it, so the toggle would write a flag that changes nothing. The
        // control says so instead of accepting a silent no-op.
        const disabledToggle = screen.getByLabelText("Mesh enabled for Chicago") as HTMLInputElement;
        expect(disabledToggle.disabled).toBe(true);
        fireEvent.click(disabledToggle);
        expect(setRegionMeshEnabled).not.toHaveBeenCalled();

        // Sync All still targets enabled regions only.
        fireEvent.click(screen.getByRole("button", { name: "Sync All Regions" }));
        const modal = screen.getByRole("dialog", { name: "Sync All Regions" });
        expect(within(modal).getByText("us-sanjose-1")).toBeTruthy();
        expect(within(modal).queryByText("us-chicago-1")).toBeNull();
        expect(within(modal).getByRole("button", { name: "Sync 1 region" })).toBeTruthy();
    });

    it("renders mesh configuration failures with a readable reason", async () => {
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", true, 1),
            region("us-chicago-1", "Chicago", true, 2),
        ]);
        getMeshDocs.mockResolvedValue(new Map([
            ["us-sanjose-1", meshDoc("us-sanjose-1", {
                peers: {
                    "us-chicago-1": meshPeer({ status: "skipped-overlap", reasonCode: "overlap-candidate" }),
                },
            })],
            ["us-chicago-1", meshDoc("us-chicago-1", {
                peers: {
                    "us-sanjose-1": meshPeer({ status: "skipped-incomplete", reasonCode: "not-a-known-code" }),
                },
            })],
        ]));

        render(<ServerHealth />);

        expect(await screen.findByText("Warnings")).toBeTruthy();
        expect(screen.getByText(
            "San Jose skipped Chicago: claimed subnet overlaps another region [overlap-candidate]"
        )).toBeTruthy();
        // An unknown reason code still renders, falling back to the status text.
        expect(screen.getByText(
            "Chicago skipped San Jose: mesh peer was skipped because required metadata is incomplete or invalid [not-a-known-code]"
        )).toBeTruthy();
    });

    it("sends a signed-out visitor to the login page", async () => {
        const { auth } = require("../../firebase");
        const { getAllRegionDocs } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        auth.currentUser = null;
        const { onAuthStateChanged } = require("../../firebase");
        onAuthStateChanged.mockImplementation((_auth: unknown, callback: (user: unknown) => void) => {
            authStateCallback = callback;
            deferFirstAuthCallback(callback, null);
            return () => undefined;
        });

        render(<ServerHealth />);

        await waitFor(() => expect(mockNavigate).toHaveBeenCalledWith("/", { replace: true }));
        expect(screen.queryByText("Mesh membership")).toBeNull();
        expect(getAllRegionDocs).not.toHaveBeenCalled();
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
