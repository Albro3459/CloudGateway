import ipaddress
import json
import logging
import time
import urllib.request
from typing import Any, Protocol

from .enums import Event
from .logs import log_event, setup_logging
from .notifications import create_ses_client, send_deployment_email
from .repository import FirebaseRepository, RegionDoc, RegionRegistration
from .settings import Settings

logger = logging.getLogger("src.register")

# IPv4-only echo services so we record the server's public IPv4, never a v6 address.
_IP_ECHO_URLS = ("https://ipv4.icanhazip.com", "https://api.ipify.org")
_HTTP_USER_AGENT = "CloudGateway-Register/1.0"


class SesClientFactory(Protocol):
    def __call__(self, settings: Settings) -> Any:
        """Build an SES client from settings (raises if SES is not configured)."""
        ...


class DeploymentEmailSender(Protocol):
    def __call__(
        self,
        ses_client: Any,
        *,
        sender: str,
        recipient: str,
        region: RegionDoc,
        settings: Settings,
        public_ipv4: str,
    ) -> str:
        """Send one deployment email and return the provider message ID."""
        ...


def _http_get(url: str, timeout: float = 10.0) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": _HTTP_USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 - fixed https hosts
        return response.read().decode("utf-8").strip()


def discover_public_ipv4() -> str:
    for url in _IP_ECHO_URLS:
        try:
            value = _http_get(url)
            ipaddress.IPv4Address(value)
            return value
        except Exception as exc:
            logger.warning("public IPv4 echo failed for %s: %s", url, exc)
            continue
    raise RuntimeError("could not determine public IPv4 from any echo service")


def health_ok(url: str, *, region_id: str, timeout: float = 5.0) -> bool:
    try:
        body = _http_get(url, timeout=timeout)
        data = json.loads(body)
    except Exception as exc:
        logger.info("health check failed for %s: %s", url, exc)
        return False
    return data.get("status") == "ok" and data.get("regionId") == region_id


def edge_ready(api_hostname: str, *, region_id: str, attempts: int = 6, delay: float = 5.0) -> bool:
    """Validate the full Cloudflare path: DNS -> proxy -> AOP -> origin firewall -> Caddy -> API.

    The host hairpins (host -> Cloudflare -> host), so a pass proves the edge is configured,
    not just that uvicorn answers on loopback. Retries absorb DNS/edge propagation right after
    a fresh apply.
    """
    url = f"https://{api_hostname}/api/health"
    for attempt in range(1, attempts + 1):
        if health_ok(url, region_id=region_id):
            return True
        if attempt < attempts:
            time.sleep(delay)
    return False


def build_registration(settings: Settings, public_ipv4: str) -> RegionRegistration:
    return RegionRegistration(
        region_id=settings.region_id,
        display_name=settings.region_display_name,
        display_order=settings.region_display_order,
        capacity_limit=settings.region_capacity_limit,
        user_client_limit=settings.region_user_client_limit,
        wireguard_endpoint_ipv4=public_ipv4,
        # wireguardEndpointIpv6 is the server's public IPv6 used as a *connection endpoint*.
        # Clients connect over the grey-cloud IPv4 hostname, so it is unused and host-owned
        # (always None here). This does NOT affect IPv6 traffic *inside* the tunnel: clients
        # still route IPv6 through wg0 (tunnel v6 addresses + AllowedIPs ::/0, NAT'd out).
        wireguard_endpoint_ipv6=None,
        wireguard_endpoint_hostname=settings.wg_endpoint_hostname,
        wireguard_port=settings.wg_port,
        wireguard_dns_ipv4=settings.wg_dns_ipv4,
        wireguard_dns_ipv6=settings.wg_dns_ipv6,
        wireguard_public_key=settings.wg_server_public_key,
    )


def run_register(
    *, repository: FirebaseRepository, settings: Settings, public_ipv4: str, ready: bool
) -> RegionDoc:
    registration = build_registration(settings, public_ipv4)
    return repository.upsert_region(registration, set_enabled=ready)


def notify_region_deployment(
    *,
    repository: FirebaseRepository,
    settings: Settings,
    region: RegionDoc,
    public_ipv4: str,
    create_client: SesClientFactory = create_ses_client,
    send_email: DeploymentEmailSender = send_deployment_email,
) -> int:
    if not region.enabled:
        return 0

    try:
        recipients = repository.list_admin_emails()
    except Exception as exc:
        log_event(
            logger,
            Event.REGION_DEPLOYMENT_EMAIL_FAILED,
            level=logging.ERROR,
            region_id=region.region_id,
            exc_info=(type(exc), exc, exc.__traceback__),
        )
        return 0

    if not recipients:
        log_event(
            logger,
            Event.REGION_DEPLOYMENT_EMAIL_COMPLETED,
            region_id=region.region_id,
            recipient_count=0,
            sent_count=0,
        )
        return 0

    # Build the SES client once and reuse it for every recipient. A build failure
    # (missing/invalid SES config) is logged once and never blocks registration.
    try:
        ses_client = create_client(settings)
    except Exception as exc:
        log_event(
            logger,
            Event.REGION_DEPLOYMENT_EMAIL_FAILED,
            level=logging.ERROR,
            region_id=region.region_id,
            exc_info=(type(exc), exc, exc.__traceback__),
        )
        return 0

    sent_count = 0
    for recipient in recipients:
        try:
            send_email(
                ses_client,
                sender=settings.ses_sender,
                recipient=recipient,
                region=region,
                settings=settings,
                public_ipv4=public_ipv4,
            )
            sent_count += 1
        except Exception as exc:
            log_event(
                logger,
                Event.REGION_DEPLOYMENT_EMAIL_FAILED,
                level=logging.ERROR,
                region_id=region.region_id,
                recipient_email=recipient,
                exc_info=(type(exc), exc, exc.__traceback__),
            )

    log_event(
        logger,
        Event.REGION_DEPLOYMENT_EMAIL_COMPLETED,
        region_id=region.region_id,
        recipient_count=len(recipients),
        sent_count=sent_count,
    )
    return sent_count


def main() -> int:
    setup_logging()
    settings = Settings()
    log_event(logger, Event.REGION_REGISTER_STARTED, region_id=settings.region_id)

    try:
        public_ipv4 = discover_public_ipv4()

        # Enable only when the whole Cloudflare path works, not just loopback. When the edge
        # check fails, probe loopback to tell an edge/firewall/AOP misconfig from a dead API.
        ready = bool(settings.api_hostname) and edge_ready(
            settings.api_hostname, region_id=settings.region_id
        )
        if not ready:
            local_ok = health_ok(
                f"http://127.0.0.1:{settings.api_port}/health", region_id=settings.region_id
            )
            if local_ok:
                logger.error(
                    "Region %s: API answers locally but the Cloudflare path failed; check "
                    "DNS / Origin cert / Authenticated Origin Pulls / firewall. Leaving disabled.",
                    settings.region_id,
                )
            else:
                logger.error(
                    "Region %s: local API is not healthy; the API failed to start. Leaving disabled.",
                    settings.region_id,
                )

        from .firebase import FirestoreRepository

        repository = FirestoreRepository(settings)
        region = run_register(
            repository=repository, settings=settings, public_ipv4=public_ipv4, ready=ready
        )
    except Exception as exc:
        log_event(
            logger,
            Event.REGION_REGISTER_FAILED,
            level=logging.ERROR,
            region_id=settings.region_id,
            exc_info=(type(exc), exc, exc.__traceback__),
        )
        return 1

    log_event(
        logger,
        Event.REGION_REGISTER_COMPLETED,
        region_id=settings.region_id,
        enabled=region.enabled,
        public_ipv4=public_ipv4,
    )

    # Best-effort deployment email. Runs after the region is registered and the
    # success marker is logged so it can never roll back enablement or flip the
    # exit code, even on an unexpected failure.
    try:
        notify_region_deployment(
            repository=repository,
            settings=settings,
            region=region,
            public_ipv4=public_ipv4,
        )
    except Exception as exc:
        log_event(
            logger,
            Event.REGION_DEPLOYMENT_EMAIL_FAILED,
            level=logging.ERROR,
            region_id=settings.region_id,
            exc_info=(type(exc), exc, exc.__traceback__),
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
