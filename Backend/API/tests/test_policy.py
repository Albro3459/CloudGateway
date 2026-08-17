import json
import subprocess
from dataclasses import dataclass

import pytest

from src.errors import PolicyApplyFailedError, SyncInProgressError
from src.policy import (
    MAX_SLOT,
    MIN_SLOT,
    POLICY_TABLE,
    LocalPolicyManager,
    PolicyRow,
    _parse_slot_map,
    hash_policy_rows,
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


class FakePolicyCommandRunner:
    """Emulates the `nft` CLI surface LocalPolicyManager drives: `nft -f -` for
    script application and `nft -j list map inet cloudgateway <name>` for read-back."""

    def __init__(
        self,
        *,
        map_json_v4: str = '{"nftables": [{"map": {"elem": []}}]}',
        map_json_v6: str = '{"nftables": [{"map": {"elem": []}}]}',
        fail_apply: bool = False,
        timeout_apply: bool = False,
        fail_read: bool = False,
        timeout_read: bool = False,
        failure_stderr: str = "simulated nft failure",
    ):
        self.calls: list[FakeCommandCall] = []
        self.map_json_v4 = map_json_v4
        self.map_json_v6 = map_json_v6
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

        if len(argv) == 7 and argv[0] == "nft" and argv[1] == "-j" and argv[2] == "list" and argv[3] == "map":
            set_name = argv[6]
            if self.timeout_read:
                raise subprocess.TimeoutExpired(list(argv), timeout)
            if self.fail_read:
                raise subprocess.CalledProcessError(1, list(argv), stderr=self.failure_stderr)
            stdout = self.map_json_v4 if set_name == "cg_slot4" else self.map_json_v6
            return subprocess.CompletedProcess(argv, 0, stdout=stdout, stderr="")

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


# --- read_map / _parse_slot_map ---------------------------------------------


def test_parse_slot_map_bare_scalar_shape_sorts_by_packed_address():
    payload = json.dumps(
        {
            "nftables": [
                {"metainfo": {"version": "1.0.9"}},
                {
                    "map": {
                        "family": "inet",
                        "name": "cg_slot4",
                        "table": "cloudgateway",
                        "elem": [
                            ["10.0.0.3", 2],
                            ["10.0.0.2", 1],
                        ],
                    }
                },
            ]
        }
    )

    rows = _parse_slot_map(payload, 4)

    assert rows == (("10.0.0.2", 1), ("10.0.0.3", 2))


def test_parse_slot_map_wrapped_elem_val_shape():
    payload = json.dumps(
        {
            "nftables": [
                {
                    "map": {
                        "elem": [
                            [{"elem": {"val": "10.0.0.5"}}, 3],
                            ["10.0.0.4", {"val": 4}],
                        ]
                    }
                }
            ]
        }
    )

    rows = _parse_slot_map(payload, 4)

    assert rows == (("10.0.0.4", 4), ("10.0.0.5", 3))


def test_parse_slot_map_empty_map_omitting_elem_key():
    payload = json.dumps({"nftables": [{"map": {"family": "inet", "name": "cg_slot4", "table": "cloudgateway"}}]})

    rows = _parse_slot_map(payload, 4)

    assert rows == ()


def test_read_map_end_to_end_sorts_hashes_and_counts(tmp_path):
    v4_json = json.dumps(
        {"nftables": [{"map": {"elem": [["10.0.0.9", 9], ["10.0.0.2", 2], ["10.0.0.5", 5]]}}]}
    )
    v6_json = json.dumps(
        {
            "nftables": [
                {"map": {"elem": [["fd42:42:42::9", 9], ["fd42:42:42::2", 2], ["fd42:42:42::5", 5]]}}
            ]
        }
    )
    runner = FakePolicyCommandRunner(map_json_v4=v4_json, map_json_v6=v6_json)
    manager = make_manager(tmp_path, runner)

    live_map = manager.read_map()

    assert live_map.rows_v4 == (("10.0.0.2", 2), ("10.0.0.5", 5), ("10.0.0.9", 9))
    assert live_map.rows_v6 == (("fd42:42:42::2", 2), ("fd42:42:42::5", 5), ("fd42:42:42::9", 9))
    assert live_map.row_count == 3
    assert live_map.hash_v4 == hash_policy_rows(live_map.rows_v4)
    assert live_map.hash_v6 == hash_policy_rows(live_map.rows_v6)
    assert live_map.hash_v4 != live_map.hash_v6


def test_read_map_empty_map_has_stable_hash_and_zero_row_count(tmp_path):
    runner = FakePolicyCommandRunner()
    manager = make_manager(tmp_path, runner)

    live_map = manager.read_map()

    assert live_map.rows_v4 == ()
    assert live_map.row_count == 0
    assert live_map.hash_v4 == hash_policy_rows(())


@pytest.mark.parametrize(
    "payload",
    [
        "not json",
        json.dumps({}),  # missing "nftables"
        json.dumps({"nftables": "oops"}),  # not a list
        json.dumps({"nftables": [{"metainfo": {}}]}),  # no map entry present
        json.dumps({"nftables": [{"map": {"elem": "oops"}}]}),  # elem not a list
        json.dumps({"nftables": [{"map": {"elem": [["10.0.0.2"]]}}]}),  # element not a pair
        json.dumps({"nftables": [{"map": {"elem": [[123, 1]]}}]}),  # address not a string
    ],
)
def test_parse_slot_map_rejects_malformed_or_unexpected_json(payload):
    with pytest.raises(PolicyApplyFailedError):
        _parse_slot_map(payload, 4)


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


# --- hash_policy_rows ---------------------------------------------------------


def test_hash_policy_rows_is_stable_and_content_sensitive():
    rows = (("10.0.0.2", 1), ("10.0.0.3", 2))

    assert hash_policy_rows(rows) == hash_policy_rows(rows)
    assert hash_policy_rows(rows) != hash_policy_rows(())
    assert hash_policy_rows(rows) != hash_policy_rows((("10.0.0.2", 1),))
    assert hash_policy_rows(rows) != hash_policy_rows((("10.0.0.2", 1), ("10.0.0.3", 3)))


def test_hash_policy_rows_empty_is_deterministic():
    assert hash_policy_rows(()) == hash_policy_rows(())


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
