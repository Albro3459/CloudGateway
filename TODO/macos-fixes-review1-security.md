# macOS fixes review 1: security and lifecycle

Date: 2026-10-02
Scope: working changes for SEC1, SEC2, SEC3 and shared dependency delivery
Status: first review complete

## Confirmed new findings

None found in this review.

## Checked fixes

- SEC1: `startConfiguredDevice` returns configuration/start failures and closes the created device on either failure. `wgTurnOn` returns a negative handle, so the macOS provider reports its existing sanitized backend failure. Handle exhaustion also closes the device. The helper tests cover failed configuration, failed Up, and successful startup
- SEC2: Unconfirmed deadlines retain the session and every pending stop callback. Repeated stops join the existing operation after a deadline. Only an actual backend callback clears the session and completes stops. Existing session IDs still reject stale callbacks. Updated tests cover deadline fencing and repeated stops after a deadline
- SEC3: The settings gate accepts the first timely completion, propagates its error, and permanently fences the adapter after an unconfirmed deadline. Late callbacks cannot revive success or submit another settings request through that adapter. Timeout cleanup closes an active backend and cancels its monitor. The iOS restart path rejects fallback when fenced. Helper tests cover timely success, system failure, missing/late callbacks, duplicate replies, and pending overlap
- Dependency delivery: Both Apple projects select the local `../wireguard-apple` package. Both Go bridge targets build its matching `Sources/WireGuardKitGo` directory. Package exclusions include the new Go helper/test files. Go archive prerequisites include source files and `go.sum`, so changing startup code invalidates an existing archive. The project Apple test entry point includes fork regressions once per shared-package invocation

## Evidence and limits

Reviewed full production changes, helpers, regression sources, package metadata,
legacy build targets, and test-entry integration. No production code changed.
Read-only whitespace checks passed for the project and fork. Root owns builds
and test execution, so this reviewer did not run them.

An adapter fence controls application submission and completion handling. It
cannot cancel a settings operation already submitted to macOS. Actual late OS
settings effects, provider replacement, System Keychain ACL persistence, XPC
rejection, and VPN teardown still need signed runtime checks. No live extension,
Keychain, session, or VPN actions were performed.

The settings timeout intentionally leaves the adapter fenced until its provider
instance ends. The shared iOS dependency uses the same behavior. Confirming
network settings and backend startup does not prove server reachability or a
WireGuard handshake, and these fixes do not add such a health check to macOS.

This is review loop 1. Only one final review remains after any corrections.
