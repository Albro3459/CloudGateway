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
# apply_map/add_client_row never write cg_tunnel4/6 (the static mesh
# aggregates installed by bootstrap.sh) - but read_map does read them back,
# since they are still authorization-bearing for the comprehensive hash.
POLICY_TABLE = "cloudgateway"

# The forward chain bootstrap.sh installs inside POLICY_TABLE. Not otherwise
# used by this module (apply_map/add_client_row/read_map only ever name the
# sets/maps, never the chain), but tests/test_bootstrap_contract.py enforces
# that this matches the live ruleset.
POLICY_CHAIN = "cg_forward"

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


# Named objects read back per family (see Infrastructure/OCI/host/bootstrap.sh's
# `table inet cloudgateway`), in the fixed order hash_policy_family hashes them.
_FAMILY_OBJECT_NAMES: dict[int, dict[str, str]] = {
    4: {"tunnel": "cg_tunnel4", "infra": "cg_infra4", "admin": "cg_admin4", "slot": "cg_slot4", "pairs": "cg_pairs4"},
    6: {"tunnel": "cg_tunnel6", "infra": "cg_infra6", "admin": "cg_admin6", "slot": "cg_slot6", "pairs": "cg_pairs6"},
}


@dataclass(frozen=True)
class LivePolicyFamily:
    """Every authorization-bearing nftables object for one address family, read
    back from the live host.

    Element order is canonicalized here, at construction, rather than trusted
    from the caller: the digest must depend only on what is on the wire, so
    two regions holding identical policy can never publish different hashes
    because their nft build happened to list elements in a different order.
    Every field must already be validated (real addresses for this family,
    slots in range) - construction is not a validation boundary.
    """

    version: int  # 4 or 6
    tunnel: tuple[str, ...]  # CIDR strings, e.g. "10.0.0.0/16"
    infra: tuple[str, ...]  # bare addresses
    admin: tuple[str, ...]  # bare addresses
    slots: tuple[tuple[str, int], ...]  # (address, slot)
    pairs: tuple[tuple[str, int], ...]  # (address, mark)

    def __post_init__(self) -> None:
        object.__setattr__(self, "tunnel", tuple(sorted(self.tunnel, key=_network_sort_key)))
        object.__setattr__(self, "infra", tuple(sorted(self.infra, key=_address_sort_key)))
        object.__setattr__(self, "admin", tuple(sorted(self.admin, key=_address_sort_key)))
        object.__setattr__(self, "slots", tuple(sorted(self.slots, key=_marked_address_sort_key)))
        object.__setattr__(self, "pairs", tuple(sorted(self.pairs, key=_marked_address_sort_key)))

    @property
    def hash(self) -> str:
        return hash_policy_family(self)


def _address_sort_key(address: str) -> bytes:
    return ipaddress.ip_address(address).packed


def _network_sort_key(cidr: str) -> tuple[bytes, int]:
    network = ipaddress.ip_network(cidr, strict=False)
    return (network.network_address.packed, network.prefixlen)


def _marked_address_sort_key(element: tuple[str, int]) -> tuple[bytes, int]:
    # The mark breaks ties so a set holding one address twice under different
    # marks still canonicalizes to one order.
    address, mark = element
    return (ipaddress.ip_address(address).packed, mark)


@dataclass(frozen=True)
class LivePolicyMap:
    v4: LivePolicyFamily
    v6: LivePolicyFamily

    @property
    def hash_v4(self) -> str:
        return self.v4.hash

    @property
    def hash_v6(self) -> str:
        return self.v6.hash

    @property
    def row_count(self) -> int:
        # The number of cg_slot4 rows, per TODO/account-scoped-acl.md Wave 5
        # ("keep rowCount as the number of slot-map rows").
        return len(self.v4.slots)


def hash_policy_family(family: LivePolicyFamily) -> str:
    """Composite digest covering every authorization-bearing nftables object in
    one address family: cg_tunnel, cg_infra, cg_admin, cg_slot, cg_pairs.

    Digest format: one line per canonicalized element, "<object-name>
    <element...>", objects emitted in a fixed order (tunnel, infra, admin,
    slot, pairs) with each object's own elements in the order
    LivePolicyFamily canonicalized them, joined with "\\n" and sha256-hashed
    (hex digest). The explicit object-name
    label on every line is load-bearing, not decorative: it is what makes
    "cg_admin4 10.0.0.2" and "cg_infra4 10.0.0.2" hash differently even though
    the address is identical, and it is why v4 and v6 are independent even if
    their contents were structurally identical - cg_admin4 and cg_admin6 never
    share a label.
    """
    names = _FAMILY_OBJECT_NAMES[family.version]
    lines: list[str] = []
    lines += (f"{names['tunnel']} {cidr}" for cidr in family.tunnel)
    lines += (f"{names['infra']} {address}" for address in family.infra)
    lines += (f"{names['admin']} {address}" for address in family.admin)
    lines += (f"{names['slot']} {address} {slot}" for address, slot in family.slots)
    lines += (f"{names['pairs']} {address} {mark}" for address, mark in family.pairs)
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()


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
        """Read back what is actually on the wire: every authorization-bearing
        object per family (cg_tunnel, cg_infra, cg_admin, cg_slot, cg_pairs),
        not just cg_slot4/6."""


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
        # One invocation for the whole table: reading each of the ten named
        # objects with its own `nft -j list <set|map> ...` call would be ten
        # round trips and ten chances for the table to change mid-read-back.
        result = self._run(
            ["nft", "-j", "list", "table", "inet", POLICY_TABLE],
            failure_message="Policy map read failed.",
        )
        objects = _extract_named_objects(result.stdout)
        return LivePolicyMap(
            v4=_read_family(objects, 4),
            v6=_read_family(objects, 6),
        )

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
    """nft's JSON wraps a set/map element in an outer {"elem": ...} on some
    versions, and wraps a scalar attribute-bearing value in {"val": ...} on
    others (either or both may be present, or neither for a bare scalar).
    Both wrappers are peeled here so every element parser below is agnostic to
    nft version; a dict that is neither wrapper (e.g. {"prefix": ...} or
    {"concat": ...}) passes through unchanged for its own specific parser."""
    if isinstance(value, dict) and "elem" in value:
        value = value["elem"]
    if isinstance(value, dict) and "val" in value:
        value = value["val"]
    return value


def _extract_named_objects(payload: str) -> dict[str, dict]:
    """Parse one `nft -j list table ...` payload into a name -> object dict
    covering every named set/map entry, regardless of which ones the caller
    needs. Missing/malformed shape at this level is fail-closed."""
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

    objects: dict[str, dict] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        for key in ("set", "map"):
            obj = entry.get(key)
            if isinstance(obj, dict) and isinstance(obj.get("name"), str):
                objects[obj["name"]] = obj
    return objects


def _require_object(objects: dict[str, dict], name: str) -> dict:
    obj = objects.get(name)
    if not isinstance(obj, dict):
        # A named object absent from the table listing is a failure, never an
        # empty object: a missing cg_admin4 must not silently hash as "no
        # admins" when the real answer is "could not be read."
        raise PolicyApplyFailedError(f"Policy map read failed: {name} missing.")
    return obj


def _elements(obj: dict, name: str) -> list:
    # An empty set/map may omit "elem" entirely rather than emit an empty list.
    raw = obj.get("elem", [])
    if not isinstance(raw, list):
        raise PolicyApplyFailedError(f"Policy map read failed: {name} elem is not a list.")
    return raw


def _parse_address_set(elements: list, version: int, label: str) -> tuple[str, ...]:
    addresses: list[str] = []
    for raw in elements:
        value = _unwrap_element_value(raw)
        if not isinstance(value, str):
            raise PolicyApplyFailedError(f"Policy map read failed: malformed {label} element.")
        addresses.append(_validate_address(value, version, f"live {label} address"))
    # Order is canonicalized by LivePolicyFamily, not here.
    return tuple(addresses)


def _parse_slot_map_elements(elements: list, version: int) -> tuple[tuple[str, int], ...]:
    rows: list[tuple[str, int]] = []
    for raw_pair in elements:
        if not isinstance(raw_pair, list) or len(raw_pair) != 2:
            raise PolicyApplyFailedError("Policy map read failed: malformed slot element.")
        raw_address, raw_slot = raw_pair
        address = _unwrap_element_value(raw_address)
        slot = _unwrap_element_value(raw_slot)
        if not isinstance(address, str):
            raise PolicyApplyFailedError("Policy map read failed: malformed slot element.")
        rows.append((_validate_address(address, version, "live slot address"), _validate_slot(slot)))
    return tuple(rows)


def _parse_pairs_set(elements: list, version: int) -> tuple[tuple[str, int], ...]:
    pairs: list[tuple[str, int]] = []
    for raw in elements:
        value = _unwrap_element_value(raw)
        if not isinstance(value, dict) or not isinstance(value.get("concat"), list):
            raise PolicyApplyFailedError("Policy map read failed: malformed pairs element.")
        parts = value["concat"]
        if len(parts) != 2:
            raise PolicyApplyFailedError("Policy map read failed: malformed pairs element.")
        address = _unwrap_element_value(parts[0])
        mark = _unwrap_element_value(parts[1])
        if not isinstance(address, str):
            raise PolicyApplyFailedError("Policy map read failed: malformed pairs element.")
        pairs.append((_validate_address(address, version, "live pairs address"), _validate_slot(mark)))
    return tuple(pairs)


def _parse_tunnel_set(elements: list, version: int) -> tuple[str, ...]:
    bits = 32 if version == 4 else 128
    networks: list[ipaddress.IPv4Network | ipaddress.IPv6Network] = []
    for raw in elements:
        value = _unwrap_element_value(raw)
        if isinstance(value, dict) and isinstance(value.get("prefix"), dict):
            prefix = value["prefix"]
            addr, length = prefix.get("addr"), prefix.get("len")
            if not isinstance(addr, str) or not isinstance(length, int) or isinstance(length, bool):
                raise PolicyApplyFailedError("Policy map read failed: malformed tunnel prefix.")
            try:
                network = ipaddress.ip_network(f"{addr}/{length}", strict=False)
            except ValueError as exc:
                raise PolicyApplyFailedError("Policy map read failed: malformed tunnel prefix.") from exc
        elif isinstance(value, str):
            address = _validate_address(value, version, "live tunnel address")
            network = ipaddress.ip_network(f"{address}/{bits}", strict=False)
        else:
            raise PolicyApplyFailedError("Policy map read failed: malformed tunnel element.")
        if network.version != version:
            raise PolicyApplyFailedError("Policy map read failed: wrong-family tunnel prefix.")
        networks.append(network)
    return tuple(str(network) for network in networks)


def _read_family(objects: dict[str, dict], version: int) -> LivePolicyFamily:
    names = _FAMILY_OBJECT_NAMES[version]
    tunnel_obj = _require_object(objects, names["tunnel"])
    infra_obj = _require_object(objects, names["infra"])
    admin_obj = _require_object(objects, names["admin"])
    slot_obj = _require_object(objects, names["slot"])
    pairs_obj = _require_object(objects, names["pairs"])
    return LivePolicyFamily(
        version=version,
        tunnel=_parse_tunnel_set(_elements(tunnel_obj, names["tunnel"]), version),
        infra=_parse_address_set(_elements(infra_obj, names["infra"]), version, "infra"),
        admin=_parse_address_set(_elements(admin_obj, names["admin"]), version, "admin"),
        slots=_parse_slot_map_elements(_elements(slot_obj, names["slot"]), version),
        pairs=_parse_pairs_set(_elements(pairs_obj, names["pairs"]), version),
    )
