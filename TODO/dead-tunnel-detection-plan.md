# Dead Tunnel Detection Plan

Plan to detect and surface a "dead" WireGuard tunnel on the Apple client (iOS
now, macOS later) so the user is told quickly instead of waiting out a 60s
request timeout.

Shared-first per `AGENTS.md`: detection lives in `CloudGatewayKit` and the
packet-tunnel extension; only the in-app banner UI is per-platform. No backend,
Firebase, or Cloudflare changes.

---

## Problem

The app runs a full tunnel (`AllowedIPs = 0.0.0.0/0`), so every packet the
device sends routes through the tunnel. When the peer is deleted server-side
(admin removes the client) or the server goes down, the tunnel keeps running but
silently blackholes **all** traffic - Firebase Auth, Firestore, and the regional
API alike. The device is wedged: nothing reaches the network.

This is not "the API is down" and is not an offline-detection problem. The device
*has* connectivity (`NWPathMonitor` reports `.satisfied`, because the tunnel
interface is up). The tunnel itself is the black hole.

### Current behavior (the 60s wait)

On a refresh, `loadRemoteState` runs a sequential chain of network calls
(`CloudGatewayViewModel.swift:918`). `idToken()` resolves to
`idToken(forceRefresh: false)` (`CloudGatewayServicing.swift:213`); with a valid
cached token Firebase returns it locally with no network. The first call that
actually touches the network is `fetchRegions()` -> `send()` ->
`URLSession.shared.data(for:)` (`CloudGatewayFirebaseService.swift:616`).

`URLSession.shared` uses the default `timeoutIntervalForRequest = 60` (never set
in code), so the request blackholes for exactly 60.0s, then throws
`NSURLErrorTimedOut`. Its `localizedDescription` ("The request timed out") is
surfaced by `run`'s catch-all `errorText = error.localizedDescription`
(`CloudGatewayViewModel.swift:1119`). Every subsequent request repeats the 60s
wait because the tunnel stays up.

---

## Decisions

- **Notify, do not auto-disconnect.** Show the user a message with a Disconnect
  action; let them choose. (The official WireGuard app also does not
  auto-disconnect.)
- **Notify regardless of auth state.** The tunnel and extension are independent
  of Firebase auth. A stuck tunnel blackholes login too, so a logged-out user
  cannot sign back in and has no idea why - the notification matters *more* when
  logged out.
- **10s request timeout.** Bound the app's `URLSession` request timeout to 10s
  (down from the 60s default). Not 5s - that risks cutting off slow-but-real
  requests on poor cellular.
- **Diagnose with tunnel health, not just the timeout.** A bare timeout only says
  "a request failed," not why (dead tunnel vs. slow cell vs. transient API blip).
  Blaming the VPN on every timeout would wrongly tell users to disconnect a
  working VPN. Use WireGuard handshake age + `rx_bytes`/`tx_bytes` to confirm the
  tunnel is the culprit before showing VPN-specific copy.
- **Local notification, not remote push.** System-level local notification via
  `UNUserNotificationCenter` (shows on lock screen, banners over other apps,
  Notification Center, badge). No Push Notifications capability, no APNs, no
  server. Runtime permission only; no privacy-policy change (nothing is collected
  or transmitted).
- **No keys cross the app<->extension boundary.** The extension writes a single
  health flag to the shared app group; the old key-leaking `handleAppMessage`
  (removed in the Fable review) is not reintroduced.

---

## Design overview

Two cooperating triggers:

1. **Fast path (request-driven).** The app-side request timeout is the trigger.
   When a request times out (now ~10s, not 60s) and a tunnel is connected, the
   app reads the extension's health flag from the shared app group. If the tunnel
   is not passing traffic, notify with VPN-specific copy + Disconnect.
2. **Backstop (extension-driven).** The extension polls its own tunnel health on
   a timer and, on a confirmed-dead tunnel, posts the local notification and
   writes the health flag - even when the app is backgrounded, closed, or the
   user is logged out and making no requests.

### Tunnel health signal

The extension reads WireGuard's runtime config
(`WireGuardAdapter.getRuntimeConfiguration`, `WireGuardAdapter.swift:157`), a
UAPI `key=value` string with per-peer `last_handshake_time_sec`, `rx_bytes`, and
`tx_bytes`.

- **Handshake age** is the essential signal: never handshaked, or aged past the
  staleness threshold, means the peer is unreachable.
- **`rx_bytes` delta** is the refinement: `tx_bytes` climbing while `rx_bytes`
  stays flat is a one-way-dead tunnel - the deleted-peer / dead-server signature.
  It confirms "dead right now" faster than handshake age alone and cuts false
  positives (a healthy idle tunnel can legitimately show a ~120s-old handshake).

The extension collapses these to one health state ("passing traffic" vs. "not
passing traffic") written to the shared app group
(`group.com.gocloudlaunch.gateway`, already used by `CloudGatewayConfigCache`).
No keys, no traffic content - just a flag + timestamp.

### WireGuard timing (why the thresholds are what they are)

- `REKEY_TIMEOUT` ~5s (handshake retry interval)
- `REKEY_AFTER_TIME` ~120s (proactive rekey on an active session)
- `REJECT_AFTER_TIME` ~180s (session key hard-expiry, forces rehandshake)

A staleness threshold must sit above the legitimate rekey interval (~150-180s) to
avoid false-positiving a healthy idle tunnel. That is why the request-driven fast
path (plus `rx_bytes`) matters: it detects death in ~10-15s instead of waiting
out the ~180s background threshold.

### Expected time-to-notify

- **Fresh (re)connect into an already-dead peer (never handshakes):** ~10-15s
  (never-handshaked detection; also covers reconnect after sleep/wake or network
  change).
- **Established tunnel, peer deleted underneath it:** ~10-15s via the fast path
  (10s timeout + health flag). The pure background handshake-age backstop alone
  is ~180s, so the fast path is the primary win.

---

## Stages

### Stage 1 - Bound the request timeout (standalone win) - DONE
Give the app's API calls a dedicated `URLSession` with
`timeoutIntervalForRequest = 10` (and `waitsForConnectivity = false`), replacing
`URLSession.shared` in `send()`. Turns the 60s wait into ~10s on its own, even
before health detection lands.

- `CloudGatewayFirebaseService.swift:616` (`send`) - use a configured session.

### Stage 2 - Extension-side tunnel health - DONE
In the packet-tunnel extension, poll `adapter.getRuntimeConfiguration` on a timer,
parse `last_handshake_time_sec` / `rx_bytes` / `tx_bytes`, and derive a health
state (never-handshaked, stale handshake, or one-way-dead via `rx` flat while
`tx` rises). Write the state + timestamp to the shared app group.

- `Frontend/Apple/iOS/CloudGatewayTunnel/PacketTunnelProvider.swift` - own the
  poll loop; call into shared logic.
- New in `CloudGatewayKit` - a UAPI parser + health evaluator + app-group health
  store, so iOS and the future macOS extension share it. Sits next to
  `CloudGatewayConfigCache` / `GatewayPlatformConfiguration`.

### Stage 3 - Local notification from the extension - DONE
On a confirmed-dead tunnel, the extension posts a local notification via
`UNUserNotificationCenter` ("Your VPN server isn't responding - disconnect to
restore your connection"). Request notification authorization from the app at an
appropriate point. Implement `UNUserNotificationCenterDelegate.willPresent` ->
`.banner` so it also shows while the app is foregrounded.

- `PacketTunnelProvider.swift` - post the notification.
- App - request authorization; set the foreground-presentation delegate.

### Stage 4 - App fast path + in-app banner - DONE
When an app request times out and a tunnel is connected, read the app-group
health flag. If the tunnel is dead, surface the VPN-specific message with a
Disconnect action instead of the generic "The request timed out." Also render an
in-app SwiftUI banner from the same flag (covers the case where notification
permission was denied), on the login screen too - not just the signed-in
dashboard.

- `CloudGatewayViewModel.swift` - on request-timeout, consult health; drive
  message/state.
- `ContentView.swift` - banner + Disconnect action, shown in guest and signed-in
  modes.

### Final review - DONE
GPT 5.4 Low reviewed Stage 4 after implementation and fixes. GPT 5.4 Medium
reviewed all stages against this plan; the final review found no actionable
issues.

---

## Permissions / entitlements / privacy

- **No new entitlement.** Local notifications need only a runtime permission
  prompt (`requestAuthorization`); no Push Notifications capability, no APNs.
- **No privacy-policy change.** The notification and health flag carry no traffic,
  metadata, keys, or connection history - just an on-device "not passing traffic"
  state. Consistent with the `AGENTS.md` "never log VPN traffic/metadata" rule.
- App group `group.com.gocloudlaunch.gateway` already exists; reuse it.

---

## Not doing

- **No auto-disconnect** - notify only.
- **No backend / API / Firebase / Cloudflare changes** - the API may be perfectly
  healthy; the tunnel is the problem.
- **No remote push / APNs.**
- **No split-tunnel exclusion of the control-plane host.** Excluding the API from
  the tunnel would stop management calls from being blackholed, but the API is
  behind Cloudflare (dynamic IPs) and it changes the VPN's routing/security
  posture. Out of scope.
- **No reintroduction of a key-returning `handleAppMessage`** - the app group flag
  replaces it.

---

## Validation

- Build the apple targets (`./scripts/test.sh` where applicable) and add unit
  coverage for the UAPI health evaluator (never-handshaked, stale handshake,
  `rx`-flat/`tx`-rising, healthy) in `CloudGatewayKit` tests.
- Automated validation complete: `./scripts/test.sh apple` passes 82
  `CloudGatewayKit` tests, the unsigned iOS app/packet-tunnel build, and the
  full iOS simulator view-model suite.
- Manual: connect a client, delete it server-side, confirm the notification and
  in-app banner appear within ~10-15s in both logged-in and logged-out states,
  and that a healthy tunnel on slow cellular does **not** false-positive.

## Open questions

- Exact handshake-staleness threshold for the background backstop (~150-180s) and
  the `rx`-flat window for the fast-path confirmation - tune during testing.
- Notification copy and whether the Disconnect action lives in the notification
  (action button) as well as the in-app banner.
