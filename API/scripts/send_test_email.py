"""Send a one-off SES deployment email to verify credentials before deploying.

Run from the API/ directory with the project venv, e.g.:

  .venv/bin/python scripts/send_test_email.py \
      --to you@example.com \
      --ses-region us-east-1 \
      --sender 'CloudGateway <noreply@gocloudlaunch.com>'

AWS credentials are read from CLOUDGATEWAY_AWS_ACCESS_KEY_ID /
CLOUDGATEWAY_AWS_SECRET_ACCESS_KEY, falling back to the standard
AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY environment variables. This mirrors
exactly what cloudgateway-register-region sends on a successful deployment.
"""

import argparse
import os
import sys

from src.notifications import create_ses_client, send_deployment_email
from src.repository import RegionDoc
from src.settings import Settings


def _sample_region(settings: Settings) -> RegionDoc:
    return RegionDoc(
        region_id=settings.region_id,
        display_name=settings.region_display_name,
        enabled=True,
        wireguard_endpoint_ipv4="203.0.113.10",
        wireguard_endpoint_ipv6=None,
        wireguard_port=settings.wg_port,
        wireguard_dns_ipv4=settings.wg_dns_ipv4,
        wireguard_dns_ipv6=settings.wg_dns_ipv6,
        wireguard_public_key=settings.wg_server_public_key,
        capacity_limit=settings.region_capacity_limit,
        active_client_count=0,
        wireguard_endpoint_hostname=settings.wg_endpoint_hostname,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Send a test SES deployment email.")
    parser.add_argument("--to", required=True, help="Recipient email address")
    parser.add_argument(
        "--ses-region",
        default=os.environ.get("CLOUDGATEWAY_SES_REGION") or os.environ.get("AWS_REGION", ""),
        help="AWS SES region (default: CLOUDGATEWAY_SES_REGION / AWS_REGION)",
    )
    parser.add_argument(
        "--sender",
        default=os.environ.get("CLOUDGATEWAY_SES_SENDER", ""),
        help="Verified SES sender identity (default: CLOUDGATEWAY_SES_SENDER)",
    )
    parser.add_argument("--public-ipv4", default="203.0.113.10")
    args = parser.parse_args()

    access_key = os.environ.get("CLOUDGATEWAY_AWS_ACCESS_KEY_ID") or os.environ.get(
        "AWS_ACCESS_KEY_ID", ""
    )
    secret_key = os.environ.get("CLOUDGATEWAY_AWS_SECRET_ACCESS_KEY") or os.environ.get(
        "AWS_SECRET_ACCESS_KEY", ""
    )

    settings = Settings(
        ses_region=args.ses_region,
        ses_sender=args.sender,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
    )

    if not settings.ses_sender:
        print("error: --sender (or CLOUDGATEWAY_SES_SENDER) is required", file=sys.stderr)
        return 2

    ses_client = create_ses_client(settings)
    message_id = send_deployment_email(
        ses_client,
        sender=settings.ses_sender,
        recipient=args.to,
        region=_sample_region(settings),
        settings=settings,
        public_ipv4=args.public_ipv4,
    )
    print(f"Sent test deployment email to {args.to} (MessageId={message_id})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
