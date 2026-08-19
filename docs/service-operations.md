# Service Operations: Restart and Log Inspection

Host-level notes for the services on each regional server. All commands run as root (or with `sudo`) on the regional host.

Logging boundaries apply to operations too:

* API logs are structured JSON and may include request IDs, routes, and user emails. That is expected.
* No service may keep VPN traffic logs: no DNS queries, no destination IPs or domains, no browsing/app metadata, no per-user connection history. If you find such logging enabled, treat it as an incident and disable it.
* Never paste private keys, full WireGuard configs, Firebase credentials, auth tokens, or the contents of `/etc/cloudgateway/api.env` into logs or tickets.

## cloudgateway-api.service (regional FastAPI)

* Runs as root, working directory `/opt/cloudgateway/api`, bound only to `127.0.0.1`. Config comes from `/etc/cloudgateway/api.env` (mode `0600`, root-owned).

```sh
systemctl status cloudgateway-api.service
systemctl restart cloudgateway-api.service
journalctl -u cloudgateway-api.service -f
journalctl -u cloudgateway-api.service --since "1 hour ago"
```

* Logs are structured JSON: request ID, event, region, route, status, UID/email, client ID, duration, exception type/message. If you see key material or full configs in API logs, that is a bug - report it immediately.
* After editing `/etc/cloudgateway/api.env`, restart the service. Verify the file stays `0600` root-owned.
* Restarting the API does not touch `wg0`; existing tunnels keep working.
* To roll the API to a new version, run `sudo cloudgateway-install-api <ref>` with a pushed tag/SHA (no argument re-fetches the deployed ref). It downloads `Backend/API/` from GitHub, reinstalls into the venv, and restarts the service - see [docs/github-deployment-setup.md](github-deployment-setup.md).

## Caddy

```sh
systemctl status caddy
journalctl -u caddy -f
journalctl -u caddy --since "1 hour ago"
```

* Validate config before restarting:

```sh
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy   # prefer reload over restart for config changes
```

* The binary is the prebuilt CloudGateway release with `github.com/mholt/caddy-ratelimit`. A stock `caddy` binary will fail on the rate-limit directives - confirm the installed binary with `caddy list-modules | grep rate` if validation errors mention unknown directives.
* Caddy logs HTTP API requests only. While Caddy is down, the dashboard cannot reach the regional API, but VPN tunnels are unaffected.

## wg-quick@wg0 (WireGuard)

```sh
systemctl status wg-quick@wg0
wg show wg0
wg show wg0 latest-handshakes
```

* Avoid `systemctl restart wg-quick@wg0` during normal operations: it tears down and re-creates the interface, briefly dropping every client and re-running the firewall `PostUp`/`PostDown` rules. Peer changes are applied live by the API with `wg set`.
* A restart is acceptable when the interface itself is wedged or after host-level interface config changes. `/etc/wireguard/wg0.conf` is interface-only (never contains peers), so after any `wg-quick` restart the peer set is empty until the sync restores it - run `sudo cloudgateway-sync-peers` immediately afterward rather than waiting for the next boot.
* WireGuard exposes runtime handshake/transfer counters via `wg show`; reading them live is fine, persisting them per user is not.

## cloudgateway-sync-peers.service (Firebase peer sync)

* Rebuilds the live `wg0` peer set from the region's `active` client docs. Firebase is the single source of truth for peers; nothing on the host persists them. Runs at boot (with on-failure retries every 30s until Firebase is reachable) and on demand.

```sh
sudo cloudgateway-sync-peers
systemctl status cloudgateway-sync-peers
journalctl -u cloudgateway-sync-peers --since "1 hour ago"
```

* Logs structured JSON with added/updated/removed counts. Semantics and drift cases are documented in [docs/wireguard-drift-repair.md](wireguard-drift-repair.md).
* It shares the API's mutation lock, so running it during live create/delete traffic is safe.

## AdGuard Home (VPN DNS filter)

```sh
systemctl status adguardhome
journalctl -u adguardhome -f
```

* AdGuard Home serves DNS to VPN clients on the tunnel DNS IPs.
* The admin UI is local-only at `127.0.0.1:3000`; do not expose it through Caddy.
* UI auth is disabled by default because the UI is localhost-only. Treat SSH access as the admin boundary.
* Only the AdGuard DNS filter should be enabled unless an operator intentionally changes it.
* Query logging and statistics must stay off. DNS query logs are forbidden VPN traffic logs.
* AdGuard Home forwards upstream queries to local Unbound on `127.0.0.1:5335`.
* If clients connect (handshake present) but cannot resolve names, check AdGuard Home first, then Unbound, before suspecting WireGuard.

## Unbound (forward-only DoT resolver with DNSSEC validation)

```sh
systemctl status unbound
systemctl restart unbound
journalctl -u unbound -f
```

* Unbound serves only AdGuard Home on localhost port `5335`.
* It forwards over DNS-over-TLS to Quad9, Mullvad, and DNS.SB (pinned by IP as `IP@853#certname`) and validates DNSSEC locally against the root trust anchor. It is forward-only, never recursive, so it never talks plaintext to authoritative servers.
* Query logging must stay off (`verbosity` low, no `log-queries`). DNS query logs are forbidden VPN traffic logs.
* If resolution fails, verify the host can reach the DoT upstreams on port 853 and that `/var/lib/unbound/root.key` exists for validation.

## Cross-Region Mesh: Enable / Verify / Rollback

The mesh bridges regional servers together over `wg0` so a peer on one region can reach a peer on
another region by tunnel IP. Membership lives only in Firestore (`meshEnabled` on each region doc,
operator-toggled from the admin dashboard); there is no tfvars var or env var for it. No SSH and no
redeploy are needed to enable, verify, or roll back mesh membership - only a dashboard sync.

**Enable:**

1. Deploy (or confirm already deployed) every region that should join the mesh, with each region's
   tunnel subnet inside the shared aggregates and non-overlapping with every other region's -
   `scripts/terraform-preflight.py` enforces this at deploy time (see
   [regional-deployment.md](regional-deployment.md)).
2. Wait for each region's deployment-ready email (bootstrap self-registers the region doc with its
   tunnel CIDRs at the end of bootstrap).
3. In the admin dashboard, flip `meshEnabled` on for each region that should join.
4. Click "Sync All Regions". This is the only sync action - there is no per-region selection,
   because a partial sync can leave the mesh half-applied on the regions left out.

**Verify (per host, over SSH):**

* `wg show wg0` lists the other mesh region's server public key with subnet-width `allowed-ips`
  (`10.0.N.0/24, fd42:42:42:N::/64`) and a recent handshake.
* `ip route` shows the remote region's subnets routed `dev wg0`.
* Two test clients in different regions can ping each other's tunnel IPs.
* The `Mesh/{regionId}` Firestore docs show `status: "applied"` for each peer, with a recent
  `updatedAt`.
* `skipped-incomplete` and `skipped-overlap` are configuration failures, not pending work. Correct
  the Region metadata or overlap, then run Sync All Regions again; runtime overlap defense remains
  active while the condition persists.

**Rollback:** flip `meshEnabled` off - for one region to remove just that region from the mesh, or
for every region to tear the mesh down entirely - then "Sync All Regions" again. Every host
converges to peers-and-routes-removed for the disabled region(s) on that one sync pass; no SSH,
redeploy, or timer is required.

## Account-Scoped ACL (Client-to-Client Isolation)

A stateless nftables filter (`inet cloudgateway` table, `cg_forward` chain, installed empty by
`PostUp` and populated by a policy reconcile pass) restricts client-to-client traffic on the
tunnel to clients owned by the same CloudGateway account. See
[docs/wireguard-drift-repair.md](wireguard-drift-repair.md#account-scoped-acl-policy-reconcile) for
how the reconcile pass works and [TODO/account-scoped-acl.md](../TODO/account-scoped-acl.md) for
the design.

**What it guarantees:** a client can reach another client over the tunnel only when both belong to
the same account. An admin-owned client can additionally reach, and be reached by, any regional
server (SSH proxy jump support), but not other accounts' clients.

**What it deliberately does not cover** - all unchanged by this feature:

* Client to internet egress.
* A client reaching its own region's server (DNS, API) - that traffic is `INPUT`, not `FORWARD`.
* Mesh server-to-server links between regions.

**Legacy account-slot migration (one-time, before enforcement):** every provisioned account needs
`Users/{uid}.accountSlot` before any region enforces the ACL - an account with no slot is absent
from every policy map and loses same-account connectivity the moment enforcement is on. Take a
fresh Firestore backup with `scripts/backup_firestore.py`, run
`releases/access-control-lists/backfill_account_slots.py` in its default dry-run mode, review the
aggregate counts, run it again with `--apply`, then rerun the dry-run and confirm it reports a
no-op. This must complete before any region is rebuilt with the ACL enforced. See
[releases/access-control-lists/README.md](../releases/access-control-lists/README.md) for the
script's flags, credentials handling, and failure modes.

**Reading the Server Health policy display:** per enabled region, row count, comprehensive IPv4/
IPv6 policy hashes (`mapHashV4`/`mapHashV6`, covering every authorization-bearing live object -
`cg_tunnel4/6`, `cg_infra4/6`, `cg_admin4/6`, `cg_slot4/6`, `cg_pairs4/6` - not just the slot map),
and `updatedAt` shown as "Last applied," the server timestamp of that region's last successful
live apply and read-back. Timestamp age alone is never drift and never staleness - the staleness
concept from earlier waves is gone entirely. Drift is comprehensive hash disagreement among
enabled regions only; a disabled region renders as excluded from the comparison, keeps showing
whatever its document holds, and can never be drifted or drift anyone else. For an enabled region,
a missing, malformed, or unreadable `Policy/{regionId}` is an explicit per-region failure state
("Never synced" / "Unreadable"), and a failure to read the `Policy` collection at all gets its own
card rather than reporting every region as never synced; none of these ever takes down the
independent Mesh status. Status writes remain best effort and a status write
failure never fails a sync pass.

Because reconcile re-reads `UserRoles` and applies `cg_admin4/6` on every pass, an admin allow-set
change is visible in the comprehensive hash as soon as the next reconcile runs. There is no
role-mutation API, UI, timer, or automatic role propagation in this release: a trusted operator who
edits `UserRoles` out of band must run Sync All Regions immediately, and until they do, the fleet
keeps enforcing the previous allow-set.

**Repair path:** the same as peer/mesh drift - **Sync All Regions** in the admin dashboard. A
region-scoped pass (`POST /api/sync/refresh`, fired automatically by client create/delete) reaches
only one region and returns no detail, so use Sync All when you need to confirm or force a repair
across the fleet.

**Failure mode:** the policy table is installed empty at boot, before any pull, and stays empty
until the first successful reconcile. So an unreachable Firestore means "peer-to-peer is down,"
never "VPN is down" - client-to-server tunnel connectivity is unaffected.

**Account deletion:** `DELETE /account` marks every one of the account's client documents
non-active fleet-wide, in every region's `Instances` subcollection, before it hard-deletes
anything - including a region whose host was unreachable when its peer/client cleanup ran. That
fence means no later policy pull, on that region or any other, can ever restore a deleted
account's connectivity, so the deleting account's rows are already non-active for the entire
window an unreachable region stays stale. An unreachable region is not repaired automatically: it
keeps an orphaned WireGuard peer and a stale policy row until its next boot or a manual
`cloudgateway-sync-peers` run (see
[docs/wireguard-drift-repair.md](wireguard-drift-repair.md)). This is an accepted, documented
risk with a bounded consequence: until that region syncs, a deleted account's existing
configuration can still bring up a tunnel to *that one region* and use it for egress, and its own
clients on that region can still reach each other through the stale policy row. It cannot reach
any other account's clients - account slots are never reused, so no live account holds the stale
row's slot - and every other region already refuses it. Run `cloudgateway-sync-peers` on the
region once it is reachable, rather than leaving it stale indefinitely.

**Inspecting live state on a host:**

```sh
sudo nft list table inet cloudgateway
```

Shows the installed sets/maps/chain and their current elements: `cg_slot4`/`cg_slot6` (address to
account slot), `cg_pairs4`/`cg_pairs6` (allowed source-slot/destination pairs), `cg_admin4`/
`cg_admin6`, and `cg_infra4`/`cg_infra6`. Never print or paste this output outside the operator's
own investigation - it maps tunnel addresses to opaque account slots, not to uids or emails, but
still treat it like the rest of the logging boundary above.

## Quick Triage Order

1. `GET https://<regionId>.<origin>/api/health` fails: check Caddy, then `cloudgateway-api.service`, then Cloudflare DNS/proxy.
2. Client create/delete fails with `WIREGUARD_APPLY_FAILED`: check API journal, then `wg show wg0`, then [docs/wireguard-drift-repair.md](wireguard-drift-repair.md).
3. Tunnel connects but no traffic/DNS: check AdGuard Home, then Unbound and DoT upstream reachability on port 853, then IP forwarding and the NAT/firewall rules from the server config `PostUp` block.
