# API Deployment Handoff

The contract the host bootstrap (Terraform / `Infrastructure/OCI/host/bootstrap.sh`) must satisfy to install
and run the regional API. The runtime request/response surface is in
[api-contract.md](api-contract.md).

## Install layout

- Host install directory: `/opt/cloudgateway/api`.
- Python virtualenv: `/opt/cloudgateway/api/.venv`.
- App import path: `src.main:app`.
- Dependency metadata: `Backend/API/pyproject.toml`. Infrastructure installs the package into the venv
  from `/opt/cloudgateway/api`.

## systemd service

- Service name: `cloudgateway-api.service`.
- Runs as `root`, working directory `/opt/cloudgateway/api`, binding only to `127.0.0.1`.

## Environment

- Environment file path: `/etc/cloudgateway/api.env`, mode `0600`, owned by `root`.
- Required environment variables:
  - `CLOUDGATEWAY_REGION_ID`
  - `CLOUDGATEWAY_API_PORT`
  - `CLOUDGATEWAY_FIREBASE_CREDENTIALS_FILE`
  - `CLOUDGATEWAY_WG_INTERFACE`
  - `CLOUDGATEWAY_WG_SERVER_PUBLIC_KEY`
  - `CLOUDGATEWAY_WG_ENDPOINT_HOSTNAME`
  - `CLOUDGATEWAY_WG_PORT`
  - `CLOUDGATEWAY_WG_DNS_IPV4`
  - `CLOUDGATEWAY_WG_DNS_IPV6`
  - `CLOUDGATEWAY_WG_TUNNEL_IPV4_CIDR`
  - `CLOUDGATEWAY_WG_TUNNEL_IPV6_CIDR`
- Default values: `CLOUDGATEWAY_API_PORT=8000`, `CLOUDGATEWAY_WG_INTERFACE=wg0`,
  `CLOUDGATEWAY_WG_PORT=51820`.

## Regional subnet allocation

`Infrastructure/OCI/terraform/subnet-registry.json` is the authoritative list of regional
WireGuard allocations and shared aggregate boundaries. The selected region's local gitignored
tfvars must copy its registry `wg_network_v4`/`wg_network_v6` values exactly. Keep removed
allocations in the registry with `status: "reserved"`; a missing local tfvars file does not remove
that inventory entry.

If Firebase was unavailable during bootstrap, rerun registration with systemd's environment-file
parser rather than shell-sourcing `/etc/cloudgateway/api.env`:

```sh
sudo systemd-run --quiet --pipe --wait --collect --property=WorkingDirectory=/opt/cloudgateway/api --property=EnvironmentFile=/etc/cloudgateway/api.env /opt/cloudgateway/api/.venv/bin/cloudgateway-register-region
```

## Peer state

- Firebase is the single source of truth for WireGuard peers. Peers are never written to
  `/etc/wireguard/wg0.conf` or any other host state file; the file is written once by bootstrap
  with interface settings only.
- The `cloudgateway-sync-peers` entry point (systemd `cloudgateway-sync-peers.service`) rebuilds
  the live peer set from Firebase on every boot and on demand, one-directionally (Firebase wins;
  unknown server peers are removed). After reconciliation it best-effort writes the server-only
  `Mesh/{regionId}` status snapshot while holding the WireGuard lock; a status write failure does
  not fail an otherwise successful sync.
- API routes hold the `/run/cloudgateway-wireguard.lock` flock across each WireGuard mutation plus
  its matching Firebase write.

## Replacement and destroy handoff

Before replacing or destroying a region, operators must run `prepare-drain`, dashboard **Sync All**
across remaining enabled regions, `verify-drain`, and only then Terraform apply/destroy. The wrapper
parses each plan and blocks destructive operations before deploy tag, `source_ref`, or Terraform
mutation when the drain cannot be proven. A Mesh status snapshot proves freshness and peer omission,
not a WireGuard handshake; check `wg show` on the host. Re-registration may enable a rebuilt region
again but keeps `meshEnabled=false` until explicit operator enable plus Sync All. When the host is
already lost, perform the same flow from an operator workstation.

## Firestore backup

- Before a regional deploy or host replacement, back up Firestore from the repo root:

  ```sh
  Backend/API/.venv/bin/python3 scripts/backup_firestore.py
  ls -lh Backend/Firebase/backups
  ```

- Confirm a new `Backend/Firebase/backups/backup-<timestamp>.json` file exists. Treat backup files as
  secret material because they can contain full WireGuard configs and client private keys.
