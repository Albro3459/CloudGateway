const PASSWORD_MIN_LENGTH = 8;
const PASSWORD_MAX_LENGTH = 4096;

export const validatePassword = (password: string): string | null => {
    if (password.length < PASSWORD_MIN_LENGTH) {
        return `Error: Password must be at least ${PASSWORD_MIN_LENGTH} characters long`;
    }
    if (password.length > PASSWORD_MAX_LENGTH) {
        return `Error: Password must be no more than ${PASSWORD_MAX_LENGTH} characters long`;
    }
    if (!/[A-Z]/.test(password)) {
        return "Error: Password must include an uppercase character";
    }
    if (!/[a-z]/.test(password)) {
        return "Error: Password must include a lowercase character";
    }
    if (!/[0-9]/.test(password)) {
        return "Error: Password must include a numeric character";
    }
    if (!/[^A-Za-z0-9]/.test(password)) {
        return "Error: Password must include a special character";
    }
    return null;
};
