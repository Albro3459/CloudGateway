# Firebase Indexes

Required Firestore index reference for the shared regional VPN platform.

## `Instances` Documents

Client documents live under the region that owns them:

```ts
collection(db, "Regions", regionId, "Instances")
```

The regional API counts allocated clients and lists sync input from that direct subcollection.
Normal dashboard users list their own clients with a collection-group query filtered by owner:

```ts
query(collectionGroup(db, "Instances"), where("ownerUid", "==", uid))
```

Admins list all clients with an unfiltered collection-group query.

## Collection-Group Field Indexes

The `Instances` collection group uses these single-field indexes:

| Field path | Ascending | Descending | Arrays |
| --- | --- | --- | --- |
| `regionId` | Enabled | Disabled | Disabled |
| `ownerUid` | Enabled | Disabled | Disabled |

These indexes are captured in the Firebase directory [firestore.indexes.json](./firestore.indexes.json).

To create them in the Firebase Console:

1. Open Firestore.
2. Go to Indexes.
3. Open Automatic.
4. Click Add exemption.
5. Set Collection ID to `Instances`.
6. Set Query scope to Collection group.
7. Set Field path to `ownerUid`.
8. Enable Ascending only.
9. Save, then repeat for `regionId`.

`ownerUid` supports the normal-user dashboard query:

```ts
query(collectionGroup(db, "Instances"), where("ownerUid", "==", uid))
```

`regionId` supports older or operational collection-group queries scoped to one region:

```ts
query(collectionGroup(db, "Instances"), where("regionId", "==", regionId))
```

If a cross-region admin screen later queries all instances with `collectionGroup("Instances")`,
an unfiltered read uses Firestore's automatically maintained collection-group index. Add a
specific collection-group index only when the query adds more filters or ordering that
Firestore explicitly requires.

At the moment there are no required composite indexes for the current Firestore schema.
