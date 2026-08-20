# ACL-C: Host filter (nftables) + Firebase + docs review

Scope: `bc7d99a..HEAD`, Account-Scoped ACL PR. Host packet filter (`bootstrap.sh`),
Firestore `Policy/{regionId}` rules/schema, `scripts/test.sh` wiring, and doc drift
against `Backend/API/src/policy.py` (ground truth, owned by another chunk).

## Reviewed

- [x] `Infrastructure/OCI/host/bootstrap.sh` (nftables table/chain/PostUp/PostDown)
- [x] `Backend/Firebase/firestore.rules` (`Policy/{regionId}`)
- [x] `Backend/Firebase/tests/firestore.rules.test.ts`
- [x] `Backend/Firebase/schema.ts`
- [x] `Backend/Firebase/README.md`
- [x] `scripts/test.sh`
- [x] `pyrightconfig.json`, `.gitignore`, top-level `README.md`
- [x] `docs/service-operations.md`
- [x] `docs/wireguard-drift-repair.md`
- [x] `docs/api-contract.md`
- [x] `docs/deployment-handoff.md`
- [x] `docs/regional-deployment.md`
- [x] `docs/quick-deployment.md`
- [x] `Infrastructure/OCI/README.md`
- [x] Cross-check against `Backend/API/src/policy.py` (ground truth, not reviewed directly)

## Findings

## Clean (no findings)

- `Infrastructure/OCI/host/bootstrap.sh` nftables table/chain/PostUp/PostDown: default policy is
  `accept` at the base-chain level but the boundary rule is a terminal `drop`, which is correct
  (DROP is terminal across all hooks; ACCEPT only continues to the next-priority hook, so the
  `-10` priority placement ahead of the legacy iptables FORWARD accepts is sound and matches the
  in-file comment). Boot state (empty maps => fail-closed for client-to-client, fail-open only for
  already-permitted infra/admin pairs) checks out. PostUp/PostDown ordering: `nft -f` runs first
  in PostUp (table loaded before the legacy iptables ACCEPT-all-on-wg0 rules are inserted) and
  `nft delete table ... || true` runs first in PostDown, both correctly idempotent. No window
  exists where wg0 is up with peers configured but the filter is not loaded, because the
  interface-only config carries no peers — `cloudgateway-sync-peers` (which adds peers) only runs
  after `wg-quick@wg0.service` (and therefore PostUp) fully completes. A failed `nft -f` PostUp
  command aborts `wg-quick up` (wg-quick treats PostUp failures as fatal and tears the interface
  back down), so the failure mode is "no VPN" rather than "VPN without the filter" — consistent
  with the file's own documented intent. Table/chain/set/map names, kinds, tunnel aggregates, rule
  ordering, and the `cloudgateway-install-api` rollout gate's grep strings are all exhaustively
  cross-checked against `Backend/API/src/policy.py` by
  `Backend/API/tests/test_bootstrap_contract.py` (parses bootstrap.sh's source text directly, with
  negative tests proving each check actually bites on a rename/reorder/type-flip). No drift found
  between what bootstrap.sh installs and what policy.py assumes.
- `Backend/Firebase/firestore.rules`: `Policy/{regionId}` is `get, list` admin-only, `write: if
  false` (Admin-SDK-only via server), matching the `Mesh/{regionId}` precedent. `Counters/{id}` is
  fully `read, write: if false` — no client, including admins, can read the account-slot
  allocator. No cross-account or non-admin read path found into either collection.
- `Backend/Firebase/tests/firestore.rules.test.ts`: new tests cover admin/non-admin/unauthenticated
  read on `Policy/{regionId}`, admin-cannot-read on `Counters/accountSlots`, and both paths are
  included in the "every client write is denied" sweep.
- `Backend/Firebase/schema.ts`: `FirebasePolicyDoc`, `FirebaseCounterDoc`, `accountSlot` on
  `FirebaseUserDoc`, and `tunnelIndexV4/V6` on `FirebaseRegionDoc` all match the rules and the
  README's description of what they hold; `FirebaseDocumentTree` wires `Policy`/`Counters` in.
- `scripts/test.sh`: `release` target wired in both the usage comment and the target dispatch,
  matches `AGENTS.md`'s documented entry point (pyright + py_compile + unittest over
  `releases/access-control-lists/`). `pyrightconfig.json` adds `releases` to `include`, consistent.
  `.gitignore` addition (`.claude/subagents/`) and top-level `README.md`'s new "Account-scoped ACL
  policy logs are aggregate-only" / "`Policy/{regionId}` status document is deliberately opaque"
  claims were cross-checked against `Backend/API/src/policy_sync.py`'s `log_event` call sites
  (region_id, skipped_rows, row_count, status_written, exc_info only — no uid/email/address/slot
  in any log field) and `policy.py`'s `PolicyApplyFailedError` messages (generic, never interpolate
  an address; the one call site with a variable interpolates only a fixed nft object/field label,
  e.g. `f"Policy map read failed: {name} missing."`) and `_run()`'s subprocess args (`["nft", "-f",
  "-"]` / `["nft", "-j", "list", ...]` — fixed argv, no address ever appears in `args`, so a
  `CalledProcessError.__str__()` chained via `exc_info` cannot leak one either). Claims hold.
- `docs/service-operations.md`, `docs/wireguard-drift-repair.md`, `docs/api-contract.md`,
  `docs/deployment-handoff.md`, `docs/regional-deployment.md`, `docs/quick-deployment.md`,
  `Infrastructure/OCI/README.md`: all cross-checked against the actual bootstrap.sh gate logic,
  `sync.py` exit codes (`EXIT_POLICY_FAILED = 2` matches the docs), and `policy_sync.py`'s
  `reconcile_policy()`/lock behavior. No drift found. The "fleet-wide client/account snapshot"
  language in `wireguard-drift-repair.md` and `service-operations.md` is the reason cross-region
  same-account peer-to-peer traffic (which transits a region's own `cg_forward` with
  `iifname/oifname wg0` on both sides, since a WireGuard-forwarded packet re-enters routing on the
  same virtual interface) still gets a `cg_pairs`/`cg_slot` match locally: every region's policy
  map already contains every account's clients fleet-wide, not just the clients physically
  attached to that region. This resolved what would otherwise have been a plausible finding here;
  flagging it as context for X-1 (cross-cutting) rather than filing it as a bug, since I found no
  evidence in policy.py/policy_sync.py (read for context, not owned by this chunk) that the
  fleet-wide pull is actually region-scoped instead — the docs' own description and the "fleet-
  wide" wording throughout `Backend/API/src/policy_sync.py` are consistent with the intended
  design. Rollout/rollback sequencing content in `deployment-handoff.md`, `quick-deployment.md`,
  and `regional-deployment.md` is out of scope per the review's ground rules and was not further
  evaluated beyond doc-vs-bootstrap.sh consistency.
- Cross-check against `Backend/API/src/policy.py`: table/chain/set/map names, kinds, mesh
  aggregates, rule ordering, and the `cloudgateway-install-api` rollout gate strings are exhaustively
  validated by `Backend/API/tests/test_bootstrap_contract.py` (owned by ACL-A, but read here to
  confirm no gap exists between bootstrap.sh and the policy layer). No mismatch found.

## Summary

No P0/P1/P2 findings in this chunk's scope. The nftables ruleset, Firestore rules/schema, test
wiring, and docs are internally consistent and match what `Backend/API/src/policy.py` /
`policy_sync.py` / `sync.py` actually do. The one open item worth flagging to the consolidation
pass: `docs/wireguard-drift-repair.md`'s own "Open verification item" section states that nft
verdict precedence (drop-in-`cg_forward` terminating evaluation ahead of the legacy
`iptables`/`ip6tables` `FORWARD` chains, the `priority -10` ordering, and the `ip daddr @cg_tunnel4
ip daddr . meta mark != @cg_pairs4` concatenated-set syntax) has **not been verified on a real
host** — this is a self-disclosed pre-rollout checklist item, not a finding against any file in
this chunk, but it is the single largest remaining risk to the account boundary this review chunk
covers, so it should not get lost before deploy.
