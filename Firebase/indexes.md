# Firebase Indexes

Required Firestore index reference for the shared regional VPN platform.

## `Instances` Documents

After the schema migration, client documents live under the region that owns them:

```ts
collection(db, "Regions", regionId, "Instances")
```

The regional API counts allocated clients and lists sync input from that direct subcollection.
No `regionId` collection-group index is needed for regional operations.

Normal dashboard users list their own clients with a collection-group query filtered by owner:

```ts
query(collectionGroup(db, "Instances"), where("ownerUid", "==", uid))
```

Firestore's automatic single-field indexes support this query unless the console reports a
project-specific exemption. Admins list all clients with an unfiltered collection-group query.

Existing projects may keep the older `collectionGroup("Instances").where("regionId", "==", regionId)`
single-field index until the migration and runtime code changes are complete. It is harmless
but no longer part of the target schema.

If a cross-region admin screen later queries all instances with `collectionGroup("Instances")`,
an unfiltered read uses Firestore's automatically maintained collection-group index. Add a
specific collection-group index only when the query adds filters or ordering that Firestore
explicitly requires.

At the moment there are no required composite indexes for the target Firestore schema.
