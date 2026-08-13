# Regional Deployment Runbook

Manual fallback steps to bring up one shared regional WireGuard server and its API by hand. The normal path is automated; see [quick-deployment.md](quick-deployment.md).

Secrets hygiene: never paste WireGuard private keys, full WireGuard configs, Firebase service account credentials, or auth tokens into logs, tickets, chat, or shell history files. Reference peers by client ID or public key only.

## 1. Prepare OCI Networking

Follow the network prerequisites in [Infrastructure/OCI/README.md](../Infrastructure/OCI/README.md):

* compartment, subnet, and routed IPv6 if IPv6 VPN traffic is wanted
* ingress TCP `22` only from your approved personal `IPv4/32`
* ingress UDP `51820` from `0.0.0.0/0` and `::/0`
* ingress TCP `80`/`443` only from Cloudflare IP ranges
* egress to `0.0.0.0/0` and `::/0`

## 2. Apply Terraform

The host fetches its bootstrap script and API source from GitHub at boot using `source_repo`/`source_ref`. The ref must be pushed to GitHub before applying - see [docs/github-deployment-setup.md](github-deployment-setup.md) for the tag workflow and the fetched-path contract.

The host also downloads the prebuilt Caddy binary from the GitHub Release named by `caddy_binary_tag` and verifies it against `caddy_binary_sha256`. Publish or refresh that binary with `./scripts/caddy-release.sh` before deploying a region whose tfvars points at a new Caddy binary tag. For first-time setup, use a temporary all-zero `caddy_binary_sha256` only until the release script writes the real hash; never deploy with the zero hash.

Before applying Terraform, back up Firestore from the repo root with the API virtualenv activated:

```sh
Backend/API/.venv/bin/python3 scripts/backup_firestore.py
ls -lh Backend/Firebase/backups
```

Confirm a new `Backend/Firebase/backups/backup-<timestamp>.json` file exists before continuing. Treat backup files as secret material because they can contain full WireGuard configs and client private keys.

Each region has its own var file (`Infrastructure/OCI/terraform/<regionId>.terraform.tfvars`, gitignored),
its own Terraform workspace (isolated state), and its own `~/.oci/config` profile named in
that var file's `oci_config_profile`. Deploy through `./scripts/terraform.sh`, which selects each
workspace and var file. A bare `terraform apply` would auto-load `terraform.tfvars` and
share one state file, so a second region would plan to destroy the first.

`./scripts/terraform.sh` also runs a regional preflight before every plan, apply, and
destroy. It stops the entire deploy if Cloudflare has existing regional API/WireGuard records or OCI
has a `CloudGatewayManaged=true` VM that is not already in the selected Terraform
workspace state. It also stops on duplicates. The script reports the region and
resource IDs; manually reconcile or import the canonical resources before
rerunning.

The tracked [subnet-registry.json](../Infrastructure/OCI/terraform/subnet-registry.json) is the
authoritative inventory and boundary for the cross-region WireGuard tunnel subnet scheme. It lists
active and reserved allocations as a JSON `regions` list; keep removed allocations as `reserved`
and never reuse or overlap them. Region index N gets `10.0.N.0/24` and `fd42:42:42:N::/64`
(`us-sanjose-1` = index 0, `us-chicago-1` = index 1), inside the registry aggregates
`10.0.0.0/16` and `fd42:42:42::/48`. Every local tfvars file must match its registry entry
exactly. The registry remains authoritative when a region's local tfvars file is absent; sibling
files are only optional consistency checks. `scripts/terraform-preflight.py` uses a strict
stdlib parser for the supported tfvars scalar/list/heredoc forms and rejects malformed or duplicate
assignments, then validates the registry, selected active allocation, present tfvars, interface
prefixes, interface-derived networks, DNS/interface equality, and all active/reserved overlap
before every plan/apply/destroy. A new region is added to the
registry first with the next free allocation; see
[Infrastructure/OCI/terraform/terraform.tfvars.example](../Infrastructure/OCI/terraform/terraform.tfvars.example)
for the operator workflow. Before enabling mesh, an operator must verify and
backfill `wireguardPort` on every existing Region document. The repository cannot
prove live Firestore state, so missing-port fallback must not be removed or relied
on until that prerequisite is complete.

### Replacement, subnet changes, and destroy

A normal replacement is self-healing. Keep the same WireGuard private key, tunnel
subnets, and endpoint hostname; run `./scripts/terraform.sh <regionId> apply`, let
boot registration and sync rebuild the live peers from Firebase, and validate
`wg show` plus the API health endpoint. Existing client documents and configs stay
valid, and clients recover when WireGuard re-resolves the endpoint hostname after
a public-IP change.

A subnet change uses a hard cutoff, never address migration. Use this exact
order: disable the region's mesh membership and run **Sync All Regions**, delete
every `Regions/{regionId}/Instances/*` document without inspecting or migrating
its assigned addresses, update the authoritative registry and matching tfvars,
then run the Terraform deployment. After registration and health checks,
explicitly enable mesh and run **Sync All Regions** again. Chicago users recreate
clients. There is no mixed-version rollout and no existing live Mesh document/API
compatibility path to support.

The wrapper's registry, Terraform, and resource-ownership preflights still run
before every plan, apply, and destroy. Permanent decommission is an explicit
operator operation: remove the region from desired state and run Sync All before
permanently deleting its infrastructure. A `Mesh/{regionId}` status document
proves what a sync observed, not a WireGuard handshake; use `wg show` on the host
for live link verification.

**One-time cutover note (shared-subnet mesh):** `us-chicago-1` moves from index 0 (shared with
San Jose, the pre-mesh bug this scheme fixes) to index 1. The values below are non-operational
reference values only. Do not edit the tfvars from this note before the authoritative cutover
sequence below. Use these values only at that sequence's registry/tfvars update step, after
Chicago mesh membership is disabled, **Sync All Regions** has run, and Chicago's client docs have
been deleted:

```
wg_address_v4     = "10.0.1.1/24"
wg_network_v4     = "10.0.1.0/24"
wg_dns_address_v4 = "10.0.1.1"
wg_address_v6     = "fd42:42:42:1::1/64"
wg_network_v6     = "fd42:42:42:1::/64"
wg_dns_address_v6 = "fd42:42:42:1::1"
```

For the Chicago cutover, first disable Chicago mesh membership and run **Sync All Regions**.
Then, before the subnet deployment, delete Chicago's client docs
(`Regions/us-chicago-1/Instances/*`): their `10.0.0.x` assignments and rendered configs
(`DNS = 10.0.0.1`) are invalid under the new subnet. Next update the authoritative registry and
matching tfvars using the reference values above, then deploy. This is a hard cutoff per the mesh
design - San Jose's docs are untouched, and Chicago users recreate their clients from the
dashboard/app after the region redeploys and re-registers with its new tunnel CIDRs.

```sh
# One-time per region: copy the template and fill in real values (source ref, OCI OCIDs,
# oci_config_profile, region ID, API hostname, CORS origin, FastAPI port, WireGuard endpoint
# hostname, tunnel DNS IPs, Firebase credentials, Caddy/Cloudflare settings, WG server key).
cp Infrastructure/OCI/terraform/terraform.tfvars.example Infrastructure/OCI/terraform/<regionId>.terraform.tfvars

./scripts/terraform.sh <regionId> plan
./scripts/terraform.sh <regionId> apply

# Multi-region: one deploy tag is created and written to every listed tfvars.
./scripts/terraform.sh <regionId> <anotherRegionId> plan
./scripts/terraform.sh <regionId> <anotherRegionId> apply
```

For `apply`, the script validates all requested var files and `source_ref` lines
before side effects, saves every region's plan against the new deploy tag, performs
all required preflight checks, then creates and pushes one `Deploy v<x>` commit
plus `deploy-v<x>` tag, writes that tag into every listed `source_ref`, and
applies the saved plans one at a time. Do not enable mesh or run Sync All until all
participating regions are on that current ref; Mesh/API versions are not mixed-
version compatible. If one region fails, the script stops and already applied
regions remain deployed; fix the failed region and rerun.

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
* `cloudgateway-sync-peers.service` succeeded (an empty region is a successful empty sync; it retries until Firebase credentials work). Bootstrap runs it twice: once early at boot (client peers only) and once more at the end, after `cloudgateway-register-region`, so this region can pick up mesh peers for already-known mesh-enabled regions immediately.
* Caddy is active on `80`/`443`
* `/etc/cloudgateway/api.env` is mode `0600`, root-owned, and `CLOUDGATEWAY_REGION_ID` matches this region

If bootstrap failed, check `/var/log/wireguard-bootstrap.log`. Bootstrap status lines include a UTC timestamp and elapsed seconds since the stub or fetched bootstrap started; Terraform apply wall time also includes OCI instance provisioning before cloud-init starts. Fetch failures (ref not pushed, no egress) and recovery steps are covered in [docs/github-deployment-setup.md](github-deployment-setup.md). API updates later use `sudo cloudgateway-install-api <ref>` - no redeploy needed.

## 3. Cloudflare DNS (Terraform-managed) and one-time zone setup

The regional API hostname is `<regionId>.<origin>`, for example `us-sanjose-1.gocloudlaunch.com`.

DNS is **managed by Terraform**, not by hand. `./scripts/terraform.sh <region> apply` creates/updates two `A` records from the instance's public IPv4 (`cloudflare_record.api`, orange/proxied; `cloudflare_record.wg`, grey/DNS-only) using `cloudflare_api_token` + `cloudflare_zone_id`. They update automatically on rebuild. If a manually-created record already exists for the name, delete it or import it before the first apply; the wrapper preflight stops on unmanaged or duplicate regional records.

If the `cloudflare_api_token` has **Client IP Address Filtering** enabled, allowlist **both** the operator machine's public **IPv4 and IPv6** (`curl -4 https://ifconfig.me`, `curl -6 https://ifconfig.me`). Terraform's provider prefers IPv6 when available, so a v4-only allowlist fails every record op with `Authentication error (10000)` despite a valid token. Residential IPv6 is a rotating /64 - allowlist the `/64` prefix or leave IP filtering off.

One-time per zone (see [Infrastructure/CloudFlare/README.md](../Infrastructure/CloudFlare/README.md)):

1. SSL/TLS mode = **Full (strict)**.
2. Create a Cloudflare **Origin CA** cert for `gocloudlaunch.com, *.gocloudlaunch.com` and put it in `origin_cert` / `origin_key` (the host serves it; ACME can't validate a proxied hostname).
3. **Authenticated Origin Pulls**: turn on Global and Zone-level (upload no cert). The host trusts Cloudflare's shared client cert via the bundled origin-pull CA.

WireGuard traffic does not go through Cloudflare. Only the API hostname is proxied; clients resolve `wg.<regionId>.<origin>` directly to the server public IPv4 at tunnel-up.

## 4. Firebase region doc (self-seeded by the host)

One-time project setup: confirm any required Firestore indexes for the current schema exist (see [Backend/Firebase/indexes.md](../Backend/Firebase/indexes.md)).

The host **self-registers** `Regions/{regionId}` at the end of bootstrap via `cloudgateway-register-region`: it discovers its public IPv4, reads the server WireGuard public key and endpoint config, upserts the region metadata doc, and sets `enabled: true` only once the full Cloudflare path validates (`https://<regionId>.<origin>/api/health` hairpins through the edge: proxy + AOP + firewall + Caddy). A failing edge check leaves the region disabled and logs whether the local API was healthy (edge/firewall misconfig) or not (API failure). Registration updates only the region document and must not overwrite or delete `Regions/{regionId}/Instances`. The region-doc field values come from the tfvars (`region_display_name`, `region_display_order`, `region_capacity_limit`) plus the host's own `/etc/cloudgateway/api.env`.

If Firebase was unreachable at boot, re-run on the host: `sudo systemctl is-active cloudgateway-api` then
run the registration command through systemd so its `EnvironmentFile` parser handles `api.env`:

```sh
sudo systemd-run --quiet --pipe --wait --collect --property=WorkingDirectory=/opt/cloudgateway/api --property=EnvironmentFile=/etc/cloudgateway/api.env /opt/cloudgateway/api/.venv/bin/cloudgateway-register-region
```

The upsert is idempotent.

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
4. Confirm the client doc exists at `Regions/{regionId}/Instances/{clientId}` with the expected `ownerUid` and `status`.
5. On the host, confirm the peer appears in `sudo wg show wg0` (`/etc/wireguard/wg0.conf` stays peer-free by design).
6. Delete the client from the dashboard. Confirm the peer is gone from `wg show wg0` and the doc status is `removed`.

## 7. Verify WireGuard Connects

1. Create a client and load its config in the WireGuard app (QR or download).
2. Confirm the config endpoint is `wg.<regionId>.<origin>:51820` and that the name resolves to the server public IPv4 (grey cloud, not proxied).
3. Activate the tunnel and confirm a handshake on the host:

```sh
sudo wg show wg0 latest-handshakes
```

4. Confirm traffic and DNS resolve through the tunnel.
5. Confirm AdGuard Home is the client-facing DNS service and Unbound is the forward-only DoT backend:

```sh
systemctl status adguardhome
systemctl status unbound
```

6. Confirm a known ad/tracker test domain is blocked by the AdGuard DNS filter, then remove the test client.

The region is live. Leave `enabled: true` on the region doc.
