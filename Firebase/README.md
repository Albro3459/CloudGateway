# Firebase Reference

Operational reference for the Firestore layout used by the shared regional VPN platform. The code, [firestore.rules](firestore.rules), and [schema.ts](schema.ts) are the source of truth; if this file disagrees with them, they win.

All JSON and Firestore field naming is camelCase. The client identifier field is `clientId`, never `client_id`.

## Files

* [schema.ts](schema.ts) documents the Firestore collection paths and document shapes as TypeScript types for quick visualization.
* [firestore.rules](firestore.rules) contains the frontend Firestore security rules.
* [indexes.md](indexes.md) documents the required Firestore indexes.

## Paths

* Region documents: `Regions/{regionId}`
* User documents: `Users/{uid}`
* Client documents: `Users/{uid}/Regions/{regionId}/Instances/{clientId}`
* Role documents: `Roles/{uid}`

Region documents are **self-seeded by each host** at the end of bootstrap
(`cloudgateway-register-region`): it upserts `Regions/{regionId}` with the live IP, server
public key, and endpoint config, sets `enabled: true` only once the full Cloudflare path
validates (health checked through the edge, not just loopback), and preserves
`activeClientCount` (0 only on first insert). You normally don't create region
docs by hand; `Users`/`Roles` are still provisioned manually or via the admin UI.

Client documents never contain the server private key. The stored `wireguardConfig` contains the client private key, which is why client docs are readable only by their owner and admins.

## Enums

* Roles: `user`, `admin`
* Client statuses: `creating`, `active`, `failed`, `removed`
* Operation results: `success`, `failed`, `noop`

## Rules Summary (frontend permissions)

Enforced by [firestore.rules](firestore.rules):

* Authenticated users can read enabled region docs.
* Normal users can read their own user document and their own client documents.
* Admins can read all user, role, and client documents.
* Frontend clients cannot create, update, or delete VPN client documents directly. All client mutation goes through the regional FastAPI using the Firebase Admin SDK.
* Admins can write `Regions`, `Users`, and `Roles` documents from the frontend where existing admin UI needs it, but not client documents.

## Limits

Enforced server-side by the regional FastAPI inside Firestore transactions (not by [firestore.rules](firestore.rules)):

* Normal users: limited to the region doc's `userClientLimit` active clients per region (defaults to 3 when the field is absent).
* Admins: create clients only for themselves, may exceed the normal limit up to server capacity (`capacityLimit`), and may delete clients for any user.
* Reservations and `activeClientCount` updates are done in Firestore transactions by the API.
