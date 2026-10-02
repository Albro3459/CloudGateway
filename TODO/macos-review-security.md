# macOS security and tunnel review

Baseline: `8cc964a`, 2026-10-02
Status: SEC1, SEC2, and SEC3 implemented, signed runtime checks remain pending

## Implementation follow-up

* SEC1 closes failed Go devices and returns a failed handle before registration
* SEC2 retains provider stop callbacks across deadlines and repeated stops until
  the adapter confirms shutdown. New starts remain fenced while stop is unconfirmed
* SEC3 fails network-settings timeout, closes any active backend/monitor, and
  permanently fences that adapter. Late callbacks cannot restore success or allow
  another settings operation. iOS restart fallback respects the fence
* Both Apple projects and Go bridge builds use the existing WireGuard submodule.
  Host-free Go startup and six Swift settings tests run once per Apple invocation
* A callback fence cannot cancel an already submitted OS settings request.
  Delayed OS callbacks across provider replacement remain a signed runtime gate


## Confirmed findings

- [x] **SEC1 · P2: Propagate WireGuard backend startup failures before reporting a connected VPN**
  - Trigger: Start a valid config whose explicit `ListenPort` is already occupied, or encounter another UDP bind/open failure
  - Source: `Frontend/Apple/wireguard-apple/Sources/WireGuardKitGo/api-apple.go:119` ignores `dev.Up()`'s error, then registers and returns a successful handle at lines 132–133. The macOS project pins this same `d03db4a` dependency. `Frontend/Apple/macOS/CloudGatewayTunnel/PacketTunnelProvider.swift:106` trusts the resulting adapter success
  - Evidence: `/Users/alexbrodsky/go/pkg/mod/golang.zx2c4.com/wireguard@v0.0.0-20230209153558-1e2c3e5a3c14/device/device.go:150` falls back to the Down state when `upLocked` fails. `upLocked` returns `BindUpdate` errors at line 170, and `BindUpdate` returns socket-open errors at line 480. `Up()` returns that error at line 207. This module matches the fork's `go.mod` pin. The shared parser accepts an explicit `ListenPort`, although the current backend-generated client config omits it
  - Impact: NetworkExtension receives a successful tunnel start while WireGuard stays down. The menu can show connected while routed traffic cannot reach the server, and the app has no macOS health monitor to correct that status
  - Fix: Handle `dev.Up()` errors in the WireGuard fork, close the created device on failure, return a failed handle, and pin the corrected revision. Keep logs suppressed and surface a sanitized backend-start failure
  - Validation: Confirmed by tracing pinned source. No live VPN or port-conflict reproduction performed
  - Scope: The same dependency serves iOS, so its remediation needs both platform gates

- [x] **SEC2 · P2: Keep the system stop completion pending until the backend actually stops**
  - Trigger: Stop a tunnel while the adapter's serial work queue remains busy for more than five seconds, or while backend shutdown is delayed
  - Source: `Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacIPC/CloudGatewayMacTunnelLifecycle.swift:105` schedules an unconfirmed stop deadline. `finishStop` at line 144 invokes all stop completions for both confirmed and unconfirmed results. `Frontend/Apple/macOS/CloudGatewayTunnel/PacketTunnelProvider.swift:63` forwards that completion to NetworkExtension
  - Evidence: [Apple's stop callback contract](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider/stoptunnel%28with%3Acompletionhandler%3A%29) requires completion after the tunnel fully stops. The current host-free `macTunnelStopDeadlineCompletesOnceAndBlocksStartUntilConfirmedStop` test explicitly expects completion at the unconfirmed deadline
  - Impact: The provider signals that stop finished while its backend is still unconfirmed. The app's `MacVPNStopWaiter` accepts `.disconnected` as confirmation and can proceed with a profile replacement or switch. The instance-local lifecycle fence cannot communicate its uncertainty to that app workflow
  - Fix: Retain the NetworkExtension stop completion until the adapter reports a real stop, or prove the backend has been forcibly torn down before completion. Keep timeout diagnostics separate from stop confirmation
  - Validation: Confirmed callback-contract violation by source and existing test review. Actual OS cleanup, replacement-provider behavior, and overlapping backends remain unverified, so this finding does not claim that overlap has been reproduced

- [x] **SEC3 · P2: Fail tunnel startup when network settings remain unconfirmed**
  - Trigger: macOS delays the `setTunnelNetworkSettings` callback beyond five seconds or never calls it. A late callback can also report a settings error after the start already succeeded
  - Source: `Frontend/Apple/wireguard-apple/Sources/WireGuardKit/WireGuardAdapter.swift:439` logs the timeout and returns normally. Startup continues at lines 295–300 and reports success. `Frontend/Apple/macOS/CloudGatewayTunnel/PacketTunnelProvider.swift:106` forwards that successful adapter result
  - Evidence: [Apple's start callback contract](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider/starttunnel%28options%3Acompletionhandler%3A%29) requires waiting for network settings to complete before reporting that the provider is ready. A late settings callback only updates captured state inside `setNetworkSettings`, and cannot retract the completed start
  - Impact: The menu can show connected without confirmed tunnel routes or DNS settings. No macOS health monitor detects this uncertain startup. Routing behavior and traffic bypass have not been observed and are not asserted here
  - Fix: Treat an unconfirmed settings deadline as a sanitized startup failure, stop any started resources, and fence late settings callbacks so they cannot apply stale settings to a later session
  - Validation: Confirmed by tracing the pinned dependency and Apple callback requirements. Runtime reproduction remains pending. The same dependency serves iOS

## Evidence and limits

Reviewed `CloudGatewayMacIPC`, macOS packet-provider composition, profile adapter
boundaries, shared WireGuard parsing, the pinned WireGuard adapter/Go bridge,
and existing authorization/lifecycle tests. No production code changed. No
tests, builds, live Keychain, extension activation, or VPN actions were run.

The listener authenticates the exact signed app identity before accepting a
connection and checks identity on incoming messages. The client authenticates
the exact signed extension identity. Local macOS SDK `NSXPCConnection.h`
documents these checks. OS-derived non-root UID, stored UID/config ownership,
bounded request/record sizes, canonical UUID handles, and bounded monotonic
single-use start grants are present. No XPC method returns private material.
WireGuard payload logging is discarded, and provider errors use fixed messages.
Source review found no confirmed secret exposure or cross-user authorization
bypass.

Signed runtime checks still need to prove System Keychain sandbox access,
trusted-application ACL persistence after extension replacement, incorrect
signatures and cross-user rejection, and real stop/start behavior under delayed
DNS/network-settings callbacks. These are verification gaps, not confirmed
vulnerabilities. Current source intentionally retains committed secrets across
replacement, sign-out, quit, and profile changes.

Final no-target `./scripts/test.sh` passed all suites, both unsigned Apple builds,
and all five scans. Log: `/tmp/cloudgateway-macos-eight-fixes-full.log`.
Two review loops completed with no remaining confirmed findings.
