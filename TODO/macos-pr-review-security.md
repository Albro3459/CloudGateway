# macOS PR 15: security and tunnel review

Baseline: `origin/main...cdb817d`, 2026-10-02
WireGuard range: `d03db4a...e18cca2`
Status: fresh source review complete

## Confirmed actionable findings

None found in this review. Earlier resolved findings were not reused.

## Coverage

- Read all macOS IPC contracts, XPC listener/client, secret service, System Keychain store, extension entry point/provider, lifecycle helper, profile adapter, related validation, and authorization/lifecycle regression sources
- Read the entire WireGuard submodule change, including settings operation, adapter start/stop/update/restart paths, Go startup cleanup, package exclusions, Go archive dependencies, and test harness. Both Apple platforms consume the changed fork
- Verified exact signed target/team requirements before activating either peer. Foundation's local SDK header documents rejection before the listener delegate and checks on incoming connection messages. OS connection UID is captured synchronously and rechecked before dispatching actor work. Manual PID or audit-token signature lookup is unnecessary for this API's code checks
- Verified bounded messages, config IDs, canonical opaque references, stored UID/config ownership, committed-state checks, random single-use monotonic start grants, and suppressed macOS WireGuard logs. No XPC response returns private configuration material
- Verified fixed System Keychain location/service, extension trusted-application ACL construction, encoded-record bounds on writes and reads, and provisional rollback versus intentional committed-secret retention
- Verified late start fencing, repeated stop joining, retained stop completions after an unconfirmed deadline, and stale callback rejection. Settings deadlines fail startup, retain an adapter fence, close an active backend, and prevent the iOS fallback path from restarting a fenced adapter

## Mach service and entitlement check

`NEMachServiceName` and the listener/client all use
`group.com.gocloudlaunch.gateway.macos.tunnel`. Both targets claim
`group.com.gocloudlaunch.gateway.macos`, which prefixes that service name.
The app connects with `.privileged`. The listener is process-wide and shares
its actor service with provider instances.

This matches [Apple's system-extension packaging guidance](https://developer.apple.com/forums/thread/800887): publish the named endpoint through `NEMachServiceName`, connect in the global namespace with `.privileged`, use an app-group-prefixed endpoint for sandbox access, and keep System Keychain operations in the root extension. The app is currently unsandboxed. The extension enables App Sandbox and network client/server access. Development and Developer ID entitlement values match their respective channels.

## Evidence and limits

This was source and existing-test review. No production edits, index changes,
commits, pushes, tests, builds, live Keychain, extension activation, auth session,
or VPN actions were performed. Root owns validation and integration checks.

Signed runtime must still verify provisioning/App Group access, Mach bootstrap
lookup, incorrect-signature and cross-user rejection, System Keychain sandbox
access, trusted-application ACL persistence after replacement, provider
deallocation, and actual delayed network-settings and stop callbacks.

The settings fence prevents new submissions through the same adapter, but
cannot cancel a settings operation already sent to macOS. Source confirms
backend startup and settings completion handling, not server reachability or
a successful WireGuard handshake. These runtime limits are not presented as
confirmed security defects.
