# Oracle Shared Regional WireGuard Host

Each OCI region runs one long-lived shared WireGuard host. Terraform supplies
regional configuration/secrets through cloud-init, which fetches bootstrap and
API source from a public GitHub ref.

Use [regional deployment](../../docs/regional-deployment.md) for first deployments
and host rebuilds. `./scripts/terraform.sh <region> apply` manages isolated
workspaces and regional DNS, creates/pushes a deploy release, and applies saved
plans. It requires a clean working tree and operator confirmation. Existing
unmanaged or duplicate DNS/VM resources must be reconciled or imported first.

Firebase is the source of truth for clients, desired peers, mesh membership, and
account policy. The API applies peers live with `wg set`. Boot sync restores them
from Firestore. Keep `/etc/wireguard/wg0.conf` interface-only, without `[Peer]`
blocks, and never persist peers in another host state file.

## What the Host Runs

* **WireGuard:** `wg-quick@wg0`, IPv4/IPv6 forwarding, firewall/NAT rules, and UDP
  rate limits. Client forwarding to OCI metadata `169.254.169.254` is blocked to
  protect user-data.
* **Account isolation:** `PostUp` loads `/etc/cloudgateway/cloudgateway.nft` into
  the `inet cloudgateway` table, and `PostDown` removes it. Dynamic policy starts
  empty and is populated from Firestore by reconciliation. It runs alongside
  `iptables`/`ip6tables`. See [policy repair](../../docs/wireguard-drift-repair.md#account-scoped-acl-policy-reconcile).
* **AdGuard Home:** DNS filtering on tunnel DNS IPs, forwarding to local Unbound.
  Only the AdGuard DNS filter is enabled. The admin UI is localhost-only on
  `127.0.0.1:3000`, with UI authentication disabled. Query logs/statistics stay off.
  See [AdGuard configuration](adguard-home.md).
* **Unbound:** localhost port `5335`, forward-only DoT to Quad9, Mullvad, and DNS.SB,
  with local DNSSEC validation and no plaintext recursion fallback.
* **Regional API:** root-run `cloudgateway-api.service`, installed in
  `/opt/cloudgateway/api` with its `.venv`, bound only to `127.0.0.1`. Systemd reads
  root-owned mode-`0600` `/etc/cloudgateway/api.env`, including the regional ID and
  Firebase credential-file path.
* **Peer/policy sync:** `cloudgateway-sync-peers.service` restores peers, mesh
  routes, and policy at boot. Failed passes retry every 30 seconds. Successful
  passes have no periodic timer.
* **Region registration:** `cloudgateway-register-region` upserts Firestore
  endpoint metadata at the end of bootstrap and enables the region only after
  edge health passes. A failed edge check preserves the existing enabled value.
  Regional DNS remains Terraform-managed.
* **Caddy:** a custom Linux ARM64 release with `github.com/mholt/caddy-ratelimit`,
  pinned by `caddy_binary_tag`/`caddy_binary_sha256`. It serves the Origin CA
  certificate, requires Cloudflare Authenticated Origin Pulls, accepts the
  regional API hostname and `api.gocloudlaunch.com`, rate-limits API requests,
  strips `/api`, and proxies to the loopback API port. OPTIONS preflight is
  handled separately. Logs cover API HTTP requests only.
* **Origin firewall:** `cloudgateway-origin-firewall.service` restricts public
  HTTP/HTTPS to configured Cloudflare IP ranges.

`dashboard_cors_origin` must be one exact dashboard URL, without wildcards,
patterns, or comma-separated origins. It is also the login link in access emails.
Terraform has no deploy-time client-peer inputs.

### Regional DNS records

Terraform manages the regional `A` records from the instance public IP:

* `cloudflare_record.api`: proxied `<regionId>.<origin>`.
* `cloudflare_record.wg`: DNS-only `wg.<regionId>.<origin>`.

`data.cloudflare_zone.this` checks token access during plan/refresh, before an
instance is created or replaced. If token IP filtering is enabled, its allowlist
must cover the operator's actual IPv4/IPv6 connection source.

The wrapper checks Cloudflare records and active OCI instances tagged
`CloudGatewayManaged=true` in the configured compartment/profile/region before
plan, apply, and destroy. No matches is valid for first deploy. One matching
resource must already belong to the selected workspace state. Duplicate or
unmanaged resources stop deployment. Import the canonical resources or reconcile
duplicates before retrying. These checks prevent a retry from creating more
resources around a half-failed deployment.

### Cross-region tunnel subnets

[`terraform/subnet-registry.json`](terraform/subnet-registry.json) is the tracked
allocation inventory. Each region has a unique IPv4 `/24` and IPv6 `/64` inside
the registry aggregates. Gitignored regional `wg_network_v4`/`wg_network_v6` values
must match exactly. Preflight validates these before deployment. Keep retired
allocations `reserved` so they cannot be reused.

Mesh membership is managed in Firestore through the dashboard, then applied with
**Sync All Regions**. See [mesh operations](../../docs/service-operations.md#cross-region-mesh-enable--verify--rollback).

## Network Prerequisites

Prepare OCI before applying:

* A compartment, subnet, and image compatible with the chosen shape/bootstrap.
* Routed IPv6 for IPv6 VPN egress.
* SSH TCP `22` from only your approved personal `IPv4/32`.
* WireGuard UDP `51820` from `0.0.0.0/0` and `::/0`.
* HTTP/HTTPS TCP `80`/`443` from Cloudflare IP ranges only.
* Egress for client traffic to `0.0.0.0/0` and `::/0`, including TCP `853` to DoT upstreams.

WireGuard UDP limits live in the host firewall. Caddy rate limits apply to API
HTTP requests. Size CPU/memory and `region_capacity_limit` for measured workload,
since client traffic volume determines WireGuard load.

## Files

* [terraform/cloudgateway.tf](terraform/cloudgateway.tf): inputs, providers,
  instance/user-data, and regional DNS.
* [terraform/stub-cloud-init.sh.tftpl](terraform/stub-cloud-init.sh.tftpl): writes
  deployment configuration, server key, credentials, and origin certificate/key;
  fetches the source ref into `/opt/cloudgateway/src`; runs versioned bootstrap.
* [host/bootstrap.sh](host/bootstrap.sh): installs/configures host services,
  disables SSH password/root login, and writes the API installer helper.
* [host/Caddyfile.template](host/Caddyfile.template): rendered by `envsubst` on the host.
* [caddy/](caddy/): custom binary build and release instructions.
* [terraform/backdoor-cloud-init.yaml](terraform/backdoor-cloud-init.yaml):
  emergency console user and SSH denial.
* [terraform/terraform.tfvars.example](terraform/terraform.tfvars.example): copy
  to `<regionId>.terraform.tfvars` and fill in regional settings and secrets.

Regional tfvars name the `~/.oci/config` profile with `oci_config_profile` and
pin the source/Caddy refs. Multi-region apply writes one fresh deploy tag into
all selected tfvars before sequential deployment. The Caddy release script
updates its configured regions' binary tag/hash separately.

Tfvars, Terraform state, and user-data contain secrets, including server/private
origin keys and Firebase credentials. Keep secure backups and never commit them.
Every deployable ref must contain the bootstrap, Caddy template, and API paths
in the [GitHub fetch contract](../../docs/github-deployment-setup.md#fetched-path-contract).

## WireGuard Config Shapes

* [Server example](wireguard_configs/example.wg0-server.conf): interface addresses,
  port, and firewall/NAT hooks without static peers. Bootstrap is the source for
  the complete deployed ruleset.
* [Client example](wireguard_configs/example.wg0-client.conf): client private key,
  assigned tunnel IPv4/IPv6, tunnel DNS, server public key, and DNS endpoint
  `wg.<regionId>.<origin>:51820`.

The endpoint bypasses Cloudflare. Retaining the server key, tunnel subnets, and
hostname across a rebuild lets users keep their configs and toggle the tunnel
to re-resolve the new host IP. See [VM recovery](../../docs/vm-loss-recovery.md).

## Backdoor User

The `backdoor` account is for emergency OCI console recovery. Cloud-init sets
its password hash from `hashed_password` and grants passwordless `sudo`.
`DenyUsers backdoor` and global password-auth restrictions block SSH login.

Open the instance's console/serial login flow and use the password matching the
configured hash. Keep the password and its recovery copy private.

## Local Validation

Use the Terraform version in [tool versions](../../docs/tool-versions.md).
From the repo root, the standard validation entry point is:

```sh
./scripts/test.sh infra
```

For Terraform-only syntax/schema inspection:

```sh
cd Infrastructure/OCI/terraform
terraform init
terraform validate
```

`init` downloads providers and prepares local state metadata. Run it before
validation on a clean machine or after provider changes. Keep `.terraform/`
local. These commands do not deploy a host.

## Runtime Logs

Cloud-init writes `/var/log/cloud-init-output.log`. The stub/bootstrap write
`/var/log/wireguard-bootstrap.log` with UTC timestamps and elapsed host-setup time,
which excludes OCI provisioning time.

```sh
sudo sed -n '1,240p' /var/log/wireguard-bootstrap.log
sudo tail -f /var/log/wireguard-bootstrap.log
```

Keep investigation output private. Never log traffic metadata, DNS queries,
private keys, full configs, Firebase credentials, or auth tokens. Use
[service operations](../../docs/service-operations.md) for service logs and repair commands.
