# macOS fresh implementation review

Baseline: branch `apple`, commit `8cc964a`, 2026-10-02
Status: all eight resolved and validated, two review loops complete

Reviewed the implementation from entry points and trust boundaries, without
assuming previous fixes proved correctness. Three GPT 6.1 Sol High reviewers
covered authentication, menu/config coordination, and extension security.
The main reviewer checked setup, packaging, integration, and findings.
The fresh review changed review notes only. Implementation follows the
[committed plan](macos-review-implementation.md).

User decision: all eight fixes are approved. M3 retains last observed status
and the existing preferences error without adding visible presentation states.
Review starts only after all eight are implemented, with at most two loops.

## Confirmed findings

| Priority | ID | Finding | Evidence | Status |
|---|---|---|---|---|
| P2 | M2 | Opening the menu hides Turn Off until remote inventory requests finish | [Menu review](macos-review-menu.md) | Resolved |
| P2 | SEC2 | Stop timeout reports completion before the backend confirms stop | [Security review](macos-review-security.md) | Resolved |
| P2 | SEC1 | WireGuard ignores backend startup errors and can report success while down | [Security review](macos-review-security.md) | Resolved |
| P2 | SEC3 | Network-settings timeout proceeds as success without confirmed routes/DNS | [Security review](macos-review-security.md) | Resolved |
| P2 | AUTH-2 | Firebase verification outages become access denials and clear valid sessions/caches | [Auth review](macos-review-auth.md) | Resolved |
| P2 | AUTH-1 | Retained removed-client history can block all online inventory at 1,001 rows | [Auth review](macos-review-auth.md) | Resolved |
| P2 | M1 | Account switching enables commands before old cancellation cleanup finishes | [Menu review](macos-review-menu.md) | Resolved |
| P2 | M3 | Failed preference reads turn unknown VPN status into an off indication | [Menu review](macos-review-menu.md) | Resolved |

These are source-confirmed conditional failures. The backend verification and
WireGuard startup findings involve shared dependencies, so their fixes need
cross-platform validation. They are not confined to macOS source files.
No severe secret disclosure or authentication bypass was established.

## Implementation assessment

The separation between AppKit composition, host-free coordinators, extension
secrets, and shared Apple contracts is appropriate. Avoid a broad rewrite.
The findings need targeted changes to command/state ownership, error
classification, inventory filtering, and backend lifecycle reporting.

Setup review covered the embedded-extension path and version metadata,
authenticated readiness, explicit replacement, approval/restart transitions,
and connection gating. Packaging review covered target membership, extension
entry point, bundle IDs, Mach service, signing configurations, entitlement
boundaries, arm64 support, and runtime library paths. No additional confirmed
setup or packaging defect was found in this pass.

## Validation and limits

`./scripts/test.sh macos` exited 0 with `All checks passed.`
Log: `/tmp/cloudgateway-macos-fresh-review.log`

* Shared Kit/AppCore: 279 XCTest tests and 260 Swift Testing tests
* Firebase adapter: 31 Swift Testing tests
* macOS core/IPC: 90 Swift Testing tests
* Packaging verifier: 8 Python tests
* Both strict macOS Periphery scans found no unused code
* Unsigned arm64 app/extension build and bundle inspection passed

Passing checks do not cover the confirmed integration and dependency failures.
No new tests were added during the review. Findings were verified through
source traces and existing test coverage, with component-specific evidence
and limitations in the linked notes.

Signed installation/replacement, real System Keychain ACL and XPC behavior,
native Firebase persistence, cross-process/user command ordering, and live VPN
networking remain runtime checks. No keys, configs, auth tokens, or traffic
were logged. Actual provider overlap after an early stop completion has not
been established.

## Implementation and bounded review

All eight fixes are implemented. The menu retains the last observed VPN status
without adding visible states. Both Apple projects now build the fixed WireGuard
submodule source. The verifier returns sanitized service errors without denying
valid identities solely because Firebase infrastructure is unavailable.

Review loop 1 found a cancellation-barrier regression and an SDK fixture error,
both corrected. Validation also corrected standalone XCTest loading, mock setup,
and the iOS scan scope for the formerly remote WireGuard library.

* [Loop 1 menu](macos-fixes-review1-menu.md)
* [Loop 1 authentication](macos-fixes-review1-auth.md)
* [Loop 1 security](macos-fixes-review1-security.md)
* [Loop 1 integration corrections](macos-fixes-review1-integration.md)

API validation passed 616 tests with pyright/vulture checks. Both unsigned Apple
builds and all five scans passed. The corrected macOS gate passed with 100 core/IPC
tests, shared package tests, eight packaging tests, Go startup tests, and six Swift
settings tests. Log: `/tmp/cloudgateway-macos-eight-fixes-loop1-harness.log`.
Final loop 2 found no remaining confirmed findings. No third review loop ran.

* [Loop 2 menu](macos-fixes-review2-menu.md)
* [Loop 2 authentication](macos-fixes-review2-auth.md)
* [Loop 2 security](macos-fixes-review2-security.md)

The final no-target `./scripts/test.sh` exited 0 with `All checks passed.`
It covered API, web, infrastructure, Firebase emulator, iOS, and macOS, including
616 API tests, all five Apple scans, both unsigned builds, WireGuard startup/settings
regressions, and packaging checks. Log:
`/tmp/cloudgateway-macos-eight-fixes-full.log`.

No live VPN, extension activation, Keychain, or native authentication action ran.
No repository was pushed. Signed runtime gates remain pending.
