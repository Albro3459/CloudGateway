# Shared Subnet Mesh: Cross-Region Peer-to-Peer

Goal: give every regional server its own tunnel subnet and bridge mesh-enabled servers so a peer on one server can reach a peer on another by tunnel IP. Subnet allocation is operator-managed and authoritative in `subnet-registry.json`; bridging is reconciled from Firestore and triggered by boot, registration, or the admin dashboard.

## Architectural decisions

* **Hard cutoff, no migration.** The mesh PR is unmerged and undeployed. There are no Mesh documents and no mixed mesh versions to support. Chicago clients are disposable: before changing the Chicago subnet, delete every `Regions/us-chicago-1/Instances/*` document. Do not inspect, migrate, retain, or validate old assigned tunnel addresses.
* A future subnet change uses the same hard cutoff. If mesh is live, disable that region's mesh membership and Sync All, delete all clients, change the registry and tfvars, deploy, then explicitly re-enable mesh and Sync All.
* **Manual-first sync, no timer.** Sync runs at boot, once after registration, and through the dashboard's Sync All Regions action. Periodic polling remains a possible future option.
* **Mesh membership lives only in Firestore.** `meshEnabled` is operator-owned, defaults to false on creation, and is not duplicated in tfvars or environment variables. Only literal `true` enables a region or mesh membership; missing and every other value are false.
* **No new keys.** Server links use each server's existing WireGuard interface keypair. No pairwise preshared keys are required.
* **Hostname endpoints.** Mesh peers use `wg.<regionId>.gocloudlaunch.com:51820`, the existing grey-cloud client endpoint hostname.
* `Mesh/{regionId}` is status and observability only. The admin-only Server Health page is web-only for this PR; iOS support can follow later.

## Lifecycle and operational assumptions

Normal server replacement must not disable the Region or mesh membership. A normal rebuild keeps the same WireGuard key, tunnel subnet, and endpoint hostname. Boot sync re-adds peers, and WireGuard endpoint roaming updates the remote peer when the rebuilt server handshakes from a new public address. No drain lifecycle is needed.

`enabled=false` means no operational server exists in that region. Permanent region decommission is a separate, explicit future operation: remove the region from desired state and Sync All before permanent deletion. This PR does not require generic decommission automation.

The following direction is removed from this plan and checklist: `region-lifecycle.py`, `drainRequestedAt`, prepare-drain, verify-drain, Terraform apply/destroy drain gates, repeated per-target lifecycle verification, and transactional drain snapshots.

## Current state and subnet plan

Both regions currently use the same tunnel networks, so bridging is impossible until Chicago moves:

| Region | Current v4 | Current v6 | Planned v4 | Planned v6 |
| --- | --- | --- | --- | --- |
| us-sanjose-1 | `10.0.0.0/24` | `fd42:42:42::/64` | `10.0.0.0/24` | `fd42:42:42::/64` |
| us-chicago-1 | `10.0.0.0/24` | `fd42:42:42::/64` | `10.0.1.0/24` | `fd42:42:42:1::/64` |
| next region | — | — | `10.0.2.0/24` | `fd42:42:42:2::/64` |

Each region uses an exact `/24` IPv4 interface network and `/64` IPv6 interface network. The interface address is the `.1`/`::1` address and DNS equals that interface address. Region networks derive from the allocation slot and remain inside aggregate `10.0.0.0/16` and `fd42:42:42::/48`; the aggregates are documentation-only and are not routed as a whole.

`subnet-registry.json` is the authoritative non-secret allocation inventory because tfvars are gitignored. Terraform preflight and `terraform.sh` must validate registry uniqueness and overlap, aggregate containment, active/reserved status, and an exact match between the selected region's registry allocation and tfvars before deployment. Runtime skipped-overlap protection remains load-bearing corruption protection against bad Firestore data; it is not legacy compatibility.

## How the bridge works

Server-to-server links use the same `wg0` interface. Each mesh-enabled server adds every other eligible mesh-enabled region as a peer with subnet-width AllowedIPs and `persistent-keepalive 25`, then installs routes for the remote `/24` and `/64` on `wg0`. Runtime peers need explicit route management because `wg set` does not install routes. Mesh peers are reapplied on every sync so endpoint hostnames resolve again; WireGuard endpoint roaming handles a remote rebuild without requiring a sync on the other host.

Client configs already use full-tunnel AllowedIPs, and existing forwarding permits wg0-to-wg0 traffic without NAT. No client, firewall, MTU, or OCI ingress change is required. A peer in San Jose can therefore reach a Chicago peer through the remote subnet route, with tunnel source addresses preserved.

## Sync and Firestore model

One reconciliation pass converges client peers, mesh peers, and routes. It runs from boot, the post-register bootstrap pass, and `POST /api/admin/sync` fan-out from Sync All Regions. Sync All targets all enabled regions, including a region whose `meshEnabled` is false, so removal converges everywhere.

Desired mesh peers are enabled regions other than self with complete, valid current metadata. Malformed metadata is isolated per candidate. `skipped-incomplete` and `skipped-overlap` are configuration failures or warnings while the condition persists, never pending. Pending means valid desired state differs from live state and Sync All can change live state. Once invalid or overlapping metadata is corrected, the candidate becomes pending until Sync All applies it.

There is no legacy normalization. `applied` and `skipped-overlap` records must contain the complete current snapshot, including `endpointPort`; `skipped-incomplete` may omit whichever fields are missing or invalid and must preserve its reason code. Responses missing the current `meshUpdated` shape are incompatible. The dashboard requires the current API response shape: an incompatible response renders an explicit failure card and must never crash. There is no mixed-version rollout.

Existing pre-feature Region documents are the one real schema rollout case. Missing `meshEnabled` is treated as false; registration backfills tunnel CIDRs; mesh remains disabled until all regions are updated. Malformed metadata must not prevent valid regions from progressing. If current Region documents are known to carry `wireguardPort`, verify and backfill it as a prerequisite rather than defaulting missing values to `51820`.

Region documents contain host-owned tunnel CIDRs and operator-owned `meshEnabled`:

```text
Regions/{regionId}
  tunnelNetworkV4
  tunnelNetworkV6
  meshEnabled
```

`Mesh/{regionId}` contains only server metadata and per-peer status such as endpoint hostname, public key, allowed networks, endpoint port, and `applied`, `skipped-incomplete`, or `skipped-overlap` status. Status writes are best effort and never make sync fail. Firestore rules permit admins to update only `meshEnabled`; Mesh reads are admin-only and writes remain Admin-SDK-only.

## Backend and dashboard requirements

The API must reconcile the union of client and mesh peers, remove unknown peers and routes, reject duplicate server public keys, and expose strict current sync counts/statuses. Mesh candidate validation must check keys, endpoint, port, exact network widths, local-network conflicts, and cross-candidate overlap.

The Server Health page shows region enabled state, mesh state, status freshness, per-peer results, and configuration failures. Toggling `meshEnabled` changes no host until Sync All. Auth generation changes must clear syncing and toggling state so controls cannot remain disabled after a session refresh. Live endpoint drift is current when the live endpoint address is one of the DNS answers and the port matches. CloudGateway manages one grey-cloud A record and no AAAA record, so this is cheap defensive correctness.

## Terraform and deploy requirements

* Fix Terraform DNS/interface comparison to canonicalize and compare the address component, not `cidrhost(interfaceCIDR, 0)`.
* Enforce strict booleans: only literal `true` enables Region or mesh; all other values are false.
* Keep `wg0.conf` interface-only; runtime peers and routes are applied by sync.
* Keep the planned Chicago values: `10.0.1.1/24`, `10.0.1.0/24`, DNS `10.0.1.1`, `fd42:42:42:1::1/64`, `fd42:42:42:1::/64`, DNS `fd42:42:42:1::1`.
* Preflight must validate every present tfvars allocation against the registry, including inactive and reserved allocations as appropriate, and reject overlap or aggregate violations before deployment.

## Cutover and rollback

1. Remove the implemented drain and legacy-compatibility machinery and complete the agreed validation fixes.
2. Before the Chicago subnet change, delete every `Regions/us-chicago-1/Instances/*` document without inspecting or migrating addresses.
3. Edit the live, gitignored `us-chicago-1.terraform.tfvars` to the planned subnet values.
4. Deploy Chicago and San Jose together with the normal Terraform flow.
5. Let registration backfill current tunnel CIDRs. Keep mesh disabled until all Region documents are updated.
6. After ready emails, explicitly enable mesh for the intended regions and run Sync All Regions.
7. Verify routes, WireGuard peers/handshakes, cross-region tunnel reachability, and Mesh status documents. Chicago users recreate clients.

Rollback of mesh membership is explicit: disable the affected `meshEnabled` flags and Sync All Regions. A future subnet change repeats the hard cutoff; it is not an address migration. Disabled-region drain concerns are inapplicable because `enabled=false` means the region is dead.

## Accepted and out-of-scope review findings

* Account-deletion local/remote peer races are accepted for this PR.
* Destroy applying a newly generated plan is accepted.
* Client old-address migration is rejected by the hard cutoff.
* Permanent decommission automation is not required.
* Per-target repeated lifecycle verification and transactional drain-snapshot concerns are removed with the drain system.

## Checklist and status

Checked items are implemented and validated on the branch. Live operator actions and newly agreed cleanup/fixes remain unchecked.

* [x] Region registration and repository models publish tunnel CIDRs and create `meshEnabled: false`.
* [x] WireGuard mesh peers, subnet-width validation, routes, union reconciliation, and endpoint reapplication.
* [x] Sync desired mesh calculation, malformed-metadata isolation, overlap protection, status write, and audit output.
* [x] Admin sync API, Firestore access/rules/schema, and Server Health Sync All UI.
* [x] Post-register bootstrap sync and subnet documentation.
* [x] Authoritative subnet registry, exact registry/tfvars matching, aggregate/status validation, fixed `/24`/`/64` invariants, and cross-region overlap preflight.
* [ ] Remove `region-lifecycle.py`, `drainRequestedAt`, prepare-drain/verify-drain, and Terraform drain-gate direction from implementation, docs, and follow-ups.
* [ ] Remove legacy applied/skipped response normalization and missing-`endpointPort`/missing-`meshUpdated` compatibility.
* [ ] Implement strict boolean handling and strict current sync-response failure cards.
* [ ] Fix Terraform address-component DNS/interface comparison.
* [ ] Implement pending versus persistent configuration-failure semantics, auth-generation state reset, and multi-address endpoint drift comparison.
* [ ] Edit live `us-chicago-1.terraform.tfvars`.
* [ ] Delete Chicago client documents, deploy the cutover, enable mesh, Sync All, and perform live verification.

Previous full validation passed before this direction change. Validation must be rerun after the cleanup and agreed fixes.
