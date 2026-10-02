# macOS fixes review 2: security and lifecycle

Date: 2026-10-02
Scope: final SEC1, SEC2, SEC3 changes and Apple dependency delivery
Status: final review complete, no new confirmed findings

## Confirmed new findings

None found. This closes the second and final review loop.

## Final checks

- Rechecked Go configuration/start failure cleanup and negative-handle propagation. Successful handles are registered only after both configuration and Up succeed
- Rechecked settings-operation locking, deadline rejection, duplicate/late callbacks, permanent timeout fencing, active backend cleanup, and the iOS fallback guard. A fenced adapter cannot submit another settings request or report a successful restart
- Rechecked macOS stop deadlines and repeated stops. Pending stop callbacks remain held until the actual adapter stop confirms shutdown. Session IDs still reject callbacks from earlier sessions
- Rechecked both Apple local package references and Go bridge working directories. Swift and Go compile from the same checked-in WireGuard fork
- Reviewed the corrected host-free harness: explicit macOS SDK, XCTest framework/overlay search paths, runtime paths, Darwin test discovery, and an enforced six-test execution count. The harness cannot silently pass after discovering zero tests

## Validation and runtime limits

Root reported successful Go startup and all six Swift settings regressions,
both unsigned Apple builds, and all five strict Apple scans. The full project
gate is still pending at this checkpoint. This reviewer only inspected source
and did not run tests or builds, edit production code, change the index, or
perform any live extension, Keychain, auth, or VPN action.

The callback fence does not cancel an OS settings request already submitted.
Actual delayed settings effects, signed provider replacement and teardown,
System Keychain ACL persistence, authenticated XPC rejection, and networking
remain signed runtime checks. The timeout intentionally fences the adapter for
the rest of its provider instance. Confirmed settings and backend startup do
not prove server reachability or a WireGuard handshake.
