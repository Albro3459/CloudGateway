#!/usr/bin/env python3
"""Detect unmanaged or duplicate CloudGateway regional resources before Terraform runs."""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


INSTANCE_ADDRESS = "oci_core_instance.generated_oci_core_instance"
API_RECORD_ADDRESS = "cloudflare_record.api"
WG_RECORD_ADDRESS = "cloudflare_record.wg"

# WireGuard tunnel subnet fields an operator sets per region in tfvars (see
# terraform.tfvars.example). All six must be present and consistent for the
# cross-region subnet check below.
WG_SUBNET_KEYS = (
    "wg_network_v4",
    "wg_address_v4",
    "wg_dns_address_v4",
    "wg_network_v6",
    "wg_address_v6",
    "wg_dns_address_v6",
)

# Region N gets 10.0.N.0/24 / fd42:42:42:N::/64 (see terraform.tfvars.example). These
# aggregates are load-bearing, not documentation: the peer sync's route sweep on every
# host only reclaims `dev wg0` routes inside them, so a region configured outside an
# aggregate would strand routes the sweep can never clean up.
SUBNET_AGGREGATE_V4 = ipaddress.IPv4Network("10.0.0.0/16")
SUBNET_AGGREGATE_V6 = ipaddress.IPv6Network("fd42:42:42::/48")


def read_tfvars(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    heredoc_end: str | None = None

    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if heredoc_end is not None:
            if line == heredoc_end:
                heredoc_end = None
            continue
        if not line or line.startswith("#"):
            continue

        heredoc_match = re.match(r"^([A-Za-z0-9_]+)\s*=\s*<<([A-Za-z0-9_]+)\s*$", line)
        if heredoc_match:
            values[heredoc_match.group(1)] = ""
            heredoc_end = heredoc_match.group(2)
            continue

        quoted_match = re.match(r'^([A-Za-z0-9_]+)\s*=\s*"([^"]*)"\s*(?:#.*)?$', line)
        if quoted_match:
            values[quoted_match.group(1)] = quoted_match.group(2)
            continue

        bare_match = re.match(r"^([A-Za-z0-9_]+)\s*=\s*([^\s#]+)\s*(?:#.*)?$", line)
        if bare_match:
            values[bare_match.group(1)] = bare_match.group(2)

    return values


def required(values: dict[str, str], key: str, varfile: Path) -> str:
    value = values.get(key)
    if value is None or value == "":
        raise SystemExit(f"Missing required {key} in {varfile}")
    return value


def discover_sibling_tfvars(varfile: Path) -> tuple[dict[str, dict[str, str]], list[str]]:
    """Read every *.terraform.tfvars next to varfile (including varfile itself).

    Returns (region_id -> raw WG_SUBNET_KEYS values, skip notes). A sibling that fails to
    read or has no region_id is skipped with a note rather than failing the deploy; a
    sibling with a region_id is always included even if its subnet fields are incomplete,
    so evaluate_subnet_plan can turn that into a hard failure.
    """
    regions: dict[str, dict[str, str]] = {}
    notes: list[str] = []

    for sibling in sorted(varfile.parent.glob("*.terraform.tfvars")):
        try:
            values = read_tfvars(sibling)
        except OSError as exc:
            notes.append(f"skipping {sibling.name}: failed to read tfvars ({exc})")
            continue

        region_id = values.get("region_id")
        if not region_id:
            notes.append(f"skipping {sibling.name}: no region_id found")
            continue

        regions[region_id] = {key: values.get(key, "") for key in WG_SUBNET_KEYS}

    return regions, notes


def _parse_subnet_network_v4(region_id: str, key: str, raw: str, errors: list[str]) -> ipaddress.IPv4Network | None:
    try:
        network = ipaddress.ip_network(raw, strict=True)
    except ValueError as exc:
        errors.append(f"{region_id}: {key} {raw!r} is not a valid network with no host bits set ({exc}).")
        return None
    if not isinstance(network, ipaddress.IPv4Network):
        errors.append(f"{region_id}: {key} {raw!r} must be an IPv4 network, got IPv{network.version}.")
        return None
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
    return network


def _check_subnet_address(
    region_id: str,
    key: str,
    raw: str,
    network: ipaddress.IPv4Network | ipaddress.IPv6Network,
    errors: list[str],
) -> None:
    try:
        address = ipaddress.ip_interface(raw).ip if "/" in raw else ipaddress.ip_address(raw)
    except ValueError as exc:
        errors.append(f"{region_id}: {key} {raw!r} is not a valid IP address ({exc}).")
        return
    if address.version != network.version:
        errors.append(f"{region_id}: {key} {raw!r} is IPv{address.version} but its network is IPv{network.version}.")
        return
    if address not in network:
        errors.append(f"{region_id}: {key} {address} is not inside its own network {network}.")


def _parse_region_subnets(
    region_id: str, values: dict[str, str]
) -> tuple[list[str], tuple[ipaddress.IPv4Network, ipaddress.IPv6Network] | None]:
    errors: list[str] = []
    missing = [key for key in WG_SUBNET_KEYS if not values.get(key)]
    if missing:
        errors.append(
            f"{region_id}: missing {', '.join(missing)} in tfvars; every region's WireGuard subnet fields "
            "must be complete for the cross-region subnet check to run."
        )
        return errors, None

    network_v4 = _parse_subnet_network_v4(region_id, "wg_network_v4", values["wg_network_v4"], errors)
    network_v6 = _parse_subnet_network_v6(region_id, "wg_network_v6", values["wg_network_v6"], errors)

    if network_v4 is not None:
        if not network_v4.subnet_of(SUBNET_AGGREGATE_V4):
            errors.append(
                f"{region_id}: wg_network_v4 {network_v4} is outside the shared aggregate {SUBNET_AGGREGATE_V4}; "
                "the peer sync's route sweep on other hosts only reclaims dev wg0 routes inside this aggregate, "
                "so a region outside it would strand routes."
            )
        _check_subnet_address(region_id, "wg_address_v4", values["wg_address_v4"], network_v4, errors)
        _check_subnet_address(region_id, "wg_dns_address_v4", values["wg_dns_address_v4"], network_v4, errors)

    if network_v6 is not None:
        if not network_v6.subnet_of(SUBNET_AGGREGATE_V6):
            errors.append(
                f"{region_id}: wg_network_v6 {network_v6} is outside the shared aggregate {SUBNET_AGGREGATE_V6}; "
                "the peer sync's route sweep on other hosts only reclaims dev wg0 routes inside this aggregate, "
                "so a region outside it would strand routes."
            )
        _check_subnet_address(region_id, "wg_address_v6", values["wg_address_v6"], network_v6, errors)
        _check_subnet_address(region_id, "wg_dns_address_v6", values["wg_dns_address_v6"], network_v6, errors)

    if network_v4 is None or network_v6 is None:
        return errors, None
    return errors, (network_v4, network_v6)


def evaluate_subnet_plan(regions: dict[str, dict[str, str]]) -> list[str]:
    """Pure cross-region subnet containment/overlap check.

    `regions` maps region_id -> a dict that should carry WG_SUBNET_KEYS (raw tfvars
    strings). Takes only parsed values, no filesystem or network access, so it stays
    unit-testable. Returns human-readable error strings; empty means the plan is clean.
    """
    errors: list[str] = []
    networks: dict[str, tuple[ipaddress.IPv4Network, ipaddress.IPv6Network]] = {}

    for region_id, values in sorted(regions.items()):
        region_errors, parsed = _parse_region_subnets(region_id, values)
        errors.extend(region_errors)
        if parsed is not None:
            networks[region_id] = parsed

    region_ids = sorted(networks)
    for i, a_id in enumerate(region_ids):
        a_v4, a_v6 = networks[a_id]
        for b_id in region_ids[i + 1 :]:
            b_v4, b_v6 = networks[b_id]
            if a_v4.overlaps(b_v4):
                errors.append(
                    f"{a_id} and {b_id}: wg_network_v4 {a_v4} and {b_v4} overlap; each region needs a "
                    "unique, non-overlapping IPv4 tunnel subnet."
                )
            if a_v6.overlaps(b_v6):
                errors.append(
                    f"{a_id} and {b_id}: wg_network_v6 {a_v6} and {b_v6} overlap; each region needs a "
                    "unique, non-overlapping IPv6 tunnel subnet."
                )

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


def check_region(region_id: str, varfile: Path, plan_json_path: Path | None) -> int:
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

    sibling_regions, skip_notes = discover_sibling_tfvars(varfile)
    for note in skip_notes:
        print(f"==> preflight note: {note}")
    subnet_errors = evaluate_subnet_plan(sibling_regions)
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
    args = parser.parse_args()
    try:
        return check_region(args.region_id, args.var_file, args.plan_json)
    except RuntimeError as exc:
        print(f"Terraform preflight failed for {args.region_id}.", file=sys.stderr)
        print("Refusing to continue because manual reconciliation is required.", file=sys.stderr)
        print("", file=sys.stderr)
        print(f"{args.region_id}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
