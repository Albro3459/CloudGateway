from dataclasses import replace

from src.repository import RegionDoc

from .conftest import REGION_ID


def region(
    region_id: str = REGION_ID,
    *,
    display_name: str = "Test Region",
    enabled: bool = True,
    display_order: int | None = 1,
) -> RegionDoc:
    return RegionDoc(
        region_id=region_id,
        display_name=display_name,
        enabled=enabled,
        wireguard_endpoint_ipv4="203.0.113.10",
        wireguard_endpoint_ipv6="2001:db8::10",
        wireguard_port=51820,
        wireguard_dns_ipv4="10.0.0.1",
        wireguard_dns_ipv6="fd42:42:42::1",
        wireguard_public_key="server-public-key",
        capacity_limit=20,
        wireguard_endpoint_hostname=f"wg.{region_id}.example.com",
        display_order=display_order,
        health_status="healthy",
    )


def test_regions_is_unauthenticated_enabled_sorted_and_projected(client, repository):
    repository.regions["us-z-1"] = region("us-z-1", display_name="Zed", display_order=None)
    repository.regions["us-a-1"] = region("us-a-1", display_name="Alpha", display_order=2)
    repository.regions["us-disabled-1"] = replace(
        region("us-disabled-1", display_name="Disabled", display_order=1),
        enabled=False,
    )

    response = client.get("/regions")

    assert response.status_code == 200
    assert response.json() == {
        "regions": [
            {
                "regionId": "us-a-1",
                "displayName": "Alpha",
                "displayOrder": 2,
            },
            {
                "regionId": "us-z-1",
                "displayName": "Zed",
                "displayOrder": 1000,
            },
        ]
    }


def test_regions_empty_when_no_enabled_regions(client, repository):
    repository.regions[REGION_ID] = region(enabled=False)

    response = client.get("/regions")

    assert response.status_code == 200
    assert response.json() == {"regions": []}
