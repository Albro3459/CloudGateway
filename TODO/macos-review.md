# macOS implementation review

Status: all five findings implemented and validated, 2026-10-02. Previous fixes
are committed as `4795d1e`; MAC-01 is complete.
Review baseline: branch `apple` at `88508d0`.

Scope: macOS menu app, browser authentication, offline inventory, VPN profile
coordination, packet-tunnel extension, authenticated IPC, System Keychain,
packaging, and shared macOS-only code. Follow-up fixes address the agreed
findings. No extension/VPN activation is part of this work.

## Review notes

* [Security and tunnel lifecycle](macos-review-security.md)
* [Browser authentication and native sessions](macos-review-auth.md)
* [Menu, inventory, and config coordination](macos-review-menu.md)
* Packaging and integration findings are recorded below

Three GPT 6.1 Sol High reviewers covered security/tunnel lifecycle, auth, and
menu/config coordination. The main reviewer checked integration and packaging,
verified findings, and consolidated overlapping setup issues.

## Confirmed findings

| Priority | Finding | Status | Detail |
|---|---|---|---|
| P1 | Known admin downgrade still permits fallback to other owners' cached configs | Resolved | [MENU-01](macos-review-menu.md) |
| P2 | Existing extension hides the upgrade path | Resolved | MAC-01 below |
| P2 | Refresh clears a required-restart state | Resolved | MAC-02 below |
| P2 | Failed session restoration offers no Sign Out/account-switch action | Resolved | [Auth review](macos-review-auth.md) |
| P3 | Accepted install payload can become an unreadable Keychain record | Resolved | [SEC-01](macos-review-security.md) |

MENU-01 now invalidates old admin access before another inventory request and
records the role authorizing each cache. The other agreed changes preserve
restart state, expose retained-session logout, and enforce write/read record
bounds. The user subsequently authorized MAC-01 so future releases can replace
an existing extension through the menu.

The architecture fits the intended scope: a thin AppKit menu, host-free
coordinators, extension-owned secrets, authenticated IPC, and fenced auth/tunnel
operations. No broad refactor or new dependency is needed to address these
findings. The gaps are in integration state and cache authorization.

## Packaging and integration findings

### MAC-01: Existing extension hides the upgrade path (P2)

* Resolution: implemented and validated. Authenticated XPC readiness
  reports the running extension's build and marketing versions. The app reads
  the embedded extension's own metadata and requires both values to match.
  A mismatched version or an older version-less reply shows Update VPN
  Extension and prevents new connections. Replacement remains an explicit
  activation action, and completion rechecks the responding version
* Coverage: readiness for matching, changed build/release, and legacy replies;
  version reply codec, invalid bundled metadata, and disabled connection rows
  while an update is required
* Location: `Frontend/Apple/macOS/CloudGateway/CloudGatewayExtensionActivationCoordinator.swift:14-27`
  and `CloudGatewayMacAppController.swift:385-388`
* Trigger: launch an updated containing app while an older signed extension
  with the same team and bundle ID is already installed and responding
* Behavior: readiness only pings the Mach service. The reply contains no build
  version, and a successful ping marks setup ready. The menu then hides its
  only activation action, so no activation/replacement request reaches macOS
* Impact: the new app keeps using the old provider, missing provider fixes or
  encountering an incompatible IPC contract. Installing the updated app does
  not provide a product UI path to replace the old extension
* Fix: compare installed/embedded extension versions and retain an explicit
  update/activation action until the embedded version is active
* Evidence: source control flow confirmed. Apple's
  [activation API](https://developer.apple.com/documentation/systemextensions/ossystemextensionrequest/activationrequest(forextensionwithidentifier:queue:))
  describes activation requests as the mechanism for replacing active versions.
  No live extension replacement was attempted

### MAC-02: Refresh clears the required-restart state (P2)

* Resolution: implemented and validated on 2026-10-02. The setup policy
  blocks readiness refresh and activation while awaiting restart. The
  coordinator checks this policy before changing setup state. Host-free tests
  cover both blocked actions and allowed retries from ordinary setup states
* Location: `Frontend/Apple/macOS/CloudGateway/CloudGatewayExtensionActivationCoordinator.swift:14-25,60-67`
  and `CloudGatewayMacAppController.swift:513-516`
* Trigger: activation completes with `willCompleteAfterReboot`, then the user
  selects Refresh before restarting
* Behavior: `refreshReadiness()` immediately replaces `awaitingRestart` with
  `checkingConnection`. A responding old extension changes the state to `ready`;
  a failed ping changes it to `required`
* Impact: the restart instruction disappears and the UI can enable connection
  before the replacement extension is active
* Fix: retain the restart requirement for the current app session. A generic
  readiness ping or another activation request must not clear it. After reboot,
  the app starts a fresh version-aware readiness check
* Evidence: source control flow and Apple's activation documentation confirmed
  the transition. No live reboot-required installation was attempted

## Validation

The preceding full `./scripts/test.sh` run passed at the review baseline. During this
review, `./scripts/test.sh macos` also exited 0 with `All checks passed.` Its
log is `/tmp/cloudgateway-macos-review-validation.log`. It covered 260 shared
Kit/AppCore tests, 31 Firebase adapter tests, 73 macOS core/IPC tests, packaging
tests, both strict macOS Periphery scans, the unsigned arm64 build, and bundle
inspection. Existing tests do not cover the confirmed integration failures.

Follow-up validation passed `./scripts/test.sh apple`, covering both platforms
and all five Periphery scans. After the final cancellation correction,
`./scripts/test.sh macos` passed again with 260 shared, 31 Firebase adapter, and
85 macOS tests, both macOS Periphery scans, unsigned build, and packaging checks.
Logs: `/tmp/cloudgateway-macos-review-fixes-apple.log` and
`/tmp/cloudgateway-macos-review-fixes-final.log`. New regressions cover downgrade
and transport fallback, persisted/cancelled invalidation, retained-session logout,
restart policy, and the encoded-record boundary. A bounded follow-up review
confirmed the integration and cancellation correction without remaining blockers.

MAC-01 passed `./scripts/test.sh apple` with 260 shared, 31 Firebase adapter,
and 90 macOS tests, all five Periphery scans, both unsigned builds, and macOS
packaging verification. Log: `/tmp/cloudgateway-macos-extension-update.log`.
A GPT 6.1 Sol High review confirmed version comparison, legacy compatibility,
menu gating, explicit activation, and restart fencing without blockers.

Findings are source-confirmed. SEC-01 also has a synthetic JSON size calculation.
No live role downgrade, extension replacement, or native auth/VPN action was
performed. Signed activation, real XPC/System Keychain access, native Firebase
persistence, cross-process/user VPN commands, and networking remain runtime
gates. No keys, configs, tokens, or traffic were logged.

The earlier production fixes and regressions are committed as `4795d1e`.
MAC-01 includes its version-handshake and menu-gating regressions. Resolved
hypotheses and the existing backend
access-policy consistency question remain in the component notes for follow-up.
