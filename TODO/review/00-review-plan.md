# Stacked PR Review Plan: shared-subnet + access-control-lists

Written to the `access-control-lists` branch. All findings land under `TODO/review/`.

## Diff ranges

| PR | Range | Scale |
| --- | --- | --- |
| Shared Subnet Mesh | `e4db044..bc7d99a` | 97 files, +15482 / -917 |
| Account-Scoped ACL (stacked) | `bc7d99a..57bc1d2` (HEAD) | 69 files, +11006 / -139 |

Merge base for both against `main`/`dev` is `e4db044`. ACL branches off `bc7d99a`
(`shared-subnet` head).

## Ground rules given to every reviewer

* No findings about legacy support, migration/cutover sequencing, or deployment
  rollout. `shared-subnet` is already deployed (`deploy-v1.0.25`). ACL is complete
  but not yet deployed.
* Read the real files at HEAD, not only the diff hunks. A hunk that looks wrong in
  isolation is often correct in context, and vice versa.
* Cite `path:line`. Every finding needs a concrete failure scenario.
* Findings are written incrementally, appended as each area completes, so partial
  work survives an interrupted run.
* Security is escalated immediately: exposed secrets, unsafe command execution,
  auth/authz flaws, WireGuard key leaks, Firebase credential leaks, and any logging
  of VPN traffic, DNS queries, tunnel IPs, packet metadata, per-user connection
  history, full configs, or auth tokens.

## Severity scale

* **P0 Critical** — security hole, data loss, or a bug that breaks the tunnel or the
  account boundary in normal operation.
* **P1 High** — real correctness bug reachable on a normal path; wrong behavior under
  concurrency, error, or partial-failure conditions.
* **P2 Medium** — narrow-path bug, missing validation, misleading state, or a real
  test-coverage gap on load-bearing logic.
* **P3 Low** — clarity, dead code, duplication, minor inefficiency, doc drift.

## Chunk assignments

### Shared Subnet Mesh (`e4db044..bc7d99a`)

| ID | Area | Output |
| --- | --- | --- |
| SS-A | API core: `wireguard.py`, `sync.py`, `repository.py`, `register.py`, `firebase.py`, `routes.py`, `models.py`, `enums.py`, `errors.py` + tests | `10-ss-api.md` |
| SS-B | Web dashboard: `Home.tsx`, `ServerHealth.tsx`, `meshHelper.ts`, `meshValidation.ts`, `APIHelper.ts`, stores, `Login.tsx`, components + tests | `11-ss-web.md` |
| SS-C | Apple: `CloudGatewayAppCore` mesh/sync/health sources, iOS `ServerHealthView`, adapters, Swift tests | `12-ss-apple.md` |
| SS-D | Infra + Firebase + scripts: `terraform-preflight.py`, `terraform.sh`, `cloudgateway.tf`, `subnet-registry.json`, `bootstrap.sh`, `firestore.rules`, `schema.ts`, docs | `13-ss-infra.md` |

### Account-Scoped ACL (`bc7d99a..HEAD`)

| ID | Area | Output |
| --- | --- | --- |
| ACL-A | Policy engine: `policy.py`, `policy_sync.py` + their tests, concurrency and bootstrap-contract tests | `20-acl-policy.md` |
| ACL-B | API integration: `routes.py`, `repository.py` (slots + monotonic addressing), `firebase.py`, `sync.py`, `app.py`, `errors.py`, account cleanup + tests | `21-acl-api.md` |
| ACL-C | Host filter + Firebase + docs: `bootstrap.sh` nftables, `firestore.rules`, `schema.ts`, `scripts/test.sh`, ops docs | `22-acl-infra.md` |
| ACL-D | Clients: web `policyHelper`/`ServerHealth`/`APIHelper`, Apple `CloudGatewayPolicyStatus`/mapper/view model/`ServerHealthView` + tests | `23-acl-clients.md` |
| ACL-E | Release migration: `releases/access-control-lists/backfill_account_slots.py` + tests + README | `24-acl-migration.md` |

### Cross-cutting

| ID | Area | Output |
| --- | --- | --- |
| X-1 | Seam between the two PRs: mesh subnet-width `AllowedIPs` vs the nftables boundary, address-allocation change, lock interaction, boot ordering, threat-model gaps | `30-cross-cutting.md` |

Run after the per-chunk passes so it can build on their findings.

## Consolidation

`99-summary.md` — deduplicated, severity-ranked roll-up across all chunk docs.

## Run state

Session 1 (2026-08-19, thread "Review ACL and Shared-Subnet PRs") was killed by
usage limits mid-dispatch. Recovered state:

| Chunk | Session 1 progress | Findings on disk |
| --- | --- | --- |
| SS-A | read most API core; verdict "clean" on `errors.py`/`enums.py`; cut off in `test_wireguard.py` | 0 |
| SS-B | read all main web sources, no conclusions stated | 0 |
| SS-C | 3/25 files done, 1 finding written | 1 (P1) |
| SS-D | scope essentially exhausted, repeated "no findings" verdicts; cut off on `cloudgateway.tf` cloudflare_record check | 0 |
| ACL-A | read `policy.py`/`policy_sync.py`, cut off in `test_policy.py` | 0 |
| ACL-B | read `repository.py`/`firebase.py`/`routes.py`, cut off on `PolicyCoordinator` threading | 0 |
| ACL-C | read `bootstrap.sh`, cut off cross-checking `MESH_AGGREGATE`/fwmark markers | 0 |
| ACL-D | template only, no files read | 0 |
| ACL-E | never started; output file did not exist | 0 |
| X-1 | never launched | 0 |

Session 2 re-runs every chunk from scratch (session-1 verdicts were not written
down, so they are not citable). Max 3 reviewers concurrently.

- Wave 1: ACL-A, ACL-B, ACL-C — the account-isolation boundary, highest risk.
- Wave 2: SS-A, ACL-D, ACL-E.
- Wave 3: SS-B, SS-C, SS-D.
- Wave 4: X-1, then `99-summary.md`.

Every chunk doc now also carries a `## Clean (no findings)` section so that
confirmed-clean coverage survives an interrupted run, not just defects.

## Run state — session 3 (2026-08-19, thread "Continue ACL/Mesh review")

Session 2 died on a monthly spend limit. Recovered state from the on-disk docs:

| Chunk | Status entering session 3 | Findings on disk |
| --- | --- | --- |
| ACL-A | Complete | 1×P2, 1×P3 |
| ACL-B | Complete | 1×P2 |
| ACL-C | Complete | 0 (clean, with 2 handoffs to X-1) |
| ACL-D | Complete | 0 (clean, parity matrix written) |
| ACL-E | Complete | 1×P1, 2×P2 |
| SS-A | Complete | 2×P2 |
| SS-B | **Complete** (session 3) — all boxes ticked, `## Summary` written | 2×P2 |
| SS-C | **Complete** (session 3) — all 26 boxes ticked, duplicate `## Clean` heading merged, `## Summary` written | 2×P1 |
| SS-D | **Complete** (session 3) — all 22 boxes ticked, `## Summary` written | 0 (clean) |
| X-1 | **Complete** (session 3) — all 6 focus items ticked, all 5 handoffs resolved, `## Summary` written | 1×P2 |

Session 3 dispatch: wave 3 = SS-B, SS-C, SS-D (finish the partials only, no
re-review of ticked files). Then wave 4 = X-1, then `99-summary.md`.

**Session 3 outcome: review complete.** All ten passes (SS-A..SS-D, ACL-A..ACL-E, X-1)
closed, and `99-summary.md` is written — 11 findings post-merge (0×P0, 3×P1, 7×P2,
1×P3; 13 raw before merging the slot-reuse defect class into one entry).
