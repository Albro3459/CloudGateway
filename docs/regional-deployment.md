# Regional Deployment Runbook

Use this guide for first deployments and planned host rebuilds. The shorter
operator checklist is [quick deployment](quick-deployment.md). API-only upgrades
use [the host installer](github-deployment-setup.md#updating-a-live-regions-api).
Mesh membership changes use [Sync All Regions](service-operations.md#cross-region-mesh-enable--verify--rollback).

Never paste private keys, full WireGuard configs, Firebase credentials, or auth
tokens into logs, tickets, chat, or shell history. Keep tfvars, Terraform state,
and Firestore backups private.

## 1. Prepare OCI Networking

Follow the [OCI prerequisites](../Infrastructure/OCI/README.md#network-prerequisites):

* Prepare the compartment, subnet, compatible image, and routed IPv6.
* Allow SSH TCP `22` only from your approved personal `IPv4/32`.
* Allow WireGuard UDP `51820` from `0.0.0.0/0` and `::/0`.
* Allow HTTP/HTTPS TCP `80`/`443` only from Cloudflare IP ranges.
* Allow VPN egress to `0.0.0.0/0` and `::/0`.

## 2. Apply Terraform

Bootstrap and API source must be available publicly on GitHub. See the
[fetched-path contract](github-deployment-setup.md#fetched-path-contract).
Hosts also download the pinned `caddy_binary_tag` release asset and verify
`caddy_binary_sha256`. If a new binary is needed, follow the
[Caddy release guide](../Infrastructure/OCI/caddy/README.md). An all-zero hash is
only a temporary first-setup placeholder until the release script writes the
real hash. Never deploy it.

Before applying, create a Firestore backup from the repo root:

```sh
Backend/API/.venv/bin/python3 scripts/backup_firestore.py
ls -lh Backend/Firebase/backups
```

The script uses `Backend/Firebase/Secrets/firebase-credentials.json`. Confirm a
new `backup-<timestamp>.json` exists. Backups can contain full client configs and
private keys. Preserve the server key and regional tfvars/state separately so
[host recovery](vm-loss-recovery.md) can retain existing clients.

Each region has a gitignored
`Infrastructure/OCI/terraform/<regionId>.terraform.tfvars`, isolated Terraform
workspace, and `~/.oci/config` profile named by `oci_config_profile`. Use the
wrapper to select these. A bare `terraform apply` can use the wrong variable
file or shared state and replace another region.

Register each region's unique IPv4 `/24` and IPv6 `/64` in
[subnet-registry.json](../Infrastructure/OCI/terraform/subnet-registry.json).
Local `wg_network_v4`/`wg_network_v6` must match exactly. Keep retired allocations
reserved. Preflight checks allocation validity and ownership of matching
Cloudflare records and tagged OCI instances. Reconcile duplicates or import
canonical unmanaged resources before rerunning.

```sh
# Copy once per region, then fill in regional settings and secrets
cp Infrastructure/OCI/terraform/terraform.tfvars.example Infrastructure/OCI/terraform/<regionId>.terraform.tfvars

./scripts/terraform.sh <regionId> plan
./scripts/terraform.sh <regionId> apply

# One deploy release across multiple regions
./scripts/terraform.sh <regionId> <anotherRegionId> plan
./scripts/terraform.sh <regionId> <anotherRegionId> apply
```

**Apply creates and pushes a release.** It requires a clean working tree, fetches
tags, prepares every region's saved plan using the next deploy tag, and checks
preflight before confirmation. On confirmation it bumps the API version,
commits and pushes the current branch, creates/pushes the tag, updates all
selected tfvars, then applies the saved plans sequentially. It replaces the
configured `source_ref` with that new tag. A separate `plan` command uses the
current tfvars and publishes nothing. Review the final apply plans.

If one apply fails, earlier regions stay deployed. Fix the failed region and
review plans before rerunning. Another wrapper apply creates another deploy
release. After all intended regions are ready, run **Sync All Regions**.

The OCI profile must exist, for example:

```ini
[us-chicago-1]
user=ocid1.user.oc1..<region user OCID>
fingerprint=<api key fingerprint>
tenancy=ocid1.tenancy.oc1..<region tenancy OCID>
region=us-chicago-1
key_file=~/.oci/us-chicago-1.pem
```

After cloud-init finishes, check:

* `sudo wg show wg0` succeeds. Its config is interface-only, without `[Peer]` blocks.
* The API is active and loopback-only. `api.env` is root-owned, mode `0600`, and
  has the correct `CLOUDGATEWAY_REGION_ID`.
* Caddy and the origin firewall are active.
* Peer and policy sync succeeded. Bootstrap starts the sync unit before
  registration and again after successful edge readiness. A pre-existing enabled
  region can restore mesh on the first pass. A new region begins with no peers.
  Missing/disabled region docs produce an empty desired peer set.

Failures appear in `/var/log/wireguard-bootstrap.log`. Status timestamps measure
stub/bootstrap time, excluding OCI provisioning. See
[fetch recovery](github-deployment-setup.md#troubleshooting-fetch-failures) and
[service operations](service-operations.md) for retries and exit codes.

Host-level ACL changes require the nftables table loaded by interface `PostUp`.
The API installer rejects ACL-aware source if that live table is missing.
Re-running bootstrap on an active interface does not run `PostUp`. The initial
ACL migration requires rebuilding every region from one deploy tag, with only
partial enforcement until all regions finish. Later API-only upgrades on
properly provisioned hosts use the installer.

## 3. Cloudflare DNS (Terraform-managed) and one-time zone setup

Terraform manages the regional API and WireGuard `A` records, following instance
IP changes automatically:

* `<regionId>.<origin>`: proxied API (`cloudflare_record.api`).
* `wg.<regionId>.<origin>`: DNS-only WireGuard (`cloudflare_record.wg`).

Use a zone-scoped DNS-edit token in the local tfvars. If its client-IP filter is
enabled, allow the operator's actual IPv4 and IPv6 source addresses as applicable.
An allowed IPv4 alone does not cover an IPv6 connection. Reconcile/import
pre-existing manual records before the first apply. Keep the global API alias,
frontend, and email records manually managed.

Complete the [Cloudflare setup](../Infrastructure/CloudFlare/README.md):

1. Use **Full (strict)** TLS.
2. Put the Origin CA certificate/key covering the regional/global API hostnames
   in `origin_cert`/`origin_key`.
3. Enable Authenticated Origin Pulls using Cloudflare's shared client certificate.
   The host trusts the configured origin-pull CA. This is separate from the
   Origin CA server certificate.

WireGuard UDP bypasses Cloudflare. Clients resolve its DNS-only endpoint at tunnel-up.

## 4. Firebase region doc (self-seeded by the host)

Complete [Firestore project/index setup](../Backend/Firebase/indexes.md) first.
At the end of bootstrap, `cloudgateway-register-region` upserts
`Regions/{regionId}` from the host's public IPv4, server public key, endpoint,
tunnel networks, and configured display/capacity settings. It preserves the
`Instances` subcollection.

Registration sets `enabled: true` only after
`https://<regionId>.<origin>/api/health` succeeds through Cloudflare. Edge failure
returns `2`, preserves an existing enabled value, and leaves a new region disabled.
Logs distinguish a healthy local API from an API startup failure.

If Firebase or the edge was unavailable at boot, fix it, confirm the API is
active, and rerun registration through systemd so it parses `api.env` correctly:

```sh
sudo systemctl is-active cloudgateway-api
sudo systemd-run --quiet --pipe --wait --collect --property=WorkingDirectory=/opt/cloudgateway/api --property=EnvironmentFile=/etc/cloudgateway/api.env /opt/cloudgateway/api/.venv/bin/cloudgateway-register-region
```

Registration is idempotent. Confirm it succeeded before restoring peers and policy:

```sh
sudo systemctl start cloudgateway-sync-peers.service
sudo systemctl status cloudgateway-sync-peers.service
```

A still-disabled region has no desired peers, so sync removes its live peers.

## 5. Validate `/api/health` Through Cloudflare

```sh
curl -s https://<regionId>.<origin>/api/health
```

Expected:

```json
{ "status": "ok", "regionId": "<regionId>" }
```

Check that direct-origin access is blocked:

```sh
curl -sk --resolve <regionId>.<origin>:443:<server-public-ipv4> https://<regionId>.<origin>/api/health
```

This must fail or be rejected. If it returns a healthy response, fix the
firewall/Caddy configuration before enabling or releasing the region.

## 6. Create and Delete a Test Client from the Dashboard

1. Confirm registration enabled the region after successful edge health.
2. Sign in, select the region, and create a client with a display name.
3. Confirm `active` status, assigned tunnel IPv4/IPv6, and endpoint
   `wg.<regionId>.<origin>:51820`.
4. Verify the expected `ownerUid` and `status` at
   `Regions/{regionId}/Instances/{clientId}` through trusted admin access.
5. Confirm its peer appears in `sudo wg show wg0`, while the config stays peer-free.
6. Delete the client and confirm the peer disappears and the document becomes `removed`.

## 7. Verify WireGuard Connects

1. Create a test client and select it in the CloudGateway macOS or iOS app.
   Mac users can also use the [CLI](../Frontend/Apple/macOS/README.md#command-line-tool).
2. Confirm the DNS-only endpoint resolves to the host's public IPv4.
3. Connect from the app or run `cloudgateway up '<client-uuid>'` on Mac.
4. Check `sudo wg show wg0 latest-handshakes`, tunnel traffic, and DNS resolution.
5. Confirm `systemctl status adguardhome` and `systemctl status unbound` are healthy.
   Verify the configured ad filter blocks a known test domain without recording
   user DNS queries.
6. Remove the test client after validation.

## Device authorization rollout

Back up Firestore and deploy Firebase rules and TTL policies before the API and
dashboard. Host configuration must include the updated Caddy template and
Uvicorn `--no-proxy-headers`. An API-only install does not update those files.
Caddy replaces `X-CloudGateway-Client-IP` using Cloudflare's client IP, and the
API stays loopback-only. Follow the [device authorization runbook](device-auth.md)
for staging, production validation, and rollback, including dashboard anti-framing.
