# GitHub Deployment Setup

How the repository on GitHub must be set up for regional deployments to work. At boot, the cloud-init stub baked by Terraform downloads this repo from GitHub at a pinned ref and runs the versioned bootstrap from it. If GitHub does not have the ref, or the ref does not contain the expected paths, the deployment fails.

## Repository Requirements

* The repo must be **public**. The stub downloads tarballs unauthenticated; there is no token support by design. If the repo ever goes private, the stub needs a fine-grained read-only PAT passed via a new Terraform variable and an auth header on the download - that is intentionally out of scope today.
* GitHub's unauthenticated rate limit (60 requests/hour/IP) is irrelevant for rare manual deploys; each deploy makes one tarball request.

## Fetched-Path Contract

Any ref used for deployment must contain these paths:

* `OCI/host/bootstrap.sh` - the full host bootstrap run by the stub.
* `OCI/host/Caddyfile.template` - rendered on the host with `envsubst`.
* `API/` - `pyproject.toml` plus the `src/` package, installed into the host venv.

The stub baked into an instance's user-data expects these exact paths. Renaming or moving them is a breaking change: older tfvars pinned to newer refs (or the reverse) will fail the stub's path check. If the layout must change, update `OCI/terraform/stub-cloud-init.sh.tftpl` in the same commit and only deploy refs at or after that commit.

## How the Stub Fetches

The stub builds the download URL from two Terraform variables:

```text
https://codeload.github.com/<source_repo>/tar.gz/<source_ref>
```

* `source_repo`: GitHub `owner/repo`, default `Albro3459/CloudGateway`.
* `source_ref`: required, no default. Accepts a tag name, a full commit SHA, or a branch name.

It extracts only `API/` and `OCI/host/` into `/opt/cloudgateway/src`, verifies `bootstrap.sh` exists, and runs it. Secrets never come from GitHub - the WireGuard server key, Firebase credentials, and all per-region config are written by the stub from Terraform variables before the fetch.

## Release Workflow

The normal operator path is [`./scripts/terraform.sh`](../scripts/terraform.sh), which bumps
`API/src/version.py`, creates and pushes one `Deploy vX.Y.Z` commit plus matching
`deploy-vX.Y.Z` tag, and writes that tag to every listed region's
`<regionId>.terraform.tfvars` before applying.

For a manual fallback:

1. Merge the deployable state to `main`.
2. Create an annotated tag, convention `deploy-vX.Y.Z`:

```sh
git tag -a deploy-v1.0.0 -m "deploy-v1.0.0"
git push origin deploy-v1.0.0
```

3. Set `source_ref = "deploy-v1.0.0"` in each region's `<regionId>.terraform.tfvars` and deploy per [docs/regional-deployment.md](regional-deployment.md).

**The commit/tag must be pushed to GitHub before deploying.** codeload serves only what GitHub has - local-only commits cannot be deployed.

Ref choice trade-offs:

* **Tag** (recommended): readable, auditable in `terraform plan` diffs. Git tags are technically mutable; do not move published `deploy-*` tags.
* **Full 40-character commit SHA**: strictly immutable. Use when you want a deploy that can never silently change.
* **Branch**: convenient for dev spins; two deploys from the same tfvars can differ. Do not use for real regions.

## Updating a Live Region's API

The host keeps `SOURCE_REPO` and `SOURCE_REF` in `/etc/cloudgateway/bootstrap.env`. To roll the API to a new ref without redeploying:

```sh
git tag -a deploy-v1.1.0 -m "deploy-v1.1.0" && git push origin deploy-v1.1.0
ssh ubuntu@<server-public-ipv4>
sudo cloudgateway-install-api deploy-v1.1.0
```

With no argument, `cloudgateway-install-api` re-fetches the ref the host was deployed with. The helper only updates `API/`. Update `source_ref` in that region's `<regionId>.terraform.tfvars` afterward so any future host build uses the same code.

**Updating `source_ref` in tfvars is bookkeeping only - never run `terraform apply` just to sync it.** OCI does not allow changing `user_data` on a launched instance, so once `source_ref` (or anything else baked into user-data) changes, the next wrapper deploy plans to destroy and recreate the regional server. A rebuild gets a new ephemeral public IPv4, so the recovery checklist in [docs/vm-loss-recovery.md](vm-loss-recovery.md) applies (Terraform updates the API/WireGuard `A` records, operators update the Firebase region doc IP, and DNS is touched manually only when preflight reports unmanaged state to reconcile/import before rerunning; the boot peer sync restores peers from Firebase and users just toggle their tunnels). Treat a rebuild as a planned event, not a variable refresh.

The operating rule for a live region:

* API change: `sudo cloudgateway-install-api <ref>`. Running tunnels are unaffected.
* Host-level change (bootstrap, Caddyfile template, firewall, systemd): plan a rebuild via `./scripts/terraform.sh <region> apply` and walk the VM-loss recovery checklist, or for smaller changes re-run the fetched bootstrap and re-sync peers (see Troubleshooting below).
* Tiny one-off tweak: hand-edit the specific file on the host (for example `/etc/caddy/Caddyfile`, then `systemctl reload caddy`) and fold the real change into the next tagged ref so the next rebuild matches.

## Troubleshooting Fetch Failures

Boot-time fetch failures land in `/var/log/wireguard-bootstrap.log` (`journalctl -t wireguard-bootstrap`).

* `Failed to download <repo>@<ref>`: the ref is not on GitHub (not pushed), the repo went private, or the host has no egress. Fix the cause, then either re-run the stub's fetch manually or terminate and re-apply Terraform.
* `does not contain OCI/host/bootstrap.sh`: the ref predates the fetched-path contract. Pin a ref that satisfies the contract.
* If the tarball extracted but the bootstrap failed partway during initial deployment, it is safe to re-run after fixing the cause:

```sh
sudo bash /opt/cloudgateway/src/OCI/host/bootstrap.sh
```

Re-running the bootstrap on a live host is largely safe under the Firebase-master peer model: `/etc/wireguard/wg0.conf` is interface-only (peers are never persisted anywhere on the host), `wg-quick` is not restarted by a re-run, and `cloudgateway-sync-peers` re-converges the live peer set from Firebase afterward. It does overwrite host config files and restart the API/Caddy/AdGuard Home, so prefer a planned rebuild for substantive host-level changes and run `sudo cloudgateway-sync-peers` after any re-run.

Never paste the contents of `/etc/cloudgateway/bootstrap.env` secrets, `/etc/cloudgateway/wireguard-server.key`, or the Firebase credential file into logs or tickets.
