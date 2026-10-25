# Full and Mesh only modes

Research for `mesh-mode`, 2026-10-25. Scope: macOS app and its existing CLI. Future Linux CLI behavior is described only. No iOS UI change.

## Recommendation

Implement this as a local routing preference. Existing servers already carry mesh traffic and enforce account access. No VPN server deployment, API change, Firestore migration, new client, or key rotation is needed for the proposed toggle, assuming deployed hosts match the current mesh/ACL implementation.

The routing change is small. A complete feature is a modest client change across the controller, tunnel extension, menu, CLI, persistence, and status. It needs more than replacing one `AllowedIPs` line.

- **Full:** keep today's configuration. Internet traffic uses the selected region's VPN, alongside permitted mesh traffic. Keep regional VPN DNS and its AdGuard filtering.
- **Mesh only:** route CloudGateway tunnel addresses through the selected region. Ordinary internet traffic and DNS use the Mac's underlying connection. Keep access to permitted devices in the same region and other connected mesh regions.

Full remains the default. This switch does not enable or disable a region's mesh membership. A Mac in Mesh only can communicate with permitted iOS devices that continue using Full.

## What the app and CLI would show

Add a **Mode** submenu near the VPN connection control, with exactly two checkmarked choices: **Full** and **Mesh only**. Keep the VPN on/off control separate. Show the current mode beside connected status, for example `VPN connected · Mesh only`.

Proposed CLI syntax, to implement on macOS first:

```text
cloudgateway mode
cloudgateway mode status
cloudgateway mode full
cloudgateway mode mesh
cloudgateway status
cloudgateway auth status
```

Use `full` and `mesh` as CLI arguments and serialized mode values. Display them as **Full** and **Mesh only** in the app.

`status` keeps every existing VPN, observation, config, operation/result/warning, and extension-update detail, and adds mode and auth status. Preserve existing JSON fields and add mode/auth data alongside them. Apply the same additions to `status --operation` without changing its lookup behavior.

`mode status` shows only mode status, including selected versus active mode when they differ. Bare `mode` is shorthand for the same read. The existing `auth status` remains the focused auth check. Reuse its auth state for the combined status summary, including signed out, restoring, retained but unverified, signed in online/offline, and access denied. A retained session alone must not appear as verified sign-in. VPN state remains visible when signed out or auth is unavailable.

Combined status maps auth from the same controller snapshot it already reads. Do not call the focused `authStatus()` workflow or add a wait for auth restoration. On the compatible path for a different build, show mode/auth as unavailable when those fields are absent, while retaining VPN status and operation lookup.

Setting an already-selected and applied mode does nothing. When disconnected, a change saves the preference for the next connection. When connected, it reconnects the same client in the new mode. The CLI and menu use the same controller command and preference. The existing `up` command uses that preference.

Recommend one preference per signed-in account on this Mac, shared across its selected regions/configs. It persists through controller/app restarts and does not sync to other devices. Signed-out status can still describe a retained tunnel, following the existing disclosure rules. Mode changes that start/restart a tunnel require the normal authorized controller path.

Status should distinguish the selected preference from the active session. Example combined output for a connected tunnel, retaining the existing rows:

```text
VPN: connected
Observation: current
Config: <config-id>
Mode: mesh
Auth: Signed in (online)
Operation: none retained
```

The focused mode check when disconnected:

```text
Selected mode: mesh
Active mode: none
```

During switching, show reconnecting and the requested mode. Internally and in JSON, carry `selectedMode` and nullable `activeMode`, with the existing observation time/freshness. A saved preference or successful start submission does not prove the new mode is active. If the restart fails, report the failure and disconnected/unknown state. Do not silently reconnect in Full. Older compatible status clients can retain coarse VPN status without claiming a mode.

## Routing and DNS

Keep the server-issued config as the canonical secret. At tunnel start, parse it and derive the runtime configuration for the selected mode. Preserve keys, assigned addresses, regional endpoint, MTU, and persistent keepalive.

For Mesh only, replace the regional peer's defaults with the existing fleet aggregates:

```text
AllowedIPs = 10.0.0.0/16, fd42:42:42::/48
```

Clear both interface DNS servers and DNS search domains. The bundled WireGuardKit generates OS routes from peer AllowedIPs and installs a wildcard DNS resolver whenever DNS servers are present. Merely narrowing routes would keep ordinary DNS on the VPN. Clearing both DNS fields lets its current settings generator omit the VPN resolver, so no WireGuardKit fork change should be needed.

These are the exact CloudGateway aggregates, not all private address space. Current allocations are San Jose `10.0.0.0/24` and `fd42:42:42::/64`, and Chicago `10.0.1.0/24` and `fd42:42:42:1::/64`. Aggregate routing covers future regions within the existing allocation contract without fetching a new client route list. Both IPv4 and IPv6 must change together.

There is no configured mesh naming domain or AdGuard DNS rewrite service to preserve. Initial mesh access remains by tunnel IP or names the user already resolves independently. A future private naming feature would need explicit split DNS. Mesh only also means ordinary DNS no longer receives CloudGateway's AdGuard filtering.

**LAN overlap is the main routing tradeoff.** The fleet's `10.0.0.0/16` can overlap home or office networks. Local routes, including more specific routes, can affect which destination wins. Exact regional routes would reduce the claimed address range but still collide with an identical LAN subnet. For the initial implementation, use the established aggregates and document/validate this limit. If overlap is a frequent problem, consider discovered regional prefixes separately. Do not broaden the routes to `10.0.0.0/8` or all ULA space.

Apple documents the role of [included routes](https://developer.apple.com/documentation/networkextension/neipv4settings/includedroutes) and how a wildcard [DNS match domain](https://developer.apple.com/documentation/networkextension/nednssettings/matchdomains) makes a split tunnel use VPN DNS. WireGuard documents how [AllowedIPs selects outgoing peers and filters incoming source addresses](https://www.wireguard.com/#cryptokey-routing).

## Why servers can stay as they are

Each client already connects to one regional server. That server forwards same-region traffic directly and remote-region traffic over existing server mesh peers. Mesh only keeps that topology. It does not add direct device peering, discovery, NAT traversal, or a serverless mesh.

Server-side client AllowedIPs remain the assigned `/32` and `/128`. Those authenticate source addresses. Narrowing the client's destination routes does not change the server's return route. Remote server peers already carry regional `/24` and `/64` networks.

Cross-region reachability still requires both regions to be enabled mesh members, working peer/routes, account ACL permission, and destination host firewall permission. Same-region client access does not require inter-region mesh membership. The normal same-account client ACL and existing infrastructure/admin exceptions apply equally in both modes. Regional capacity and account client limits stay the same.

This conclusion comes from source inspection, not a live server audit. Existing mesh operation is a deployment prerequisite. Selecting Mesh only does not prove any remote device is online, and the admin `Mesh.applied` snapshot does not prove a working handshake.

**Mesh only is a user routing choice.** It does not prevent a modified client from sending internet traffic through its VPN server. Enforcing that prohibition would require separate server firewall policy and control-plane state. That is a different requirement from the requested toggle. It also adds no kill switch or guarantee that traffic is blocked during a reconnect.

## Client implementation

Implementation started 2026-10-25. Checkboxes track completed code and validation checkpoints.

- [x] Add a small shared routing-mode enum and pure parsed-config transformation in CloudGatewayKit, with Full preserving today's behavior. Keep Apple UI/lifecycle changes in macOS. Shared tests and the complete iOS gate pass.
- [ ] Reject malformed/unsupported mode values at mutation/start boundaries. Treat legacy profiles with no mode as Full. Keep profile identity and tunnel observation readable when mode metadata is invalid, report mode as unknown, and allow the normal stop path. Invalid mode metadata must not hide a running tunnel or prevent disconnecting it.
- [ ] Persist the account preference as non-secret metadata. Carry mode into the Mac's installed profile metadata and decode it alongside the secret reference. Keep the canonical config and its hash unchanged so inventory authorization, secret recovery, and cloud refresh keep working.
- [ ] Apply the transformation inside the Mac packet tunnel after its one-use grant resolves the canonical secret and before starting WireGuard. Reuse the existing start authorization. Do not write derived configs or secrets to disk or logs.
- [ ] Add a controller-owned mode operation using the current acceptance/confirmation/result workflow. Include mode in request validation and deduplication. Reject overlapping mutations and extension-update work. An accepted operation continues if the menu closes or the CLI detaches.
- [ ] Initially switch by confirmed stop, metadata save/reload, fresh start grant, then start of the same client. Acquire the short-lived grant after the stop. Existing `connect` returns early for an already-active profile, so the mode operation must explicitly handle the restart. Handle failure without silently substituting another mode or client.
- [ ] Preserve mode through profile replacement, refresh, offline starts, secret recovery, region switching, and managed extension-update reconnect. Recover active-session mode after controller restart from trustworthy session/profile evidence. If that evidence is unavailable, show unknown rather than the latest preference.
- [ ] Extend menu snapshots, controller status/IPC, CLI parser/help/text/JSON, and operation lookup. Preserve all existing combined status output and add mode plus the existing auth summary. Add `mode status` and keep `auth status` as focused reads. Keep backward-compatible coarse status and stop behavior. Because saving profile metadata does not change a running adapter, establish active mode only after the corresponding session applies it and is observed connected. Add a small provider acknowledgement if profile/session evidence cannot establish that reliably.

A reconnect briefly interrupts mesh sessions. Switching from Full can also interrupt existing internet sessions as their public source address changes. Existing Mac lifecycle code already supports stop-and-wait and authenticated restarts. WireGuardKit supports live updates underneath, but the Mac provider currently exposes start/stop only. Live switching would add an update command, serialization with stop, acknowledgement, and applied-state handling. Defer it unless avoiding reconnects becomes a requirement.

macOS currently has no blackout health monitor or automatic traffic-probe recovery, so this feature does not need to adapt that iOS behavior. Keep status about observed tunnel lifecycle and mode. Do not label mesh reachability healthy based on ordinary internet working.

## Future Linux CLI

Reuse the same Full/Mesh only semantics, command names, default, and selected/applied status distinction. Linux will need its own interface routing, DNS integration, persistence, and permissions. No Linux code or scaffolding is part of this work.

Fixed aggregate routing does not require new backend metadata. If a future HTTP-only Linux client needs dynamic regional subnet discovery, the current HTTP region summaries would need expansion. Firestore region documents already contain those fields, but today's generic client region model does not carry them.

## Validation

- [ ] Run the repository Apple checks, including host-free mode lifecycle and CLI tests
- [ ] Complete independent implementation review, with at most three review rounds
- [ ] Update the macOS user/development docs and commit completed checkpoints locally

Run the repository's macOS target, and Apple targets if shared behavior changes. Add focused coverage for runtime transformation, legacy defaults, controller mode operations, persistence, and status/IPC compatibility as part of implementation.

Manually verify IPv4 and IPv6 mesh access within/across regions, access denial across accounts, unchanged iOS peers, ordinary internet egress/DNS in each mode, local LAN overlap, and switching while active. Check restart failure, offline start, controller restart, menu/CLI agreement, frontend detach, profile refresh, and managed extension updates. Cover invalid-mode observation/stop and mixed-build status/operation lookup with unavailable mode/auth. Verify actual routes/resolver settings locally without recording traffic, DNS queries, configs, or keys. Do not treat `doctor` HTTPS success as proof of mesh routing.

## Source anchors and review

Research used independent Codex main and secure account subagents. Both concluded that the routing preference can be client-only and recommended aggregate routes, local DNS, canonical-config preservation, and reconnect-based switching. Findings were checked against the current source. No live hosts were accessed and no builds/tests were run for this docs-only research.

Astra reviewed the plan on the secure Codex account with high reasoning and found no material blockers. Its review clarified invalid-mode observation/stop behavior and the combined status fallback for different builds.

- [Mesh topology, aggregates, addressing, and membership](/Users/alexbrodsky/GitHub/CloudGateway/docs/shared-subnet-mesh.md:1)
- [Account ACL boundary](/Users/alexbrodsky/GitHub/CloudGateway/docs/access-control-list.md:15)
- [Tracked subnet allocations](/Users/alexbrodsky/GitHub/CloudGateway/Infrastructure/OCI/terraform/subnet-registry.json:1)
- [Canonical client config and server peer generation](/Users/alexbrodsky/GitHub/CloudGateway/Backend/API/src/wireguard.py:301)
- [Region membership gates](/Users/alexbrodsky/GitHub/CloudGateway/Backend/API/src/sync.py:92)
- [DNS settings and route generation](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/wireguard-apple/Sources/WireGuardKit/PacketTunnelSettingsGenerator.swift:86)
- [Mac secret resolution and adapter start](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayTunnel/PacketTunnelProvider.swift:15)
- [Profile replacement and start options](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacVPNProfileAdapter.swift:58)
- [Start-grant lifetime and consumption](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacIPC/CloudGatewayMacSecretService.swift:72)
- [Controller requests and versioning](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerContracts.swift:10)
- [CLI commands and options](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIArguments.swift:49)
- [Current Mac lifecycle and health boundary](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/README.md:69)
