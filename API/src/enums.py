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
    WIREGUARD_APPLY_FAILED = "WIREGUARD_APPLY_FAILED"
    FIREBASE_WRITE_FAILED = "FIREBASE_WRITE_FAILED"
    INTERNAL_ERROR = "INTERNAL_ERROR"


class Event(str, Enum):
    REQUEST_RECEIVED = "request_received"
    REQUEST_COMPLETED = "request_completed"
    REQUEST_FAILED = "request_failed"
    USER_CREATE_STARTED = "user_create_started"
    USER_CREATE_FAILED = "user_create_failed"
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
    REGION_REGISTER_STARTED = "region_register_started"
    REGION_REGISTER_COMPLETED = "region_register_completed"
    REGION_REGISTER_FAILED = "region_register_failed"
    REGION_DEPLOYMENT_EMAIL_COMPLETED = "region_deployment_email_completed"
    REGION_DEPLOYMENT_EMAIL_FAILED = "region_deployment_email_failed"
