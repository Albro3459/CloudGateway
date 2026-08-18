import threading
from collections.abc import Callable, Sequence
from dataclasses import replace
from typing import Any, cast

from google.cloud.firestore_v1.base_document import BaseDocumentReference, DocumentSnapshot
from google.cloud.firestore_v1.base_query import FieldFilter
from google.cloud.firestore_v1.transforms import Sentinel

from .auth import AuthenticatedUser, TokenVerifier
from .enums import ClientStatus, Role
from .errors import (
    AccountDisabledError,
    AuthRequiredError,
    ClientNotFoundError,
    DuplicateEmailError,
    FirebaseWriteFailedError,
    InvalidRequestError,
    RoleDefaultMissingError,
)
from .repository import (
    ALLOCATED_CLIENT_STATUSES,
    ClientDoc,
    CreateUserResult,
    FirebaseRepository,
    MeshPeerState,
    PolicyClientEntry,
    PolicyStatus,
    RegionDoc,
    RegionRegistration,
    RoleDefaultDoc,
    UserDoc,
    UserRoleDoc,
    assert_capacity_available,
    assert_user_limit_available,
    clean_client_name,
    ensure_delete_allowed,
    ensure_local_region,
    ensure_region_enabled,
    new_client_id,
    next_account_slot,
    next_tunnel_index,
    region_display_order,
    require_region,
    tunnel_addresses_for_index,
    used_tunnel_indices,
    utc_now,
    valid_account_slot,
)
from .settings import Settings

_init_lock = threading.Lock()


def _transactional():
    from google.cloud.firestore_v1 import transactional

    return transactional


def _server_timestamp() -> Sentinel:
    from google.cloud.firestore_v1 import SERVER_TIMESTAMP

    return SERVER_TIMESTAMP


def _sync_snapshot(snapshot: Any) -> DocumentSnapshot:
    return cast(DocumentSnapshot, snapshot)


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
            decoded = auth.verify_id_token(token, check_revoked=True)
        except Exception as exc:
            raise AuthRequiredError("Invalid or expired token.") from exc
        uid = decoded.get("uid")
        if not uid:
            raise AuthRequiredError("Invalid or expired token.")
        return AuthenticatedUser(
            uid=uid,
            email=decoded.get("email"),
            auth_time=decoded.get("auth_time"),
        )


class FirestoreRepository(FirebaseRepository):
    def __init__(self, settings: Settings):
        self._settings = settings

    def _db(self):
        from firebase_admin import firestore

        _firebase_app(self._settings)
        return firestore.client()

    def get_role(self, uid: str) -> Role | None:
        doc = _sync_snapshot(self._db().collection("UserRoles").document(uid).get())
        if not doc.exists:
            return None
        user_role = _user_role_from_data(doc.to_dict() or {}, uid)
        return user_role.role if user_role else None

    def get_user(self, uid: str) -> UserDoc | None:
        doc = _sync_snapshot(self._db().collection("Users").document(uid).get())
        if not doc.exists:
            return None
        return _user_from_data(doc.to_dict() or {}, uid)

    def get_region(self, region_id: str) -> RegionDoc | None:
        doc = _sync_snapshot(self._db().collection("Regions").document(region_id).get())
        if not doc.exists:
            return None
        return _region_from_data(doc.to_dict() or {}, region_id)

    def list_enabled_regions(self) -> list[RegionDoc]:
        snapshots = self._db().collection("Regions").where(filter=FieldFilter("enabled", "==", True)).get()
        regions = [_region_from_snapshot(snapshot, snapshot.id) for snapshot in snapshots]
        return sorted((region for region in regions if region is not None and region.enabled is True), key=region_display_order)

    def list_regions(self) -> list[RegionDoc]:
        snapshots = self._db().collection("Regions").get()
        regions = [_region_from_snapshot(snapshot, snapshot.id) for snapshot in snapshots]
        return sorted((region for region in regions if region is not None), key=region_display_order)

    def upsert_region(self, registration: RegionRegistration, *, set_enabled: bool | None) -> RegionDoc:
        db = self._db()
        transactional = _transactional()
        ref = db.collection("Regions").document(registration.region_id)

        @transactional
        def _apply(transaction) -> None:
            # Firestore transactions require all reads before any write; this read
            # decides whether meshEnabled needs seeding (create-only, operator-owned
            # afterward) and whether enabled has to be seeded false.
            exists = _sync_snapshot(ref.get(transaction=transaction)).exists
            data: dict[str, Any] = {
                "regionId": registration.region_id,
                "displayName": registration.display_name,
                "wireguardEndpointIpv4": registration.wireguard_endpoint_ipv4,
                "wireguardEndpointIpv6": registration.wireguard_endpoint_ipv6,
                "wireguardEndpointHostname": registration.wireguard_endpoint_hostname,
                "wireguardPort": registration.wireguard_port,
                "wireguardDnsIpv4": registration.wireguard_dns_ipv4,
                "wireguardDnsIpv6": registration.wireguard_dns_ipv6,
                "wireguardPublicKey": registration.wireguard_public_key,
                "capacityLimit": registration.capacity_limit,
                "displayOrder": registration.display_order,
                "tunnelNetworkV4": registration.tunnel_network_v4,
                "tunnelNetworkV6": registration.tunnel_network_v6,
                "updatedAt": _server_timestamp(),
            }
            if set_enabled is not None:
                data["enabled"] = set_enabled
            elif not exists:
                data["enabled"] = False
            if not exists:
                data["meshEnabled"] = False
            transaction.set(ref, data, merge=True)

        try:
            _apply(db.transaction())
        except Exception as exc:
            raise FirebaseWriteFailedError() from exc

        region = self.get_region(registration.region_id)
        if region is None:
            raise FirebaseWriteFailedError()
        return region

    def write_mesh_status(self, *, region_id: str, mesh_enabled: bool, peers: Sequence[MeshPeerState]) -> None:
        # Full replacement (not merge): peers that fell out of the desired set must
        # disappear from the doc rather than lingering as stale entries.
        applied_at = _server_timestamp()
        peers_data = {}
        for peer in peers:
            peer_data: dict[str, Any] = {
                "status": peer.status.value,
                "appliedAt": applied_at,
            }
            if peer.endpoint_hostname:
                peer_data["endpointHostname"] = peer.endpoint_hostname
            if peer.endpoint_port is not None:
                peer_data["endpointPort"] = peer.endpoint_port
            if peer.public_key:
                peer_data["publicKey"] = peer.public_key
            if peer.allowed_network_v4:
                peer_data["allowedNetworkV4"] = peer.allowed_network_v4
            if peer.allowed_network_v6:
                peer_data["allowedNetworkV6"] = peer.allowed_network_v6
            if peer.reason_code:
                peer_data["reasonCode"] = peer.reason_code
            peers_data[peer.region_id] = peer_data
        try:
            self._db().collection("Mesh").document(region_id).set(
                {
                    "regionId": region_id,
                    "meshEnabled": mesh_enabled,
                    "updatedAt": _server_timestamp(),
                    "peers": peers_data,
                }
            )
        except Exception as exc:
            raise FirebaseWriteFailedError() from exc

    def get_client(self, *, owner_uid: str, region_id: str, client_id: str) -> ClientDoc | None:
        doc = _sync_snapshot(_client_ref(self._db(), region_id, client_id).get())
        if not doc.exists:
            return None
        client = _client_from_data(doc.to_dict() or {}, client_id)
        if client.owner_uid != owner_uid or client.region_id != region_id:
            return None
        return client

    def list_active_clients(self, region_id: str) -> list[ClientDoc]:
        return _region_clients(
            self._db(),
            region_id,
            predicate=lambda client: client.status == ClientStatus.ACTIVE and bool(client.client_public_key),
        )

    def list_allocated_clients(self, region_id: str) -> list[ClientDoc]:
        return _region_clients(
            self._db(),
            region_id,
            predicate=lambda client: client.status in ALLOCATED_CLIENT_STATUSES,
        )

    def list_clients_by_public_key(self, region_id: str, public_keys: set[str]) -> list[ClientDoc]:
        if not public_keys:
            return []
        return _region_clients(
            self._db(),
            region_id,
            predicate=lambda client: client.client_public_key in public_keys,
        )

    def list_clients_for_owner(self, owner_uid: str) -> list[ClientDoc]:
        snapshots = (
            self._db()
            .collection_group("Instances")
            .where(filter=FieldFilter("ownerUid", "==", owner_uid))
            .stream()
        )
        clients: list[ClientDoc] = []
        for raw_snapshot in snapshots:
            snapshot = _sync_snapshot(raw_snapshot)
            client = _client_from_snapshot(snapshot, snapshot.id)
            if client is not None and client.owner_uid == owner_uid:
                clients.append(client)
        return clients

    def list_admin_emails(self) -> list[str]:
        snapshots = (
            self._db()
            .collection("UserRoles")
            .where(filter=FieldFilter("roleId", "==", Role.ADMIN.value))
            .stream()
        )
        emails: list[str] = []
        seen: set[str] = set()
        for raw_snapshot in snapshots:
            snapshot = _sync_snapshot(raw_snapshot)
            user = self.get_user(snapshot.id)
            if user is None:
                continue
            email = user.email.strip()
            if not email:
                continue
            normalized = email.lower()
            if normalized in seen:
                continue
            seen.add(normalized)
            emails.append(email)
        return emails

    def create_user(self, *, email: str) -> CreateUserResult:
        from firebase_admin import auth

        _firebase_app(self._settings)
        already_existed = False
        reenabled_existing_auth = False
        try:
            auth_user = auth.create_user(email=email)
        except Exception as exc:
            if _exception_is_named(exc, "EmailAlreadyExistsError"):
                auth_user = self._get_existing_auth_user(email=email)
                already_existed = True
            elif isinstance(exc, ValueError):
                raise InvalidRequestError() from exc
            else:
                raise FirebaseWriteFailedError() from exc

        uid = auth_user.uid
        if bool(getattr(auth_user, "disabled", False)):
            role_exists = self._role_exists_after_failure(uid)
            if role_exists is None:
                raise FirebaseWriteFailedError()
            if role_exists:
                raise AccountDisabledError("This user already has access, but their Firebase account is disabled.")
            self.enable_auth_user(uid)
            reenabled_existing_auth = True
        now = utc_now()
        try:
            self._provision_user_documents(
                uid=uid,
                email=auth_user.email or email,
            )
        except DuplicateEmailError:
            # If a role now exists, another request provisioned this account;
            # keep any re-enabled Auth user enabled so that successful grant works.
            self._rollback_created_auth_user(auth=auth, uid=uid, already_existed=already_existed)
            raise
        except Exception as exc:
            role_exists = self._role_exists_after_failure(uid)
            if role_exists:
                raise DuplicateEmailError() from exc
            if reenabled_existing_auth:
                self._rollback_reenabled_auth_user(uid=uid, role_exists=role_exists)
            # Roll back the auth account so a retry does not hit duplicate email,
            # but never delete an account that existed before this request
            self._rollback_created_auth_user(
                auth=auth,
                uid=uid,
                already_existed=already_existed,
                role_exists=role_exists,
            )
            raise FirebaseWriteFailedError() from exc

        user = UserDoc(uid=uid, email=auth_user.email or email, created_at=now)
        return CreateUserResult(user=user, already_existed=already_existed)

    def disable_auth_user(self, uid: str) -> None:
        from firebase_admin import auth

        _firebase_app(self._settings)
        try:
            auth.update_user(uid, disabled=True)
            auth.revoke_refresh_tokens(uid)
        except Exception as exc:
            raise FirebaseWriteFailedError() from exc

    def enable_auth_user(self, uid: str) -> None:
        from firebase_admin import auth

        _firebase_app(self._settings)
        try:
            auth.update_user(uid, disabled=False)
        except Exception as exc:
            raise FirebaseWriteFailedError() from exc

    def delete_auth_user(self, uid: str) -> None:
        from firebase_admin import auth

        _firebase_app(self._settings)
        try:
            auth.delete_user(uid)
        except Exception as exc:
            if _exception_is_named(exc, "UserNotFoundError"):
                return
            raise FirebaseWriteFailedError() from exc

    def hard_delete_account_documents(self, uid: str) -> None:
        db = self._db()
        try:
            refs: list[BaseDocumentReference] = [
                db.collection("UserRoles").document(uid),
                db.collection("Users").document(uid),
            ]
            snapshots = (
                db.collection_group("Instances")
                .where(filter=FieldFilter("ownerUid", "==", uid))
                .stream()
            )
            refs.extend(_sync_snapshot(snapshot).reference for snapshot in snapshots)

            for index in range(0, len(refs), 500):
                batch = db.batch()
                for ref in refs[index : index + 500]:
                    batch.delete(ref)
                batch.commit()
        except Exception as exc:
            raise FirebaseWriteFailedError() from exc

    def _get_existing_auth_user(self, *, email: str) -> Any:
        from firebase_admin import auth

        try:
            return auth.get_user_by_email(email)
        except Exception as exc:
            raise FirebaseWriteFailedError() from exc

    def _role_exists(self, uid: str) -> bool:
        return self.get_role(uid) is not None

    def _role_exists_after_failure(self, uid: str) -> bool | None:
        try:
            return self._role_exists(uid)
        except Exception:
            return None

    def _rollback_created_auth_user(
        self,
        *,
        auth: Any,
        uid: str,
        already_existed: bool,
        role_exists: bool | None = None,
    ) -> None:
        if already_existed:
            return
        if role_exists is None:
            role_exists = self._role_exists_after_failure(uid)
        if role_exists is not False:
            return
        try:
            auth.delete_user(uid)
        except Exception:
            pass

    def _rollback_reenabled_auth_user(self, *, uid: str, role_exists: bool | None) -> None:
        if role_exists is not False:
            return
        try:
            self.disable_auth_user(uid)
        except Exception:
            pass

    def _provision_user_documents(self, *, uid: str, email: str) -> None:
        db = self._db()

        @_transactional()
        def provision(transaction):
            user_ref = db.collection("Users").document(uid)
            user_role_ref = db.collection("UserRoles").document(uid)
            counter_ref = _account_slot_ref(db)

            user_role_snapshot = _sync_snapshot(user_role_ref.get(transaction=transaction))
            user_snapshot = _sync_snapshot(user_ref.get(transaction=transaction))
            if user_role_snapshot.exists:
                raise DuplicateEmailError()

            # Allocation is once per account, never reused: only pull a new
            # slot when the (possibly pre-existing) user doc doesn't already
            # carry one - e.g. a prior provisioning attempt that created the
            # Users doc but failed before UserRoles.
            existing_slot = _optional_safe_int((user_snapshot.to_dict() or {}).get("accountSlot")) if user_snapshot.exists else None
            new_slot = existing_slot
            if new_slot is None:
                counter_snapshot = _sync_snapshot(counter_ref.get(transaction=transaction))
                new_slot = _allocate_account_slot(transaction, db, counter_ref, counter_snapshot, exclude_uid=uid)

            transaction.set(
                user_ref,
                _user_write_data(
                    uid=uid,
                    email=email,
                    exists=user_snapshot.exists,
                    account_slot=None if existing_slot is not None else new_slot,
                ),
                merge=True,
            )
            transaction.create(
                user_role_ref,
                {
                    "uid": uid,
                    "roleId": Role.USER.value,
                    "perRegionClientLimit": None,
                    "updatedAt": _server_timestamp(),
                },
            )

        provision(db.transaction())

    def reserve_client(
        self,
        *,
        owner_uid: str,
        owner_email: str | None,
        region_id: str,
        client_name: str,
    ) -> ClientDoc:
        ensure_local_region(region_id, self._settings.region_id)
        db = self._db()

        @_transactional()
        def reserve(transaction):
            user_role_ref = db.collection("UserRoles").document(owner_uid)
            user_ref = db.collection("Users").document(owner_uid)
            region_ref = db.collection("Regions").document(region_id)
            counter_ref = _account_slot_ref(db)

            user_role = _require_user_role(_sync_snapshot(user_role_ref.get(transaction=transaction)), owner_uid)
            role_default = _require_role_default(
                _sync_snapshot(db.collection("Roles").document(user_role.role.value).get(transaction=transaction)),
                user_role.role,
            )
            user_snapshot = _sync_snapshot(user_ref.get(transaction=transaction))
            region = ensure_region_enabled(
                _region_from_snapshot(_sync_snapshot(region_ref.get(transaction=transaction)), region_id)
            )
            allocated_clients = _allocated_region_clients(db, transaction, region_id)
            owner_allocated_count = sum(1 for client in allocated_clients if client.owner_uid == owner_uid)
            per_region_client_limit = _effective_per_region_client_limit(user_role, role_default)

            assert_capacity_available(allocated_count=len(allocated_clients), capacity_limit=region.capacity_limit)
            assert_user_limit_available(
                owner_allocated_count=owner_allocated_count,
                per_region_client_limit=per_region_client_limit,
            )

            # Lazy allocation covers accounts provisioned before this feature:
            # the read must happen here, before any write in this transaction.
            existing_slot = _optional_safe_int((user_snapshot.to_dict() or {}).get("accountSlot")) if user_snapshot.exists else None
            new_account_slot = existing_slot
            if new_account_slot is None:
                counter_snapshot = _sync_snapshot(counter_ref.get(transaction=transaction))
                new_account_slot = _allocate_account_slot(
                    transaction, db, counter_ref, counter_snapshot, exclude_uid=owner_uid
                )

            next_index = next_tunnel_index(
                stored_index=region.tunnel_index_v4,
                used_indices=used_tunnel_indices(
                    allocated_clients,
                    ipv4_cidr=self._settings.wg_tunnel_ipv4_cidr,
                    ipv6_cidr=self._settings.wg_tunnel_ipv6_cidr,
                ),
                ipv4_cidr=self._settings.wg_tunnel_ipv4_cidr,
            )
            assigned_ipv4, assigned_ipv6 = tunnel_addresses_for_index(
                index=next_index,
                ipv4_cidr=self._settings.wg_tunnel_ipv4_cidr,
                ipv6_cidr=self._settings.wg_tunnel_ipv6_cidr,
            )

            client_id, client_ref = _new_client_ref(db, transaction, region_id)
            now = utc_now()
            user_data = _user_write_data(
                uid=owner_uid,
                email=owner_email,
                exists=user_snapshot.exists,
                account_slot=None if existing_slot is not None else new_account_slot,
            )
            client_data = _client_write_data(
                client_id=client_id,
                owner_uid=owner_uid,
                owner_email=owner_email,
                client_name=client_name,
                region=region,
                assigned_tunnel_ipv4=assigned_ipv4,
                assigned_tunnel_ipv6=assigned_ipv6,
            )

            transaction.set(user_ref, user_data, merge=True)
            transaction.set(client_ref, client_data)
            # merge=True, and never touches updatedAt: this is an allocator
            # counter advance, not a metadata change to the region doc.
            transaction.set(region_ref, {"tunnelIndexV4": next_index, "tunnelIndexV6": next_index}, merge=True)
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

        @_transactional()
        def activate(transaction):
            client_ref = _client_ref(db, region_id, client_id)
            snapshot = _sync_snapshot(client_ref.get(transaction=transaction))
            client = _require_client(snapshot, client_id, owner_uid=owner_uid, region_id=region_id)
            if client.status not in {ClientStatus.CREATING, ClientStatus.ACTIVE}:
                raise ClientNotFoundError()

            now = utc_now()
            updates = {
                "status": ClientStatus.ACTIVE.value,
                "clientPublicKey": client_public_key,
                "wireguardConfig": wireguard_config,
                "updatedAt": _server_timestamp(),
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

        @_transactional()
        def delete(transaction):
            user_role_ref = db.collection("UserRoles").document(requester_uid)
            region_ref = db.collection("Regions").document(region_id)
            client_ref = _client_ref(db, region_id, client_id)

            role = _role_from_snapshot(_sync_snapshot(user_role_ref.get(transaction=transaction)))
            ensure_delete_allowed(requester_uid=requester_uid, requester_role=role, target_uid=target_uid)
            require_region(_region_from_snapshot(_sync_snapshot(region_ref.get(transaction=transaction)), region_id))
            client = _require_client(
                _sync_snapshot(client_ref.get(transaction=transaction)),
                client_id,
                owner_uid=target_uid,
                region_id=region_id,
            )
            return self._write_terminal_client(
                transaction=transaction,
                client_ref=client_ref,
                client=client,
                status=ClientStatus.REMOVED,
                error_code=None,
                error_message=None,
            )

        return delete(db.transaction())

    def list_policy_clients(self) -> list[PolicyClientEntry]:
        # Fleet-wide, unfiltered: status filtering happens here in Python so
        # this needs no new composite index (see repository.PolicyClientEntry).
        snapshots = self._db().collection_group("Instances").stream()
        entries: list[PolicyClientEntry] = []
        for raw_snapshot in snapshots:
            snapshot = _sync_snapshot(raw_snapshot)
            try:
                client = _client_from_data(snapshot.to_dict() or {}, snapshot.id)
            except ValueError:
                continue
            if client.status != ClientStatus.ACTIVE or not client.client_public_key:
                continue
            entries.append(
                PolicyClientEntry(
                    owner_uid=client.owner_uid,
                    region_id=client.region_id,
                    assigned_tunnel_ipv4=client.assigned_tunnel_ipv4,
                    assigned_tunnel_ipv6=client.assigned_tunnel_ipv6,
                )
            )
        return entries

    def list_account_slots(self) -> dict[str, int]:
        snapshots = self._db().collection("Users").stream()
        slots: dict[str, int] = {}
        for raw_snapshot in snapshots:
            snapshot = _sync_snapshot(raw_snapshot)
            slot = valid_account_slot((snapshot.to_dict() or {}).get("accountSlot"))
            if slot is not None:
                slots[snapshot.id] = slot
        return slots

    def list_admin_uids(self) -> set[str]:
        snapshots = (
            self._db()
            .collection("UserRoles")
            .where(filter=FieldFilter("roleId", "==", Role.ADMIN.value))
            .stream()
        )
        return {_sync_snapshot(snapshot).id for snapshot in snapshots}

    def get_account_slot(self, uid: str) -> int | None:
        doc = _sync_snapshot(self._db().collection("Users").document(uid).get())
        if not doc.exists:
            return None
        return valid_account_slot((doc.to_dict() or {}).get("accountSlot"))

    def write_policy_status(self, status: PolicyStatus) -> None:
        # Full replacement (not merge), mirroring write_mesh_status: a status
        # doc must describe exactly what the last reconcile pass applied.
        try:
            self._db().collection("Policy").document(status.region_id).set(
                {
                    "regionId": status.region_id,
                    "mapHashV4": status.map_hash_v4,
                    "mapHashV6": status.map_hash_v6,
                    "rowCount": status.row_count,
                    "appliedSequence": status.applied_sequence,
                    # Always null: the policy path dropped updatedAt in Wave 2
                    # (see TODO/account-scoped-acl.md). Kept here, not omitted,
                    # so the documented Firestore shape is unchanged until
                    # Wave 5 removes the field from schema/UI.
                    "dataVintage": None,
                    "updatedAt": _server_timestamp(),
                }
            )
        except Exception as exc:
            raise FirebaseWriteFailedError() from exc

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

        @_transactional()
        def mark_terminal(transaction):
            region_ref = db.collection("Regions").document(region_id)
            client_ref = _client_ref(db, region_id, client_id)
            require_region(_region_from_snapshot(_sync_snapshot(region_ref.get(transaction=transaction)), region_id))
            client = _require_client(
                _sync_snapshot(client_ref.get(transaction=transaction)),
                client_id,
                owner_uid=owner_uid,
                region_id=region_id,
            )
            return self._write_terminal_client(
                transaction=transaction,
                client_ref=client_ref,
                client=client,
                status=status,
                error_code=error_code,
                error_message=error_message,
            )

        return mark_terminal(db.transaction())

    def _write_terminal_client(
        self,
        *,
        transaction,
        client_ref,
        client: ClientDoc,
        status: ClientStatus,
        error_code: str | None,
        error_message: str | None,
    ) -> ClientDoc:
        now = utc_now()
        removed_at = now if status == ClientStatus.REMOVED else None
        updates = {
            "status": status.value,
            "updatedAt": _server_timestamp(),
            "removedAt": _server_timestamp() if removed_at is not None else None,
            "wireguardConfig": None if status == ClientStatus.REMOVED else client.wireguard_config,
            "lastErrorCode": error_code,
            "lastErrorMessage": error_message,
        }
        transaction.update(client_ref, updates)
        return replace(
            client,
            status=status,
            wireguard_config=updates["wireguardConfig"],
            updated_at=now,
            removed_at=removed_at,
            last_error_code=error_code,
            last_error_message=error_message,
        )


def _role_from_snapshot(snapshot: DocumentSnapshot) -> Role | None:
    if not snapshot.exists:
        return None
    return _role_from_data(snapshot.to_dict() or {})


def _exception_is_named(exc: Exception, *class_names: str) -> bool:
    return any(cls.__name__ in class_names for cls in type(exc).__mro__)


def _role_from_data(data: dict[str, Any]) -> Role | None:
    try:
        return Role(data.get("roleId") or data.get("role"))
    except (TypeError, ValueError):
        return None


def _optional_int(value: Any) -> int | None:
    return int(value) if value is not None else None


def _user_role_from_data(data: dict[str, Any], uid: str) -> UserRoleDoc | None:
    role = _role_from_data(data)
    if role is None:
        return None
    try:
        per_region_client_limit = _optional_int(data.get("perRegionClientLimit"))
    except (TypeError, ValueError):
        return None
    return UserRoleDoc(
        uid=data.get("uid") or uid,
        role=role,
        per_region_client_limit=per_region_client_limit,
        updated_at=data.get("updatedAt"),
    )


def _role_default_from_data(data: dict[str, Any], role: Role) -> RoleDefaultDoc | None:
    role_id = _role_from_data(data)
    if role_id is None:
        role_id = role
    if role_id != role:
        return None
    try:
        default_per_region_client_limit = _optional_int(data.get("defaultPerRegionClientLimit"))
    except (TypeError, ValueError):
        return None
    return RoleDefaultDoc(
        role=role,
        default_per_region_client_limit=default_per_region_client_limit,
        updated_at=data.get("updatedAt"),
    )


def _require_user_role(snapshot: DocumentSnapshot, uid: str) -> UserRoleDoc:
    if not snapshot.exists:
        raise FirebaseWriteFailedError()
    user_role = _user_role_from_data(snapshot.to_dict() or {}, uid)
    if user_role is None:
        raise FirebaseWriteFailedError()
    return user_role


def _require_role_default(snapshot: DocumentSnapshot, role: Role) -> RoleDefaultDoc:
    if not snapshot.exists:
        raise RoleDefaultMissingError(f"Roles/{role.value} is missing. Seed the role default in Firestore.")
    role_default = _role_default_from_data(snapshot.to_dict() or {}, role)
    if role_default is None:
        raise RoleDefaultMissingError(f"Roles/{role.value} is malformed. Fix the role default in Firestore.")
    return role_default


def _effective_per_region_client_limit(user_role: UserRoleDoc, role_default: RoleDefaultDoc) -> int | None:
    if user_role.per_region_client_limit is not None:
        return user_role.per_region_client_limit
    return role_default.default_per_region_client_limit


def _region_from_snapshot(snapshot: DocumentSnapshot, region_id: str) -> RegionDoc | None:
    if not snapshot.exists:
        return None
    return _region_from_data(snapshot.to_dict() or {}, region_id)


def _region_from_data(data: dict[str, Any], region_id: str) -> RegionDoc:
    raw_port = data.get("wireguardPort")
    wireguard_port = raw_port if isinstance(raw_port, int) and not isinstance(raw_port, bool) else None
    return RegionDoc(
        region_id=data.get("regionId") or region_id,
        display_name=data.get("displayName") or region_id,
        enabled=data.get("enabled") is True,
        wireguard_endpoint_ipv4=data.get("wireguardEndpointIpv4") or "",
        wireguard_endpoint_ipv6=data.get("wireguardEndpointIpv6"),
        wireguard_port=wireguard_port,
        wireguard_dns_ipv4=data.get("wireguardDnsIpv4") or "",
        wireguard_dns_ipv6=data.get("wireguardDnsIpv6") or "",
        wireguard_public_key=data.get("wireguardPublicKey") or "",
        capacity_limit=_safe_int(data.get("capacityLimit"), default=0),
        wireguard_endpoint_hostname=data.get("wireguardEndpointHostname") or "",
        display_order=_optional_safe_int(data.get("displayOrder")),
        health_status=data.get("healthStatus"),
        updated_at=data.get("updatedAt"),
        tunnel_network_v4=data.get("tunnelNetworkV4") or "",
        tunnel_network_v6=data.get("tunnelNetworkV6") or "",
        mesh_enabled=data.get("meshEnabled") is True,
        tunnel_index_v4=_optional_safe_int(data.get("tunnelIndexV4")),
        tunnel_index_v6=_optional_safe_int(data.get("tunnelIndexV6")),
    )


def _safe_int(value: Any, *, default: int) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) else default


def _optional_safe_int(value: Any) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def _user_from_data(data: dict[str, Any], uid: str) -> UserDoc:
    return UserDoc(
        uid=data.get("uid") or uid,
        email=data.get("email") or "",
        created_at=data.get("createdAt"),
        disabled=bool(data.get("disabled", False)),
        account_slot=_optional_safe_int(data.get("accountSlot")),
    )


def _client_from_snapshot(snapshot: DocumentSnapshot, client_id: str) -> ClientDoc | None:
    if not snapshot.exists:
        return None
    try:
        return _client_from_data(snapshot.to_dict() or {}, client_id)
    except (TypeError, ValueError):
        return None


def _client_from_data(data: dict[str, Any], client_id: str, *, now=None) -> ClientDoc:
    return ClientDoc(
        client_id=data.get("clientId") or client_id,
        owner_uid=data.get("ownerUid") or "",
        owner_email=data.get("ownerEmail") or "",
        client_name=data.get("clientName") or "",
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


def _user_write_data(*, uid: str, email: str | None, exists: bool, account_slot: int | None = None) -> dict[str, Any]:
    data: dict[str, Any] = {
        "uid": uid,
        "email": email or "",
    }
    if not exists:
        data["createdAt"] = _server_timestamp()
        data["disabled"] = False
    # Omitted (not None-written) when there is nothing new to set, so a
    # merge=True write never clears an existing accountSlot.
    if account_slot is not None:
        data["accountSlot"] = account_slot
    return data


def _account_slot_ref(db):
    return db.collection("Counters").document("accountSlots")


def _allocate_account_slot(
    transaction,
    db,
    counter_ref,
    counter_snapshot: DocumentSnapshot,
    *,
    exclude_uid: str,
) -> int:
    """Transactional Counters/accountSlots.nextSlot allocation; caller must have
    already read counter_snapshot (Firestore transactions require every read
    before any write) and must not have written anything yet.

    Reads the full Users collection inside the transaction so a lost or
    corrupted counter can be recovered from the live assigned slots instead of
    resetting to slot 1 and colliding with an existing account (see
    TODO/account-scoped-acl-review.md finding 2). The fleet is tiny
    (region_capacity_limit 20, single-digit accounts today), so a full
    collection read on this rare allocation path is acceptable. exclude_uid is
    the uid being provisioned: both callers only reach this function when that
    uid does not already carry a slot, so it never contributes a valid entry
    here anyway - excluding it is defensive, not load-bearing.
    """
    stored_next_slot = (counter_snapshot.to_dict() or {}).get("nextSlot") if counter_snapshot.exists else None
    assigned_slots: list[object] = []
    for raw_snapshot in db.collection("Users").stream(transaction=transaction):
        snapshot = _sync_snapshot(raw_snapshot)
        if snapshot.id == exclude_uid:
            continue
        slot_value = (snapshot.to_dict() or {}).get("accountSlot")
        # An explicit null is "no slot", not a malformed one: _user_write_data
        # omits the field rather than writing None, and a null can never reach
        # the wire, so it must not fail the recovery path closed.
        if slot_value is not None:
            assigned_slots.append(slot_value)

    slot = next_account_slot(stored_next_slot=stored_next_slot, assigned_slots=assigned_slots)
    transaction.set(counter_ref, {"nextSlot": slot + 1, "updatedAt": _server_timestamp()}, merge=True)
    return slot


def _client_write_data(
    *,
    client_id: str,
    owner_uid: str,
    owner_email: str | None,
    client_name: str,
    region: RegionDoc,
    assigned_tunnel_ipv4: str,
    assigned_tunnel_ipv6: str,
) -> dict[str, Any]:
    return {
        "clientId": client_id,
        "ownerUid": owner_uid,
        "ownerEmail": owner_email or "",
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
        "createdAt": _server_timestamp(),
        "updatedAt": _server_timestamp(),
        "removedAt": None,
        "lastErrorCode": None,
        "lastErrorMessage": None,
    }


def _region_instances_ref(db, region_id: str):
    return db.collection("Regions").document(region_id).collection("Instances")


def _client_ref(db, region_id: str, client_id: str):
    return _region_instances_ref(db, region_id).document(client_id)


def _new_client_ref(db, transaction, region_id: str):
    for _ in range(5):
        client_id = new_client_id()
        client_ref = _client_ref(db, region_id, client_id)
        if not _sync_snapshot(client_ref.get(transaction=transaction)).exists:
            return client_id, client_ref
    raise FirebaseWriteFailedError("Unable to reserve a unique client id.")


def _region_clients(
    db,
    region_id: str,
    *,
    predicate: Callable[[ClientDoc], bool],
    transaction=None,
) -> list[ClientDoc]:
    region_instances = _region_instances_ref(db, region_id)
    snapshots = (
        region_instances.stream(transaction=transaction)
        if transaction is not None
        else region_instances.stream()
    )
    clients = []
    for raw_snapshot in snapshots:
        snapshot = _sync_snapshot(raw_snapshot)
        try:
            client = _client_from_data(snapshot.to_dict() or {}, snapshot.id)
        except ValueError:
            continue
        if predicate(client):
            clients.append(client)
    return clients


def _allocated_region_clients(db, transaction, region_id: str) -> list[ClientDoc]:
    return _region_clients(
        db,
        region_id,
        predicate=lambda client: client.status in ALLOCATED_CLIENT_STATUSES,
        transaction=transaction,
    )


def _require_client(snapshot: DocumentSnapshot, client_id: str, *, owner_uid: str, region_id: str) -> ClientDoc:
    if not snapshot.exists:
        raise ClientNotFoundError()
    try:
        client = _client_from_data(snapshot.to_dict() or {}, client_id)
    except ValueError as exc:
        raise ClientNotFoundError() from exc
    if client.client_id != client_id or client.owner_uid != owner_uid or client.region_id != region_id:
        raise ClientNotFoundError()
    return client
