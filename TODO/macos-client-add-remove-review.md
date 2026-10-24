# Review CLI add and controller removal

Reviewed snapshot: `ceeeb5c816c35aa7d3733601c90c87a7fdc121b2`
Date: 2026-10-24
Worktree: `/Users/alexbrodsky/GitHub/CloudGateway-review-ceeeb5c8` (detached HEAD)

Scope: `cloudgateway add <region> <name>` and controller-owned client removal,
including their IPC, session, inventory, HTTP, cache, and profile boundaries.
The removal CLI command and menu action remain intentionally deferred.

## Findings at the reviewed snapshot

The original review found one new P2 and reconfirmed one previously tracked P2.
No confirmed actionable issues were found in controller removal. Both add fixes
are implemented, reviewed, and validated unsigned in this worktree.

### P2: CLI add reports ordinary API failures as account access denial

Location: [creation error handling](/Users/alexbrodsky/GitHub/CloudGateway-review-ceeeb5c8/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:1114)

- Trigger: an authorized user has reached their per-region client limit while
  the region still has free capacity, then runs `cloudgateway add sanjose "Mac mini"`.
  Region preparation succeeds, but [reservation](/Users/alexbrodsky/GitHub/CloudGateway-review-ceeeb5c8/Backend/API/src/firebase.py:574)
  returns HTTP 409 `LIMIT_REACHED`.
  A capacity race returning 409 or a server error returning 500/503 follows the
  same path.
- Cause: the [shared HTTP client](/Users/alexbrodsky/GitHub/CloudGateway-review-ceeeb5c8/Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayControlPlaneClient.swift:252)
  uses `apiAccessDenied` for 401/403 and `accessDenied` for every other non-2xx
  response. The [production creation adapter](/Users/alexbrodsky/GitHub/CloudGateway-review-ceeeb5c8/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacInventoryService.swift:146)
  forwards that error. The controller treats the ordinary `accessDenied` case
  as `.failed(.accessDenied)` before its uncertain-creation handling can run.
- Effect: both text and JSON report `access_denied`, exit 3, and suggest signing
  in after access is restored. The controller retains the authorized session.
  Reauthentication cannot fix a client limit or server outage, and automation
  receives an auth failure instead of the actual failure category or uncertainty.
  Operation lookup retains the same incorrect typed result.
- Fix: reserve auth-denied outcomes for actual auth/access failures. Preserve
  structured HTTP status/error codes if precise limit/capacity errors are needed.
  Without that evidence, treat an ordinary API error after a possible POST
  dispatch conservatively as unknown and direct callers to inspect inventory.
  Do not infer success or a safe retry from API message text.
- Coverage gap: [shared decoder fixtures](/Users/alexbrodsky/GitHub/CloudGateway-review-ceeeb5c8/Frontend/Apple/CloudGatewayKit/Tests/CloudGatewayAppCoreTests/CloudGatewayControlPlaneClientTests.swift:198)
  already prove that 409 and 503 become `CloudGatewayAppError.accessDenied`.
  The [controller outcome fixture](/Users/alexbrodsky/GitHub/CloudGateway-review-ceeeb5c8/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:1285)
  injects `CloudGatewayMacInventoryError.offline`, so it misses the production
  HTTP error path. Add controller-to-CLI assertions for real 409/500/503 responses
  alongside 401/403, including the typed outcome, exit, recovery hint, retained
  account, and exactly one POST.

### P2: An accepted add blocks local Disconnect (already tracked)

Locations: [IPC admission](/Users/alexbrodsky/GitHub/CloudGateway-review-ceeeb5c8/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift:434)
and [domain stop admission](/Users/alexbrodsky/GitHub/CloudGateway-review-ceeeb5c8/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:1210)

- Trigger: leave an owned VPN connected, confirm an add, and hold its cloud POST
  or final inventory read open. Run `cloudgateway down` from another caller.
- Effect: IPC rejects the stop as busy while `runningOperation` belongs to add.
  The domain also rejects both global stop and target Disconnect while creation
  occupies `commandTask`. A slow cloud request prevents an independent local stop
  until creation finishes. The menu stop availability uses that same command gate.
- Fix: allow local stop independently of cloud-only creation at both admission
  layers. Preserve add's task, completion, and operation recovery while the stop
  runs. Changing only IPC admission would leave the domain rejection in place.
- Coverage gap: hold creation at cloud and inventory boundaries, then prove a
  second frontend can complete a confirmed stop without cancelling or losing
  add's eventual outcome. Include reservation/confirmation and result lookup.

This was already open in [the CLI plan](/Users/alexbrodsky/GitHub/CloudGateway-review-ceeeb5c8/TODO/macos-cli.md:865).
The review reconfirms it at this commit rather than counting it as a new finding.

## Controller removal

No confirmed actionable bugs found. Reviewed fresh owner/role resolution,
account-bound reservation/confirmation, session fences, durable eviction before
DELETE, final inactive-profile checks, dispatch evidence, uncertain outcomes,
exact profile cleanup, deferred inventory, replay limits, and outcome redaction.
Existing coverage exercises the production-used HTTP and profile helpers.

The absent removal frontend, retained committed secrets, and possible orphan
profiles after failed cleanup are documented design choices. The earlier CLI
preparation auth-classification finding is fixed in this snapshot.

## Review record

- Main Codex, `gpt-6.1-sol`, high reasoning: CLI add, parser/output, controller
  creation, production adapters, and existing coverage. Confirmed both add
  findings above and the earlier preparation fix
- Secure Codex, `gpt-6.1-sol`, high reasoning: controller removal across domain,
  IPC, cache, HTTP, profiles, cancellation, replay, and coverage. No actionable
  findings
- Parent: independently traced both production flows and identified the new
  ordinary HTTP error classification finding
- Secure focused follow-up: independently confirmed the new P2, its user-limit
  trigger, retained authorization, CLI result, and missing integration coverage

The original review was a source review and documentation change. Existing tests were inspected,
but no tests, builds, signed runtime checks, cloud calls, or VPN operations were
run for this review. Prior validation logs in implementation notes are historical.
Manual review checked the report against source and verified its local links
and whitespace. Only this report changed during the original review. No branches, commits, or
pushes were made during that review. Implementation and validation follow below.

## Fix implementation

The user authorized implementing both fixes, tests, fresh review, and local
commits in the detached worktree. The original checkout stays untouched.

- The ordinary HTTP-error catch now follows the existing conservative attempted
  creation outcome. Real 401/403 handling and session redaction remain intact
- Regression coverage runs actual shared HTTP decoding through the controller,
  IPC, and CLI for 401/403/409/500/503 in text and JSON modes
- Secure approved the production error fix. Its first review found two fixture
  assumptions: sign-out hides account-bound auth outcomes from the CLI, and text
  recovery hints use diagnostics. Both expectations were corrected
- Main implemented independent creation/stop ownership in the domain and IPC,
  separate bounded result retention, and the optional menu stop capability. Tests
  cover both confirmation/completion orders, held POST/final inventory, deferred
  refresh, exact request counts, target isolation, account changes, expiry, and
  cross-slot ID collisions
- The initial macOS run caught those fixture assumptions and a missing local
  Firebase app configuration in the new worktree. The existing app configuration
  was copied without exposing its contents. The unsigned app/extension build and
  58 packaged CLI checks passed. A stable combined validation run followed

Secure's fresh aggregate review passed with no actionable findings. Main's
supporting review found that the creation fixture omitted production's
post-response cancellation/account checks. The fixture now mirrors those checks,
and the held-POST account-change test expects unknown with redacted account
output. Main's focused follow-up passed with no new actionable findings.

The combined validation passed all 732 macOS package tests, but its Periphery
app scan read index data from another worktree through the tool's shared cache.
A validation-only wrapper now gives that scan `--skip-build` and this worktree's
explicit app index path, following [Periphery's CI workflow](https://github.com/peripheryapp/periphery#continuous-integration).
The app index came from the successful unsigned build of these production
sources. Strict analysis remains enabled, and the host-free scan uses its normal
package index. No test runner or scan configuration is changed in the repository.
The final full runner passed. No live cloud or VPN operations were used.

## Final validation

- [x] Fix ordinary creation HTTP-error classification and cover real HTTP replies
- [x] Allow local stop during add reservation, handoff, POST, and final inventory
- [x] Preserve independent results, session fences, cancellation, and menu gates
- [x] Pass Secure aggregate review and Main's HTTP/fixture follow-up
- [x] Pass the complete unsigned macOS runner and final diff review

Command: `PATH=/tmp/cloudgateway-add-fixes-tools:/opt/homebrew/bin:$PATH ./scripts/test.sh macos`

Passed: 732 macOS package tests, 280 shared XCTest tests, 263 shared Swift Testing
tests, 31 Firebase auth adapter tests, both strict Periphery scans, unsigned arm64
app/extension build, packaging verification, and 58 packaged CLI checks.
Log: [/tmp/cloudgateway-add-fixes-macos-final.log](/tmp/cloudgateway-add-fixes-macos-final.log).
The temporary wrapper only selects the app index for strict Periphery analysis,
as described above. Shared Apple production sources and dependencies are unchanged.
Signed IPC, live Keychain/NetworkExtension behavior, and the signed runtime matrix
remain separate runtime acceptance work.

The final report's local links and whitespace were checked. The user authorized a local
commit containing both fixes and this review record in the detached worktree. No branch was created, and nothing was pushed.
