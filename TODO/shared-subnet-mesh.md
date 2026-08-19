# Shared Subnet Mesh: Completed PR Plan

Status: fully implemented on the `shared-subnet` branch.

## Goal

Give each regional server its own tunnel subnet and connect mesh-enabled regions so a peer on one server can reach a peer on another by tunnel IP. The implementation covers subnet allocation, WireGuard reconciliation, Firestore state, regional APIs, the web dashboard, and the iOS admin Server Health surface.

## Completed implementation plan

### 1. Establish the subnet and state model

* Use `subnet-registry.json` as the authoritative non-secret allocation inventory. Each region has an exact `/24` IPv4 network and `/64` IPv6 network inside `10.0.0.0/16` and `fd42:42:42::/48`.
* Store host-owned tunnel CIDRs and the operator-owned `meshEnabled` flag on `Regions/{regionId}`. New regions default to `meshEnabled: false`; only literal `true` enables a region or mesh membership.
* Keep `Mesh/{regionId}` as status and observability data. Admins can update only `Regions/{regionId}.meshEnabled`; Mesh writes remain Admin-SDK-only.
* Validate registry uniqueness, overlap, aggregate containment, active/reserved status, and exact registry-to-tfvars matches before Terraform deployment. Runtime overlap protection remains enabled for corrupted Firestore data.

### 2. Reconcile client and mesh peers together

* Run one reconciliation pass for client peers, mesh peers, and routes at boot, after registration, and through the admin Sync All Regions action. There is no timer or legacy migration path.
* Keep `wg0.conf` interface-only. Runtime mesh peers use the existing server WireGuard keypairs, hostname endpoints, subnet-width AllowedIPs, and `persistent-keepalive 25`; routes for remote `/24` and `/64` networks are managed explicitly on `wg0`.
* Reconcile the union of desired client and mesh peers, remove unknown peers and routes, reject duplicate server keys, and reapply mesh endpoints on every sync so endpoint roaming and server replacement continue to work.
* Validate mesh keys, endpoint hostnames, ports, exact network widths, local-network conflicts, and cross-candidate overlap. Isolate malformed candidates, preserve an already-live peer when its active record has a valid key but malformed tunnel metadata, and still remove peers for revoked or inactive records.
* Write best-effort Mesh status with strict current response shapes and region-scoped audit output. Do not log private keys, full configs, emails, client names, tunnel IPs, or traffic metadata.

### 3. Complete the API, Firestore, and dashboard workflow

* Add the admin sync fan-out across all enabled regions, including regions whose mesh membership is disabled so removal converges everywhere.
* Isolate regional failures: a timeout, non-JSON proxy error, incompatible response, or `409 SYNC_IN_PROGRESS` affects only that region's result. Sync requests use a 45-second regional timeout and classify an already-running sync separately from a generic failure.
* Expose strict mesh counters, peer snapshots, status, and `meshStatusWritten` in the current sync response. `appliedAt` and `updatedAt` are Firestore server timestamps from the same status write.
* Implement the web Server Health page with mesh membership toggles, pending and persistent configuration states, link status, warnings, status freshness, Sync All Regions, and per-region results with safe expandable logs.
* Keep toggling as a Firestore-only change until Sync All runs. Clear in-flight state on auth-generation changes and retire optimistic overrides when superseded reads complete.

### 4. Add the iOS Server Health surface

* Port mesh validation, status derivation, warning text, link rows, staleness, and strict sync-response parsing into shared `CloudGatewayAppCore` code for iOS and future macOS reuse.
* Replace the per-region iOS sync action with an admin-only Server Health page. It reads `Regions/*` and `Mesh/*`, writes only `meshEnabled`, fans out syncs in parallel, and re-reads durable Mesh status after the fan-out.
* Match the web behavior for mesh toggles, pending state, warnings, link statuses, per-region counts, `409` handling, incompatible responses, and sign-out protection. Use a 45-second timeout only for admin sync requests.
* Use a monotonic load generation so an older refresh cannot overwrite a newer toggle reload. Keep pending reload bookkeeping correct across identity changes and remove the obsolete single-region sync API and result view.
* Export sync logs with `ShareLink`; never write sensitive sync logs to disk or application logs.

### 5. Perform the Chicago cutover and deployment

* Keep San Jose on `10.0.0.0/24` and `fd42:42:42::/64`. Move Chicago to `10.0.1.0/24` with interface/DNS addresses `10.0.1.1`, and to `fd42:42:42:1::/64` with interface/DNS address `fd42:42:42:1::1`.
* Before the subnet change, disable Chicago mesh membership, run Sync All Regions, and delete every `Regions/us-chicago-1/Instances/*` document without migrating old addresses.
* Verify current `wireguardPort` and tunnel CIDRs, update the registry and live Chicago tfvars, deploy Chicago and San Jose, let registration backfill state, then explicitly enable mesh and run Sync All Regions.
* Verify routes, WireGuard peers and handshakes, cross-region tunnel reachability, and Mesh status. Chicago clients are recreated on the new subnet; this is a hard cutoff, not an address migration.

### 6. Close review findings and validate

* Isolate malformed API client records; fix web optimistic-override retirement and login account-switch invalidation; add iOS load-generation and pending-reload protection.
* Promote `validate_port`, use server timestamps for `appliedAt`, correct unknown mesh reason handling in web and Swift, consolidate the remaining login attempt state, and remove obsolete lifecycle/drain compatibility code.
* Complete the bounded review, documentation cleanup, and full validation gate. `./scripts/test.sh` passed across API, web, Apple, infrastructure, and Firebase targets on 2026-08-16.

## Delivered state

The cutover completed on 2026-08-13/14. The repository backup records both regions with populated tunnel CIDRs and `wireguardPort: 51820`, Chicago clients on `10.0.1.0/24`, `meshEnabled: true` for both regions, and each `Mesh/*` document containing the other region as an `applied` peer. The implementation, review fixes, documentation, and validation are complete; no additional work remains for this PR.
