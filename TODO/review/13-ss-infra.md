# SS-D: Shared Subnet Mesh — Infra, Firebase, Scripts, Docs Review

Diff range: `e4db044..bc7d99a` (read current file state at HEAD unless noted).

## Reviewed
- [x] scripts/terraform-preflight.py
- [x] scripts/test_terraform_preflight.py
- [x] scripts/test_terraform_wrapper.py
- [x] scripts/terraform.sh
- [x] scripts/test.sh (SS-D relevant parts)
- [x] scripts/ios-release.sh
- [x] Infrastructure/OCI/terraform/cloudgateway.tf
- [x] Infrastructure/OCI/terraform/subnet-registry.json
- [x] Infrastructure/OCI/terraform/terraform.tfvars.example
- [x] Infrastructure/OCI/host/bootstrap.sh
- [x] Infrastructure/OCI/README.md
- [x] Backend/Firebase/firestore.rules
- [x] Backend/Firebase/schema.ts
- [x] Backend/Firebase/tests/firestore.rules.test.ts
- [x] docs/api-contract.md
- [x] docs/service-operations.md
- [x] docs/deployment-handoff.md
- [x] docs/wireguard-drift-repair.md
- [x] docs/vm-loss-recovery.md
- [x] docs/regional-deployment.md
- [x] docs/quick-deployment.md
- [x] docs/github-deployment-setup.md

## Findings


## Clean (no findings)

- `scripts/test.sh` mesh-range diff — the `run_step` rewrite (lines ~286-311) is a genuine fix,
  not a regression. Old `run_step` never captured `"$@"`'s exit status; it judged
  success/failure purely by whether `FAILURES` grew during the call. Every `test_*` target
  (`test_web`, `test_firebase`, `test_apple`, `run_pyright`) opens with an unguarded `cd ... ||
  return 1` (e.g. `scripts/test.sh:93` `cd "$ROOT/Frontend/Web" || return 1`, `:110`
  `cd "$ROOT/Backend/Firebase" || return 1`) that returns early *before* any `run_check` call, so
  a `cd` failure left `FAILURES` unchanged and old `run_step` printed `OK: $name` for a target
  that ran nothing. New `run_step` captures `status=$?` from `"$@"` and falls back to appending
  `$name` to `FAILURES` itself when `status != 0` but `FAILURES` didn't grow, closing that gap;
  it still also checks `FAILURES` growth after a zero exit so a target whose *last* command
  happens to succeed after an earlier `run_check` failure (e.g. `test_apple`'s `failed=1`
  accumulator pattern) is still correctly reported as `FAILED`. Confirmed no `set -e` is in play
  (`set -uo pipefail` at scripts/test.sh:21) and the target loop (scripts/test.sh:329-341) calls
  `run_step` as a bare statement, so `run_step`'s now-nonzero return doesn't early-exit the
  `for target in ...` loop — the script's documented "every step runs even if an earlier one
  failed" contract (scripts/test.sh:18) is preserved. The `cd`-failure scenario itself is
  low-probability in a normal checkout (the target directories always exist), but the fix is
  correct and strictly closes a real, if narrow, silent-pass gap. New `test_infra` lines
  (`scripts/test.sh:267-270`, wiring `scripts/test_terraform_wrapper.py` into pyright/compile/
  unittest) just add coverage, no logic change.
- `scripts/ios-release.sh` mesh-range diff (lines 375-397) — reordered/tightened the post-upload
  log-scan heuristics: real rejections now require an `ITMS-\d+` code or an explicit failure
  phrase (previously any bare `ERROR:` line failed the whole release even after Apple had
  already accepted the delivery, per the new comment describing a known Transporter
  "eTags cannot be empty" post-commit race). The script still requires both a
  `N packages? (was|were) uploaded successfully` summary line and the `Returning 0` sentinel
  before treating the upload as delivered, and still refuses to `git commit` (the version-bump
  commit at the bottom of the file) unless both are present — a truncated/hung Transporter run
  still cannot pass. Bare `ERROR:` lines are now surfaced as a non-fatal note (still visible on
  stderr) rather than aborting a delivery the server already committed. No change to credential
  handling: `AUTH_HOME` is still a fresh `mktemp -d`, the `.p8` key is still copied with
  `chmod 600`, and nothing new is logged.
- `Infrastructure/OCI/README.md` mesh-range diff — the new "Cross-region tunnel subnets" section
  and the `cloudgateway-sync-peers.service` bullet update ("at boot and after region
  registration") were cross-checked against `Infrastructure/OCI/host/bootstrap.sh`: the first
  `systemctl start cloudgateway-sync-peers` runs at bootstrap.sh:869 (boot-time first sync,
  `|| true` since a fresh region with no Firebase credentials yet is expected to fail and let
  systemd's `Restart=on-failure`/`RestartSec=30` retry it, per the service unit at
  bootstrap.sh:813-830), and the second runs post-registration
  (bootstrap.sh:893-936, gated on `REGISTER_STATUS -eq 0`, already verified in a prior pass of
  this doc). The claim matches. "Retries until Firebase is reachable" wording was trimmed from
  the WireGuard bullet but the retry behavior is unchanged and still documented via the systemd
  unit comment (bootstrap.sh:811-812) and the service's own `Restart=on-failure` — not misleading
  drift, just moved text.
- `Backend/Firebase/firestore.rules` mesh-range diff (lines 41-55) — reviewed for real
  authz, not just prose. `Regions/{regionId}` gains `allow update: if isAdmin() &&
  request.resource.data.diff(resource.data).affectedKeys().hasOnly(['meshEnabled']) &&
  request.resource.data.meshEnabled is bool` (firestore.rules:45-47): non-admins are already
  excluded by the pre-existing `isAdmin()` gate, and `affectedKeys().hasOnly(['meshEnabled'])`
  means no other Region field (endpoint, keys, CIDRs, capacity) can be smuggled in — verified via
  the test file's dedicated denial cases (bundling another field, or changing a different field
  alone, both `assertFails`). No `allow create`/`allow delete` is granted on `Regions`, so an
  admin cannot use this rule to fabricate a new region doc or wipe one (also directly tested).
  New `match /Mesh/{regionId}` (firestore.rules:52-55) is `get, list: if isAdmin()` / `write: if
  false` — non-admin and unauthenticated reads are denied, and no client (including admin) can
  write, matching the `Policy/{regionId}` precedent already reviewed by ACL-C for the ACL range.
  This mirrors that precedent's shape but is new in the mesh range (`Mesh` didn't exist before
  this PR). No cross-account or non-admin path into either collection.
- `Backend/Firebase/tests/firestore.rules.test.ts` mesh-range diff (lines 56-62, 123-183, 193) —
  confirmed the new tests assert denial, not just success: `Mesh` get/list denied for `user1` and
  unauthenticated (lines 126-128); plain user denied the `meshEnabled` update (line 174);
  admin denied on bundling a second field, changing a different field alone, a non-boolean
  `meshEnabled` value, doc creation via the update rule, and doc deletion (lines 160-183, all
  `assertFails`). The blanket "every client write is denied — including admins" sweep
  (lines 187-209) adds `Mesh/us-1` to `writeTargets` and uses a `{ hacked: true }` payload, which
  correctly still fails for admin against `Regions/us-1` too (different field than
  `meshEnabled`, so it doesn't contradict the meshEnabled-specific success test) — the sweep and
  the targeted tests are consistent, not overlapping in a way that would mask a rule regression.
  Good coverage on the load-bearing authz path; no gap found.
- `Backend/Firebase/schema.ts` mesh-range diff — `FirebaseMeshDoc`/`FirebaseMeshPeerEntry`/
  `FirebaseMeshPeerReasonCode` additions are typed observability records only (status, reason
  codes, peer metadata under `Admin SDK`-only write per the rules above); `Regions.meshEnabled?:
  boolean` and `tunnelNetworkV4/V6` additions match the new rule and the mesh subnet fields
  already reviewed on the API/infra side. No secrets or over-broad fields in the new types.
- `docs/api-contract.md` mesh-range diff (`POST /sync` section, lines ~200-350) — cross-checked
  every operator-facing claim against `Backend/API/src/sync.py` and `Backend/API/src/routes.py`
  (owned by SS-A, read here only to verify doc accuracy, not re-reviewed for its own bugs):
  non-blocking lock claim matches `routes.py:661-664` (`run_sync(..., blocking=False)`,
  `SyncInProgressError` -> `409 SYNC_IN_PROGRESS` per `errors.py:95`/`errors.py:16`); "boot and
  post-registration passes still wait for the lock" matches `sync.py:596` (`main()`'s
  `run_sync(...)` call omits `blocking`, defaulting to `True` per `sync.py:404`). `meshEnabled`
  derivation claim ("true only when this region's doc exists, is enabled: true, and carries
  meshEnabled: true") matches `sync.py:101-106`'s `desired_mesh_peers`, and `Mesh/{regionId}`
  persisting that same combined value matches `sync.py:449-452`'s `write_mesh_status(...,
  mesh_enabled=mesh.mesh_enabled, ...)`. `meshStatusWritten` false-without-failing-the-pass claim
  matches `sync.py:447-463` (`write_mesh_status` failure is caught, logged via
  `MESH_STATUS_WRITE_FAILED`, and only flips `mesh_status_written = False` — never re-raised).
  `clientPeersDegraded` protection-follows-status claim matches `sync.py:60-81`
  (`list_active_clients` already filters to active status before any record reaches the
  degraded/protection branch, so a revoked or removed record can never be protected) and
  `wireguard.py:389` (`protected_keys` further filtered to syntactically valid keys only). Log
  content claim ("mesh section is server metadata only... never a public key, never per-user
  data") verified directly against `build_sync_audit_log` (`sync.py:475-568`): the mesh-candidate
  and mesh-peer-change log lines interpolate only `regionId`/`status`/`endpointHostname`/
  `endpointPort`/`allowedNetworkV4`/`allowedNetworkV6`/`reasonCode`/`action`/`cidr` — no public
  key or per-user field appears in any mesh-section line (client-section lines do carry
  `clientId`/`email`/`clientName`, but that is pre-existing, documented behavior unchanged by
  this diff). `SYNC_IN_PROGRESS` addition to the error-code table and its `409` HTTP-status-
  mapping bullet matches `enums.py:57` and `errors.py:16`. All spot-checked claims hold; no drift
  found that would mislead an operator.
- `docs/service-operations.md` mesh-range diff (new "Cross-Region Mesh: Enable / Verify /
  Rollback" section) — "Membership lives only in Firestore... there is no tfvars var or env var
  for it" checked with `grep -rn "mesh_enabled\|meshEnabled\|MESH_ENABLED"` across
  `cloudgateway.tf` and `terraform.tfvars.example`: zero hits, confirmed. "Click Sync All
  Regions. This is the only sync action - there is no per-region selection" checked against
  `Frontend/Web/src/pages/ServerHealth.tsx`: both call sites of `runSync` (`:357`, `:448`) pass
  `enabledRegions.map(region => region.regionId)` — the full enabled-region set, never a single
  region — confirming no per-region sync path exists in the dashboard. The doc frames enable/
  rollback as dashboard-only while separately, correctly, labeling the deeper diagnostic steps
  "(per host, over SSH)" — not a contradiction, just two different documented flows.
- `docs/deployment-handoff.md` mesh-range diff ("Regional subnet allocation", "Peer state"
  addendum, "Replacement handoff") — "a status write failure does not fail an otherwise
  successful sync" matches `sync.py:447-463`. "A normal rebuild is self-healing. Keep the
  region's WireGuard private key, tunnel subnets, and endpoint hostname unchanged" checked
  against `Infrastructure/OCI/terraform/stub-cloud-init.sh.tftpl:67-72` (`wg_server_private_key`
  is a Terraform-interpolated tfvars value, not regenerated at boot) and `cloudgateway.tf`'s
  `wg_network_v4/v6`/`wg_endpoint_hostname` variables, none of which change when only
  `source_ref` changes (the trigger for a destroy/recreate cited in `github-deployment-setup.md`)
  — confirmed these values persist across a rebuild because they come from the same unchanged
  tfvars file, not from anything regenerated per-boot.
- `docs/wireguard-drift-repair.md` mesh-range diff (near-total rewrite) — the highest-density set
  of new operator-facing claims in this chunk; spot-checked the safety-relevant ones directly
  against `Backend/API/src/sync.py`/`wireguard.py`/`firebase.py` (owned by SS-A, read here only
  for doc-accuracy, not re-reviewed for bugs in their own right): mesh candidate collision
  ("whole candidate set is rejected... `desired_mesh_peers` filters all three upstream") matches
  `sync.py:129-156` (duplicate-key rejection) and `:181-204` (local-overlap and candidate-vs-
  candidate overlap rejection), all computed before `desired_mesh_peers` ever returns a peer.
  "Every `wg`/`ip` call and the endpoint DNS lookup are individually time-bounded" matches
  `wireguard.py:644` (`timeout=COMMAND_TIMEOUT_SECONDS` on subprocess calls) and `:724-732`
  (`ENDPOINT_RESOLVE_TIMEOUT_SECONDS` via a worker-thread `future.result(timeout=...)` since
  `getaddrinfo` itself takes no timeout param). `peer_sync_partial` line existing and "carrying
  the same counters" matches `Event.PEER_SYNC_PARTIAL` at `wireguard.py:487-494` (logs
  added/updated/removed/mesh_applied/mesh_removed/routes_added/routes_removed on the
  apply-error path before re-raising). Mesh route reconciliation scope (`10.0.0.0/16` /
  `fd42:42:42::/48`, `proto kernel` skip, `mesh_route_reclaimed` WARNING event) matches
  `wireguard.py:45-46` (`MESH_AGGREGATE_V4/V6` constants) and `Event.MESH_ROUTE_RECLAIMED` at
  `:598`. "The One Firebase Write" section's claim that the persisted `Mesh/{regionId}` doc holds
  "region IDs, CIDRs, public keys, endpoint hostnames, and endpoint ports... never handshake
  timestamps" matches `firebase.py:189-222`'s `write_mesh_status` (`status`/`appliedAt`/
  `endpointHostname`/`endpointPort`/`publicKey`/`allowedNetworkV4`/`allowedNetworkV6`/
  `reasonCode` only — no handshake field) — this is a *different* surface than
  `docs/api-contract.md`'s `meshPeers` JSON response (which deliberately omits the public key per
  a claim already verified above); the two docs are consistent, not contradictory, since one
  describes the durable Firestore doc and the other describes the API response that points to it.
  All spot-checked claims hold.
- `docs/github-deployment-setup.md` mesh-range diff (`source_ref` rebuild paragraph) — "a normal
  rebuild keeps the WireGuard key, tunnel subnets, and endpoint hostname" is the same claim
  checked above for `deployment-handoff.md`, from the same evidence (unchanged tfvars across a
  `source_ref`-only rebuild). Confirmed, no drift.
- `docs/vm-loss-recovery.md` mesh-range diff ("Standard Recovery" section rewrite) — the doc
  dropped the old step "update `Regions/{regionId}.wireguardEndpointIpv4`... to the new IP" in
  favor of "Registration updates `Regions/{regionId}` with the current endpoint metadata" —
  checked this isn't silently dropping a now-still-necessary manual step: `register.py`'s
  self-registration (`cloudgateway-register-region`, run automatically at the end of bootstrap
  per `bootstrap.sh`) discovers the host's public IPv4 itself and upserts the region doc, so a
  manual IP field edit is no longer part of the operator's job — the doc correctly reflects that
  registration, not a manual Firestore edit, is now what updates the endpoint IP. "WireGuard
  endpoint roaming updates remote mesh peers after the rebuilt host connects" relies on WireGuard's
  own protocol-level behavior (a peer's endpoint updates from the source address of the last valid
  handshake) plus each remote region's own mesh-sync pass re-resolving the DNS hostname every
  pass (already confirmed above in the `wireguard-drift-repair.md` review) — both mechanisms
  converge to the new IP without a manual step, consistent with the doc's framing. "A Mesh status
  document records the last reconciliation snapshot and does not prove a live WireGuard
  handshake" restates the same accurate claim verified in the `wireguard-drift-repair.md` review
  above (no handshake timestamp is ever persisted).
- `docs/regional-deployment.md` mesh-range diff — "the host self-registers... A failing edge check
  logs whether the local API was healthy... and exits 2; it leaves the stored `enabled` value
  untouched" checked directly against `Backend/API/src/register.py:127-131` (`run_register`'s own
  comment: "A readiness failure must never disable a region that is already serving clients" and
  `set_enabled=True if ready else None`, where `None` means "don't touch the existing value" in
  `FirebaseRepository.upsert_region`) — matches exactly, including the subtlety that this is a
  *change* from the old doc text ("it leaves the region disabled"), and the new text is the
  materially more correct description: a transient edge failure on an already-enabled, already-
  serving region does not flip it to disabled. "Bootstrap runs it twice... second pass is skipped
  when registration did not report a ready region (exit code 2)" matches `EXIT_EDGE_NOT_READY = 2`
  in `register.py:22` and the `REGISTER_STATUS -eq 0` gating in `bootstrap.sh` already verified in
  an earlier pass of this doc. The `systemd-run ... EnvironmentFile=/etc/cloudgateway/api.env`
  recovery command (line 121) is a byte-for-byte match with `scripts/test_terraform_preflight.py`'s
  `RecoveryDocumentationTests` expected string (already confirmed by a prior pass of this doc) and
  with the identical command in `deployment-handoff.md`.
- `docs/quick-deployment.md` mesh-range diff — "Every wrapper apply writes a fresh `source_ref`
  into user_data... so apply always destroys and recreates the OCI instance and changes its
  public IPv4" checked against `scripts/terraform.sh`'s `prepare_next_deploy_tag`/`create_deploy_tag`
  (lines 138-197): every apply run computes a strictly-incrementing `deploy-v<x>` tag (patch+1 at
  minimum off the latest existing tag) and writes it as `source_ref` for every listed region, so
  `source_ref` changes on every apply, not just ones with real code changes — confirmed accurate,
  matches `github-deployment-setup.md`'s independently-verified claim that any `source_ref` change
  forces a destroy/recreate (OCI disallows in-place `user_data` changes). "A normal rebuild keeps
  the existing WireGuard key, tunnel subnets, and endpoint hostname" is the same claim verified
  twice above. The commit/tag/push mechanics trimmed from this paragraph (which region's
  `Deploy v<x>` commit workflow) are deployment-rollout sequencing detail, out of scope per the
  review's ground rules, and the underlying behavior is unchanged in `scripts/terraform.sh` either
  way.
- `scripts/terraform-preflight.py` — read the full file (890 lines) at HEAD and cross-checked `terraform.sh`. Verified: overlap detection (`evaluate_subnet_plan`, `validate_subnet_registry`) covers all pairs in both v4/v6, registry allocations must be canonical `/24`/`/64` and inside the fixed aggregates, `wg_address_v4/v6` must be the exact first host address of their network, DNS address must equal the interface IP. Confirmed `terraform.sh` always constructs `--var-file` as `$TFDIR/${region_id}.terraform.tfvars` (line 79), so the canonical-sibling-filename gating in `split_blocking_siblings`/`is_canonical_sibling` can never cause the *currently selected* region's own tfvars to be silently downgraded to a non-blocking note in normal wrapper usage (it would only matter for a hand-invocation of `terraform-preflight.py` with a non-canonical `--var-file`, which is not how the wrapper calls it). Verified exit-code parity: `main()` catches `RuntimeError` (which `TfvarsParseError` subclasses) around `check_region(...)` and always returns 1 on any failure path, `check_region` returns 1 on every error branch and 0 only after all checks pass; `terraform.sh` never captures `$?` from the `python3 "$PREFLIGHT"` calls, relying on `set -euo pipefail` to abort the whole script on any nonzero preflight exit — contract holds. `require_active`/`--no-require-active` wiring: `terraform.sh` passes `--no-require-active` only from `save_destroy_plan`/`destroy`'s `preflight_region ... false` call, matching the README's guidance that decommissioned regions stay `status: reserved` and must still be destroyable.
- `Infrastructure/OCI/terraform/cloudgateway.tf` — read full mesh diff (231 lines). New `wg_interface`/`wg_rate_limit` regex validations close shell-injection surface for values interpolated unquoted into `PostUp`/`PostDown` lines in `bootstrap.sh`. New `oci_core_instance.generated_oci_core_instance` `lifecycle.precondition` blocks cross-check `wg_network_v4/v6`, `wg_address_v4/v6`, DNS addresses, and the subnet registry (`local.selected_registry`) at plan/apply time, duplicating (defense-in-depth) the Python preflight checks. Confirmed Terraform skips resource preconditions during destroy (docs: "Custom condition checks are not evaluated during a plan to destroy a resource"), so the `status == "active"` precondition does not block destroying a `reserved`/decommissioned region — consistent with `terraform-preflight.py --no-require-active` on the destroy path. `cloudflare_record.wg` (line ~716-721) sets `proxied = false` (grey-cloud, required so the WireGuard UDP tunnel isn't proxied by Cloudflare); `cloudflare_record.api` sets `proxied = true`. No `security_list`/`nsg`/ingress rule resources are defined in this file (network security is managed on the pre-existing `subnet_id` referenced from tfvars, outside this file's scope), so there is no `0.0.0.0/0` ingress rule introduced by this diff to review here.
- `Infrastructure/OCI/terraform/subnet-registry.json` — read full file. Two active regions, `us-sanjose-1` (`10.0.0.0/24`, `fd42:42:42::/64`) and `us-chicago-1` (`10.0.1.0/24`, `fd42:42:42:1::/64`), both `/24`/`/64`, non-overlapping, subnets of the `10.0.0.0/16`/`fd42:42:42::/48` aggregates declared in the same file — consistent with `terraform-preflight.py`'s `SUBNET_AGGREGATE_V4`/`SUBNET_AGGREGATE_V6` fallback constants and with `ALLOCATION_PREFIX_V4`/`V6`.
- `Infrastructure/OCI/terraform/terraform.tfvars.example` — placeholder values for `wg_network_v4`/`wg_address_v4`/`wg_dns_address_v4` (`10.0.0.0/24`/`10.0.0.1/24`/`10.0.0.1`) and v6 equivalents match the `us-sanjose-1` registry entry exactly (region index 0 per the file's own "region N uses 10.0.N.0/24" comment), so copying the example for the first region and filling in the rest requires no subnet edits.
- `scripts/terraform.sh` — read full file (338 lines). `PREFLIGHT`/`REGISTRY` paths passed to every `python3 "$PREFLIGHT"` invocation; preflight runs before every `terraform plan`/`apply`/`destroy` call in `plan_region`, `save_apply_plan`, `save_destroy_plan`, and `preflight_region` (destroy). `set -euo pipefail` at top ensures a nonzero preflight exit aborts the whole wrapper before any Terraform mutation runs.
- `scripts/test_terraform_preflight.py` / `scripts/test_terraform_wrapper.py` — skimmed structure (82 test functions across the preflight suite plus 8 wrapper-ordering tests). Coverage includes overlap detection (v4/v6, identical subnets), host-bit/family/canonical-CIDR rejection, aggregate-boundary rejection, sibling-file canonical/non-canonical classification (including duplicate region_id and broken-registry downgrade cases), `require_active` gating for destroy vs plan/apply, first-host/DNS-match checks including IPv4/IPv6 terminal-network edge cases (no overflow), and doc-drift guards (`RecoveryDocumentationTests`) that assert `docs/regional-deployment.md` still contains the exact `systemd-run ... EnvironmentFile=/etc/cloudgateway/api.env ... cloudgateway-register-region` command and that no recovery doc tells an operator to `source`/`. ` the API env file directly. Spot-checked the `regional-deployment.md` doc against `test_registration_recovery_uses_systemd_environment_file`'s expected string — verbatim match at line 121. No coverage gaps found worth flagging as a P2.
- `Infrastructure/OCI/host/bootstrap.sh` mesh-range diff — the mesh PR's entire diff to this file (41 insertions, 2 hunks) is (1) the `CADDY_MODULES="$(...)"` fix that reads the Caddy module list into a variable before grepping instead of piping straight into `grep -q`, avoiding a false "module missing" failure from `caddy list-modules | grep -q` under `pipefail` (Caddy gets SIGPIPE'd on first match before finishing its write); and (2) the post-registration peer sync (lines 893-936). Verified the registration exit-code handling (`REGISTER_STATUS` captured via `|| REGISTER_STATUS=$?` under `set -e`) against `Backend/API/src/register.py`'s `EXIT_OK=0`/`EXIT_REGISTER_FAILED=1`/`EXIT_EDGE_NOT_READY=2` and `run_register`'s `set_enabled=True if ready else None` semantics: bootstrap only runs the second `cloudgateway-sync-peers` pass when `REGISTER_STATUS -eq 0` (i.e. `ready=True`, region actually enabled), matching the comment's stated reason (a disabled region has an empty desired peer set, so syncing would tear down every client peer) — confirmed correct, not just asserted. Confirmed no `[Peer]` block is ever written to `/etc/wireguard/$WG_INTERFACE.conf` (grep for `[Peer]` across the whole file returns nothing); the file stays interface-only per the project rule, with the comment at line 197-199 stating this explicitly. The nftables `cg_tunnel4`/`cg_tunnel6`/`cg_pairs`/`cg_slot` ACL table (lines 169-194) is unchanged by the mesh-range diff (confirmed via `git diff e4db044..bc7d99a` — zero hits for `cg_tunnel`/`cg_pairs`/`cg_slot`/`cloudgateway.nft`) and was already reviewed by ACL-C; not re-reviewed here per the overlap note, beyond noting its `cg_tunnel4`/`cg_tunnel6` elements (`10.0.0.0/16`, `fd42:42:42::/48`) match the mesh aggregate declared in `subnet-registry.json`.

## Summary

Reviewed every file in the SS-D chunk (infra, Firebase, scripts, docs) against the Shared Subnet
Mesh diff `e4db044..bc7d99a`, reading the real files at HEAD for context. For the files ACL-C had
already reviewed on the ACL range (`firestore.rules`, `schema.ts`, `firestore.rules.test.ts`,
`scripts/test.sh`, and most of the `docs/` set), only the mesh-range portions were reviewed here;
ACL-C's ACL-range conclusions were not duplicated.

**No P0/P1/P2/P3 findings in this chunk.** Every operator-facing doc claim that could plausibly
mislead an operator into an unsafe or wrong action was cross-checked directly against the
implementing code (`Backend/API/src/sync.py`, `wireguard.py`, `firebase.py`, `register.py`,
`Infrastructure/OCI/host/bootstrap.sh`, `scripts/terraform.sh`, `Infrastructure/OCI/terraform/
stub-cloud-init.sh.tftpl`) rather than taken on faith, including: the non-blocking-lock/
`SYNC_IN_PROGRESS` contract for `POST /admin/sync` vs. the blocking boot/post-registration sync;
the exact derivation and persistence of `meshEnabled`; `meshStatusWritten`/`mesh_status_write_failed`
never failing an otherwise-successful sync; `clientPeersDegraded` protection following client
status, not record shape; mesh-candidate collision/overlap/duplicate-key rejection happening
entirely before any peer is applied; per-call timeouts on every `wg`/`ip` invocation and the
endpoint DNS lookup; the mesh route-reconciliation aggregate scope and `mesh_route_reclaimed`
signal; what the persisted `Mesh/{regionId}` Firestore doc contains (region metadata and public
keys, explicitly never a handshake timestamp) versus what the admin API JSON response omits
(the public key, by design, since the Firestore doc is the source for it); that a rebuild
(`source_ref` change forcing OCI instance destroy/recreate) preserves the WireGuard private key,
tunnel subnets, and endpoint hostname because none of those come from anything regenerated per
boot; and that a failed edge-readiness check during self-registration leaves the previously
stored `Regions/{regionId}.enabled` value untouched rather than disabling an already-serving
region. No drift was found between any reviewed doc and the code it describes.

On the authz question specifically: `Backend/Firebase/firestore.rules`' mesh-range diff (new
`Regions/{regionId}` `allow update` restricted to the single `meshEnabled` boolean field via
`affectedKeys().hasOnly(['meshEnabled'])`, and new `Mesh/{regionId}` admin-only-read/no-write)
has no path for a non-admin user to read or write either collection, and no path for an admin to
smuggle other Region fields through the mesh toggle or to create/delete a Region doc via that
rule. `Backend/Firebase/tests/firestore.rules.test.ts`'s new tests assert denial paths (non-admin
reads, field-bundling, wrong type, doc create/delete via the narrow rule), not just success paths.

Also worth noting as a genuine (in-scope) fix rather than a finding: `scripts/test.sh`'s
`run_step` rewrite closes a real, if narrow, silent-pass gap where a `cd`-failure early return
from a `test_*` target function (before any `run_check` call) previously printed `OK` instead of
`FAILED`.

Nothing in the assigned scope was skipped. `scripts/ios-release.sh`, `Infrastructure/OCI/README.md`,
and all eight assigned `docs/*.md` files were read and cross-checked against code for the
mesh-range diff specifically.
