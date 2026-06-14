from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="CLOUDLAUNCH_", extra="ignore")

    region_id: str = "local-region"
    api_port: int = 8000
    api_hostname: str = ""
    firebase_credentials_file: str = "/tmp/cloudlaunch-firebase-credentials.json"
    wg_interface: str = "wg0"
    wg_server_public_key: str = "local-server-public-key"
    wg_endpoint_hostname: str = "127.0.0.1"
    wg_port: int = 51820
    wg_dns_ipv4: str = "1.1.1.1"
    wg_dns_ipv6: str = "2606:4700:4700::1111"
    wg_tunnel_ipv4_cidr: str = "10.0.0.0/24"
    wg_tunnel_ipv6_cidr: str = "fd42:42:42::/64"

    # Region-doc metadata used by cloudlaunch-register-region to self-seed Firestore.
    region_display_name: str = "local-region"
    region_display_order: int = 1000
    region_capacity_limit: int = 20
    region_user_client_limit: int = 3


@lru_cache
def get_settings() -> Settings:
    return Settings()
