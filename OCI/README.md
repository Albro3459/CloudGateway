# Oracle Shared Regional WireGuard Host

This folder contains the Oracle Cloud Infrastructure Terraform package used to launch one long-lived shared WireGuard server per OCI region, bootstrapped with cloud-init.

CloudGateway uses this model:

```text
1 OCI region = 1 long-lived shared WireGuard server
```

Deployment is rare and manual. An operator prepares OCI networking, then deploys
or rebuilds a region through `./scripts/terraform.sh <region> apply` following
[docs/regional-deployment.md](../docs/regional-deployment.md). The wrapper
manages Terraform workspaces and regional DNS; unmanaged or duplicate regional
DNS/VM resources must be reconciled or imported before rerunning. There is no
Lambda orchestrator, no OCI Resource Manager flow, and no per-user stack
deployment.

WireGuard peers are never created at deploy time and are never saved to `/etc/wireguard/wg0.conf` or any other host state file. Firebase is the single source of truth: the regional FastAPI control plane applies peers live with `wg set`, and `cloudgateway-sync-peers` rebuilds the live peer set from Firebase on every boot.

## What the Host Runs

Cloud-init is a small stub: Terraform bakes only the per-region config and secrets into user-data, and the stub fetches the versioned bootstrap script and API source from GitHub at `source_repo`/`source_ref` before running it. Any deployable ref must contain `OCI/host/bootstrap.sh`, `OCI/host/Caddyfile.template`, and `API/` - see [docs/github-deployment-setup.md](../docs/github-deployment-setup.md).

The fetched bootstrap installs and configures:

* WireGuard bare metal with `/etc/wireguard/wg0.conf` written once with interface settings only (<b>never any `[Peer]` blocks</b>), started through `wg-quick@wg0`. The `cloudgateway-sync-peers.service` oneshot rebuilds the live peer set from Firebase at boot and retries until Firebase is reachable.
* IPv4/IPv6 forwarding, firewall/NAT rules, and WireGuard UDP `iptables`/`ip6tables` rate limits.
* AdGuard Home DNS filtering for VPN clients, listening only on the tunnel DNS IPs and forwarding to Unbound.
* Unbound recursive DNS on localhost as the AdGuard Home upstream resolver.
* Python runtime and the regional FastAPI app per [docs/deployment-handoff.md](../docs/deployment-handoff.md):
  * install directory `/opt/cloudgateway/api` with venv `/opt/cloudgateway/api/.venv`, installed from the fetched `API/` source
  * systemd service `cloudgateway-api.service`, running as root, bound only to `127.0.0.1`
  * environment file `/etc/cloudgateway/api.env` (mode `0600`, root-owned) with the `CLOUDGATEWAY_*` variables, including `CLOUDGATEWAY_REGION_ID`
  * Firebase Admin credentials file referenced by `CLOUDGATEWAY_FIREBASE_CREDENTIALS_FILE`
  * `cloudgateway-install-api [ref]` helper for rolling the API to a new pushed ref without redeploying
  * `cloudgateway-register-region` runs once at the end of bootstrap to self-seed the Firestore region doc (IP, server public key, endpoint), enabling the region only once the full Cloudflare path validates (health checked through the edge, not just loopback). Regional DNS `A` records are managed by Terraform (`cloudflare_record.api`/`.wg`), not by the host.
* Custom Caddy binary built with `github.com/mholt/caddy-ratelimit`, listening on public `80`/`443`:
  * serves the Cloudflare Origin CA certificate (`origin_cert`/`origin_key`) on the origin TLS hop - ACME cannot validate a Cloudflare-proxied hostname
  * Cloudflare Authenticated Origin Pulls required
  * exact regional Host/SNI allowlist; unknown hostnames are rejected
  * rate limits on `/api/*`, including `/api/health`
  * strips `/api/*` and proxies only to `127.0.0.1:<fastapi_port>`
  * logs API HTTP requests only, never VPN traffic

Terraform inputs cover the shared-server deployment config: source repo/ref, region ID, regional API hostname, dashboard CORS origin, FastAPI port, WireGuard endpoint hostname (`wg.<regionId>.<origin>`, grey-cloud), server tunnel DNS IPs, Firebase credential payload/path, and Caddy/Cloudflare settings. `dashboard_cors_origin` is also rendered into user access emails as the login link, so it must be one exact dashboard URL with no globs, wildcards, patterns, or comma-separated origins. There are no deploy-time client peer variables.

### Regional DNS records

The region's `A` records (`cloudflare_record.api`, proxied; `cloudflare_record.wg`, grey-cloud) are Terraform-managed and point at the instance public IP, so they follow a rebuild automatically. Two safeguards exist because the Cloudflare provider does not validate the token up front and its record create is an insert, not an upsert:

* `data.cloudflare_zone.this` makes an authenticated Cloudflare call during `plan`/refresh, so an invalid or IP-blocked token fails before the instance is created or replaced. If a deploy errors here, check that the `cloudflare_api_token` is valid and that the operator machine's public IP is in the token's client-IP allowlist.
* The deploy wrapper blocks unmanaged matching records before Terraform can create
  more DNS state. If a matching record already exists but is not in Terraform
  state, import the canonical record or delete/recreate intentionally before
  rerunning. If a prior half-failed apply left duplicate records, manually
  reconcile them before rerunning because Terraform cannot safely disambiguate.

A token that is valid but blocked by source-IP filtering used to surface only after the instance was created (the records depend on the instance), leaving an orphaned instance, unupdated records, and duplicates on the next run. The zone preflight now fails that case at plan time.

The deploy wrapper also checks regional resource ownership before every plan,
apply, and destroy. It queries Cloudflare for the exact API and WireGuard `A` records, and OCI
for active instances tagged `CloudGatewayManaged=true` in that region's configured
compartment/profile/region. Zero matching resources is safe for a first deploy.
Exactly one matching resource is safe only when it is already in the selected
Terraform workspace state. More than one matching DNS record or VM is unsafe.
Any unsafe region stops the whole deploy so the operator can manually reconcile
resources or import the canonical resources into state before rerunning.

AdGuard Home is installed from the pinned `adguard_home_version` Terraform input. The bootstrap writes its config directly: only the AdGuard DNS filter is enabled, the admin UI binds to `127.0.0.1:3000`, and query logs/statistics are disabled to preserve the VPN traffic logging boundary.

See [adguard-home.md](adguard-home.md) for the AdGuard Home runtime configuration and operator rules.

The minimum recommended server shape is 2 OCPU and 4-6 GB RAM, with capacity for roughly 15-25 clients per region. CPU matters more than memory as client count grows because WireGuard encrypts and decrypts traffic for every connection.

## Network Prerequisites

Before applying the stack in a region, make sure OCI already has:

* a target compartment
* a subnet for the instance
* IPv6 enabled and routed if you want IPv6 VPN traffic
* an image OCID compatible with the Terraform shape and cloud-init scripts
* ingress for SSH on TCP `22` set to only your approved personal `IPv4/32`
* ingress for WireGuard on UDP `51820`
  * IPv4: `0.0.0.0/0`
  * IPv6: `::/0`
* ingress for HTTP/HTTPS on TCP `80`/`443` restricted to Cloudflare IP ranges only (the regional API origin must not be reachable directly)
* egress that allows VPN client traffic out to `0.0.0.0/0` and `::/0`

WireGuard UDP rate limiting lives in the host firewall rules. Caddy rate limiting protects the regional API only and does not protect UDP VPN traffic.

## Files

[cloudgateway.tf](terraform/cloudgateway.tf)

* Main Terraform file.
* Declares the input variables.
* Renders the cloud-init templates.
* Creates the OCI compute instance and passes SSH keys plus multipart `user_data`.

[stub-cloud-init.sh.tftpl](terraform/stub-cloud-init.sh.tftpl)

* Small shell script template rendered by Terraform and run by cloud-init.
* Writes `/etc/cloudgateway/bootstrap.env`, the WireGuard server key, and the optional Firebase credential file from Terraform inputs.
* Fetches the repo tarball from GitHub at `source_repo`/`source_ref` and runs the versioned bootstrap.
* Starts the step-marker logging to `/var/log/wireguard-bootstrap.log` so bootstrap failures are easier to pinpoint.

[host/bootstrap.sh](host/bootstrap.sh)

* Full host bootstrap, fetched from GitHub by the stub (never rendered by Terraform).
* Installs and configures the host services described above from `/etc/cloudgateway/bootstrap.env`.
* Disables SSH password auth and root SSH login.
* Installs the API from the fetched source and writes the `cloudgateway-install-api` update helper.

[host/Caddyfile.template](host/Caddyfile.template)

* Caddy configuration template fetched alongside the bootstrap and rendered on the host with `envsubst`.

[backdoor-cloud-init.yaml](terraform/backdoor-cloud-init.yaml)

* Cloud-init config that creates the emergency `backdoor` user.
* Sets the password hash from Terraform input.
* Appends `DenyUsers backdoor` to SSH config so this user cannot log in over SSH.
* Intended only for console access through OCI when normal SSH access is unavailable.

[terraform.tfvars.example](terraform/terraform.tfvars.example)

* Example variable values for a regional deployment.
* Copy to `<regionId>.terraform.tfvars` (one per region) and fill in real values before applying.

`<regionId>.terraform.tfvars`

* Per-region local-only deployment values, for example `us-chicago-1.terraform.tfvars`.
* Deployed via [./scripts/terraform.sh](../scripts/terraform.sh), which accepts one or more regions, selects each per-region Terraform workspace (isolated state), and uses the matching var file, so regions never share state.
* Multi-region apply creates one deploy tag and writes that same `source_ref` into every listed region's tfvars before applying them sequentially.
* `oci_config_profile` names the `~/.oci/config` profile for that region's tenancy.
* Contains sensitive values such as the WireGuard private key, Firebase credentials, and password hash. Never commit it; `*.tfvars` is gitignored.

## WireGuard Config Shapes

[wireguard_configs/example.wg0-server.conf](wireguard_configs/example.wg0-server.conf)

* Shared-server interface shape: address, listen port, firewall/NAT `PostUp`/`PostDown`, UDP rate limits.
* The host firewall blocks VPN client traffic to OCI instance metadata at `169.254.169.254` so `user_data` stays protected.
* No static `[Peer]` blocks. Peers are managed at runtime by the regional API.

[wireguard_configs/example.wg0-client.conf](wireguard_configs/example.wg0-client.conf)

* Client config shape generated by the regional API: client private key, assigned tunnel IPv4/IPv6, tunnel DNS IPs, server public key, and `Endpoint = wg.<regionId>.<origin>:51820`.
* The endpoint is a non-proxied (grey-cloud) DNS record resolving to the server public IPv4. WireGuard traffic does not go through Cloudflare; clients re-resolve the name at tunnel-up, so a rebuilt host with a new IP keeps existing clients.

## Backdoor User

The `backdoor` user exists only as an emergency recovery path.

What it does:

* account name: `backdoor`
* password login is allowed on the local console because cloud-init sets the provided password hash
* password login over SSH is blocked because the bootstrap disables SSH password authentication globally and the cloud-init file adds `DenyUsers backdoor`
* `sudo` is passwordless so you can recover access if your normal SSH path is broken

How to use it:

1. Open the OCI instance.
2. Go to the console connection / serial login flow.
3. Log in as `backdoor` with the password that matches the `hashed_password` Terraform input.

This user is for recovery only.

## Local Validation

Use Terraform `1.6` or newer. See [../docs/tool-versions.md](../docs/tool-versions.md) for local tooling and deployed host package expectations.

```sh
cd terraform
terraform init
terraform validate
```

What these do:

* `terraform init` downloads the OCI provider and prepares the local working directory.
* `terraform validate` checks Terraform syntax, type usage, and provider schema compatibility.

Useful notes:

* `.terraform/` is local init output and should not be committed.
* `terraform validate` requires `terraform init` first on a clean machine.
* If you change provider-related settings later, rerun `terraform init`.

## Runtime Logs

After the instance launches, useful logs on the VM are:

* `/var/log/cloud-init-output.log`
* `/var/log/wireguard-bootstrap.log`

Check with:
```sh
sudo sed -n '1,240p' /var/log/wireguard-bootstrap.log
# or
tail -f /var/log/wireguard-bootstrap.log
```

Bootstrap status lines include a UTC timestamp and elapsed seconds since the stub or fetched bootstrap started. Terraform apply wall time also includes OCI instance provisioning before cloud-init starts, so these timestamps measure the host setup work only.


For service-level logs (`cloudgateway-api.service`, Caddy, `wg-quick@wg0`, Unbound), see [docs/service-operations.md](../docs/service-operations.md).

If the regional VM or its boot volume is lost, see [docs/vm-loss-recovery.md](../docs/vm-loss-recovery.md).
