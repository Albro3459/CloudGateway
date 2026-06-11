# Service Operations: Restart and Log Inspection

Host-level notes for the services on each regional server. All commands run as root (or with `sudo`) on the regional host.

Logging boundaries apply to operations too:

* API logs are structured JSON and may include request IDs, routes, user emails, and display names. That is expected.
* No service may keep VPN traffic logs: no DNS queries, no destination IPs or domains, no browsing/app metadata, no per-user connection history. If you find such logging enabled, treat it as an incident and disable it.
* Never paste private keys, full WireGuard configs, Firebase credentials, auth tokens, or the contents of `/etc/cloudlaunch/api.env` into logs or tickets.

## cloudlaunch-api.service (regional FastAPI)

* Runs as root, working directory `/opt/cloudlaunch/api`, bound only to `127.0.0.1`. Config comes from `/etc/cloudlaunch/api.env` (mode `0600`, root-owned).

```sh
systemctl status cloudlaunch-api.service
systemctl restart cloudlaunch-api.service
journalctl -u cloudlaunch-api.service -f
journalctl -u cloudlaunch-api.service --since "1 hour ago"
```

* Logs are structured JSON: request ID, event, region, route, status, UID/email, client ID, duration, exception type/message. If you see key material or full configs in API logs, that is a bug - report it immediately.
* After editing `/etc/cloudlaunch/api.env`, restart the service. Verify the file stays `0600` root-owned.
* Restarting the API does not touch `wg0`; existing tunnels keep working.
* To roll the API to a new version, run `sudo cloudlaunch-install-api <ref>` with a pushed tag/SHA (no argument re-fetches the deployed ref). It downloads `API/` from GitHub, reinstalls into the venv, and restarts the service - see [docs/github-deployment-setup.md](github-deployment-setup.md).

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

* The binary is a custom build with `github.com/mholt/caddy-ratelimit`. A stock `caddy` binary will fail on the rate-limit directives - confirm the installed binary with `caddy list-modules | grep rate` if validation errors mention unknown directives.
* Caddy logs HTTP API requests only. While Caddy is down, the dashboard cannot reach the regional API, but VPN tunnels are unaffected.

## wg-quick@wg0 (WireGuard)

```sh
systemctl status wg-quick@wg0
wg show wg0
wg show wg0 latest-handshakes
```

* Avoid `systemctl restart wg-quick@wg0` during normal operations: it tears down and re-creates the interface, briefly dropping every client and re-running the firewall `PostUp`/`PostDown` rules. Peer changes are applied by the API with `wg syncconf`; manual peer repair uses [docs/wireguard-drift-repair.md](wireguard-drift-repair.md).
* A restart is acceptable when the interface itself is wedged or after host-level interface config changes. On boot, the service brings `wg0` up from `/etc/wireguard/wg0.conf` with the current peer set.
* WireGuard exposes runtime handshake/transfer counters via `wg show`; reading them live is fine, persisting them per user is not.

## Unbound (VPN DNS), if present

```sh
systemctl status unbound
systemctl restart unbound
journalctl -u unbound -f
```

* Unbound serves DNS to VPN clients on the tunnel DNS IPs.
* Query logging must stay off (`verbosity` low, no `log-queries`). DNS query logs are forbidden VPN traffic logs.
* If clients connect (handshake present) but cannot resolve names, check Unbound before suspecting WireGuard.

## Quick Triage Order

1. `GET https://<regionId>.<origin>/api/health` fails: check Caddy, then `cloudlaunch-api.service`, then Cloudflare DNS/proxy.
2. Client create/delete fails with `WIREGUARD_APPLY_FAILED`: check API journal, then `wg show wg0`, then [docs/wireguard-drift-repair.md](wireguard-drift-repair.md).
3. Tunnel connects but no traffic/DNS: check Unbound, IP forwarding, and the NAT/firewall rules from the server config `PostUp` block.
