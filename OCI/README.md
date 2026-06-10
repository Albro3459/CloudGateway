# Oracle Shared Regional WireGuard Host

This folder contains the Oracle Cloud Infrastructure Terraform package used to launch one long-lived shared WireGuard server per OCI region, bootstrapped with cloud-init.

CloudLaunch uses this model:

```text
1 OCI region = 1 long-lived shared WireGuard server
```

Deployment is rare and manual. An operator prepares OCI networking, applies this Terraform stack directly, then finishes the regional setup (Cloudflare DNS, Firebase region doc, validation) following [docs/regional-deployment.md](../docs/regional-deployment.md). There is no Lambda orchestrator, no OCI Resource Manager flow, and no per-user stack deployment.

WireGuard peers are never created at deploy time. The regional FastAPI control plane adds and removes peers later, keeping `/etc/wireguard/wg0.conf` as the persistent host config.

## What the Host Runs

Cloud-init installs and configures:

* WireGuard bare metal with `/etc/wireguard/wg0.conf` written with interface settings and <b>no initial `[Peer]`</b>, started through `wg-quick@wg0`.
* IPv4/IPv6 forwarding, firewall/NAT rules, and WireGuard UDP `iptables`/`ip6tables` rate limits.
* Unbound DNS for VPN clients (tunnel DNS IPs).
* Python runtime and the regional FastAPI app per the deployment handoff in `TODO/Shared_VPN_Contract.md`:
  * install directory `/opt/cloudlaunch/api` with venv `/opt/cloudlaunch/api/.venv`
  * systemd service `cloudlaunch-api.service`, running as root, bound only to `127.0.0.1`
  * environment file `/etc/cloudlaunch/api.env` (mode `0600`, root-owned) with the `CLOUDLAUNCH_*` variables, including `CLOUDLAUNCH_REGION_ID`
  * Firebase Admin credentials file referenced by `CLOUDLAUNCH_FIREBASE_CREDENTIALS_FILE`
* Custom Caddy binary built with `github.com/mholt/caddy-ratelimit`, listening on public `80`/`443`:
  * automatic HTTPS for the regional API hostname
  * Cloudflare Authenticated Origin Pulls required
  * exact regional Host/SNI allowlist; unknown hostnames are rejected
  * rate limits on `/api/*`, including `/api/health`
  * strips `/api/*` and proxies only to `127.0.0.1:<fastapi_port>`
  * logs API HTTP requests only, never VPN traffic

Terraform inputs cover the shared-server deployment config: region ID, regional API hostname, dashboard CORS origin, FastAPI port, WireGuard public endpoint IPv4, server tunnel DNS IPs, Firebase credential payload/path, and Caddy/Cloudflare settings. There are no deploy-time client peer variables.

The recommended server shape is 2 OCPU and 8-12 GB RAM, with capacity for roughly 15-25 clients per region.

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

[cloudlaunch.tf](terraform/cloudlaunch.tf)

* Main Terraform file.
* Declares the input variables.
* Renders the cloud-init templates.
* Creates the OCI compute instance and passes SSH keys plus multipart `user_data`.

[wireguard-cloud-init.sh.tftpl](terraform/wireguard-cloud-init.sh.tftpl)

* Shell script template rendered by Terraform and run by cloud-init.
* Installs and configures the host services described above.
* Disables SSH password auth and root SSH login.
* Writes step markers into `/var/log/wireguard-bootstrap.log` so bootstrap failures are easier to pinpoint.

[backdoor-cloud-init.yaml](terraform/backdoor-cloud-init.yaml)

* Cloud-init config that creates the emergency `backdoor` user.
* Sets the password hash from Terraform input.
* Appends `DenyUsers backdoor` to SSH config so this user cannot log in over SSH.
* Intended only for console access through OCI when normal SSH access is unavailable.

[terraform.tfvars.example](terraform/terraform.tfvars.example)

* Example variable values for a regional deployment.
* Copy to `terraform.tfvars` and fill in real values before applying.

`terraform.tfvars`

* Local-only deployment values.
* Contains sensitive values such as the WireGuard private key, Firebase credentials, and password hash. Never commit it.

## WireGuard Config Shapes

[wireguard_configs/example.wg0-server.conf](wireguard_configs/example.wg0-server.conf)

* Shared-server interface shape: address, listen port, firewall/NAT `PostUp`/`PostDown`, UDP rate limits.
* No static `[Peer]` blocks. Peers are managed at runtime by the regional API.

[wireguard_configs/example.wg0-client.conf](wireguard_configs/example.wg0-client.conf)

* Client config shape generated by the regional API: client private key, assigned tunnel IPv4/IPv6, tunnel DNS IPs, server public key, and `Endpoint = <raw server public IPv4>:51820`.
* The endpoint is the server's actual public IPv4. WireGuard traffic does not go through Cloudflare.

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

For service-level logs (`cloudlaunch-api.service`, Caddy, `wg-quick@wg0`, Unbound), see [docs/service-operations.md](../docs/service-operations.md).

If the regional VM or its boot volume is lost, see [docs/vm-loss-recovery.md](../docs/vm-loss-recovery.md).
