import fcntl
import hashlib
import ipaddress
import json
import os
import subprocess
from abc import ABC, abstractmethod
from collections.abc import Sequence
from contextlib import AbstractContextManager, contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator

from .errors import PolicyApplyFailedError, SyncInProgressError

CommandRunner = Callable[..., subprocess.CompletedProcess[str]]

# Fixed object names installed empty by PostUp (see TODO/account-scoped-acl.md,
# "Filter design"). This module never creates or deletes the table/chain, and
# it never touches cg_tunnel4/6 (the static mesh aggregates from wireguard.py).
POLICY_TABLE = "cloudgateway"

DEFAULT_POLICY_LOCK_PATH = "/run/cloudgateway-policy.lock"
# nft is local and fast; the caller holds lock() across this call, so a wedged
# process must not pin it indefinitely (same reasoning as wireguard.py).
COMMAND_TIMEOUT_SECONDS = 20.0

# Slot 0 is reserved: `meta mark set ip saddr map @cg_slot` leaves the mark
# cleared for an unknown source, so 0 must never be an assignable slot.
MIN_SLOT = 1
MAX_SLOT = 2**32 - 1


@dataclass(frozen=True)
class PolicyRow:
    address_v4: str  # bare host address, no prefix, e.g. "10.0.0.2"
    address_v6: str
    slot: int
    admin: bool = False


@dataclass(frozen=True)
class LivePolicyMap:
    rows_v4: tuple[tuple[str, int], ...]  # (address, slot), sorted by packed address
    rows_v6: tuple[tuple[str, int], ...]

    @property
    def hash_v4(self) -> str:
        return hash_policy_rows(self.rows_v4)

    @property
    def hash_v6(self) -> str:
        return hash_policy_rows(self.rows_v6)

    @property
    def row_count(self) -> int:
        # rows_v4 and rows_v6 are paired 1:1 per client (see address allocation
        # in the design doc); the v4 side is the count of reference.
        return len(self.rows_v4)


def hash_policy_rows(rows: Sequence[tuple[str, int]]) -> str:
    """Stable digest of a sorted (address, slot) row set, including the empty map."""
    return hashlib.sha256(
        "\n".join(f"{address} {slot}" for address, slot in rows).encode()
    ).hexdigest()


class PolicyManager(ABC):
    """The account-scoped ACL map lives only on the host's nftables sets/maps.

    Nothing here persists rows to disk. apply_map replaces the whole map
    atomically; add_client_row is an additive fast path for the create
    request's inline local row. Callers must hold lock() across a mutation and
    its matching Firestore/status write so a concurrent reconcile never
    observes mid-apply state.
    """

    @abstractmethod
    def lock(self, *, blocking: bool = True) -> AbstractContextManager[None]:
        """Exclusive cross-process lock context manager for policy mutations.

        A different lock file than wireguard.lock(): a policy refresh must
        never contend with add_peer on the client create path. blocking=False
        raises SyncInProgressError instead of queueing, so an HTTP caller can
        shed the request.
        """

    @abstractmethod
    def apply_map(
        self,
        rows: Sequence[PolicyRow],
        *,
        infra_v4: Sequence[str] = (),
        infra_v6: Sequence[str] = (),
    ) -> None:
        """Replace cg_infra/cg_admin/cg_pairs/cg_slot contents atomically."""

    @abstractmethod
    def add_client_row(self, row: PolicyRow) -> None:
        """Add one row's elements without flushing the rest of the map."""

    @abstractmethod
    def read_map(self) -> LivePolicyMap:
        """Read back what is actually on the wire (cg_slot4/6)."""


class LocalPolicyManager(PolicyManager):
    def __init__(
        self,
        *,
        lock_path: str = DEFAULT_POLICY_LOCK_PATH,
        command_runner: CommandRunner = subprocess.run,
    ):
        self.lock_path = Path(lock_path)
        self.command_runner = command_runner

    @contextmanager
    def lock(self, *, blocking: bool = True) -> Iterator[None]:
        self.lock_path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        fd = os.open(self.lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        os.fchmod(fd, 0o600)
        file = os.fdopen(fd, "w")
        operation = fcntl.LOCK_EX if blocking else fcntl.LOCK_EX | fcntl.LOCK_NB
        try:
            fcntl.flock(file.fileno(), operation)
        except BlockingIOError as exc:
            file.close()
            raise SyncInProgressError() from exc
        except BaseException:
            file.close()
            raise
        try:
            yield
        finally:
            fcntl.flock(file.fileno(), fcntl.LOCK_UN)
            file.close()

    def apply_map(
        self,
        rows: Sequence[PolicyRow],
        *,
        infra_v4: Sequence[str] = (),
        infra_v6: Sequence[str] = (),
    ) -> None:
        validated_rows = [_validate_row(row) for row in rows]
        validated_infra_v4 = [_validate_address(address, 4, "infra address v4") for address in infra_v4]
        validated_infra_v6 = [_validate_address(address, 6, "infra address v6") for address in infra_v6]
        script = render_policy_script(
            validated_rows, infra_v4=validated_infra_v4, infra_v6=validated_infra_v6
        )
        self._run_script(script, failure_message="Policy map apply failed.")

    def add_client_row(self, row: PolicyRow) -> None:
        validated = _validate_row(row)
        script = render_client_row_script(validated)
        self._run_script(script, failure_message="Policy row apply failed.")

    def read_map(self) -> LivePolicyMap:
        return LivePolicyMap(
            rows_v4=self._read_slot_map(4),
            rows_v6=self._read_slot_map(6),
        )

    def _read_slot_map(self, version: int) -> tuple[tuple[str, int], ...]:
        set_name = "cg_slot4" if version == 4 else "cg_slot6"
        result = self._run(
            ["nft", "-j", "list", "map", "inet", POLICY_TABLE, set_name],
            failure_message="Policy map read failed.",
        )
        return _parse_slot_map(result.stdout, version)

    def _run_script(self, script: str, *, failure_message: str) -> None:
        self._run(["nft", "-f", "-"], input=script, failure_message=failure_message)

    def _run(
        self,
        args: list[str],
        *,
        input: str | None = None,
        failure_message: str | None = None,
        transient: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        try:
            return self.command_runner(
                args,
                input=input,
                capture_output=True,
                text=True,
                check=True,
                shell=False,
                timeout=COMMAND_TIMEOUT_SECONDS,
            )
        except subprocess.CalledProcessError as exc:
            raise PolicyApplyFailedError(
                failure_message or f"{args[0]} command failed.",
                transient=transient,
            ) from exc
        except subprocess.TimeoutExpired as exc:
            # The caller holds the policy lock; a wedged nft call must not pin it.
            raise PolicyApplyFailedError(
                failure_message or f"{args[0]} command timed out.",
                transient=True,
            ) from exc


def render_policy_script(
    rows: Sequence[PolicyRow],
    *,
    infra_v4: Sequence[str] = (),
    infra_v6: Sequence[str] = (),
) -> str:
    """Render one nft script that atomically replaces every dynamic policy object.

    SECURITY: every value rendered here originates in Firestore by way of the
    caller. Nothing may be interpolated raw into an nft script - callers
    (apply_map, add_client_row) validate every address with ipaddress and
    every slot as an int in MIN_SLOT..MAX_SLOT before this function ever sees
    it, because a single unescaped field here is a command injection into the
    host firewall. This function itself does not re-validate; it trusts its
    caller and must only ever be called with already-validated rows.
    """
    rows_by_v4 = sorted(rows, key=lambda row: ipaddress.ip_address(row.address_v4).packed)
    rows_by_v6 = sorted(rows, key=lambda row: ipaddress.ip_address(row.address_v6).packed)
    admin_v4 = sorted(
        (row.address_v4 for row in rows if row.admin), key=lambda a: ipaddress.ip_address(a).packed
    )
    admin_v6 = sorted(
        (row.address_v6 for row in rows if row.admin), key=lambda a: ipaddress.ip_address(a).packed
    )
    sorted_infra_v4 = sorted(infra_v4, key=lambda a: ipaddress.ip_address(a).packed)
    sorted_infra_v6 = sorted(infra_v6, key=lambda a: ipaddress.ip_address(a).packed)

    lines = [
        f"flush set inet {POLICY_TABLE} cg_infra4",
        f"flush set inet {POLICY_TABLE} cg_infra6",
        f"flush set inet {POLICY_TABLE} cg_admin4",
        f"flush set inet {POLICY_TABLE} cg_admin6",
        f"flush set inet {POLICY_TABLE} cg_pairs4",
        f"flush set inet {POLICY_TABLE} cg_pairs6",
        f"flush map inet {POLICY_TABLE} cg_slot4",
        f"flush map inet {POLICY_TABLE} cg_slot6",
    ]
    lines += _filter_empty(
        [
            _render_set_element("cg_infra4", sorted_infra_v4),
            _render_set_element("cg_infra6", sorted_infra_v6),
            _render_set_element("cg_admin4", admin_v4),
            _render_set_element("cg_admin6", admin_v6),
            _render_slot_element(rows_by_v4, family=4),
            _render_slot_element(rows_by_v6, family=6),
            _render_pairs_element(rows_by_v4, family=4),
            _render_pairs_element(rows_by_v6, family=6),
        ]
    )
    return "\n".join(lines) + "\n"


def render_client_row_script(row: PolicyRow) -> str:
    """Render the single-row additive script used by the create path's inline
    local apply. See render_policy_script's SECURITY note; this function has
    the same trust contract with its caller (add_client_row validates first).
    """
    mark = _format_mark(row.slot)
    lines = [
        f"add element inet {POLICY_TABLE} cg_slot4 {{ {row.address_v4} : {mark} }}",
        f"add element inet {POLICY_TABLE} cg_slot6 {{ {row.address_v6} : {mark} }}",
        f"add element inet {POLICY_TABLE} cg_pairs4 {{ {row.address_v4} . {mark} }}",
        f"add element inet {POLICY_TABLE} cg_pairs6 {{ {row.address_v6} . {mark} }}",
    ]
    if row.admin:
        lines.append(f"add element inet {POLICY_TABLE} cg_admin4 {{ {row.address_v4} }}")
        lines.append(f"add element inet {POLICY_TABLE} cg_admin6 {{ {row.address_v6} }}")
    return "\n".join(lines) + "\n"


def _filter_empty(lines: Sequence[str | None]) -> list[str]:
    return [line for line in lines if line is not None]


def _render_set_element(name: str, addresses: Sequence[str]) -> str | None:
    # nft rejects `{ }`; a set/map with nothing to add just keeps its flush.
    if not addresses:
        return None
    return f"add element inet {POLICY_TABLE} {name} {{ {', '.join(addresses)} }}"


def _render_slot_element(rows: Sequence[PolicyRow], *, family: int) -> str | None:
    if not rows:
        return None
    name = "cg_slot4" if family == 4 else "cg_slot6"
    items = ", ".join(
        f"{_row_address(row, family)} : {_format_mark(row.slot)}" for row in rows
    )
    return f"add element inet {POLICY_TABLE} {name} {{ {items} }}"


def _render_pairs_element(rows: Sequence[PolicyRow], *, family: int) -> str | None:
    if not rows:
        return None
    name = "cg_pairs4" if family == 4 else "cg_pairs6"
    items = ", ".join(
        f"{_row_address(row, family)} . {_format_mark(row.slot)}" for row in rows
    )
    return f"add element inet {POLICY_TABLE} {name} {{ {items} }}"


def _row_address(row: PolicyRow, family: int) -> str:
    return row.address_v4 if family == 4 else row.address_v6


def _format_mark(slot: int) -> str:
    return f"0x{slot:08x}"


def _validate_address(value: str, version: int, label: str) -> str:
    try:
        address = ipaddress.ip_address(value)
    except ValueError as exc:
        raise PolicyApplyFailedError(f"Invalid policy {label}.") from exc
    if address.version != version:
        raise PolicyApplyFailedError(f"Invalid policy {label}.")
    return str(address)


def _validate_slot(value: object) -> int:
    if isinstance(value, str):
        try:
            value = int(value, 0)
        except ValueError as exc:
            raise PolicyApplyFailedError("Invalid policy slot.") from exc
    if not isinstance(value, int) or isinstance(value, bool) or not (MIN_SLOT <= value <= MAX_SLOT):
        raise PolicyApplyFailedError("Invalid policy slot.")
    return value


def _validate_row(row: PolicyRow) -> PolicyRow:
    return PolicyRow(
        address_v4=_validate_address(row.address_v4, 4, "address v4"),
        address_v6=_validate_address(row.address_v6, 6, "address v6"),
        slot=_validate_slot(row.slot),
        admin=bool(row.admin),
    )


def _unwrap_element_value(value: object) -> object:
    """nft's JSON emits a bare scalar for a simple element on some versions and
    a wrapped object (e.g. {"elem": {"val": ...}} or {"val": ...}) on others;
    normalize both to the bare value so read_map does not depend on nft version."""
    if isinstance(value, dict):
        wrapped = value.get("elem", value)
        if isinstance(wrapped, dict) and "val" in wrapped:
            return wrapped["val"]
    return value


def _parse_slot_map(payload: str, version: int) -> tuple[tuple[str, int], ...]:
    try:
        data = json.loads(payload)
    except (TypeError, ValueError) as exc:
        raise PolicyApplyFailedError("Policy map read failed: invalid JSON.") from exc

    try:
        entries = data["nftables"]
    except (KeyError, TypeError, IndexError) as exc:
        raise PolicyApplyFailedError("Policy map read failed: unexpected JSON shape.") from exc
    if not isinstance(entries, list):
        raise PolicyApplyFailedError("Policy map read failed: unexpected JSON shape.")

    map_obj: object = None
    for entry in entries:
        if isinstance(entry, dict) and isinstance(entry.get("map"), dict):
            map_obj = entry["map"]
            break
    if not isinstance(map_obj, dict):
        raise PolicyApplyFailedError("Policy map read failed: map object missing.")

    # An empty map may omit "elem" entirely rather than emit an empty list.
    raw_elements = map_obj.get("elem", [])
    if not isinstance(raw_elements, list):
        raise PolicyApplyFailedError("Policy map read failed: elem is not a list.")

    rows: list[tuple[str, int]] = []
    for raw_pair in raw_elements:
        if not isinstance(raw_pair, list) or len(raw_pair) != 2:
            raise PolicyApplyFailedError("Policy map read failed: malformed element.")
        raw_address, raw_slot = raw_pair
        address = _unwrap_element_value(raw_address)
        slot = _unwrap_element_value(raw_slot)
        if not isinstance(address, str):
            raise PolicyApplyFailedError("Policy map read failed: malformed element.")
        rows.append((_validate_address(address, version, "live policy address"), _validate_slot(slot)))

    rows.sort(key=lambda row: ipaddress.ip_address(row[0]).packed)
    return tuple(rows)
