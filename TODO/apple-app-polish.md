# Apple App UX Polish And VPN Profile Follow-Up

Status: Planning / partial implementation. This doc tracks the iOS app changes requested after the multi-profile VPN and required display-name work. Some foundation is already implemented; the remaining work is mostly SwiftUI behavior and polish.

Goal: make the iOS app behave like a per-client VPN manager. Each VPN client is named by the user, installs as a distinct Apple VPN profile, and is controlled from its own row without a separate global "Installed VPN" mental model.

## Already Implemented

* [x] Client display name is required when creating a VPN client across API, web, and iOS. Example placeholder/copy should use `ex: John's iPhone`.
* [x] Apple VPN installs use the required display name as the Apple-visible profile name.
* [x] Apple VPN profile identity uses stable `clientId`, not display name.
* [x] Multiple Apple VPN profiles can be installed for one app, one per Firebase client.
* [x] Installing/updating one client profile does not force-stop an already running VPN. If a user wants the new profile active, they can turn the current VPN off and then start the desired profile.

## Loading And Refresh

* [ ] On app load, do not show "none available" or equivalent empty/error messages while regions or clients are still loading.
  * Regions should show a loading state until the regions request resolves.
  * Clients should show a loading state until the selected region and client list resolve.
  * Only show "none available" after loading completes successfully with an empty result.
* [ ] Fix pull-to-refresh showing `cancelled` as an error and failing to refresh.
  * The toolbar refresh button works, so compare its task lifetime with `.refreshable`.
  * Cancellation during view/task replacement should not be surfaced as a user error.

## Layout And Copy

* [ ] Put the Regions card below the Create VPN Client card.
  * This makes it clearer that changing the selected region changes the client list below it.
* [ ] Rename Create Client copy:
  * Panel title: `Create VPN Client`
  * Subtitle: replace `WireGuard` with `VPN`
  * Field label: `Display name`
  * Remove any `optional` wording
  * Button: `Create VPN Client`
* [ ] Remove `Sync the selected region's live peers...` helper text. The button already says what it does.
* [ ] Remove `Showing clients visible...` from the VPN Clients header/subtitle.
* [ ] Remove region text from client rows because the selected Regions card already provides that context.
* [ ] Hide VPN/client id from the normal list row.

## VPN Client Row Behavior

* [ ] Remove the separate Selected/Installed VPN panel.
* [ ] Each client row should own its VPN controls.
  * Show a per-client on/off toggle for installed profiles.
  * Start/stop should target that row's `clientId`.
  * Disable or explain the toggle when the client has no installed local VPN profile yet.
* [ ] Replace `Install Update` text with a sync icon button that syncs only that client from the cloud.
  * The sync action should refresh/reinstall that specific VPN profile by `clientId`.
  * Use display name for Apple-visible profile naming, but never for lookup.
* [ ] Delete action should be an icon-only trash button.
  * Keep delete as the single destructive row action.
  * Do not keep a separate `Remove VPN` button; it is confusing next to delete.
* [ ] Add a three-dots details button to each row.
  * This shares space freed by icon-only delete.
* [ ] Long press/force hold on a row should also open details.

## Client Details Modal

* [ ] Details modal should show:
  * VPN/client id
  * Region id
  * Connection URL/endpoint
  * Owner email
* [ ] Details modal is available to all signed-in users for visible clients.
* [ ] Admin users should see owner email for every client they can view.

## Admin View

* [ ] Admin view should show every user's VPN clients, not only the signed-in admin's clients.
* [ ] Admin client rows should show user email in admin context.
* [ ] Sync and Grant Access buttons should use the blue primary style when enabled, matching Create VPN Client.
  * They should only be grey when disabled.

## Login And About

* [ ] Login layout:
  * Sign in button is a full-width row.
  * Request Access is a separate full-width row below it.
* [ ] About Email action should open an in-app popup/sheet showing the email address.
  * Inside that popup, include a mail icon button that uses `mailto:`.

## Notifications And Keyboard

* [ ] Notifications/banners should drop down from the top of the screen.
  * They must remain visible even when the user has scrolled far down the page.
* [ ] Scrolling up or down a meaningful amount while focused in a text input should dismiss the keyboard.

## Sync Result Modal

* [ ] Region sync should open a modal after completion.
  * Show sync results at the top.
  * Include a Download Logs button with a download icon.
  * The button should save/export the logs to the user's files.

## Acceptance

* Initial loading never flashes false empty/error states.
* Required display name is enforced and used for Apple-visible VPN profile names.
* Multiple installed VPN profiles coexist under the app, keyed by `clientId`.
* The client list is the primary control surface: per-row toggle, sync icon, trash icon, details menu, and long-press details.
* There is no separate Remove VPN action or global Installed VPN section.
* Admin users can see all visible clients with owner email.
* Pull-to-refresh works without showing cancellation as an error.
* Top notifications, keyboard dismissal, login/about layout, and sync-result export behave as described.

## Validation

Run normal Apple validation after implementation:

```sh
./scripts/test.sh apple
```

Signing-sensitive VPN/device behavior still needs manual review on a signed build/device. Local validation can cover package/unit tests and static wiring, but not full App Store-style signing or live Network Extension installation.
