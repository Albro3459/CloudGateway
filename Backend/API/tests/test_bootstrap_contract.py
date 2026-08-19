"""Offline contract check between Infrastructure/OCI/host/bootstrap.sh's base
nftables ruleset and the API's policy layer (src/policy.py).

This is the check TODO/account-scoped-acl.md finding 12 required:
until this module existed, nothing read or validated the bootstrap ruleset,
so the claim that renaming a bootstrap object "fails the build" was false. A
rename on EITHER side - bootstrap.sh or src/policy.py - must fail a test in
this module. No `nft` binary, network, or live host is used; everything here
parses bootstrap.sh's source text directly.

The nft heredoc in bootstrap.sh is unquoted (it interpolates $WG_INTERFACE at
apply time), so the parser below tolerates runtime shell placeholders inside
rule lines without trying to resolve them - it only checks structure and
object-name references.
"""

import re
from dataclasses import dataclass
from pathlib import Path

import pytest

from src.policy import (
    POLICY_CHAIN,
    POLICY_TABLE,
    _FAMILY_OBJECT_NAMES,
    PolicyRow,
    render_client_row_script,
    render_policy_script,
)
from src.wireguard import MESH_AGGREGATE_V4, MESH_AGGREGATE_V6

BOOTSTRAP_PATH = Path(__file__).resolve().parents[3] / "Infrastructure" / "OCI" / "host" / "bootstrap.sh"

_HEREDOC_RE = re.compile(
    r"cat > /etc/cloudgateway/cloudgateway\.nft <<NFTCONF\n(?P<body>.*?)\nNFTCONF\n",
    re.DOTALL,
)
_TABLE_RE = re.compile(r"\Atable inet (?P<name>\S+) \{\n(?P<body>.*)\n\}\s*\Z", re.DOTALL)
_OBJECT_LINE_RE = re.compile(r"\A\t(?P<kind>set|map) (?P<name>cg_\w+) \{ (?P<decl>.*) \}\Z")
_CHAIN_START_RE = re.compile(r"\A\tchain (?P<name>\S+) \{\Z")
_CHAIN_END_LINE = "\t}"

_POSTUP_RE = re.compile(r"^PostUp = nft -f (\S+)$", re.MULTILINE)
_POSTDOWN_RE = re.compile(r"^PostDown = nft delete table inet (\S+) \|\| true$", re.MULTILINE)
_GATE_TABLE_RE = re.compile(r"nft list table inet (\S+)")
_GATE_CHAIN_RE = re.compile(r"grep -q 'chain (\S+)'")
_GATE_MAP_RE = re.compile(r"grep -q 'map (\S+)'")

_ROLES = ("tunnel", "infra", "admin", "slot", "pairs")
_VERSIONS = (4, 6)


# --- parsing -----------------------------------------------------------------


@dataclass(frozen=True)
class NftObjectSpec:
    kind: str  # "set" or "map", exactly as declared in bootstrap.sh
    declaration: str  # raw text between the outer { } of the declaration


@dataclass(frozen=True)
class BootstrapRuleset:
    table_name: str
    objects: dict[str, NftObjectSpec]
    chain_name: str
    chain_hook_line: str
    chain_rules: tuple[str, ...]  # chain body lines, hook line excluded


@dataclass(frozen=True)
class GateStrings:
    table_name: str
    chain_name: str
    map_names: tuple[str, ...]


def _read_bootstrap_source() -> str:
    if not BOOTSTRAP_PATH.is_file():
        raise AssertionError(f"bootstrap.sh not found at {BOOTSTRAP_PATH}; contract check cannot run")
    return BOOTSTRAP_PATH.read_text()


def _extract_nft_heredoc(source: str) -> str:
    match = _HEREDOC_RE.search(source)
    if not match:
        raise AssertionError(
            "bootstrap.sh: could not locate the "
            "`cat > /etc/cloudgateway/cloudgateway.nft <<NFTCONF ... NFTCONF` heredoc"
        )
    return match.group("body")


def _parse_ruleset(heredoc_body: str) -> BootstrapRuleset:
    table_match = _TABLE_RE.match(heredoc_body)
    if not table_match:
        raise AssertionError("bootstrap.sh: could not parse `table inet <name> { ... }` from the nft heredoc")
    table_name = table_match.group("name")
    body_lines = table_match.group("body").split("\n")

    objects: dict[str, NftObjectSpec] = {}
    chain_name: str | None = None
    chain_rules_raw: list[str] = []

    index = 0
    while index < len(body_lines):
        line = body_lines[index]
        object_match = _OBJECT_LINE_RE.match(line)
        if object_match:
            name = object_match.group("name")
            if name in objects:
                raise AssertionError(f"bootstrap.sh: duplicate nft object {name!r} in the heredoc")
            objects[name] = NftObjectSpec(kind=object_match.group("kind"), declaration=object_match.group("decl"))
            index += 1
            continue

        chain_match = _CHAIN_START_RE.match(line)
        if chain_match:
            if chain_name is not None:
                raise AssertionError("bootstrap.sh: more than one chain in the nft heredoc")
            chain_name = chain_match.group("name")
            index += 1
            while index < len(body_lines) and body_lines[index] != _CHAIN_END_LINE:
                rule_line = body_lines[index]
                if not rule_line.startswith("\t\t"):
                    raise AssertionError(f"bootstrap.sh: unexpected chain body line: {rule_line!r}")
                chain_rules_raw.append(rule_line[2:])
                index += 1
            if index >= len(body_lines):
                raise AssertionError("bootstrap.sh: chain block never closes in the nft heredoc")
            index += 1  # skip the closing "\t}"
            continue

        raise AssertionError(f"bootstrap.sh: unrecognized line in the nft heredoc: {line!r}")

    if chain_name is None or not chain_rules_raw:
        raise AssertionError("bootstrap.sh: no chain found in the nft heredoc")

    hook_line, *rule_lines = chain_rules_raw
    return BootstrapRuleset(
        table_name=table_name,
        objects=objects,
        chain_name=chain_name,
        chain_hook_line=hook_line,
        chain_rules=tuple(rule_lines),
    )


def _parse_gate(source: str) -> GateStrings:
    table_match = _GATE_TABLE_RE.search(source)
    chain_match = _GATE_CHAIN_RE.search(source)
    map_names = tuple(_GATE_MAP_RE.findall(source))
    if not table_match or not chain_match or not map_names:
        raise AssertionError(
            "bootstrap.sh: could not find the cloudgateway-install-api rollout gate's grep checks"
        )
    return GateStrings(table_name=table_match.group(1), chain_name=chain_match.group(1), map_names=map_names)


def _tunnel_elements(spec: NftObjectSpec) -> tuple[str, ...]:
    match = re.search(r"elements = \{ (?P<elements>.*) \}", spec.declaration)
    if not match:
        raise AssertionError(f"bootstrap.sh: tunnel object missing `elements = {{ ... }}`: {spec.declaration!r}")
    return tuple(part.strip() for part in match.group("elements").split(","))


# --- reusable, raising assertion helpers (shared by positive + negative tests) ----


def _expected_object_names() -> set[str]:
    return {name for family in _FAMILY_OBJECT_NAMES.values() for name in family.values()}


def _assert_every_expected_object_declared(ruleset: BootstrapRuleset) -> None:
    missing = _expected_object_names() - set(ruleset.objects)
    assert not missing, f"bootstrap.sh is missing nft objects the policy layer expects: {sorted(missing)}"


def _assert_every_declared_object_known(ruleset: BootstrapRuleset) -> None:
    extra = set(ruleset.objects) - _expected_object_names()
    assert not extra, f"bootstrap.sh declares nft objects the policy layer does not know about: {sorted(extra)}"


def _assert_object_kind(role: str, version: int, spec: NftObjectSpec) -> None:
    family_type = "ipv4_addr" if version == 4 else "ipv6_addr"
    decl = spec.declaration.strip()
    if role == "tunnel":
        assert spec.kind == "set", f"cg_tunnel{version} must be a set, found {spec.kind!r}"
        assert "flags interval" in decl, f"cg_tunnel{version} must be an interval set: {decl!r}"
        assert re.search(rf"\btype {family_type}\b", decl), f"cg_tunnel{version} wrong element type: {decl!r}"
    elif role in ("infra", "admin"):
        assert spec.kind == "set", f"{role}{version} must be a set, found {spec.kind!r}"
        assert decl == f"type {family_type};", f"{role}{version} unexpected declaration: {decl!r}"
    elif role == "slot":
        assert spec.kind == "map", f"cg_slot{version} must be a map, found {spec.kind!r}"
        assert decl == f"type {family_type} : mark;", f"cg_slot{version} unexpected declaration: {decl!r}"
    elif role == "pairs":
        assert spec.kind == "set", f"cg_pairs{version} must be a set, found {spec.kind!r}"
        ip_keyword = "ip" if version == 4 else "ip6"
        assert decl == f"typeof {ip_keyword} daddr . meta mark;", f"cg_pairs{version} unexpected declaration: {decl!r}"
    else:  # pragma: no cover - exhaustive over _ROLES
        raise AssertionError(f"unknown role {role!r}")


def _assert_tunnel_aggregate(ruleset: BootstrapRuleset, version: int) -> None:
    name = _FAMILY_OBJECT_NAMES[version]["tunnel"]
    elements = _tunnel_elements(ruleset.objects[name])
    expected = MESH_AGGREGATE_V4 if version == 4 else MESH_AGGREGATE_V6
    assert elements == (expected,), f"{name} elements {elements} != expected ({expected!r},)"


def _assert_terminal_drop_rule_present(ruleset: BootstrapRuleset, version: int) -> None:
    tunnel = _FAMILY_OBJECT_NAMES[version]["tunnel"]
    pairs = _FAMILY_OBJECT_NAMES[version]["pairs"]
    ip_keyword = "ip" if version == 4 else "ip6"
    matches = [
        line
        for line in ruleset.chain_rules
        if f"{ip_keyword} daddr @{tunnel}" in line
        and f"{ip_keyword} daddr . meta mark != @{pairs}" in line
        and line.rstrip().endswith("drop")
    ]
    assert matches, f"missing terminal drop rule referencing @{tunnel} and @{pairs} for family {version}"


def _rule_index(ruleset: BootstrapRuleset, predicate) -> int:
    for position, line in enumerate(ruleset.chain_rules):
        if predicate(line):
            return position
    raise AssertionError("no chain rule matched the predicate")


def _assert_rule_ordering(ruleset: BootstrapRuleset) -> None:
    """Rule order is load-bearing, not cosmetic: nft evaluates a chain top to
    bottom, so the mark assignment must run before the terminal drops (a drop
    evaluated against an unassigned mark would deny every in-aggregate
    destination), and the infra/admin accepts must precede them too (drop is
    terminal, so a drop placed first would deny the admin proxy path). Both
    reorderings fail closed rather than open, but both break the boundary."""
    drop_positions = [
        _rule_index(
            ruleset,
            lambda line, version=version: (
                f"daddr @{_FAMILY_OBJECT_NAMES[version]['tunnel']}" in line
                and f"@{_FAMILY_OBJECT_NAMES[version]['pairs']}" in line
                and line.rstrip().endswith("drop")
            ),
        )
        for version in _VERSIONS
    ]
    first_drop = min(drop_positions)

    for version in _VERSIONS:
        ip_keyword = "ip" if version == 4 else "ip6"
        slot = _FAMILY_OBJECT_NAMES[version]["slot"]
        mark_position = _rule_index(ruleset, lambda line, e=f"meta mark set {ip_keyword} saddr map @{slot}": line == e)
        assert mark_position < first_drop, (
            f"the cg_slot{version} mark assignment must precede the terminal drop rules"
        )

        infra = _FAMILY_OBJECT_NAMES[version]["infra"]
        admin = _FAMILY_OBJECT_NAMES[version]["admin"]
        for source_set, destination_set in ((infra, admin), (admin, infra)):
            accept_position = _rule_index(
                ruleset,
                lambda line, s=source_set, d=destination_set: (
                    f"saddr @{s}" in line and f"daddr @{d}" in line and line.rstrip().endswith("accept")
                ),
            )
            assert accept_position < first_drop, (
                f"the @{source_set} -> @{destination_set} accept must precede the terminal drop rules"
            )


# --- fixtures ------------------------------------------------------------


@pytest.fixture(scope="session")
def bootstrap_source() -> str:
    return _read_bootstrap_source()


@pytest.fixture(scope="session")
def heredoc_text(bootstrap_source: str) -> str:
    return _extract_nft_heredoc(bootstrap_source)


@pytest.fixture(scope="session")
def ruleset(heredoc_text: str) -> BootstrapRuleset:
    return _parse_ruleset(heredoc_text)


# --- 1. table name ---------------------------------------------------------


def test_table_name_matches_policy_table(ruleset: BootstrapRuleset) -> None:
    assert ruleset.table_name == POLICY_TABLE


# --- 2. chain name and hook -------------------------------------------------


def test_chain_name_matches_policy_chain(ruleset: BootstrapRuleset) -> None:
    assert ruleset.chain_name == POLICY_CHAIN


def test_chain_hook_is_forward_priority_minus_10_policy_accept(ruleset: BootstrapRuleset) -> None:
    assert ruleset.chain_hook_line == "type filter hook forward priority -10; policy accept;"


# --- 3 & 6. object names, both directions, both address families -----------


def test_every_expected_object_name_is_declared(ruleset: BootstrapRuleset) -> None:
    _assert_every_expected_object_declared(ruleset)


def test_every_declared_cg_object_is_known_to_the_policy_layer(ruleset: BootstrapRuleset) -> None:
    _assert_every_declared_object_known(ruleset)


@pytest.mark.parametrize("role", _ROLES)
def test_both_address_families_present_for_every_logical_object(ruleset: BootstrapRuleset, role: str) -> None:
    for version in _VERSIONS:
        name = _FAMILY_OBJECT_NAMES[version][role]
        assert name in ruleset.objects, f"{name} not declared in bootstrap.sh"


# --- 4. object kinds/types match what the renderer assumes -----------------


@pytest.mark.parametrize("role", _ROLES)
@pytest.mark.parametrize("version", _VERSIONS)
def test_object_declaration_matches_expected_kind(ruleset: BootstrapRuleset, role: str, version: int) -> None:
    name = _FAMILY_OBJECT_NAMES[version][role]
    _assert_object_kind(role, version, ruleset.objects[name])


def test_render_policy_script_flushes_every_set_and_map_the_ruleset_declares_for_those_roles(
    ruleset: BootstrapRuleset,
) -> None:
    script = render_policy_script([])
    for role in ("infra", "admin", "pairs"):
        for version in _VERSIONS:
            name = _FAMILY_OBJECT_NAMES[version][role]
            assert ruleset.objects[name].kind == "set"
            assert f"flush set inet {POLICY_TABLE} {name}\n" in script
    for version in _VERSIONS:
        name = _FAMILY_OBJECT_NAMES[version]["slot"]
        assert ruleset.objects[name].kind == "map"
        assert f"flush map inet {POLICY_TABLE} {name}\n" in script


def test_render_policy_script_never_flushes_or_writes_the_tunnel_aggregate(ruleset: BootstrapRuleset) -> None:
    script = render_policy_script([])
    for version in _VERSIONS:
        tunnel_name = _FAMILY_OBJECT_NAMES[version]["tunnel"]
        assert tunnel_name not in script, f"render_policy_script must never touch {tunnel_name} (bootstrap owns it)"


def test_render_client_row_script_only_names_objects_that_exist(ruleset: BootstrapRuleset) -> None:
    row = PolicyRow(address_v4="10.0.0.9", address_v6="fd42:42:42::9", slot=9, admin=True)
    script = render_client_row_script(row)
    referenced = set(re.findall(r"cg_\w+", script))
    assert referenced, "expected at least one cg_* reference in the rendered script"
    unknown = referenced - set(ruleset.objects)
    assert not unknown, f"render_client_row_script named unknown object(s): {sorted(unknown)}"
    tunnel_names = {_FAMILY_OBJECT_NAMES[4]["tunnel"], _FAMILY_OBJECT_NAMES[6]["tunnel"]}
    infra_names = {_FAMILY_OBJECT_NAMES[4]["infra"], _FAMILY_OBJECT_NAMES[6]["infra"]}
    assert not referenced & tunnel_names, "render_client_row_script must never touch cg_tunnel4/6"
    assert not referenced & infra_names, "render_client_row_script must never touch cg_infra4/6"


# --- 5. tunnel aggregates ----------------------------------------------------


@pytest.mark.parametrize("version", _VERSIONS)
def test_tunnel_aggregate_matches_mesh_aggregate(ruleset: BootstrapRuleset, version: int) -> None:
    _assert_tunnel_aggregate(ruleset, version)


# --- 7. both rule families --------------------------------------------------


@pytest.mark.parametrize("version", _VERSIONS)
def test_chain_has_infra_admin_accept_rules_both_directions(ruleset: BootstrapRuleset, version: int) -> None:
    infra = _FAMILY_OBJECT_NAMES[version]["infra"]
    admin = _FAMILY_OBJECT_NAMES[version]["admin"]
    ip_keyword = "ip" if version == 4 else "ip6"
    forward = f"{ip_keyword} saddr @{infra} {ip_keyword} daddr @{admin} accept"
    reverse = f"{ip_keyword} saddr @{admin} {ip_keyword} daddr @{infra} accept"
    assert any(forward in line for line in ruleset.chain_rules), f"missing rule: {forward}"
    assert any(reverse in line for line in ruleset.chain_rules), f"missing rule: {reverse}"


@pytest.mark.parametrize("version", _VERSIONS)
def test_chain_assigns_mark_from_the_slot_map(ruleset: BootstrapRuleset, version: int) -> None:
    slot = _FAMILY_OBJECT_NAMES[version]["slot"]
    ip_keyword = "ip" if version == 4 else "ip6"
    expected = f"meta mark set {ip_keyword} saddr map @{slot}"
    assert any(line == expected for line in ruleset.chain_rules), f"missing mark assignment: {expected}"


@pytest.mark.parametrize("version", _VERSIONS)
def test_chain_terminal_drop_rule_present(ruleset: BootstrapRuleset, version: int) -> None:
    _assert_terminal_drop_rule_present(ruleset, version)


def test_chain_rule_ordering_puts_mark_assignment_and_accepts_before_the_drops(ruleset: BootstrapRuleset) -> None:
    _assert_rule_ordering(ruleset)


def test_chain_starts_by_accepting_established_and_related_traffic(ruleset: BootstrapRuleset) -> None:
    # Return traffic for an already-permitted flow must never re-evaluate the
    # slot comparison, so this stays the first rule in the chain.
    assert ruleset.chain_rules[0] == "ct state established,related accept"


def test_every_at_reference_in_the_chain_names_an_object_that_exists(ruleset: BootstrapRuleset) -> None:
    referenced: set[str] = set()
    for line in (ruleset.chain_hook_line, *ruleset.chain_rules):
        referenced.update(re.findall(r"@(cg_\w+)", line))
    assert referenced, "expected at least one @cg_* reference in the chain"
    unknown = referenced - set(ruleset.objects)
    assert not unknown, f"chain references unknown object(s): {sorted(unknown)}"


# --- 8. PostUp/PostDown wiring -----------------------------------------------


def test_postup_loads_the_ruleset_via_nft_dash_f(bootstrap_source: str) -> None:
    match = _POSTUP_RE.search(bootstrap_source)
    assert match, "bootstrap.sh: no `PostUp = nft -f <path>` line found"
    assert match.group(1) == "/etc/cloudgateway/cloudgateway.nft"


def test_postdown_deletes_the_same_table_postup_loads(bootstrap_source: str, ruleset: BootstrapRuleset) -> None:
    match = _POSTDOWN_RE.search(bootstrap_source)
    assert match, "bootstrap.sh: no `PostDown = nft delete table inet <name> || true` line found"
    assert match.group(1) == ruleset.table_name == POLICY_TABLE


# --- 9. cloudgateway-install-api gate ----------------------------------------


def test_install_api_gate_greps_agree_with_policy_table_chain_and_slot_maps(
    bootstrap_source: str, ruleset: BootstrapRuleset
) -> None:
    gate = _parse_gate(bootstrap_source)
    assert gate.table_name == POLICY_TABLE == ruleset.table_name
    assert gate.chain_name == POLICY_CHAIN == ruleset.chain_name
    expected_slot_names = {_FAMILY_OBJECT_NAMES[4]["slot"], _FAMILY_OBJECT_NAMES[6]["slot"]}
    assert set(gate.map_names) == expected_slot_names


# --- negative tests: prove the parser/assertions above actually bite -------
#
# Each test mutates an in-memory copy of the real heredoc text (never the
# file on disk) and re-parses it, then reuses the exact assertion helper the
# corresponding positive test above calls. If any of these stopped raising,
# the positive test it mirrors would no longer be a real contract check.


def test_negative_renamed_object_is_caught_by_the_name_contract(heredoc_text: str) -> None:
    mutated_text = heredoc_text.replace("set cg_admin6 { type ipv6_addr; }", "set cg_admin6x { type ipv6_addr; }", 1)
    mutated = _parse_ruleset(mutated_text)
    with pytest.raises(AssertionError):
        _assert_every_expected_object_declared(mutated)


def test_negative_unknown_extra_object_is_caught_by_the_reverse_name_contract(heredoc_text: str) -> None:
    mutated_text = heredoc_text.replace(
        "\tset cg_admin6 { type ipv6_addr; }\n",
        "\tset cg_admin6 { type ipv6_addr; }\n\tset cg_bogus4 { type ipv4_addr; }\n",
        1,
    )
    mutated = _parse_ruleset(mutated_text)
    with pytest.raises(AssertionError):
        _assert_every_declared_object_known(mutated)


def test_negative_slot_map_flipped_to_a_set_is_caught_by_the_kind_check(heredoc_text: str) -> None:
    mutated_text = heredoc_text.replace(
        "map cg_slot4 { type ipv4_addr : mark; }", "set cg_slot4 { type ipv4_addr : mark; }", 1
    )
    mutated = _parse_ruleset(mutated_text)
    with pytest.raises(AssertionError):
        _assert_object_kind("slot", 4, mutated.objects["cg_slot4"])


def test_negative_changed_tunnel_aggregate_is_caught(heredoc_text: str) -> None:
    mutated_text = heredoc_text.replace("elements = { 10.0.0.0/16 }", "elements = { 10.0.0.0/8 }", 1)
    mutated = _parse_ruleset(mutated_text)
    with pytest.raises(AssertionError):
        _assert_tunnel_aggregate(mutated, 4)


def test_negative_missing_v6_drop_rule_is_caught(heredoc_text: str) -> None:
    lines = heredoc_text.split("\n")
    kept = [line for line in lines if "ip6 daddr @cg_tunnel6" not in line]
    mutated = _parse_ruleset("\n".join(kept))
    with pytest.raises(AssertionError):
        _assert_terminal_drop_rule_present(mutated, 6)


def test_negative_mark_assignment_moved_after_the_drops_is_caught_by_the_ordering_check(heredoc_text: str) -> None:
    lines = heredoc_text.split("\n")
    mark_lines = [line for line in lines if "meta mark set" in line]
    assert mark_lines, "expected mark assignment lines in the real ruleset"
    kept = [line for line in lines if "meta mark set" not in line]
    closing = max(position for position, line in enumerate(kept) if line == "\t}")
    reordered = kept[:closing] + mark_lines + kept[closing:]
    mutated = _parse_ruleset("\n".join(reordered))
    with pytest.raises(AssertionError):
        _assert_rule_ordering(mutated)
