# Firebase Reference

Operational reference for the Firestore layout used by the shared regional VPN platform. The code, [firestore.rules](firestore.rules), and [schema.ts](schema.ts) are the source of truth; if this file disagrees with them, they win.

All JSON and Firestore field naming is camelCase. The client identifier field is `clientId`, never `client_id`.

## Files

* [schema.ts](schema.ts) documents the Firestore collection paths and document shapes as TypeScript types for quick visualization.
* [firestore.rules](firestore.rules) contains the frontend Firestore security rules. Update the rules alongside the API and app code when Firestore access patterns change.
* [indexes.md](indexes.md) documents the required Firestore indexes; [./firestore.indexes.json](./firestore.indexes.json) captures the deployable index configuration.
* [../../scripts/backup_firestore.py](../../scripts/backup_firestore.py) creates a recursive JSON backup of every Firestore document.

## Paths

* Region documents: `Regions/{regionId}`
* Client documents: `Regions/{regionId}/Instances/{clientId}`
* User documents: `Users/{uid}`
* Role default documents: `Roles/{roleId}` (`Roles/user`, `Roles/admin`)
* User role assignment documents: `UserRoles/{uid}`
* Account-scoped ACL policy status documents: `Policy/{regionId}`
* Account slot counter document: `Counters/accountSlots`

Region documents are **self-seeded by each host** at the end of bootstrap
(`cloudgateway-register-region`): it upserts `Regions/{regionId}` with the live IP, server
public key, and endpoint config, sets `enabled: true` only once the full Cloudflare path
validates (health checked through the edge, not just loopback), and updates only the
region metadata document. It must not delete or overwrite `Regions/{regionId}/Instances`.
You normally don't create region docs by hand; `Users`, `UserRoles`, and role defaults
are still provisioned manually or via the admin UI.

Client documents live under the region they belong to and include `ownerUid`/`ownerEmail`
links back to the owning user. They never contain the server private key. The stored
`wireguardConfig` contains the client private key, which is why client docs are readable
only by their owner and admins.

User documents own each user's profile data, such as email and disabled status. `accountSlot` is
the opaque account-scoped ACL identifier: a monotonically allocated integer, never reused, that
hosts key the client-to-client isolation filter on instead of the uid - see
[docs/wireguard-drift-repair.md](../../docs/wireguard-drift-repair.md#account-scoped-acl-policy-reconcile).
It is allocated once, in a transaction, from `Counters/accountSlots`, the sole allocator document
(document id always `accountSlots`); no client, including admins, may read or write it directly.

Policy documents (`Policy/{regionId}`) mirror the existing `Mesh/{regionId}` pattern: observability
only, written by each region's host via the Admin SDK after a policy reconcile pass, describing
what the live account-scoped ACL map on that host actually contains, not what the region intended
to apply. `mapHashV4`/`mapHashV6` are one composite hash per address family over every
authorization-bearing live object read back from the host - `cg_tunnel4/6`, `cg_infra4/6`,
`cg_admin4/6`, `cg_slot4/6`, `cg_pairs4/6` - not just the slot map, so an admin allow-set change is
visible in the hash as soon as the next reconcile runs. `rowCount` is the `cg_slot4` row count.
`updatedAt` is a server timestamp meaning the last successful live apply and read-back; Server
Health renders it as "Last applied." A failed apply or read-back never writes this document at
all - the write happens only after both succeed, so a failure leaves the previous successful
document untouched rather than recording a failure state; the failure is visible only in host logs
and, for Sync All, in that call's response. Timestamp age alone is never drift or staleness - drift is
comprehensive hash disagreement among enabled regions only, and disabled regions never participate
in the comparison. There is no role-mutation API, UI, timer, or automatic role propagation in this
release: reconcile re-reads `UserRoles` and applies `cg_admin4/6` on every pass, so a trusted
operator who edits `UserRoles` out of band must run Sync All Regions immediately, and the fleet
keeps enforcing the previous allow-set until they do. Policy documents deliberately never contain a
uid, email, address, or key.

Account deletion (`DELETE /account`) performs the one fleet-wide client-document write the API
ever makes: an Admin-SDK-only, cross-region write across every region's `Instances`
subcollection (`Regions/*/Instances`) that marks every one of the deleting account's client
documents non-active, regardless of whether that region's host is reachable. It is the only place
any regional API writes into another region's `Instances` path, and it is reachable only from a
recently authenticated self-delete - see [docs/api-contract.md](../../docs/api-contract.md) and
[TODO/account-scoped-acl.md](../../TODO/account-scoped-acl.md).

Role documents are defaults keyed by role name:

* `Roles/user.defaultPerRegionClientLimit`: default per-region client limit for normal users.
* `Roles/admin.defaultPerRegionClientLimit`: default per-region client limit for admins. A
  `null` value means no per-user limit; regional `capacityLimit` still applies.

User role assignment documents provide role and entitlement data for provisioned
users. Each `UserRoles/{uid}` document has `roleId: "user" | "admin"` and optional
`perRegionClientLimit`. The override uses the same semantics as role defaults: `null`
and missing mean "use the role default," while `0` is a real override that allows zero
clients per region. Firestore rules require both this role assignment and a matching
`Users/{uid}` document whose `disabled` field is not `true`. `UserRoles` is writable
only by admins or the API.

## Enums

* Roles: `user`, `admin`
* Client statuses: `creating`, `active`, `failed`, `removed`
* Operation results: `success`, `failed`, `noop`

## Rules Summary (frontend permissions)

Enforced by [firestore.rules](firestore.rules):

* Provisioned users can read enabled region docs.
* Normal users can read their own user document and their own client documents.
* Users can read their own role assignment. Role defaults are admin-only.
* Admins can read all user, role default, role assignment, and client documents.
* Admins can read `Policy/{regionId}` status documents. Write is Admin-SDK only.
* No client, including admins, may read or write `Counters/{counterId}` documents.
* Frontend clients cannot create, update, or delete VPN client documents directly. All client mutation goes through the regional FastAPI using the Firebase Admin SDK.
* Frontend clients cannot write `Regions`, `Users`, `UserRoles`, `Roles`, or client documents directly. Admin and operational mutation goes through trusted backend/Admin SDK paths.

## Limits

Enforced server-side by the regional FastAPI inside Firestore transactions (not by [firestore.rules](firestore.rules)):

* Region capacity: `Regions/{regionId}.capacityLimit` caps the total allocated clients in the region.
* Allocated clients are `creating` plus `active` client docs under `Regions/{regionId}/Instances`.
* Per-user limits resolve from `UserRoles/{uid}.perRegionClientLimit` when it is a number. If it is `null` or missing, the API falls back to `Roles/{roleId}.defaultPerRegionClientLimit` using `UserRoles/{uid}.roleId`.
* `0` is a valid per-user override and does not fall back to the role default.
* Admins may use a `null` role default to mean no per-user limit, while still being capped by regional `capacityLimit`.
* Reservations and client status transitions are done in Firestore transactions by the API.
* Tunnel addresses are allocated from a per-region monotonic index, `Regions/{regionId}.tunnelIndexV4`/`.tunnelIndexV6`, advanced in the same transaction as the client reservation and paired so a client's v4/v6 addresses share an index. This replaces lowest-free-address reuse; v4 wraps at the top of the host range with an in-use check, v6 never wraps. No `releasedAt` field and no time-based TTL.

## Backup Script

Run this script from the repo root with the API virtualenv activated. It uses the
hardcoded Admin SDK credential path `Backend/Firebase/Secrets/firebase-credentials.json`.

```sh
Backend/API/.venv/bin/python3 scripts/backup_firestore.py
ls -lh Backend/Firebase/backups
```

Backups are written to `Backend/Firebase/backups/backup-<timestamp>.json`. Treat these files as
secret material because client documents can contain full WireGuard configs and client
private keys. `Backend/Firebase/backups/` is intentionally ignored by git.
