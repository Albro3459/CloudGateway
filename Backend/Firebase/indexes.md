# Firebase Indexes

[firestore.indexes.json](firestore.indexes.json) is the deployable index and TTL
configuration. Its `indexes` array is empty: current queries need no composite indexes.

## `Instances` Documents

The regional API reads the direct `Regions/{regionId}/Instances` subcollection for
capacity and sync. The dashboard and account cleanup use collection-group reads:

```ts
// Normal user: own clients across regions
query(collectionGroup(db, "Instances"), where("ownerUid", "==", uid))

// Admin: all clients across regions
collectionGroup(db, "Instances")
```

Normal-user queries need the owner filter to satisfy Firestore rules. Admins may
use the unfiltered query. Add filters/orderings only with their required indexes.

## Collection-Group Field Indexes

The configuration declares these single-field `COLLECTION_GROUP` indexes:

| Collection group | Field | Order |
| --- | --- | --- |
| `Instances` | `ownerUid` | Ascending |
| `Instances` | `regionId` | Ascending |

`ownerUid` supports owner queries and account deletion. `regionId` remains available
for operational collection-group region queries, although regional API reads use
the direct subcollection. No descending or array indexes are declared for these fields.

Deploy the checked-in configuration with the Firebase release workflow. For a manual
Console repair, create matching field overrides for collection ID `Instances`,
collection-group scope, and Ascending order. Keep the checked-in configuration in sync.

## Device Authorization TTL

`DeviceAuthRequests.expiresAt` and `DeviceAuthLimits.expiresAt` each have `ttl: true`
and `indexes: []`. Their timestamps need no query index because the API reads each
record by document ID.

After deployment, verify both TTL policies are enabled. Cleanup is asynchronous:
the API enforces expiry itself and never relies on deletion for authorization.
See the [Firebase reference](README.md#device-authorization-records) for retention
and backup rules, and the [device authorization runbook](../../docs/device-auth.md#deployment-and-release)
for release checks.
