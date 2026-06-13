# AdGuard Home Configuration

The regional bootstrap configures AdGuard Home automatically. No manual UI setup is required for the default deployment.

## Default Configuration

* DNS listens only on the WireGuard tunnel DNS IPs.
* Upstream DNS is Unbound on `127.0.0.1:5335`.
* Only the AdGuard DNS filter is enabled.
* Query logging is disabled.
* Statistics are disabled.
* The admin UI listens only on `127.0.0.1:3000`.

## Optional UI Access

Use an SSH tunnel if you need to inspect the local admin UI:

```sh
ssh -L 3000:127.0.0.1:3000 <regional-host>
```

Then open `http://127.0.0.1:3000` locally.

The bootstrap leaves AdGuard Home UI auth disabled because the UI is localhost-only. Treat SSH access as the admin boundary.

Do not expose the AdGuard Home UI through Caddy or public firewall rules.

## Operator Rules

* Keep query logging and statistics off.
* Keep filtering to DNS filters only unless there is a specific reason to expand scope.
* Keep the admin UI bound to localhost.
* Keep the AdGuard DNS filter enabled.
* Add allowlist rules only when a real user workflow breaks.

## Filter Changes

Prefer small allowlist entries over disabling the filter. After changing filters or rules, verify:

```sh
systemctl status adguardhome
journalctl -u adguardhome --since "15 minutes ago"
```

Do not paste DNS queries, requested domains, or user-specific browsing details into tickets.
