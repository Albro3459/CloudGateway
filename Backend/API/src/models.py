from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator
from pydantic.alias_generators import to_camel

from .enums import ClientStatus, ErrorCode, MeshPeerStatus, Role


class ApiModel(BaseModel):
    model_config = ConfigDict(
        alias_generator=to_camel,
        populate_by_name=True,
        use_enum_values=True,
    )


class HealthResponse(ApiModel):
    status: str = "ok"
    region_id: str


class RegionSummary(ApiModel):
    region_id: str
    display_name: str
    display_order: int


class RegionsResponse(ApiModel):
    regions: list[RegionSummary]


class CreateClientRequest(ApiModel):
    region_id: str = Field(min_length=1)
    client_name: str = Field(min_length=1, max_length=80)

    @field_validator("client_name")
    @classmethod
    def client_name_is_required(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("Client display name is required.")
        return value


class CreateClientResponse(ApiModel):
    client_id: str
    region_id: str
    client_name: str
    status: ClientStatus
    assigned_tunnel_ipv4: str
    assigned_tunnel_ipv6: str
    server_endpoint_ipv4: str
    server_endpoint_hostname: str
    wireguard_config: str


class DeleteClientRequest(ApiModel):
    user_id: str = Field(min_length=1)
    region_id: str = Field(min_length=1)


class DeleteClientResponse(ApiModel):
    user_id: str
    client_id: str
    region_id: str
    status: ClientStatus


class DeleteAccountResponse(ApiModel):
    user_id: str
    deleted_client_count: int


class CreateUserRequest(ApiModel):
    model_config = ConfigDict(
        alias_generator=to_camel,
        populate_by_name=True,
        use_enum_values=True,
        extra="forbid",
    )

    email: str = Field(min_length=1, max_length=320)

    @field_validator("email")
    @classmethod
    def email_must_be_present(cls, value: str) -> str:
        value = value.strip()
        if not value or "@" not in value:
            raise ValueError("Invalid email.")
        return value


class CreateUserResponse(ApiModel):
    user_id: str
    email: str
    role: Role
    already_existed: bool = False


class AccessCheckResponse(ApiModel):
    user_id: str
    email: str | None = None
    role: Role


class CapacityResponse(ApiModel):
    region_id: str
    capacity_limit: int
    allocated_client_count: int


class AdminSyncRequest(ApiModel):
    region_id: str = Field(min_length=1)


class AdminSyncMeshPeer(ApiModel):
    # Deliberately omits the peer public key; the durable Mesh/{regionId}
    # Firestore doc carries it. Server metadata only.
    region_id: str
    status: MeshPeerStatus
    endpoint_hostname: str = ""
    endpoint_port: int | None = None
    allowed_network_v4: str = ""
    allowed_network_v6: str = ""
    reason_code: str | None = None


class AdminSyncResponse(ApiModel):
    region_id: str
    synced_at: datetime
    added: int
    updated: int
    removed: int
    no_changes: bool
    log: str
    mesh_updated: int = 0
    mesh_enabled: bool
    mesh_applied: int
    mesh_added: int
    mesh_removed: int
    mesh_skipped: int
    mesh_routes_added: int
    mesh_routes_removed: int
    mesh_peers: list[AdminSyncMeshPeer]


class ErrorDetail(ApiModel):
    code: ErrorCode
    message: str
    request_id: str


class ErrorResponse(ApiModel):
    error: ErrorDetail
