# Firebase Indexes

Required Firestore index reference for the shared regional VPN platform.

## `Instances` Collection Group

The regional API counts allocated clients per region - and the boot-time peer sync lists active clients - with the same collection group query shape:

```ts
collectionGroup("Instances").where("regionId", "==", regionId)
```

Status filtering happens client-side, so no composite index is needed. Firestore single-field indexes default to collection scope, so this query needs a one-time, project-wide collection group index.

In the Firebase console:

1. Open Firestore Database > Indexes > Automatic.
2. Choose Add exemption.
3. Enter collection ID `Instances`.
4. Enter field path `regionId`.
5. Select only the Collection group query scope.
6. Enable the Ascending index type. Leave Descending and Arrays disabled.

Do not create a structured/composite index for this query. If the structured index flow warns that the index is not necessary and should be configured with single-field index controls, use the Automatic > Add exemption flow above.

Without this index, `POST /clients` and `DELETE /clients/{clientId}` fail with a Firestore `FAILED_PRECONDITION` error that includes an index creation link; following that link creates the same index.

The admin dashboard reads every client with an unfiltered `collectionGroup("Instances")` query. Because it applies no `where` or `orderBy`, it orders by document name and uses Firestore's automatically maintained collection-group index, so it needs no exemption or composite index beyond the `regionId` exemption above.
