# GitHub Deployment Setup

How the repository on GitHub must be set up for regional deployments to work. At boot, the cloud-init stub baked by Terraform downloads this repo from GitHub at a pinned ref and runs the versioned bootstrap from it. If GitHub does not have the ref, or the ref does not contain the expected paths, the deployment fails.

## Repository Requirements

* The repo must be **public**. The stub downloads tarballs unauthenticated; there is no token support by design. If the repo ever goes private, the stub needs a fine-grained read-only PAT passed via a new Terraform variable and an auth header on the download - that is intentionally out of scope today.
* GitHub's unauthenticated rate limit (60 requests/hour/IP) is irrelevant for rare manual deploys; each deploy makes one tarball request.

## Fetched-Path Contract

Any ref used for deployment must contain these paths:

* `OCI/host/bootstrap.sh` - the full host bootstrap run by the stub.
* `OCI/host/Caddyfile.template` - rendered on the host with `envsubst`.
* `API/` - `pyproject.toml` plus the `cloudlaunch_api/` package, installed into the host venv.

The stub baked into an instance's user-data expects these exact paths. Renaming or moving them is a breaking change: older tfvars pinned to newer refs (or the reverse) will fail the stub's path check. If the layout must change, update `OCI/terraform/stub-cloud-init.sh.tftpl` in the same commit and only deploy refs at or after that commit.

## How the Stub Fetches

The stub builds the download URL from two Terraform variables:

```text
https://codeload.github.com/<source_repo>/tar.gz/<source_ref>
```

* `source_repo`: GitHub `owner/repo`, default `Albro3459/CloudGateway`.
* `source_ref`: required, no default. Accepts a tag name, a full commit SHA, or a branch name.

It extracts only `API/` and `OCI/host/` into `/opt/cloudlaunch/src`, verifies `bootstrap.sh` exists, and runs it. Secrets never come from GitHub - the WireGuard server key, Firebase credentials, and all per-region config are written by the stub from Terraform variables before the fetch.

## Release Workflow

1. Merge the deployable state to `main`.
2. Create an annotated tag, convention `deploy-vX.Y.Z`:

```sh
git tag -a deploy-v1.0.0 -m "deploy-v1.0.0"
git push origin deploy-v1.0.0
```

3. Set `source_ref = "deploy-v1.0.0"` in `terraform.tfvars` and deploy per [docs/regional-deployment.md](regional-deployment.md).

**The commit/tag must be pushed to GitHub before deploying.** codeload serves only what GitHub has - local-only commits cannot be deployed.

Ref choice trade-offs:

* **Tag** (recommended): readable, auditable in `terraform plan` diffs. Git tags are technically mutable; do not move published `deploy-*` tags.
* **Full 40-character commit SHA**: strictly immutable. Use when you want a deploy that can never silently change.
* **Branch**: convenient for dev spins; two deploys from the same tfvars can differ. Do not use for real regions.

## Updating a Live Region's API

The host keeps `SOURCE_REPO` and `SOURCE_REF` in `/etc/cloudlaunch/bootstrap.env`. To roll the API to a new ref without redeploying:

```sh
git tag -a deploy-v1.1.0 -m "deploy-v1.1.0" && git push origin deploy-v1.1.0
ssh ubuntu@<server-public-ipv4>
sudo cloudlaunch-install-api deploy-v1.1.0
```

With no argument, `cloudlaunch-install-api` re-fetches the ref the host was deployed with. The helper only updates `API/`; host-level changes (Caddy, WireGuard, firewall, systemd) still require re-running the bootstrap or redeploying. Update `source_ref` in tfvars afterward so the next `terraform apply` matches what is running.

## Troubleshooting Fetch Failures

Boot-time fetch failures land in `/var/log/wireguard-bootstrap.log` (`journalctl -t wireguard-bootstrap`).

* `Failed to download <repo>@<ref>`: the ref is not on GitHub (not pushed), the repo went private, or the host has no egress. Fix the cause, then either re-run the stub's fetch manually or terminate and re-apply Terraform.
* `does not contain OCI/host/bootstrap.sh`: the ref predates the fetched-path contract. Pin a ref that satisfies the contract.
* If the tarball extracted but the bootstrap failed partway, it is safe to re-run after fixing the cause:

```sh
sudo bash /opt/cloudlaunch/src/OCI/host/bootstrap.sh
```

The bootstrap overwrites its own config files and re-enables services, so re-running is idempotent for practical purposes. Never paste the contents of `/etc/cloudlaunch/bootstrap.env` secrets, `/etc/cloudlaunch/wireguard-server.key`, or the Firebase credential file into logs or tickets.
