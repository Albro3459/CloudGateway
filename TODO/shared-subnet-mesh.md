# Shared Subnet Mesh: Cross-Region Peer-to-Peer

Goal: give every regional server its own tunnel subnet and bridge the servers together so a peer on one server can reach a peer on another server by tunnel IP. Subnet assignment is operator-managed in tfvars; bridging is reconciled from Firestore and triggered manually from the admin dashboard. Hard cutoff, no live clients to preserve (Chicago users recreate their clients).

Design decisions settled after discussion:

* **Manual-first sync, no timer.** Sync triggers are boot, a post-register pass at end of bootstrap, and the admin endpoint from the dashboard. Deploys and membership changes are rare and operator-driven (ready emails arrive per region, then the operator syncs from the dashboard). Periodic polling stays a documented future option.
* **Mesh membership lives only in Firestore.** `meshEnabled` on the region doc, default `false`, created by register and owned by the dashboard afterward. No tfvars var, no env var - a second copy in tfvars could disagree with Firestore and confuse things. Missing doc or missing field = not in the mesh.
* **No new keys.** Server-to-server links authenticate with each server's existing interface keypair (private key already in tfvars + `/etc/cloudgateway/wireguard-server.key`, public key already in the region doc). WireGuard's optional pairwise preshared key (post-quantum hardening) is explicitly skipped.
* **Hostname endpoints.** Mesh peers dial `wg.<regionId>.gocloudlaunch.com:51820`, the same grey-cloud record clients use, already stored as `wireguardEndpointHostname` in the region doc.
* Top-level `Mesh/{regionId}` status collection; admin-only Server Health page on the web dashboard (iOS later); no reserved subnet block (the whole `10.0.0.0/16` is for regions).

## Where We Are Today

Both regions currently use identical tunnel networks, which makes any bridging impossible until they are split:

| Region | wg_network_v4 | wg_network_v6 | DNS |
| --- | --- | --- | --- |
| us-sanjose-1 | `10.0.0.0/24` | `fd42:42:42::/64` | `10.0.0.1` / `fd42:42:42::1` |
| us-chicago-1 | `10.0.0.0/24` (same) | `fd42:42:42::/64` (same) | same |

Relevant facts from the current setup:

* `wg0.conf` is interface-only; peers are applied live with `wg set` and rebuilt from Firebase at boot by `cloudgateway-sync-peers` (`Backend/API/src/sync.py`). `sync_peers` removes **any** live peer not in the desired client set - a mesh peer added out-of-band would be stripped on the next sync. Mesh peers must become part of the desired set.
* Client configs use `AllowedIPs = 0.0.0.0/0, ::/0`, so clients already send all traffic through their server. **No client-side config change is needed** for cross-region routing; the routing decision happens entirely on the servers.
* The host firewall already allows `FORWARD -i wg0 ACCEPT` and `FORWARD -o wg0 ACCEPT`, so wg0-to-wg0 forwarding (client-to-client, and client-to-mesh-peer) is already permitted. NAT masquerade only applies `-o $PRIMARY_IFACE`, so cross-tunnel traffic keeps real tunnel source IPs. The `169.254.169.254` metadata DROP still applies. No firewall changes needed.
* Region docs in Firestore (`Regions/{regionId}`) already carry `wireguardPublicKey`, `wireguardEndpointHostname`, `wireguardPort` - almost everything a peer server needs. Missing: the region's tunnel CIDRs and mesh membership.
* `api.env` already carries `CLOUDGATEWAY_WG_TUNNEL_IPV4_CIDR` / `_IPV6_CIDR` per region, and `cloudgateway-register-region` already self-seeds the region doc at the end of bootstrap.
* Both servers have public IPs and listen on UDP 51820 (ingress already open `0.0.0.0/0` / `::/0`), so either side can initiate the server-to-server handshake. No OCI security-list changes needed.
* `POST /api/admin/sync` already exists per region - the manual trigger plumbing is mostly there.

## Subnet Plan (operator-managed in tfvars)

Region index N gets `10.0.N.0/24` and `fd42:42:42:N::/64`. All regions sit inside the aggregates `10.0.0.0/16` and `fd42:42:42::/48` (documentation-only aggregates; nothing routes them as a whole).

| Region | v4 network | server addr / DNS | v6 network | v6 addr / DNS |
| --- | --- | --- | --- | --- |
| us-sanjose-1 | `10.0.0.0/24` | `10.0.0.1` | `fd42:42:42::/64` | `fd42:42:42::1` |
| us-chicago-1 | `10.0.1.0/24` | `10.0.1.1` | `fd42:42:42:1::/64` | `fd42:42:42:1::1` |
| next region | `10.0.2.0/24` | `10.0.2.1` | `fd42:42:42:2::/64` | `fd42:42:42:2::1` |

Notes:

* `fd42:42:42::/64` **is** `fd42:42:42:0::/64`, so San Jose's v6 network is already slot 0 and does not change. San Jose keeps everything; existing SJ clients survive (a redeploy rebuilds the host, but the endpoint hostname re-resolves and boot sync restores peers).
* Chicago changes v4, v6, and both DNS IPs. Its client docs in Firestore hold `10.0.0.x` assignments and rendered configs with `DNS = 10.0.0.1`, all invalid after the cutover - they must be deleted so users recreate.
* This stays in per-region tfvars as today (`wg_address_v4`, `wg_network_v4`, `wg_dns_address_v4`, and v6 equivalents). No derived/indexed Terraform variable needed - but we should add a cross-region overlap preflight (below) since nothing currently stops two regions from shipping the same subnet, which is exactly the bug we have now.

## How the Bridge Actually Works

Server-to-server links ride the **same `wg0` interface** - no second interface, no nested tunnel, no MTU change (both hops are independent WG tunnels at MTU 1420). No new keys: each side authenticates with its existing interface keypair, exactly as it does with clients - a peer is a peer, whether it is an iPhone or another server.

Each server adds every other mesh-enabled region's server as a peer:

```
wg set wg0 peer <region.wireguardPublicKey> \
  endpoint wg.<regionId>.gocloudlaunch.com:51820 \
  allowed-ips 10.0.N.0/24,fd42:42:42:N::/64 \
  persistent-keepalive 25
```

Things `wg set` does **not** do that we must handle:

1. **Routes.** wg-quick only auto-installs routes for peers present in the conf file. Runtime peers get none. Today that is invisible because client allowed-ips fall inside the interface's own on-link `/24`. A remote region's subnet is not on-link, so after adding a mesh peer the sync must also run `ip -4 route replace 10.0.N.0/24 dev wg0` and `ip -6 route replace fd42:42:42:N::/64 dev wg0` (and delete routes when a mesh peer is removed). `replace` keeps it idempotent.
2. **Endpoint DNS resolution.** `wg set` resolves the hostname once, at set time. Each sync pass re-applies mesh peers unconditionally, which re-resolves.

**Why no periodic sync is needed for healing:** the server keypair lives in tfvars, so a rebuilt region comes back with the *same public key*. Its own boot sync re-adds all its peers (resolving their endpoints fresh) and initiates handshakes; when the other side receives a valid handshake from the new IP, WireGuard's built-in endpoint roaming updates its stored endpoint for that peer automatically. Rebuilds self-heal with no action on the other servers.

The one ordering gap: a **brand-new** region (new public key) that existing servers have never synced. If A finishes bootstrap before B exists, A won't have B as a peer; B's post-register sync adds A, but A drops B's handshakes until A syncs again. Closing it is the manual flow: wait for both ready emails, then sync from the dashboard.

Traffic path for peer P1 (SJ, `10.0.0.5`) to peer P2 (CHI, `10.0.1.7`):
P1 sends to `10.0.1.7` -> full-tunnel AllowedIPs push it into P1's tunnel -> SJ server FORWARD accepts, route `10.0.1.0/24 dev wg0` matches, WG cryptokey-routes it to the Chicago mesh peer (allowed-ips cover `10.0.1.0/24`) -> Chicago server receives, forwards out wg0 to P2's `/32`. Return path mirrors it. Source IPs are preserved end to end (no NAT on the wg0-to-wg0 path).

Same-server peer-to-peer already works today (hairpin through the server); this extends it across regions.

## Sync Model (manual-first)

One reconciliation job does everything: read Firestore, converge the live state - client peers, mesh peers, routes. It runs from:

* **Boot** - existing `cloudgateway-sync-peers.service` (client peers restored; mesh peers too, if this region is mesh-enabled in Firestore).
* **End of bootstrap** - one extra pass after `cloudgateway-register-region`, so the last-deployed region bridges to already-known regions immediately.
* **Admin dashboard** - a single "Sync All Regions" action that fans out `POST /api/admin/sync` (extended to cover mesh) to every enabled region; no per-region selection (see Web Dashboard Changes). This is the primary operational trigger: new server deployment -> ready emails arrive -> enable mesh in the dashboard -> Sync All.

No timer. Adding/removing servers and clients is infrequent and operator-driven, drift repair stays the manual one-command story it is today, and the "there is no periodic sync" contract in `docs/wireguard-drift-repair.md` stays true. **Future option:** a systemd timer (`OnCalendar=*:0/5` for UTC-aligned runs; simultaneous runs across servers are harmless since each host only mutates its own interface and writes its own status doc). Cost math if ever wanted: ~10 Firestore doc reads per pass, so 2 servers at 5 min ≈ 6k reads/day vs ~29k/day at 1 min against the 50k/day free tier.

### Mesh membership (`meshEnabled`)

* Lives **only** on the Firestore region doc. No tfvars var and no env var - a tfvars copy could disagree with Firestore and confuse things, and the server doesn't need the value before it can read Firestore because the answer to "what does a server do mesh-wise before its first sync?" is *nothing*.
* `cloudgateway-register-region` sets `meshEnabled: false` **only when creating** a brand-new region doc and never touches it again. Host-owned fields (IP, pubkey, endpoint, CIDRs) stay upserted every deploy; `meshEnabled` is operator-owned via the dashboard.
* Missing doc or missing field = not in the mesh. A new server cannot join the mesh by accident; joining requires the operator to flip the flag and run a sync.
* Desired mesh set for a server = enabled regions with `meshEnabled == true` and complete mesh fields, minus self. If the server's **own** flag is false, its desired mesh set is empty - a sync then also *removes* any existing mesh peers and routes.
* **Removing region C from the mesh:** flip C's flag off, sync all regions. A and B each see C fall out of their desired set and remove its peer + routes; C removes A and B. No SSH, no redeploy - this is the rollback story.

## Firestore Changes

**Region doc (`Regions/{regionId}`)** gains:

```
tunnelNetworkV4: "10.0.1.0/24"     // host-owned, upserted by register
tunnelNetworkV6: "fd42:42:42:1::/64"
meshEnabled: boolean                // operator-owned, created false by register, dashboard-toggled
```

These plus the existing `wireguardPublicKey` / `wireguardEndpointHostname` / `wireguardPort` fully define a mesh peer. Desired mesh state is therefore **derived** from region docs - no separate desired-state doc to keep in sync.

**New top-level `Mesh` collection** - observability/status only, one doc per region, written by that region's host after each sync pass:

```
Mesh/{regionId}:
  regionId: string
  updatedAt: timestamp
  peers: {
    [peerRegionId]: {
      endpointHostname: string
      publicKey: string            // peer server public key (already public data)
      allowedNetworkV4: string
      allowedNetworkV6: string
      status: "applied" | "skipped-overlap" | "skipped-incomplete"
      appliedAt: timestamp
    }
  }
```

* Server-to-server metadata only - no per-user data, no traffic/handshake stats, so it stays inside the logging boundary. (Deliberately not storing `latestHandshake`; it edges toward connection-history logging. `wg show wg0` on the host answers "is the link up" when debugging.)
* Firestore rules: `Mesh` gets `allow read: if isAdmin()`, writes stay Admin-SDK-only. Region docs need one new rule: admins may update **only** the `meshEnabled` key from the dashboard (`request.resource.data.diff(resource.data).affectedKeys().hasOnly(['meshEnabled'])`); everything else stays `allow write: if false`.
* This is the one place the peer sync writes to Firebase. Today's contract is "sync never writes to Firebase" (docs/wireguard-drift-repair.md) - the doc must carve out this status write, and the write must be best-effort (a Firestore write failure must not fail the sync).
* `schema.ts`, rules tests, and `firestore.indexes.json` (no new indexes expected) updated to match. `scripts/backup_firestore.py` walks all collections generically, so backups pick it up automatically.

## Backend/API Changes

`src/register.py` + `src/repository.py`

* `RegionRegistration` and `RegionDoc` gain `tunnel_network_v4` / `tunnel_network_v6` (registered from settings; the CIDR env vars already exist) and `RegionDoc` gains `mesh_enabled`.
* `upsert_region` writes the CIDRs every time and `meshEnabled: false` only on create.
* Repository gains a `write_mesh_status(...)` method (and the fake in `tests/fakes.py` mirrors it).

`src/wireguard.py`

* Today `_validate_ip_interface` enforces exactly `/32` + `/128` - correct for clients, wrong for mesh. Introduce a distinct mesh-peer type rather than loosening client validation:
  * `MeshPeer(public_key, endpoint_host, endpoint_port, allowed_network_v4, allowed_network_v6)` with subnet-width validation (must not equal or overlap the local networks).
  * `add_mesh_peer(...)` runs `wg set ... endpoint ... allowed-ips <cidrs> persistent-keepalive 25` then `ip route replace` for both CIDRs; removal also deletes the routes.
* `sync_peers` takes both desired sets (clients + mesh) and reconciles the union, so mesh peers survive client sync and unknown peers still get removed. Notes:
  * Mesh peers are **always re-applied** each pass (`wg set` is idempotent and cheap; this is also what re-resolves endpoints). Client peers keep the current compare-then-apply behavior.
  * Classify a live peer as "mesh" iff its public key matches a known region server key; everything else is judged against the client set. A region removed from the mesh falls out of the desired set and gets removed like any unknown peer - routes included.
* Route ops go through the same `_run` wrapper (`ip` is another root subprocess; same error handling, nothing logged beyond CIDRs).

`src/sync.py`

* `desired_peers` stays; add `desired_mesh_peers(repository, settings)`: enabled regions with `meshEnabled == true`, minus self, minus any region missing pubkey/CIDRs (`skipped-incomplete`), minus any region whose claimed CIDRs overlap the local networks or another region's (`skipped-overlap`, logged loudly - a region doc claiming someone else's subnet would otherwise blackhole traffic). Empty set when the local region's own flag is false or its doc is missing.
* After a successful pass, best-effort `write_mesh_status`.
* Audit log (`build_sync_audit_log`) gains a mesh section (region IDs and CIDRs only).

`src/routes.py` (`POST /api/admin/sync`)

* Gets mesh reconciliation for free once `run_sync` includes it. Extend `AdminSyncResponse` with mesh counts/statuses so the dashboard can trigger-and-see. `docs/api-contract.md` updated to match.

## Web Dashboard Changes (`Frontend/Web/`)

Admin-only **Server Health** page (web only; iOS later once we're happy with it). The existing sync modal (`Home.tsx` + `RegionSyncCard.tsx`) already fans out `POST /api/admin/sync` per region and shows per-region counts + audit logs; it currently preselects all enabled regions with per-region checkboxes.

* **Drop region selection: "Sync All Regions" is the only sync action.** Mesh changes are inherently all-region operations - a partial sync leaves the mesh half-applied (e.g. toggling C off and syncing only C still leaves A and B holding C's peer and routes until they sync). Client-drift repair on one region is harmless to run everywhere (idempotent; untouched regions report "no changes"). The modal lists every region it will sync, then renders the existing per-region result cards (extended with mesh counts); a failed region shows its failure card and the retry is simply Sync All again.
* Sync All targets all *enabled* regions regardless of `meshEnabled` - a region leaving the mesh needs a sync to remove its peers.
* Region list with existing health/enabled state plus mesh state from `Mesh/*` docs (per-peer status, `updatedAt` staleness warning - visibility matters more in a manual-sync world since nothing self-heals unnoticed).
* `meshEnabled` toggle per region (direct Firestore update under the narrow rules change above). Toggles change nothing on any host until a sync runs, so show a "pending - not yet applied" state by comparing each region's `meshEnabled` flag against what its `Mesh/*` doc says was last applied, and light up Sync All when anything is pending.

## Host / Bootstrap Changes (`Infrastructure/OCI/host/bootstrap.sh`)

* Run one sync pass *after* `cloudgateway-register-region` at the end of bootstrap (the existing early sync runs before registration; the final pass lets the last-deployed region bridge to already-known mesh regions immediately).
* No timer unit. No wg0.conf changes: it stays interface-only, and the interface `Address`/`PostUp` lines already come from tfvars, which carry the new per-region values.
* No AdGuard/Unbound changes: clients keep using their own region's DNS. (Cross-region clients cannot query the *remote* region's DNS IP - AdGuard binds only the local tunnel DNS IPs and allowlists only the local networks. That's fine and arguably correct.)

## Terraform / Deploy Script Changes

* `Infrastructure/OCI/terraform/cloudgateway.tf`: no new variables. Optional: variable validation that `wg_dns_address_v4` ∈ `wg_network_v4`, etc.
* `terraform.tfvars.example`: document the subnet-per-region scheme and the reserved aggregates; add the "next region bumps the third octet / fourth hextet" instructions.
* `us-chicago-1.terraform.tfvars`: `wg_address_v4 = "10.0.1.1/24"`, `wg_network_v4 = "10.0.1.0/24"`, `wg_dns_address_v4 = "10.0.1.1"`, `wg_address_v6 = "fd42:42:42:1::1/64"`, `wg_network_v6 = "fd42:42:42:1::/64"`, `wg_dns_address_v6 = "fd42:42:42:1::1"`. (Gitignored - operator edit.)
* `scripts/terraform-preflight.py`: add a subnet-uniqueness check across **all** `*.terraform.tfvars` present (not just the regions being deployed): no two regions may have equal or overlapping `wg_network_v4`/`wg_network_v6`, and each region's address/DNS must sit inside its own networks. This is the programmatic guard for the operator-managed scheme.
* `scripts/terraform.sh`: nothing structural. Deploying `chicago sanjose` in one invocation already cuts one tag and applies both; bridging happens via register + post-register sync + the operator's dashboard sync once the ready emails arrive.

## Cutover / Rollout Order

1. Land all code/docs changes; both regions need the new API anyway, so both get redeployed.
2. Delete Chicago's client docs (`Regions/us-chicago-1/Instances/*`) - their `10.0.0.x` assignments and rendered configs are invalid under the new subnet. (Hard cutoff per plan; SJ docs untouched.)
3. Edit `us-chicago-1.terraform.tfvars` with the new subnet values.
4. `./scripts/terraform.sh chicago sanjose` - one deploy tag, both instances rebuild. Rebuilds are the normal path; SJ clients survive via endpoint DNS re-resolve + boot peer sync.
5. Each host registers itself (now with tunnel CIDRs; existing region docs keep their `meshEnabled` value, which starts absent/false).
6. Ready emails arrive. In the dashboard: enable `meshEnabled` for both regions, then "Sync all regions".
7. Verify: `wg show wg0` on each host shows the other server's key with subnet-width allowed-ips and a recent handshake; `ip route` shows the remote subnets on wg0; two test clients in different regions ping each other's tunnel IPs; `Mesh/*` docs show `applied`.
8. Chicago users recreate clients from the dashboard/app as usual.

Rollback = mesh membership: flip `meshEnabled` off (one region or all), sync all regions; every host converges to peers-and-routes-removed. Documented in service-operations.

## Security / Privacy Notes

* Cross-region bridging extends the existing intra-region reality: any active client can reach any other active client's tunnel IP, now across regions. All clients are provisioned by us for known users, but if per-user isolation is ever wanted, it becomes an iptables FORWARD policy question (allow client-to-client only within an owner's peers) - out of scope here, worth a future TODO.
* Mesh peers are added only from region docs written via the Admin SDK by our own hosts (plus the narrow admin-only `meshEnabled` toggle); a compromised regional host could already tamper with Firestore, so the mesh does not add a new trust boundary - but the overlap guard in `desired_mesh_peers` prevents a bad region doc from hijacking another region's subnet on healthy hosts.
* No pairwise preshared keys: WG's optional PSK layer would need per-pair distribution for marginal benefit here; interface keys already authenticate both ends.
* The `Mesh` docs and audit log stay server-metadata-only (region IDs, CIDRs, public keys, endpoints). No per-user connection history, no handshake timestamps in Firestore.
* Region docs are readable by any signed-in user (rules); adding tunnel CIDRs and `meshEnabled` there exposes nothing sensitive (endpoint + public key are already there, and `10.0.N.0/24` is guessable).

## What Needs To Change (checklist)

* [ ] `Backend/API/src/repository.py` - `RegionDoc`/`RegionRegistration` tunnel CIDRs + `mesh_enabled`, mesh-status write, mesh validation helpers
* [ ] `Backend/API/src/register.py` - publish tunnel CIDRs; `meshEnabled: false` on create only
* [ ] `Backend/API/src/wireguard.py` - `MeshPeer`, subnet-width validation, endpoint/keepalive support, route management, union sync
* [ ] `Backend/API/src/sync.py` - desired mesh set, overlap/incomplete guards, status write, audit log section
* [ ] `Backend/API/src/routes.py` + `models.py` - admin sync response mesh fields
* [ ] `Backend/API/src/firebase.py` - Firestore reads/writes for the above
* [ ] `Backend/API/tests/*` - fakes + coverage for all of the above
* [ ] `Frontend/Web/` - admin Server Health page: mesh status, `meshEnabled` toggles with pending-state, Sync All Regions replacing per-region selection
* [ ] `Infrastructure/OCI/host/bootstrap.sh` - post-register sync pass
* [ ] `Infrastructure/OCI/terraform/terraform.tfvars.example` - subnet scheme docs
* [ ] `us-chicago-1.terraform.tfvars` (local, gitignored) - new subnet values
* [ ] `scripts/terraform-preflight.py` (+ its tests) - cross-region subnet overlap check
* [ ] `Backend/Firebase/schema.ts`, `firestore.rules`, rules tests - region fields, `Mesh` collection, admin `meshEnabled`-only update rule
* [ ] Docs: `Infrastructure/OCI/README.md`, `docs/regional-deployment.md`, `docs/wireguard-drift-repair.md` (mesh in the sync + the status-write carve-out; "no periodic sync" stays true), `docs/service-operations.md` (mesh on/off runbook), `docs/api-contract.md`
* [ ] Validation: `./scripts/test.sh api web infra firebase`
