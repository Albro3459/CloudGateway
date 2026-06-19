from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from typing import Any, cast

from src.notifications import send_access_grant_email, send_deployment_email
from src.repository import RegionDoc
from src.settings import Settings


class FakeSesClient:
    def __init__(self):
        self.calls: list[dict[str, Any]] = []

    def send_email(self, **kwargs) -> dict[str, str]:
        self.calls.append(kwargs)
        return {"MessageId": "message-1"}


def region_doc() -> RegionDoc:
    return RegionDoc(
        region_id="us-test-1",
        display_name="Test Region",
        enabled=True,
        wireguard_endpoint_ipv4="203.0.113.10",
        wireguard_endpoint_ipv6=None,
        wireguard_port=51820,
        wireguard_dns_ipv4="10.0.0.1",
        wireguard_dns_ipv6="fd42:42:42::1",
        wireguard_public_key="server-public-key",
        capacity_limit=20,
        active_client_count=0,
        wireguard_endpoint_hostname="wg.us-test-1.example.com",
    )


def test_send_deployment_email_uses_sesv2_raw_mime_shape():
    ses_client = FakeSesClient()
    settings = Settings(api_hostname="us-test-1.example.com")

    message_id = send_deployment_email(
        ses_client,
        sender="CloudGateway <noreply@example.com>",
        recipient="admin@example.com",
        region=region_doc(),
        settings=settings,
        public_ipv4="203.0.113.10",
    )

    assert message_id == "message-1"
    assert len(ses_client.calls) == 1
    call = ses_client.calls[0]
    assert call["FromEmailAddress"] == "CloudGateway <noreply@example.com>"
    assert call["Destination"] == {"ToAddresses": ["admin@example.com"]}
    raw = call["Content"]["Raw"]["Data"]
    assert isinstance(raw, bytes)
    parsed = cast(EmailMessage, BytesParser(policy=policy.default).parsebytes(raw))
    body_part = parsed.get_body(preferencelist=("plain"))
    assert body_part is not None
    body = body_part.get_content()
    assert parsed["Subject"] == "VPN is live in Test Region!"
    assert parsed["From"] == "CloudGateway <noreply@example.com>"
    assert parsed["To"] == "admin@example.com"
    assert "Your VPN is live in: Test Region" in body
    assert "Region ID: us-test-1" in body
    assert "IPv4: 203.0.113.10" in body
    assert "API Hostname: us-test-1.example.com" in body
    assert "WireGuard Endpoint: wg.us-test-1.example.com:51820" in body
    assert "Timestamp:" in body


def test_send_access_grant_email_uses_sesv2_raw_mime_shape():
    ses_client = FakeSesClient()

    message_id = send_access_grant_email(
        ses_client,
        sender="CloudGateway <noreply@example.com>",
        recipient="new.user@example.com",
        dashboard_origin="https://gocloudlaunch.com",
    )

    assert message_id == "message-1"
    assert len(ses_client.calls) == 1
    call = ses_client.calls[0]
    assert call["FromEmailAddress"] == "CloudGateway <noreply@example.com>"
    assert call["Destination"] == {"ToAddresses": ["new.user@example.com"]}
    raw = call["Content"]["Raw"]["Data"]
    assert isinstance(raw, bytes)
    parsed = cast(EmailMessage, BytesParser(policy=policy.default).parsebytes(raw))
    body_part = parsed.get_body(preferencelist=("plain"))
    assert body_part is not None
    body = body_part.get_content()
    assert parsed["Subject"] == "You now have access to CloudGateway"
    assert parsed["From"] == "CloudGateway <noreply@example.com>"
    assert parsed["To"] == "new.user@example.com"
    assert "You now have access to CloudGateway." in body
    assert "Email: new.user@example.com" in body
    assert "Website: https://gocloudlaunch.com" in body
    assert "choose Reset password for this email" in body
