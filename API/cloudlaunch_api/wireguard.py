from abc import ABC, abstractmethod
from dataclasses import dataclass

from .enums import OperationResult
from .errors import WireGuardApplyFailedError


@dataclass(frozen=True)
class WireGuardKeypair:
    private_key: str
    public_key: str


class WireGuardManager(ABC):
    @abstractmethod
    def generate_keypair(self) -> WireGuardKeypair:
        """Generate a fresh WireGuard keypair."""

    @abstractmethod
    def add_peer(
        self,
        *,
        client_id: str,
        public_key: str,
        tunnel_ipv4: str,
        tunnel_ipv6: str,
    ) -> None:
        """Add a peer to the persistent config and live interface."""

    @abstractmethod
    def remove_peer(self, *, client_id: str, public_key: str) -> OperationResult:
        """Remove a peer. An already-absent peer returns NOOP."""


class UnavailableWireGuardManager(WireGuardManager):
    def generate_keypair(self) -> WireGuardKeypair:
        raise WireGuardApplyFailedError("WireGuard manager is not implemented yet.")

    def add_peer(
        self,
        *,
        client_id: str,
        public_key: str,
        tunnel_ipv4: str,
        tunnel_ipv6: str,
    ) -> None:
        raise WireGuardApplyFailedError("WireGuard manager is not implemented yet.")

    def remove_peer(self, *, client_id: str, public_key: str) -> OperationResult:
        raise WireGuardApplyFailedError("WireGuard manager is not implemented yet.")
