#!/usr/bin/env python3
"""Detect unmanaged or duplicate CloudGateway regional resources before Terraform runs."""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import subprocess
import sys
from collections.abc import Mapping
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


INSTANCE_ADDRESS = "oci_core_instance.generated_oci_core_instance"
API_RECORD_ADDRESS = "cloudflare_record.api"
WG_RECORD_ADDRESS = "cloudflare_record.wg"
REGISTRY_PATH = Path(__file__).resolve().parents[1] / "Infrastructure" / "OCI" / "terraform" / "subnet-registry.json"

WG_SUBNET_KEYS = (
    "wg_network_v4",
    "wg_address_v4",
    "wg_dns_address_v4",
    "wg_network_v6",
    "wg_address_v6",
    "wg_dns_address_v6",
)
REGISTRY_REGION_KEYS = {"region_id", "wg_network_v4", "wg_network_v6", "status"}
REGISTRY_STATUSES = {"active", "reserved"}
ALLOCATION_PREFIX_V4 = 24
ALLOCATION_PREFIX_V6 = 64

# Fallback values keep evaluate_subnet_plan independently useful in unit tests. Runtime
# preflight always replaces these with the tracked registry aggregates.
SUBNET_AGGREGATE_V4 = ipaddress.IPv4Network("10.0.0.0/16")
SUBNET_AGGREGATE_V6 = ipaddress.IPv6Network("fd42:42:42::/48")


class RegionValues(dict[str, str]):
    """Raw tfvars values with the source file retained for diagnostics."""

    def __init__(self, values: Mapping[str, str], source_filename: Path | None = None) -> None:
        super().__init__(values)
        self.source_filename = source_filename


class RegistryRegion:
    __slots__ = ("region_id", "network_v4", "network_v6", "status", "source_filename")

    def __init__(
        self,
        region_id: str,
        network_v4: ipaddress.IPv4Network,
        network_v6: ipaddress.IPv6Network,
        status: str,
        source_filename: Path,
    ) -> None:
        self.region_id = region_id
        self.network_v4 = network_v4
        self.network_v6 = network_v6
        self.status = status
        self.source_filename = source_filename


class SubnetRegistry:
    __slots__ = ("aggregate_v4", "aggregate_v6", "regions", "source_filename")

    def __init__(
        self,
        aggregate_v4: ipaddress.IPv4Network,
        aggregate_v6: ipaddress.IPv6Network,
        regions: tuple[RegistryRegion, ...],
        source_filename: Path,
    ) -> None:
        self.aggregate_v4 = aggregate_v4
        self.aggregate_v6 = aggregate_v6
        self.regions = regions
        self.source_filename = source_filename


class TfvarsParseError(RuntimeError):
    """A tfvars file contains syntax this dependency-free parser cannot trust."""

    def __init__(self, path: Path, line_number: int, message: str) -> None:
        location = f"{path}:{line_number}" if line_number else str(path)
        super().__init__(f"{location}: {message}")
        self.path = path
        self.line_number = line_number


def read_tfvars(path: Path) -> dict[str, str]:
    """Read the scalar/heredoc tfvars syntax used by the regional wrapper.

    This intentionally is not a general HCL parser. It accepts only the forms used by
    the checked-in example and rejects unknown lines, duplicate assignments, malformed
    quoted values, and unterminated heredocs instead of silently dropping them.
    """
    try:
        lines = path.read_text().splitlines()
    except OSError as exc:
        raise TfvarsParseError(path, 0, f"failed to read tfvars ({exc})") from exc

    values: dict[str, str] = {}
    heredoc_end: str | None = None
    heredoc_line = 0
    list_end = False
    list_line = 0

    def assign(key: str, value: str, line_number: int) -> None:
        if key in values:
            raise TfvarsParseError(path, line_number, f"duplicate assignment for {key!r}")
        values[key] = value

    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.strip()
        if heredoc_end is not None:
            if line == heredoc_end:
                heredoc_end = None
            continue
        if list_end:
            # HCL allows comments and blank lines inside a list, and `terraform fmt`
            # preserves them. The parser only needs region_id and the six wg_* scalars
            # (never list-typed), so list bodies are skipped unvalidated until the
            # closing bracket instead of fullmatching each item.
            if line.startswith("]"):
                list_end = False
            continue
        if not line or line.startswith("#"):
            continue

        list_match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\[\s*", line)
        if list_match:
            assign(list_match.group(1), "", line_number)
            list_end = True
            list_line = line_number
            continue

        heredoc_match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*<<-?([A-Za-z_][A-Za-z0-9_]*)", line)
        if heredoc_match:
            assign(heredoc_match.group(1), "", line_number)
            heredoc_end = heredoc_match.group(2)
            heredoc_line = line_number
            continue

        quoted_match = re.fullmatch(
            r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"((?:\\.|[^"\\])*)"\s*(?:#.*)?',
            line,
        )
        if quoted_match:
            try:
                value = json.loads(f'"{quoted_match.group(2)}"')
            except json.JSONDecodeError as exc:
                raise TfvarsParseError(path, line_number, f"invalid quoted value: {exc.msg}") from exc
            assign(quoted_match.group(1), value, line_number)
            continue

        bare_match = re.fullmatch(
            r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^\s#\[\]{}(),]+)\s*(?:#.*)?",
            line,
        )
        if bare_match:
            assign(bare_match.group(1), bare_match.group(2), line_number)
            continue

        raise TfvarsParseError(path, line_number, "unsupported or malformed tfvars assignment")

    if heredoc_end is not None:
        raise TfvarsParseError(path, heredoc_line, f"unterminated heredoc; expected {heredoc_end}")
    if list_end:
        raise TfvarsParseError(path, list_line, "unterminated list; expected ]")
    return values


def required(values: dict[str, str], key: str, varfile: Path) -> str:
    value = values.get(key)
    if value is None or value == "":
        raise SystemExit(f"Missing required {key} in {varfile}")
    return value


def discover_sibling_tfvars(
    varfile: Path, registry: SubnetRegistry | None = None
) -> tuple[dict[str, RegionValues], list[str]]:
    """Read present sibling tfvars as optional consistency checks.

    The registry, not this directory scan, is the region inventory. Missing registry
    regions are therefore valid.

    Only a canonical `<registry-region-id>.terraform.tfvars` may block a run, the same
    rule split_blocking_siblings applies to the consistency check itself. An operator's
    scratch file - a half-written draft for an unregistered region, or a backup copy
    that still carries the original's region_id - is reported as a plain note, so it
    cannot fail an unrelated region's deploy or destroy. When two files claim one
    region_id the canonical one wins the slot, so the retained entry is always the file
    the consistency check is actually about.
    """
    canonical_ids = registry_region_ids(registry)
    regions: dict[str, RegionValues] = {}
    notes: list[str] = []

    for sibling in sorted(varfile.parent.glob("*.terraform.tfvars")):
        # A file that fails to parse has no region_id to check, so the filename is all
        # there is to go on.
        sibling_is_canonical = is_canonical_sibling(sibling.name, canonical_ids)
        try:
            values = read_tfvars(sibling)
        except TfvarsParseError as exc:
            if sibling_is_canonical:
                notes.append(f"error: {exc}")
            else:
                notes.append(
                    f"skipping {sibling.name}: {exc}; it is not the canonical tfvars of a "
                    "registered region, so its parse failure does not block this run."
                )
            continue

        region_id = values.get("region_id")
        if not region_id:
            notes.append(f"skipping {sibling.name}: no region_id found")
            continue

        region_values = RegionValues(
            {key: values.get(key, "") for key in WG_SUBNET_KEYS},
            sibling,
        )
        previous = regions.get(region_id)
        if previous is not None:
            previous_name = previous.source_filename.name if previous.source_filename else "unknown"
            # The canonical file wins the slot, so the retained entry is always the one
            # the consistency check is about; the copy only earns a note.
            if is_canonical_sibling(sibling.name, canonical_ids, region_id):
                kept, skipped = sibling.name, previous_name
            else:
                kept, skipped = previous_name, sibling.name
            notes.append(
                f"duplicate region_id {region_id!r} in {previous_name} and {sibling.name}; "
                f"keeping {kept} and skipping {skipped}'s subnet consistency check."
            )
            if kept != sibling.name:
                continue
        regions[region_id] = region_values

    return regions, notes


def canonical_sibling_filename(region_id: str) -> str:
    return f"{region_id}.terraform.tfvars"


def registry_region_ids(registry: SubnetRegistry | None) -> set[str]:
    return {region.region_id for region in registry.regions} if registry is not None else set()


def is_canonical_sibling(filename: str, canonical_ids: set[str], region_id: str | None = None) -> bool:
    """A sibling is canonical when it is named `<region-id>.terraform.tfvars` for a
    region the registry actually has. region_id defaults to the one the filename claims;
    pass the file's own region_id to also require that the two agree."""
    if region_id is None:
        region_id = filename.removesuffix(".terraform.tfvars")
    return region_id in canonical_ids and filename == canonical_sibling_filename(region_id)


def split_blocking_siblings(
    sibling_regions: Mapping[str, RegionValues],
    registry: SubnetRegistry | None,
) -> tuple[dict[str, RegionValues], list[str]]:
    """Separate siblings whose consistency mismatch is worth blocking a deploy.

    Only a sibling whose filename is exactly `<region-id>.terraform.tfvars` for a
    region_id that is actually in the registry is the canonical file for that region;
    a mismatch there is a real signal. Anything else (a draft for a region that is not
    registered yet, or a file renamed/copied so its name no longer matches its own
    region_id) is unrelated operator scratch space and is downgraded to a note instead
    of hard-failing every other region's deploy and destroy.
    """
    canonical_ids = registry_region_ids(registry)
    blocking: dict[str, RegionValues] = {}
    notes: list[str] = []
    for region_id, values in sibling_regions.items():
        filename = values.source_filename.name if values.source_filename else ""
        if is_canonical_sibling(filename, canonical_ids, region_id):
            blocking[region_id] = values
        else:
            notes.append(
                f"{filename or region_id} does not match a canonical registry filename "
                f"({canonical_sibling_filename(region_id)!r} for a registered region); "
                "skipping its subnet consistency check."
            )
    return blocking, notes


def _parse_registry_network(
    raw: Any,
    region_id: str,
    key: str,
    family: int,
    source_filename: Path,
    errors: list[str],
) -> ipaddress.IPv4Network | ipaddress.IPv6Network | None:
    if not isinstance(raw, str) or not raw:
        errors.append(f"{source_filename}: registry region {region_id!r} has invalid {key}; expected a CIDR string.")
        return None
    try:
        network = ipaddress.ip_network(raw, strict=True)
    except ValueError as exc:
        errors.append(
            f"{source_filename}: registry region {region_id!r} {key} {raw!r} is not a canonical network "
            f"with no host bits set ({exc})."
        )
        return None
    if network.version != family:
        errors.append(
            f"{source_filename}: registry region {region_id!r} {key} {raw!r} must be IPv{family}, "
            f"got IPv{network.version}."
        )
        return None
    if str(network) != raw:
        errors.append(
            f"{source_filename}: registry region {region_id!r} {key} {raw!r} is not canonical; use {network}."
        )
    return network


def validate_subnet_registry(payload: Any, source_filename: Path = REGISTRY_PATH) -> tuple[list[str], SubnetRegistry | None]:
    """Validate and decode the tracked authoritative subnet registry."""
    errors: list[str] = []
    if not isinstance(payload, dict):
        return [f"{source_filename}: registry must be a JSON object."], None

    expected_keys = {"schema_version", "aggregate_v4", "aggregate_v6", "regions"}
    if set(payload) != expected_keys:
        errors.append(
            f"{source_filename}: registry must contain exactly {sorted(expected_keys)}, got {sorted(payload)}."
        )
    schema_version = payload.get("schema_version")
    if not isinstance(schema_version, int) or isinstance(schema_version, bool) or schema_version != 1:
        errors.append(f"{source_filename}: registry schema_version must be integer 1.")

    aggregate_v4_raw = _parse_registry_network(payload.get("aggregate_v4"), "<aggregate>", "aggregate_v4", 4, source_filename, errors)
    aggregate_v6_raw = _parse_registry_network(payload.get("aggregate_v6"), "<aggregate>", "aggregate_v6", 6, source_filename, errors)
    aggregate_v4 = aggregate_v4_raw if isinstance(aggregate_v4_raw, ipaddress.IPv4Network) else None
    aggregate_v6 = aggregate_v6_raw if isinstance(aggregate_v6_raw, ipaddress.IPv6Network) else None
    if aggregate_v4 is not None and aggregate_v4 != SUBNET_AGGREGATE_V4:
        errors.append(f"{source_filename}: aggregate_v4 must be exactly {SUBNET_AGGREGATE_V4}.")
    if aggregate_v6 is not None and aggregate_v6 != SUBNET_AGGREGATE_V6:
        errors.append(f"{source_filename}: aggregate_v6 must be exactly {SUBNET_AGGREGATE_V6}.")
    raw_regions = payload.get("regions")
    if not isinstance(raw_regions, list):
        errors.append(f"{source_filename}: registry regions must be a JSON list, not an object or scalar.")
        raw_regions = []

    regions: list[RegistryRegion] = []
    seen_ids: set[str] = set()
    for index, raw_region in enumerate(raw_regions):
        location = f"{source_filename}: registry regions[{index}]"
        if not isinstance(raw_region, dict):
            errors.append(f"{location} must be an object.")
            continue
        if set(raw_region) != REGISTRY_REGION_KEYS:
            errors.append(f"{location} must contain exactly {sorted(REGISTRY_REGION_KEYS)}.")
        region_id = raw_region.get("region_id")
        if not isinstance(region_id, str) or not region_id.strip() or region_id != region_id.strip():
            errors.append(f"{location}.region_id must be a non-empty, trimmed string.")
            continue
        if region_id in seen_ids:
            errors.append(f"{source_filename}: duplicate registry region_id {region_id!r}.")
            continue
        seen_ids.add(region_id)
        status = raw_region.get("status")
        if not isinstance(status, str) or status not in REGISTRY_STATUSES:
            errors.append(f"{location}.status must be exactly 'active' or 'reserved', got {status!r}.")
        network_v4_raw = _parse_registry_network(raw_region.get("wg_network_v4"), region_id, "wg_network_v4", 4, source_filename, errors)
        network_v6_raw = _parse_registry_network(raw_region.get("wg_network_v6"), region_id, "wg_network_v6", 6, source_filename, errors)
        network_v4 = network_v4_raw if isinstance(network_v4_raw, ipaddress.IPv4Network) else None
        network_v6 = network_v6_raw if isinstance(network_v6_raw, ipaddress.IPv6Network) else None
        if network_v4 is None or network_v6 is None or status not in REGISTRY_STATUSES:
            continue
        if network_v4.prefixlen != ALLOCATION_PREFIX_V4:
            errors.append(f"{location}.wg_network_v4 must use /{ALLOCATION_PREFIX_V4}, got {network_v4}.")
        if network_v6.prefixlen != ALLOCATION_PREFIX_V6:
            errors.append(f"{location}.wg_network_v6 must use /{ALLOCATION_PREFIX_V6}, got {network_v6}.")
        regions.append(RegistryRegion(region_id, network_v4, network_v6, status, source_filename))

    if aggregate_v4 is not None:
        for region in regions:
            if not region.network_v4.subnet_of(aggregate_v4):
                errors.append(f"{source_filename}: registry region {region.region_id!r} network {region.network_v4} is outside aggregate_v4 {aggregate_v4}.")
    if aggregate_v6 is not None:
        for region in regions:
            if not region.network_v6.subnet_of(aggregate_v6):
                errors.append(f"{source_filename}: registry region {region.region_id!r} network {region.network_v6} is outside aggregate_v6 {aggregate_v6}.")

    for index, first in enumerate(regions):
        for second in regions[index + 1 :]:
            if first.network_v4.overlaps(second.network_v4):
                errors.append(f"{source_filename}: registry networks for {first.region_id} and {second.region_id} overlap in IPv4 ({first.network_v4} and {second.network_v4}).")
            if first.network_v6.overlaps(second.network_v6):
                errors.append(f"{source_filename}: registry networks for {first.region_id} and {second.region_id} overlap in IPv6 ({first.network_v6} and {second.network_v6}).")

    if errors or aggregate_v4 is None or aggregate_v6 is None:
        return errors, None
    return errors, SubnetRegistry(aggregate_v4, aggregate_v6, tuple(regions), source_filename)


def load_subnet_registry(path: Path = REGISTRY_PATH) -> tuple[list[str], SubnetRegistry | None]:
    try:
        payload = json.loads(path.read_text())
    except OSError as exc:
        return [f"{path}: failed to read subnet registry ({exc})."], None
    except json.JSONDecodeError as exc:
        return [f"{path}: subnet registry is not valid JSON ({exc})."], None
    return validate_subnet_registry(payload, path)


def _region_label(region_id: str, values: Mapping[str, str]) -> str:
    source = getattr(values, "source_filename", None)
    return f"{region_id} ({source.name})" if isinstance(source, Path) else region_id


def _parse_subnet_network_v4(region_id: str, key: str, raw: str, errors: list[str]) -> ipaddress.IPv4Network | None:
    try:
        network = ipaddress.ip_network(raw, strict=True)
    except ValueError as exc:
        errors.append(f"{region_id}: {key} {raw!r} is not a valid network with no host bits set ({exc}).")
        return None
    if not isinstance(network, ipaddress.IPv4Network):
        errors.append(f"{region_id}: {key} {raw!r} must be an IPv4 network, got IPv{network.version}.")
        return None
    if str(network) != raw:
        errors.append(f"{region_id}: {key} {raw!r} is not canonical; use {network}.")
    return network


def _parse_subnet_network_v6(region_id: str, key: str, raw: str, errors: list[str]) -> ipaddress.IPv6Network | None:
    try:
        network = ipaddress.ip_network(raw, strict=True)
    except ValueError as exc:
        errors.append(f"{region_id}: {key} {raw!r} is not a valid network with no host bits set ({exc}).")
        return None
    if not isinstance(network, ipaddress.IPv6Network):
        errors.append(f"{region_id}: {key} {raw!r} must be an IPv6 network, got IPv{network.version}.")
        return None
    if str(network) != raw:
        errors.append(f"{region_id}: {key} {raw!r} is not canonical; use {network}.")
    return network


def _check_subnet_interface(
    region_id: str,
    key: str,
    raw: str,
    network: ipaddress.IPv4Network | ipaddress.IPv6Network,
    errors: list[str],
) -> ipaddress.IPv4Interface | ipaddress.IPv6Interface | None:
    try:
        interface = ipaddress.ip_interface(raw)
    except ValueError as exc:
        errors.append(f"{region_id}: {key} {raw!r} is not a valid IP interface ({exc}).")
        return None
    if interface.version != network.version:
        errors.append(f"{region_id}: {key} {raw!r} is IPv{interface.version} but its network is IPv{network.version}.")
        return None
    if interface.network.prefixlen != network.prefixlen:
        errors.append(
            f"{region_id}: {key} prefix /{interface.network.prefixlen} does not match its network's /{network.prefixlen} prefix."
        )
    if interface.network != network:
        errors.append(
            f"{region_id}: {key} {interface} is not inside its own network {network} and does not derive that network."
        )
    if network.prefixlen == network.max_prefixlen:
        errors.append(
            f"{region_id}: {key} exact network {network} has no first host address; use a network with host space."
        )
        return interface
    expected_ip = network.network_address + 1
    if interface.ip != expected_ip:
        errors.append(
            f"{region_id}: {key} {interface.ip} must be the first host address {expected_ip} of its exact network {network}."
        )
    return interface


def _check_dns_address(
    region_id: str,
    key: str,
    raw: str,
    interface: ipaddress.IPv4Interface | ipaddress.IPv6Interface | None,
    network: ipaddress.IPv4Network | ipaddress.IPv6Network,
    errors: list[str],
) -> None:
    try:
        address = ipaddress.ip_address(raw)
    except ValueError as exc:
        errors.append(f"{region_id}: {key} {raw!r} is not a valid IP address ({exc}).")
        return
    if address.version != network.version:
        errors.append(f"{region_id}: {key} {raw!r} is IPv{address.version} but its network is IPv{network.version}.")
        return
    if address not in network:
        errors.append(f"{region_id}: {key} {address} is not inside its own network {network}.")
    if interface is not None and address != interface.ip:
        errors.append(f"{region_id}: {key} {address} must equal {interface.ip}, the corresponding WireGuard interface IP.")


def _parse_region_subnets(
    region_id: str, values: Mapping[str, str], aggregate_v4: ipaddress.IPv4Network = SUBNET_AGGREGATE_V4,
    aggregate_v6: ipaddress.IPv6Network = SUBNET_AGGREGATE_V6,
) -> tuple[list[str], tuple[ipaddress.IPv4Network, ipaddress.IPv6Network] | None]:
    label = _region_label(region_id, values)
    errors: list[str] = []
    missing = [key for key in WG_SUBNET_KEYS if not values.get(key)]
    if missing:
        errors.append(
            f"{label}: missing {', '.join(missing)} in tfvars; every present region's WireGuard subnet fields "
            "must be complete for the subnet consistency check to run."
        )
        return errors, None

    network_v4 = _parse_subnet_network_v4(label, "wg_network_v4", values["wg_network_v4"], errors)
    network_v6 = _parse_subnet_network_v6(label, "wg_network_v6", values["wg_network_v6"], errors)
    if network_v4 is not None:
        if network_v4.prefixlen != ALLOCATION_PREFIX_V4:
            errors.append(f"{label}: wg_network_v4 must use /{ALLOCATION_PREFIX_V4}, got {network_v4}.")
        if not network_v4.subnet_of(aggregate_v4):
            errors.append(f"{label}: wg_network_v4 {network_v4} is outside the shared aggregate {aggregate_v4}.")
        interface_v4 = _check_subnet_interface(label, "wg_address_v4", values["wg_address_v4"], network_v4, errors)
        _check_dns_address(label, "wg_dns_address_v4", values["wg_dns_address_v4"], interface_v4, network_v4, errors)
    if network_v6 is not None:
        if network_v6.prefixlen != ALLOCATION_PREFIX_V6:
            errors.append(f"{label}: wg_network_v6 must use /{ALLOCATION_PREFIX_V6}, got {network_v6}.")
        if not network_v6.subnet_of(aggregate_v6):
            errors.append(f"{label}: wg_network_v6 {network_v6} is outside the shared aggregate {aggregate_v6}.")
        interface_v6 = _check_subnet_interface(label, "wg_address_v6", values["wg_address_v6"], network_v6, errors)
        _check_dns_address(label, "wg_dns_address_v6", values["wg_dns_address_v6"], interface_v6, network_v6, errors)

    if network_v4 is None or network_v6 is None:
        return errors, None
    return errors, (network_v4, network_v6)


def evaluate_subnet_plan(
    regions: Mapping[str, Mapping[str, str]],
    registry: SubnetRegistry | None = None,
    selected_region_id: str | None = None,
    require_active: bool = True,
) -> list[str]:
    """Validate present tfvars and compare them with the authoritative registry.

    require_active gates the registry status check on the selected region: plan/apply
    must select an `active` allocation, but destroy must accept `reserved` too, since
    README.md tells operators to leave a decommissioned region's allocation reserved
    rather than deleting it, and that region still needs to be torn down.
    """
    errors: list[str] = []
    aggregate_v4 = registry.aggregate_v4 if registry else SUBNET_AGGREGATE_V4
    aggregate_v6 = registry.aggregate_v6 if registry else SUBNET_AGGREGATE_V6
    networks: dict[str, tuple[ipaddress.IPv4Network, ipaddress.IPv6Network]] = {}
    registry_by_id = {region.region_id: region for region in registry.regions} if registry else {}

    for region_id, values in sorted(regions.items()):
        if registry and region_id not in registry_by_id:
            errors.append(f"{_region_label(region_id, values)}: region_id is not present in the authoritative subnet registry.")
        region_errors, parsed = _parse_region_subnets(region_id, values, aggregate_v4, aggregate_v6)
        errors.extend(region_errors)
        if parsed is not None:
            networks[region_id] = parsed
            if registry and region_id in registry_by_id:
                expected = registry_by_id[region_id]
                actual_v4, actual_v6 = parsed
                expected_v4 = str(expected.network_v4)
                expected_v6 = str(expected.network_v6)
                if actual_v4 != expected.network_v4 or values["wg_network_v4"] != expected_v4:
                    errors.append(f"{_region_label(region_id, values)}: wg_network_v4 {values['wg_network_v4']!r} must exactly match registry allocation {expected_v4}.")
                if actual_v6 != expected.network_v6 or values["wg_network_v6"] != expected_v6:
                    errors.append(f"{_region_label(region_id, values)}: wg_network_v6 {values['wg_network_v6']!r} must exactly match registry allocation {expected_v6}.")

    if registry and selected_region_id is not None:
        selected = [region for region in registry.regions if region.region_id == selected_region_id]
        if not selected:
            errors.append(f"{selected_region_id}: no registry entry exists; the selected region must have one active allocation.")
        elif require_active and selected[0].status != "active":
            errors.append(f"{selected_region_id}: registry allocation is {selected[0].status}, not active; reserved regions cannot be selected.")
        elif selected_region_id not in regions:
            errors.append(f"{selected_region_id}: selected tfvars has no matching local registry consistency entry.")

    region_ids = sorted(networks)
    for i, a_id in enumerate(region_ids):
        a_v4, a_v6 = networks[a_id]
        for b_id in region_ids[i + 1 :]:
            b_v4, b_v6 = networks[b_id]
            if a_v4.overlaps(b_v4):
                errors.append(f"{_region_label(a_id, regions[a_id])} and {_region_label(b_id, regions[b_id])}: wg_network_v4 {a_v4} and {b_v4} overlap.")
            if a_v6.overlaps(b_v6):
                errors.append(f"{_region_label(a_id, regions[a_id])} and {_region_label(b_id, regions[b_id])}: wg_network_v6 {a_v6} and {b_v6} overlap.")
    return errors


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        raise RuntimeError(f"missing command: {command[0]}") from None


def run_json(command: list[str]) -> Any:
    result = run(command)
    if result.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(command)}\n{result.stderr.strip()}")
    return json.loads(result.stdout or "null")


def state_ids() -> dict[str, str]:
    result = run(["terraform", "show", "-json"])
    if result.returncode != 0 or not result.stdout.strip():
        return {}
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}

    ids: dict[str, str] = {}

    def walk(module: dict[str, Any]) -> None:
        for resource in module.get("resources", []):
            address = resource.get("address")
            value_id = (resource.get("values") or {}).get("id")
            if address and value_id is not None:
                ids[address] = str(value_id)
        for child in module.get("child_modules", []):
            walk(child)

    walk((payload.get("values") or {}).get("root_module") or {})
    return ids


def state_matches(ids: dict[str, str], address: str, external_id: str, zone_id: str | None = None) -> bool:
    current_id = ids.get(address)
    if current_id is None:
        return False
    accepted_ids = {external_id}
    if zone_id:
        accepted_ids.add(f"{zone_id}/{external_id}")
    return current_id in accepted_ids


def cloudflare_records(zone_id: str, token: str, hostname: str) -> list[dict[str, Any]]:
    query = urllib.parse.urlencode({"type": "A", "name": hostname, "per_page": "100"})
    request = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?{query}",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Cloudflare lookup failed for {hostname}: HTTP {exc.code} {detail}") from None
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Cloudflare lookup failed for {hostname}: {exc.reason}") from None

    if not payload.get("success"):
        raise RuntimeError(f"Cloudflare lookup failed for {hostname}: {payload}")
    return list(payload.get("result", []))


def oci_instances(compartment_id: str, profile: str, region: str) -> list[dict[str, Any]]:
    payload = run_json(
        [
            "oci",
            "--profile",
            profile,
            "--region",
            region,
            "compute",
            "instance",
            "list",
            "--compartment-id",
            compartment_id,
            "--all",
            "--output",
            "json",
        ]
    )
    instances = payload.get("data", []) if isinstance(payload, dict) else []
    matches = []
    for instance in instances:
        if instance.get("lifecycle-state") in {"TERMINATING", "TERMINATED"}:
            continue
        tags = instance.get("freeform-tags") or {}
        if tags.get("CloudGatewayManaged") == "true":
            matches.append(instance)
    return matches


def format_records(records: list[dict[str, Any]]) -> str:
    return "\n".join(
        f"  - id={record.get('id')} name={record.get('name')} content={record.get('content')} proxied={record.get('proxied')}"
        for record in records
    )


def format_instances(instances: list[dict[str, Any]]) -> str:
    return "\n".join(
        f"  - id={instance.get('id')} name={instance.get('display-name')} state={instance.get('lifecycle-state')}"
        for instance in instances
    )


def load_plan_changes(plan_json_path: Path | None) -> list[dict[str, Any]] | None:
    if plan_json_path is None:
        return None
    if not plan_json_path.exists():
        return []
    payload = json.loads(plan_json_path.read_text() or "{}")
    return list(payload.get("resource_changes", []))


def evaluate_region(
    region_id: str,
    zone_id: str,
    managed_ids: dict[str, str],
    api_records: list[dict[str, Any]],
    wg_records: list[dict[str, Any]],
    instances: list[dict[str, Any]],
    api_hostname: str,
    wg_hostname: str,
    plan_changes: list[dict[str, Any]] | None,
) -> list[str]:
    errors: list[str] = []

    def check_existing_records(label: str, address: str, hostname: str, records: list[dict[str, Any]]) -> None:
        if len(records) == 0:
            return
        if len(records) > 1:
            errors.append(
                f"{region_id}: duplicate Cloudflare {label} A records for {hostname}; manually reconcile before deploy.\n"
                f"{format_records(records)}"
            )
            return
        record_id = str(records[0].get("id", ""))
        if not state_matches(managed_ids, address, record_id, zone_id):
            errors.append(
                f"{region_id}: Cloudflare {label} A record exists for {hostname} but is not owned by Terraform state; "
                "manually import or reconcile before deploy.\n"
                f"{format_records(records)}"
            )

    check_existing_records("API", API_RECORD_ADDRESS, api_hostname, api_records)
    check_existing_records("WireGuard", WG_RECORD_ADDRESS, wg_hostname, wg_records)

    if len(instances) > 1:
        errors.append(
            f"{region_id}: duplicate OCI CloudGateway-managed instances found; manually reconcile before deploy.\n"
            f"{format_instances(instances)}"
        )
    elif len(instances) == 1:
        instance_id = str(instances[0].get("id", ""))
        if not state_matches(managed_ids, INSTANCE_ADDRESS, instance_id):
            errors.append(
                f"{region_id}: OCI CloudGateway-managed instance exists but is not owned by Terraform state; "
                "manually import or reconcile before deploy.\n"
                f"{format_instances(instances)}"
            )

    if plan_changes is not None:
        external_present = {
            API_RECORD_ADDRESS: len(api_records) == 1,
            WG_RECORD_ADDRESS: len(wg_records) == 1,
            INSTANCE_ADDRESS: len(instances) == 1,
        }
        for change in plan_changes:
            address = change.get("address")
            actions = change.get("change", {}).get("actions", [])
            if isinstance(address, str) and actions == ["create"] and external_present.get(address):
                errors.append(
                    f"{region_id}: Terraform plan wants to create {address}, but a matching external resource already exists; "
                    "manually reconcile state/resources before deploy."
                )

    return errors


def check_region(
    region_id: str,
    varfile: Path,
    plan_json_path: Path | None,
    registry_path: Path = REGISTRY_PATH,
    require_active: bool = True,
) -> int:
    values = read_tfvars(varfile)
    zone_id = required(values, "cloudflare_zone_id", varfile)
    token = required(values, "cloudflare_api_token", varfile)
    compartment_id = required(values, "compartment_id", varfile)
    profile = values.get("oci_config_profile", "DEFAULT")
    region = required(values, "region", varfile)
    tfvars_region_id = required(values, "region_id", varfile)
    if region != region_id or tfvars_region_id != region_id:
        errors = [
            f"{region_id}: tfvars region is {region} and tfvars region_id is {tfvars_region_id}, "
            f"but terraform.sh selected {region_id}; manually reconcile the region arguments and tfvars before deploy."
        ]
        print(f"Terraform preflight failed for {region_id}.", file=sys.stderr)
        print("Refusing to continue because manual reconciliation is required.", file=sys.stderr)
        print("", file=sys.stderr)
        print("\n\n".join(errors), file=sys.stderr)
        return 1

    registry_errors, registry = load_subnet_registry(registry_path)
    sibling_regions, skip_notes = discover_sibling_tfvars(varfile, registry)
    blocking_regions, filter_notes = split_blocking_siblings(sibling_regions, registry)
    skip_notes = skip_notes + filter_notes
    for note in skip_notes:
        stream = sys.stderr if note.startswith("error:") else sys.stdout
        print(f"==> preflight note: {note}", file=stream)
    subnet_errors = registry_errors + evaluate_subnet_plan(blocking_regions, registry, region_id, require_active)
    if any(note.startswith("error:") for note in skip_notes):
        subnet_errors.extend(note.removeprefix("error: ").strip() for note in skip_notes if note.startswith("error:"))
    if subnet_errors:
        print(f"Terraform preflight failed for {region_id}.", file=sys.stderr)
        print("Refusing to continue because manual reconciliation is required.", file=sys.stderr)
        print("", file=sys.stderr)
        print("\n\n".join(subnet_errors), file=sys.stderr)
        return 1

    api_hostname = required(values, "api_hostname", varfile)
    wg_hostname = required(values, "wg_endpoint_hostname", varfile)
    api_records = cloudflare_records(zone_id, token, api_hostname)
    wg_records = cloudflare_records(zone_id, token, wg_hostname)
    instances = oci_instances(compartment_id, profile, region)

    errors = evaluate_region(
        region_id,
        zone_id,
        state_ids(),
        api_records,
        wg_records,
        instances,
        api_hostname,
        wg_hostname,
        load_plan_changes(plan_json_path),
    )

    if errors:
        print(f"Terraform preflight failed for {region_id}.", file=sys.stderr)
        print("Refusing to continue because manual reconciliation is required.", file=sys.stderr)
        print("", file=sys.stderr)
        print("\n\n".join(errors), file=sys.stderr)
        return 1

    print(f"==> preflight ok: {region_id}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region-id", required=True)
    parser.add_argument("--var-file", required=True, type=Path)
    parser.add_argument("--plan-json", type=Path)
    parser.add_argument("--registry", type=Path, default=REGISTRY_PATH)
    parser.add_argument(
        "--require-active",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "Require the selected region's registry allocation to be status=active "
            "(default). terraform.sh passes --no-require-active for destroy, which "
            "must accept a reserved allocation so a decommissioned region can still "
            "be torn down."
        ),
    )
    args = parser.parse_args()
    try:
        return check_region(args.region_id, args.var_file, args.plan_json, args.registry, args.require_active)
    except RuntimeError as exc:
        print(f"Terraform preflight failed for {args.region_id}.", file=sys.stderr)
        print("Refusing to continue because manual reconciliation is required.", file=sys.stderr)
        print("", file=sys.stderr)
        print(f"{args.region_id}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
