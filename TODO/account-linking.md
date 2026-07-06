# Account Linking

## Goal

Let a signed-in user add another sign-in method to the same Firebase Auth account. Supported methods are:

- Email and password
- Google
- Apple

The linked provider must attach to the current Firebase user. A successful link keeps the same Firebase UID, so existing UID-keyed data in `Users/{uid}`, `UserRoles/{uid}`, and backend API flows continue to work without migration.

## Non-Goals

- Do not merge existing accounts in this feature.
- Do not auto-merge accounts based on matching email addresses.
- Do not change backend ownership or Firestore document IDs.
- Do not link a provider through a normal sign-in flow.

If the provider credential is already attached to another Firebase user, show a clear error and stop.

## Current Codebase Fit

- `Frontend/Web/src/firebase.ts` already exports Google and Apple providers/sign-in helpers.
- `Frontend/Web/src/pages/Home.tsx` already reads `auth.currentUser.providerData` through `currentProviderIds()`.
- `Frontend/Web/src/pages/Home.tsx` already has account deletion reauthentication patterns for password, Apple popup, and Google popup.
- Backend account data is keyed by the authenticated UID, so linking another provider to the current Auth user should not require backend changes.

## UX Placement

In the account profile dropdown, add a menu item after logout and before delete account:

`Link another sign-in method`

Only show it when the current account is missing at least one supported provider.

Supported provider IDs:

- `password`
- `google.com`
- `apple.com`

Compute missing methods from `auth.currentUser.providerData`. The linking view should only list methods that are not already linked.

Example:

```ts
const allProviderIds = ["password", "google.com", "apple.com"];
const linkedProviderIds = currentProviderIds();
const missingProviderIds = allProviderIds.filter(providerId => !linkedProviderIds.includes(providerId));
```

Show the dropdown item only when `missingProviderIds.length > 0`.

## User Warnings

Show warnings before the user starts linking:

- If this sign-in method is already used by another CloudGateway account, linking will not work. They should sign in with that account directly or contact support.
- Do not link an Apple private relay email address to an account with a real email address unless they are comfortable associating those identities.
- Emails do not need to match. Linking is based on explicit proof of control while signed in, not email equality.

For Apple, include the private relay warning next to the Apple option or inside the confirmation step before starting the Apple popup.

## Link Flows

### Google

Use the Firebase provider-linking API with the current user:

- Ensure `auth.currentUser` exists.
- Call `linkWithPopup(auth.currentUser, googleProvider)`.
- On success, refresh local user/provider state and close the modal/menu.

### Apple

Use the Firebase provider-linking API with the current user:

- Ensure `auth.currentUser` exists.
- Show the Apple private relay warning before starting.
- Call `linkWithPopup(auth.currentUser, appleProvider)`.
- On success, refresh local user/provider state and close the modal/menu.

### Email and Password

This is not a popup flow:

- Collect email and new password.
- Create a credential with `EmailAuthProvider.credential(email, password)`.
- Call `linkWithCredential(auth.currentUser, credential)`.
- Consider sending an email verification after the link succeeds.

The email does not need to match the existing Google or Apple account email.

## Recent Sign-In Handling

Firebase can require recent authentication before linking. If linking fails with `auth/requires-recent-login`:

- Ask the user to sign in again with one of their already linked providers.
- Reuse the same reauth pattern used by account deletion:
  - Password account: ask for current password and call `reauthenticateWithCredential`.
  - Apple account: call `reauthenticateWithPopup(user, appleProvider)`.
  - Google account: call `reauthenticateWithPopup(user, googleProvider)`.
- After reauth succeeds, retry the linking operation.

For accounts with multiple existing providers, prefer reauth with the provider the user chooses or the first linked provider that can be reauthenticated cleanly.

## Error Handling

Handle these Firebase errors explicitly:

- `auth/credential-already-in-use`: The selected provider is already linked to another CloudGateway account. Do not merge. Tell the user to sign in with that account directly or contact support.
- `auth/email-already-in-use`: The email/password credential is already attached to another Firebase account. Do not merge.
- `auth/provider-already-linked`: The provider is already linked. Refresh provider state and hide the option.
- `auth/requires-recent-login`: Prompt for reauthentication, then retry the link.
- `auth/popup-closed-by-user`: Treat as a cancellation and do not show a scary error.
- `auth/cancelled-popup-request`: Treat as a cancellation.
- `auth/popup-blocked`: Tell the user to allow popups and try again.
- `auth/invalid-email`: Ask for a valid email address.
- `auth/weak-password`: Ask for a stronger password.
- `auth/wrong-password`: Show that the reauth password is incorrect.

Unknown errors should show a generic message such as:

`Unable to link that sign-in method. Try again or contact support.`

## State Updates

After a successful link:

- Refresh the Firebase user if needed.
- Recompute `currentProviderIds()`.
- Hide any newly linked option.
- Show a success banner.
- Keep the user on the same page.
- Do not call normal sign-in navigation.

## Backend Impact

No backend change is expected for the basic linking flow because the Firebase UID remains unchanged.

Do not add account merge endpoints as part of this feature. A future merge project would need a trusted backend flow that proves control of both accounts, chooses one UID to keep, moves Firestore data, updates ownership references, and retires the duplicate account.

## Test/Validation Notes

Manual validation is enough for the planning doc. When implementing, validate:

- Google account can link email/password.
- Google account can link Apple.
- Apple account can link Google.
- Email/password account can link Google.
- Email/password account can link Apple.
- Already-linked providers do not appear as options.
- Accounts with all three providers do not show the dropdown item.
- `credential-already-in-use` shows the no-merge message.
- Apple private relay warning appears before Apple linking.
- Stale sessions trigger reauth and then allow retry.
- Popup cancellation does not show an error banner.
