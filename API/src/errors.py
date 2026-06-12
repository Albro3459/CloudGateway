from .enums import ErrorCode


HTTP_STATUS_BY_CODE: dict[ErrorCode, int] = {
    ErrorCode.AUTH_REQUIRED: 401,
    ErrorCode.ADMIN_REQUIRED: 403,
    ErrorCode.USER_NOT_PROVISIONED: 403,
    ErrorCode.INVALID_REQUEST: 400,
    ErrorCode.REGION_DISABLED: 400,
    ErrorCode.REGION_MISMATCH: 400,
    ErrorCode.INVALID_PASSWORD: 400,
    ErrorCode.CLIENT_NOT_FOUND: 404,
    ErrorCode.DUPLICATE_EMAIL: 409,
    ErrorCode.ACCOUNT_DISABLED: 409,
    ErrorCode.LIMIT_REACHED: 409,
    ErrorCode.CAPACITY_REACHED: 409,
    ErrorCode.WIREGUARD_APPLY_FAILED: 500,
    ErrorCode.FIREBASE_WRITE_FAILED: 500,
    ErrorCode.INTERNAL_ERROR: 500,
}


class ApiError(Exception):
    code = ErrorCode.INTERNAL_ERROR
    default_message = "Unexpected error."

    def __init__(self, message: str | None = None):
        self.message = message or self.default_message
        super().__init__(self.message)

    @property
    def http_status(self) -> int:
        return HTTP_STATUS_BY_CODE[self.code]


class AuthRequiredError(ApiError):
    code = ErrorCode.AUTH_REQUIRED
    default_message = "Authentication required."


class AdminRequiredError(ApiError):
    code = ErrorCode.ADMIN_REQUIRED
    default_message = "Admin role required."


class UserNotProvisionedError(ApiError):
    code = ErrorCode.USER_NOT_PROVISIONED
    default_message = "User is not provisioned for CloudGateway."


class InvalidRequestError(ApiError):
    code = ErrorCode.INVALID_REQUEST
    default_message = "Invalid request."


class RegionDisabledError(ApiError):
    code = ErrorCode.REGION_DISABLED
    default_message = "Requested region is disabled."


class RegionMismatchError(ApiError):
    code = ErrorCode.REGION_MISMATCH
    default_message = "Requested region does not match this API server."


class LimitReachedError(ApiError):
    code = ErrorCode.LIMIT_REACHED
    default_message = "Client limit reached for this region."


class CapacityReachedError(ApiError):
    code = ErrorCode.CAPACITY_REACHED
    default_message = "Server capacity reached for this region."


class ClientNotFoundError(ApiError):
    code = ErrorCode.CLIENT_NOT_FOUND
    default_message = "Client not found."


class DuplicateEmailError(ApiError):
    code = ErrorCode.DUPLICATE_EMAIL
    default_message = "An account already exists for this email and already has access."


class AccountDisabledError(ApiError):
    code = ErrorCode.ACCOUNT_DISABLED
    default_message = "Account is disabled and cannot be granted access."


class InvalidPasswordError(ApiError):
    code = ErrorCode.INVALID_PASSWORD
    default_message = "Password does not meet requirements."


class WireGuardApplyFailedError(ApiError):
    code = ErrorCode.WIREGUARD_APPLY_FAILED
    default_message = "Failed to apply WireGuard change."

    def __init__(self, message: str | None = None, *, transient: bool = False):
        self.transient = transient
        super().__init__(message)


class FirebaseWriteFailedError(ApiError):
    code = ErrorCode.FIREBASE_WRITE_FAILED
    default_message = "Failed to write to Firebase."


class InternalError(ApiError):
    code = ErrorCode.INTERNAL_ERROR
    default_message = "Unexpected error."
