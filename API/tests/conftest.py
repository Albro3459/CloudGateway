from typing import Any

import pytest
from fastapi.testclient import TestClient

from src.app import create_app
from src.auth import AuthenticatedUser
from src.enums import Role
from src.settings import Settings

from .fakes import FakeRepository, FakeTokenVerifier, FakeWireGuardManager

REGION_ID = "us-test-1"


def make_settings(**overrides) -> Settings:
    values: dict[str, Any] = {
        "region_id": REGION_ID,
        "firebase_credentials_file": "/tmp/test-firebase-credentials.json",
        "wg_server_public_key": "server-public-key",
        "wg_endpoint_hostname": "wg.us-test-1.example.com",
        "wg_dns_ipv4": "10.0.0.1",
        "wg_dns_ipv6": "fd42:42:42::1",
        "wg_tunnel_ipv4_cidr": "10.0.0.0/24",
        "wg_tunnel_ipv6_cidr": "fd42:42:42::/64",
    }
    values.update(overrides)
    return Settings(**values)


@pytest.fixture
def settings() -> Settings:
    return make_settings()


@pytest.fixture
def repository() -> FakeRepository:
    return FakeRepository()


@pytest.fixture
def token_verifier() -> FakeTokenVerifier:
    verifier = FakeTokenVerifier()
    verifier.users["user-token"] = AuthenticatedUser(
        uid="user-1",
        email="user@example.com",
        display_name="User One",
    )
    verifier.users["admin-token"] = AuthenticatedUser(
        uid="admin-1",
        email="admin@example.com",
        display_name="Admin One",
    )
    return verifier


@pytest.fixture
def wireguard() -> FakeWireGuardManager:
    return FakeWireGuardManager()


@pytest.fixture
def client(settings, token_verifier, repository, wireguard) -> TestClient:
    repository.roles["user-1"] = Role.USER
    repository.roles["admin-1"] = Role.ADMIN
    app = create_app(
        settings=settings,
        token_verifier=token_verifier,
        repository=repository,
        wireguard=wireguard,
    )
    return TestClient(app, raise_server_exceptions=False)
