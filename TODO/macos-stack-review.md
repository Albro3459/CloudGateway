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

- [ ] **P1: Preserve authorization denials across parallel inventory reads.**
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

- [ ] **P2: Accept historical Mach endpoints when verifying the previous release baseline.**
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

Two findings remain open above. No additional P1/P2 findings were confirmed.
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

Only the six review documents were created. Existing source and documentation,
the Git index, branch, and commits were left unchanged. No tests or builds ran.
