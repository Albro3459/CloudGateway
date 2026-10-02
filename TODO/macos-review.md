# macOS implementation review

Status: source review complete, branch `apple` at `88508d0`, 2026-10-02.

Scope: macOS menu app, browser authentication, offline inventory, VPN profile
coordination, packet-tunnel extension, authenticated IPC, System Keychain,
packaging, and shared macOS-only code. This review records findings without
changing production code or activating the extension/VPN.

## Review notes

* [Security and tunnel lifecycle](macos-review-security.md)
* [Browser authentication and native sessions](macos-review-auth.md)
* [Menu, inventory, and config coordination](macos-review-menu.md)
* Packaging and integration findings are recorded below

Three GPT 6.1 Sol High reviewers covered security/tunnel lifecycle, auth, and
menu/config coordination. The main reviewer checked integration and packaging,
verified findings, and consolidated overlapping setup issues.

## Confirmed findings

| Priority | Finding | Detail |
|---|---|---|
| P1 | Known admin downgrade still permits fallback to other owners' cached configs | [MENU-01](macos-review-menu.md) |
| P2 | Existing extension hides the upgrade path | MAC-01 below |
| P2 | Refresh clears a required-restart state | MAC-02 below |
| P2 | Failed session restoration offers no Sign Out/account-switch action | [Auth review](macos-review-auth.md) |
| P3 | Accepted install payload can become an unreadable Keychain record | [SEC-01](macos-review-security.md) |

Resolve MENU-01 before release. Cache authorization must reflect a known role
reduction before a later inventory failure can select offline fallback. The
other findings need version-aware setup state, a retained-session sign-out
action, and consistent encoded-record bounds.

The architecture fits the intended scope: a thin AppKit menu, host-free
coordinators, extension-owned secrets, authenticated IPC, and fenced auth/tunnel
operations. No broad refactor or new dependency is needed to address these
findings. The gaps are in integration state and cache authorization.

## Packaging and integration findings

### MAC-01: Existing extension hides the upgrade path (P2)

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

* Location: `Frontend/Apple/macOS/CloudGateway/CloudGatewayExtensionActivationCoordinator.swift:14-25,60-67`
  and `CloudGatewayMacAppController.swift:513-516`
* Trigger: activation completes with `willCompleteAfterReboot`, then the user
  selects Refresh before restarting
* Behavior: `refreshReadiness()` immediately replaces `awaitingRestart` with
  `checkingConnection`. A responding old extension changes the state to `ready`;
  a failed ping changes it to `required`
* Impact: the restart instruction disappears and the UI can enable connection
  before the replacement extension is active
* Fix: retain the restart requirement until the expected extension version is
  confirmed active after reboot. A generic readiness ping must not clear it
* Evidence: source control flow and Apple's activation documentation confirmed
  the transition. No live reboot-required installation was attempted

## Validation

The preceding full `./scripts/test.sh` run passed at this revision. During this
review, `./scripts/test.sh macos` also exited 0 with `All checks passed.` Its
log is `/tmp/cloudgateway-macos-review-validation.log`. It covered 260 shared
Kit/AppCore tests, 31 Firebase adapter tests, 73 macOS core/IPC tests, packaging
tests, both strict macOS Periphery scans, the unsigned arm64 build, and bundle
inspection. Existing tests do not cover the confirmed integration failures.

Findings are source-confirmed. SEC-01 also has a synthetic JSON size calculation.
No live role downgrade, extension replacement, or native auth/VPN action was
performed. Signed activation, real XPC/System Keychain access, native Firebase
persistence, cross-process/user VPN commands, and networking remain runtime
gates. No keys, configs, tokens, or traffic were logged.

Production code and the git index remain unchanged. Only these review notes
were added. Resolved hypotheses and the existing backend access-policy
consistency question remain in the component notes for follow-up.
