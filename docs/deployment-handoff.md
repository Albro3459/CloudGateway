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

## Peer state

- Firebase is the single source of truth for WireGuard peers. Peers are never written to
  `/etc/wireguard/wg0.conf` or any other host state file; the file is written once by bootstrap
  with interface settings only.
- The `cloudgateway-sync-peers` entry point (systemd `cloudgateway-sync-peers.service`) rebuilds
  the live peer set from Firebase on every boot and on demand, one-directionally (Firebase wins;
  unknown server peers are removed; sync never writes to Firebase).
- API routes hold the `/run/cloudgateway-wireguard.lock` flock across each WireGuard mutation plus
  its matching Firebase write.

## Firestore backup

- Before a regional deploy or host replacement, back up Firestore from the repo root:

  ```sh
  source Backend/API/.venv/bin/activate
  python3 scripts/backup_firestore.py
  ls -lh Backend/Firebase/backups
  ```

- Confirm a new `Backend/Firebase/backups/backup-<timestamp>.json` file exists. Treat backup files as
  secret material because they can contain full WireGuard configs and client private keys.
