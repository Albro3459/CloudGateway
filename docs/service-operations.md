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
* To roll the API to a new version, run `sudo cloudgateway-install-api <ref>` with a pushed tag/SHA (no argument re-fetches the deployed ref). It downloads `API/` from GitHub, reinstalls into the venv, and restarts the service - see [docs/github-deployment-setup.md](github-deployment-setup.md).

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

## Quick Triage Order

1. `GET https://<regionId>.<origin>/api/health` fails: check Caddy, then `cloudgateway-api.service`, then Cloudflare DNS/proxy.
2. Client create/delete fails with `WIREGUARD_APPLY_FAILED`: check API journal, then `wg show wg0`, then [docs/wireguard-drift-repair.md](wireguard-drift-repair.md).
3. Tunnel connects but no traffic/DNS: check AdGuard Home, then Unbound and DoT upstream reachability on port 853, then IP forwarding and the NAT/firewall rules from the server config `PostUp` block.
