import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import type { Region } from "../../helpers/regionsHelper";
import type { MeshDoc } from "../../helpers/meshHelper";
import type { PolicyDoc } from "../../helpers/policyHelper";
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
    getPolicyDocs: jest.fn(),
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

const policyDoc = (regionId: string, overrides: Partial<PolicyDoc> = {}): PolicyDoc => ({
    regionId,
    mapHashV4: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    mapHashV6: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    rowCount: 3,
    updatedAt: new Date("2026-01-01T00:00:00Z"),
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
    policyApplied: true,
    policyRowCount: 3,
    policyStatusWritten: true,
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
        const { getAllRegionDocs, getMeshDocs, getPolicyDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
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
        getPolicyDocs.mockResolvedValue(new Map());
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

        // "San Jose" now also appears in the Client isolation card's own
        // region row, so this has to target the mesh membership control
        // specifically rather than matching on the region name alone.
        expect(await screen.findByLabelText("Mesh enabled for San Jose")).toBeTruthy();
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
        // "San Jose" also appears in the Client isolation card's region row,
        // so this targets the mesh membership control specifically.
        expect(await screen.findByLabelText("Mesh enabled for San Jose")).toBeTruthy();
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

    it("warns when a region's account-scoped ACL policy pass failed", async () => {
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true, 1)]);
        getMeshDocs.mockResolvedValue(new Map());
        runRegionsSync.mockResolvedValue([
            {
                regionId: "us-sanjose-1",
                result: {
                    success: true,
                    data: syncResponse("us-sanjose-1", {
                        policyApplied: false,
                        policyRowCount: null,
                        policyStatusWritten: null,
                    }),
                },
            },
        ]);

        render(<ServerHealth />);

        expect(await screen.findByText(/client-isolation policy pass failed/)).toBeTruthy();
    });

    it("warns more mildly when a region applied its policy map but could not save the status snapshot", async () => {
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true, 1)]);
        getMeshDocs.mockResolvedValue(new Map());
        runRegionsSync.mockResolvedValue([
            {
                regionId: "us-sanjose-1",
                result: {
                    success: true,
                    data: syncResponse("us-sanjose-1", {
                        policyApplied: true,
                        policyRowCount: 5,
                        policyStatusWritten: false,
                    }),
                },
            },
        ]);

        render(<ServerHealth />);

        expect(await screen.findByText(/policy status snapshot could not/)).toBeTruthy();
        expect(screen.queryByText(/client-isolation policy pass failed/)).toBeNull();
    });

    it("stays quiet about policy status on a fully successful sync", async () => {
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true, 1)]);
        getMeshDocs.mockResolvedValue(new Map());
        runRegionsSync.mockResolvedValue([
            {
                regionId: "us-sanjose-1",
                result: {
                    success: true,
                    data: syncResponse("us-sanjose-1", {
                        policyApplied: true,
                        policyRowCount: 5,
                        policyStatusWritten: true,
                    }),
                },
            },
        ]);

        render(<ServerHealth />);

        expect(await screen.findByText("San Jose (us-sanjose-1)")).toBeTruthy();
        expect(screen.queryByText(/client-isolation policy pass failed/)).toBeNull();
        expect(screen.queryByText(/policy status snapshot could not/)).toBeNull();
    });

    it("stays quiet about policy status for a region that predates account-scoped ACL policy sync", async () => {
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true, 1)]);
        getMeshDocs.mockResolvedValue(new Map());
        runRegionsSync.mockResolvedValue([
            {
                regionId: "us-sanjose-1",
                result: {
                    success: true,
                    data: syncResponse("us-sanjose-1", {
                        policyApplied: null,
                        policyRowCount: null,
                        policyStatusWritten: null,
                    }),
                },
            },
        ]);

        render(<ServerHealth />);

        expect(await screen.findByText("San Jose (us-sanjose-1)")).toBeTruthy();
        expect(screen.queryByText(/client-isolation policy pass failed/)).toBeNull();
        expect(screen.queryByText(/policy status snapshot could not/)).toBeNull();
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

    it("renders a sync already running on the host as an expected outcome, not a failure", async () => {
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
                failureType: "sync-in-progress",
                errorCode: "SYNC_IN_PROGRESS",
                status: 409,
                error: "sync already running",
            },
        }]);

        render(<ServerHealth />);

        expect(await screen.findByText("A sync is already running on this region - try again shortly.")).toBeTruthy();
        expect(screen.queryByText("Failed")).toBeNull();
        expect(screen.queryByText("sync already running")).toBeNull();
    });

    it("retires a toggle's override when Sync All Regions supersedes its confirming read", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);
        const checkbox = await screen.findByLabelText("Mesh enabled for San Jose") as HTMLInputElement;

        // The toggle's own confirming read is slow.
        const confirmingRead = deferred<Region[]>();
        getAllRegionDocs.mockImplementationOnce(() => confirmingRead.promise);
        fireEvent.click(checkbox);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));
        // Sync All is blocked until the membership write acknowledges; the
        // confirming read that follows it does not block a sync.
        await waitFor(() => expect(
            (screen.getByRole("button", { name: "Sync All Regions" }) as HTMLButtonElement).disabled
        ).toBe(false));

        // Sync All Regions re-reads Region/Mesh state before the confirming
        // read resolves, superseding it as the load that gets to render.
        getAllRegionDocs.mockResolvedValueOnce([
            region("us-sanjose-1", "San Jose", true, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
        runRegionsSync.mockResolvedValueOnce([]);
        fireEvent.click(screen.getByRole("button", { name: "Sync All Regions" }));
        fireEvent.click(screen.getByRole("button", { name: "Sync 2 regions" }));
        await waitFor(() => expect(runRegionsSync).toHaveBeenCalled());

        // The superseded confirming read resolves last. If its override never
        // retires, a later refresh would keep showing the pinned optimistic
        // value regardless of what Firestore actually says.
        await act(async () => {
            confirmingRead.resolve([
                region("us-sanjose-1", "San Jose", true, 1),
                region("us-chicago-1", "Chicago", false, 2),
            ]);
            await confirmingRead.promise;
        });
        await waitFor(() => expect(
            (screen.getByLabelText("Refresh") as HTMLButtonElement).disabled
        ).toBe(false));

        getAllRegionDocs.mockResolvedValueOnce([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
        fireEvent.click(screen.getByLabelText("Refresh"));

        await waitFor(() => expect(
            (screen.getByLabelText("Mesh enabled for San Jose") as HTMLInputElement).checked
        ).toBe(false));
    });

    // Guards the revision check specifically. Retirement runs before the
    // isCurrent gate, so that check is now the only thing standing between a
    // stale confirming read and a newer toggle's override; drop it and this
    // fails. It does not exercise the reordering itself - under the old
    // ordering the isCurrent gate blocked this read first and the override
    // survived anyway.
    it("does not let an older superseded read retire a newer toggle's override on the same region", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);
        const checkbox = await screen.findByLabelText("Mesh enabled for San Jose") as HTMLInputElement;

        // Toggle 1's confirming read is slow.
        const firstConfirmingRead = deferred<Region[]>();
        getAllRegionDocs.mockImplementationOnce(() => firstConfirmingRead.promise);
        fireEvent.click(checkbox);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));

        // An auth-generation reset (e.g. a repeated observer callback for the
        // same admin) clears togglingRegionIds and re-enables the checkbox
        // while toggle 1's confirming read is still pending in the background.
        await act(async () => {
            authStateCallback?.(mockUser);
        });
        await waitFor(() => expect(
            (screen.getByLabelText("Mesh enabled for San Jose") as HTMLInputElement).disabled
        ).toBe(false));

        // Toggle 2 starts on the same region with a newer revision. Its own
        // confirming read is also slow.
        const secondConfirmingRead = deferred<Region[]>();
        getAllRegionDocs.mockImplementationOnce(() => secondConfirmingRead.promise);
        fireEvent.click(screen.getByLabelText("Mesh enabled for San Jose"));
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledTimes(2));

        // Toggle 1's stale confirming read finally resolves. It carries the
        // old revision, which no longer matches the override toggle 2
        // installed, so it must not retire toggle 2's override.
        await act(async () => {
            firstConfirmingRead.resolve([
                region("us-sanjose-1", "San Jose", true, 1),
                region("us-chicago-1", "Chicago", false, 2),
            ]);
            await firstConfirmingRead.promise;
        });

        // Sync All Regions re-reads Firestore in between, still authoritatively
        // false for this region. If toggle 1's stale read had wrongly cleared
        // toggle 2's override, this read would show the un-overridden false
        // value instead of staying pinned to the pending toggle's intent.
        getAllRegionDocs.mockResolvedValueOnce([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
        runRegionsSync.mockResolvedValueOnce([]);
        fireEvent.click(screen.getByRole("button", { name: "Sync All Regions" }));
        fireEvent.click(screen.getByRole("button", { name: "Sync 2 regions" }));

        await waitFor(() => expect(
            (screen.getByLabelText("Mesh enabled for San Jose") as HTMLInputElement).checked
        ).toBe(true));

        await act(async () => {
            secondConfirmingRead.resolve([
                region("us-sanjose-1", "San Jose", true, 1),
                region("us-chicago-1", "Chicago", false, 2),
            ]);
            await secondConfirmingRead.promise;
        });
    });

    it("retires a superseded confirming read's override when another region's toggle supersedes it", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);
        const sanJose = await screen.findByLabelText("Mesh enabled for San Jose") as HTMLInputElement;

        // San Jose's confirming read is slow.
        const sanJoseRead = deferred<Region[]>();
        getAllRegionDocs.mockImplementationOnce(() => sanJoseRead.promise);
        fireEvent.click(sanJose);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));

        // A second region is toggled while the first is still confirming. Only
        // the toggled region's checkbox is disabled, so this is an ordinary
        // path, not a contrived one: the toggle bumps the shared load
        // generation, superseding San Jose's read before it resolves.
        const chicagoRead = deferred<Region[]>();
        getAllRegionDocs.mockImplementationOnce(() => chicagoRead.promise);
        fireEvent.click(screen.getByLabelText("Mesh enabled for Chicago"));
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-chicago-1", true));

        // San Jose's read resolves superseded, so it never renders. Its
        // override still has to retire here, or the shared override map keeps
        // pinning San Jose for the rest of the session.
        await act(async () => {
            sanJoseRead.resolve([
                region("us-sanjose-1", "San Jose", true, 1),
                region("us-chicago-1", "Chicago", false, 2),
            ]);
            await sanJoseRead.promise;
        });

        // Chicago's read is the newest load, so it is the one that renders.
        // San Jose must come back authoritatively false rather than carrying an
        // orphaned optimistic true.
        await act(async () => {
            chicagoRead.resolve([
                region("us-sanjose-1", "San Jose", false, 1),
                region("us-chicago-1", "Chicago", true, 2),
            ]);
            await chicagoRead.promise;
        });

        await waitFor(() => expect(
            (screen.getByLabelText("Mesh enabled for San Jose") as HTMLInputElement).checked
        ).toBe(false));
        expect((screen.getByLabelText("Mesh enabled for Chicago") as HTMLInputElement).checked).toBe(true);
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

        // The Client isolation card also renders a "Disabled" state for a
        // disabled region (excluded from the policy comparison), so this has
        // to scope to the Mesh membership card specifically.
        await screen.findByText("Mesh membership");
        const meshCard = screen.getByText("Mesh membership").closest("div") as HTMLElement;
        expect(within(meshCard).getByText("Disabled")).toBeTruthy();
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

    it("renders per-region policy row count, last-applied time, and both comprehensive hashes without running a sync", async () => {
        const { getAllRegionDocs, getMeshDocs, getPolicyDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true, 1)]);
        getMeshDocs.mockResolvedValue(new Map());
        getPolicyDocs.mockResolvedValue(new Map([
            ["us-sanjose-1", policyDoc("us-sanjose-1", { rowCount: 7 })],
        ]));

        render(<ServerHealth />);

        expect(await screen.findByText("Client isolation")).toBeTruthy();
        expect(screen.getByText("OK")).toBeTruthy();
        expect(screen.getByText("7 rows")).toBeTruthy();
        expect(screen.getByText(/^Last applied /)).toBeTruthy();
        expect(screen.getByLabelText("Copy San Jose comprehensive IPv4 policy hash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")).toBeTruthy();
        expect(screen.getByLabelText("Copy San Jose comprehensive IPv6 policy hash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")).toBeTruthy();
        expect(runRegionsSync).not.toHaveBeenCalled();
    });

    it("renders a zero-row snapshot's row count and last-applied time rather than a 'no snapshot' message", async () => {
        const { getAllRegionDocs, getMeshDocs, getPolicyDocs } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true, 1)]);
        getMeshDocs.mockResolvedValue(new Map());
        getPolicyDocs.mockResolvedValue(new Map([
            ["us-sanjose-1", policyDoc("us-sanjose-1", { rowCount: 0 })],
        ]));

        render(<ServerHealth />);

        expect(await screen.findByText("Client isolation")).toBeTruthy();
        expect(screen.getByText("0 rows")).toBeTruthy();
        expect(screen.getByText(/^Last applied /)).toBeTruthy();
        expect(screen.queryByText("No applied snapshot yet")).toBeNull();
    });

    it("flags a region as drifted against the fleet majority without requiring a sync first", async () => {
        const { getAllRegionDocs, getMeshDocs, getPolicyDocs } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", true, 1),
            region("us-chicago-1", "Chicago", true, 2),
            region("us-dallas-1", "Dallas", true, 3),
        ]);
        getMeshDocs.mockResolvedValue(new Map());
        getPolicyDocs.mockResolvedValue(new Map([
            ["us-sanjose-1", policyDoc("us-sanjose-1")],
            ["us-chicago-1", policyDoc("us-chicago-1")],
            ["us-dallas-1", policyDoc("us-dallas-1", { mapHashV4: "cccccccccccccccccccccccccccccccc" })],
        ]));

        render(<ServerHealth />);

        expect(await screen.findByText("Drifted")).toBeTruthy();
        expect(screen.getByText("IPv4 map differs from the fleet.")).toBeTruthy();
        expect(runRegionsSync).not.toHaveBeenCalled();
    });

    it("excludes a disabled region from the policy comparison: its divergent hash cannot drift enabled regions, and it renders its own disabled state instead of ok/drifted", async () => {
        const { getAllRegionDocs, getMeshDocs, getPolicyDocs } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", true, 1),
            region("us-chicago-1", "Chicago", true, 2),
            region("us-dallas-1", "Dallas", true, 3, false),
        ]);
        getMeshDocs.mockResolvedValue(new Map());
        getPolicyDocs.mockResolvedValue(new Map([
            ["us-sanjose-1", policyDoc("us-sanjose-1")],
            ["us-chicago-1", policyDoc("us-chicago-1")],
            // Dallas is disabled and wildly divergent - must not drift anyone,
            // and must not be flagged drifted itself.
            ["us-dallas-1", policyDoc("us-dallas-1", { mapHashV4: "cccccccccccccccccccccccccccccccc" })],
        ]));

        render(<ServerHealth />);

        await screen.findByText("Client isolation");
        const policyCard = screen.getByText("Client isolation").closest("div") as HTMLElement;
        // Both enabled regions stay OK - Dallas's divergent hash never enters
        // the comparison.
        expect(within(policyCard).getAllByText("OK")).toHaveLength(2);
        expect(within(policyCard).queryByText("Drifted")).toBeNull();
        expect(within(policyCard).getByText("Disabled")).toBeTruthy();
        expect(within(policyCard).getByText("Region disabled - excluded from the fleet comparison.")).toBeTruthy();
    });

    it("renders an explicit failure card for a missing or unreadable Policy doc without crashing the page", async () => {
        const { getAllRegionDocs, getMeshDocs, getPolicyDocs } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", true, 1),
            region("us-chicago-1", "Chicago", true, 2),
        ]);
        getMeshDocs.mockResolvedValue(new Map());
        getPolicyDocs.mockResolvedValue(new Map([
            ["us-sanjose-1", null],
            // Missing mapHashV4 makes the doc unusable for comparison, distinct
            // from a region that has simply never synced.
            ["us-chicago-1", policyDoc("us-chicago-1", { mapHashV4: null })],
        ]));

        render(<ServerHealth />);

        // Mesh membership's own "Never synced" freshness label uses the same
        // text, so this has to scope to the Client isolation card itself.
        await screen.findByText("Client isolation");
        const policyCard = screen.getByText("Client isolation").closest("div") as HTMLElement;
        expect(within(policyCard).getByText("Never synced")).toBeTruthy();
        expect(within(policyCard).getByText("No policy reconcile has completed for this region yet.")).toBeTruthy();
        expect(within(policyCard).getByText("Unreadable")).toBeTruthy();
        expect(within(policyCard).getByText("Policy status could not be read for this region.")).toBeTruthy();
        // The rest of the page rendered fine - a bad Policy doc never crashes it.
        expect(screen.getByText("Mesh membership")).toBeTruthy();
    });

    it("leaves the rest of the page intact and reads differently from never-synced when the Policy collection fails to load", async () => {
        const { getAllRegionDocs, getMeshDocs, getPolicyDocs } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");

        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", true, 1)]);
        getMeshDocs.mockResolvedValue(new Map());
        getPolicyDocs.mockRejectedValue(new Error("Policy collection unavailable"));

        render(<ServerHealth />);

        // Mesh membership still renders: a Policy read failure must not blank
        // the rest of the page. This region's own Mesh doc is also absent, so
        // its freshness label reads "Never synced" too - that's a separate,
        // legitimate mesh state and not what this test is checking.
        expect(await screen.findByLabelText("Mesh enabled for San Jose")).toBeTruthy();
        expect(screen.getByText("Mesh membership")).toBeTruthy();
        expect(screen.queryByText("Unable to load server health data.")).toBeNull();

        // The Client isolation card gets its own distinct failure message
        // instead of collapsing into "Never synced" for every region, which
        // would misreport a read failure as a fleet-wide never-synced state.
        const policyCard = screen.getByText("Client isolation").closest("div") as HTMLElement;
        expect(within(policyCard).getByText(
            "Unable to load client isolation status. This is a read failure, not a report that no region has completed a policy reconcile."
        )).toBeTruthy();
        expect(within(policyCard).queryByText("Never synced")).toBeNull();
    });
    // --- Sync All write barrier (mesh membership must be durable first) ---

    const renderWithTwoRegions = async () => {
        const { getAllRegionDocs, getMeshDocs } = require("../../helpers/firebaseDbHelper");
        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
        getMeshDocs.mockResolvedValue(new Map());
        const { default: ServerHealth } = require("../ServerHealth");
        render(<ServerHealth />);
        return await screen.findByLabelText("Mesh enabled for San Jose") as HTMLInputElement;
    };

    const syncAllButton = () => screen.getByRole("button", { name: "Sync All Regions" }) as HTMLButtonElement;

    it("blocks Sync All until an unresolved mesh membership write acknowledges", async () => {
        const { setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const write = deferred<void>();
        const checkbox = await renderWithTwoRegions();
        setRegionMeshEnabled.mockReturnValueOnce(write.promise);

        fireEvent.click(checkbox);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));

        // The optimistic checkbox already shows the new value while Firestore
        // has not acknowledged it, so a sync now would hand the regional API a
        // membership it cannot read.
        expect(checkbox.checked).toBe(true);
        expect(syncAllButton().disabled).toBe(true);
        expect(screen.getByText("Waiting for mesh membership changes to save before syncing.")).toBeTruthy();
        expect(runRegionsSync).not.toHaveBeenCalled();

        await act(async () => {
            write.resolve();
            await write.promise;
        });

        await waitFor(() => expect(syncAllButton().disabled).toBe(false));
    });

    it("holds a confirmed sync until every concurrent membership write settles", async () => {
        const { setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const firstWrite = deferred<void>();
        const secondWrite = deferred<void>();
        const checkbox = await renderWithTwoRegions();
        setRegionMeshEnabled
            .mockReturnValueOnce(firstWrite.promise)
            .mockReturnValueOnce(secondWrite.promise);

        fireEvent.click(checkbox);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));
        fireEvent.click(screen.getByLabelText("Mesh enabled for Chicago"));
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledTimes(2));

        await act(async () => {
            firstWrite.resolve();
            await firstWrite.promise;
        });

        expect(syncAllButton().disabled).toBe(true);
        expect(runRegionsSync).not.toHaveBeenCalled();

        await act(async () => {
            secondWrite.resolve();
            await secondWrite.promise;
        });

        await waitFor(() => expect(syncAllButton().disabled).toBe(false));
    });

    it("aborts a Home-confirmed sync whose membership write failed", async () => {
        // The Home path never passes through this page's button, so the button
        // gating cannot protect it - the barrier has to live in the sync path.
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        const write = deferred<void>();
        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
        getMeshDocs.mockResolvedValue(new Map());
        setRegionMeshEnabled.mockReturnValueOnce(write.promise);

        render(<ServerHealth />);
        const checkbox = await screen.findByLabelText("Mesh enabled for San Jose") as HTMLInputElement;
        fireEvent.click(checkbox);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));

        // The Home-originated run arrives while that write is unresolved.
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        fireEvent.click(screen.getByLabelText("Refresh"));
        await waitFor(() => expect(runRegionsSync).not.toHaveBeenCalled());

        await act(async () => {
            write.reject(new Error("firestore unavailable"));
            await write.promise.catch(() => undefined);
        });

        await waitFor(() => expect(
            screen.getByText("A mesh membership change did not save, so nothing was synced. Review the regions and sync again.")
        ).toBeTruthy());
        expect(runRegionsSync).not.toHaveBeenCalled();
        // The optimistic value rolled back, so the page does not claim a
        // membership the fleet never got.
        await waitFor(() => expect(
            (screen.getByLabelText("Mesh enabled for San Jose") as HTMLInputElement).checked
        ).toBe(false));
    });

    it("syncs the membership acknowledged after the barrier, not the pre-barrier snapshot", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        const write = deferred<void>();
        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2, false),
        ]);
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);
        const checkbox = await screen.findByLabelText("Mesh enabled for San Jose") as HTMLInputElement;
        setRegionMeshEnabled.mockReturnValueOnce(write.promise);
        fireEvent.click(checkbox);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));

        // Confirmed while the write is still outstanding, through the same
        // entry point the Home button uses.
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        fireEvent.click(screen.getByLabelText("Refresh"));
        await waitFor(() => expect(
            (screen.getByLabelText("Refresh") as HTMLButtonElement).disabled
        ).toBe(false));
        expect(runRegionsSync).not.toHaveBeenCalled();

        // Chicago is enabled fleet-side and rendered while the barrier waits,
        // so the confirm-time membership is already out of date.
        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
        fireEvent.click(screen.getByLabelText("Refresh"));
        await waitFor(() => expect(
            (screen.getByLabelText("Mesh enabled for Chicago") as HTMLInputElement).disabled
        ).toBe(false));

        await act(async () => {
            write.resolve();
            await write.promise;
        });

        await waitFor(() => expect(runRegionsSync).toHaveBeenCalledWith(
            ["us-sanjose-1", "us-chicago-1"],
            "firebase-token",
        ));
    });

    it("keeps the barrier across a repeated observer callback for the same admin", async () => {
        const { setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const write = deferred<void>();
        const checkbox = await renderWithTwoRegions();
        setRegionMeshEnabled.mockReturnValueOnce(write.promise);

        fireEvent.click(checkbox);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));

        // The callback clears togglingRegionIds (presentation state) but cannot
        // clear the unresolved write.
        await act(async () => {
            authStateCallback?.(mockUser);
        });

        expect(syncAllButton().disabled).toBe(true);
        expect(runRegionsSync).not.toHaveBeenCalled();

        await act(async () => {
            write.resolve();
            await write.promise;
        });
        await waitFor(() => expect(syncAllButton().disabled).toBe(false));
    });

    it("drops a confirmed sync when the account changes while the barrier is waiting", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { auth } = require("../../firebase");
        const { default: ServerHealth } = require("../ServerHealth");
        const write = deferred<void>();
        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);
        const checkbox = await screen.findByLabelText("Mesh enabled for San Jose") as HTMLInputElement;
        setRegionMeshEnabled.mockReturnValueOnce(write.promise);
        fireEvent.click(checkbox);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));

        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        fireEvent.click(screen.getByLabelText("Refresh"));

        const otherAdmin = { uid: "admin-2", email: "other@example.com", getIdToken: jest.fn().mockResolvedValue("other-token") };
        auth.currentUser = otherAdmin;
        await act(async () => {
            authStateCallback?.(otherAdmin);
        });
        await act(async () => {
            write.resolve();
            await write.promise;
        });

        expect(runRegionsSync).not.toHaveBeenCalled();
    });

    it("disables the modal's confirm button while a mesh write is outstanding, and re-enables it once the write acknowledges", async () => {
        const { setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const write = deferred<void>();
        const checkbox = await renderWithTwoRegions();

        // Opened before any write is pending, so the confirm button starts enabled.
        fireEvent.click(syncAllButton());
        const modal = screen.getByRole("dialog", { name: "Sync All Regions" });
        const confirmButton = within(modal).getByRole("button", { name: "Sync 2 regions" }) as HTMLButtonElement;
        expect(confirmButton.disabled).toBe(false);

        setRegionMeshEnabled.mockReturnValueOnce(write.promise);
        fireEvent.click(checkbox);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));

        // The write is unresolved, so the modal itself - not just the page
        // button behind it - must block confirmation against a membership
        // Firestore hasn't acknowledged yet.
        await waitFor(() => expect(confirmButton.disabled).toBe(true));
        expect(within(modal).getByText("Waiting for mesh membership changes to save before syncing.")).toBeTruthy();

        fireEvent.click(confirmButton);
        expect(runRegionsSync).not.toHaveBeenCalled();
        expect(screen.getByRole("dialog", { name: "Sync All Regions" })).toBeTruthy();

        await act(async () => {
            write.resolve();
            await write.promise;
        });

        await waitFor(() => expect(confirmButton.disabled).toBe(false));
    });

    it("keeps waiting when a second write starts while the barrier is already draining the first, then syncs the state acknowledged after both", async () => {
        // Pins the awaitPendingMeshWrites loop's second pass: a single-shot
        // await would resolve the sync as soon as write A settles, even
        // though write B registered itself mid-drain.
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        const writeA = deferred<void>();
        const writeB = deferred<void>();
        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
            region("us-dallas-1", "Dallas", false, 3, false),
        ]);
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);
        const sanJose = await screen.findByLabelText("Mesh enabled for San Jose") as HTMLInputElement;

        setRegionMeshEnabled.mockReturnValueOnce(writeA.promise);
        fireEvent.click(sanJose);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));

        // Confirm through the Home entry point while write A is outstanding.
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        fireEvent.click(screen.getByLabelText("Refresh"));
        await waitFor(() => expect(
            (screen.getByLabelText("Refresh") as HTMLButtonElement).disabled
        ).toBe(false));
        expect(runRegionsSync).not.toHaveBeenCalled();

        // Write B starts after the barrier has already begun draining write A.
        setRegionMeshEnabled.mockReturnValueOnce(writeB.promise);
        fireEvent.click(screen.getByLabelText("Mesh enabled for Chicago"));
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-chicago-1", true));

        await act(async () => {
            writeA.resolve();
            await writeA.promise;
        });
        // Write A settling alone must not release the sync.
        expect(runRegionsSync).not.toHaveBeenCalled();

        // Dallas comes online while the barrier is still waiting on write B.
        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", true, 1),
            region("us-chicago-1", "Chicago", true, 2),
            region("us-dallas-1", "Dallas", false, 3),
        ]);
        fireEvent.click(screen.getByLabelText("Refresh"));
        await waitFor(() => expect(
            (screen.getByLabelText("Mesh enabled for Dallas") as HTMLInputElement).disabled
        ).toBe(false));

        await act(async () => {
            writeB.resolve();
            await writeB.promise;
        });

        await waitFor(() => expect(runRegionsSync).toHaveBeenCalledWith(
            ["us-sanjose-1", "us-chicago-1", "us-dallas-1"],
            "firebase-token",
        ));
    });

    it("allows a newly confirmed sync after a failed toggle rolls back, and targets the post-rollback state rather than the aborted optimistic value", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        const write = deferred<void>();
        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
        getMeshDocs.mockResolvedValue(new Map());
        setRegionMeshEnabled.mockReturnValueOnce(write.promise);

        render(<ServerHealth />);
        const checkbox = await screen.findByLabelText("Mesh enabled for San Jose") as HTMLInputElement;
        fireEvent.click(checkbox);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));

        // Confirm through the Home entry point while the write is outstanding.
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        fireEvent.click(screen.getByLabelText("Refresh"));
        await waitFor(() => expect(
            (screen.getByLabelText("Refresh") as HTMLButtonElement).disabled
        ).toBe(false));
        expect(runRegionsSync).not.toHaveBeenCalled();

        await act(async () => {
            write.reject(new Error("firestore unavailable"));
            await write.promise.catch(() => undefined);
        });

        // The write failed: the confirmed intent aborts and the optimistic
        // value rolls back before anything else can run.
        await waitFor(() => expect(
            (screen.getByLabelText("Mesh enabled for San Jose") as HTMLInputElement).checked
        ).toBe(false));
        expect(runRegionsSync).not.toHaveBeenCalled();

        // A region comes online after the abort. If a newly confirmed sync
        // were stuck behind the now-retired write, or targeted a regionsRef
        // snapshot captured before the rollback, this region would never
        // reach the fan-out.
        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
            region("us-dallas-1", "Dallas", false, 3),
        ]);
        fireEvent.click(screen.getByLabelText("Refresh"));
        await screen.findByLabelText("Mesh enabled for Dallas");

        runRegionsSync.mockResolvedValueOnce([]);
        fireEvent.click(screen.getByRole("button", { name: "Sync All Regions" }));
        fireEvent.click(screen.getByRole("button", { name: "Sync 3 regions" }));

        await waitFor(() => expect(runRegionsSync).toHaveBeenCalledWith(
            ["us-sanjose-1", "us-chicago-1", "us-dallas-1"],
            "firebase-token",
        ));
        // The retired write never resurrects San Jose's aborted optimistic value.
        expect((screen.getByLabelText("Mesh enabled for San Jose") as HTMLInputElement).checked).toBe(false);
    });

    it("rolls a toggle back when the mesh write throws synchronously instead of rejecting", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        getAllRegionDocs.mockResolvedValue([region("us-sanjose-1", "San Jose", false, 1)]);
        getMeshDocs.mockResolvedValue(new Map());
        // Not a rejected promise: setRegionMeshEnabled throws before it ever
        // returns one. Started outside the toggle's try, that escapes the
        // handler entirely - no rollback, no banner, and the region stays
        // pinned in togglingRegionIds for the rest of the session.
        setRegionMeshEnabled.mockImplementationOnce(() => {
            throw new Error("firestore unavailable");
        });

        render(<ServerHealth />);
        const checkbox = await screen.findByLabelText("Mesh enabled for San Jose") as HTMLInputElement;
        fireEvent.click(checkbox);

        await waitFor(() => expect(
            (screen.getByLabelText("Mesh enabled for San Jose") as HTMLInputElement).checked
        ).toBe(false));
        expect(await screen.findByText("Unable to update San Jose.")).toBeTruthy();
        const settled = screen.getByLabelText("Mesh enabled for San Jose") as HTMLInputElement;
        expect(settled.disabled).toBe(false);
        expect(settled.getAttribute("aria-busy")).toBe("false");
        // The write never reached the registry, so nothing is left blocking a sync.
        expect((screen.getByRole("button", { name: "Sync All Regions" }) as HTMLButtonElement).disabled).toBe(false);
    });

    it("drops a region disabled while the barrier waits from the post-barrier sync targets", async () => {
        const { getAllRegionDocs, getMeshDocs, setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const { default: ServerHealth } = require("../ServerHealth");
        const write = deferred<void>();
        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2),
        ]);
        getMeshDocs.mockResolvedValue(new Map());

        render(<ServerHealth />);
        const checkbox = await screen.findByLabelText("Mesh enabled for San Jose") as HTMLInputElement;
        setRegionMeshEnabled.mockReturnValueOnce(write.promise);
        fireEvent.click(checkbox);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));

        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        fireEvent.click(screen.getByLabelText("Refresh"));
        await waitFor(() => expect(
            (screen.getByLabelText("Refresh") as HTMLButtonElement).disabled
        ).toBe(false));
        expect(runRegionsSync).not.toHaveBeenCalled();

        // The mirror of the newly-enabled case: Chicago is disabled fleet-side
        // while the barrier waits, so the confirm-time membership is stale in
        // the other direction and syncing it would target a region the fan-out
        // must no longer touch.
        getAllRegionDocs.mockResolvedValue([
            region("us-sanjose-1", "San Jose", false, 1),
            region("us-chicago-1", "Chicago", false, 2, false),
        ]);
        fireEvent.click(screen.getByLabelText("Refresh"));
        await waitFor(() => expect(
            (screen.getByLabelText("Mesh enabled for Chicago") as HTMLInputElement).disabled
        ).toBe(true));

        await act(async () => {
            write.resolve();
            await write.promise;
        });

        await waitFor(() => expect(runRegionsSync).toHaveBeenCalledWith(
            ["us-sanjose-1"],
            "firebase-token",
        ));
    });

    it("reads as queued only once a sync is confirmed behind the barrier, not while a write is merely outstanding", async () => {
        const { setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const write = deferred<void>();
        const checkbox = await renderWithTwoRegions();
        setRegionMeshEnabled.mockReturnValueOnce(write.promise);

        fireEvent.click(checkbox);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));

        // Nothing confirmed yet: the page says the sync is blocked, not queued.
        expect(screen.getByText("Waiting for mesh membership changes to save before syncing.")).toBeTruthy();
        expect(screen.queryByText("Sync queued - it starts as soon as the mesh membership changes finish saving.")).toBeNull();

        // Confirmed through the Home entry point, which the disabled button
        // cannot gate.
        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        fireEvent.click(screen.getByLabelText("Refresh"));

        const queuedHelp = await screen.findByText("Sync queued - it starts as soon as the mesh membership changes finish saving.");
        expect(queuedHelp.getAttribute("role")).toBe("status");
        expect(screen.queryByText("Waiting for mesh membership changes to save before syncing.")).toBeNull();
        expect(screen.getByRole("button", { name: "Sync queued..." })).toBeTruthy();
        expect(runRegionsSync).not.toHaveBeenCalled();

        await act(async () => {
            write.resolve();
            await write.promise;
        });

        // The barrier drained, so the queue is over: the run itself owns the
        // busy state from here.
        await waitFor(() => expect(runRegionsSync).toHaveBeenCalled());
        expect(screen.queryByText("Sync queued - it starts as soon as the mesh membership changes finish saving.")).toBeNull();
        expect(screen.queryByRole("button", { name: "Sync queued..." })).toBeNull();
    });

    it("clears the queued state when the confirmed sync is aborted by a failed write", async () => {
        const { setRegionMeshEnabled } = require("../../helpers/firebaseDbHelper");
        const { runRegionsSync } = require("../../helpers/APIHelper");
        const write = deferred<void>();
        const checkbox = await renderWithTwoRegions();
        setRegionMeshEnabled.mockReturnValueOnce(write.promise);

        fireEvent.click(checkbox);
        await waitFor(() => expect(setRegionMeshEnabled).toHaveBeenCalledWith("us-sanjose-1", true));

        mockLocation = { pathname: "/server-health", state: { runSync: true } };
        fireEvent.click(screen.getByLabelText("Refresh"));
        await screen.findByText("Sync queued - it starts as soon as the mesh membership changes finish saving.");

        await act(async () => {
            write.reject(new Error("firestore unavailable"));
            await write.promise.catch(() => undefined);
        });

        // The abort banner is the outcome, so leaving a queued spinner behind
        // would claim a run that is never going to start.
        await waitFor(() => expect(
            screen.getByText("A mesh membership change did not save, so nothing was synced. Review the regions and sync again.")
        ).toBeTruthy());
        expect(screen.queryByText("Sync queued - it starts as soon as the mesh membership changes finish saving.")).toBeNull();
        expect(screen.queryByRole("button", { name: "Sync queued..." })).toBeNull();
        expect(runRegionsSync).not.toHaveBeenCalled();
    });

});
