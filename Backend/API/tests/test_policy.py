import json
import subprocess
from dataclasses import dataclass, replace

import pytest

from src.errors import PolicyApplyFailedError, SyncInProgressError
from src.policy import (
    MAX_SLOT,
    MIN_SLOT,
    POLICY_TABLE,
    LivePolicyFamily,
    LocalPolicyManager,
    PolicyRow,
    hash_policy_family,
    render_client_row_script,
    render_policy_script,
)

# The literal table name is the contract with the base ruleset installed by
# bootstrap.sh (`table inet cloudgateway { ... }`); if POLICY_TABLE is ever
# renamed, that file must be updated in lockstep.
assert POLICY_TABLE == "cloudgateway"


@dataclass(frozen=True)
class FakeCommandCall:
    args: tuple[str, ...]
    input: str | None
    shell: bool
    timeout: float | None


def _obj(kind: str, name: str, elem: list | None = None) -> dict:
    obj: dict = {"family": "inet", "name": name, "table": "cloudgateway"}
    if elem is not None:
        obj["elem"] = elem
    return {kind: obj}


def make_table_json(overrides: dict | None = None) -> str:
    """Builds a realistic `nft -j list table inet cloudgateway` payload with
    sample content in every one of the ten named objects. `overrides` maps an
    object name to a replacement entry dict, or to None to omit that object
    entirely (simulating a missing object) - used to test malformed/missing
    shapes without rebuilding the whole payload each time."""
    entries = [
        {"metainfo": {"version": "1.0.9"}},
        {"table": {"family": "inet", "name": "cloudgateway"}},
        _obj("set", "cg_tunnel4", [{"prefix": {"addr": "10.0.0.0", "len": 16}}]),
        _obj("set", "cg_tunnel6", [{"prefix": {"addr": "fd42:42:42::", "len": 48}}]),
        _obj("set", "cg_infra4", ["10.0.0.1"]),
        _obj("set", "cg_infra6", ["fd42:42:42::1"]),
        _obj("set", "cg_admin4", ["10.0.0.2"]),
        _obj("set", "cg_admin6", ["fd42:42:42::2"]),
        _obj("map", "cg_slot4", [["10.0.0.2", 1], ["10.0.0.3", 2]]),
        _obj("map", "cg_slot6", [["fd42:42:42::2", 1], ["fd42:42:42::3", 2]]),
        _obj("set", "cg_pairs4", [{"concat": ["10.0.0.2", 1]}, {"concat": ["10.0.0.3", 2]}]),
        _obj("set", "cg_pairs6", [{"concat": ["fd42:42:42::2", 1]}, {"concat": ["fd42:42:42::3", 2]}]),
    ]
    if overrides:
        replaced: list[dict] = []
        for entry in entries:
            obj = entry.get("set") or entry.get("map")
            name = obj.get("name") if isinstance(obj, dict) else None
            if name in overrides:
                replacement = overrides[name]
                if replacement is not None:
                    replaced.append(replacement)
                continue
            replaced.append(entry)
        entries = replaced
    return json.dumps({"nftables": entries})


class FakePolicyCommandRunner:
    """Emulates the `nft` CLI surface LocalPolicyManager drives: `nft -f -` for
    script application and one `nft -j list table inet cloudgateway` for
    read-back (a single call covering every named object, not one per set/map)."""

    def __init__(
        self,
        *,
        table_json: str = "",
        fail_apply: bool = False,
        timeout_apply: bool = False,
        fail_read: bool = False,
        timeout_read: bool = False,
        failure_stderr: str = "simulated nft failure",
    ):
        self.calls: list[FakeCommandCall] = []
        self.table_json = table_json or make_table_json()
        self.fail_apply = fail_apply
        self.timeout_apply = timeout_apply
        self.fail_read = fail_read
        self.timeout_read = timeout_read
        self.failure_stderr = failure_stderr

    def __call__(
        self,
        args,
        *,
        input: str | None = None,
        capture_output: bool = False,
        text: bool = False,
        check: bool = False,
        shell: bool = False,
        timeout: float | None = None,
    ) -> subprocess.CompletedProcess[str]:
        del capture_output, text, check
        if shell is not False:
            raise AssertionError("nft commands must run with shell=False.")
        if timeout is None:
            raise AssertionError("nft commands must run with an explicit timeout.")

        argv: tuple[str, ...] = tuple(args)
        self.calls.append(FakeCommandCall(args=argv, input=input, shell=shell, timeout=timeout))

        if argv == ("nft", "-f", "-"):
            if self.timeout_apply:
                raise subprocess.TimeoutExpired(list(argv), timeout)
            if self.fail_apply:
                raise subprocess.CalledProcessError(1, list(argv), stderr=self.failure_stderr)
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        if argv == ("nft", "-j", "list", "table", "inet", POLICY_TABLE):
            if self.timeout_read:
                raise subprocess.TimeoutExpired(list(argv), timeout)
            if self.fail_read:
                raise subprocess.CalledProcessError(1, list(argv), stderr=self.failure_stderr)
            return subprocess.CompletedProcess(argv, 0, stdout=self.table_json, stderr="")

        raise AssertionError(f"Unexpected policy command: {argv}")


def make_manager(tmp_path, runner, *, lock_path=None):
    return LocalPolicyManager(
        lock_path=lock_path or str(tmp_path / "cloudgateway-policy.lock"),
        command_runner=runner,
    )


# --- render_policy_script ---------------------------------------------------


def test_render_policy_script_exact_text_for_multi_row_set():
    admin_row = PolicyRow(address_v4="10.0.0.2", address_v6="fd42:42:42::2", slot=1, admin=True)
    plain_row = PolicyRow(address_v4="10.0.0.3", address_v6="fd42:42:42::3", slot=2, admin=False)

    script = render_policy_script(
        [plain_row, admin_row],
        infra_v4=["10.0.0.1"],
        infra_v6=["fd42:42:42::1"],
    )

    assert script == (
        "flush set inet cloudgateway cg_infra4\n"
        "flush set inet cloudgateway cg_infra6\n"
        "flush set inet cloudgateway cg_admin4\n"
        "flush set inet cloudgateway cg_admin6\n"
        "flush set inet cloudgateway cg_pairs4\n"
        "flush set inet cloudgateway cg_pairs6\n"
        "flush map inet cloudgateway cg_slot4\n"
        "flush map inet cloudgateway cg_slot6\n"
        "add element inet cloudgateway cg_infra4 { 10.0.0.1 }\n"
        "add element inet cloudgateway cg_infra6 { fd42:42:42::1 }\n"
        "add element inet cloudgateway cg_admin4 { 10.0.0.2 }\n"
        "add element inet cloudgateway cg_admin6 { fd42:42:42::2 }\n"
        "add element inet cloudgateway cg_slot4 { 10.0.0.2 : 0x00000001, 10.0.0.3 : 0x00000002 }\n"
        "add element inet cloudgateway cg_slot6 { fd42:42:42::2 : 0x00000001, fd42:42:42::3 : 0x00000002 }\n"
        "add element inet cloudgateway cg_pairs4 { 10.0.0.2 . 0x00000001, 10.0.0.3 . 0x00000002 }\n"
        "add element inet cloudgateway cg_pairs6 { fd42:42:42::2 . 0x00000001, fd42:42:42::3 . 0x00000002 }\n"
    )


def test_render_policy_script_empty_rows_flushes_only_and_never_emits_empty_braces():
    script = render_policy_script([])

    assert script == (
        "flush set inet cloudgateway cg_infra4\n"
        "flush set inet cloudgateway cg_infra6\n"
        "flush set inet cloudgateway cg_admin4\n"
        "flush set inet cloudgateway cg_admin6\n"
        "flush set inet cloudgateway cg_pairs4\n"
        "flush set inet cloudgateway cg_pairs6\n"
        "flush map inet cloudgateway cg_slot4\n"
        "flush map inet cloudgateway cg_slot6\n"
    )
    assert "{ }" not in script
    assert "add element" not in script


def test_render_policy_script_admin_rows_only_land_in_admin_sets():
    admin_row = PolicyRow(address_v4="10.0.0.2", address_v6="fd42:42:42::2", slot=1, admin=True)
    plain_row = PolicyRow(address_v4="10.0.0.3", address_v6="fd42:42:42::3", slot=2, admin=False)

    script = render_policy_script([admin_row, plain_row])

    admin4_line = next(line for line in script.splitlines() if line.startswith("add element inet cloudgateway cg_admin4"))
    admin6_line = next(line for line in script.splitlines() if line.startswith("add element inet cloudgateway cg_admin6"))
    assert admin4_line == "add element inet cloudgateway cg_admin4 { 10.0.0.2 }"
    assert admin6_line == "add element inet cloudgateway cg_admin6 { fd42:42:42::2 }"
    assert "10.0.0.3" not in admin4_line
    assert "fd42:42:42::3" not in admin6_line


def test_render_policy_script_never_emits_empty_braces_with_only_admin_rows_absent():
    # No admin rows at all: cg_admin4/6 flush but get no add element line.
    plain_row = PolicyRow(address_v4="10.0.0.3", address_v6="fd42:42:42::3", slot=2, admin=False)

    script = render_policy_script([plain_row])

    assert "cg_admin4 {" not in script
    assert "cg_admin6 {" not in script
    assert "{ }" not in script


def test_render_policy_script_deterministic_regardless_of_input_row_order():
    row_a = PolicyRow(address_v4="10.0.0.5", address_v6="fd42:42:42::5", slot=5)
    row_b = PolicyRow(address_v4="10.0.0.2", address_v6="fd42:42:42::2", slot=2)
    row_c = PolicyRow(address_v4="10.0.0.9", address_v6="fd42:42:42::9", slot=9)

    forward = render_policy_script([row_a, row_b, row_c])
    reversed_order = render_policy_script([row_c, row_b, row_a])
    shuffled = render_policy_script([row_b, row_c, row_a])

    assert forward == reversed_order == shuffled


# --- render_client_row_script / add_client_row ------------------------------


def test_render_client_row_script_without_admin():
    row = PolicyRow(address_v4="10.0.0.7", address_v6="fd42:42:42::7", slot=7, admin=False)

    script = render_client_row_script(row)

    assert script == (
        "add element inet cloudgateway cg_slot4 { 10.0.0.7 : 0x00000007 }\n"
        "add element inet cloudgateway cg_slot6 { fd42:42:42::7 : 0x00000007 }\n"
        "add element inet cloudgateway cg_pairs4 { 10.0.0.7 . 0x00000007 }\n"
        "add element inet cloudgateway cg_pairs6 { fd42:42:42::7 . 0x00000007 }\n"
    )


def test_render_client_row_script_with_admin():
    row = PolicyRow(address_v4="10.0.0.8", address_v6="fd42:42:42::8", slot=8, admin=True)

    script = render_client_row_script(row)

    assert script == (
        "add element inet cloudgateway cg_slot4 { 10.0.0.8 : 0x00000008 }\n"
        "add element inet cloudgateway cg_slot6 { fd42:42:42::8 : 0x00000008 }\n"
        "add element inet cloudgateway cg_pairs4 { 10.0.0.8 . 0x00000008 }\n"
        "add element inet cloudgateway cg_pairs6 { fd42:42:42::8 . 0x00000008 }\n"
        "add element inet cloudgateway cg_admin4 { 10.0.0.8 }\n"
        "add element inet cloudgateway cg_admin6 { fd42:42:42::8 }\n"
    )


def test_add_client_row_runs_nft_with_rendered_script_as_input(tmp_path):
    runner = FakePolicyCommandRunner()
    manager = make_manager(tmp_path, runner)
    row = PolicyRow(address_v4="10.0.0.9", address_v6="fd42:42:42::9", slot=9, admin=False)

    manager.add_client_row(row)

    assert len(runner.calls) == 1
    assert runner.calls[0].args == ("nft", "-f", "-")
    assert runner.calls[0].input == render_client_row_script(row)
    assert runner.calls[0].shell is False


def test_apply_map_runs_nft_with_rendered_script_as_input(tmp_path):
    runner = FakePolicyCommandRunner()
    manager = make_manager(tmp_path, runner)
    admin_row = PolicyRow(address_v4="10.0.0.2", address_v6="fd42:42:42::2", slot=1, admin=True)
    plain_row = PolicyRow(address_v4="10.0.0.3", address_v6="fd42:42:42::3", slot=2, admin=False)

    manager.apply_map([plain_row, admin_row], infra_v4=["10.0.0.1"], infra_v6=["fd42:42:42::1"])

    assert len(runner.calls) == 1
    assert runner.calls[0].args == ("nft", "-f", "-")
    assert runner.calls[0].input == render_policy_script(
        [plain_row, admin_row], infra_v4=["10.0.0.1"], infra_v6=["fd42:42:42::1"]
    )


# --- read_map: one `nft -j list table` call, all ten named objects ---------


def test_read_map_reads_the_whole_table_with_one_command(tmp_path):
    runner = FakePolicyCommandRunner()
    manager = make_manager(tmp_path, runner)

    manager.read_map()

    assert len(runner.calls) == 1
    assert runner.calls[0].args == ("nft", "-j", "list", "table", "inet", "cloudgateway")


def test_read_map_end_to_end_parses_every_object_sorts_and_hashes(tmp_path):
    runner = FakePolicyCommandRunner(table_json=make_table_json())
    manager = make_manager(tmp_path, runner)

    live_map = manager.read_map()

    assert live_map.v4.tunnel == ("10.0.0.0/16",)
    assert live_map.v4.infra == ("10.0.0.1",)
    assert live_map.v4.admin == ("10.0.0.2",)
    assert live_map.v4.slots == (("10.0.0.2", 1), ("10.0.0.3", 2))
    assert live_map.v4.pairs == (("10.0.0.2", 1), ("10.0.0.3", 2))
    assert live_map.v6.tunnel == ("fd42:42:42::/48",)
    assert live_map.row_count == 2
    assert live_map.hash_v4 == hash_policy_family(live_map.v4)
    assert live_map.hash_v6 == hash_policy_family(live_map.v6)
    assert live_map.hash_v4 != live_map.hash_v6


def test_read_map_wrapped_elem_and_val_forms_parse_the_same_as_bare(tmp_path):
    # Every element wrapped in {"elem": ...}, and scalar marks additionally
    # wrapped in {"val": ...} - both nft JSON quirks in one payload.
    wrapped = make_table_json(
        {
            "cg_infra4": _obj("set", "cg_infra4", [{"elem": "10.0.0.1"}]),
            "cg_slot4": _obj(
                "map",
                "cg_slot4",
                [
                    [{"elem": {"val": "10.0.0.5"}}, 3],
                    ["10.0.0.4", {"elem": {"val": 4}}],
                ],
            ),
            "cg_pairs4": _obj(
                "set",
                "cg_pairs4",
                [{"elem": {"concat": [{"val": "10.0.0.4"}, {"val": 4}]}}, {"concat": ["10.0.0.5", 3]}],
            ),
        }
    )
    runner = FakePolicyCommandRunner(table_json=wrapped)
    manager = make_manager(tmp_path, runner)

    live_map = manager.read_map()

    assert live_map.v4.infra == ("10.0.0.1",)
    assert live_map.v4.slots == (("10.0.0.4", 4), ("10.0.0.5", 3))
    assert live_map.v4.pairs == (("10.0.0.4", 4), ("10.0.0.5", 3))


def test_read_map_tunnel_accepts_bare_host_address_alongside_prefix(tmp_path):
    payload = make_table_json(
        {
            "cg_tunnel4": _obj(
                "set", "cg_tunnel4", [{"prefix": {"addr": "10.0.0.0", "len": 16}}, "10.1.0.9"]
            )
        }
    )
    runner = FakePolicyCommandRunner(table_json=payload)
    manager = make_manager(tmp_path, runner)

    live_map = manager.read_map()

    assert live_map.v4.tunnel == ("10.0.0.0/16", "10.1.0.9/32")


def test_read_map_empty_objects_omitting_elem_key_produce_empty_family(tmp_path):
    payload = make_table_json(
        {
            "cg_tunnel4": _obj("set", "cg_tunnel4"),
            "cg_infra4": _obj("set", "cg_infra4"),
            "cg_admin4": _obj("set", "cg_admin4"),
            "cg_slot4": _obj("map", "cg_slot4"),
            "cg_pairs4": _obj("set", "cg_pairs4"),
        }
    )
    runner = FakePolicyCommandRunner(table_json=payload)
    manager = make_manager(tmp_path, runner)

    live_map = manager.read_map()

    assert live_map.v4.tunnel == ()
    assert live_map.v4.infra == ()
    assert live_map.v4.admin == ()
    assert live_map.v4.slots == ()
    assert live_map.v4.pairs == ()
    assert live_map.row_count == 0
    assert live_map.hash_v4 == hash_policy_family(live_map.v4)


@pytest.mark.parametrize(
    "overrides",
    [
        {"cg_admin4": None},  # object missing from the table listing entirely
        {"cg_tunnel4": None},
        {"cg_pairs6": None},
        {"cg_infra4": _obj("set", "cg_infra4", ["not-an-ip"])},  # malformed address
        {"cg_infra4": _obj("set", "cg_infra4", ["fd42:42:42::1"])},  # wrong-family address
        {"cg_admin4": _obj("set", "cg_admin4", [123])},  # not a string
        {"cg_slot4": _obj("map", "cg_slot4", [["10.0.0.2"]])},  # element not a pair
        {"cg_slot4": _obj("map", "cg_slot4", [["10.0.0.2", 0]])},  # slot 0 (reserved)
        {"cg_slot4": _obj("map", "cg_slot4", [["10.0.0.2", MAX_SLOT + 1]])},  # slot out of range
        {"cg_pairs4": _obj("set", "cg_pairs4", [{"concat": ["10.0.0.2"]}])},  # concat wrong length
        {"cg_pairs4": _obj("set", "cg_pairs4", ["10.0.0.2 . 1"])},  # not a concat dict at all
        {"cg_tunnel4": _obj("set", "cg_tunnel4", [{"prefix": {"addr": "10.0.0.0", "len": "16"}}])},  # len not int
        {"cg_tunnel4": _obj("set", "cg_tunnel4", ["not-an-ip"])},  # malformed bare tunnel address
        {"cg_tunnel4": _obj("set", "cg_tunnel4", [42])},  # neither prefix dict nor string
    ],
)
def test_read_map_rejects_malformed_or_missing_objects(tmp_path, overrides):
    runner = FakePolicyCommandRunner(table_json=make_table_json(overrides))
    manager = make_manager(tmp_path, runner)

    with pytest.raises(PolicyApplyFailedError):
        manager.read_map()


@pytest.mark.parametrize(
    "payload",
    [
        "not json",
        json.dumps({}),  # missing "nftables"
        json.dumps({"nftables": "oops"}),  # not a list
    ],
)
def test_read_map_rejects_malformed_top_level_json(tmp_path, payload):
    runner = FakePolicyCommandRunner(table_json=payload)
    manager = make_manager(tmp_path, runner)

    with pytest.raises(PolicyApplyFailedError):
        manager.read_map()


def test_read_map_nft_failure_maps_to_transient_policy_error(tmp_path):
    runner = FakePolicyCommandRunner(fail_read=True)
    manager = make_manager(tmp_path, runner)

    with pytest.raises(PolicyApplyFailedError) as exc_info:
        manager.read_map()

    assert exc_info.value.transient is True


def test_read_map_nft_timeout_maps_to_transient_policy_error(tmp_path):
    runner = FakePolicyCommandRunner(timeout_read=True)
    manager = make_manager(tmp_path, runner)

    with pytest.raises(PolicyApplyFailedError) as exc_info:
        manager.read_map()

    assert exc_info.value.transient is True


# --- hash_policy_family --------------------------------------------------


def _family(version=4, *, tunnel=(), infra=(), admin=(), slots=(), pairs=()):
    return LivePolicyFamily(version=version, tunnel=tunnel, infra=infra, admin=admin, slots=slots, pairs=pairs)


def test_hash_policy_family_is_stable_and_content_sensitive():
    base = _family(slots=(("10.0.0.2", 1), ("10.0.0.3", 2)), pairs=(("10.0.0.2", 1), ("10.0.0.3", 2)))

    assert hash_policy_family(base) == hash_policy_family(base)
    assert hash_policy_family(base) != hash_policy_family(_family())
    assert hash_policy_family(base) != hash_policy_family(replace(base, slots=(("10.0.0.2", 1),)))


def test_hash_policy_family_empty_is_deterministic():
    assert hash_policy_family(_family()) == hash_policy_family(_family())


def test_read_map_element_order_in_the_nft_payload_never_affects_the_hash(tmp_path):
    # Order-independence is canonicalized by LivePolicyFamily itself, so two
    # payloads with identical content in different element order must read
    # back identical hashes - otherwise two regions holding the same policy
    # could publish different hashes and look drifted.
    forward = make_table_json(
        {
            "cg_slot4": _obj("map", "cg_slot4", [["10.0.0.2", 1], ["10.0.0.3", 2]]),
            "cg_pairs4": _obj("set", "cg_pairs4", [{"concat": ["10.0.0.2", 1]}, {"concat": ["10.0.0.3", 2]}]),
            "cg_admin4": _obj("set", "cg_admin4", ["10.0.0.2", "10.0.0.3"]),
        }
    )
    reversed_order = make_table_json(
        {
            "cg_slot4": _obj("map", "cg_slot4", [["10.0.0.3", 2], ["10.0.0.2", 1]]),
            "cg_pairs4": _obj("set", "cg_pairs4", [{"concat": ["10.0.0.3", 2]}, {"concat": ["10.0.0.2", 1]}]),
            "cg_admin4": _obj("set", "cg_admin4", ["10.0.0.3", "10.0.0.2"]),
        }
    )
    manager_forward = make_manager(tmp_path, FakePolicyCommandRunner(table_json=forward))
    manager_reversed = make_manager(tmp_path, FakePolicyCommandRunner(table_json=reversed_order), lock_path=str(tmp_path / "other.lock"))

    assert manager_forward.read_map().hash_v4 == manager_reversed.read_map().hash_v4


def test_live_policy_family_canonicalizes_element_order_at_construction():
    # The digest must describe content, not the order nft happened to list it
    # in, and must not depend on every caller remembering to pre-sort.
    shuffled = _family(
        tunnel=("10.1.0.0/16", "10.0.0.0/16"),
        infra=("10.0.0.9", "10.0.0.1"),
        admin=("10.0.0.10", "10.0.0.2"),
        slots=(("10.0.0.10", 2), ("10.0.0.2", 1)),
        pairs=(("10.0.0.2", 2), ("10.0.0.2", 1)),
    )

    assert shuffled.tunnel == ("10.0.0.0/16", "10.1.0.0/16")
    assert shuffled.infra == ("10.0.0.1", "10.0.0.9")
    assert shuffled.admin == ("10.0.0.2", "10.0.0.10")
    assert shuffled.slots == (("10.0.0.2", 1), ("10.0.0.10", 2))
    # Same address twice under different marks still has one canonical order.
    assert shuffled.pairs == (("10.0.0.2", 1), ("10.0.0.2", 2))

    sorted_family = _family(
        tunnel=("10.0.0.0/16", "10.1.0.0/16"),
        infra=("10.0.0.1", "10.0.0.9"),
        admin=("10.0.0.2", "10.0.0.10"),
        slots=(("10.0.0.2", 1), ("10.0.0.10", 2)),
        pairs=(("10.0.0.2", 1), ("10.0.0.2", 2)),
    )
    assert hash_policy_family(shuffled) == hash_policy_family(sorted_family)


def test_hash_policy_family_changing_admin_alone_changes_the_hash():
    without_admin = _family(slots=(("10.0.0.2", 1),), pairs=(("10.0.0.2", 1),))
    with_admin = replace(without_admin, admin=("10.0.0.2",))

    assert hash_policy_family(without_admin) != hash_policy_family(with_admin)


def test_hash_policy_family_changing_infra_or_tunnel_alone_changes_the_hash():
    base = _family(slots=(("10.0.0.2", 1),), pairs=(("10.0.0.2", 1),))

    assert hash_policy_family(base) != hash_policy_family(replace(base, infra=("10.0.0.1",)))
    assert hash_policy_family(base) != hash_policy_family(replace(base, tunnel=("10.0.0.0/16",)))


def test_hash_policy_family_object_label_distinguishes_identical_addresses_across_objects():
    # The same address in cg_admin4 vs cg_infra4 must never collide - the
    # object-name label on every digest line is what prevents that.
    as_admin = _family(admin=("10.0.0.2",))
    as_infra = _family(infra=("10.0.0.2",))

    assert hash_policy_family(as_admin) != hash_policy_family(as_infra)


def test_hash_policy_family_v4_and_v6_are_independent_even_with_identical_content():
    v4 = _family(version=4, admin=("10.0.0.2",))
    v6 = _family(version=6, admin=("10.0.0.2",))

    assert hash_policy_family(v4) != hash_policy_family(v6)


# --- validation: bad input never reaches nft --------------------------------


def test_apply_map_rejects_bad_address_without_running_commands(tmp_path):
    runner = FakePolicyCommandRunner()
    manager = make_manager(tmp_path, runner)
    bad_row = PolicyRow(address_v4="not-an-ip", address_v6="fd42:42:42::2", slot=1)

    with pytest.raises(PolicyApplyFailedError):
        manager.apply_map([bad_row])
    assert runner.calls == []


def test_apply_map_rejects_wrong_family_address_without_running_commands(tmp_path):
    runner = FakePolicyCommandRunner()
    manager = make_manager(tmp_path, runner)
    # A v6 literal in the v4 field.
    bad_row = PolicyRow(address_v4="fd42:42:42::2", address_v6="fd42:42:42::2", slot=1)

    with pytest.raises(PolicyApplyFailedError):
        manager.apply_map([bad_row])
    assert runner.calls == []


@pytest.mark.parametrize(
    "slot",
    [
        0,  # below MIN_SLOT: slot 0 is reserved for "unknown source"
        -1,
        MAX_SLOT + 1,
        "not-a-number",
        True,  # bool is an int subclass but must never be accepted as a slot
        1.5,
        None,
    ],
)
def test_apply_map_rejects_bad_slot_without_running_commands(tmp_path, slot):
    runner = FakePolicyCommandRunner()
    manager = make_manager(tmp_path, runner)
    bad_row = PolicyRow(address_v4="10.0.0.2", address_v6="fd42:42:42::2", slot=slot)

    with pytest.raises(PolicyApplyFailedError):
        manager.apply_map([bad_row])
    assert runner.calls == []


def test_apply_map_accepts_slot_at_bounds(tmp_path):
    runner = FakePolicyCommandRunner()
    manager = make_manager(tmp_path, runner)
    min_row = PolicyRow(address_v4="10.0.0.2", address_v6="fd42:42:42::2", slot=MIN_SLOT)
    max_row = PolicyRow(address_v4="10.0.0.3", address_v6="fd42:42:42::3", slot=MAX_SLOT)

    manager.apply_map([min_row, max_row])

    assert len(runner.calls) == 1


def test_add_client_row_rejects_bad_input_without_running_commands(tmp_path):
    runner = FakePolicyCommandRunner()
    manager = make_manager(tmp_path, runner)
    bad_row = PolicyRow(address_v4="10.0.0.2", address_v6="fd42:42:42::2", slot=0)

    with pytest.raises(PolicyApplyFailedError):
        manager.add_client_row(bad_row)
    assert runner.calls == []


def test_apply_map_rejects_bad_infra_address_without_running_commands(tmp_path):
    runner = FakePolicyCommandRunner()
    manager = make_manager(tmp_path, runner)
    row = PolicyRow(address_v4="10.0.0.2", address_v6="fd42:42:42::2", slot=1)

    with pytest.raises(PolicyApplyFailedError):
        manager.apply_map([row], infra_v4=["not-an-ip"])
    assert runner.calls == []


# --- nft failure mapping -----------------------------------------------------


def test_apply_map_nft_failure_raises_transient_policy_error(tmp_path):
    runner = FakePolicyCommandRunner(fail_apply=True)
    manager = make_manager(tmp_path, runner)
    row = PolicyRow(address_v4="10.0.0.2", address_v6="fd42:42:42::2", slot=1)

    with pytest.raises(PolicyApplyFailedError) as exc_info:
        manager.apply_map([row])

    assert exc_info.value.transient is True


def test_apply_map_nft_timeout_raises_transient_policy_error(tmp_path):
    runner = FakePolicyCommandRunner(timeout_apply=True)
    manager = make_manager(tmp_path, runner)
    row = PolicyRow(address_v4="10.0.0.2", address_v6="fd42:42:42::2", slot=1)

    with pytest.raises(PolicyApplyFailedError) as exc_info:
        manager.apply_map([row])

    assert exc_info.value.transient is True


def test_add_client_row_nft_failure_raises_transient_policy_error(tmp_path):
    runner = FakePolicyCommandRunner(fail_apply=True)
    manager = make_manager(tmp_path, runner)
    row = PolicyRow(address_v4="10.0.0.2", address_v6="fd42:42:42::2", slot=1)

    with pytest.raises(PolicyApplyFailedError) as exc_info:
        manager.add_client_row(row)

    assert exc_info.value.transient is True


# --- lock() -------------------------------------------------------------------


def test_lock_is_exclusive_and_reusable(tmp_path):
    runner = FakePolicyCommandRunner()
    manager = make_manager(tmp_path, runner)

    with manager.lock():
        pass
    with manager.lock():
        manager.add_client_row(PolicyRow(address_v4="10.0.0.2", address_v6="fd42:42:42::2", slot=1))

    assert (tmp_path / "cloudgateway-policy.lock").exists()


def test_non_blocking_lock_sheds_while_held_and_recovers_after_release(tmp_path):
    # flock is per open file description, so a second manager on the same path
    # contends exactly as a second process would (a policy refresh vs. a
    # concurrent add_client_row on the create path).
    runner = FakePolicyCommandRunner()
    lock_path = str(tmp_path / "cloudgateway-policy.lock")
    manager = make_manager(tmp_path, runner, lock_path=lock_path)
    other = make_manager(tmp_path, runner, lock_path=lock_path)

    with manager.lock():
        with pytest.raises(SyncInProgressError):
            with other.lock(blocking=False):
                pass

    with other.lock(blocking=False):
        pass
