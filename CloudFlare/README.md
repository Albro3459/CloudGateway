# CloudFlare

Cloudflare-side artifacts for the platform: the **Origin CA certificate** each regional
Caddy serves, and the **DNS zone records** for the domain.

Real files are gitignored; the committed `example.*` files are templates. Never commit the
real certificate, private key, or zone export.

## Why Cloudflare needs these

Each region's API is proxied (orange-cloud) at `https://<regionId>.gocloudlaunch.com`, so
Cloudflare terminates TLS at the edge and opens a second TLS hop to the origin. The zone is
set to **Full (strict)**, so the origin must present a certificate Cloudflare trusts.

A proxied hostname resolves to Cloudflare, not the host, so the origin can **never** obtain a
public cert via ACME (HTTP-01/TLS-ALPN-01 challenges never reach it). The fix is a Cloudflare
**Origin CA** certificate: Cloudflare issues it directly with no inbound challenge, and its
edge trusts it in Full (strict). The origin stays locked to Cloudflare (firewall + AOP), so
none of the edge protections (DDoS, rate limiting, WAF) are bypassed.

## Files

* `cloud-gateway.pem` (gitignored) - Cloudflare **Origin CA certificate**. The server
  cert each regional Caddy presents to Cloudflare on the origin TLS hop.
* `cloud-gateway.key` (gitignored) - the Origin CA **private key**. Secret.
* `gocloudlaunch.com.txt` (gitignored) - export/backup of the Cloudflare DNS zone records
  (BIND format).
* `example.cloud-gateway.pem` / `example.cloud-gateway.key` - committed
  placeholder cert/key.
* `example.gocloudlaunch.com.txt` - committed example of the full DNS record set (frontend
  GitHub Pages, per-region API + WireGuard records, email DKIM/SPF/DMARC).

## Generating the Origin CA certificate

Cloudflare dashboard -> **SSL/TLS -> Origin Server -> Create Certificate**:

* Hostnames: `gocloudlaunch.com, *.gocloudlaunch.com` (the wildcard covers every regional API
  host, e.g. `us-chicago-1.gocloudlaunch.com`).
* Validity: 15 years.
* Format: PEM.

Save the certificate to `cloud-gateway.pem` and the private key (shown only once) to
`cloud-gateway.key`. One cert covers all regions.

## How it reaches the hosts

The cert and key are baked into each regional deploy through the gitignored
`<regionId>.terraform.tfvars` (`origin_cert` / `origin_key`). The host bootstrap writes them to
`origin_cert_path` / `origin_key_path`, and the Caddyfile `tls` directive serves them instead
of using ACME. Replacing the cert means updating the tfvars and rebuilding (or hand-placing the
files and reloading Caddy).

## Required Cloudflare zone settings

1. **SSL/TLS -> Overview -> encryption mode = `Full (strict)`.**
2. **SSL/TLS -> Origin Server -> Origin Certificates -> Create Certificate** for
   `gocloudlaunch.com, *.gocloudlaunch.com` (PEM, 15 years). This is the server cert the host
   serves (installed via the `origin_cert` / `origin_key` tfvars) - it is **not** an AOP cert.
3. **SSL/TLS -> Origin Server -> Authenticated Origin Pulls -> turn on both Global and Zone-level.
   Do NOT upload any certificate to Zone-level.** The host trusts Cloudflare's shared client
   cert via the origin-pull CA the bootstrap installs at
   `/etc/caddy/cloudflare-origin-pull-ca.pem`.

## DNS records

See `example.gocloudlaunch.com.txt` for the full set. Summary:

* `gocloudlaunch.com` (apex) -> GitHub Pages IPs, **proxied** - hosts the React frontend.
* `<regionId>.gocloudlaunch.com` -> server public IPv4, **proxied** (orange) - regional API.
  **Terraform-managed** (`cloudflare_record.api`).
* `wg.<regionId>.gocloudlaunch.com` -> server public IPv4, **DNS-only** (grey) - WireGuard
  endpoint; never proxied (Cloudflare does not proxy WireGuard UDP). **Terraform-managed**
  (`cloudflare_record.wg`).
* Email DKIM/SPF/DMARC CNAME/TXT records for AWS SES and Firebase - managed by hand.

The two per-region `A` records are created/updated by `./scripts/terraform.sh <region> apply`
from the instance's public IP (they self-heal on rebuild), using a Cloudflare API token
with **Zone: gocloudlaunch.com -> DNS: Edit**. The token lives only on the operator
machine (`cloudflare_api_token` tfvar), never on a host. The apex/www/email records stay
manual. Before the first apply for a region, delete any pre-existing manual `<regionId>` /
`wg.<regionId>` record or import the canonical record; the wrapper preflight stops on
unmanaged or duplicate regional records before Terraform can create more DNS state.

If you enable **Client IP Address Filtering** on the token, allowlist **both** the operator
machine's public **IPv4 and IPv6** addresses. Terraform's provider connects over IPv6 when the
machine has working IPv6 (often preferred over IPv4), so a v4-only allowlist fails with
`Authentication error (10000)` even though the token and DNS permissions are correct. Get the
addresses with `curl -4 https://ifconfig.me` and `curl -6 https://ifconfig.me`; residential IPv6
is usually a rotating /64, so prefer allowlisting the `/64` prefix, or leave IP filtering off
(the token is already scoped to DNS: Edit on one zone).
