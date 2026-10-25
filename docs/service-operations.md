# Service Operations: Restart and Log Inspection

Run host commands as root or with `sudo`. Use [regional deployment](regional-deployment.md)
for host builds and [VM recovery](vm-loss-recovery.md) for replacements.

Logging rules apply during investigation:

* API logs are structured JSON and can include request IDs, routes, UIDs/emails,
  client IDs, durations, and redacted exception details.
* Never keep VPN traffic logs: DNS queries, destinations, packet metadata,
  browsing/app metadata, or per-user connection history. Treat such logging as
  an incident and disable it.
* Never share private keys, full configs, Firebase credentials, auth tokens,
  `api.env`, or `bootstrap.env` contents. Report leaked key material immediately.

## cloudgateway-api.service (regional FastAPI)

Runs as root from `/opt/cloudgateway/api`, bound only to `127.0.0.1`. Systemd reads
`/etc/cloudgateway/api.env`, which must stay root-owned and mode `0600`.

```sh
systemctl status cloudgateway-api.service
systemctl restart cloudgateway-api.service
journalctl -u cloudgateway-api.service -f
journalctl -u cloudgateway-api.service --since "1 hour ago"
```

Restart after environment changes. Restarting the API leaves `wg0` and existing
tunnels running. For an API-only update, use `sudo cloudgateway-install-api <ref>`
with a published tag/SHA. With no argument it fetches the original bootstrap ref.
The helper reinstalls the API and restarts it, but does not update host configuration.
See [GitHub deployment setup](github-deployment-setup.md).

## Caddy

```sh
systemctl status caddy
journalctl -u caddy --since "1 hour ago"
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
```

Validate before reloading config. The custom binary must include
`http.handlers.rate_limit`. Check with `caddy list-modules | grep rate` if validation
reports unknown directives. Caddy logs API HTTP requests only. An outage prevents
API access while existing VPN tunnels keep running.

The `cloudgateway-origin-firewall.service` restricts HTTP/HTTPS to configured
Cloudflare ranges. Check its status alongside Caddy when edge health fails.
Caddy also requires Authenticated Origin Pulls and the allowed regional/global
API hostname. Keep the API loopback-only and direct-origin access blocked.

## wg-quick@wg0 (WireGuard)

```sh
systemctl status wg-quick@wg0
wg show wg0
wg show wg0 latest-handshakes
```

Peer changes use live `wg set` calls. Restarting `wg-quick@wg0` tears down the
interface, interrupts every client, and reruns firewall `PostDown`/`PostUp` rules.
Reserve it for a wedged interface or planned interface changes.

`/etc/wireguard/wg0.conf` must remain interface-only, without `[Peer]` blocks.
After an interface restart, restore peers, mesh routes, and policy immediately:

```sh
sudo systemctl start cloudgateway-sync-peers.service
sudo systemctl status cloudgateway-sync-peers.service
```

Reading live handshake/transfer counters is allowed. Do not persist them per user.

## cloudgateway-sync-peers.service (Firebase peer sync)

The oneshot unit restores peers, mesh routes, and account policy from Firestore
at boot. Start it through systemd so it gets the venv executable and `api.env`:

```sh
sudo systemctl start cloudgateway-sync-peers.service
systemctl status cloudgateway-sync-peers.service
journalctl -u cloudgateway-sync-peers.service --since "1 hour ago"
```

The CLI is installed at `/opt/cloudgateway/api/.venv/bin/cloudgateway-sync-peers`.
It requires the same environment as the unit, so a bare `sudo cloudgateway-sync-peers`
is not the standard host repair command.

Peer mutation shares the API's WireGuard lock. Policy uses a separate flock.
See [drift repair](wireguard-drift-repair.md) for convergence and partial failures.

* Exit `1`: peer/mesh sync failed. Policy was not attempted.
* Exit `2`: peers converged, then policy failed. Look for `peer_sync_completed`
  followed by `policy_refresh_failed`.
* Exit `0`: peers and policy applied. Best-effort status writes can still fail,
  leaving the dashboard snapshot behind the live state.

`Restart=on-failure`, `RestartSec=30`, and `StartLimitIntervalSec=0` retry the whole
pass indefinitely. Successful passes have no periodic timer. Investigate a
persistent retry loop: each retry reads Firestore again. Initial bootstrap starts
the unit before registration, then starts it again only if registration reports
edge readiness. On a rebuild, the first pass can already restore mesh if the
existing region document allows it.

**Sync All Regions** in Server Health runs the API repair path across enabled
regions. Check peer/mesh results, `policyApplied`, `meshStatusWritten`,
`policyStatusWritten`, and `clientPeersDegraded`, rather than treating HTTP success
as proof that every part converged.

## AdGuard Home (VPN DNS filter)

```sh
systemctl status adguardhome
journalctl -u adguardhome -f
```

DNS listens on the tunnel DNS IPs and forwards to Unbound on `127.0.0.1:5335`.
The admin UI is localhost-only at `127.0.0.1:3000`, with authentication disabled.
SSH access is its admin boundary. Keep query logging/statistics off and the
AdGuard DNS filter enabled. See [AdGuard configuration](../Infrastructure/OCI/adguard-home.md).

## Unbound (forward-only DoT resolver with DNSSEC validation)

```sh
systemctl status unbound
systemctl restart unbound
journalctl -u unbound -f
```

Unbound serves AdGuard Home on localhost port `5335`. It forwards over DoT to
Quad9, Mullvad, and DNS.SB, pinned by IP and TLS certificate name, and validates
DNSSEC locally. It has no plaintext recursion fallback.

Keep query logging off. If resolution fails, check outbound TCP `853` and the
root trust anchor at `/var/lib/unbound/root.key`. A resolver restart can briefly
interrupt client DNS while WireGuard stays connected.

## Cross-Region Mesh: Enable / Verify / Rollback

Mesh membership is the `meshEnabled` field in each Firestore region document.
Changing membership needs a dashboard save and sync, with compatible host/API
code already deployed. It has no tfvars or environment toggle.

**Enable:**

1. Confirm each region is deployed and registered, with unique `/24` IPv4 and
   `/64` IPv6 tunnel subnets matching the tracked subnet registry.
2. Enable `meshEnabled` for the intended regions in the admin dashboard.
3. Wait for membership saves to finish, then run **Sync All Regions**. Sync is
   disabled during saves, and a failed save cancels a pending confirmed sync.
   Sync every enabled region so membership converges across the fleet.

**Verify:**

* On each host, `wg show wg0` should list sibling server public keys with subnet
  AllowedIPs and recent handshakes. Use `ip -4 route show dev wg0` and
  `ip -6 route show dev wg0` to confirm remote tunnel routes.
* Two clients owned by the same account in different mesh regions should reach
  each other's tunnel IPs, subject to their local firewalls.
* `Mesh/{regionId}` should show `applied` entries and a successful status write.
  This is a reconciliation snapshot, not proof of a handshake.
* `skipped-incomplete` and `skipped-overlap` require metadata/subnet repair and
  another Sync All. They are configuration failures, not queued work.

**Rollback:** clear `meshEnabled` for one region or all regions, wait for saves,
then run **Sync All Regions**. Successful hosts remove the disabled regions'
mesh peers and routes. Investigate any host whose pass fails or cannot be reached.

## Account-Scoped ACL (Client-to-Client Isolation)

The `inet cloudgateway` nftables table restricts forwarded tunnel traffic to
clients owned by the same account. Admin-owned clients can also reach regional
servers and be reached by them. Other accounts' clients remain isolated.
Client internet egress, local client-to-server `INPUT`, and server mesh links
have separate rules. See [ACL design](access-control-list.md) and
[policy reconciliation](wireguard-drift-repair.md#account-scoped-acl-policy-reconcile).

The table loads at interface `PostUp` with empty dynamic policy. Before the first
successful policy pull, forwarded client-to-client traffic is denied while
client-to-server traffic remains available. A later failure leaves the last
applied policy in place. An API-only update cannot install a missing table.
The initial ACL rollout required rebuilding every region from one deploy tag,
with only partial enforcement until the final region completed.

Every account needs `Users/{uid}.accountSlot`. The one-time backfill is complete
and its release files are in git history. If `Counters/accountSlots.nextSlot` is
lost or lowered, restore the allocation watermark from a trusted backup. It is
the only record of slots issued to hard-deleted accounts. Never derive it from
live `Users` or rerun migration seeding. Allocation fails closed until the counter
is valid. Any manual correction must exceed every slot that could ever have been
issued. Client reservation exposes
`ACCOUNT_SLOT_UNAVAILABLE`; user provisioning wraps the failure as `FIREBASE_WRITE_FAILED`.

Server Health compares comprehensive IPv4/IPv6 policy hashes across enabled
regions. Hashes cover `cg_tunnel4/6`, `cg_infra4/6`, `cg_admin4/6`, `cg_slot4/6`, and
`cg_pairs4/6`. Disabled regions are excluded. Missing/unreadable policy documents
are failures. "Last applied" is the last successful apply/read-back timestamp,
and age alone is not drift. A failed apply leaves the previous document intact,
so a healthy-looking card can coexist with a failed reconcile. Check host logs
and Sync All results. A status-write failure also leaves stale display data.

After trusted out-of-band `UserRoles` changes, run **Sync All Regions** immediately.
There is no role-change API, timer, or automatic propagation. Until sync, hosts
keep the previous admin allow-set. Client create/delete policy pokes target
individual regions and do not replace fleet-wide verification.

Account deletion marks its clients non-active fleet-wide before removing account
documents. An unreachable host can retain a live peer and stale policy until its
next boot or manual sync. During that gap, the deleted account's old config can
still use that region's egress and reach its own clients there. Account slots
are never reused, so this does not grant access to another account. Sync the host
as soon as it is reachable.

Inspect policy locally with:

```sh
sudo nft list table inet cloudgateway
```

The output maps tunnel addresses to account slots. Keep it within the operator's
investigation and do not paste it into tickets or logs.

## Quick Triage Order

1. Edge `/api/health` fails: check Caddy, the API service, origin firewall, and
   Cloudflare DNS/proxy/AOP settings.
2. Client mutation returns `WIREGUARD_APPLY_FAILED`: check the API journal,
   `wg show wg0`, and [drift repair](wireguard-drift-repair.md).
3. A handshake exists but DNS fails: check AdGuard Home, Unbound, and DoT egress.
   For other traffic failures, check forwarding, NAT/firewall rules, and policy
   when client-to-client traffic is affected.
