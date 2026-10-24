# CLI add implementation review

Review of the uncommitted `add <region> <name>` implementation on `mac-cli`.
Required names, display-name/city/full-ID regions, controller-owned creation,
acceptance before confirmation, and unchanged VPN state are the intended behavior.

The unsigned macOS suite passed before review: 618 macOS tests, shared/auth tests,
both strict Periphery scans, arm64 app/extension build, and 58 packaged CLI checks.
Reviewers made no commits or pushes. The user authorized a local commit after
successful implementation, review, and unsigned validation.

Review complete. Secure Codex 6.1 Sol High performed both implementation reviews
and the follow-up. Main Codex 6.1 Sol High supplied the initial supporting
coverage inventory. All future subagents use Secure, per the user's updated
preference.

Secure input/output review — PASS

No confirmed actionable bugs or security issues found in the requested scope: required names and normalization/bounds, help and flags, prepared-region display/city/ID matching without existing clients, known-capacity checks, mutation-submit compatibility, text/JSON output and sanitization, docs, and packaged static fixtures.

Inspected the full uncommitted diff and the untracked /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCLITests/CloudGatewayMacCLIAddTests.swift. Checked the existing controller IPC validation and backend name contract to trace input/output guarantees. Deep controller/session lifetime review remains with the other reviewer.

Static review only. No tests, builds, live app, VPN, Firebase, SSH, or child agents were run. The existing /tmp/cloudgateway-cli-add-final.log ends with all checks passed. No production code, tests, index, branches, or commits were changed.

Secure controller review — P2 (fixed and re-reviewed): Preserve auth failures during region preparation

Location: /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIMutations.swift:65

Trigger: A signed-in caller runs `cloudgateway add sanjose "Mac mini"`, and the capacity request receives HTTP 401/403 during `.prepareClient` (for example, access was revoked after the initial snapshot).

Effect: The production inventory adapter raises accessDenied. /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:881 denies cached access, signs out, sets accessResult to denied, and rethrows. /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift:582 reduces this to unavailable. The new CLI catch then always emits network_unavailable (exit 6) with a retry suggestion, even though the account was denied and signed out. This misclassifies a confirmed authorization failure as a transient network failure for both humans and automation. No creation is reserved in this case.

Smallest fix: After preparation returns unavailable, attempt a current snapshot and apply the existing accessDenied/signInRequired checks when the account is absent. Fall back to networkUnavailable for a retained unreachable session or when no better state can be read. This can stay in the CLI without adding a controller feature.

Static review also traced the untracked /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCLITests/CloudGatewayMacCLIAddTests.swift, production XPC cancellation, session-bound preparation closure, reservation/confirmation, receipt replay prevention, controller-owned execution, inventory creation adapter, and partial-success/unknown outcomes. No other confirmed actionable findings in this scope. No tests, builds, live app, VPN, Firebase, SSH, or delegation were run. Only this append changed a repository file.


Secure follow-up review — PASS

The original P2 is resolved. In /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIMutations.swift:65, preparation unavailable now triggers one best-effort snapshot. An absent account with denied access returns access_denied (exit 3), other absent-account states return sign_in_required (exit 3), and retained unreachable or still-authorized states retain network_unavailable (exit 6). A failed diagnostic snapshot also retains the original network classification. Traced the production denial path through signOut, snapshot projection, and the orchestrator's unavailable reply. The frontend throws reply.error without marking a successful transport disconnected, so this follow-up snapshot can read the denial.

Inspected the final implementation diff and the complete untracked /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCLITests/CloudGatewayMacCLIAddTests.swift. Its new auth-state cases use .init(error: .unavailable), matching the production orchestrator response, and assert exact error codes/exits, a second snapshot, and no create/confirm. The failed-follow-up case covers the network fallback. These are injected controller states, with the production transition checked by static tracing.

No remaining actionable findings in the requested scope. The follow-up uses the existing caller deadline in /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLISession.swift:134, so it cannot extend the wait beyond that deadline. Direct preparation timeouts still propagate as exit 8. Task.checkCancellation after the optional snapshot preserves caller interruption instead of swallowing it as a network failure. Every preparation-failure branch exits before reservation, while successful creation retains the prepared context, acceptance-before-confirmation, session-bound controller submission, and unchanged VPN behavior.

Static review only. No tests, builds, live app, VPN, Firebase, SSH, Git mutations, or delegation were run. Parent owns the current validation run. This single append is the only file write performed by this reviewer.

## Final outcome

- Secure input/output review passed
- Secure controller review found one P2 auth-error classification issue
- Fixed the P2 in the CLI, added exact-error/exit regressions, and received a fresh
  Secure follow-up PASS with no remaining actionable findings
- Main's supporting analysis found no additional production mismatch. It noted
  that CLI tests inject controller replies while existing controller suites
  separately cover real session fences, creation handoff, and VPN behavior

Final unsigned validation:
`PATH=/opt/homebrew/bin:$PATH ./scripts/test.sh macos` exited 0 with All checks passed.
This includes 620 macOS tests, shared/auth tests, both strict Periphery scans,
unsigned arm64 app/extension build, packaging verification, and 58 packaged CLI
checks. Log: /tmp/cloudgateway-cli-add-reviewed-final.log

The implementation and review fixes are ready for the user-authorized local
commit. No push, signed build, installed app change, live Firebase, VPN, or SSH
operation was performed.
