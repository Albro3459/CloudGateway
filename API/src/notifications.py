import importlib
from datetime import datetime
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from typing import Any, cast
from zoneinfo import ZoneInfo

from .repository import RegionDoc
from .settings import Settings


def central_timestamp(now: datetime | None = None) -> str:
    central = ZoneInfo("America/Chicago")
    current = now.astimezone(central) if now is not None else datetime.now(central)
    tz_label = current.tzname()
    return current.strftime(f"%m/%d/%Y %a %I:%M %p ({tz_label})")


def build_deployment_email(
    *,
    sender: str,
    recipient: str,
    region: RegionDoc,
    settings: Settings,
    public_ipv4: str,
    now: datetime | None = None,
) -> MIMEMultipart:
    timestamp = central_timestamp(now)
    subject = f"VPN is live in {region.display_name}!"
    body_text = (
        f"Your VPN is live in: {region.display_name}\n\n"
        f"Region ID: {region.region_id}\n\n"
        f"IPv4: {public_ipv4}\n\n"
        f"API Hostname: {settings.api_hostname}\n\n"
        f"WireGuard Endpoint: {region.wireguard_endpoint_hostname}:{region.wireguard_port}\n\n"
        f"Timestamp: {timestamp}\n\n"
        f"Enjoy!"
    )

    msg = MIMEMultipart("mixed")
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = recipient
    msg.attach(MIMEText(body_text, "plain"))
    return msg


def build_access_grant_email(
    *,
    sender: str,
    recipient: str,
    dashboard_origin: str,
) -> MIMEMultipart:
    subject = "You now have access to CloudGateway"
    body_text = (
        "You now have access to CloudGateway.\n\n"
        f"Email: {recipient}\n\n"
        f"Website: {dashboard_origin}\n\n"
        "You can sign in with Google, or open the website and choose Reset password for this email."
    )

    msg = MIMEMultipart("mixed")
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = recipient
    msg.attach(MIMEText(body_text, "plain"))
    return msg


def create_ses_client(settings: Settings) -> Any:
    missing = [
        name
        for name, value in (
            ("CLOUDGATEWAY_SES_REGION", settings.ses_region),
            ("CLOUDGATEWAY_SES_SENDER", settings.ses_sender),
            ("CLOUDGATEWAY_AWS_ACCESS_KEY_ID", settings.aws_access_key_id),
            ("CLOUDGATEWAY_AWS_SECRET_ACCESS_KEY", settings.aws_secret_access_key),
        )
        if not value
    ]
    if missing:
        raise ValueError(f"Missing SES configuration: {', '.join(missing)}")

    boto3 = cast(Any, importlib.import_module("boto3"))
    return boto3.client(
        "sesv2",
        region_name=settings.ses_region,
        aws_access_key_id=settings.aws_access_key_id,
        aws_secret_access_key=settings.aws_secret_access_key,
    )


def send_deployment_email(
    ses_client: Any,
    *,
    sender: str,
    recipient: str,
    region: RegionDoc,
    settings: Settings,
    public_ipv4: str,
) -> str:
    msg = build_deployment_email(
        sender=sender,
        recipient=recipient,
        region=region,
        settings=settings,
        public_ipv4=public_ipv4,
    )
    response = ses_client.send_email(
        FromEmailAddress=sender,
        Destination={"ToAddresses": [recipient]},
        Content={"Raw": {"Data": msg.as_bytes()}},
    )
    return str(response.get("MessageId") or "")


def send_access_grant_email(
    ses_client: Any,
    *,
    sender: str,
    recipient: str,
    dashboard_origin: str,
) -> str:
    msg = build_access_grant_email(
        sender=sender,
        recipient=recipient,
        dashboard_origin=dashboard_origin,
    )
    response = ses_client.send_email(
        FromEmailAddress=sender,
        Destination={"ToAddresses": [recipient]},
        Content={"Raw": {"Data": msg.as_bytes()}},
    )
    return str(response.get("MessageId") or "")
