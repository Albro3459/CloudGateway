# AdGuard Home Configuration

The [regional bootstrap](host/bootstrap.sh) installs the pinned `adguard_home_version`
and writes its configuration. Default deployments need no manual UI setup.

## Default Configuration

* DNS listens only on the WireGuard tunnel DNS IPs.
* Upstream DNS is Unbound on `127.0.0.1:5335`.
* Unbound forwards over DNS-over-TLS (DoT) to Quad9, Mullvad, and DNS.SB and validates
  DNSSEC locally against the root trust anchor.
* AdGuard Home enables DNSSEC support, but Unbound performs validation.
* Only the AdGuard DNS filter is enabled.
* Query logging and statistics are disabled.
* The admin UI listens only on `127.0.0.1:3000`, with UI authentication disabled.

## Why DNS-over-TLS and local validation

Unbound uses certificate-authenticated DoT upstreams pinned as `IP@853#name`.
This encrypts forwarded DNS between the region and those resolvers. Upstream
resolvers still receive the queries, and DNSSEC authenticates answers only for
signed zones.

The resolver is forward-only (`forward-first: no`), so it does not fall back to
plaintext recursive queries to root, TLD, or authoritative servers. Local DNSSEC
validation checks signed answers independently of the upstream resolver.

## Optional UI Access

Open an SSH tunnel:

```sh
ssh -L 3000:127.0.0.1:3000 <regional-host>
```

Then open `http://127.0.0.1:3000` locally. SSH access is the admin boundary because
the UI has no login. Keep it bound to localhost and never expose it through Caddy
or public firewall rules.

## Operator Rules

* Keep query logging and statistics off.
* Keep the AdGuard DNS filter enabled and filtering limited to DNS filters unless
  an operator deliberately changes the scope.
* Use small allowlist entries when a real user workflow breaks.
* Record lasting configuration changes in bootstrap so a rebuild preserves them.

## Filter Changes

After changing filters or rules, check service health:

```sh
systemctl status adguardhome
journalctl -u adguardhome --since "15 minutes ago"
```

If clients have a handshake but DNS fails, check AdGuard Home, Unbound, and outbound
TCP `853` per [service operations](../../docs/service-operations.md).
Never paste DNS queries, requested domains, or user browsing details into tickets.
