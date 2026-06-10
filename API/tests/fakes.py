from cloudlaunch_api.auth import AuthenticatedUser, TokenVerifier
from cloudlaunch_api.enums import OperationResult, Role
from cloudlaunch_api.errors import AuthRequiredError
from cloudlaunch_api.repository import FirebaseRepository
from cloudlaunch_api.wireguard import WireGuardKeypair, WireGuardManager


class FakeTokenVerifier(TokenVerifier):
    def __init__(self, users: dict[str, AuthenticatedUser] | None = None):
        self.users = users or {}

    def verify_token(self, token: str) -> AuthenticatedUser:
        user = self.users.get(token)
        if user is None:
            raise AuthRequiredError("Invalid or expired token.")
        return user


class FakeRepository(FirebaseRepository):
    def __init__(self):
        self.roles: dict[str, Role] = {}

    def get_role(self, uid: str) -> Role | None:
        return self.roles.get(uid)


class FakeWireGuardManager(WireGuardManager):
    def __init__(self):
        self.peers: dict[str, str] = {}
        self.keypair_count = 0

    def generate_keypair(self) -> WireGuardKeypair:
        self.keypair_count += 1
        return WireGuardKeypair(
            private_key=f"fake-private-{self.keypair_count}",
            public_key=f"fake-public-{self.keypair_count}",
        )

    def add_peer(
        self,
        *,
        client_id: str,
        public_key: str,
        tunnel_ipv4: str,
        tunnel_ipv6: str,
    ) -> None:
        self.peers[public_key] = client_id

    def remove_peer(self, *, client_id: str, public_key: str) -> OperationResult:
        if public_key not in self.peers:
            return OperationResult.NOOP
        del self.peers[public_key]
        return OperationResult.SUCCESS
