from cloudlaunch_api.enums import ClientStatus, Role
from cloudlaunch_api.models import (
    CreateClientRequest,
    CreateClientResponse,
    CreateUserRequest,
    CreateUserResponse,
    DeleteClientResponse,
)


def test_request_accepts_camel_case():
    request = CreateClientRequest.model_validate({"regionId": "us-test-1", "clientName": "Phone"})

    assert request.region_id == "us-test-1"
    assert request.client_name == "Phone"


def test_request_accepts_snake_case_internally():
    request = CreateClientRequest(region_id="us-test-1", client_name=" ")

    assert request.region_id == "us-test-1"
    assert request.client_name is None


def test_response_serializes_camel_case():
    response = CreateClientResponse(
        client_id="abc",
        region_id="us-test-1",
        client_name="Phone",
        status=ClientStatus.ACTIVE,
        assigned_tunnel_ipv4="10.0.0.2/32",
        assigned_tunnel_ipv6="fd42:42:42::2/128",
        server_endpoint_ipv4="1.2.3.4",
        server_endpoint_hostname="wg.us-test-1.example.com",
        wireguard_config="[Interface]",
    )

    assert response.model_dump(by_alias=True) == {
        "clientId": "abc",
        "regionId": "us-test-1",
        "clientName": "Phone",
        "status": "active",
        "assignedTunnelIpv4": "10.0.0.2/32",
        "assignedTunnelIpv6": "fd42:42:42::2/128",
        "serverEndpointIpv4": "1.2.3.4",
        "serverEndpointHostname": "wg.us-test-1.example.com",
        "wireguardConfig": "[Interface]",
    }


def test_delete_response_serializes_camel_case():
    response = DeleteClientResponse(
        user_id="uid",
        client_id="abc",
        region_id="us-test-1",
        status=ClientStatus.REMOVED,
    )

    assert response.model_dump(by_alias=True) == {
        "userId": "uid",
        "clientId": "abc",
        "regionId": "us-test-1",
        "status": "removed",
    }


def test_user_models_serialize_camel_case():
    request = CreateUserRequest.model_validate(
        {"email": "user@example.com", "displayName": " User "}
    )
    response = CreateUserResponse(user_id="uid", email=request.email, role=Role.USER)

    assert request.display_name == "User"
    assert response.model_dump(by_alias=True) == {
        "userId": "uid",
        "email": "user@example.com",
        "role": "user",
        "alreadyExisted": False,
    }
