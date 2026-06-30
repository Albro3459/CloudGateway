import { render, screen } from "@testing-library/react";

const mockNavigate = jest.fn();

jest.mock("react-router-dom", () => ({
    useLocation: () => ({
        state: {
            email: "new.user@example.com",
            alreadyExisted: false,
        },
    }),
    useNavigate: () => mockNavigate,
}), { virtual: true });

jest.mock("../../firebase", () => ({
    auth: {},
    onAuthStateChanged: jest.fn((_auth, callback) => {
        setTimeout(() => callback({ uid: "admin-1" }), 0);
        return () => undefined;
    }),
}));

jest.mock("../../helpers/firebaseDbHelper", () => ({
    logout: jest.fn(),
}));

describe("CreateUserSuccess", () => {
    it("renders email, website, and sign-in instructions without password text", () => {
        const { default: CreateUserSuccess } = require("../CreateUserSuccess");

        render(<CreateUserSuccess />);

        expect(screen.getByText("User Has Access")).toBeTruthy();
        expect(screen.getByText("new.user@example.com")).toBeTruthy();
        expect(screen.getByText(window.location.origin)).toBeTruthy();
        expect(screen.getByText(/They can sign in with Google/)).toBeTruthy();
        expect(screen.queryByText(/Password:/i)).toBeNull();
    });
});
