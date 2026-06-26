# AdGuard Home Configuration

The regional bootstrap configures AdGuard Home automatically. No manual UI setup is required for the default deployment.

## Default Configuration

* DNS listens only on the WireGuard tunnel DNS IPs.
* Upstream DNS is forwarded over DNS-over-TLS (DoT) to Quad9, Mullvad, and LibreDNS, load balanced so each query goes to a single upstream.
* `bootstrap_dns` (Quad9 plus dns0.eu as an independent anycast resolver) is plaintext but only resolves the upstream resolver hostnames at startup; it never carries user queries.
* DNSSEC is enabled in AdGuard Home, which sets the DNSSEC OK bit on upstream queries; the DoT resolvers perform validation and AdGuard passes their validated answers through to clients.
* Only the AdGuard DNS filter is enabled.
* Query logging is disabled.
* Statistics are disabled.
* The admin UI listens only on `127.0.0.1:3000`.

## Why DNS-over-TLS

Forwarding over DoT means the only DNS leaving the region is encrypted traffic to known, certificate-authenticated resolvers. The cloud provider and any on-path observer cannot see the domains clients look up, only that encrypted DNS is occurring.

This is also why the region runs no self-hosted recursive resolver. Recursion has to query the root, TLD, and authoritative servers over plaintext port 53 (encrypted authoritative DNS is effectively undeployed), which would expose every lookup to the provider in clear. Encrypting egress therefore requires forwarding to an external resolver that speaks DoT. Queries are load balanced across three independent no-log providers so no single upstream sees the full stream.

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
