from abc import ABC, abstractmethod
from dataclasses import dataclass

from fastapi import Depends, Request

from .enums import Role
from .errors import AdminRequiredError, AuthRequiredError


@dataclass(frozen=True)
class AuthenticatedUser:
    uid: str
    email: str | None = None
    display_name: str | None = None


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


def require_admin_user(
    request: Request,
    user: AuthenticatedUser = Depends(get_current_user),
) -> AuthenticatedUser:
    role = request.app.state.repository.get_role(user.uid)
    if role != Role.ADMIN:
        raise AdminRequiredError()
    return user
