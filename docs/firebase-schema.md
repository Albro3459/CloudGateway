# Firebase Schema and Rules Reference

Operational reference for the Firestore layout used by the shared regional VPN platform. `TODO/Shared_VPN_Contract.md` is the source of truth; if this file and the contract disagree, the contract wins.

All JSON and Firestore field naming is camelCase. The client identifier field is `clientId`, never `client_id`.

## Paths

* Region documents: `Regions/{regionId}`
* User documents: `Users/{uid}`
* Client documents: `Users/{uid}/Regions/{regionId}/Instances/{clientId}`
* Role documents: `Roles/{uid}`

## `Regions/{regionId}`

| Field | Type | Notes |
| --- | --- | --- |
| `regionId` | string | same as document ID |
| `displayName` | string | |
| `enabled` | boolean | dashboard shows enabled regions only |
| `wireguardEndpointIpv4` | string | raw server public IPv4 (operations/display) |
| `wireguardEndpointIpv6` | string or null | |
| `wireguardEndpointHostname` | string | grey-cloud `wg.<regionId>.<origin>` used as the client config endpoint |
| `wireguardPort` | number | default `51820` |
| `wireguardDnsIpv4` | string | tunnel DNS |
| `wireguardDnsIpv6` | string | tunnel DNS |
| `wireguardPublicKey` | string | server public key |
| `capacityLimit` | number | server capacity, start with 15-25 |
| `activeClientCount` | number | maintained by API transactions |
| `displayOrder` | number, optional | missing sorts as `1000` |
| `healthStatus` | string, optional | |
| `updatedAt` | timestamp | |

## `Users/{uid}`

| Field | Type | Notes |
| --- | --- | --- |
| `uid` | string | same as document ID |
| `email` | string | |
| `displayName` | string or null | |
| `createdAt` | timestamp | |
| `disabled` | boolean, optional | |

## `Roles/{uid}`

| Field | Type | Notes |
| --- | --- | --- |
| `role` | string | `user` or `admin` |
| `updatedAt` | timestamp | |

## Client Documents (`Users/{uid}/Regions/{regionId}/Instances/{clientId}`)

| Field | Type | Notes |
| --- | --- | --- |
| `clientId` | string | UUIDv4, same as document ID |
| `ownerUid` | string | |
| `ownerEmail` | string | |
| `ownerDisplayName` | string or null | |
| `clientName` | string | user-provided or server default |
| `regionId` | string | |
| `status` | string | `creating`, `active`, `failed`, or `removed` |
| `assignedTunnelIpv4` | string | CIDR, e.g. `10.0.0.2/32` |
| `assignedTunnelIpv6` | string | CIDR, e.g. `fd42:42:42::2/128` |
| `serverEndpointIpv4` | string | raw public IPv4 |
| `serverEndpointHostname` | string | DNS endpoint hostname used in the stored config |
| `serverPublicKey` | string | |
| `clientPublicKey` | string | |
| `wireguardConfig` | string or null | full client config for dashboard QR/download/copy |
| `createdAt` | timestamp | |
| `updatedAt` | timestamp | |
| `removedAt` | timestamp or null | |
| `lastErrorCode` | string or null | |
| `lastErrorMessage` | string or null | |

Client documents never contain the server private key. The stored `wireguardConfig` contains the client private key, which is why client docs are readable only by their owner and admins.

## Enums

* Roles: `user`, `admin`
* Client statuses: `creating`, `active`, `failed`, `removed`
* Operation results: `success`, `failed`, `noop`

## Required Indexes

The regional API counts allocated clients per region - and the boot-time peer sync lists active clients - with the same collection group query shape: `collectionGroup("Instances").where("regionId", "==", ...)` (status filtering happens client-side, so no composite index is needed). Firestore single-field indexes default to collection scope, so this query needs a one-time, project-wide collection group index.

In the Firebase console:

1. Open Firestore Database > Indexes > Automatic.
2. Choose Add exemption.
3. Enter collection ID `Instances`.
4. Enter field path `regionId`.
5. Select only the Collection group query scope.
6. Enable the Ascending index type. Leave Descending and Arrays disabled.

Do not create a structured/composite index for this query. If the structured index flow warns that the index is not necessary and should be configured with single-field index controls, use the Automatic > Add exemption flow above.

Without this index, `POST /clients` and `DELETE /clients/{clientId}` fail with a Firestore `FAILED_PRECONDITION` error that includes an index creation link; following that link creates the same index.

The admin dashboard's cross-user reads use direct document/collection reads and need no extra index.

## Rules Summary (frontend permissions)

Enforced by `firebase.rules`:

* Authenticated users can read enabled region docs.
* Normal users can read their own user document and their own client documents.
* Admins can read all user, role, and client documents.
* Frontend clients cannot create, update, or delete VPN client documents directly. All client mutation goes through the regional FastAPI using the Firebase Admin SDK.
* Admins can write `Regions`, `Users`, and `Roles` documents from the frontend where existing admin UI needs it, but not client documents.

## Limits

* Normal users: 3 active clients per region by default.
* Admins: create clients only for themselves, may exceed the normal limit up to server capacity (`capacityLimit`), and may delete clients for any user.
* Reservations and `activeClientCount` updates are done in Firestore transactions by the API.
