# macOS menu and config review

Baseline: `8cc964a`, 2026-10-02
Status: M1, M2, and M3 implemented, implemented and validated, two review loops complete

## Implementation follow-up

* M1 drains cancelled VPN commands and mandatory profile/secret recovery before
  dropping the cancellation busy state. Read-only remote tasks remain fenced
  without blocking the new account until an SDK callback arrives
* M2 separates inventory refresh from command/cancellation activity. Refresh
  disables new connections but leaves local Turn Off available
* M3 retains last observed profiles/status and an independent preferences error.
  Only successful preference reads clear that error. No visible state was added
* Host-free regressions cover stop/connect gating, retained observation/error,
  and cancellation drain through both commit/cache recovery and rollback


## Confirmed findings

### M1 · P2 · Wait for cancelled commands before enabling new commands

- Trigger: Sign out while an install, profile save, or XPC request is pending. Sign back in before the old command finishes, then select a client or Turn Off
- Source: `Frontend/Apple/macOS/CloudGateway/CloudGatewayMacAppController.swift:328` clears the app command task immediately. Lines 336–338 clear the cancellation task after requesting cancellation. `Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacConfigCoordinator.swift:87` only cancels the running command. Its busy flag clears when `runCommand` exits at line 241
- Impact: The menu enables commands while the coordinator still rejects them with `busy`, and reports a generic VPN command failure. This can last through the ten-second XPC deadline, preferences callbacks, or required installation recovery. Cancellation prevents a new start, so this is a transient command availability/error issue, not a confirmed unsafe connection or permanent deadlock
- Fix: Keep cancellation presentation active until the coordinator command and required recovery finish. Drain the retained command before enabling another operation, while keeping account presentation fenced
- Evidence: Static call-order trace. XPC waits for reply or ten-second timeout in `CloudGatewayMacXPC.swift:194–218`. Saved-profile commit/cache work intentionally runs in an uncancelled task at `CloudGatewayMacConfigCoordinator.swift:159–172`. Existing cancellation tests wait for old commands explicitly and do not cover the app enabling a new command before that wait completes

### M2 · P2 · Keep Turn Off available during inventory refresh

- Trigger: Open the menu while signed in with a running VPN. Opening automatically starts access/inventory requests, even when the user only wants to stop the local VPN
- Source: `Frontend/Apple/macOS/CloudGateway/CloudGatewayMacAppController.swift:97–101` refreshes inventory before rendering. Line 353 counts `inventoryTask` as a VPN command in flight. `Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacMenuState.swift:51–52` blocks Turn Off for that combined flag. The app removes the Turn Off item entirely at `CloudGatewayMacAppController.swift:403`
- Impact: Turn Off disappears on every menu opening until remote access/inventory work finishes. During an API outage it can stay absent for the ten-second access request deadline. Firestore server reads use callbacks with no app-level timeout or cancellation completion, so the local stop control also waits for those reads. Closing and reopening the menu starts another refresh after the last one ends
- Fix: Track inventory refresh separately from VPN command/cancellation state. Keep local Turn Off available during a read-only inventory refresh, or cancel the refresh before issuing the stop. Preserve command serialization and account fences
- Evidence: Static call-order trace. The access check uses `CloudGatewayAPISession.requestTimeout` (10 seconds) in `CloudGatewayMacInventoryService.swift:34–60`. Inventory requests use server-only `getDocuments` continuation at lines 106–119. No live network/VPN reproduction was performed

### M3 · P2 · Represent failed VPN status reads as unknown

- Trigger: A CloudGateway VPN is active, and the next preferences/status refresh fails. A malformed owned profile also makes the adapter's whole snapshot read throw
- Source: `Frontend/Apple/macOS/CloudGateway/CloudGatewayMacAppController.swift:301–304` replaces the snapshot with an empty list on error. Line 360 maps that list to an inactive icon. `Frontend/Apple/macOS/CloudGateway/CloudGatewayStatusGlyph.swift:58` labels that icon “VPN off”. `CloudGatewayMacVPNProfileAdapter.swift:47–49` maps every owned manager through the throwing metadata parser
- Impact: The app presents the off icon even though it has not observed a stopped tunnel. Signed-out users receive no preferences error. Signed-in users also lose Turn Off because the snapshot is empty. A concurrent successful inventory refresh clears the shared error message at `CloudGatewayMacAppController.swift:243`, after which the menu can say “VPN off” too
- Fix: Keep VPN read failure separate from inventory/command errors and retain an explicitly stale or unknown status. Only show off after a successful read establishes it. Preserve a recovery path for stopping a previously observed active profile
- Evidence: Static error-path and presentation trace. No actual preferences failure or live VPN was induced. The normal disconnected read still correctly produces the off icon

## Coverage

Reviewed these production components from source, without relying on earlier findings:

- App controller: startup, session restoration, account switching, epoch fences, menu opening/rendering, selection, cancellation, local stop, sign-out, quit, refresh, launch at login
- Menu state and glyph: online/offline grouping, disabled rows, hidden active profiles, signed-out inventory privacy, setup gating, connection status, last selection
- Inventory service: access checks, token/account guards, server-only Firestore reads, role/owner filters, redirects, transport fallback, invalid response handling
- Account cache: account namespaces, role downgrade, authorization hashes, pruning rotated/revoked configs, metadata refresh, validation, persistence failure, permissions, selection
- Config coordinator: parser boundary, install/save/commit/cache ordering, rollback, conservative retention when preferences cannot be read, parent cancellation, single-command serialization, switching, stop-before-start
- Native profile adapter and replacement helper: ownership, duplicate profiles, save/reload, enabled state, start grants, status observation, stop confirmation/timeout/cancellation
- Corresponding host-free menu, cache, config coordinator, and replacement tests were read for coverage and assumptions

## Evidence and limits

Findings are static source/control-flow traces. Root owns build/test validation. This
review performed no builds, tests, live VPN commands, profile changes, or production
code changes.

Signed runtime checks still need to exercise Apple preference read/save errors,
status notifications, cancellation while callbacks are pending, and the menu while
network access fails. No permanent callback hang was established.

Offline repair after a failed metadata save still requires an online retry. The
app reports that failure explicitly and retains referenced secrets conservatively.
This is a documented failure state, not an additional finding. Signed-out VPN
controls are intentionally hidden by the product's storage/lifecycle contract.

Malformed or duplicate owned profiles fail the whole adapter read. M3 covers the
resulting false status presentation. Whether old releases or macOS itself can
produce such a profile needs a runtime or migration example before treating profile
repair as a separate finding.

Final no-target `./scripts/test.sh` passed all suites. Log:
`/tmp/cloudgateway-macos-eight-fixes-full.log`. Signed runtime checks remain pending.
