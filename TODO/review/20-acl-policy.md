# ACL-A: Policy Engine Review (`policy.py` + `policy_sync.py`)

Diff range: `bc7d99a..HEAD`. Read-only review, findings appended incrementally.

## Reviewed

- [x] `Backend/API/src/policy.py`
- [x] `Backend/API/src/policy_sync.py`
- [x] `Backend/API/tests/test_policy.py`
- [x] `Backend/API/tests/test_policy_sync.py`
- [x] `Backend/API/tests/test_policy_concurrency.py`
- [x] `Backend/API/tests/test_bootstrap_contract.py`
- [x] Cross-check: `Backend/API/src/wireguard.py` (lock separation)
- [x] Cross-check: `Backend/API/src/routes.py` (poke sites, inline write)

## Findings

(appended as confirmed)


### [P2] `_infra_address` can add an unrelated live address to cg_infra for a degenerate region CIDR
- **Where:** `Backend/API/src/policy_sync.py:53-74` (`_infra_address`)
- **What:** The region's cg_infra address is computed as `network.network_address + 1`, then only checked with `if address not in aggregate: return None` (still inside the fleet-wide mesh aggregate). There is no check that `network_address + 1` actually falls *inside* the region's own `tunnel_network_v4`/`_v6`. For any normal region subnet (`/24` or wider) this is harmless, since `.1` is always inside a `/24`+. But if a region document's `tunnel_network_v4` is ever a single-host CIDR (`/32`, e.g. `"10.0.5.5/32"`), `ipaddress.ip_network(..., strict=True)` accepts it (it is a syntactically valid network), `network_address` is `10.0.5.5` itself, and `network_address + 1` = `10.0.5.6` - an address outside that region's declared network entirely, yet still inside the fleet-wide `10.0.0.0/16` aggregate, so it passes the `in aggregate` check and is added to `cg_infra4`.
- **Failure:** If `10.0.5.6` happens to already be a legitimately-allocated client tunnel address (any account, monotonically assigned elsewhere in the fleet), a bad/corrupted region CIDR silently promotes that unrelated client's address to `cg_infra4` membership on the next reconcile. Via bootstrap.sh's `saddr @cg_infra4 daddr @cg_admin4` / reverse accept rules, that address becomes reachable by (and able to reach) every operator-admin client in the fleet, bypassing the per-account slot check entirely for that one address - all without the affected client's owner doing anything wrong. This is a genuine boundary violation in the reachability graph, not merely a wrong health-check target.
- **Fix:** In `_infra_address`, additionally require the computed address to be a member of `network` itself (`address in network`), not just the outer mesh aggregate, before accepting it - keeping the existing "malformed/wrong-family/out-of-aggregate -> skip" fail-closed pattern consistent for degenerate CIDRs too.

### [P3] No test coverage for a degenerate (`/31`/`/32`) region tunnel CIDR in `desired_policy`'s infra derivation
- **Where:** `Backend/API/tests/test_policy_sync.py:275-345`
- **What:** `test_desired_policy_skips_malformed_region_cidr_for_infra`, `test_desired_policy_infra_address_is_network_address_plus_one`, `test_desired_policy_dedupes_infra_addresses_across_regions`, and `test_desired_policy_rejects_infra_address_outside_tunnel_aggregate` all use `/24`/`/64` regions. None of them exercise a single-host region CIDR, which is exactly the case that reaches the P2 finding above (`network_address + 1` landing outside the region's own network but still inside the fleet aggregate).
- **Failure:** The gap this finding describes could regress silently even after a fix, since nothing pins the "computed infra address must stay inside the region's own CIDR" invariant.
- **Fix:** Add a case with `tunnel_network_v4="10.0.5.5/32"` (and the v6 analogue) asserting `desired.infra_v4 == ()` once the P2 fix lands, or documenting the accepted behavior if the team decides degenerate CIDRs are pre-validated elsewhere and out of this function's remit.

## Clean (no findings)

- `Backend/API/src/policy.py` - command construction is injection-safe: every address/slot is validated via `ipaddress`/int-range checks (`_validate_address`, `_validate_slot`) before any value is interpolated into an nft script string, `render_policy_script`/`render_client_row_script` document and honor this trust boundary, and all subprocess calls use `shell=False` with argument lists (`["nft", "-f", "-"]`, `["nft", "-j", "list", "table", "inet", POLICY_TABLE]`) - no shell injection surface. `read_map`'s parsing is fail-closed on every malformed/missing shape (`_require_object`, `_elements`, `_parse_*`), so a corrupted or partial `nft -j list` payload raises rather than silently reporting an empty/healthy map.
- `Backend/API/src/policy.py` / `policy_sync.py` - no logging of tunnel IPs, WireGuard keys, per-user connection history, or auth tokens anywhere in either module; `POLICY_ROWS_SKIPPED` logs only a count, never which client/address/uid.
- Lock separation (`policy.lock()` vs `wireguard.lock()`): confirmed no nesting in either direction. `routes.py`'s create path releases `wireguard.lock()` (closes at line ~264) before ever touching `policy.lock()` in `_write_inline_policy_row` (line ~1016); the delete and account-cleanup peer-removal paths (`routes.py:356`, `:890`) never reference `policy` at all inside their `wireguard.lock()` blocks; `wireguard.py` has zero references to `policy`. No deadlock path between the two locks.
- `reconcile_policy`'s pull-inside-the-lock ordering and `PolicyCoordinator`'s depth-1 coalescing (`request`/`run_blocking`/`_drain`) are correctly implemented standard condition-variable patterns, and are proven against a real `fcntl.flock` in `test_policy_concurrency.py` (two-process interleave test, pull-never-predates-lock-acquisition regression test, inline-row-vs-full-pass no-op test, WireGuard-lock-never-held test, and the depth-1-vs-total-work third-pass test). No gaps found in this suite.
- `render_policy_script`/`render_client_row_script` correctly implement default-deny for the empty-fleet case (flush-only, no `{ }` emitted - covered by `test_render_policy_script_empty_rows_flushes_only_and_never_emits_empty_braces`) and the single-client case degrades to "no peer to reach" rather than any accidental accept, consistent with bootstrap.sh's fail-closed terminal drop.
- `desired_policy`'s two-pass collision handling (account-slot collisions exclude every participating uid; address collisions exclude both colliding candidates regardless of Firestore iteration order) is symmetric and order-independent, matches its own docstring, and is exercised from both collection orders in `test_policy_sync.py` (`reorder_first_last` parametrization).
- `Backend/API/tests/test_bootstrap_contract.py` - genuinely pins the bootstrap.sh <-> policy.py contract: parses the real nft heredoc and PostUp/PostDown/install-gate text (not a copy), asserts object names/kinds/declarations, tunnel aggregate values, chain rule presence and ordering (mark-assignment and infra/admin accepts before the terminal drops), and backs every positive assertion with a negative mutation test proving the check actually fails when the corresponding bootstrap.sh line is broken. This closes the gap the plan called out (a rename previously did not fail the build).
- `Backend/API/tests/test_policy.py` - render/apply/read-map/hash coverage is thorough: exact-text rendering, empty-map handling, deterministic ordering regardless of input order, both nft JSON wrapper conventions (`elem`/`val`), malformed/missing-object fail-closed paths, and hash sensitivity to admin/infra/tunnel changes and per-family independence are all covered.
