# Shared Subnet Mesh

Cross-region WireGuard server-to-server mesh. Each regional server owns a distinct tunnel subnet
inside a shared aggregate, and every mesh-enabled region carries a WireGuard peer plus routes for
every other mesh-enabled region. A client attached to one region can therefore reach a client (or
a server) in another region by tunnel IP, without a second tunnel and without any client-side
config change.

This is the durable reference for the feature: the allocation model, the state model, how peers
are computed and reconciled, and how it is operated. For host command-level recovery see
[wireguard-drift-repair.md](wireguard-drift-repair.md); for the enable/verify/rollback runbook see
[service-operations.md](service-operations.md#cross-region-mesh-enable--verify--rollback); for
deployment see [regional-deployment.md](regional-deployment.md) and
[Infrastructure/OCI/README.md](../Infrastructure/OCI/README.md).

Secrets hygiene applies as everywhere else: reference peers by region ID or public key, never
paste private keys, full configs, Firebase credentials, or host public IPs into tickets or logs.

## 1. What the Mesh Is and Why It Exists

Before the mesh, every region was an island: each server NATed its clients to the internet, and a
client on one region had no route to any address on another. The tunnel address space was also
identical across regions, so two regions could not have been bridged even if a route existed.

The mesh solves both problems at once:

* **Disjoint addressing.** Every region gets an exact `/24` IPv4 and `/64` IPv6 tunnel network
  inside one shared pair of aggregates, so every tunnel address in the fleet is globally unique.
* **Server-to-server links.** Each mesh-enabled region adds every other mesh-enabled region's
  server as a WireGuard peer whose `AllowedIPs` are that region's whole `/24` and `/64`, plus a
  matching kernel route on `wg0`. Traffic to a remote tunnel address leaves through the local
  server, crosses the server-to-server link, and is delivered by the remote server to its own
  client peer.

The mesh is server infrastructure only. Client configs are unchanged by it: a client still has one
peer (its own region's server) with `AllowedIPs = 0.0.0.0/0, ::/0`, so remote tunnel addresses are
already inside its default route.

Two things the mesh deliberately does not do:

* It does not authorize anything. Whether two clients may actually exchange packets is decided by
  the account-scoped ACL - see [access-control-list.md](access-control-list.md). The mesh only
  provides reachability; the ACL decides who uses it.
* It does not carry client internet egress across regions. Egress still NATs out of the client's
  own region.

### Aggregates

| Constant | Value | Defined in |
| --- | --- | --- |
| `MESH_AGGREGATE_V4` | `10.0.0.0/16` | `Backend/API/src/wireguard.py` |
| `MESH_AGGREGATE_V6` | `fd42:42:42::/48` | `Backend/API/src/wireguard.py` |

Nothing ever routes an aggregate as a whole. They exist as a bound: a candidate tunnel network is
rejected unless it is a subnet of the matching aggregate, and the mesh route sweep only considers
routes inside them, so it can never delete an unrelated route on `wg0`.

The same two values appear in three other places and must be changed in all of them together:

* `Infrastructure/OCI/terraform/subnet-registry.json` as `aggregate_v4` / `aggregate_v6`.
* `scripts/terraform-preflight.py` as `SUBNET_AGGREGATE_V4` / `SUBNET_AGGREGATE_V6`, which
  requires the registry's aggregates to equal them exactly.
* `Infrastructure/OCI/host/bootstrap.sh`, as the `cg_tunnel4` / `cg_tunnel6` nftables interval
  sets in the `inet cloudgateway` table. **`cg_tunnel4`/`cg_tunnel6` mirror
  `MESH_AGGREGATE_V4`/`MESH_AGGREGATE_V6`**: they are what makes the ACL's empty-map boot state
  fail closed, because a forwarded packet whose destination falls inside the tunnel aggregate is
  dropped unless it is explicitly paired. `Backend/API/tests/test_bootstrap_contract.py` checks
  the aggregates (and the table/object names) offline against the API renderer, so a change on one
  side fails the build until it is made on the other.

## 2. Subnet Allocation Model

### The tracked registry

`Infrastructure/OCI/terraform/subnet-registry.json` is the authoritative, non-secret inventory of
regional tunnel allocations. It is tracked in git deliberately: the per-region
`<regionId>.terraform.tfvars` files are gitignored (they carry keys and OCIDs), each region has its
own Terraform workspace and state, and no live system enumerates allocations before handing one
out. Without a tracked registry there would be no place where "which `/24` belongs to which
region" is reviewable, diffable, or checkable at deploy time, and a second region could silently
be given an overlapping subnet - which, because cryptokey routing is exclusive, would break both.

```json
{
  "schema_version": 1,
  "aggregate_v4": "10.0.0.0/16",
  "aggregate_v6": "fd42:42:42::/48",
  "regions": [
    { "region_id": "us-sanjose-1", "wg_network_v4": "10.0.0.0/24", "wg_network_v6": "fd42:42:42::/64",   "status": "active" },
    { "region_id": "us-chicago-1", "wg_network_v4": "10.0.1.0/24", "wg_network_v6": "fd42:42:42:1::/64", "status": "active" }
  ]
}
```

The top level must contain exactly `schema_version`, `aggregate_v4`, `aggregate_v6`, `regions`, and
each region entry exactly `region_id`, `wg_network_v4`, `wg_network_v6`, `status`. `status` is
`active` or `reserved`. A decommissioned region's allocation stays in the file as `reserved` rather
than being deleted, so its addresses are never reissued to a different region.

`scripts/terraform-preflight.py` runs before every `plan`, `apply`, and `destroy` through
`./scripts/terraform.sh`, and fails the deploy on any of:

| Check | Rejects |
| --- | --- |
| Schema | `schema_version` not integer `1`; unexpected or missing keys at either level |
| Aggregates | `aggregate_v4`/`aggregate_v6` not exactly the constants above |
| Canonical form | A network string with host bits set, the wrong family, or a non-canonical spelling |
| Prefix width | Any `wg_network_v4` not `/24`, any `wg_network_v6` not `/64` |
| Uniqueness | A duplicate `region_id` |
| Containment | A region network outside its aggregate |
| Overlap | Any pair of region networks overlapping in v4 or v6 |
| Status | A `status` other than `active` or `reserved` |
| Selection | The selected region absent from the registry; for `plan`/`apply`, an allocation that is `reserved` rather than `active` (`destroy` accepts `reserved`, since a decommissioned region still has to be torn down) |
| tfvars match | A local tfvars `wg_network_v4`/`wg_network_v6` that is not byte-identical to its registry entry, or a `region_id` with no registry entry |

Preflight also cross-checks every other present tfvars file for pairwise overlap, so a mistake in
a region you are not deploying is still caught.

### Deriving a region's tunnel network and interface address

Given allocation index `N` (the `/24`'s third octet and the `/64`'s fourth hextet), the whole
regional address plan is determined:

| Value | Derivation | `us-sanjose-1` (N=0) | `us-chicago-1` (N=1) |
| --- | --- | --- | --- |
| `wg_network_v4` | `10.0.N.0/24` | `10.0.0.0/24` | `10.0.1.0/24` |
| `wg_network_v6` | `fd42:42:42:N::/64` | `fd42:42:42::/64` | `fd42:42:42:1::/64` |
| `wg_address_v4` | first host of the v4 network, `/24` | `10.0.0.1/24` | `10.0.1.1/24` |
| `wg_address_v6` | first host of the v6 network, `/64` | `fd42:42:42::1/64` | `fd42:42:42:1::1/64` |
| `wg_dns_address_v4` | equal to `wg_address_v4`'s address | `10.0.0.1` | `10.0.1.1` |
| `wg_dns_address_v6` | equal to `wg_address_v6`'s address | `fd42:42:42::1` | `fd42:42:42:1::1` |

This is enforced three times, independently:

* **Terraform variable validation** (`Infrastructure/OCI/terraform/cloudgateway.tf`) requires
  `wg_network_v4` to be a canonical IPv4 `/24` and `wg_network_v6` a canonical IPv6 `/64`.
* **Terraform resource preconditions** on `oci_core_instance.generated_oci_core_instance` require
  the address vars to derive exactly those networks, to be the first host (`.1` / `::1`), the DNS
  addresses to equal the interface addresses, and `region_id` to select exactly one `active`
  registry entry whose networks match the tfvars exactly. Preconditions rather than cross-variable
  validation blocks, so this stays safe on Terraform 1.6 for a direct `plan`/`apply`.
* **The API at runtime** - `validate_local_tunnel_settings()` in `Backend/API/src/wireguard.py`
  re-derives the same invariants from `/etc/cloudgateway/api.env` when the WireGuard manager is
  constructed, and refuses to start on a mismatch. A region whose host config was edited by hand
  cannot serve with an inconsistent plan.

Client addresses come out of the same `/24`/`/64` from index `2` upward
(`repository.region_tunnel_index_bounds`: `2` through `num_addresses - 2`, i.e. `.2` to `.254` for
a `/24`), paired so a client's v4 and v6 share one index. The v4 range is what bounds the
allocator, so a region wraps after roughly 253 lifetime allocations and skips indices still in
use. Index `0` (network), `1` (server/DNS), and the v4 broadcast address are never issued.

## 3. State Model: Firestore Is the Source of Truth

Peers are **never** written to `/etc/wireguard/wg0.conf`. That file is interface-only
(`[Interface]` with `Address`, `ListenPort`, `PrivateKey`, and the `PostUp`/`PostDown` firewall and
nftables lines) and contains no `[Peer]` block of any kind - not for clients, not for mesh. The
live `wg0` peer set and the mesh routes on `wg0` are a disposable projection of Firestore, rebuilt
from scratch by `cloudgateway-sync-peers` on every pass. A `wg-quick` restart therefore empties the
peer set until the next sync, which is exactly why
[service-operations.md](service-operations.md#wg-quickwg0-wireguard) tells operators to run
`sudo cloudgateway-sync-peers` immediately after one.

### `Regions/{regionId}`

Two owners, cleanly split.

| Field | Written by | Notes |
| --- | --- | --- |
| `regionId`, `displayName`, `displayOrder`, `capacityLimit` | host (`cloudgateway-register-region`) | Display fields come from tfvars |
| `wireguardEndpointIpv4`, `wireguardEndpointIpv6` | host | Discovered public addresses |
| `wireguardEndpointHostname` | host | `wg.<regionId>.<origin>`; the mesh endpoint |
| `wireguardPort` | host | UDP listen port (`51820` in the current fleet) |
| `wireguardPublicKey` | host | The server keypair, shared by client and mesh peering |
| `wireguardDnsIpv4`, `wireguardDnsIpv6` | host | Equal to the interface addresses |
| `tunnelNetworkV4`, `tunnelNetworkV6` | host | This region's exact `/24` and `/64` - the mesh `AllowedIPs` |
| `tunnelIndexV4`, `tunnelIndexV6` | API | Client address allocator cursor; not mesh state |
| `enabled` | host | Seeded `false` on create; set `true` only once the full Cloudflare edge path validates. A failed edge check leaves the stored value untouched |
| `meshEnabled` | operator (admin dashboard / iOS) | Seeded `false` on document creation and never written by the host again |
| `updatedAt` | host | Firestore server timestamp |

`upsert_region()` performs the create-or-update inside a Firestore transaction so that the
create-only seeding of `enabled: false` and `meshEnabled: false` cannot race a concurrent
registration. Registration is idempotent and touches only the region document - never the
`Regions/{regionId}/Instances` subcollection.

Only literal `true` counts. `mesh_enabled=data.get("meshEnabled") is True` and
`enabled=data.get("enabled") is True`, so a missing field, a string `"true"`, or any other truthy
value reads as disabled.

### `Mesh/{regionId}`

Observability only. Each region's own host writes its own document at the end of a sync pass,
while still holding the WireGuard lock, describing what that host judged and applied.

```jsonc
{
  "regionId": "us-chicago-1",
  "meshEnabled": true,            // what this host actually reconciled for itself
  "updatedAt": "<server timestamp>",
  "peers": {
    "us-sanjose-1": {
      "status": "applied",        // applied | skipped-overlap | skipped-incomplete
      "appliedAt": "<server timestamp>",
      "endpointHostname": "wg.us-sanjose-1.<origin>",
      "endpointPort": 51820,
      "publicKey": "<server public key>",
      "allowedNetworkV4": "10.0.0.0/24",
      "allowedNetworkV6": "fd42:42:42::/64"
      // "reasonCode": present on every skip, optional on applied
    }
  }
}
```

Properties worth knowing:

* The write is a **full replacement**, not a merge. A peer that fell out of the desired set
  disappears from the document instead of lingering as a stale entry.
* `updatedAt` and every peer's `appliedAt` are Firestore server timestamps taken from that single
  write, so all peers in one document share an `appliedAt`.
* A `skipped-incomplete` entry may omit any of the metadata fields - the malformed value is simply
  absent - and always carries a `reasonCode`. That absence is operator evidence, so parsers on
  both surfaces keep the entry rather than discarding it.
* The write is **best effort**. A Firestore failure here is logged (`mesh_status_write_failed`) and
  never fails, retries, or rolls back an already-successful reconciliation; the sync response
  reports `meshStatusWritten: false` instead. The wire is correct, only the snapshot is stale.
* The document proves a reconciliation snapshot, not a handshake. It records what the host applied,
  not whether packets flow. Use `wg show wg0` for live link state.

The TypeScript shapes are in [Backend/Firebase/schema.ts](../Backend/Firebase/schema.ts)
(`FirebaseRegionDoc`, `FirebaseMeshDoc`, `FirebaseMeshPeerEntry`).

### Access rules

From [Backend/Firebase/firestore.rules](../Backend/Firebase/firestore.rules):

```
match /Regions/{regionId} {
  allow get, list: if isUser() && (resource.data.enabled == true || isAdmin());
  allow update: if isAdmin()
    && request.resource.data.diff(resource.data).affectedKeys().hasOnly(['meshEnabled'])
    && request.resource.data.meshEnabled is bool;
}

match /Mesh/{regionId} {
  allow get, list: if isAdmin();
  allow write: if false;
}
```

An admin client can flip exactly one field on a region document and nothing else; every host-owned
field (endpoint, keys, CIDRs, capacity, `enabled`) is API-only. `Mesh/*` is admin-readable and
client-unwritable - the hosts write it through the Admin SDK, which bypasses rules.

## 4. Computing the Desired Mesh

`desired_mesh_peers()` in `Backend/API/src/sync.py` turns region documents into a desired peer set
for **this** host. It never mutates anything and never raises on bad data: every rejection produces
a `MeshPeerState` that ends up in `Mesh/{regionId}` as operator evidence.

### Gate and candidate selection

1. This region's own document must exist with `enabled is True` **and** `mesh_enabled is True`.
   If not, the result is an empty peer set with `mesh_enabled: false` - which is the teardown
   path, not a no-op: the reconcile below then removes every mesh peer and route this host has.
2. Candidates are every *other* region document with `enabled is True` and `mesh_enabled is True`.
   Disabled regions are never peered with, even if their `meshEnabled` still reads `true`.

### Per-candidate normalization

Each candidate is normalized independently (`normalize_mesh_candidate`). The first failing check
wins and produces a `skipped-incomplete` entry with a reason code:

| Reason code | Meaning |
| --- | --- |
| `missing-public-key` / `invalid-public-key` | `wireguardPublicKey` absent, or not a 44-character base64 32-byte key |
| `missing-endpoint-hostname` / `invalid-endpoint-hostname` | `wireguardEndpointHostname` absent, or not a valid hostname/IP literal |
| `invalid-endpoint-port` | `wireguardPort` absent, non-integer, boolean, or outside `1-65535` |
| `missing-network-v4` / `invalid-network-v4` | `tunnelNetworkV4` absent, not a canonical strict network, wrong family, or not `/24` |
| `missing-network-v6` / `invalid-network-v6` | Same for `tunnelNetworkV6` and `/64` |
| `outside-aggregate` | Networks are well formed but not subnets of `MESH_AGGREGATE_V4`/`V6` |
| `duplicate-public-key` | Two or more enabled regions publish the same `wireguardPublicKey` |

A duplicate key drops **every** region holding it, not just the later one - there is no way to tell
which document is the correct owner, and cryptokey routing would let whichever applied last steal
the other's ranges. The check is scoped to enabled regions, and the log line records the
conflicting region IDs.

### Cross-candidate and local checks

Surviving candidates are then checked against each other and against this host's own configuration.
These produce `skipped-overlap` (except `local-network-invalid`, which is recorded as
`skipped-incomplete` on every candidate because nothing about the candidate itself is wrong):

| Reason code | Meaning |
| --- | --- |
| `overlap-local` | The candidate's `/24` or `/64` overlaps this host's own tunnel network (from `api.env`, not from Firestore). Applying it would take every local client's `/32` away from its own peer |
| `overlap-candidate` | Two candidates overlap each other in v4 or v6. **Both** are dropped |
| `local-network-invalid` | This host's own `wg_tunnel_ipv4_cidr`/`wg_tunnel_ipv6_cidr` do not parse, so no overlap check is possible. Every candidate is skipped and `mesh_local_network_invalid` is logged |

`skipped-overlap` and `skipped-incomplete` are configuration failures, not pending work. They will
not clear by syncing again; the underlying region metadata or overlap has to be corrected first.

### Second line of defence

`validate_mesh_peers()` in `wireguard.py` re-runs the same key/host/port/width/aggregate/overlap
and duplicate-key checks on whatever `desired_mesh_peers` produced, and is shared with the test
fake so a fake can never accept a peer set the real host would reject. A rejection there **drops
the candidate rather than aborting the pass**, and the first rejection is raised only after the
whole pass has reconciled - so bad mesh metadata can never keep a revoked client's peer alive on
the interface.

## 5. Reconciliation: Mesh Peers vs Client Peers

One pass reconciles client peers, mesh peers, and mesh routes together
(`WireGuardManager.sync_peers`). There is no timer and no separate mesh sync.

### How mesh peers differ from client peers

| | Client peer | Mesh peer |
| --- | --- | --- |
| Source | `Regions/{regionId}/Instances/*` with status `active` | Other `Regions/*` docs with `enabled` and `meshEnabled` |
| `AllowedIPs` | One `/32` + one `/128` (single host) | The peer region's whole `/24` + `/64` |
| Endpoint | Not set - the client roams and is learned from its handshake | Explicitly set to `<wireguardEndpointHostname>:<wireguardPort>` |
| Keypair | Generated per client | The region's existing server keypair, reused |
| Keepalive | `25` | `25` |
| Applied when | Only when the live state differs from desired | **Every pass, unconditionally** |
| Routes | None (covered by the interface address) | Explicit `ip route ... dev wg0` per remote `/24` and `/64` |
| Classified as | Anything whose key is not a known region key | Key present in the desired mesh set **or** in any region document's `wireguardPublicKey`, enabled or not |

Two consequences of that classification rule are load-bearing. A *disabled* or *rekeyed* region's
leftover peer is still recognised as a server peer, so it is removed and audit-logged as a mesh
change rather than being mistaken for a client peer. And an unknown key on the interface belongs to
neither set, so it is removed - leftover drift and tampering both deserve removal.

Mesh peers are re-applied every pass on purpose. `wg set peer ... endpoint <host>:<port>` resolves
the hostname itself, so the unconditional re-apply is what makes endpoint roaming and whole-server
replacement converge without any special-case migration path.

### Drift detection

A live mesh peer is considered current only when all of the following hold (`mesh_peer_drifted`,
reading `wg show wg0 dump`):

* At least one of the peer's dump-reported endpoint addresses is still an answer for the desired
  hostname, and the port matches.
* `AllowedIPs` equals exactly `{<v4 /24>, <v6 /64>}`.
* `persistent-keepalive` is `25`.

Otherwise the pass counts it as `meshUpdated`. Endpoint resolution is bounded (5s) and runs on one
process-wide single-worker resolver behind a non-queueing gate, because `getaddrinfo` cannot be
cancelled and the caller holds the sync lock. A timed-out or failed lookup reads as "unresolved",
which only marks that peer drifted and re-applies it - it never stalls the pass.

### Phase order and failure isolation

1. **Client peers** - add/update each desired client peer that differs from live.
2. **Unknown-peer removal** - remove every live peer that is neither a desired client, a desired
   mesh peer, nor a protected key. This runs *before* the mesh phase so an unresolvable mesh
   endpoint can never keep a revoked client's peer on the interface.
3. **Mesh apply** - apply every validated candidate, each in isolation.
4. **Route reconciliation** - see below.

Every unit within every phase is independent. The first failure is kept as the primary error, the
remaining phases still run, a single `peer_sync_partial` line records everything that did land plus
per-phase failure counts, and only then is the error re-raised. A failed mutation is never counted
as a change, so the counters never report progress the next pass would have to undo.

*Protected client keys*: an `active` client record with a syntactically valid public key but a
missing or corrupt tunnel IP is excluded from the desired set (it cannot be applied) yet its
already-live peer is protected from the removal sweep, rather than being torn down as unknown. The
count is reported as `clientPeersDegraded`; the record itself is never logged.

### Mesh route reconciliation

`wg-quick` only auto-installs routes for peers in the conf file, and peers added at runtime get
none - so the mesh needs explicit routes. Each pass sweeps `dev wg0` rather than deleting
per-peer:

* Every desired mesh CIDR gets `ip -4|-6 route replace <cidr> dev wg0` (idempotent, matching the
  always-re-apply behaviour for peers).
* Every existing `dev wg0` route that is inside the mesh aggregate, is not a desired mesh CIDR, is
  not this host's own tunnel network, and was not installed by the kernel (`protocol kernel`) is
  deleted. Routes outside the aggregates are never touched.
* A deleted route whose CIDR is claimed by no current region document is logged as
  `mesh_route_reclaimed` at WARNING. Treat that as a signal that a region document was deleted or
  rewritten out from under a live route.
* Routes follow what the interface can actually carry, not what applied this pass: a candidate that
  failed to re-apply but is still live with exactly the desired ranges keeps its route, because
  tearing it down would break a working link until the next successful pass. A candidate that never
  applied gets no route.

## 6. Endpoints and DNS

Mesh peers dial `wg.<regionId>.<origin>` on the region's WireGuard UDP port - the same hostname and
port that client configs use.

| Record | Terraform resource | Proxy | Used by |
| --- | --- | --- | --- |
| `<regionId>.<origin>` | `cloudflare_record.api` | Orange / proxied | Dashboard and iOS app HTTPS calls to the regional API |
| `wg.<regionId>.<origin>` | `cloudflare_record.wg` | Grey / DNS-only | WireGuard clients **and** mesh peers |

WireGuard traffic must never traverse Cloudflare; only the API hostname is proxied. Both records
are Terraform-managed from the instance's public IPv4 and refresh on rebuild, so a rebuilt region
keeps a stable mesh endpoint name even though its address changes. Because the mesh applies the
endpoint by hostname on every pass, a rebuild converges on the next Sync All with no per-peer
edit anywhere.

A mesh endpoint that fails to resolve fails only that one candidate: it is not counted as applied,
`mesh_peer_apply_failed` is logged with the endpoint host and port (region infrastructure, not
client metadata), the other candidates still apply, and the pass exits nonzero afterwards.

## 7. Enabling and Disabling a Region

Membership lives in exactly one place: `Regions/{regionId}.meshEnabled`. There is no tfvars
variable, no environment variable, and no host-side switch. Enabling, verifying, and rolling back
require no SSH and no redeploy.

* **Toggling is a Firestore-only change.** The dashboard checkbox (and the iOS Server Health
  toggle) writes the single field and nothing else. Nothing on any host changes until a sync runs.
* **Sync All Regions applies it.** It is the only sync action; there is no per-region selection,
  because a partial sync can leave the mesh half-applied on the regions left out.
* **The button is barriered on the write.** The checkbox shows the new value immediately, but each
  host reads Firestore, so a sync started before the write lands would reconcile the old
  membership. Sync All is disabled while any membership write is unresolved, a confirmed sync that
  has to wait is announced as queued, and if a membership write fails the confirmed sync is dropped
  with a banner rather than run against state that did not save.
* **Disabling is symmetric.** Turn `meshEnabled` off for one region to remove just that region, or
  for every region to tear the mesh down entirely, then Sync All again. The disabled region's own
  pass removes all of its mesh peers and routes; every other region stops listing it as a candidate
  and removes its peer and routes on the same pass.
* **`enabled: false` overrides `meshEnabled`.** A disabled region is never a mesh candidate
  regardless of its flag, and it is not a Sync All target either - so its own `Mesh` document can
  no longer be reconciled and is not reported as pending.

## 8. Boot and Sync All

### At boot

1. `wg-quick@wg0` brings up the interface from the interface-only `wg0.conf`. `PostUp` loads
   `/etc/cloudgateway/cloudgateway.nft` (the ACL table, with `cg_tunnel4`/`cg_tunnel6` populated
   and every other set/map empty) and installs the iptables/ip6tables forward, NAT, rate-limit, and
   DNS rules. The peer set is empty at this point and there are no mesh routes.
2. `cloudgateway-sync-peers` runs once (`systemctl start`). On a brand-new region there is no
   region document yet, so this is a successful empty pass; on an existing region it restores
   client peers and any mesh peers whose sibling regions are already known and enabled.
3. `cloudgateway-register-region` runs, upserting this region's document (endpoint, public key,
   tunnel CIDRs, port) and setting `enabled: true` only if the full Cloudflare edge path validates.
4. `cloudgateway-sync-peers` runs a **second** time, now that this region's own document exists, so
   the last-deployed region bridges immediately rather than waiting for an operator. This second
   pass is **skipped** unless registration returned `0`: a still-disabled region document yields an
   empty desired peer set, and that pass would remove every client peer on the interface.

The unit is `Type=oneshot` with `Restart=on-failure`, `RestartSec=30`, `StartLimitIntervalSec=0`,
so a host that boots before Firebase is reachable retries the whole idempotent pass indefinitely
without operator action. Note that the same unit also runs the ACL policy reconcile after the
peer/mesh pass; the exit-code split and what a failing closing status line means are covered in
[service-operations.md](service-operations.md#cloudgateway-sync-peersservice-firebase-peer-sync).

### On Sync All Regions

`Sync All Regions` (admin dashboard, and the equivalent on the iOS Server Health page) fans out one
`POST https://<regionId>.<origin>/api/admin/sync` per region, in parallel, from the client:

* **Targets every `enabled` region**, including regions whose `meshEnabled` is off. That is what
  makes removal converge everywhere - a region that was just demoted still has to run a pass to
  tear its own peers down.
* **Each regional API syncs only itself.** `admin/sync` rejects a body whose `regionId` is not the
  local region rather than silently syncing the wrong host.
* **The host takes the WireGuard lock non-blocking**, so a pass already running (another admin, the
  boot pass, a client create/delete) answers `409 SYNC_IN_PROGRESS` instead of queueing behind it.
* **Per-region isolation.** The fan-out settles all requests independently; a timeout, a non-JSON
  proxy error, an incompatible response, or a `409` affects only that region's result card.
* **45-second timeout per region**, on both surfaces (`REGION_SYNC_TIMEOUT_MS` in
  `Frontend/Web/src/helpers/APIHelper.ts`, `CloudGatewayAPISession.adminSyncRequestTimeout` in
  `CloudGatewayAppCore`). On iOS that longer timeout is applied to admin sync requests only.
* **The same call also reconciles the account-scoped ACL** and reports `policyApplied`; a policy
  failure never fails the sync and never touches the mesh or peer fields. See
  [access-control-list.md](access-control-list.md).

Note that `POST /api/sync/refresh` (fired automatically by client create/delete) is a different,
region-scoped path that enqueues an ACL policy pass and returns `202` with no body. It is not a
mesh operation and returns no mesh detail. See [api-contract.md](api-contract.md).

## 9. Failure Modes and How They Surface

| Condition | Where it surfaces | Repair |
| --- | --- | --- |
| Sibling region metadata missing or malformed | `Mesh/*` peer `skipped-incomplete` + reason code; Server Health warning; `meshSkipped` counter | Fix the region document (usually by re-running registration), then Sync All |
| Two regions publish the same server public key | `duplicate-public-key`; both dropped | Rebuild or rekey one region; Sync All |
| Overlapping tunnel subnets | `skipped-overlap` (`overlap-local` / `overlap-candidate`) | Correct the registry and tfvars, redeploy the offending region, Sync All |
| Host's own tunnel CIDRs unparseable | `local-network-invalid` on every candidate; `mesh_local_network_invalid` in the API journal | Fix `/etc/cloudgateway/api.env` and restart the API |
| Mesh endpoint fails to resolve or `wg set` fails | `mesh_peer_apply_failed`; that peer not counted as applied; sync exits nonzero | Check the grey-cloud `wg` DNS record; Sync All |
| Route command fails | `mesh_route_reconcile_failed` + `peer_sync_partial` with `routeReconciliationFailed: true` | Next successful pass repairs it |
| Route inside the aggregate claimed by no region | `mesh_route_reclaimed` (WARNING); route deleted | Investigate a deleted or rewritten region document |
| Mesh status write fails | `mesh_status_write_failed`; `meshStatusWritten: false` on the sync card | The wire is correct; run Sync All again to refresh the snapshot |
| A pass is already running | `409 SYNC_IN_PROGRESS`, classified separately from a failure | Wait and re-run |

### Reading Server Health

Both the web page (`Frontend/Web/src/pages/ServerHealth.tsx`, derivation in
`Frontend/Web/src/helpers/meshHelper.ts`) and the iOS page
(`Frontend/Apple/iOS/CloudGateway/ServerHealthView.swift`, derivation in
`CloudGatewayAppCore/CloudGatewayMeshStatus.swift`) read the same `Regions/*` and `Mesh/*`
documents and apply the same derivation, so the two surfaces agree by construction. The Swift file
is a direct port of the TypeScript one and is meant to be kept in lockstep with it.

**Mesh membership card, per region.** The toggle, a *pending* marker, and a freshness marker.
Pending means the region's desired `Regions.meshEnabled` disagrees with what its host last applied
(`Mesh.meshEnabled`), or it wants in and has never synced at all. A disabled region is never
reported as pending, because nothing can clear it.

**Link rows, one per unordered region pair.** A graph's links, not a per-region list, so an
asymmetric failure is visible once instead of being rendered twice from opposite sides.

| Status | Meaning |
| --- | --- |
| `both-applied` | Each side recorded an `applied` entry for the other whose snapshot (key, endpoint hostname, port, both networks) still matches the peer's current region document |
| `one-sided` | Exactly one direction is current. The link is not usable |
| `stale` | Some side recorded `applied`, but against metadata that no longer matches the peer's region document - the peer was rebuilt or rekeyed since |
| `not-synced` | Neither direction has a current applied entry |

Each row also carries `pending`, which is true when Sync All would still change something: a
membership change not yet applied, an `applied` entry that must be removed because the pair is no
longer both-desired, or a desired direction whose recorded entry no longer matches. A skip whose
underlying reason is still present is *not* pending - it is a configuration failure to fix.

**Warnings.** Every `skipped-overlap` / `skipped-incomplete` entry across all `Mesh` documents,
attributed to the region whose host made the judgment, rendered with plain-language reason text.

**Freshness.** `MESH_STALE_THRESHOLD_MS` is 24 hours. Because sync is manual-first with no timer,
this only flags "this has not run recently" for operator awareness. It is not a health signal and
is not drift.

**Per-region result cards** after a fan-out show `meshEnabled`, `meshApplied`, `meshAdded`,
`meshUpdated`, `meshRemoved`, `meshSkipped`, routes added/removed, `meshStatusWritten`, and the
per-candidate `meshPeers` list, plus an expandable plain-text audit log. The audit log's mesh
section is server metadata only - region IDs, CIDRs, endpoint hostnames - never a public key and
never per-user data, and the sync response body deliberately omits mesh peer public keys (the
durable `Mesh` document carries them, behind the admin-only rule).

Mesh status reflects durable configuration snapshots only. It does not prove a handshake or traffic
reachability - for that, use `wg show wg0` on the host.

## 10. Adding a New Region to the Mesh

1. **Allocate.** Pick the next unused index `N` and add the entry to
   `Infrastructure/OCI/terraform/subnet-registry.json` with `status: "active"`. Never reuse a
   `reserved` allocation. Commit it - the registry is the reviewable record.
2. **Write tfvars.** Copy `terraform.tfvars.example` to `<regionId>.terraform.tfvars` and set
   `wg_network_v4` / `wg_network_v6` byte-identical to the registry entry, `wg_address_v4` /
   `wg_address_v6` to the first host of each, and `wg_dns_address_v4` / `wg_dns_address_v6` to the
   same addresses without the prefix.
3. **Deploy.** `./scripts/terraform.sh <regionId> plan` then `apply`. Preflight validates the
   registry, the tfvars match, cross-region overlap, and the selected region's `active` status
   before any side effect. See [regional-deployment.md](regional-deployment.md).
4. **Wait for registration.** The host self-registers `Regions/{regionId}` at the end of bootstrap
   with its tunnel CIDRs, public key, endpoint hostname, and port, and sets `enabled: true` only
   once the Cloudflare edge path validates. Confirm the region document has non-empty
   `tunnelNetworkV4`/`tunnelNetworkV6` before continuing - an empty CIDR is exactly what produces a
   `missing-network-v4` skip on every other region.
5. **Enable membership.** In admin Server Health, flip `meshEnabled` on for the new region. Existing
   regions keep whatever membership they already have.
6. **Sync All Regions.** One pass converges every host.
7. **Verify.** Per host over SSH:

```sh
sudo wg show wg0                      # remote region's server key, subnet-width allowed-ips, recent handshake
sudo wg show wg0 latest-handshakes
sudo ip -4 route show dev wg0         # remote /24 routed dev wg0
sudo ip -6 route show dev wg0         # remote /64 routed dev wg0
```

   Then confirm the `Mesh/{regionId}` documents show `status: "applied"` for each peer with a recent
   `updatedAt`, and that two test clients in different regions (belonging to the same account, so
   the ACL permits it) can reach each other by tunnel IP.

**Changing an existing region's subnet is a hard cutoff, not a migration.** Existing clients keep
configs holding their old addresses, and nothing rewrites them. The sequence used for the Chicago
cutover was: disable that region's `meshEnabled`, Sync All, delete every
`Regions/{regionId}/Instances/*` document, update the registry and tfvars, redeploy, let
registration backfill the region document, re-enable `meshEnabled`, Sync All, verify. Clients are
recreated on the new subnet afterwards.

**Decommissioning.** Set the registry entry to `status: "reserved"` rather than deleting it, so the
allocation is never reissued. `destroy` accepts a `reserved` allocation; `plan`/`apply` do not.

## 11. Relationship to the Account-Scoped ACL

The mesh and the ACL are independent features that share a host, a sync unit, and a Server Health
page. Keep the distinction clear when triaging:

* The **mesh** decides *reachability*: whether a route and a WireGuard peer exist between regions.
* The **ACL** decides *authorization*: whether two clients on the tunnel may exchange packets at
  all, scoped to a single CloudGateway account. Mesh server-to-server links themselves are outside
  what the ACL filters.

Both are reconciled by the same `cloudgateway-sync-peers` run and by the same `Sync All Regions`
action, and both publish an admin-readable, Admin-SDK-written status document (`Mesh/{regionId}`
and `Policy/{regionId}`) whose write is best effort and whose failure never fails a pass. A policy
failure never affects the mesh fields of a sync response, and a mesh failure never takes down the
policy card.

The one hard coupling is the aggregates: the ACL's `cg_tunnel4`/`cg_tunnel6` nftables sets mirror
`MESH_AGGREGATE_V4`/`MESH_AGGREGATE_V6`, which is what makes the ACL fail closed for every
in-aggregate destination while its maps are still empty.

For everything else about the ACL - account slots, the policy map, drift, hashes, the rollout gate,
and the deletion fence - see [access-control-list.md](access-control-list.md).
