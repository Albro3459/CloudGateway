# Regional Deployment Runbook

Manual fallback steps to bring up one shared regional WireGuard server and its API by hand. The normal path is automated; see [quick-deployment.md](quick-deployment.md).

Secrets hygiene: never paste WireGuard private keys, full WireGuard configs, Firebase service account credentials, or auth tokens into logs, tickets, chat, or shell history files. Reference peers by client ID or public key only.

## 1. Prepare OCI Networking

Follow the network prerequisites in [OCI/README.md](../OCI/README.md):

* compartment, subnet, and routed IPv6 if IPv6 VPN traffic is wanted
* ingress TCP `22` only from your approved personal `IPv4/32`
* ingress UDP `51820` from `0.0.0.0/0` and `::/0`
* ingress TCP `80`/`443` only from Cloudflare IP ranges
* egress to `0.0.0.0/0` and `::/0`

## 2. Apply Terraform

The host fetches its bootstrap script and API source from GitHub at boot using `source_repo`/`source_ref`. The ref must be pushed to GitHub before applying - see [docs/github-deployment-setup.md](github-deployment-setup.md) for the tag workflow and the fetched-path contract.

Each region has its own var file (`OCI/terraform/<regionId>.terraform.tfvars`, gitignored),
its own Terraform workspace (isolated state), and its own `~/.oci/config` profile named in
that var file's `oci_config_profile`. Deploy through `terraform.sh`, which selects the
workspace and var file for the region. A bare `terraform apply` would auto-load
`terraform.tfvars` and share one state file, so a second region would plan to destroy the first.

```sh
# One-time per region: copy the template and fill in real values (source ref, OCI OCIDs,
# oci_config_profile, region ID, API hostname, CORS origin, FastAPI port, WireGuard endpoint
# hostname, tunnel DNS IPs, Firebase credentials, Caddy/Cloudflare settings, WG server key).
cp OCI/terraform/terraform.tfvars.example OCI/terraform/<regionId>.terraform.tfvars

./terraform.sh <regionId> plan
./terraform.sh <regionId> apply
```

The matching OCI profile must exist in `~/.oci/config`, for example:

```ini
[us-chicago-1]
user=ocid1.user.oc1..<region user OCID>
fingerprint=<api key fingerprint>
tenancy=ocid1.tenancy.oc1..<region tenancy OCID>
region=us-chicago-1
key_file=~/.oci/us-chicago-1.pem
```

Record the instance's public IPv4. After cloud-init finishes, confirm on the host:

* `wg0` is up: `sudo wg show wg0`
* `/etc/wireguard/wg0.conf` has interface settings and no `[Peer]` blocks (peers are never written to it; Firebase is the single source of truth and `cloudgateway-sync-peers` rebuilds the live peer set at boot)
* `cloudgateway-api.service` is active and listening only on `127.0.0.1`
* `cloudgateway-sync-peers.service` succeeded (an empty region is a successful empty sync; it retries until Firebase credentials work)
* Caddy is active on `80`/`443`
* `/etc/cloudgateway/api.env` is mode `0600`, root-owned, and `CLOUDGATEWAY_REGION_ID` matches this region

If bootstrap failed, check `/var/log/wireguard-bootstrap.log`. Fetch failures (ref not pushed, no egress) and recovery steps are covered in [docs/github-deployment-setup.md](github-deployment-setup.md). API updates later use `sudo cloudgateway-install-api <ref>` - no redeploy needed.

## 3. Cloudflare DNS (Terraform-managed) and one-time zone setup

The regional API hostname is `<regionId>.<origin>`, for example `us-sanjose-1.gocloudlaunch.com`.

DNS is **managed by Terraform**, not by hand. `terraform apply` creates/updates two `A` records from the instance's public IPv4 (`cloudflare_record.api`, orange/proxied; `cloudflare_record.wg`, grey/DNS-only) using `cloudflare_api_token` + `cloudflare_zone_id`. They update automatically on rebuild. If a manually-created record already exists for the name, delete it (or `terraform import` it) before the first apply, or the create conflicts.

If the `cloudflare_api_token` has **Client IP Address Filtering** enabled, allowlist **both** the operator machine's public **IPv4 and IPv6** (`curl -4 https://ifconfig.me`, `curl -6 https://ifconfig.me`). Terraform's provider prefers IPv6 when available, so a v4-only allowlist fails every record op with `Authentication error (10000)` despite a valid token. Residential IPv6 is a rotating /64 - allowlist the `/64` prefix or leave IP filtering off.

One-time per zone (see [CloudFlare/README.md](../CloudFlare/README.md)):

1. SSL/TLS mode = **Full (strict)**.
2. Create a Cloudflare **Origin CA** cert for `gocloudlaunch.com, *.gocloudlaunch.com` and put it in `origin_cert` / `origin_key` (the host serves it; ACME can't validate a proxied hostname).
3. **Authenticated Origin Pulls**: turn on Global and Zone-level (upload no cert). The host trusts Cloudflare's shared client cert via the bundled origin-pull CA.

WireGuard traffic does not go through Cloudflare. Only the API hostname is proxied; clients resolve `wg.<regionId>.<origin>` directly to the server public IPv4 at tunnel-up.

## 4. Firebase region doc (self-seeded by the host)

One-time project setup: confirm the `Instances` collection group index for `regionId` exists (see [Firebase/indexes.md](../Firebase/indexes.md)). The API's create/delete transactions fail without it.

The host **self-registers** `Regions/{regionId}` at the end of bootstrap via `cloudgateway-register-region`: it discovers its public IPv4, reads the server WireGuard public key and endpoint config, upserts the doc, and sets `enabled: true` only once the full Cloudflare path validates (`https://<regionId>.<origin>/api/health` hairpins through the edge: proxy + AOP + firewall + Caddy). A failing edge check leaves the region disabled and logs whether the local API was healthy (edge/firewall misconfig) or not (API failure). `activeClientCount` is preserved on update (0 on first insert) and never reset. The region-doc field values come from the tfvars (`region_display_name`, `region_display_order`, `region_capacity_limit`, `region_user_client_limit`) plus the host's own `/etc/cloudgateway/api.env`.

If Firebase was unreachable at boot, re-run on the host: `sudo systemctl is-active cloudgateway-api` then
`( set -a; source /etc/cloudgateway/api.env; set +a; /opt/cloudgateway/api/.venv/bin/cloudgateway-register-region )`. The upsert is idempotent.

## 5. Validate `/api/health` Through Cloudflare

```sh
curl -s https://<regionId>.<origin>/api/health
```

Expected:

```json
{ "status": "ok", "regionId": "<regionId>" }
```

Also verify direct origin access fails (Authenticated Origin Pulls plus Host/SNI allowlist plus Cloudflare-only firewall):

```sh
curl -sk --resolve <regionId>.<origin>:443:<server-public-ipv4> https://<regionId>.<origin>/api/health
```

This must be rejected. If it returns a healthy response, the origin is reachable without Cloudflare; stop and fix the firewall/Caddy configuration before enabling the region.

## 6. Create and Delete a Test Client from the Dashboard

1. Set `enabled: true` on the region doc so the dashboard shows the region.
2. Log in to the dashboard, select the new region tab, and create a client with an optional display name.
3. Confirm the response shows status `active`, assigned tunnel IPv4/IPv6, and a config whose `Endpoint` is `wg.<regionId>.<origin>:51820`.
4. Confirm the client doc exists at `Users/{uid}/Regions/{regionId}/Instances/{clientId}` and `activeClientCount` incremented.
5. On the host, confirm the peer appears in `sudo wg show wg0` (`/etc/wireguard/wg0.conf` stays peer-free by design).
6. Delete the client from the dashboard. Confirm the peer is gone from `wg show wg0`, the doc status is `removed`, and the counter decremented.

## 7. Verify WireGuard Connects

1. Create a client and load its config in the WireGuard app (QR or download).
2. Confirm the config endpoint is `wg.<regionId>.<origin>:51820` and that the name resolves to the server public IPv4 (grey cloud, not proxied).
3. Activate the tunnel and confirm a handshake on the host:

```sh
sudo wg show wg0 latest-handshakes
```

4. Confirm traffic and DNS resolve through the tunnel.
5. Confirm AdGuard Home is the client-facing DNS service and Unbound is the recursive backend:

```sh
systemctl status adguardhome
systemctl status unbound
```

6. Confirm a known ad/tracker test domain is blocked by the AdGuard DNS filter, then remove the test client.

The region is live. Leave `enabled: true` on the region doc.
