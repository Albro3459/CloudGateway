# macOS PR 15 menu and coordination review

Range: `origin/main...cdb817d`, 2026-10-02
Status: fresh full-PR review complete, no confirmed actionable findings

## Findings

None in this scope.

## Coverage

Reviewed the complete current implementation introduced by the PR, rather than
only the latest fixes:

- `CloudGatewayMacAppController.swift`: composition, Firebase configuration, initial status, restored/browser sessions, account fences, inventory presentation, online/offline selection, retry, cancellation, local stop, refresh, sign-out, shutdown, and launch at login
- `CloudGatewayMacMenuState.swift` and `CloudGatewayStatusGlyph.swift`: grouping/sorting, account isolation, online/offline action gating, hidden active profiles, status/error priority, template drawing, and accessibility text
- `CloudGatewayMacVPNProfileAdapter.swift`: owned manager filtering, metadata/duplicate validation, save/reload, disabled profiles, grants, preference/status observation, and confirmed stop/cancellation/deadline handling
- `CloudGatewayMacConfigCoordinator.swift` and `CloudGatewayMacProfileReplacement.swift`: validation before secret transfer, install/save/commit/cache order, recovery, safe rollback, single-command serialization, draining, stop-before-start, and no-op selection of an already active profile
- `CloudGatewayExtensionActivationCoordinator.swift` and `CloudGatewayMacSetupState.swift`: embedded bundle lookup, version comparison, activation request/delegate retention, approval, explicit replacement, failure/retry, reboot, and connection readiness gates
- `CloudGatewayAppDelegate.swift`, `main.swift`, and app `Info.plist`: lifecycle ownership, menu-agent startup, shutdown, and bundle composition
- Inventory/error/cache integration: server-only reads, owner/admin filters, account checks, transport versus denial, metadata authorization hashes, removed history, role changes, persistence, and offline selection
- Corresponding setup/menu/cache/coordinator/replacement/error tests, plus README and implementation-plan contracts, were read to challenge behavior and coverage assumptions

## Candidates checked

- Cancelled command cleanup remains part of the app barrier. Cancelled read-only inventory/restoration tasks are not awaited by that barrier. Replacement tasks capture the preceding barrier, so no self-await cycle was found
- Inventory reads do not hide local Turn Off. Connections still wait for inventory authorization and command/recovery completion
- Preference read failures preserve the prior observation and an independent error. Inventory/command success cannot silently clear that error
- Missing metadata after an installation failure does not prove the profile or secret can be deleted. Conservative retention and an online retry are explicit failure behavior, rather than a new finding
- Signed-out VPN controls are intentionally hidden. The retained tunnel can affect the glyph without exposing another account's client details
- Malformed or duplicate owned preferences fail the adapter read. No supported PR migration or normal write path was found that creates them, so a separate recovery finding would need a concrete runtime or migration example
- Extension readiness compares both build and marketing versions. Binary changes must advance the build number, as documented. No supported single-app setup transition was found that skips this comparison

## Evidence and limits

This is static source/control-flow review. No production edits, tests, builds,
index changes, commits, live sign-ins, activation, profile changes, or VPN actions
were performed by this reviewer. Root owns validation results.

Signed runtime checks remain necessary for actual System Extension approval and
replacement, listener startup after activation, preferences save/read failures,
status notifications, Firebase persistence/callback latency, System Keychain/XPC,
retained VPN after quit/sign-out, sleep/wake, and launch at login.

The retained status can be stale, and a failed first read has no previous snapshot
to retain. That follows the approved existing-state presentation. Multiple running
app copies or replacement of the extension outside this app's setup flow require a
runtime example before treating stale readiness as a confirmed finding.
