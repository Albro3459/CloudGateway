# Apple App UX Polish And VPN Profile Follow-Up

Status: Implemented pending signed-device/manual verification. The app polish work landed in `5cfe4f2` (`Polish Apple app VPN controls`) after the multi-profile VPN and required display-name work.

Goal: make the iOS app behave like a per-client VPN manager. Each VPN client is named by the user, installs as a distinct Apple VPN profile, and is controlled from its own row without a separate global "Installed VPN" mental model.

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
