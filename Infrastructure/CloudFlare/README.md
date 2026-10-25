# Cloudflare

This directory holds Origin CA certificate templates and example DNS records.
Real certificates, private keys, and zone exports are gitignored. Never commit
or share the real private key, Terraform state, or secret tfvars.

## Why Cloudflare needs these

Cloudflare proxies the regional API at `https://<regionId>.gocloudlaunch.com`.
It terminates edge TLS and connects to Caddy over a second TLS connection.
**Full (strict)** requires a trusted origin certificate. This deployment uses a
Cloudflare Origin CA certificate installed explicitly in Caddy, with no ACME flow.

Keep origins restricted to Cloudflare IPs and require Authenticated Origin Pulls
(AOP). The Origin CA certificate authenticates the server to Cloudflare. The
separate origin-pull CA lets Caddy authenticate Cloudflare's client certificate.

## Files

* `cloud-gateway.pem`: gitignored Origin CA server certificate.
* `cloud-gateway.key`: gitignored private key. Treat it as a secret.
* `gocloudlaunch.com.txt`: gitignored BIND-format zone export/backup.
* `example.cloud-gateway.pem` / `example.cloud-gateway.key`: committed placeholders.
* `example.gocloudlaunch.com.txt`: example frontend, API, WireGuard, and email records.

## Generating the Origin CA certificate

In Cloudflare **SSL/TLS -> Origin Server**, create an Origin CA certificate:

* Hostnames: `gocloudlaunch.com` and `*.gocloudlaunch.com`. The wildcard covers
  `api.gocloudlaunch.com` and single-label regional API hostnames.
* Format: PEM.
* Validity: the deployment convention is 15 years. Track expiry for renewal.

Save the certificate and private key as the gitignored files above. The private
key is shown only once. One certificate can cover all current regional API hosts.

## How it reaches the hosts

Each regional tfvars supplies `origin_cert`/`origin_key`. The cloud-init stub writes
`origin_cert_path`/`origin_key_path`, and Caddy serves them with its `tls` directive.

For rotation, update every region's private tfvars. Either plan a rebuild or
replace the files securely on each host, preserve private-key permissions,
validate the Caddy config, and reload Caddy. A live file replacement alone does
not update recovery inputs. Do not run Terraform merely to refresh user-data
values, since those changes replace the host.

## Required Cloudflare zone settings

1. Set TLS encryption mode to **Full (strict)**.
2. Create and install the Origin CA server certificate above.
3. Enable Authenticated Origin Pulls for the zone using Cloudflare's shared client
   certificate, without uploading a custom zone certificate. Bootstrap installs
   its trusted CA at `/etc/caddy/cloudflare-origin-pull-ca.pem` by default.
4. Keep OCI and host HTTP/HTTPS ingress restricted to configured Cloudflare ranges.

Validate health through Cloudflare and confirm direct-origin access is rejected
per [regional deployment](../../docs/regional-deployment.md#5-validate-apihealth-through-cloudflare).

## Dashboard anti-framing rule

The dashboard is served by GitHub Pages through Cloudflare. Device authorization
requires a **Response Header Transform Rule** on its whole hostname. Create a
rule named `Block dashboard framing`, using this production expression or the
matching staging hostname:

```text
http.host eq "gocloudlaunch.com"
```

Add these response header operations:

| Operation | Header | Value |
| --- | --- | --- |
| Add static | `Content-Security-Policy` | `frame-ancestors 'none'` |
| Set static | `X-Frame-Options` | `DENY` |

Append the CSP header to preserve any existing CSP headers. Set
`X-Frame-Options` to replace an existing value or add it if absent. Enable the
rule, then check the dashboard HTML response in browser DevTools and confirm an
iframe is blocked. See the [Cloudflare rule instructions](https://developers.cloudflare.com/rules/transform/response-header-modification/create-dashboard/).

The `/#/auth/code` fragment never reaches the server, so a `/auth/code` path rule
does not cover it. API Caddy headers do not affect dashboard HTML, and CSP meta
tags cannot enforce `frame-ancestors`. The approval page also refuses frames
before mounting its auth flow.

## DNS records

The [example zone](example.gocloudlaunch.com.txt) includes:

* Apex `gocloudlaunch.com`: proxied GitHub Pages IPs for the dashboard.
* `api.gocloudlaunch.com`: manually managed proxied CNAME to
  `us-sanjose-1.gocloudlaunch.com` for the global API, including `/api/regions`
  and `/api/auth/check-access`.
* `<regionId>.gocloudlaunch.com`: proxied regional API `A` record, Terraform-managed
  as `cloudflare_record.api`.
* `wg.<regionId>.gocloudlaunch.com`: DNS-only WireGuard `A` record, Terraform-managed
  as `cloudflare_record.wg`. Never proxy WireGuard UDP through Cloudflare.
* SES/Firebase email DKIM, SPF, and DMARC records: manually managed.

Apply an API rate-limit rule to the deployed API hostnames, for example:

```text
(
  http.host eq "api.gocloudlaunch.com"
  or http.host eq "us-sanjose-1.gocloudlaunch.com"
  or http.host eq "us-chicago-1.gocloudlaunch.com"
)
and starts_with(http.request.uri.path, "/api/")
```

`./scripts/terraform.sh <region> apply` updates regional records to the instance
IP. The zone-scoped DNS-edit token stays on the operator machine in
`cloudflare_api_token`, not on the regional host. Before first apply, import a
canonical pre-existing record or deliberately reconcile it. Preflight blocks
unmanaged or duplicate records.

If token client-IP filtering is enabled, allow the operator's actual IPv4 and
IPv6 source addresses as applicable. A provider connection over IPv6 is not
covered by an IPv4 allowlist and can return `Authentication error (10000)` despite
valid DNS permissions. Account for changing source addresses when maintaining
the allowlist. A zone lookup during plan/refresh checks token access before
instance creation or replacement.
