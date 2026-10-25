# macOS controller, CLI, and removal review

Date: 2026-10-24
Reviewed head: `a83ccee6` on `mac-remove-client`
Status: review complete, all three findings resolved by the subsequent fixes

The review covers all three layers of stack 18, including their integration at
the top layer. Existing successful functionality is assumed. The focus is
security, authorization, concurrency, and failures outside the normal workflow.

| Layer | PR | Base | Reviewed head |
|---|---|---|---|
| Controller architecture | [#17](https://github.com/Albro3459/CloudGateway/pull/17) | `main`, `9f426542` | `b7d0410d` |
| Mac CLI | [#16](https://github.com/Albro3459/CloudGateway/pull/16) | controller architecture | `373f854f` |
| Client removal in both interfaces | [#19](https://github.com/Albro3459/CloudGateway/pull/19) | Mac CLI | `a83ccee6` |

## Resolution update

The findings below describe the reviewed snapshot. The user subsequently
authorized all three fixes. The
[fix plan](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-stack-fixes.md)
passed a fresh Secure Codex plan review, and the implementation passed fresh
Secure Codex review round 1 with no actionable findings. Both used
`gpt-6.1-sol` with high reasoning. The fixes are committed with this update.

- Resolved menu removal by using settled account authorization independently of
  browser sign-in state. The
  [retained-session regression](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:53)
  covers online and cached restoration, another refresh, and sign-out.
- Resolved cache recovery by making preload optional while preserving the
  session fence and mandatory fresh authorization/persistence. Tests cover
  [invalid metadata recovery](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:75),
  [offline/denied inventory](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:92),
  and [failed persistence](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:122).
- Resolved false PATH setup success by accounting for later assignments before
  accepting or editing profile configuration. Tests cover
  [rejection without file changes](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacCLIInstallerTests.swift:330),
  [preserved inheritance](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacCLIInstallerTests.swift:355),
  and [explicit restoration](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacCLIInstallerTests.swift:378).

The full unsigned macOS check passed with 789 macOS host-free tests, both
Periphery scans, shared package checks, the unsigned arm64 app/extension build,
packaging verification, and 88 CLI smoke checks. No signed operations ran.
Installer fixtures do not execute real shell startup files; signed platform and
live service behavior remain outside this validation.

## Validated findings

### P2: Enable menu removal after restoring a retained session

Location: [removal gate](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerViewMapping.swift:13)
Introduced in the removal layer, still present at the reviewed head.

Restart the controller with an existing Firebase session and wait for account
restoration and online inventory refresh. The menu's Remove Client action stays
disabled, even though the account is authorized, clients are listed, and Add
Client is available. Refresh does not enable removal.

The gate requires `state.auth == .signedIn`, but this value describes the
browser coordinator. That coordinator starts at `signedOut`.
[Retained-session restoration](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:313)
sets the account without changing the browser coordinator's state, and
[snapshot projection](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:625)
passes that state through. The
[menu](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacAppController.swift:218)
uses the resulting false permission both to disable the item and reject its
action. This affects retained-session startup after reboot or controller exit.

Fresh browser sign-in sets `signedIn`, which explains why removal can pass
manual testing. CLI removal sends its request through a separate path and does
not depend on this menu permission.

Validation: the Main reviewer traced the production path, and the parent
independently checked it and ran a temporary host-free reproduction using the
real controller, account cache, and view mapping. After restoration, the account
was authorized, inventory was current, one client was present, and Add Client
was enabled, while browser state remained signed out and removal stayed
disabled before and after a successful refresh.

Suggested fix: derive removal permission from the settled, authorized account,
or normalize restored authentication presentation consistently. Add a regression
covering retained-session restoration through the production view mapping.

### P3: Let online inventory repair an invalid local cache

Location: [cache preload](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:405)
Introduced by `a96a944a` in the controller layer, still present at the reviewed head.

If an admin account's saved inventory metadata is invalid, retained-session
restoration succeeds, but every inventory refresh fails before contacting the
inventory service. The menu and CLI cannot list or connect to existing clients
through normal inventory selection, despite a working network and valid account.
Repeated Refresh cannot repair the state.

When in-memory options are empty, refresh performs a throwing `cache.load`
before its fresh access check and inventory fetch. A decode or validation error
jumps directly to the failure handler, which leaves options empty, so every
retry repeats the same failure. Admin sign-out/sign-in and relaunch preserve the
bad file. An admin's
[role observation](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacAccountCache.swift:98)
does not clear the invalid file. In contrast,
[cache authorization](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacAccountCache.swift:116)
can rebuild an invalid payload once fresh inventory reaches it.

This is a recovery defect, not an authorization bypass. It requires damaged or
invalid local metadata, and atomic cache writes make that prerequisite uncommon.
Missing files and legacy payloads without a stored role do not trigger it.
Non-admin startup can clear invalid metadata through role observation, so the
persistent startup case is specifically confirmed for admin accounts. Existing
tunnels can still be stopped. Creating an unrelated client can also reach fresh
authorization and heal the cache, but normal refresh cannot.

Validation: the parent ran a temporary host-free reproduction with the real
cache and controller. A malformed inventory file allowed the initial admin
access check but prevented all inventory fetches. Two explicit refreshes returned
unavailable with zero fetches. Calling the real cache authorization method to
rebuild the payload immediately allowed the next refresh to fetch and publish
the client, isolating the failure to preload ordering. A fresh Secure reviewer
independently confirmed the trigger and recovery limits, and rated it P3 because
no ordinary application action was found that necessarily corrupts the file.

Suggested fix: treat an invalid optional cache preload as unavailable cached
data and continue with fresh authorization and inventory. Continue rejecting
invalid metadata for offline use and preserve explicit access-denial behavior.

### P3: Detect later PATH replacement before reporting CLI setup success

Location: [startup-file inspection](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacCLIInstaller.swift:79)
Introduced in the CLI layer, still present at the reviewed head.

Start with an empty login profile and an interactive startup file containing
`export PATH=/usr/bin:/bin`. The app environment does not include the user's
local bin directory. Choosing Add to Zsh PATH appends the local bin export to
the login profile and reports success, but a new interactive login shell then
replaces PATH while reading the later startup file. The installed `cloudgateway`
command remains unavailable by name.

For the default home directory, the two files are
`/Users/alexbrodsky/.zprofile` and `/Users/alexbrodsky/.zshrc`. The installer reads
both, but its inspection only returns whether each file already includes the
local bin directory. A detected PATH replacement in the later file is reduced
to false, so the installer proceeds to edit the earlier file. Its existing
manual-configuration guard checks only the file it edits. The
[success notice](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacAppController.swift:509)
then says to open a new login shell to use the command.

Validation: the Main CLI reviewer and parent independently traced the concrete
assignments through the installer. The parent checked the
[official Zsh startup order](https://zsh.sourceforge.io/Doc/Release/Files.html),
which places the interactive startup file after the login profile. No user
shell files were edited or executed. Existing installer tests check return
values and file preservation without evaluating the resulting shell PATH.

The explicit executable path remains usable, so this is a P3 setup defect.
The earlier custom-shell warning does not prevent this detectable configuration
from receiving an unconditional success result. Suggested fix: preserve enough
information from later startup-file inspection to reject a PATH replacement
that would erase the addition, and show the manual-configuration guidance.

## Review and validation record

- Main Codex, `gpt-6.1-sol`, high reasoning: controller architecture, ownership,
  XPC, session fencing, runtime adapters, and integration
- Main Codex, same model and reasoning: CLI parsing, login, installer, doctor,
  output redaction, command correlation, menu replacement/quit, and managed
  update confirmation, recovery, revocation, and reconnect fencing
- Secure Codex, same model and reasoning: removal authorization and transport,
  cache eviction, exact profile cleanup, both frontends, provider start grants,
  secret-service identity checks, and account transitions
- Secure Codex, same model and reasoning: fresh independent cache recovery
  validation and historical regression check
- Parent, Secure Codex, same model and reasoning: integration, inventory/cache
  recovery, production menu projection, release tooling, and finding validation

The original unsigned macOS validation entry point passed in full: packaging
and release workflow checks, WireGuard startup regressions, shared Kit/AppCore
tests, Firebase adapter tests, 781 macOS host-free tests, both strict Periphery
scans, unsigned arm64 app/extension build, and 88 packaged CLI smoke checks.
Two additional full unsigned runs passed while validating the findings: first
with the cache reproduction, then with both controller reproductions (783 macOS
host-free tests). The temporary test additions were restored afterward. Only
this report remains changed.

Signed tests and builds were not requested or run. Live Firebase requests,
Keychain authorization, signed XPC connections, NetworkExtension operations,
extension replacement, reboot, and SSH behavior were not exercised by this
review. Host-free tests use test adapters at those platform boundaries.
No severe security defect was confirmed in the reviewed paths. Unsigned checks
do not establish runtime enforcement of signed platform boundaries.

The earlier add denial/sign-out and creation/Disconnect findings are fixed in
`07825f1c` and are not open findings at this head. The proposed removal-menu
cleanup warning issue remains rejected: the injected active-profile fixture
does not establish a production start without the required one-use grant.

The original review changed documentation only. Later local review, plan, and
fix commits were explicitly authorized and are covered in the resolution update.
Nothing was pushed, and no external review comments were posted.
