# Google Sign-In Firebase Setup

Use these Firebase console settings when deploying the Google sign-in UI from the static GitHub Pages app.

## Auth Provider

1. Open Firebase Console > Authentication > Sign-in method.
2. Enable Google as a provider.
3. Keep "one account per email address" enabled so Google sign-in uses/link-checks the existing email account behavior.
4. Keep Email/Password enabled. Existing admin-created users still use this path and password reset still works.

## Authorized Domains

Add every static frontend hostname that will load the React app:

* `gocloudlaunch.com`
* Any Firebase-provided hosting domain used for testing.
* Localhost is normally present by default; keep it for local verification.

GitHub Pages does not need a server callback route. The app uses `HashRouter`, and Google sign-in runs through Firebase Auth's popup flow in the browser.

## Provisioning Rule

Google sign-in is for existing CloudGateway users only.

* Users must already have `Users/{uid}` and `Roles/{uid}` documents.
* Admin-created password users get those documents from the existing `/users` API.
* An account with no `Users/{uid}` document is signed out by the UI.
* An account with no `Roles/{uid}` document is rejected by the API with `USER_NOT_PROVISIONED`.

## Manual Checks

1. Sign in with an existing provisioned user using Google.
2. Sign in with an existing provisioned admin using Google and confirm admin controls still appear.
3. Try an unprovisioned Google account and confirm the app shows an access message and signs out.
4. Confirm email/password login and password reset still work.
