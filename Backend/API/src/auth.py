from abc import ABC, abstractmethod
from dataclasses import dataclass

from fastapi import Depends, Request

from .enums import Role
from .errors import AdminRequiredError, AuthRequiredError, UserNotProvisionedError

USER_NOT_PROVISIONED_DISABLED_MESSAGE = (
    "Your account does not have access to CloudGateway. "
    "Your account has been disabled until an admin grants access."
)


@dataclass(frozen=True)
class AuthenticatedUser:
    uid: str
    email: str | None = None


class TokenVerifier(ABC):
    @abstractmethod
    def verify_token(self, token: str) -> AuthenticatedUser:
        """Return the authenticated user or raise AuthRequiredError."""


def bearer_token(request: Request) -> str:
    header = request.headers.get("Authorization", "")
    scheme, _, token = header.partition(" ")
    token = token.strip()
    if scheme.lower() != "bearer" or not token:
        raise AuthRequiredError("Missing bearer token.")
    return token


def get_current_user(request: Request) -> AuthenticatedUser:
    return request.app.state.token_verifier.verify_token(bearer_token(request))


def require_role_or_disable_unprovisioned(request: Request, user: AuthenticatedUser) -> Role:
    repository = request.app.state.repository
    role = repository.get_role(user.uid)
    if role is None:
        repository.disable_auth_user(user.uid)
        raise UserNotProvisionedError(USER_NOT_PROVISIONED_DISABLED_MESSAGE)
    return role


def require_admin_user(
    request: Request,
    user: AuthenticatedUser = Depends(get_current_user),
) -> AuthenticatedUser:
    role = require_role_or_disable_unprovisioned(request, user)
    if role != Role.ADMIN:
        raise AdminRequiredError()
    return user


def require_provisioned_user(
    request: Request,
    user: AuthenticatedUser = Depends(get_current_user),
) -> AuthenticatedUser:
    require_role_or_disable_unprovisioned(request, user)
    return user
