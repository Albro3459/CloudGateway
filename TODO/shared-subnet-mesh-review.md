# Shared Subnet Mesh Review

Reviewed: 2026-08-13

Status: discussion document only. No production code or live infrastructure was changed during this review.

## Executive assessment

The implementation is on the right path for the current two-region, undeployed hard cutover:

* San Jose remains on `10.0.0.0/24` and `fd42:42:42::/64`.
* Chicago moves to `10.0.1.0/24` and `fd42:42:42:1::/64`.
* Chicago client documents are deleted and users recreate clients. No legacy address migration or compatibility layer is needed.
* Firestore remains desired state, while `/etc/wireguard/wg0.conf` remains interface-only.
* Runtime sync reconciles the union of client peers, server mesh peers, and explicit remote-subnet routes.
* The subnet registry, Terraform preflight, runtime overlap checks, strict API response handling, and dashboard status model are good defense-in-depth choices.

The branch passes the selected API, web, infrastructure, and Firebase validation targets. The default repository gate also includes Apple validation, which was not part of the command recorded below. The remaining concerns are mainly rollout gates, security-policy decisions, and operational convergence. They do not justify restoring legacy compatibility, drain lifecycle code, or Chicago address migration.

The live cutover should not proceed until the rollout gates below are resolved or explicitly accepted.

## Review inputs

This review used:

* `TODO/shared-subnet-mesh.md` and all branch changes from `main`.
* The prior T3 implementation thread `c5f8310e-edce-4ef7-af9f-05f9fde139fa`, recovered through `t3-session`. A Luna agent parsed the normalized projection first and then the provider JSONL with `rg` and `jq`; the main agent did not read the massive raw thread.
* Independent design, implementation, operations, and security reviews.
* The selected repository-supported validation targets:

```sh
./scripts/test.sh api web infra firebase
```

The command passed with API compile, Pyright, Vulture, and tests; web Jest, TypeScript, Knip, and production build; infrastructure Terraform and script validation; and Firebase emulator tests. Apple validation was not run because this branch does not change Apple code. `git diff --check` also passed, and the working tree remained clean after validation.

The prior thread's conclusion that no verified findings remained after its bounded implementation review is not contradicted by this document. This review identified additional live-state, deployment, trust-boundary, and network-policy concerns that the repository test suite cannot prove.

## Rollout gates

### Gate 1 — Prove the OCI underlay does not overlap the tunnel aggregates

**Priority:** Blocker before live cutover.

The registry and preflight validate WireGuard allocations against each other, but they do not prove that the OCI VCN, instance subnet, host routes, or another connected network do not overlap `10.0.0.0/16`, `fd42:42:42::/48`, or an allocated regional subnet.

Terraform receives an opaque `subnet_id` rather than the subnet CIDR (`Infrastructure/OCI/terraform/cloudgateway.tf:49`). Runtime reconciliation installs remote routes in the host's main routing table using `ip route replace <cidr> dev wg0` (`Backend/API/src/wireguard.py:496`). An overlapping OCI route could therefore blackhole VCN traffic, redirect ordinary host traffic into WireGuard, or make the tunnel allocation ambiguous.

**Required decision:** choose one of these before deployment:

1. Extend preflight to query OCI subnet and VCN CIDRs and reject overlap with every active or reserved WireGuard allocation and aggregate.
2. Require explicit underlay CIDRs in deployment inputs and validate them locally.
3. For this first cutover, manually prove and record the live San Jose and Chicago VCN/subnet/host-route non-overlap, then add automated enforcement before adding another region.

A manual verification is acceptable for the initial two undeployed regions only if it is recorded as a completed rollout gate. The preferred durable direction is automated preflight validation.

### Gate 2 — Verify the WireGuard port across Firestore, hosts, tfvars, and OCI ingress

**Priority:** Blocker before live cutover.

The current plan already requires verification and backfill of `wireguardPort` on all existing Region documents (`TODO/shared-subnet-mesh.md:51`, `TODO/shared-subnet-mesh.md:82`). That prerequisite is correct and remains incomplete.

There is also a configuration consistency gap:

* Terraform accepts any numeric `wg_listen_port` (`Infrastructure/OCI/terraform/cloudgateway.tf:115`).
* Host firewall rules use that configured port (`Infrastructure/OCI/host/bootstrap.sh:164`).
* OCI prerequisites document fixed UDP ingress on `51820` (`Infrastructure/OCI/README.md:114`).
* The mesh design specifies regional endpoints on port `51820` (`TODO/shared-subnet-mesh.md:12`).

A valid non-51820 tfvars value could be registered and advertised while OCI still drops the traffic.

**Recommended direction:** if CloudGateway intentionally uses a fixed port, enforce `wg_listen_port == 51820` in Terraform/preflight and validate the registered Firestore value. If configurable ports are intentional, OCI ingress must be Terraform-managed or otherwise verified against the same setting. Do not rely on documentation alone.

### Gate 3 — Use an exact, auditable Chicago client-deletion procedure

**Priority:** Blocker before changing the Chicago subnet.

The hard cutoff is correct, but the repository does not provide a dedicated region-wide deletion operation for `Regions/us-chicago-1/Instances/*`. Browser rules intentionally reject client writes (`Backend/Firebase/firestore.rules:62`), and existing bulk deletion behavior is account-scoped rather than cutover-scoped.

A manual console deletion can omit documents or target the wrong region. Because the plan intentionally forbids inspecting or migrating old addresses, the deletion mechanism should be more precise, not less.

**Recommended direction:** create an operator-only Admin SDK command or documented one-off procedure that:

1. Requires the exact region ID `us-chicago-1`.
2. Displays the number of matching instance documents.
3. Requires explicit confirmation of that region and count.
4. Deletes only that region's `Instances` subcollection.
5. Verifies that zero documents remain.
6. Does not print client configs, keys, assigned addresses, tokens, or private metadata.

This should not become a user-facing API and does not need to support migration.

### Gate 4 — Decide the intended cross-region forwarding policy

**Priority:** Security decision before enabling mesh.

The current host rules insert unconditional forwarding accepts for traffic entering or leaving `wg0` for both IPv4 and IPv6 (`Infrastructure/OCI/host/bootstrap.sh:160`). Mesh route reconciliation applies each remote `/24` and `/64` to `wg0` (`Backend/API/src/wireguard.py:496`). This enables cross-region client-to-client reachability, which matches the stated peer-to-peer goal, but also expands the blast radius of a compromised client.

The existing rules are broader than a policy limited to allocated mesh subnets. IPv4 blocks OCI metadata, but IPv6 has no equivalent management-network policy, and there is no explicit segmentation between client-to-client, client-to-mesh, Internet egress, and private OCI destinations.

**Decision required:**

* If every VPN client is intentionally allowed to reach every other client in every mesh-enabled region, record that as an accepted security property and document the tenant/lateral-movement consequence.
* If the goal is narrower, add explicit forwarding chains that permit only the required regional tunnel networks and deny OCI metadata, management, VCN, and other private ranges for both address families.

Do not enable the mesh until the intended policy is explicit. Route correctness is not an access-control policy.

### Gate 5 — Define success and rollback as all-region convergence

**Priority:** Operational blocker for declaring rollout complete; not necessarily a distributed-transaction requirement.

Sync is intentionally regional and non-atomic. The dashboard fans out requests with `Promise.allSettled` (`Frontend/Web/src/helpers/APIHelper.ts:590`), and each API mutates only its local WireGuard state before attempting best-effort status publication (`Backend/API/src/sync.py:339`). A region can therefore apply a peer and route while the other region fails, producing a one-sided link or temporary blackhole. The dashboard reports per-region outcomes but does not itself enforce that the operator treats a partial result as an incomplete rollout.

This is acceptable as an eventual-consistency model if the operator workflow fails closed. It does not require a cross-region distributed transaction for this release.

**Required rollout behavior:**

1. Sync All must report success for every participating region.
2. Both `Mesh/{regionId}` documents must show current bilateral `applied` snapshots.
3. Live peers, AllowedIPs, routes, handshakes, and bidirectional tunnel reachability must be verified.
4. A one-sided or stale result means rollout is incomplete, not partially successful.
5. Rollback is not complete until peer and route removal is verified on every affected host.

**Recommended follow-up:** add bounded retry/backoff or a dedicated reconcile command. A desired-generation identifier may become useful if more regions or automated rollouts are added, but it is not required for the initial two-region cutover.

## Important trust-boundary decisions

### Regional hosts use project-wide Firebase Admin credentials

**Priority:** Explicitly accept or reduce before production use.

Each regional host receives Firebase Admin credential material when `firebase_credentials_json` is rendered into the host credential file (`Infrastructure/OCI/terraform/stub-cloud-init.sh.tftpl:74`), and the API initializes the Firebase Admin SDK from that file (`Backend/API/src/firebase.py:65`). Admin SDK access bypasses browser Firestore rules, including the rule that browser clients cannot write `Mesh` documents (`Backend/Firebase/firestore.rules:50`).

Compromise of one regional host therefore appears capable of affecting project-wide Regions, Mesh status, users, and client documents. The mesh increases the impact because corrupted region metadata can remove peers, redirect endpoints, or advertise conflicting routes.

This is not a newly introduced credential leak, and no private credentials were found in responses or logs. It is an architectural blast-radius decision.

**Preferred direction:** use least-privilege service accounts or split regional client operations from global region/mesh control-plane operations. If that is deferred, document that any regional-host compromise is treated as a project-wide control-plane compromise and include credential rotation and mesh reconciliation in incident recovery.

### Endpoint metadata is syntactically validated but Admin-SDK-authoritative

**Priority:** Clarify policy; lower priority than the rollout gates.

Runtime validation checks endpoint syntax, port range, keys, and CIDRs, but does not require the hostname to equal the Terraform-managed `wg.<regionId>.<origin>` name. Corrupted Admin-SDK-written metadata can therefore cause outbound UDP attempts to another valid hostname. WireGuard key authentication prevents an unrelated endpoint from becoming a valid peer without the matching private key, but does not prevent redirection attempts or operational confusion.

**Decision:** either enforce the expected hostname pattern or explicitly document endpoint metadata as trusted host-registration/Admin-SDK-controlled state within the Firebase Admin trust boundary.

## Deployment and lifecycle follow-ups

### Enforce the no-mixed-version rule for future upgrades

The initial cutover can keep mesh disabled until both regions run the current version, as already documented (`docs/regional-deployment.md:127`). Terraform applies regions sequentially (`scripts/terraform.sh:293`), so a later incompatible mesh/API release can leave a mixed deployment if an early region succeeds and a later region fails.

Before future incompatible upgrades, require mesh to be disabled and removal fully converged. A deployment preflight should eventually refuse an incompatible rollout while participating regions remain mesh-enabled. This is not a reason to add old-response normalization now.

### Define the full-mesh scale limit

The current topology is appropriate for two regions. For `N` mesh-enabled regions, it creates `N - 1` server peers per region and `N(N - 1)/2` logical links overall. Document an operational threshold before adding many regions. Beyond that threshold, evaluate hub-and-spoke, regional gateways, or a topology controller.

No topology redesign is needed for San Jose and Chicago.

### Add bounded automatic reconciliation later

Manual-first sync is reasonable during development. The boot `cloudgateway-sync-peers` service retries failed syncs every 30 seconds (`Infrastructure/OCI/host/bootstrap.sh:695`), but DNS changes, endpoint replacement, mesh toggles, and best-effort status-write failures can still leave live state or observability state stale until another sync trigger.

Add a periodic timer, queue, or control-plane-triggered reconcile after the two-region cutover is proven. Any health mechanism must preserve the privacy rule against logging traffic, DNS queries, destination data, packet metadata, per-user connection history, full configs, private keys, or tokens.

### Mesh status is not link health

`Mesh/{regionId}` correctly represents last-applied reconciliation state, not handshake or reachability truth. Keep this distinction. The live rollout checklist must require `wg show`, route inspection, and bidirectional cross-region traffic tests. A future active probe should avoid creating per-user connection history.

### Stale `creating` reservations remain a general operational issue

A crashed client-creation flow can leave a `creating` document consuming an address or capacity. The Chicago deletion removes existing Chicago reservations during cutover, but the general issue remains. Add an age-bounded operator cleanup command or reaper later. This is not specific to the mesh and is not a cutover blocker unless stale documents prevent the required Chicago zero-document verification.

## Validated decisions to keep

The following choices should not be reopened without a new requirement:

1. **Hard cutoff for Chicago.** Delete all Chicago clients and require recreation. Do not add address migration or legacy compatibility.
2. **Distinct exact-width networks.** Use `/24` IPv4 and `/64` IPv6 allocations, with `.1` and `::1` as interface and DNS addresses.
3. **Authoritative subnet registry.** Keep tracked allocation state in `Infrastructure/OCI/terraform/subnet-registry.json`, with tfvars matching enforced by preflight.
4. **Runtime overlap defense.** Keep runtime validation even when Terraform preflight passes because Firestore metadata can drift or be corrupted.
5. **Existing server keypairs.** Reuse each server's WireGuard interface keypair; pairwise keys are unnecessary.
6. **Interface-only `wg0.conf`.** Continue rebuilding peers and routes from Firestore rather than persisting peer blocks.
7. **Union reconciliation.** Reconcile client peers, mesh peers, and routes in one local locked pass; remove unknown peers and stale managed routes.
8. **Strict current schema.** Keep explicit incompatible-response failures. Do not normalize old Mesh/API response shapes for an undeployed feature.
9. **Missing `meshEnabled` means false.** This safely handles pre-feature Region documents without enabling mesh accidentally.
10. **No silent port fallback.** Live `wireguardPort` must be verified and backfilled rather than silently assuming 51820.
11. **Dashboard-derived pending state.** Do not create a second durable pending state machine in the backend.
12. **Status writes are best effort.** A Firestore observability failure should not falsely report that a successful live WireGuard mutation failed; the dashboard must continue to expose stale or missing status.
13. **No generic drain lifecycle.** Normal rebuilds retain key, subnet, hostname, and membership; permanent decommission remains a separate future workflow.
14. **No Apple work in this PR.** The admin Server Health workflow is web-only for now.

## Proposed cutover checklist

This refines, but does not replace, the hard-cutoff order in `TODO/shared-subnet-mesh.md`:

- [ ] Record OCI VCN, subnet, and relevant host routes for both regions; prove no overlap with the WireGuard aggregates or regional allocations.
- [ ] Decide and document the cross-region client forwarding and isolation policy.
- [ ] Verify OCI ingress, tfvars, host configuration, and every Region document agree on the WireGuard port.
- [ ] Backfill missing `wireguardPort` and current tunnel CIDRs while mesh remains disabled.
- [ ] Disable Chicago mesh membership and run Sync All Regions.
- [ ] Verify Chicago peers and routes are absent from every participating host before changing the subnet.
- [ ] Run the exact Chicago instance-deletion procedure and verify `Regions/us-chicago-1/Instances` is empty.
- [ ] Update `subnet-registry.json` and the live gitignored Chicago tfvars to `10.0.1.0/24` and `fd42:42:42:1::/64`, with `.1` and `::1` interface/DNS addresses.
- [ ] Build and validate every regional Terraform plan before applying any region.
- [ ] Apply the prepared San Jose and Chicago plans through one controlled multi-region wrapper invocation. The wrapper applies them sequentially; if one region fails, keep mesh disabled and repair the partial deployment before proceeding.
- [ ] Wait for registration and regional health checks; verify both regions expose the current admin sync response shape.
- [ ] Explicitly enable only the intended mesh regions and run Sync All Regions.
- [ ] Require successful sync results from every participating region.
- [ ] Verify bilateral Mesh snapshots, live peer keys, exact `/24` and `/64` AllowedIPs, endpoint ports, routes, recent handshakes, and bidirectional tunnel reachability.
- [ ] Verify Chicago users can recreate clients and receive only Chicago's new subnet addresses.
- [ ] Record rollback verification steps: disable membership, Sync All, then prove peer and route removal on all affected hosts.

## Recommended scope before deployment

### Must complete or explicitly accept

1. Underlay overlap verification.
2. WireGuard port and OCI ingress consistency.
3. Auditable Chicago client deletion.
4. Explicit forwarding/lateral-access policy.
5. All-region convergence and rollback verification procedure.
6. Firebase Admin credential blast-radius decision.

### Good code changes before deployment

1. Add automated underlay CIDR overlap validation to preflight.
2. Enforce fixed port 51820 or validate/manage matching OCI ingress.
3. Add a narrowly scoped Chicago region-deletion operator command.
4. Add explicit host firewall policy if unrestricted client lateral access is not intended.

### Safe to defer after the two-region cutover

1. Automatic periodic reconciliation or bounded retries.
2. Desired-generation rollout tracking.
3. Full-mesh scale threshold and alternate topology.
4. Stale `creating` reservation reaper.
5. Active mesh reachability probes.
6. Apple administration UI.

## Current conclusion

The core mesh design and branch implementation are suitable for the intended hard-cutover direction. The code is strongly validated and no high-confidence new production-code security vulnerability was found.

The operator accepted manual Chicago client deletion, unrestricted pre-release client-to-client routing, regional partial-sync failure, and the Firebase Admin credential blast radius. The regional WireGuard port remains fixed at `51820`. The remaining live prerequisites are the one-time OCI overlap check, the Chicago tfvars update, the hard-cutoff deletion and deployment sequence, and bilateral post-deployment verification.

The dashboard now uses a 45-second per-region Sync All timeout, treats `local-network-invalid` as a persistent configuration failure, and renders an explicit initial loading state. Backend tests now cover partial peer and route mutation failures followed by successful next-sync convergence.
