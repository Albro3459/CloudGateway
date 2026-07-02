# Apple App UX Polish And VPN Profile Follow-Up

Status: Round 1 implemented pending signed-device/manual verification (landed in `5cfe4f2`, `Polish Apple app VPN controls`). Round 2 (below) is open — a second batch of UX fixes found in manual use.

Goal: make the iOS app behave like a per-client VPN manager. Each VPN client is named by the user, installs as a distinct Apple VPN profile, and is controlled from its own row without a separate global "Installed VPN" mental model.

## Round 2 — UX Fixes

Implemented pending signed-device verification; `./scripts/test.sh apple` green. Each item notes the root cause and the file changed.

Still needs on-device verification (Network Extension behavior is not unit-testable): the toggle-on-without-sync fix, the switch-VPN confirm/stop-then-start flow, the toggle reverting when the switch is cancelled, and Install → toggle appearing after a fresh pull.

* [x] **Sort clients by owner email, then display name.** Matters for admins (groups each user's clients); a no-op for normal users, who own one email. Client list currently sorts by `displayName` then `regionId` in `CloudGatewayConfigSelection` (`Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayKit/CloudGatewayConfigModels.swift:~189`), with no owner grouping. `ownerEmail` is already on `CloudGatewayClient`; sort by it first, then `displayName`.
* [x] **Show an Install button when a client isn't installed; hide the disabled toggle + sync.** `ClientRow` always renders the toggle and sync icon and just disables them pre-install (`ContentView.swift:1070–1088`). When `installStateLabel(for:) == nil` (not installed), show a single "Install" button instead, and reveal the toggle + sync only once installed. The install action should re-pull from Firebase first (like `sync(_:)` does: `loadRemoteState` → install the fresh option, `CloudGatewayViewModel.swift:416`), not install the stale cached option.
* [x] **Confirm before switching the active VPN.** `startTunnel` starts the selected client with no check for an already-connected tunnel (`CloudGatewayViewModel.swift:435`). Toggling a client on while another is connected should prompt first — e.g. "Turn off `<name>` (`<region>`) and start `<this>`?" — naming the currently-connected client (found via `configState.tunnelStatus(for:)`), then stop it and start the requested one.
* [x] **Bug: toggle-on fails until Sync is tapped.** After all clients are off, toggling one on fails; tapping that row's Sync (which re-installs via `configManager.install`) then makes it work. The stray selected profile in iOS Settings is *not* the cause. Hypothesis: the `NETunnelProviderManager` for that `clientId` needs a fresh `loadFromPreferences`/`saveToPreferences` before `startVPNTunnel`, which the sync/re-install path performs. Investigate the start path in `GatewayVPNManager` (CloudGatewayKit) — likely reload-then-start before `startVPNTunnel`.
* [x] **Every banner needs a dismiss X.** `MessageBanner` only renders the close button when `onDismiss` is set (`ContentView.swift:1268`); the stale-state warning passes `onDismiss: nil` (`ContentView.swift:360–366`), e.g. "Unable to refresh remote state. The last installed config remains available offline." Give the stale banner a dismiss (add a `dismissStale()` that clears `staleText`).
* [x] **Make detail values copyable.** `DetailLine`'s value text isn't selectable (`ContentView.swift:1220`), so `ClientDetailsView` (VPN id, region id, connection URL, owner email) can't be copied on long-press. `EmailContactView` already uses `.textSelection(.enabled)`; add the same to `DetailLine`'s value (or a long-press Copy menu).
* [x] **Guest "Create VPN Client" CTAs should be stacked full-width rows.** `guestCreatePanel` lays Sign in + Request Access side by side in an `HStack` (`ContentView.swift:500`). Make them full-width vertical rows, matching the already-fixed login layout.
* [x] **About link colors are inconsistent.** GitHub and LinkedIn are `Link`s with no explicit color, so they render white (inheriting the view's `foregroundStyle(theme.content)`), while Email is a `Button` with `.foregroundStyle(theme.accent)` (blue) (`ContentView.swift:746–757`). Give all three the same color — accent/blue.
* [x] **Sync result should show the backend's full audit log, named like the web.** The `admin/sync` endpoint already returns the complete audit text in `AdminSyncResponse.log` (`Backend/API/src/models.py:118`, built by `build_sync_audit_log`) — title "CloudGateway peer sync audit log", region, syncedAt, summary, and each removed peer's `publicKey`/`clientId`/`status`/`email`/`clientName`. The web renders/downloads that `log`. iOS drops it: `CloudGatewayRegionSyncResponse` (`Frontend/Apple/iOS/CloudGateway/CloudGatewayServicing.swift:51`) doesn't decode `log`, and `CloudGatewaySyncResult.logText` (`CloudGatewayViewModel.swift:29`) is a synthesized counts-only summary. Decode `log`, surface it in `SyncResultView` and the ShareLink, and format the header like the web's audit log.

## Already Implemented

* [x] Client display name is required when creating a VPN client across API, web, and iOS. Example placeholder/copy should use `ex: John's iPhone`.
* [x] Apple VPN installs use the required display name as the Apple-visible profile name.
* [x] Apple VPN profile identity uses stable `clientId`, not display name.
* [x] Multiple Apple VPN profiles can be installed for one app, one per Firebase client.
* [x] Installing/updating one client profile does not force-stop an already running VPN. If a user wants the new profile active, they can turn the current VPN off and then start the desired profile.

## Loading And Refresh

* [x] On app load, do not show "none available" or equivalent empty/error messages while regions or clients are still loading.
  * Regions should show a loading state until the regions request resolves.
  * Clients should show a loading state until the selected region and client list resolve.
  * Only show "none available" after loading completes successfully with an empty result.
* [x] Fix pull-to-refresh showing `cancelled` as an error and failing to refresh.
  * Pull-to-refresh now uses the same reload logic without presenting the blocking working overlay that likely interrupted SwiftUI's native refresh gesture.
  * Cancellation during view/task replacement is not surfaced as an error or stale warning.

## Layout And Copy

* [x] Put the Regions card below the Create VPN Client card.
  * This makes it clearer that changing the selected region changes the client list below it.
* [x] Rename Create Client copy:
  * Panel title: `Create VPN Client`
  * Subtitle: replace `WireGuard` with `VPN`
  * Field label: `Display name`
  * Remove any `optional` wording
  * Button: `Create VPN Client`
* [x] Remove `Sync the selected region's live peers...` helper text. The button already says what it does.
* [x] Remove `Showing clients visible...` from the VPN Clients header/subtitle.
* [x] Remove region text from client rows because the selected Regions card already provides that context.
* [x] Hide VPN/client id from the normal list row.

## VPN Client Row Behavior

* [x] Remove the separate Selected/Installed VPN panel.
* [x] Each client row should own its VPN controls.
  * Show a per-client on/off toggle for installed profiles.
  * Start/stop should target that row's `clientId`.
  * Disable or explain the toggle when the client has no installed local VPN profile yet.
* [x] Replace `Install Update` text with a sync icon button that syncs only that client from the cloud.
  * The sync action should refresh/reinstall that specific VPN profile by `clientId`.
  * Use display name for Apple-visible profile naming, but never for lookup.
* [x] Delete action should be an icon-only trash button.
  * Keep delete as the single destructive row action.
  * Do not keep a separate `Remove VPN` button; it is confusing next to delete.
* [x] Add a three-dots details button to each row.
  * This shares space freed by icon-only delete.
* [x] Long press/force hold on a row should also open details.

## Client Details Modal

* [x] Details modal should show:
  * VPN/client id
  * Region id
  * Connection URL/endpoint
  * Owner email
* [x] Details modal is available to all signed-in users for visible clients.
* [x] Admin users should see owner email for every client they can view.

## Admin View

* [x] Admin view should show every user's VPN clients, not only the signed-in admin's clients.
* [x] Admin client rows should show user email in admin context.
* [x] Admin delete targets the selected client's owner uid, so admins can delete another user's client safely.
* [x] Sync and Grant Access buttons should use the blue primary style when enabled, matching Create VPN Client.
  * They should only be grey when disabled.

## Login And About

* [x] Login layout:
  * Sign in button is a full-width row.
  * Request Access is a separate full-width row below it.
* [x] About Email action should open an in-app popup/sheet showing the email address.
  * Inside that popup, include a mail icon button that uses `mailto:`.

## Notifications And Keyboard

* [x] Notifications/banners should drop down from the top of the screen.
  * They must remain visible even when the user has scrolled far down the page.
* [x] Scrolling up or down a meaningful amount while focused in a text input should dismiss the keyboard.

## Sync Result Modal

* [x] Region sync should open a modal after completion.
  * Show sync results at the top.
  * Include a Download Logs button with a download icon.
  * The button should save/export the logs to the user's files.

## Remaining

* [ ] Manually verify pull-to-refresh in a signed app/device build. The root-cause fix avoids presenting the blocking overlay during `.refreshable`, but the actual iOS gesture still needs device confirmation.
* [ ] Manually verify live Network Extension start/stop behavior in a signed app/device build.
* [ ] Manually verify the share/save flow for downloaded sync logs on device.

## Acceptance

* [x] Initial loading never flashes false empty/error states.
* [x] Required display name is enforced and used for Apple-visible VPN profile names.
* [x] Multiple installed VPN profiles coexist under the app, keyed by `clientId`.
* [x] The client list is the primary control surface: per-row toggle, sync icon, trash icon, details menu, and long-press details.
* [x] There is no separate Remove VPN action or global Installed VPN section.
* [x] Admin users can see all visible clients with owner email.
* [x] Pull-to-refresh no longer uses the blocking overlay path and does not show cancellation as an error.
* [x] Top notifications, keyboard dismissal, login/about layout, and sync-result export behave as described in code and tests.

## Validation

Normal Apple validation passed for `5cfe4f2`:

```sh
./scripts/test.sh apple
```

Signing-sensitive VPN/device behavior still needs manual review on a signed build/device. Local validation can cover package/unit tests and static wiring, but not full App Store-style signing or live Network Extension installation.
