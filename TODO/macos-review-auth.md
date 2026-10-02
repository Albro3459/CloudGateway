# macOS Auth Review Findings

Review date: 2026-10-02. Scope: browser device auth, shared device client,
macOS Firebase adapter/session cleanup, controller auth integration, and API
contract. Review only. Production files and git index remain unchanged.

## Confirmed Findings

### P2: A session that cannot restore has no sign-out or account-switch action

- Location: `Frontend/Apple/macOS/CloudGateway/CloudGatewayMacAppController.swift:343-357`, `:488-494`, `:181-206`
- Trigger: Firebase has a persisted user, but startup access verification fails because the API is unavailable, or the device is offline with no usable account cache
- Impact: `user` remains nil while `auth.currentUser` remains present. The menu offers Sign In and Refresh Session, but both retry restoration. Sign Out appears only in the authenticated presentation or the unsettled-exchange cleanup case. The user cannot discard this retained session or start browser sign-in for another account from the app
- Smallest fix: Offer Sign Out whenever a retained Firebase user exists, including the signed-out presentation with a failed restoration. Reuse the existing sign-out action to cancel restoration and clear the SDK session
- Evidence: Source-confirmed control flow. `restoreSession` keeps the Firebase user on offline/unavailable failures, the `user == nil` menu omits Sign Out, and `signIn` retries restoration whenever `auth.currentUser` exists. No runtime or live Firebase check performed

## Review Notes

- Browser links require the configured HTTPS origin, exact approval fragment, expected request ID/code, and no credentials/query. The device secret stays in POST bodies and process memory
- Polling uses a monotonic deadline and validates every late result before exchange. Cancellation fences old attempts
- The Firebase custom-token session hides an exchange while pending, blocks new exchanges until late callbacks settle, signs out stale callbacks, and retains a cleanup marker on failed sign-out for relaunch cleanup
- Existing host-free tests cover these intended guards using fakes. They do not establish Firebase SDK callback/persistence ordering or deployed endpoint behavior
- Existing API policy difference: `/auth/check-access` checks Firebase token validity and `UserRoles` but does not read `Users` existence/disabled (`Backend/API/src/auth.py:51-57`, `Backend/API/src/firebase.py:115-121`). Device authorization and Firestore rules require both. Normal online macOS inventory still fails closed when the Firestore rules deny access. No new macOS authorization bypass established by this review. This shared backend policy merits separate review if product denial through `Users.disabled` must govern every API

## Pending Suspicions

None. Source review complete. Native Firebase persistence, signed app behavior, and live device-auth flow remain untested in this review.

