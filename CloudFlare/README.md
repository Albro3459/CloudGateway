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

* `cloud-launch-gateway.pem` (gitignored) — Cloudflare **Origin CA certificate**. The server
  cert each regional Caddy presents to Cloudflare on the origin TLS hop.
* `cloud-launch-gateway.key` (gitignored) — the Origin CA **private key**. Secret.
* `gocloudlaunch.com.txt` (gitignored) — export/backup of the Cloudflare DNS zone records
  (BIND format).
* `example.cloud-launch-gateway.pem` / `example.cloud-launch-gateway.key` — committed
  placeholder cert/key.
* `example.gocloudlaunch.com.txt` — committed example of the full DNS record set (frontend
  GitHub Pages, per-region API + WireGuard records, email DKIM/SPF/DMARC).

## Generating the Origin CA certificate

Cloudflare dashboard → **SSL/TLS → Origin Server → Create Certificate**:

* Hostnames: `gocloudlaunch.com, *.gocloudlaunch.com` (the wildcard covers every regional API
  host, e.g. `us-chicago-1.gocloudlaunch.com`).
* Validity: 15 years.
* Format: PEM.

Save the certificate to `cloud-launch-gateway.pem` and the private key (shown only once) to
`cloud-launch-gateway.key`. One cert covers all regions.

## How it reaches the hosts

The cert and key are baked into each regional deploy through the gitignored
`<regionId>.terraform.tfvars` (`origin_cert` / `origin_key`). The host bootstrap writes them to
`origin_cert_path` / `origin_key_path`, and the Caddyfile `tls` directive serves them instead
of using ACME. Replacing the cert means updating the tfvars and rebuilding (or hand-placing the
files and reloading Caddy).

## Authenticated Origin Pulls (do not confuse with the Origin cert)

AOP is the **opposite direction** — Cloudflare presenting a client cert to the origin so the
origin can confirm the request came from Cloudflare.

* Leave AOP on **Global = Enabled** (Cloudflare's shared client cert).
* The host trusts it via the origin-pull CA the bootstrap downloads to
  `/etc/caddy/cloudflare-origin-pull-ca.pem`; the Caddyfile `client_auth.trusted_ca_cert_file`
  points at it.
* Do **not** switch to zone-level/per-hostname AOP and do **not** upload the Origin cert there.
  The Origin cert is a server cert, not a client cert, and zone-level AOP would require trusting
  a different CA.

## DNS records

See `example.gocloudlaunch.com.txt` for the full set. Summary:

* `gocloudlaunch.com` (apex) → GitHub Pages IPs, **proxied** — hosts the React frontend.
* `<regionId>.gocloudlaunch.com` → server public IPv4, **proxied** (orange) — regional API.
* `wg.<regionId>.gocloudlaunch.com` → server public IPv4, **DNS-only** (grey) — WireGuard
  endpoint; never proxied (Cloudflare does not proxy WireGuard UDP).
* Email DKIM/SPF/DMARC CNAME/TXT records for AWS SES and Firebase.
