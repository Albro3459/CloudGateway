# Shared Subnet Mesh

Every mesh-enabled region has a WireGuard server peer and routes for each other mesh-enabled
region's tunnel subnet. Clients keep one full-tunnel connection to their own region and can reach
permitted remote tunnel addresses without changing config. Internet egress stays in the client's
own region. The [account-scoped ACL](access-control-list.md) controls forwarded access.

For recovery commands see [wireguard-drift-repair.md](wireguard-drift-repair.md). For the
membership runbook see [service-operations.md](service-operations.md#cross-region-mesh-enable--verify--rollback).
Deploy through [regional-deployment.md](regional-deployment.md) and
[Infrastructure/OCI/README.md](../Infrastructure/OCI/README.md).

Keep private keys, full configs, Firebase credentials, and client connection metadata out of logs
and tickets. Read live peer state on-screen only.

## 1. What the Mesh Is and Why It Exists

Each region owns a distinct `/24` IPv4 and `/64` IPv6 tunnel network. A server's peer for a remote
region carries that region's entire networks as `AllowedIPs`, with matching kernel routes on
`wg0`. The remote server delivers packets to its local client peers. Clients still use
`AllowedIPs = 0.0.0.0/0, ::/0` toward their own server.

The mesh provides routes and peers. Authorization belongs to the ACL, and internet egress is
never routed through another region.

### Aggregates

| Constant | Value | Defined in |
| --- | --- | --- |
| `MESH_AGGREGATE_V4` | `10.0.0.0/16` | `Backend/API/src/wireguard.py` |
| `MESH_AGGREGATE_V6` | `fd42:42:42::/48` | `Backend/API/src/wireguard.py` |

The aggregates bound candidate validation and route cleanup. No aggregate-wide route is installed.
Change these values together in:

* `Backend/API/src/wireguard.py`.
* `Infrastructure/OCI/terraform/subnet-registry.json` (`aggregate_v4` / `aggregate_v6`).
* `scripts/terraform-preflight.py` (`SUBNET_AGGREGATE_V4` / `SUBNET_AGGREGATE_V6`).
* `Infrastructure/OCI/host/bootstrap.sh` (`cg_tunnel4` / `cg_tunnel6`). These static nftables
  sets make the ACL deny new in-aggregate forwarded flows even when its dynamic maps are empty.

`Backend/API/tests/test_bootstrap_contract.py` checks bootstrap/API aggregate and object contracts.

## 2. Subnet Allocation Model

### The tracked registry

`Infrastructure/OCI/terraform/subnet-registry.json` is the non-secret allocation inventory.
Region tfvars are gitignored and each region has separate Terraform state, so the tracked registry
is the shared check against overlapping allocations.

```json
{
  "schema_version": 1,
  "aggregate_v4": "10.0.0.0/16",
  "aggregate_v6": "fd42:42:42::/48",
  "regions": [
    { "region_id": "us-sanjose-1", "wg_network_v4": "10.0.0.0/24", "wg_network_v6": "fd42:42:42::/64", "status": "active" },
    { "region_id": "us-chicago-1", "wg_network_v4": "10.0.1.0/24", "wg_network_v6": "fd42:42:42:1::/64", "status": "active" }
  ]
}
```

The top-level keys and entry keys must match this schema exactly. `schema_version` is integer `1`.
Status is `active` or `reserved`. Retain a decommissioned region as `reserved` so its allocation
is never reissued.

Before `plan`, `apply`, and `destroy`, `./scripts/terraform.sh` runs
`scripts/terraform-preflight.py`. It rejects:

* Missing or unexpected keys, wrong schema version, or aggregates that differ from the constants.
* Non-canonical networks, host bits, wrong family, unsupported widths, or networks outside the
  aggregates. Region networks must be `/24` and `/64`.
* Duplicate region IDs, overlapping networks in either family, or invalid status values.
* A selected region absent from the registry. `plan`/`apply` require `active`; `destroy` also
  accepts `reserved`.
* Present tfvars whose region or byte-for-byte networks do not match the registry. All present
  regional tfvars are also checked for pairwise overlap.

### Deriving a region's tunnel network and interface address

| Value | San Jose (index 0) | Chicago (index 1) |
| --- | --- | --- |
| `wg_network_v4` | `10.0.0.0/24` | `10.0.1.0/24` |
| `wg_network_v6` | `fd42:42:42::/64` | `fd42:42:42:1::/64` |
| `wg_address_v4` | `10.0.0.1/24` | `10.0.1.1/24` |
| `wg_address_v6` | `fd42:42:42::1/64` | `fd42:42:42:1::1/64` |
| `wg_dns_address_v4` | `10.0.0.1` | `10.0.1.1` |
| `wg_dns_address_v6` | `fd42:42:42::1` | `fd42:42:42:1::1` |

Terraform variable validation checks canonical family and width. Resource preconditions in
`Infrastructure/OCI/terraform/cloudgateway.tf` require the first host as the interface address,
DNS equal to that address, and an exact active registry match. These preconditions also protect
direct Terraform 1.6 `plan`/`apply` calls.

At runtime, `validate_local_tunnel_settings()` in `Backend/API/src/wireguard.py` checks the local
network/interface/DNS invariants from `/etc/cloudgateway/api.env` when constructing the manager.
It refuses to start on a mismatch.

Client indices run from `2` through `num_addresses - 2` of the IPv4 network (`.2` through `.254`
for a `/24`). Both families share the index. The allocator advances, wraps after 253 indices, and
skips indices still in use. Network, server/DNS, and IPv4 broadcast addresses are never issued.
See [Address Allocation](access-control-list.md#address-allocation) for recovery constraints.

## 3. State Model: Firestore Is the Source of Truth

`/etc/wireguard/wg0.conf` is interface-only. It contains no client or mesh `[Peer]` blocks.
Live peers and mesh routes are rebuilt from Firestore by `cloudgateway-sync-peers`. After a
`wg-quick` restart, run `sudo systemctl start cloudgateway-sync-peers.service` immediately
to restore them with the service's configured environment.

### `Regions/{regionId}`

| Field | Owner | Contract |
| --- | --- | --- |
| `regionId`, `displayName`, `displayOrder`, `capacityLimit` | host registration | Display fields come from tfvars |
| `wireguardEndpointIpv4`, `wireguardEndpointIpv6` | host | Discovered public addresses |
| `wireguardEndpointHostname`, `wireguardPort` | host | `wg.<regionId>.<origin>`, current port `51820` |
| `wireguardPublicKey` | host | Existing server keypair, shared by client and mesh peering |
| `wireguardDnsIpv4`, `wireguardDnsIpv6` | host | Interface addresses |
| `tunnelNetworkV4`, `tunnelNetworkV6` | host | Exact `/24` and `/64` |
| `tunnelIndexV4`, `tunnelIndexV6` | API | Paired client allocation cursors |
| `enabled` | host | Seeded false, set true only after full Cloudflare edge validation; a failed check leaves the stored value unchanged |
| `meshEnabled` | admin Web/iOS | Seeded false on creation, then preserved by registration |
| `updatedAt` | host | Firestore server timestamp |

`upsert_region()` seeds the flags transactionally, is idempotent, and never touches `Instances`.
Only literal `true` enables either flag. Missing fields and strings such as `"true"` are disabled.

### `Mesh/{regionId}`

Each host writes a full replacement snapshot at the end of a successful peer/route pass, while
holding the WireGuard lock:

```jsonc
{
  "regionId": "us-chicago-1",
  "meshEnabled": true,
  "updatedAt": "<server timestamp>",
  "peers": {
    "us-sanjose-1": {
      "status": "applied", // applied | skipped-overlap | skipped-incomplete
      "appliedAt": "<server timestamp>",
      "endpointHostname": "wg.us-sanjose-1.<origin>",
      "endpointPort": 51820,
      "publicKey": "<server public key>",
      "allowedNetworkV4": "10.0.0.0/24",
      "allowedNetworkV6": "fd42:42:42::/64"
    }
  }
}
```

* Removed peers disappear from the replacement document. All timestamps in one write share the
  server timestamp.
* Every skipped entry has a `reasonCode`. Incomplete entries retain valid metadata and may omit
  malformed fields. Parsers keep these entries as operator evidence.
* Status writes are best effort. Failure logs `mesh_status_write_failed` and returns
  `meshStatusWritten: false` without retrying or rolling back the applied state.
* Peer/route mutation failures leave the previous snapshot untouched. A snapshot proves what was
  reconciled, never a handshake or traffic reachability.

Types live in [Backend/Firebase/schema.ts](../Backend/Firebase/schema.ts).

### Access rules

[Backend/Firebase/firestore.rules](../Backend/Firebase/firestore.rules) allows users to read enabled
regions and admins to read all regions. Admin clients may update only `meshEnabled`, with a boolean
value. Endpoints, keys, networks, capacity, and `enabled` remain host-owned. `Mesh/*` is admin-read,
client-write-denied. Hosts write through the Admin SDK.

## 4. Computing the Desired Mesh

`desired_mesh_peers()` in `Backend/API/src/sync.py` validates region documents without mutating
state. Bad candidates become skip entries rather than aborting the pass.

### Gate and candidate selection

The local region must exist with both `enabled` and `meshEnabled` true. Otherwise the desired
mesh is empty, and reconciliation removes its existing mesh peers and routes. Candidates are all
other regions with both flags true. A region with only `meshEnabled` true is excluded.

### Per-candidate normalization

Candidate validation records the first failing check as `skipped-incomplete`.
`normalize_mesh_candidate()` handles field validation; duplicate-key detection runs before it:

| Reason code | Check |
| --- | --- |
| `missing-public-key` / `invalid-public-key` | Present, 44-character base64 key decoding to 32 bytes |
| `missing-endpoint-hostname` / `invalid-endpoint-hostname` | Valid hostname or IP literal |
| `invalid-endpoint-port` | Integer, never boolean, in `1-65535` |
| `missing-network-v4` / `invalid-network-v4` | Canonical strict IPv4 `/24` |
| `missing-network-v6` / `invalid-network-v6` | Canonical strict IPv6 `/64` |
| `outside-aggregate` | Both networks inside their fleet aggregates |
| `duplicate-public-key` | No other enabled region holds the key |

Duplicate-key checks include enabled regions even when their mesh flag is off. Every region
holding a duplicate key is excluded, so collection order cannot choose an owner.

### Cross-candidate and local checks

| Reason code | Result |
| --- | --- |
| `overlap-local` | `skipped-overlap`: either candidate network overlaps this host's configured network from `api.env` |
| `overlap-candidate` | `skipped-overlap`: two candidates overlap in either family, excluding both |
| `local-network-invalid` | `skipped-overlap` for otherwise valid candidates, with `mesh_local_network_invalid` logged |

Skip states are configuration failures. Fix the metadata or allocation before syncing again.

### Second line of defence

`validate_mesh_peers()` in `wireguard.py` repeats key, host, port, width, aggregate, overlap, and
duplicate-key checks at the mutation boundary. Rejected candidates are omitted. The first error
is raised only after the other reconciliation phases run, so bad mesh metadata cannot prevent
revoked-client removal.

## 5. Reconciliation: Mesh Peers vs Client Peers

`WireGuardManager.sync_peers()` handles client peers, mesh peers, and mesh routes in one pass.
There is no mesh timer or separate mesh sync.

### How mesh peers differ from client peers

| | Client peer | Mesh peer |
| --- | --- | --- |
| Source | Active local `Instances` | Eligible remote `Regions` |
| `AllowedIPs` | One `/32` and `/128` | One `/24` and `/64` |
| Endpoint | Learned from roaming client's handshake | Explicit hostname and port |
| Keypair | Per client | Region's server keypair |
| Keepalive | `25` | `25` |
| Apply | When desired addresses differ from live | Every pass, refreshing hostname resolution |
| Routes | Covered by interface network | Explicit remote-network routes |

Classification uses the desired mesh keys plus keys in all current region documents, including
disabled regions. A no-longer-desired peer is removed. A leftover key absent from current region
metadata is also removed, but cannot be attributed to a region by that metadata.

### Drift detection

`mesh_peer_drifted()` counts a live mesh peer as updated unless its endpoint address is still an
answer for the desired hostname, the port matches, `AllowedIPs` equals both desired networks, and
keepalive is `25`. Reapplication still happens on every pass even when no drift is counted.

Endpoint comparison uses a 5-second bound, one process-wide resolver worker, and a non-queueing
gate. A failed/timed-out comparison marks the peer drifted. `wg set` also resolves the hostname
and has a separate 20-second command timeout.

### Phase order and failure isolation

Client reconciliation also requires an enabled local region document. A missing or disabled
document produces an empty desired client set, so a sync removes existing unprotected client
peers as well as tearing down the mesh.

1. Add/update desired client peers whose addresses differ from live.
2. Remove live peers absent from desired client/mesh sets and protected client keys.
3. Reapply each validated mesh peer independently.
4. Reconcile routes.

Each mutation can fail independently. Remaining phases still run, `peer_sync_partial` records
successful changes and failure counts, then the first error is raised. Failed mutations do not
count as changes, and no success snapshot is written for a failed pass.

An active client with a valid key but corrupt/missing tunnel addresses is degraded: its existing
peer is protected from removal, although no replacement can be applied. `clientPeersDegraded`
reports the count without logging client details.

### Mesh route reconciliation

Runtime-added peers need explicit routes, because `wg-quick` only auto-routes peers in its file.
Each pass:

* Runs `ip -4|-6 route replace <cidr> dev wg0` for networks the interface can carry.
* Deletes non-kernel `dev wg0` routes inside the fleet aggregates that are neither desired mesh
  routes nor this host's own network. Routes outside the aggregates are untouched.
* Logs `mesh_route_reclaimed` at WARNING when a deleted CIDR belongs to no current region doc.
* Keeps a route when reapplication failed but the already-live peer still carries exactly the
  desired ranges. A candidate that never applied gets no route.

## 6. Endpoints and DNS

| Record | Terraform resource | Proxy | Purpose |
| --- | --- | --- | --- |
| `<regionId>.<origin>` | `cloudflare_record.api` | Proxied | HTTPS API |
| `wg.<regionId>.<origin>` | `cloudflare_record.wg` | DNS-only | WireGuard clients and mesh |

Both records use the instance's public IPv4 and refresh on rebuild. Mesh hostname reapplication
lets the next Sync All converge after a server replacement. WireGuard must never use a proxied
record.

An endpoint resolution/apply failure logs `mesh_peer_apply_failed` with infrastructure hostname
and port. Other candidates and route reconciliation still run, then the pass fails.

## 7. Enabling and Disabling a Region

`Regions/{regionId}.meshEnabled` is the only membership switch. There is no tfvars, environment,
or host-side switch, and changing membership needs no redeploy.

1. Toggle membership in admin Server Health on Web or iOS. This writes only Firestore.
2. Wait for the write, then Sync All Regions. Until sync, hosts retain their applied membership.
3. Verify the snapshots and live reachability.

Sync All is disabled while a membership write is unresolved. A confirmed sync waiting for a write
is shown as queued; if the write fails, the sync is dropped with a banner.

To remove a region, turn its flag off and Sync All. Its own pass removes all mesh peers/routes,
and others remove their peer/routes for it. Turning every flag off tears down the mesh.
`enabled: false` overrides membership and removes the region from Sync All targets, so its own
stale snapshot is not reported as pending.

## 8. Boot and Sync All

### At boot

1. `wg-quick@wg0` loads the interface-only config, the empty dynamic ACL objects with populated
   tunnel aggregates, and iptables/ip6tables forwarding, NAT, rate-limit, and DNS rules.
2. `cloudgateway-sync-peers` runs. A new region without a document gets a successful empty peer pass;
   an existing enabled region restores client and eligible mesh peers.
3. `cloudgateway-register-region` publishes endpoint/key/networks and sets `enabled: true` only
   after the Cloudflare edge path validates.
4. If registration returned `0`, a second sync applies the newly registered state. On registration
   failure this pass is skipped, because syncing a disabled document would remove local peers.

The oneshot unit uses `Restart=on-failure`, `RestartSec=30`, and `StartLimitIntervalSec=0`.
It retries failed peer/mesh passes indefinitely, then runs the ACL reconcile after a successful
peer pass. Peer failure exits `1`; policy-only failure exits `2` and also retries the whole pass.
A best-effort status-write failure exits `0`. See
[service-operations.md](service-operations.md#cloudgateway-sync-peersservice-firebase-peer-sync).

### On Sync All Regions

Web and iOS send one `POST https://<regionId>.<origin>/api/admin/sync` per enabled region in
parallel, including regions whose mesh flag is off so teardown can converge.

* Each endpoint syncs only itself and rejects another `regionId` in the body.
* The WireGuard lock is non-blocking. Contention returns `409 SYNC_IN_PROGRESS`.
* Each client request has a 45-second timeout. Timeout, proxy errors, incompatible responses,
  and contention are isolated to that region's result.
* After peer/mesh success, the same request runs a synchronous ACL policy reconcile. A policy
  failure reports `policyApplied: false` without changing peer/mesh results. A peer/mesh failure
  returns before the policy leg and leaves its previous status intact.

`POST /api/sync/refresh` is separate: client create/delete uses it to enqueue only the ACL map
refresh, returning `202` without mesh detail. See [api-contract.md](api-contract.md).

## 9. Failure Modes and How They Surface

| Condition | Evidence | Repair |
| --- | --- | --- |
| Missing/malformed metadata | `skipped-incomplete`, reason code, `meshSkipped` | Correct metadata, usually through registration, then Sync All |
| Duplicate server key | `duplicate-public-key`, all owners skipped | Rebuild/rekey the affected region, then Sync All |
| Overlapping subnets | `overlap-local` / `overlap-candidate` | Correct registry/tfvars, redeploy, Sync All |
| Invalid local networks | `local-network-invalid`, `mesh_local_network_invalid` | Fix local config and restart API; constructor validation can prevent startup |
| Endpoint/apply failure | `mesh_peer_apply_failed`, failed sync | Check DNS-only WireGuard record, Sync All |
| Route failure | `mesh_route_reconcile_failed`, `peer_sync_partial` | Resolve host error and run another pass |
| Unclaimed aggregate route | `mesh_route_reclaimed`, route removed | Investigate deleted/rewritten region metadata |
| Status write failure | `mesh_status_write_failed`, `meshStatusWritten: false` | Applied state remains, sync again to refresh status |
| Lock contention | `409 SYNC_IN_PROGRESS` | Wait, then retry |

### Reading Server Health

Web uses `Frontend/Web/src/helpers/meshHelper.ts`; iOS uses the shared
`CloudGatewayAppCore/CloudGatewayMeshStatus.swift`. Keep their derivation in sync. macOS has no
native Server Health UI. Use Web or iOS for admin management.

A region is **pending** when desired membership differs from its applied snapshot, or membership
is desired with no snapshot. Disabled regions are never pending.

One link row represents each unordered region pair:

| Status | Meaning |
| --- | --- |
| `both-applied` | Both directions recorded applied metadata matching the current peer region docs |
| `one-sided` | Only one direction is current; the link is not usable |
| `stale` | An applied entry uses outdated key, hostname, port, or network metadata |
| `not-synced` | Neither direction is current |

Link `pending` also covers removal still needed or desired directions that need refresh. An
unresolved configuration skip is a warning to fix, rather than pending work. Warnings retain the
judging host's region and plain-language reason.

`MESH_STALE_THRESHOLD_MS` is 24 hours. This is time-since-sync awareness, not drift or a handshake
health signal. Result cards show membership, applied/add/update/remove/skip counts, route changes,
status-write outcome, candidates, and the audit log. The mesh log section contains infrastructure
metadata only and no public keys. Sync responses omit mesh public keys; admin-readable durable
`Mesh` documents retain them. Treat client sections of the full audit log as sensitive.

## 10. Adding a New Region to the Mesh

1. Allocate an unused network pair in `Infrastructure/OCI/terraform/subnet-registry.json` as
   `active`. Never reuse a `reserved` allocation. Include the registry in deployment review.
2. Create `<regionId>.terraform.tfvars` from the example. Match registry networks exactly and
   set interface/DNS values to the first hosts.
3. Run `./scripts/terraform.sh <regionId> plan`, then `apply`, following
   [regional-deployment.md](regional-deployment.md). Preflight runs before Terraform actions.
4. Wait for registration and edge validation. Confirm `enabled: true`, both tunnel networks,
   key, hostname, and port. Missing networks produce skip entries on sibling hosts.
5. Turn on the new region's membership, wait for the write, then Sync All Regions.
6. Check every host on-screen:

```sh
sudo wg show wg0
sudo wg show wg0 latest-handshakes
sudo ip -4 route show dev wg0
sudo ip -6 route show dev wg0
```

Confirm subnet-width `AllowedIPs`, remote `/24` and `/64` routes, and recent handshakes after
sending test traffic. Check matching applied snapshots in `Mesh/*`, then prove same-account
client reachability across regions and run [ACL verification](acl-live-verification.md).

**Changing an existing subnet cuts off old client configs.** Nothing rewrites their addresses.
The previous Chicago cutover disabled mesh membership, synced all hosts, deleted that region's
`Instances` documents, updated registry/tfvars, redeployed, waited for registration, then re-enabled
membership and synced/verified. That is a destructive cutover requiring a deliberate recovery
plan, not a routine drift repair. Recreate affected clients on the new subnet.

**Decommissioning:** retain the registry allocation as `reserved`. `destroy` accepts it;
`plan`/`apply` do not.

## 11. Relationship to the Account-Scoped ACL

The mesh supplies routes and server peers. The ACL authorizes new forwarded tunnel flows by
account. They share the boot sync unit and Sync All, but use separate locks and status documents.
Status writes are best effort. A policy failure leaves mesh results intact; a peer/mesh failure
returns before the policy leg. Existing cards can therefore describe an older successful pass.

The static ACL tunnel sets must match the mesh aggregates. For slots, hashes, propagation,
account deletion, and activation on pre-ACL hosts, see [access-control-list.md](access-control-list.md).
