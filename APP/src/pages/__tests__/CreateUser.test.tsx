import { fireEvent, render, screen, waitFor } from "@testing-library/react";

const mockNavigate = jest.fn();

jest.mock("react-router-dom", () => ({
    useNavigate: () => mockNavigate,
}), { virtual: true });

jest.mock("../../firebase", () => ({
    auth: {},
}));

jest.mock("firebase/auth", () => ({
    getIdToken: jest.fn().mockResolvedValue("firebase-token"),
    onAuthStateChanged: jest.fn((_auth, callback) => {
        setTimeout(() => callback({ uid: "admin-1" }), 0);
        return () => undefined;
    }),
}));

jest.mock("../../helpers/APIHelper", () => ({
    createAdminUser: jest.fn().mockResolvedValue({
        success: true,
        data: {
            userId: "user-1",
            email: "new.user@example.com",
            role: "user",
            alreadyExisted: false,
        },
    }),
}));

jest.mock("../../helpers/firebaseDbHelper", () => ({
    logout: jest.fn(),
}));

jest.mock("../../helpers/usersHelper", () => ({
    getUserRole: jest.fn().mockResolvedValue("admin"),
}));

jest.mock("../../stores/ociRegionsStore", () => ({
    fetchOciRegions: jest.fn(),
    useOciRegionsStore: () => ({
        ociRegions: [{ regionId: "us-sanjose-1", enabled: true }],
        loading: false,
        error: null,
    }),
}));

describe("CreateUser", () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    it("grants access with email only", async () => {
        const { createAdminUser } = require("../../helpers/APIHelper");
        const { fetchOciRegions } = require("../../stores/ociRegionsStore");
        const { default: CreateUser } = require("../CreateUser");

        render(<CreateUser />);

        await screen.findByRole("button", { name: "Grant Access" });
        await waitFor(() => {
            expect(fetchOciRegions).toHaveBeenCalledWith("firebase-token", true);
        });

        expect(screen.queryAllByLabelText(/password/i)).toHaveLength(0);

        fireEvent.change(screen.getByPlaceholderText("Email"), {
            target: { value: " new.user@example.com " },
        });
        fireEvent.click(screen.getByRole("button", { name: "Grant Access" }));

        await waitFor(() => {
            expect(createAdminUser).toHaveBeenCalledWith(
                { email: "new.user@example.com" },
                "firebase-token",
                [{ regionId: "us-sanjose-1", enabled: true }],
            );
        });
    });
});
