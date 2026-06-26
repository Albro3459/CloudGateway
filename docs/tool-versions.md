# Tool Versions

Expected local and deployment tooling for this repo.

## Local Development

* macOS on ARM is the primary local development environment.
* Python `3.12` or newer for `API/`.
  * `API/pyproject.toml` declares `requires-python = ">=3.12"`.
  * Use `python3 -m venv .venv` from `API/` unless you intentionally need a different interpreter.
* Node.js `20` LTS or newer for `APP/`.
  * The frontend lockfile is npm lockfile version `3`.
  * Current Firebase and build dependencies require at least Node `18`; use Node `20` LTS as the repo baseline.
* npm `10` or newer for `APP/`.
  * Use `npm install` from `APP/` to refresh `package-lock.json`.
* Terraform `1.6` or newer for `OCI/terraform`.
  * The Terraform code uses standard provider and template features and does not pin a CLI patch version.
  * Run Terraform from `OCI/terraform`, not the repo root.

## Deployed OCI Hosts

The regional host bootstrap expects an Ubuntu-like apt-based OCI image with systemd and cloud-init.

The bootstrap installs these packages from the OS package repositories:

* `wireguard`
* `iptables`
* `fail2ban`
* `python3-venv`
* `python3-pip`
* `ca-certificates`
* `curl`
* `gettext-base`

Pinned or Terraform-controlled host tool versions:

* AdGuard Home: `v0.107.77` by default, controlled by `adguard_home_version`.
* Caddy: prebuilt CloudGateway Linux ARM64 binary, controlled by `caddy_binary_tag` and verified with `caddy_binary_sha256`.
* Caddy build inputs: `OCI/caddy/Dockerfile` builds Caddy `v2.8.4` with `github.com/mholt/caddy-ratelimit`; releases are published with `scripts/caddy-release.sh`.

The deployed API runs in a host-created Python virtual environment at `/opt/cloudgateway/api/.venv`.

## Version Sources

* Python package floor: [API/pyproject.toml](../API/pyproject.toml)
* Frontend dependencies and lockfile: [APP/package.json](../APP/package.json), [APP/package-lock.json](../APP/package-lock.json)
* OCI host package and pinned runtime inputs: [OCI/host/bootstrap.sh](../OCI/host/bootstrap.sh), [OCI/terraform/cloudgateway.tf](../OCI/terraform/cloudgateway.tf), [OCI/terraform/terraform.tfvars.example](../OCI/terraform/terraform.tfvars.example)
