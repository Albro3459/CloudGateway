from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime

from .enums import ClientStatus, Role


@dataclass(frozen=True)
class RegionDoc:
    region_id: str
    display_name: str
    enabled: bool
    wireguard_endpoint_ipv4: str
    wireguard_endpoint_ipv6: str | None
    wireguard_port: int
    wireguard_dns_ipv4: str
    wireguard_dns_ipv6: str
    wireguard_public_key: str
    capacity_limit: int
    active_client_count: int
    display_order: int | None = None
    health_status: str | None = None
    updated_at: datetime | None = None


@dataclass(frozen=True)
class UserDoc:
    uid: str
    email: str
    display_name: str | None
    created_at: datetime | None = None
    disabled: bool = False


@dataclass(frozen=True)
class ClientDoc:
    client_id: str
    owner_uid: str
    owner_email: str
    owner_display_name: str | None
    client_name: str
    region_id: str
    status: ClientStatus
    assigned_tunnel_ipv4: str
    assigned_tunnel_ipv6: str
    server_endpoint_ipv4: str
    server_public_key: str
    client_public_key: str
    wireguard_config: str | None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    removed_at: datetime | None = None
    last_error_code: str | None = None
    last_error_message: str | None = None


class FirebaseRepository(ABC):
    @abstractmethod
    def get_role(self, uid: str) -> Role | None:
        """Return the role for a UID, or None when no role doc exists."""
