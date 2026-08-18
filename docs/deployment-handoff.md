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

## Replacement handoff

A normal rebuild is self-healing. Keep the region's WireGuard private key, tunnel
subnets, and endpoint hostname unchanged; boot sync rebuilds peers from Firebase
and WireGuard endpoint roaming handles a new public IP. Check `wg show` on the
rebuilt host and validate the API before leaving the region enabled.

## Account-scoped ACL rollout

The account-scoped ACL is host-level: the `inet cloudgateway` nftables table is
loaded by `PostUp`, which only runs when `wg0` transitions from down to up, not
on an API restart. `cloudgateway-install-api` checks the incoming ref for
`Backend/API/src/policy.py` and, if present, requires `nft list table inet
cloudgateway` to show the `cg_forward` chain and the `cg_slot4`/`cg_slot6` maps
before it copies the new API or restarts the service; otherwise it exits 1
without touching the host. This release therefore ships only by rebuilding
every region through `./scripts/terraform.sh` from one deploy tag, never by
`cloudgateway-install-api` alone. The check has a documented, unsupported
escape hatch (`CLOUDGATEWAY_ALLOW_UNSAFE_API_UPGRADE=1`) that leaves the
account boundary unenforced and is for genuine emergencies only. During a
sequential multi-region rebuild the fleet is only partially enforced; the ACL
is not active until the last region finishes.

For mesh changes, follow [service-operations.md](service-operations.md). After
all Terraform regions are deployed and ready, run **Sync All Regions** from the
admin dashboard.

## Firestore backup

- Before a regional deploy or host replacement, back up Firestore from the repo root:

  ```sh
  Backend/API/.venv/bin/python3 scripts/backup_firestore.py
  ls -lh Backend/Firebase/backups
  ```

- Confirm a new `Backend/Firebase/backups/backup-<timestamp>.json` file exists. Treat backup files as
  secret material because they can contain full WireGuard configs and client private keys.
