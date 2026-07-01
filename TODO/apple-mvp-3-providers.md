# Apple MVP 3: Sign In With Apple And Google

Status: Planning. Part of the [Apple MVP 3 program](apple-mvp-3-implementation.md). Done **last**, after the [UI build](apple-mvp-3-ui.md) ships email/password with placeholder provider buttons.

Goal: replace the placeholder "Continue with Apple" / "Continue with Google" buttons with working Firebase-backed provider sign-in.

## Ordering And Rationale

* Deferred to the end so the UI and guest flow stabilize on the known-good email/password path first; the placeholders keep the login layout final in the meantime.
* Apple before Google. Guideline 4.8: if the app offers a third-party or social login (Google), it must also offer an equivalent privacy-focused option — Sign in with Apple. Shipping Google without Apple is a rejection. Implement Apple first, then Google, so the app is never in the non-compliant state.
* Both map onto the same Firebase Auth user model already used by email/password, so downstream (`check-access`, provisioning, region/config flows) is unchanged.

## Sign In With Apple

* Add the **Sign in with Apple** capability to the app target (entitlement `com.apple.developer.applesignin`).
* Use `AuthenticationServices` (`ASAuthorizationAppleIDProvider`) for the native flow, bridged to Firebase via `OAuthProvider(providerID: "apple.com")` with a nonce (SHA256-hashed nonce in the request, raw nonce to Firebase) — per Firebase's Apple auth guidance.
* On success, Firebase returns a `User`; feed it through the existing `CloudGatewayServicing.signIn`-equivalent path so the app runs the same post-sign-in load (`check-access`, regions, clients).
* Handle the first-login-only name/email quirk (Apple returns them once) — not required for CloudGateway since provisioning is by uid/email from Firebase, but note it.

## Sign In With Google

* Add the Google sign-in dependency (GoogleSignIn SDK, or Firebase's Google provider) and the reversed-client-ID URL scheme from `GoogleService-Info.plist`.
* Bridge to Firebase `GoogleAuthProvider.credential(...)` and sign in; same post-sign-in load path.
* Mirror the web app's Google error handling where relevant (popup-cancelled, account-exists-with-different-credential, unauthorized-domain) — adapted to native flows.

## Provisioning Interplay

* A brand-new provider user is authenticated but **not provisioned** until an admin grants access. The existing `check-access` flow already gates this: an unprovisioned user is signed out with the "request access" message. No change needed beyond routing provider sign-in through the same post-auth load.
* Guest → provider sign-in is a clean transition (guests are tokenless, so there's nothing to link).

## Seam / Testing

* Keep providers behind the `CloudGatewayServicing` seam (e.g. `signInWithApple()`, `signInWithGoogle()` returning the same `AuthenticatedUser`), so the view model and host-less tests stay Firebase-free.
* Add view-model tests for the post-provider-sign-in load and the unprovisioned → sign-out path (reusing the existing mock/branching coverage).
* The native provider UI (ASAuthorization / GoogleSignIn) is verified manually on device; the account-independent, device-independent sign-out behavior from the UI doc applies.

## Acceptance

* "Continue with Apple" and "Continue with Google" replace the placeholders and complete Firebase sign-in.
* Apple is shipped no later than Google (never Google-only).
* A new provider user who is unprovisioned is handled by the existing access-check → request-access path.
* `./scripts/test.sh apple` green, including provider post-sign-in view-model coverage.
