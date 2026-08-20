"""Firestore transaction ordering for the account-slot allocator.

Firestore requires every read in a transaction to precede every write, and the
Python SDK enforces it client-side: `_helpers.get_transaction_id` raises
`ReadAfterWriteError` for any read issued once the transaction holds a pending
write. `_allocate_account_slot` queues the `Counters/accountSlots` write in the
middle of `reserve_client`'s transaction, so every read that transaction needs -
including `_new_client_ref`'s client-id probe - has to happen before it.

`FakeRepository` is a repository-level double with no transaction semantics, so
it cannot catch a regression here. The strict double below is a Firestore-level
one: reads carrying a transaction fail the moment that transaction has a write.
"""

import pytest

from src.enums import ClientStatus
from src.errors import AccountSlotUnavailableError
from src.firebase import FirestoreRepository
from src.repository import MIN_TUNNEL_INDEX
from src.settings import Settings

REGION_ID = "us-test-1"
OWNER_UID = "user-1"
SEEDED_NEXT_SLOT = 7


class ReadAfterWriteError(AssertionError):
    """Mirrors google.cloud.firestore_v1.base_client.ReadAfterWriteError, which
    the real SDK raises for a read issued after a write in the same
    transaction."""


class StrictTransaction:
    """Records writes and rejects any transactional read that follows one."""

    def __init__(self) -> None:
        # (path, data, merge) per write, in the order they were queued.
        self.writes: list[tuple[str, dict, bool]] = []

    def note_read(self) -> None:
        if self.writes:
            raise ReadAfterWriteError("Attempted read after write in a transaction.")

    def set(self, ref: "FakeDocumentRef", data: dict, merge: bool = False) -> None:
        self.writes.append((ref.path, dict(data), merge))

    def create(self, ref: "FakeDocumentRef", data: dict) -> None:
        self.writes.append((ref.path, dict(data), False))

    def paths(self) -> list[str]:
        return [path for path, _data, _merge in self.writes]

    def data_for(self, path: str) -> dict:
        return next(data for written, data, _merge in self.writes if written == path)


class FakeSnapshot:
    def __init__(self, path: str, data: dict | None) -> None:
        self.id = path.rsplit("/", 1)[-1]
        self.exists = data is not None
        self._data = data

    def to_dict(self) -> dict | None:
        return dict(self._data) if self._data is not None else None


class FakeDocumentRef:
    def __init__(self, store: dict[str, dict], path: str) -> None:
        self._store = store
        self.path = path

    def get(self, transaction: StrictTransaction | None = None) -> FakeSnapshot:
        if transaction is not None:
            transaction.note_read()
        return FakeSnapshot(self.path, self._store.get(self.path))

    def collection(self, name: str) -> "FakeCollectionRef":
        return FakeCollectionRef(self._store, f"{self.path}/{name}")


class FakeCollectionRef:
    def __init__(self, store: dict[str, dict], path: str) -> None:
        self._store = store
        self.path = path

    def document(self, doc_id: str) -> FakeDocumentRef:
        return FakeDocumentRef(self._store, f"{self.path}/{doc_id}")

    def stream(self, transaction: StrictTransaction | None = None) -> list[FakeSnapshot]:
        if transaction is not None:
            transaction.note_read()
        prefix = f"{self.path}/"
        return [
            FakeSnapshot(path, data)
            for path, data in self._store.items()
            if path.startswith(prefix) and "/" not in path[len(prefix) :]
        ]


class FakeDb:
    def __init__(self, store: dict[str, dict]) -> None:
        self._store = store
        self.transaction_double = StrictTransaction()

    def collection(self, name: str) -> FakeCollectionRef:
        return FakeCollectionRef(self._store, name)

    def transaction(self) -> StrictTransaction:
        return self.transaction_double


def _passthrough_transactional():
    """Stands in for firebase._transactional(), which returns the real SDK's
    transactional decorator; the strict double is driven directly instead."""

    def decorator(func):
        return func

    return decorator


def seeded_store(*, account_slot: int | None = None, next_slot: int | None = SEEDED_NEXT_SLOT) -> dict[str, dict]:
    """A minimal fleet: one provisioned account, one enabled region, no
    clients. account_slot=None is the legacy account the lazy allocation path
    exists for."""
    user: dict = {"uid": OWNER_UID, "email": "user@example.com"}
    if account_slot is not None:
        user["accountSlot"] = account_slot
    store: dict[str, dict] = {
        "UserRoles/user-1": {"uid": OWNER_UID, "roleId": "user"},
        "Roles/user": {"roleId": "user", "defaultPerRegionClientLimit": 5},
        "Users/user-1": user,
        f"Regions/{REGION_ID}": {
            "regionId": REGION_ID,
            "displayName": "Test Region",
            "enabled": True,
            "wireguardEndpointIpv4": "203.0.113.10",
            "wireguardEndpointHostname": f"wg.{REGION_ID}.example.com",
            "wireguardPort": 51820,
            "wireguardDnsIpv4": "10.0.0.1",
            "wireguardDnsIpv6": "fd42:42:42::1",
            "wireguardPublicKey": "server-public-key",
            "capacityLimit": 10,
        },
    }
    if next_slot is not None:
        store["Counters/accountSlots"] = {"nextSlot": next_slot}
    return store


@pytest.fixture
def firestore_repository(settings: Settings, monkeypatch: pytest.MonkeyPatch):
    """FirestoreRepository wired to the strict double instead of Firestore."""

    def build(store: dict[str, dict]) -> tuple[FirestoreRepository, FakeDb]:
        from src import firebase

        db = FakeDb(store)
        monkeypatch.setattr(firebase, "_transactional", _passthrough_transactional)
        monkeypatch.setattr(FirestoreRepository, "_db", lambda _self: db)
        return FirestoreRepository(settings), db

    return build


def test_strict_double_rejects_a_read_after_a_write():
    # Without this, a broken double would let every test below pass silently.
    store = seeded_store()
    db = FakeDb(store)
    transaction = db.transaction()

    db.collection("Users").document(OWNER_UID).get(transaction=transaction)
    transaction.set(db.collection("Counters").document("accountSlots"), {"nextSlot": 8}, merge=True)

    with pytest.raises(ReadAfterWriteError):
        db.collection("Users").document(OWNER_UID).get(transaction=transaction)
    with pytest.raises(ReadAfterWriteError):
        db.collection("Users").stream(transaction=transaction)


def test_reserve_client_reads_everything_before_the_account_slot_write(firestore_repository):
    # The legacy-account path: no accountSlot yet, so the transaction queues
    # the counter write mid-way. Every read - including _new_client_ref's
    # client-id probe - must already have happened.
    repository, db = firestore_repository(seeded_store())

    client = repository.reserve_client(
        owner_uid=OWNER_UID,
        owner_email="user@example.com",
        region_id=REGION_ID,
        client_name="Phone",
    )

    assert client.status == ClientStatus.CREATING
    transaction = db.transaction_double
    assert transaction.data_for("Counters/accountSlots")["nextSlot"] == SEEDED_NEXT_SLOT + 1
    assert transaction.data_for(f"Users/{OWNER_UID}")["accountSlot"] == SEEDED_NEXT_SLOT
    assert transaction.data_for(f"Regions/{REGION_ID}")["tunnelIndexV4"] == MIN_TUNNEL_INDEX
    assert f"Regions/{REGION_ID}/Instances/{client.client_id}" in transaction.paths()
    # The counter write is the allocator's, and it comes first: everything
    # after it in this transaction must be a write too.
    assert transaction.paths()[0] == "Counters/accountSlots"


def test_provision_user_documents_reads_everything_before_the_account_slot_write(firestore_repository):
    repository, db = firestore_repository(seeded_store())

    repository._provision_user_documents(uid="user-2", email="second@example.com")

    transaction = db.transaction_double
    assert transaction.data_for("Counters/accountSlots")["nextSlot"] == SEEDED_NEXT_SLOT + 1
    assert transaction.data_for("Users/user-2")["accountSlot"] == SEEDED_NEXT_SLOT
    assert "UserRoles/user-2" in transaction.paths()
    assert transaction.paths()[0] == "Counters/accountSlots"


def test_reserve_client_for_an_account_that_already_has_a_slot_writes_no_counter(firestore_repository):
    repository, db = firestore_repository(seeded_store(account_slot=3))

    repository.reserve_client(
        owner_uid=OWNER_UID,
        owner_email="user@example.com",
        region_id=REGION_ID,
        client_name="Phone",
    )

    transaction = db.transaction_double
    assert "Counters/accountSlots" not in transaction.paths()
    # merge=True with the field omitted, so the existing slot is never rewritten.
    assert "accountSlot" not in transaction.data_for(f"Users/{OWNER_UID}")


def test_reserve_client_writes_nothing_when_the_counter_cannot_allocate(firestore_repository):
    # Counter document missing: allocation fails closed, and because it fails
    # before the first write, no user, slot, client, tunnel index, or
    # replacement counter reaches Firestore.
    repository, db = firestore_repository(seeded_store(next_slot=None))

    with pytest.raises(AccountSlotUnavailableError):
        repository.reserve_client(
            owner_uid=OWNER_UID,
            owner_email="user@example.com",
            region_id=REGION_ID,
            client_name="Phone",
        )

    assert db.transaction_double.writes == []
