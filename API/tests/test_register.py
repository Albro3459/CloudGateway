from dataclasses import replace

import src.register as register
from src.enums import Role
from src.register import build_registration, notify_region_deployment, run_register
from src.repository import RegionDoc, UserDoc
from src.settings import Settings

from .fakes import FakeRepository

REGION_ID = "us-test-1"


def _settings() -> Settings:
    return Settings(
        region_id=REGION_ID,
        api_hostname="us-test-1.example.com",
        region_display_name="Test Region",
        region_display_order=5,
        region_capacity_limit=22,
        region_user_client_limit=4,
        wg_endpoint_hostname="wg.us-test-1.example.com",
        wg_port=51820,
        wg_dns_ipv4="10.0.0.1",
        wg_dns_ipv6="fd42:42:42::1",
        wg_server_public_key="server-pub-key",
    )


_SES_CLIENT = object()


def _fake_client_factory(settings: Settings) -> object:
    return _SES_CLIENT


class RecordingDeploymentEmailSender:
    def __init__(self, error: Exception | None = None):
        self.error = error
        self.calls: list[tuple[str, str, str]] = []
        self.clients: list[object] = []

    def __call__(
        self,
        ses_client: object,
        *,
        sender: str,
        recipient: str,
        region: RegionDoc,
        settings: Settings,
        public_ipv4: str,
    ) -> str:
        self.clients.append(ses_client)
        self.calls.append((recipient, region.region_id, public_ipv4))
        if self.error is not None:
            raise self.error
        return "message-1"


def test_build_registration_maps_settings():
    reg = build_registration(_settings(), "203.0.113.5")
    assert reg.region_id == REGION_ID
    assert reg.display_name == "Test Region"
    assert reg.display_order == 5
    assert reg.capacity_limit == 22
    assert reg.user_client_limit == 4
    assert reg.wireguard_endpoint_ipv4 == "203.0.113.5"
    assert reg.wireguard_public_key == "server-pub-key"
    assert reg.wireguard_endpoint_hostname == "wg.us-test-1.example.com"


def test_upsert_inserts_enabled_with_zero_count():
    repo = FakeRepository(local_region_id=REGION_ID)
    region = run_register(repository=repo, settings=_settings(), public_ipv4="203.0.113.5", ready=True)
    assert region.enabled is True
    assert region.active_client_count == 0
    assert region.wireguard_endpoint_ipv4 == "203.0.113.5"


def test_upsert_preserves_active_client_count_and_follows_ready():
    repo = FakeRepository(local_region_id=REGION_ID)
    run_register(repository=repo, settings=_settings(), public_ipv4="203.0.113.5", ready=True)
    repo.regions[REGION_ID] = replace(repo.regions[REGION_ID], active_client_count=7)

    region = run_register(repository=repo, settings=_settings(), public_ipv4="198.51.100.9", ready=False)
    assert region.active_client_count == 7
    assert region.enabled is False
    assert region.wireguard_endpoint_ipv4 == "198.51.100.9"


def test_notify_region_deployment_sends_to_admin_emails():
    repo = FakeRepository(local_region_id=REGION_ID)
    repo.roles["admin-1"] = Role.ADMIN
    repo.roles["admin-2"] = Role.ADMIN
    repo.users["admin-1"] = UserDoc(uid="admin-1", email="admin1@example.com")
    repo.users["admin-2"] = UserDoc(uid="admin-2", email="admin2@example.com")
    region = run_register(repository=repo, settings=_settings(), public_ipv4="203.0.113.5", ready=True)
    sender = RecordingDeploymentEmailSender()

    sent_count = notify_region_deployment(
        repository=repo,
        settings=_settings(),
        region=region,
        public_ipv4="203.0.113.5",
        create_client=_fake_client_factory,
        send_email=sender,
    )

    assert sent_count == 2
    assert sorted(r for r, _, _ in sender.calls) == ["admin1@example.com", "admin2@example.com"]
    # SES client is built once and reused for every recipient.
    assert sender.clients == [_SES_CLIENT, _SES_CLIENT]


def test_notify_region_deployment_skips_disabled_region():
    repo = FakeRepository(local_region_id=REGION_ID)
    repo.roles["admin-1"] = Role.ADMIN
    repo.users["admin-1"] = UserDoc(uid="admin-1", email="admin@example.com")
    region = run_register(repository=repo, settings=_settings(), public_ipv4="203.0.113.5", ready=False)
    sender = RecordingDeploymentEmailSender()

    sent_count = notify_region_deployment(
        repository=repo,
        settings=_settings(),
        region=region,
        public_ipv4="203.0.113.5",
        create_client=_fake_client_factory,
        send_email=sender,
    )

    assert sent_count == 0
    assert sender.calls == []


def test_notify_region_deployment_logs_ses_failure_without_failing(caplog):
    repo = FakeRepository(local_region_id=REGION_ID)
    repo.roles["admin-1"] = Role.ADMIN
    repo.users["admin-1"] = UserDoc(uid="admin-1", email="admin@example.com")
    region = run_register(repository=repo, settings=_settings(), public_ipv4="203.0.113.5", ready=True)
    sender = RecordingDeploymentEmailSender(error=RuntimeError("ses send failed"))

    with caplog.at_level("ERROR", logger="src.register"):
        sent_count = notify_region_deployment(
            repository=repo,
            settings=_settings(),
            region=region,
            public_ipv4="203.0.113.5",
            create_client=_fake_client_factory,
            send_email=sender,
        )

    assert sent_count == 0
    assert sender.calls == [("admin@example.com", REGION_ID, "203.0.113.5")]
    assert "region_deployment_email_failed" in caplog.text


def test_notify_region_deployment_logs_client_build_failure_without_sending(caplog):
    repo = FakeRepository(local_region_id=REGION_ID)
    repo.roles["admin-1"] = Role.ADMIN
    repo.users["admin-1"] = UserDoc(uid="admin-1", email="admin@example.com")
    region = run_register(repository=repo, settings=_settings(), public_ipv4="203.0.113.5", ready=True)
    sender = RecordingDeploymentEmailSender()

    def failing_factory(settings: Settings) -> object:
        raise ValueError("Missing SES configuration")

    with caplog.at_level("ERROR", logger="src.register"):
        sent_count = notify_region_deployment(
            repository=repo,
            settings=_settings(),
            region=region,
            public_ipv4="203.0.113.5",
            create_client=failing_factory,
            send_email=sender,
        )

    assert sent_count == 0
    assert sender.calls == []
    assert "region_deployment_email_failed" in caplog.text


def test_health_ok_parsing(monkeypatch):
    monkeypatch.setattr(register, "_http_get", lambda url, timeout=5.0: f'{{"status":"ok","regionId":"{REGION_ID}"}}')
    assert register.health_ok("http://x/health", region_id=REGION_ID) is True

    monkeypatch.setattr(register, "_http_get", lambda url, timeout=5.0: '{"status":"ok","regionId":"other"}')
    assert register.health_ok("http://x/health", region_id=REGION_ID) is False


def test_edge_ready(monkeypatch):
    monkeypatch.setattr(register, "health_ok", lambda url, *, region_id, timeout=5.0: True)
    assert register.edge_ready("us-test-1.example.com", region_id=REGION_ID, attempts=1, delay=0) is True

    monkeypatch.setattr(register, "health_ok", lambda url, *, region_id, timeout=5.0: False)
    assert register.edge_ready("us-test-1.example.com", region_id=REGION_ID, attempts=3, delay=0) is False


def test_discover_public_ipv4(monkeypatch):
    monkeypatch.setattr(register, "_http_get", lambda url, timeout=10.0: "203.0.113.42")
    assert register.discover_public_ipv4() == "203.0.113.42"
