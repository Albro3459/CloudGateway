# AdGuard Home Configuration

The regional bootstrap configures AdGuard Home automatically. No manual UI setup is required for the default deployment.

## Default Configuration

* DNS listens only on the WireGuard tunnel DNS IPs.
* Upstream DNS is local Unbound on `127.0.0.1:5335`, which forwards over DNS-over-TLS (DoT) to Quad9, Mullvad, and DNS.SB and validates DNSSEC locally.
* DNSSEC is also enabled in AdGuard Home (it sets the DNSSEC OK bit and passes the validated answers through), but Unbound is the actual validator.
* Only the AdGuard DNS filter is enabled.
* Query logging is disabled.
* Statistics are disabled.
* The admin UI listens only on `127.0.0.1:3000`.

## Why DNS-over-TLS and local validation

Forwarding over DoT means the only DNS leaving the region is encrypted traffic to known, certificate-authenticated resolvers. The cloud provider and any on-path observer cannot see the domains clients look up, only that encrypted DNS is occurring.

Unbound performs DNSSEC validation locally against the root trust anchor, so answer integrity rests on the DNSSEC chain itself rather than on trusting the upstream resolvers - a coerced or compromised resolver cannot feed forged data for a signed zone.

The region runs Unbound as a forward-only resolver, not a recursive one. Recursion would have to query the root, TLD, and authoritative servers over plaintext port 53 (encrypted authoritative DNS is effectively undeployed), which would expose every lookup to the provider in clear. So Unbound forwards over DoT to three independent no-log providers instead, spreading the stream so no single upstream sees all of it. Upstreams are pinned by IP with their TLS certificate name (`IP@853#name`) because Unbound has no bootstrap resolver of its own.

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
