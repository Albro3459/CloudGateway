# macOS controller and CLI review

Review completed 2026-10-23 at `5ba539b7` on `mac-cli`.
Stack #18 includes [PR #17](https://github.com/Albro3459/CloudGateway/pull/17)
(controller refactor) and [PR #16](https://github.com/Albro3459/CloudGateway/pull/16)
(CLI), reviewed together against `origin/main`.

Scope: standout bugs and security issues. Source review only, with no repeated
functional testing, builds, installed app changes, or live VPN operations.
No code fixes, staging, commits, or pushes are part of this review.

Reviewers use Codex 6.1 Sol High across Main and Secure. Confirmed findings are
recorded as they are found in the linked notes, then checked for duplicates and
concrete impact before the final summary.

## Review notes

- [IPC and security](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-review-ipc-security.md), Main
- [Controller auth and state](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-review-controller-auth.md), Secure
- [Updates and lifecycle](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-review-update-lifecycle.md), Secure
- [CLI and concurrent frontend boundaries](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-review-cli-boundaries.md), fresh Main reviewer
- [Authorization-finding validation](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-review-denial-validation.md), independent Main reviewer
- CLI parsing, output, login frontend, diagnostics, and installation: primary reviewer, Main

## Confirmed findings

- [x] **P1: Preserve authorization denials across parallel inventory reads.**
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacInventoryService.swift:96
  awaits Regions before Clients. If Clients has already failed with Firestore
  permission-denied and Regions then times out, the Regions `.offline` failure
  wins and the Clients denial is discarded. The controller's offline branch
  reloads cached authorization instead of denying it. An admin downgraded after
  the successful access check can therefore retain cached other-user configs
  under this failure ordering. Authorization denial must dominate transport
  failure. Confirmed by the Secure domain reviewer, primary source inspection,
  and an independent Main validation pass.
  [Evidence and fix direction](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-review-controller-auth.md)
  Swift's [async-let error propagation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0317-async-let.md#async-let-error-propagation)
  specifies that errors of children not explicitly awaited are discarded at
  scope exit.

- [x] **P2: Accept historical Mach endpoints when verifying the previous release baseline.**
  /Users/alexbrodsky/GitHub/CloudGateway/scripts/macos-release.py:144 passes
  the previous distributed app through the current verifier, whose check at
  /Users/alexbrodsky/GitHub/CloudGateway/scripts/verify_macos_build.py:213
  requires a build-specific endpoint. Releases from `origin/main` use the
  original fixed endpoint, so selecting one as the mandatory baseline aborts
  release preparation. Applies when the last distributed release uses that
  older format. Confirmed independently against both source versions.
  [Evidence and fix direction](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-review-update-lifecycle.md)

All review passes are complete: three Main delegations (IPC/security, fresh CLI
integration, and focused P1 validation), two Secure delegations (auth/state and
update/lifecycle), plus the primary review. Every delegation used 6.1 Sol High.
No account usage limit or account fallback was encountered.

Both findings above were fixed after review. No additional P1/P2 findings were confirmed.
The P1 requires the stated asymmetric read-failure timing. The P2 applies to a
previous distributed app using the historical fixed endpoint. No distributed
binary or live Firebase outcome was inspected.

## Primary review coverage

Completed source review of CLI parsing/dispatch, selectors, NDJSON and human
output, accepted/confirmed mutations, bounded waits, login terminal cleanup,
doctor probes, CLI symlink/PATH installation, and menu frontend wiring.
No standout bug or security issue confirmed in these paths.

Cross-checked account-filtered state serialization, command outcome hiding,
profile start/stop adapters, inventory requests, and launch/storage helpers
alongside the delegated reviews of their owning state machines.

Validation is source inspection only. Existing functional test results and SSH
behavior are supplied by the user and were not rerun for this review.

The original review created only the six review documents. It left existing
source, the Git index, branch, and commits unchanged and ran no tests or builds.
The follow-up fixes and validation are recorded below.


## Fix review

Reviewed 2026-10-23 on `mac-cli`, HEAD `d4a30a69`, covering the eight
uncommitted files for the two fixes above. Focused source review only.

**PASS: Both original defects are addressed. No new standout bug or security
issue found in these changes.**

- Authorization ordering: [the inventory join](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacInventoryRequest.swift:37)
  captures both child outcomes as nonthrowing results, checks parent cancellation,
  then gives either authorization denial priority before propagating ordinary
  failures. A Regions transport failure cannot discard a completed Clients
  denial. [Production fetchOptions](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacInventoryService.swift:81)
  uses that join, retaining both query filters and the final account/cancellation
  checks. The existing per-read deadlines and cancellation cleanup remain in
  effect. [The held-completion regression](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacInventoryRequestTests.swift:163)
  forces denial to finish before the sibling transport failure in both directions,
  including the original Clients-denied/Regions-offline ordering. Adjacent tests
  cover success, ordinary offline propagation, and cancellation of both stalled reads.
- Historical packaging: [extension_baseline](/Users/alexbrodsky/GitHub/CloudGateway/scripts/macos-release.py:139)
  alone requests historical compatibility. [The verifier](/Users/alexbrodsky/GitHub/CloudGateway/scripts/verify_macos_build.py:210)
  accepts exactly the original fixed endpoint or the endpoint matching the
  extension's own build, without changing signature, team, identifier, entitlement,
  profile, architecture, dependency, or artifact checks. [CLI argument validation](/Users/alexbrodsky/GitHub/CloudGateway/scripts/verify_macos_build.py:330)
  requires Developer ID and rejects combining historical mode with current CLI
  checks. [Current release verification](/Users/alexbrodsky/GitHub/CloudGateway/scripts/macos-release.py:104)
  remains strict across prepare, retry, and validation paths. The original fixed
  endpoint and required metadata were cross-checked against `origin/main` plists.
  [Packaging fixtures](/Users/alexbrodsky/GitHub/CloudGateway/scripts/test_verify_macos_build.py:397)
  cover flag restrictions, both accepted historical formats, rejected foreign or
  wrong-build endpoints, strict rejection of the fixed endpoint for new builds,
  and retained app/extension Developer ID verification calls.
  [Release tests](/Users/alexbrodsky/GitHub/CloudGateway/scripts/test_macos_release.py:47)
  also check distinct baseline/current arguments and baseline signer rejection.

`git diff --check` passed. Regression tests were inspected, not executed.
No builds, tests, installed app, Firebase, VPN, or SSH operations ran in this
review. Unsigned validation belongs to the parent and remains a separate commit
gate. Only this Fix review section was appended. No code, index, branch, or
commit changes were made by this reviewer.

## Fix validation

Implemented both fixes on 2026-10-23. The inventory loader retains both outcomes
and makes authorization denial dominate a sibling transport failure. The release
baseline alone accepts the historical fixed Mach endpoint, with existing signing
and identity validation preserved. New release verification stays strict.

The user clarified that they are the only admin and have no role-change flow.
The authorization race has low practical likelihood in this deployment, so the
original P1 priority overstated the immediate operational risk.

Secure Codex 6.1 Sol High reviewed the final code and regression coverage and
returned PASS, with no new standout bug or security issue. The review is recorded
in the Fix review section above.

`PATH=/opt/homebrew/bin:$PATH ./scripts/test.sh macos` passed unsigned:

- Packaging verifier and release workflow fixtures
- 263 shared Kit/AppCore tests and 31 Firebase auth adapter tests
- 607 macOS host-free core/IPC/CLI tests, including the new denial-ordering,
  successful-result, offline-propagation, and cancellation regressions
- Both strict macOS Periphery scans
- Unsigned Debug arm64 app and system extension build
- Bundle packaging verification and 50 packaged CLI direct/symlink checks

The suite exited 0 with All checks passed. Log:
/tmp/cloudgateway-macos-review-fixes.log

No signed build, installed app changes, live Firebase, VPN, or SSH operations
were performed. The review documents will be removed in a separate commit after
the fixes commit, as requested; this evidence remains in Git history.
