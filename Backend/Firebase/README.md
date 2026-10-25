# Firebase Reference

Firestore stores product state for the regional VPN platform. The API implementation
and [firestore.rules](firestore.rules) define behavior. [schema.ts](schema.ts) describes
document shapes for reference and does not validate runtime data. Fields use camelCase,
including `clientId`.

## Files

* [firestore.rules](firestore.rules): client SDK permissions. The Admin SDK bypasses them.
* [schema.ts](schema.ts): collection paths and TypeScript document types.
* [indexes.md](indexes.md), [firestore.indexes.json](firestore.indexes.json): query indexes
  and device-authorization TTL configuration.
* [Backup script](../../scripts/backup_firestore.py): recursive Firestore JSON export.

## Paths

* `Regions/{regionId}`: regional endpoint, keys, capacity, mesh setting, and tunnel allocators.
* `Regions/{regionId}/Instances/{clientId}`: clients linked by `ownerUid` and `ownerEmail`.
* `Users/{uid}`: email, disabled status, and account ACL slot.
* `Roles/{roleId}`: defaults for `user` and `admin`.
* `UserRoles/{uid}`: assigned `roleId` and optional `perRegionClientLimit`.
* `Mesh/{regionId}`: host-reported mesh snapshot.
* `Policy/{regionId}`: host-reported account ACL snapshot.
* `Counters/accountSlots`: authoritative account-slot allocation watermark.
* `DeviceAuthRequests/{deviceRequestId}`, `DeviceAuthLimits/{scopeId}`: temporary login state.

Each host upserts its region metadata through `cloudgateway-register-region`. A successful
Cloudflare edge health check sets `enabled: true`. Failed readiness preserves the stored
value, with new regions disabled. Registration preserves `Instances`, tunnel counters,
and an existing `meshEnabled` setting. Terraform manages DNS.

Client documents never contain the server private key. Their `wireguardConfig` contains
the client private key, so reads are restricted to the owner and admins. Account and
client creation use the API. Trusted operators seed role defaults and the account-slot
counter, and maintain roles through the Admin SDK or Firebase Console.

`accountSlot` is an opaque integer from 1 through `2^32 - 1`, allocated transactionally
once per account and never reused. `Counters/accountSlots.nextSlot` must remain above
every slot ever issued. Hard-deleted users leave no slot history in `Users`, so a lost
or lowered counter cannot be rebuilt from live users. Allocation fails closed until
an operator restores an authoritative watermark. Never lower or delete the counter.
See [account slot allocation](../../docs/access-control-list.md#account-slot-allocation)
and [counter recovery](../../docs/service-operations.md).

`Mesh` and `Policy` are observability records, separate from desired state. Hosts write
them after live reconciliation. `Policy` holds composite live authorization hashes
`mapHashV4`/`mapHashV6`, `rowCount` (the `cg_slot4` count), and server timestamp
`updatedAt`. It contains no UID, email, address, or key. An apply/read-back failure
leaves the previous successful record untouched. A status-write failure can leave a
correct live map with an old snapshot. Hash disagreement across enabled regions indicates drift. Timestamp age alone does
not indicate drift. Trusted role changes require Sync All Regions to update host allow-sets.
See [ACL policy reconciliation](../../docs/wireguard-drift-repair.md#account-scoped-acl-policy-reconcile).

Account deletion is the API's cross-region client mutation: it fences all of the
account's clients non-active, including clients on unreachable hosts, before policy
refresh and hard deletion. See the [account deletion contract](../../docs/api-contract.md#delete-account)
for ordering and recovery semantics.

## Enums

* Roles: `user`, `admin`.
* Client statuses: `creating`, `active`, `failed`, `removed`.
* Operation results: `success`, `failed`, `noop`.

## Rules Summary (frontend permissions)

[firestore.rules](firestore.rules) requires a signed-in user, a `UserRoles/{uid}` record,
and a matching `Users/{uid}` whose `disabled` field is not `true`. Admin access additionally
requires `roleId: "admin"`.

* Provisioned users read enabled regions. Admins also read disabled regions.
* Users read their own user, role assignment, and client documents. Admins read all
  users, role defaults, role assignments, and clients.
* Admins read `Mesh` and `Policy`. Only the Admin SDK writes these snapshots.
* No client, including admins, reads or writes `Counters`, `DeviceAuthRequests`, or
  `DeviceAuthLimits`.
* Client SDK writes to `Users`, `UserRoles`, `Roles`, and `Instances` are denied.
* Admins may update only the boolean `Regions/{regionId}.meshEnabled`. All other
  region writes use trusted backend/Admin SDK paths.

Rules restrict client reads independently of API authorization. Normal users must
filter collection-group client queries by `ownerUid`; rules do not filter results
for an unrestricted query. See [indexes](indexes.md).

## Device Authorization Records

Requests use a random 32-character lowercase hexadecimal document ID. Each stores
SHA-256 hex `deviceSecretHash`/`userCodeHash`, sanitized `deviceName` (up to 80
characters, empty when omitted), and `createdAt`, `expiresAt`, and `nextPollAt` timestamps.
The six-digit code can repeat because lookups require the random request ID too.

`state` is `pending`, `approved`, `denied`, or `consumed`. Decisions add `decidedUid`
and `decidedAt`; approval adds matching `approvedUid`. Consumption retains approval
fields and adds `consumedAt`. Verification responses never expose these identities.

Limit documents store `scope` (`creation` or `guesses`), a bounded `attempts` timestamp
array, and `expiresAt`. The API accesses requests and limits by document ID and shares
budgets across hosts through transactions.

Both collections use TTL on `expiresAt`, exempted from single-field indexing. TTL
cleanup is asynchronous. The API checks expiry on every operation. Deploy and verify
both TTL policies before the API rollout. Exclude both collections from recovery:
expired or consumed requests must never become redeemable again. See
[device authorization](../../docs/device-auth.md) for protocol, retention, and release checks.

## Limits

The API enforces these in Firestore transactions:

* `Regions/{regionId}.capacityLimit` caps allocated clients (`creating` plus `active`).
* A numeric `UserRoles/{uid}.perRegionClientLimit` overrides the role default.
  `0` allows zero clients. Missing or `null` falls back to
  `Roles/{roleId}.defaultPerRegionClientLimit`. A `null` default means no per-user cap;
  regional capacity still applies. Missing/malformed role-default documents fail creation.
* Client IDs, account slots when needed, paired tunnel addresses, and reservations
  commit together. Client status transitions are transactional too.
* Address allocation advances from `tunnelIndexV4`, wraps at the IPv4 host limit,
  and skips indices held by allocated clients. It writes the same chosen index to
  `tunnelIndexV4` and `tunnelIndexV6`, deriving both addresses from it. Both addresses
  therefore reuse the paired index after wrap. There is no release-time TTL.

## Backup Script

From the repo root, use the API virtualenv interpreter. No activation is needed.
The script reads `Backend/Firebase/Secrets/firebase-credentials.json` and writes
`Backend/Firebase/backups/backup-<timestamp>.json` by default:

```sh
Backend/API/.venv/bin/python3 scripts/backup_firestore.py
ls -lh Backend/Firebase/backups
```

`--output <path>` selects a different destination. The export walks subcollections,
including orphaned `Instances` documents. It exports Firestore, not Firebase Auth,
and is a recursive read rather than an atomic database snapshot.

Backups contain full WireGuard configs, client private keys, and possibly temporary
login records. Restrict access and keep them outside git (`backups/` is ignored).
Exclude `DeviceAuthRequests` and `DeviceAuthLimits` from restoration. Preserve the
account-slot watermark and use the [recovery runbook](../../docs/vm-loss-recovery.md)
for host recovery.

## Local validation

Run `./scripts/test.sh firebase` from the repo root. It checks schema/test types,
runs the device test-client checks, and starts Auth and Firestore emulators for
client rules and API integration/concurrency tests. Both suites use
`demo-cloudgateway`, with no real credentials. The target prepares API dev dependencies
when run alone.

`./scripts/test.sh api` excludes tests marked `emulator`; the Firebase target selects
them and fails if either local emulator is unavailable. Emulators do not prove
production custom-token signing, deployed indexes, or TTL cleanup. Follow the
[device authorization release checks](../../docs/device-auth.md#deployment-and-release).
