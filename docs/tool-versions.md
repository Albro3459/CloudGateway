# Tool versions

Use repository manifests for requirements and Terraform inputs for deployed
versions. These are development baselines, not a record of workstation patches.

## Local tools

* ARM macOS is the primary environment.
* Python 3.12 or newer: [API metadata](../Backend/API/pyproject.toml).
  Create the API environment with `python3 -m venv .venv` in `Backend/API/`.
* Node.js 24 or newer: [web engines](../Frontend/Web/package.json).
  Use the same Node installation for Firebase tooling.
* npm 10 or newer: web/Firebase development baseline. The web lockfile uses
  format 3; run `npm install` in the relevant package directory.
* Java 21 or newer: Firebase emulator tooling. ARM Homebrew uses `openjdk@21`.
* Xcode with Swift 6.3 or newer: [shared package manifest](../Frontend/Apple/CloudGatewayKit/Package.swift).
  The shared package targets iOS 17/macOS 14; the Mac app targets macOS 26/arm64.
* Go available to Xcode: both Apple projects build the checked-in WireGuard
  submodule and Go bridge. Its module declares Go 1.17 as a floor, not a pinned
  build toolchain. Homebrew Go is found at `/opt/homebrew/bin/go` on ARM macOS.
* Go 1.26 or newer for the [Linux client](../Frontend/Linux/go.mod), which pins
  `toolchain go1.27.3` so release builds stay reproducible. It has no
  third-party modules.
* Periphery: strict Apple dead-code scans. Install with `brew install periphery`;
  see the platform configs under `Frontend/Apple/`.
* Terraform 1.6 or newer: repo development baseline. Use the
  [regional wrapper](../Infrastructure/OCI/README.md), which isolates state per
  region; manual commands run in `Infrastructure/OCI/terraform/`.

## Regional hosts

Bootstrap expects an Ubuntu-like apt image with systemd/cloud-init. It installs
WireGuard, iptables, nftables, fail2ban, Unbound, DNS root data, Python venv/pip,
CA certificates, curl, and gettext. API dependencies run in
`/opt/cloudgateway/api/.venv`.

Terraform-controlled tools:

* AdGuard Home defaults to `v0.107.77` via `adguard_home_version`.
* Caddy comes from a prebuilt Linux arm64 release pinned by `caddy_binary_tag`
  and verified by `caddy_binary_sha256`.
* The [Caddy build](../Infrastructure/OCI/caddy/Dockerfile) defaults to `v2.8.4`
  with `github.com/mholt/caddy-ratelimit`; `scripts/caddy-release.sh` publishes it.

See [bootstrap](../Infrastructure/OCI/host/bootstrap.sh),
[Terraform variables](../Infrastructure/OCI/terraform/cloudgateway.tf), and
[example tfvars](../Infrastructure/OCI/terraform/terraform.tfvars.example) for
host inputs. Dependency ranges and resolved versions live in each package's
manifest/lockfile. Do not replace documented floors with whichever patch happens
to be installed locally.
