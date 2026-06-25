# Firebase Reference

Operational reference for the Firestore layout used by the shared regional VPN platform. The code, [firestore.rules](firestore.rules), and [schema.ts](schema.ts) are the source of truth; if this file disagrees with them, they win.

All JSON and Firestore field naming is camelCase. The client identifier field is `clientId`, never `client_id`.

## Files

* [schema.ts](schema.ts) documents the Firestore collection paths and document shapes as TypeScript types for quick visualization.
* [firestore.rules](firestore.rules) contains the frontend Firestore security rules. During the schema migration, the rules must be updated alongside the API and app code before deployment.
* [indexes.md](indexes.md) documents the required Firestore indexes; [../firestore.indexes.json](../firestore.indexes.json) captures the deployable index configuration.
* [scripts/backup_firestore.py](scripts/backup_firestore.py) creates a recursive JSON backup of every Firestore document.
* [scripts/migrate_firestore_schema.py](scripts/migrate_firestore_schema.py) backs up Firestore, creates role defaults and user role assignments, and moves old nested client documents to the regional layout.

## Paths

* Region documents: `Regions/{regionId}`
* Client documents: `Regions/{regionId}/Instances/{clientId}`
* User documents: `Users/{uid}`
* Role default documents: `Roles/{roleId}` (`Roles/user`, `Roles/admin`)
* User role assignment documents: `UserRoles/{uid}`

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

User documents own each user's profile data, such as email and disabled status.

Role documents are defaults keyed by role name:

* `Roles/user.defaultPerRegionClientLimit`: default per-region client limit for normal users.
* `Roles/admin.defaultPerRegionClientLimit`: default per-region client limit for admins. A
  `null` value means no per-user limit; regional `capacityLimit` still applies.

User role assignment documents are the Firestore rules authorization anchor. Each
`UserRoles/{uid}` document has `roleId: "user" | "admin"` and optional
`perRegionClientLimit`. The override uses the same semantics as role defaults: `null`
and missing mean "use the role default," while `0` is a real override that allows zero
clients per region. `UserRoles` is writable only by admins or the API. Keeping assignment
and entitlement overrides separate from `Users/{uid}` avoids making normal user profile
data part of the rules bootstrap path.

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
* Frontend clients cannot create, update, or delete VPN client documents directly. All client mutation goes through the regional FastAPI using the Firebase Admin SDK.
* Admins can write `Regions`, `Users`, `UserRoles`, and `Roles` documents from the frontend where existing admin UI needs it, but not client documents.

## Limits

Enforced server-side by the regional FastAPI inside Firestore transactions (not by [firestore.rules](firestore.rules)):

* Region capacity: `Regions/{regionId}.capacityLimit` caps the total allocated clients in the region.
* Allocated clients are `creating` plus `active` client docs under `Regions/{regionId}/Instances`.
* Per-user limits resolve from `UserRoles/{uid}.perRegionClientLimit` when it is a number. If it is `null` or missing, the API falls back to `Roles/{roleId}.defaultPerRegionClientLimit` using `UserRoles/{uid}.roleId`.
* `0` is a valid per-user override and does not fall back to the role default.
* Admins may use a `null` role default to mean no per-user limit, while still being capped by regional `capacityLimit`.
* Reservations and client status transitions are done in Firestore transactions by the API.

## Backup and Migration Scripts

Run these scripts from the repo root with the API virtualenv activated. They use the
hardcoded Admin SDK credential path `Firebase/Secrets/firebase-credentials.json`.

```sh
source API/.venv/bin/activate
python3 Firebase/scripts/backup_firestore.py
python3 Firebase/scripts/migrate_firestore_schema.py
```

Backups are written to `Firebase/backups/backup-<timestamp>.json`. Treat these files as
secret material because client documents can contain full WireGuard configs and client
private keys. `Firebase/backups/` is intentionally ignored by git.

The migration script calls the backup script first. It then:

* Creates `Roles/user` with `defaultPerRegionClientLimit` derived from matching legacy
  region `userClientLimit` values, or `3` when no legacy value exists. The script fails
  before writes if legacy region values disagree.
* Creates `Roles/admin` with `defaultPerRegionClientLimit: 10`.
* Creates `UserRoles/{uid}` from valid old `Roles/{uid}.role` documents and omits
  `perRegionClientLimit`. Users without an old role assignment remain unprovisioned.
  The script fails before writes if an old role value is unsupported.
* Copies old `Users/{uid}/Regions/{regionId}/Instances/{clientId}` client documents to
  `Regions/{regionId}/Instances/{clientId}`, preserving fields while forcing
  `ownerUid`, `regionId`, and `clientId` from the old path.
* Removes stale `activeClientCount` and `userClientLimit` fields from `Regions/{regionId}`.
* Fails before any writes or deletes if a target role, user-role, or client document
  already exists with conflicting data.
* Deletes old nested client documents, old `Users/{uid}/Regions/{regionId}` shadow docs,
  and old per-user `Roles/{uid}` documents only after the backup and all writes succeed.

Keep the backup until the new `Roles`, `UserRoles`, and
`Regions/{regionId}/Instances` documents have been verified.
