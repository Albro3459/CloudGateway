# API deployment handoff

The contract between [host bootstrap](../Infrastructure/OCI/host/bootstrap.sh)
and the [regional API](../Backend/API/README.md). Request/response details live in
[API contracts](api-contract.md); operator commands live in
[service operations](service-operations.md).

## Install layout

* API: `/opt/cloudgateway/api`, installed from `Backend/API/pyproject.toml`.
* Virtualenv: `/opt/cloudgateway/api/.venv`.
* Service: `cloudgateway-api.service`, running as root from that directory.
* ASGI app: `src.main:app`, bound only to `127.0.0.1` on the configured port.
* Environment: `/etc/cloudgateway/api.env`, root-owned mode `0600`.

## Environment

Bootstrap writes these `CLOUDGATEWAY_`-prefixed settings. Local development
defaults in [settings.py](../Backend/API/src/settings.py) are not production
configuration.

* Routing: `REGION_ID`, `API_PORT` (default `8000`), `API_HOSTNAME`, and
  `DASHBOARD_CORS_ORIGIN`.
* Credentials: `FIREBASE_CREDENTIALS_FILE` points to the server-only credential file.
* WireGuard: `WG_INTERFACE` (default `wg0`), `WG_SERVER_PUBLIC_KEY`,
  `WG_ENDPOINT_HOSTNAME`, `WG_PORT` (default `51820`), `WG_DNS_IPV4`, `WG_DNS_IPV6`,
  `WG_TUNNEL_IPV4_CIDR`, and `WG_TUNNEL_IPV6_CIDR`.
* Registration: `REGION_DISPLAY_NAME`, `REGION_DISPLAY_ORDER`, and
  `REGION_CAPACITY_LIMIT`.
* SES email: `SES_REGION`, `SES_SENDER`, `AWS_ACCESS_KEY_ID`, and
  `AWS_SECRET_ACCESS_KEY`.

Treat the environment file as secret. Parse it with systemd, never shell-source
it. To retry registration after Firebase was unavailable during bootstrap:

```sh
sudo systemd-run --quiet --pipe --wait --collect \
  --property=WorkingDirectory=/opt/cloudgateway/api \
  --property=EnvironmentFile=/etc/cloudgateway/api.env \
  /opt/cloudgateway/api/.venv/bin/cloudgateway-register-region
```

## Subnets and peer state

`Infrastructure/OCI/terraform/subnet-registry.json` owns regional allocations
and shared aggregates. Local tfvars must match the selected registry subnets.
Keep retired entries as `status: "reserved"`; missing tfvars do not release them.

Firebase owns desired peers. Bootstrap writes interface-only `wg0.conf` once;
never persist peers there or in another host file. `cloudgateway-sync-peers`
rebuilds the live interface at boot/on demand and removes unknown server peers.
API mutations and matching Firebase writes hold `/run/cloudgateway-wireguard.lock`.
Sync best-effort writes server-only `Mesh/{regionId}` status under that lock;
a status-write failure does not fail an otherwise successful sync.

## Replacement and host policy

Before replacement, take a [Firestore backup](../Backend/Firebase/README.md#backup-script)
and confirm the new timestamped file. Backups can contain configs/private keys.
Keep the server key, subnets, and endpoint hostname unchanged. Validate the rebuilt
API, live peer state, and updated DNS before leaving the region enabled. Clients
may need to re-resolve the endpoint after its public IP changes.

Account isolation uses `inet cloudgateway` nftables policy loaded by WireGuard
`PostUp`; restarting the API does not install it. `cloudgateway-install-api`
checks ACL-aware refs for a live `cg_forward` chain and `cg_slot4`/`cg_slot6` maps
before copying source or restarting. Missing policy stops the upgrade untouched.
The unsupported `CLOUDGATEWAY_ALLOW_UNSAFE_API_UPGRADE=1` bypass leaves the account
boundary unenforced and is an emergency-only escape hatch.

Deploy host-level policy changes by rebuilding every region from one deploy tag,
then run **Sync All Regions** after all are ready. Sequential rollout provides
only partial fleet enforcement until the last region is ready. See
[service operations](service-operations.md) for ACL/mesh sequencing and recovery.
