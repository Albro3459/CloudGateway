# Regional Deployment Runbook

Manual steps to bring up one shared regional WireGuard server and its API. Deployment is rare and manual; do not automate this without updating `TODO/Shared_VPN_Contract.md` first.

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
that var file's `oci_config_profile`. Deploy through `terraform-deploy.sh`, which selects the
workspace and var file for the region. A bare `terraform apply` would auto-load
`terraform.tfvars` and share one state file, so a second region would plan to destroy the first.

```sh
# One-time per region: copy the template and fill in real values (source ref, OCI OCIDs,
# oci_config_profile, region ID, API hostname, CORS origin, FastAPI port, WireGuard endpoint
# hostname, tunnel DNS IPs, Firebase credentials, Caddy/Cloudflare settings, WG server key).
cp OCI/terraform/terraform.tfvars.example OCI/terraform/<regionId>.terraform.tfvars

./terraform-deploy.sh <regionId> plan
./terraform-deploy.sh <regionId> apply
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
* `/etc/wireguard/wg0.conf` has interface settings and no `[Peer]` blocks (peers are never written to it; Firebase is the single source of truth and `cloudlaunch-sync-peers` rebuilds the live peer set at boot)
* `cloudlaunch-api.service` is active and listening only on `127.0.0.1`
* `cloudlaunch-sync-peers.service` succeeded (an empty region is a successful empty sync; it retries until Firebase credentials work)
* Caddy is active on `80`/`443`
* `/etc/cloudlaunch/api.env` is mode `0600`, root-owned, and `CLOUDLAUNCH_REGION_ID` matches this region

If bootstrap failed, check `/var/log/wireguard-bootstrap.log`. Fetch failures (ref not pushed, no egress) and recovery steps are covered in [docs/github-deployment-setup.md](github-deployment-setup.md). API updates later use `sudo cloudlaunch-install-api <ref>` - no redeploy needed.

## 3. Configure Cloudflare DNS and Origin Pulls

The regional API hostname is `<regionId>.<origin>`, for example `us-sanjose-1.gateway.gocloudlaunch.com`.

1. In the Cloudflare zone for `<origin>`, add an `A` record for `<regionId>.<origin>` pointing at the server public IPv4, with proxy enabled (orange cloud).
2. Add an `A` record for the WireGuard endpoint `wg.<regionId>.<origin>` pointing at the server public IPv4, with proxy **disabled** (grey cloud) and a low TTL (300s). This must match the `wg_endpoint_hostname` tfvar - it is the endpoint inside every client config, and it must never be proxied (Cloudflare does not proxy WireGuard UDP).
3. Enable Authenticated Origin Pulls for the zone (or per-hostname) so the origin only accepts TLS from Cloudflare. Caddy on the host requires the Cloudflare client certificate.
4. Set the zone SSL/TLS mode to Full (strict).

WireGuard traffic does not go through Cloudflare. Only the API hostname is proxied; clients resolve `wg.<regionId>.<origin>` directly to the server public IPv4 at tunnel-up.

## 4. Create/Update the Firebase Region Doc

One-time project setup: confirm the `Instances` collection group index for `regionId` exists (see [Firebase/indexes.md](../Firebase/indexes.md)). The API's create/delete transactions fail without it.

Create or update `Regions/{regionId}` in Firestore with the contract fields (see [Firebase/README.md](../Firebase/README.md)):

* `regionId`: same as the document ID
* `displayName`
* `enabled`: `true` once validation passes (keep `false` while validating)
* `wireguardEndpointIpv4`: raw server public IPv4 (operations/display)
* `wireguardEndpointIpv6`: string or `null`
* `wireguardEndpointHostname`: the grey-cloud `wg.<regionId>.<origin>` hostname used in client configs
* `wireguardPort`: `51820` by default
* `wireguardDnsIpv4` / `wireguardDnsIpv6`: server tunnel DNS IPs
* `wireguardPublicKey`: server WireGuard public key
* `capacityLimit`: start with 15-25
* `userClientLimit`: per-normal-user client cap for this region; defaults to `3` if omitted
* `activeClientCount`: `0` for a new host
* `displayOrder`: optional; missing sorts as `1000`
* `healthStatus`: optional
* `updatedAt`: Firestore timestamp

These values must match the host's `/etc/cloudlaunch/api.env` (`CLOUDLAUNCH_REGION_ID`, `CLOUDLAUNCH_WG_ENDPOINT_HOSTNAME`, `CLOUDLAUNCH_WG_PORT`, `CLOUDLAUNCH_WG_DNS_IPV4`, `CLOUDLAUNCH_WG_DNS_IPV6`, `CLOUDLAUNCH_WG_SERVER_PUBLIC_KEY`).

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
