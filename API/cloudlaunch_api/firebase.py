import threading
from dataclasses import replace
from typing import Any

from .auth import AuthenticatedUser, TokenVerifier
from .enums import ClientStatus, Role
from .errors import (
    AuthRequiredError,
    ClientNotFoundError,
    DuplicateEmailError,
    FirebaseWriteFailedError,
    InvalidPasswordError,
    InvalidRequestError,
)
from .repository import (
    ALLOCATED_CLIENT_STATUSES,
    ClientDoc,
    FirebaseRepository,
    RegionDoc,
    UserDoc,
    assert_capacity_available,
    assert_user_limit_available,
    assign_tunnel_ips,
    clean_client_name,
    ensure_delete_allowed,
    ensure_local_region,
    ensure_region_enabled,
    new_client_id,
    require_region,
    role_or_user,
    utc_now,
)
from .settings import Settings

_init_lock = threading.Lock()


def _transactional():
    from google.cloud.firestore_v1 import transactional

    return transactional


def _firebase_app(settings: Settings):
    import firebase_admin
    from firebase_admin import credentials

    with _init_lock:
        if not firebase_admin._apps:
            cred = credentials.Certificate(settings.firebase_credentials_file)
            firebase_admin.initialize_app(cred)
        return firebase_admin.get_app()


class FirebaseTokenVerifier(TokenVerifier):
    def __init__(self, settings: Settings):
        self._settings = settings

    def verify_token(self, token: str) -> AuthenticatedUser:
        from firebase_admin import auth

        _firebase_app(self._settings)
        try:
            decoded = auth.verify_id_token(token)
        except Exception as exc:
            raise AuthRequiredError("Invalid or expired token.") from exc
        uid = decoded.get("uid")
        if not uid:
            raise AuthRequiredError("Invalid or expired token.")
        return AuthenticatedUser(
            uid=uid,
            email=decoded.get("email"),
            display_name=decoded.get("name"),
        )


class FirestoreRepository(FirebaseRepository):
    def __init__(self, settings: Settings):
        self._settings = settings

    def _db(self):
        from firebase_admin import firestore

        _firebase_app(self._settings)
        return firestore.client()

    def get_role(self, uid: str) -> Role | None:
        doc = self._db().collection("Roles").document(uid).get()
        if not doc.exists:
            return None
        return _role_from_data(doc.to_dict() or {})

    def get_user(self, uid: str) -> UserDoc | None:
        doc = self._db().collection("Users").document(uid).get()
        if not doc.exists:
            return None
        return _user_from_data(doc.to_dict() or {}, uid)

    def get_region(self, region_id: str) -> RegionDoc | None:
        doc = self._db().collection("Regions").document(region_id).get()
        if not doc.exists:
            return None
        return _region_from_data(doc.to_dict() or {}, region_id)

    def get_client(self, *, owner_uid: str, region_id: str, client_id: str) -> ClientDoc | None:
        doc = _client_ref(self._db(), owner_uid, region_id, client_id).get()
        if not doc.exists:
            return None
        return _client_from_data(doc.to_dict() or {}, client_id)

    def list_active_clients(self, region_id: str) -> list[ClientDoc]:
        snapshots = self._db().collection_group("Instances").where("regionId", "==", region_id).stream()
        clients = []
        for snapshot in snapshots:
            try:
                client = _client_from_data(snapshot.to_dict() or {}, snapshot.id)
            except ValueError:
                continue
            if client.status == ClientStatus.ACTIVE and client.client_public_key:
                clients.append(client)
        return clients

    def create_user(self, *, email: str, password: str, display_name: str | None) -> UserDoc:
        from firebase_admin import auth, firestore

        _firebase_app(self._settings)
        try:
            auth_data = {"email": email, "password": password}
            if display_name is not None:
                auth_data["display_name"] = display_name
            auth_user = auth.create_user(**auth_data)
        except Exception as exc:
            if _exception_is_named(exc, "EmailAlreadyExistsError"):
                raise DuplicateEmailError() from exc
            if _exception_is_named(exc, "InvalidPasswordError"):
                raise InvalidPasswordError() from exc
            if isinstance(exc, ValueError):
                raise InvalidRequestError() from exc
            raise FirebaseWriteFailedError() from exc

        uid = auth_user.uid
        now = utc_now()
        try:
            db = self._db()
            batch = db.batch()
            batch.set(
                db.collection("Users").document(uid),
                {
                    "uid": uid,
                    "email": auth_user.email or email,
                    "displayName": display_name,
                    "createdAt": firestore.SERVER_TIMESTAMP,
                },
            )
            batch.set(
                db.collection("Roles").document(uid),
                {
                    "role": Role.USER.value,
                    "updatedAt": firestore.SERVER_TIMESTAMP,
                },
            )
            batch.commit()
        except Exception as exc:
            # Roll back the auth account so a retry does not hit duplicate email
            try:
                auth.delete_user(uid)
            except Exception:
                pass
            raise FirebaseWriteFailedError() from exc

        return UserDoc(uid=uid, email=auth_user.email or email, display_name=display_name, created_at=now)

    def reserve_client(
        self,
        *,
        owner_uid: str,
        owner_email: str | None,
        owner_display_name: str | None,
        region_id: str,
        client_name: str | None,
    ) -> ClientDoc:
        ensure_local_region(region_id, self._settings.region_id)
        db = self._db()

        from firebase_admin import firestore

        @_transactional()
        def reserve(transaction):
            role_ref = db.collection("Roles").document(owner_uid)
            user_ref = db.collection("Users").document(owner_uid)
            region_ref = db.collection("Regions").document(region_id)

            role = role_or_user(_role_from_snapshot(role_ref.get(transaction=transaction)))
            user_snapshot = user_ref.get(transaction=transaction)
            region = ensure_region_enabled(_region_from_snapshot(region_ref.get(transaction=transaction), region_id))
            allocated_clients = _allocated_region_clients(db, transaction, region_id)
            owner_allocated_count = sum(1 for client in allocated_clients if client.owner_uid == owner_uid)

            assert_capacity_available(allocated_count=len(allocated_clients), capacity_limit=region.capacity_limit)
            assert_user_limit_available(requester_role=role, owner_allocated_count=owner_allocated_count)

            used_ipv4 = {client.assigned_tunnel_ipv4 for client in allocated_clients}
            used_ipv6 = {client.assigned_tunnel_ipv6 for client in allocated_clients}
            assigned_ipv4, assigned_ipv6 = assign_tunnel_ips(
                ipv4_cidr=self._settings.wg_tunnel_ipv4_cidr,
                ipv6_cidr=self._settings.wg_tunnel_ipv6_cidr,
                used_ipv4=used_ipv4,
                used_ipv6=used_ipv6,
            )

            client_id, client_ref = _new_client_ref(db, transaction, owner_uid, region_id)
            now = utc_now()
            user_data = _user_write_data(
                uid=owner_uid,
                email=owner_email,
                display_name=owner_display_name,
                exists=user_snapshot.exists,
            )
            client_data = _client_write_data(
                client_id=client_id,
                owner_uid=owner_uid,
                owner_email=owner_email,
                owner_display_name=owner_display_name,
                client_name=client_name,
                region=region,
                assigned_tunnel_ipv4=assigned_ipv4,
                assigned_tunnel_ipv6=assigned_ipv6,
            )

            transaction.set(user_ref, user_data, merge=True)
            transaction.set(client_ref, client_data)
            transaction.update(
                region_ref,
                {
                    "activeClientCount": len(allocated_clients) + 1,
                    "updatedAt": firestore.SERVER_TIMESTAMP,
                },
            )
            return _client_from_data(client_data, client_id, now=now)

        return reserve(db.transaction())

    def mark_client_active(
        self,
        *,
        owner_uid: str,
        region_id: str,
        client_id: str,
        client_public_key: str,
        wireguard_config: str,
    ) -> ClientDoc:
        ensure_local_region(region_id, self._settings.region_id)
        db = self._db()

        from firebase_admin import firestore

        @_transactional()
        def activate(transaction):
            client_ref = _client_ref(db, owner_uid, region_id, client_id)
            snapshot = client_ref.get(transaction=transaction)
            client = _require_client(snapshot, client_id, owner_uid=owner_uid, region_id=region_id)
            if client.status not in {ClientStatus.CREATING, ClientStatus.ACTIVE}:
                raise ClientNotFoundError()

            now = utc_now()
            updates = {
                "status": ClientStatus.ACTIVE.value,
                "clientPublicKey": client_public_key,
                "wireguardConfig": wireguard_config,
                "updatedAt": firestore.SERVER_TIMESTAMP,
                "removedAt": None,
                "lastErrorCode": None,
                "lastErrorMessage": None,
            }
            transaction.update(client_ref, updates)
            return replace(
                client,
                status=ClientStatus.ACTIVE,
                client_public_key=client_public_key,
                wireguard_config=wireguard_config,
                updated_at=now,
                removed_at=None,
                last_error_code=None,
                last_error_message=None,
            )

        return activate(db.transaction())

    def mark_client_failed(
        self,
        *,
        owner_uid: str,
        region_id: str,
        client_id: str,
        error_code: str,
        error_message: str,
    ) -> ClientDoc:
        return self._mark_client_terminal(
            owner_uid=owner_uid,
            region_id=region_id,
            client_id=client_id,
            status=ClientStatus.FAILED,
            error_code=error_code,
            error_message=error_message,
        )

    def remove_client_reservation(
        self,
        *,
        owner_uid: str,
        region_id: str,
        client_id: str,
        error_code: str | None = None,
        error_message: str | None = None,
    ) -> ClientDoc:
        return self._mark_client_terminal(
            owner_uid=owner_uid,
            region_id=region_id,
            client_id=client_id,
            status=ClientStatus.REMOVED,
            error_code=error_code,
            error_message=error_message,
        )

    def delete_client(
        self,
        *,
        requester_uid: str,
        target_uid: str,
        region_id: str,
        client_id: str,
    ) -> ClientDoc:
        ensure_local_region(region_id, self._settings.region_id)
        db = self._db()

        from firebase_admin import firestore

        @_transactional()
        def delete(transaction):
            role_ref = db.collection("Roles").document(requester_uid)
            region_ref = db.collection("Regions").document(region_id)
            client_ref = _client_ref(db, target_uid, region_id, client_id)

            role = _role_from_snapshot(role_ref.get(transaction=transaction))
            ensure_delete_allowed(requester_uid=requester_uid, requester_role=role, target_uid=target_uid)
            require_region(_region_from_snapshot(region_ref.get(transaction=transaction), region_id))
            client = _require_client(
                client_ref.get(transaction=transaction),
                client_id,
                owner_uid=target_uid,
                region_id=region_id,
            )
            allocated_clients = _allocated_region_clients(db, transaction, region_id)
            return self._write_terminal_client(
                transaction=transaction,
                firestore=firestore,
                region_ref=region_ref,
                client_ref=client_ref,
                client=client,
                allocated_count=len(allocated_clients),
                status=ClientStatus.REMOVED,
                error_code=None,
                error_message=None,
            )

        return delete(db.transaction())

    def _mark_client_terminal(
        self,
        *,
        owner_uid: str,
        region_id: str,
        client_id: str,
        status: ClientStatus,
        error_code: str | None,
        error_message: str | None,
    ) -> ClientDoc:
        ensure_local_region(region_id, self._settings.region_id)
        db = self._db()

        from firebase_admin import firestore

        @_transactional()
        def mark_terminal(transaction):
            region_ref = db.collection("Regions").document(region_id)
            client_ref = _client_ref(db, owner_uid, region_id, client_id)
            require_region(_region_from_snapshot(region_ref.get(transaction=transaction), region_id))
            client = _require_client(
                client_ref.get(transaction=transaction),
                client_id,
                owner_uid=owner_uid,
                region_id=region_id,
            )
            allocated_clients = _allocated_region_clients(db, transaction, region_id)
            return self._write_terminal_client(
                transaction=transaction,
                firestore=firestore,
                region_ref=region_ref,
                client_ref=client_ref,
                client=client,
                allocated_count=len(allocated_clients),
                status=status,
                error_code=error_code,
                error_message=error_message,
            )

        return mark_terminal(db.transaction())

    def _write_terminal_client(
        self,
        *,
        transaction,
        firestore,
        region_ref,
        client_ref,
        client: ClientDoc,
        allocated_count: int,
        status: ClientStatus,
        error_code: str | None,
        error_message: str | None,
    ) -> ClientDoc:
        now = utc_now()
        was_allocated = client.status in ALLOCATED_CLIENT_STATUSES
        next_count = max(0, allocated_count - 1) if was_allocated else allocated_count
        removed_at = now if status == ClientStatus.REMOVED else None
        updates = {
            "status": status.value,
            "updatedAt": firestore.SERVER_TIMESTAMP,
            "removedAt": firestore.SERVER_TIMESTAMP if removed_at is not None else None,
            "wireguardConfig": None if status == ClientStatus.REMOVED else client.wireguard_config,
            "lastErrorCode": error_code,
            "lastErrorMessage": error_message,
        }
        transaction.update(client_ref, updates)
        transaction.update(
            region_ref,
            {
                "activeClientCount": next_count,
                "updatedAt": firestore.SERVER_TIMESTAMP,
            },
        )
        return replace(
            client,
            status=status,
            wireguard_config=updates["wireguardConfig"],
            updated_at=now,
            removed_at=removed_at,
            last_error_code=error_code,
            last_error_message=error_message,
        )


def _role_from_snapshot(snapshot) -> Role | None:
    if not snapshot.exists:
        return None
    return _role_from_data(snapshot.to_dict() or {})


def _exception_is_named(exc: Exception, *class_names: str) -> bool:
    return any(cls.__name__ in class_names for cls in type(exc).__mro__)


def _role_from_data(data: dict[str, Any]) -> Role | None:
    try:
        return Role(data.get("role"))
    except (TypeError, ValueError):
        return None


def _region_from_snapshot(snapshot, region_id: str) -> RegionDoc | None:
    if not snapshot.exists:
        return None
    return _region_from_data(snapshot.to_dict() or {}, region_id)


def _region_from_data(data: dict[str, Any], region_id: str) -> RegionDoc:
    return RegionDoc(
        region_id=data.get("regionId") or region_id,
        display_name=data.get("displayName") or region_id,
        enabled=bool(data.get("enabled")),
        wireguard_endpoint_ipv4=data.get("wireguardEndpointIpv4") or "",
        wireguard_endpoint_ipv6=data.get("wireguardEndpointIpv6"),
        wireguard_port=int(data.get("wireguardPort") or 51820),
        wireguard_dns_ipv4=data.get("wireguardDnsIpv4") or "",
        wireguard_dns_ipv6=data.get("wireguardDnsIpv6") or "",
        wireguard_public_key=data.get("wireguardPublicKey") or "",
        capacity_limit=int(data.get("capacityLimit") or 0),
        active_client_count=int(data.get("activeClientCount") or 0),
        wireguard_endpoint_hostname=data.get("wireguardEndpointHostname") or "",
        display_order=data.get("displayOrder"),
        health_status=data.get("healthStatus"),
        updated_at=data.get("updatedAt"),
    )


def _user_from_data(data: dict[str, Any], uid: str) -> UserDoc:
    return UserDoc(
        uid=data.get("uid") or uid,
        email=data.get("email") or "",
        display_name=data.get("displayName"),
        created_at=data.get("createdAt"),
        disabled=bool(data.get("disabled", False)),
    )


def _client_from_data(data: dict[str, Any], client_id: str, *, now=None) -> ClientDoc:
    return ClientDoc(
        client_id=data.get("clientId") or client_id,
        owner_uid=data.get("ownerUid") or "",
        owner_email=data.get("ownerEmail") or "",
        owner_display_name=data.get("ownerDisplayName"),
        client_name=data.get("clientName") or clean_client_name(None),
        region_id=data.get("regionId") or "",
        status=ClientStatus(data.get("status")),
        assigned_tunnel_ipv4=data.get("assignedTunnelIpv4") or "",
        assigned_tunnel_ipv6=data.get("assignedTunnelIpv6") or "",
        server_endpoint_ipv4=data.get("serverEndpointIpv4") or "",
        server_public_key=data.get("serverPublicKey") or "",
        client_public_key=data.get("clientPublicKey") or "",
        wireguard_config=data.get("wireguardConfig"),
        server_endpoint_hostname=data.get("serverEndpointHostname") or "",
        created_at=data.get("createdAt") if now is None else now,
        updated_at=data.get("updatedAt") if now is None else now,
        removed_at=data.get("removedAt"),
        last_error_code=data.get("lastErrorCode"),
        last_error_message=data.get("lastErrorMessage"),
    )


def _user_write_data(*, uid: str, email: str | None, display_name: str | None, exists: bool) -> dict[str, Any]:
    from firebase_admin import firestore

    data = {
        "uid": uid,
        "email": email or "",
        "displayName": display_name,
    }
    if not exists:
        data["createdAt"] = firestore.SERVER_TIMESTAMP
        data["disabled"] = False
    return data


def _client_write_data(
    *,
    client_id: str,
    owner_uid: str,
    owner_email: str | None,
    owner_display_name: str | None,
    client_name: str | None,
    region: RegionDoc,
    assigned_tunnel_ipv4: str,
    assigned_tunnel_ipv6: str,
) -> dict[str, Any]:
    from firebase_admin import firestore

    return {
        "clientId": client_id,
        "ownerUid": owner_uid,
        "ownerEmail": owner_email or "",
        "ownerDisplayName": owner_display_name,
        "clientName": clean_client_name(client_name),
        "regionId": region.region_id,
        "status": ClientStatus.CREATING.value,
        "assignedTunnelIpv4": assigned_tunnel_ipv4,
        "assignedTunnelIpv6": assigned_tunnel_ipv6,
        "serverEndpointIpv4": region.wireguard_endpoint_ipv4,
        "serverEndpointHostname": region.wireguard_endpoint_hostname,
        "serverPublicKey": region.wireguard_public_key,
        "clientPublicKey": "",
        "wireguardConfig": None,
        "createdAt": firestore.SERVER_TIMESTAMP,
        "updatedAt": firestore.SERVER_TIMESTAMP,
        "removedAt": None,
        "lastErrorCode": None,
        "lastErrorMessage": None,
    }


def _client_ref(db, owner_uid: str, region_id: str, client_id: str):
    return (
        db.collection("Users")
        .document(owner_uid)
        .collection("Regions")
        .document(region_id)
        .collection("Instances")
        .document(client_id)
    )


def _new_client_ref(db, transaction, owner_uid: str, region_id: str):
    for _ in range(5):
        client_id = new_client_id()
        client_ref = _client_ref(db, owner_uid, region_id, client_id)
        if not client_ref.get(transaction=transaction).exists:
            return client_id, client_ref
    raise FirebaseWriteFailedError("Unable to reserve a unique client id.")


def _allocated_region_clients(db, transaction, region_id: str) -> list[ClientDoc]:
    snapshots = db.collection_group("Instances").where("regionId", "==", region_id).stream(transaction=transaction)
    clients = []
    for snapshot in snapshots:
        try:
            client = _client_from_data(snapshot.to_dict() or {}, snapshot.id)
        except ValueError:
            continue
        if client.status in ALLOCATED_CLIENT_STATUSES:
            clients.append(client)
    return clients


def _require_client(snapshot, client_id: str, *, owner_uid: str, region_id: str) -> ClientDoc:
    if not snapshot.exists:
        raise ClientNotFoundError()
    try:
        client = _client_from_data(snapshot.to_dict() or {}, client_id)
    except ValueError as exc:
        raise ClientNotFoundError() from exc
    if client.client_id != client_id or client.owner_uid != owner_uid or client.region_id != region_id:
        raise ClientNotFoundError()
    return client
