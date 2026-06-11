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

```sh
cd OCI/terraform
cp terraform.tfvars.example terraform.tfvars
# fill in real values for this region (source ref, region ID, API hostname,
# CORS origin, FastAPI port, WireGuard endpoint IPv4, tunnel DNS IPs,
# Firebase credentials, Caddy/Cloudflare settings)
terraform init
terraform validate
terraform plan
terraform apply
```

Record the instance's public IPv4. After cloud-init finishes, confirm on the host:

* `wg0` is up with no peers: `sudo wg show wg0`
* `/etc/wireguard/wg0.conf` has interface settings and no `[Peer]` blocks
* `cloudlaunch-api.service` is active and listening only on `127.0.0.1`
* Caddy is active on `80`/`443`
* `/etc/cloudlaunch/api.env` is mode `0600`, root-owned, and `CLOUDLAUNCH_REGION_ID` matches this region

If bootstrap failed, check `/var/log/wireguard-bootstrap.log`. Fetch failures (ref not pushed, no egress) and recovery steps are covered in [docs/github-deployment-setup.md](github-deployment-setup.md). API updates later use `sudo cloudlaunch-install-api <ref>` - no redeploy needed.

## 3. Configure Cloudflare DNS and Origin Pulls

The regional API hostname is `<regionId>.<origin>`, for example `us-sanjose-1.gateway.gocloudlaunch.com`.

1. In the Cloudflare zone for `<origin>`, add an `A` record for `<regionId>.<origin>` pointing at the server public IPv4, with proxy enabled (orange cloud).
2. Enable Authenticated Origin Pulls for the zone (or per-hostname) so the origin only accepts TLS from Cloudflare. Caddy on the host requires the Cloudflare client certificate.
3. Set the zone SSL/TLS mode to Full (strict).

WireGuard traffic does not go through Cloudflare. Only the API hostname is proxied; clients connect to the raw server public IPv4.

## 4. Create/Update the Firebase Region Doc

One-time project setup: confirm the `Instances` collection group index for `regionId` exists (see [docs/firebase-schema.md](firebase-schema.md), "Required Indexes"). The API's create/delete transactions fail without it.

Create or update `Regions/{regionId}` in Firestore with the contract fields (see [docs/firebase-schema.md](firebase-schema.md)):

* `regionId`: same as the document ID
* `displayName`
* `enabled`: `true` once validation passes (keep `false` while validating)
* `wireguardEndpointIpv4`: raw server public IPv4
* `wireguardEndpointIpv6`: string or `null`
* `wireguardPort`: `51820` by default
* `wireguardDnsIpv4` / `wireguardDnsIpv6`: server tunnel DNS IPs
* `wireguardPublicKey`: server WireGuard public key
* `capacityLimit`: start with 15-25
* `activeClientCount`: `0` for a new host
* `displayOrder`: optional; missing sorts as `1000`
* `healthStatus`: optional
* `updatedAt`: Firestore timestamp

These values must match the host's `/etc/cloudlaunch/api.env` (`CLOUDLAUNCH_REGION_ID`, `CLOUDLAUNCH_WG_ENDPOINT_IPV4`, `CLOUDLAUNCH_WG_PORT`, `CLOUDLAUNCH_WG_DNS_IPV4`, `CLOUDLAUNCH_WG_DNS_IPV6`, `CLOUDLAUNCH_WG_SERVER_PUBLIC_KEY`).

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
3. Confirm the response shows status `active`, assigned tunnel IPv4/IPv6, and a config whose `Endpoint` is the raw server public IPv4.
4. Confirm the client doc exists at `Users/{uid}/Regions/{regionId}/Instances/{clientId}` and `activeClientCount` incremented.
5. On the host, confirm the peer appears in `sudo wg show wg0` and in `/etc/wireguard/wg0.conf`.
6. Delete the client from the dashboard. Confirm the peer is gone from `wg show wg0` and `wg0.conf`, the doc status is `removed`, and the counter decremented.

## 7. Verify WireGuard Connects

1. Create a client and load its config in the WireGuard app (QR or download).
2. Confirm the config endpoint is `<server public IPv4>:51820`, not a Cloudflare hostname.
3. Activate the tunnel and confirm a handshake on the host:

```sh
sudo wg show wg0 latest-handshakes
```

4. Confirm traffic and DNS resolve through the tunnel, then remove the test client.

The region is live. Leave `enabled: true` on the region doc.
