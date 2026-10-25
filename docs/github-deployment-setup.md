# GitHub Deployment Setup

Regional hosts fetch bootstrap and API source from GitHub. The selected ref must
be published and contain the paths below before a host can boot successfully.

## Repository Requirements

The repo must be public. The cloud-init stub and API installer download tarballs
without authentication and have no private-repository token support.

## Fetched-Path Contract

Every deployable ref must contain:

* `Infrastructure/OCI/host/bootstrap.sh`: host bootstrap.
* `Infrastructure/OCI/host/Caddyfile.template`: Caddy config rendered with `envsubst`.
* `Backend/API/`: `pyproject.toml` and the `src/` package installed into the host venv.

The [stub](../Infrastructure/OCI/terraform/stub-cloud-init.sh.tftpl) expects this
layout. Update it alongside any path changes and use compatible source refs.

## How the Stub Fetches

```text
https://codeload.github.com/<source_repo>/tar.gz/<source_ref>
```

`source_repo` defaults to `Albro3459/CloudGateway`. `source_ref` is required and
accepts a tag, full commit SHA, or branch. The stub extracts `Backend/API/` and
`Infrastructure/OCI/host/` into `/opt/cloudgateway/src`, checks for `bootstrap.sh`,
and runs it. Terraform supplies regional configuration and secrets separately
through user-data. Keep tfvars, Terraform state, and user-data private.

## Release Workflow

The normal host deployment uses [`./scripts/terraform.sh`](../scripts/terraform.sh):

1. Require a clean working tree and prepare plans for all selected regions using
   the next deploy tag.
2. After confirmation, bump `Backend/API/src/version.py`, commit `Deploy vX.Y.Z`,
   push the current branch, and create/push the matching `deploy-vX.Y.Z` tag.
3. Write that tag to each selected region's gitignored tfvars and apply the saved
   plans sequentially.

This wrapper publishes a fresh release. It does not deploy an existing
`source_ref` unchanged. `plan` alone uses the current tfvars and publishes nothing.
See [regional deployment](regional-deployment.md) for backups and host validation.

For an API-only release, publish a tag or full SHA through the normal authorized
release process, then use the installer below. Published tags must stay fixed.
A full commit SHA identifies immutable source. Branch refs can change between
fetches and should be avoided for production.

## Updating a Live Region's API

On a host with the required host configuration already installed:

```sh
sudo cloudgateway-install-api <published-tag-or-sha>
```

The helper fetches only `Backend/API/`, copies it into `/opt/cloudgateway/api`,
reinstalls the package, and restarts the API. Existing WireGuard tunnels keep
running. Without an argument, it uses `SOURCE_REF` from
`/etc/cloudgateway/bootstrap.env`, which still identifies the host's bootstrap
ref, even after an API-only update.

Record the intended API ref in the region's tfvars for future recovery. **Do not
apply Terraform just to update that record:** changing `source_ref` or other
user-data inputs plans a host replacement. The wrapper's next apply also creates
and selects a fresh deploy tag.

Host changes to bootstrap, Caddy, firewall, systemd, or Uvicorn options need a
[planned rebuild](vm-loss-recovery.md). The installer does not update those files.
It rejects ACL-aware API source when the live host lacks the `inet cloudgateway`
table, `cg_forward` chain, or `cg_slot4/6` maps. Re-running bootstrap on an already
active interface does not run `PostUp` and cannot migrate such a host. Rebuild all
affected regions from one deploy tag before treating fleet ACL enforcement as complete.

## Troubleshooting Fetch Failures

Read `/var/log/wireguard-bootstrap.log` or `journalctl -t wireguard-bootstrap`.

* `Failed to download <repo>@<ref>`: confirm the ref is published, the repo is public,
  and the host has egress. Fix the cause before retrying the fetch or rebuilding.
* Missing `Infrastructure/OCI/host/bootstrap.sh`: use a ref satisfying the path contract.
* If initial bootstrap failed after extraction, fix the cause and rerun the fetched script:

```sh
sudo bash /opt/cloudgateway/src/Infrastructure/OCI/host/bootstrap.sh
sudo systemctl start cloudgateway-sync-peers.service
sudo systemctl status cloudgateway-sync-peers.service
```

A bootstrap rerun overwrites host configuration and restarts Unbound, AdGuard
Home, the API, the origin firewall, and Caddy. It starts `wg-quick` if needed but
does not restart an active interface. Use it to resume an interrupted bootstrap,
and plan substantive host upgrades as rebuilds. A small emergency manual edit
must also reach the versioned bootstrap/template so the next rebuild preserves it.

Never paste `bootstrap.env`, `api.env`, the WireGuard server key, full configs,
Firebase credentials, or auth tokens into logs or tickets.
