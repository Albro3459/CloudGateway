from enum import Enum


class Role(str, Enum):
    USER = "user"
    ADMIN = "admin"


class ClientStatus(str, Enum):
    CREATING = "creating"
    ACTIVE = "active"
    FAILED = "failed"
    REMOVED = "removed"


class OperationResult(str, Enum):
    SUCCESS = "success"
    FAILED = "failed"
    NOOP = "noop"


class MeshPeerStatus(str, Enum):
    APPLIED = "applied"
    SKIPPED_OVERLAP = "skipped-overlap"
    SKIPPED_INCOMPLETE = "skipped-incomplete"


class MeshPeerReasonCode(str, Enum):
    MISSING_PUBLIC_KEY = "missing-public-key"
    INVALID_PUBLIC_KEY = "invalid-public-key"
    MISSING_ENDPOINT_HOSTNAME = "missing-endpoint-hostname"
    INVALID_ENDPOINT_HOSTNAME = "invalid-endpoint-hostname"
    INVALID_ENDPOINT_PORT = "invalid-endpoint-port"
    MISSING_NETWORK_V4 = "missing-network-v4"
    INVALID_NETWORK_V4 = "invalid-network-v4"
    MISSING_NETWORK_V6 = "missing-network-v6"
    INVALID_NETWORK_V6 = "invalid-network-v6"
    OUTSIDE_AGGREGATE = "outside-aggregate"
    DUPLICATE_PUBLIC_KEY = "duplicate-public-key"
    LOCAL_NETWORK_INVALID = "local-network-invalid"
    OVERLAP_LOCAL = "overlap-local"
    OVERLAP_CANDIDATE = "overlap-candidate"


class ErrorCode(str, Enum):
    AUTH_REQUIRED = "AUTH_REQUIRED"
    ADMIN_REQUIRED = "ADMIN_REQUIRED"
    USER_NOT_PROVISIONED = "USER_NOT_PROVISIONED"
    INVALID_REQUEST = "INVALID_REQUEST"
    REGION_DISABLED = "REGION_DISABLED"
    REGION_MISMATCH = "REGION_MISMATCH"
    LIMIT_REACHED = "LIMIT_REACHED"
    CAPACITY_REACHED = "CAPACITY_REACHED"
    CLIENT_NOT_FOUND = "CLIENT_NOT_FOUND"
    DUPLICATE_EMAIL = "DUPLICATE_EMAIL"
    ACCOUNT_DISABLED = "ACCOUNT_DISABLED"
    SYNC_IN_PROGRESS = "SYNC_IN_PROGRESS"
    WIREGUARD_APPLY_FAILED = "WIREGUARD_APPLY_FAILED"
    POLICY_APPLY_FAILED = "POLICY_APPLY_FAILED"
    FIREBASE_WRITE_FAILED = "FIREBASE_WRITE_FAILED"
    ROLE_DEFAULT_MISSING = "ROLE_DEFAULT_MISSING"
    INTERNAL_ERROR = "INTERNAL_ERROR"


class Event(str, Enum):
    REQUEST_RECEIVED = "request_received"
    REQUEST_COMPLETED = "request_completed"
    REQUEST_FAILED = "request_failed"
    USER_CREATE_STARTED = "user_create_started"
    USER_CREATE_FAILED = "user_create_failed"
    ACCOUNT_DELETE_STARTED = "account_delete_started"
    ACCOUNT_DELETE_COMPLETED = "account_delete_completed"
    ACCOUNT_DELETE_FAILED = "account_delete_failed"
    ACCOUNT_DELETE_PEER_UNREACHABLE = "account_delete_peer_unreachable"
    USER_ACCESS_EMAIL_COMPLETED = "user_access_email_completed"
    USER_ACCESS_EMAIL_FAILED = "user_access_email_failed"
    CLIENT_CREATE_STARTED = "client_create_started"
    CLIENT_CREATE_COMPLETED = "client_create_completed"
    CLIENT_CREATE_FAILED = "client_create_failed"
    CLIENT_DELETE_STARTED = "client_delete_started"
    CLIENT_DELETE_COMPLETED = "client_delete_completed"
    CLIENT_DELETE_FAILED = "client_delete_failed"
    WIREGUARD_APPLY_STARTED = "wireguard_apply_started"
    WIREGUARD_APPLY_COMPLETED = "wireguard_apply_completed"
    WIREGUARD_APPLY_FAILED = "wireguard_apply_failed"
    PEER_SYNC_STARTED = "peer_sync_started"
    PEER_SYNC_COMPLETED = "peer_sync_completed"
    PEER_SYNC_FAILED = "peer_sync_failed"
    PEER_SYNC_PARTIAL = "peer_sync_partial"
    PEER_SYNC_ENRICHMENT_FAILED = "peer_sync_enrichment_failed"
    REGION_REGISTER_STARTED = "region_register_started"
    REGION_REGISTER_COMPLETED = "region_register_completed"
    REGION_REGISTER_FAILED = "region_register_failed"
    REGION_DEPLOYMENT_EMAIL_COMPLETED = "region_deployment_email_completed"
    REGION_DEPLOYMENT_EMAIL_FAILED = "region_deployment_email_failed"
    MESH_PEER_SKIPPED = "mesh_peer_skipped"
    MESH_PEER_APPLY_FAILED = "mesh_peer_apply_failed"
    MESH_ROUTE_RECLAIMED = "mesh_route_reclaimed"
    MESH_STATUS_WRITE_FAILED = "mesh_status_write_failed"
    MESH_LOCAL_NETWORK_INVALID = "mesh_local_network_invalid"
    CLIENT_PEER_DEGRADED = "client_peer_degraded"
    POLICY_REFRESH_STARTED = "policy_refresh_started"
    POLICY_REFRESH_COMPLETED = "policy_refresh_completed"
    POLICY_REFRESH_FAILED = "policy_refresh_failed"
    POLICY_REFRESH_DISCARDED = "policy_refresh_discarded"
    POLICY_ROW_APPLY_FAILED = "policy_row_apply_failed"
    POLICY_STATUS_WRITE_FAILED = "policy_status_write_failed"
    POLICY_POKE_FAILED = "policy_poke_failed"
    POLICY_ROWS_SKIPPED = "policy_rows_skipped"
