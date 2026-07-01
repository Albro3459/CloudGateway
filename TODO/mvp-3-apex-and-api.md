# MVP 3: Apex API Routing And Backend Hardening

Status: Planning. Cross-cutting piece of the [Apple MVP 3 program](apple-mvp-3-implementation.md); spans web, iOS, backend, and infra (not Apple-only).

Goal: add a global apex host so guests (and all clients) can discover regions without per-region bootstrapping, split API traffic by whether it is region-specific, and lock Firestore to read-only. This is the foundation the guest flow and UI build sit on.

## API Host Routing

Split traffic by whether it touches a specific region's live WireGuard interface or reports that region's own state.

* **Apex host `api.gocloudlaunch.com`** — a manually created proxied DNS CNAME alias to `us-sanjose-1.gocloudlaunch.com`. Every region's Caddy gets a small config update to also serve the `api.` subdomain (cert reused). Cloudflare-proxied and rate-limited. Serves global / cross-region traffic:
  * `GET /regions` — **unauthenticated**, used by every client (guest and signed-in). Returns all enabled regions as a display-safe list only — `regionId`, `displayName`, `displayOrder` — and **no capacity**. The single region-list source for all clients. Response shape:

    ```json
    { "regions": [
      { "regionId": "us-sanjose-1", "displayName": "San Jose", "displayOrder": 1 },
      { "regionId": "us-ashburn-1", "displayName": "Ashburn", "displayOrder": 2 }
    ] }
    ```

    `enabled` is omitted because only enabled regions are returned.
  * `POST /auth/check-access` — authenticated access verification (replaces the current "first enabled region" host selection; behavior is otherwise unchanged).
* **Region host `https://<regionId>.gocloudlaunch.com/api/*`** — endpoints scoped to one region:
  * `GET /capacity` — that specific region's capacity (authenticated, unchanged). The **only** capacity source: signed-in clients fan it out per region to decorate the region list. Guests never call it.
  * `POST /clients` (create), `DELETE /clients/{clientId}` (delete), `POST /admin/sync`.

Endpoint distinction: `GET /regions` (apex, unauthenticated) = the region list only, no capacity; `GET /capacity` (region host, authenticated) = one region's capacity, fanned out per region by signed-in clients. Guests get names/order only and never see capacity.

Guest region visibility falls out of this: guests call the unauthenticated apex `GET /regions` — no per-region bootstrap chicken-and-egg, no capacity exposure. Firestore rules stay locked; `Regions` is never opened to unauthenticated reads.

## Backend

* [Backend/API/src/routes.py](../Backend/API/src/routes.py) + [models.py](../Backend/API/src/models.py): add `GET /regions` with no auth dependency (like `/health`), returning enabled regions as `{ regionId, displayName, displayOrder }`, sorted by `displayOrder`. Leave `GET /capacity` as the single-region authenticated endpoint.
* The apex host is region‑1's API; it reads the global `Regions` collection via the Admin SDK, so one host can list all enabled regions.
* Update [docs/api-contract.md](../docs/api-contract.md) with the apex vs region-host split and the `GET /regions` contract.

## Infra

* [Infrastructure/CloudFlare](../Infrastructure/CloudFlare): apex DNS CNAME `api.gocloudlaunch.com` → `us-sanjose-1.gocloudlaunch.com` (manually managed). Cloudflare-proxied with a rate-limit rule on the unauthenticated `GET /regions`.
* [Infrastructure/OCI](../Infrastructure/OCI) Caddy: every region's Caddyfile also accepts the `api.gocloudlaunch.com` host and routes it to the local API, reusing the existing cert. Keep WireGuard traffic on the grey-cloud `wg.<regionId>` records untouched.

## Client Changes

* **iOS** [CloudGatewayFirebaseService.swift](../Frontend/Apple/iOS/CloudGateway/CloudGatewayFirebaseService.swift): add an apex base URL; route `GET /regions` and `POST /auth/check-access` to the apex; keep `regionalAPIURL` for the `/capacity` fan-out and create/delete/sync. Replace the direct Firestore `fetchEnabledRegions()` with an apex `fetchRegions()`; the guest path stops there, and the signed-in path keeps the per-region `/capacity` fan-out (`addCapacity`).
* **Web** [apiEndpoints.ts](../Frontend/Web/src/helpers/apiEndpoints.ts) / [APIHelper.ts](../Frontend/Web/src/helpers/APIHelper.ts) / [ociRegionsStore.ts](../Frontend/Web/src/stores/ociRegionsStore.ts): `ociRegionsStore` switches the region list from the direct Firestore `Regions` query to the apex `GET /regions`, keeping the per-region `getRegionCapacity` fan-out for signed-in users. `check-access` targets the apex.
* Web and iOS can land separately; both keep existing behavior/UI in this piece (routing only).

## Firestore Rules Hardening

The web app and iOS app perform zero direct Firestore writes (verified repo-wide: no `setDoc`/`updateDoc`/`deleteDoc`/`addDoc`/`writeBatch`/`runTransaction` in web, no Firestore writes in the Swift app, no Cloud Functions). All mutations go through the regional API (Admin SDK, bypasses rules). So client-side write permissions are unused and can be removed.

Proposed changes in [firestore.rules](../Backend/Firebase/firestore.rules):

* `Roles`: split `read, write` → keep `read` (admin), drop `write`.
* `UserRoles`, `Users`, `Regions`: drop `create, update, delete` (keep the existing `get`/`list` read rules).
* `Instances`: already `create, update, delete: if false` — leave as is.
* Do **not** add any unauthenticated read; guest region access comes from the apex API, not relaxed rules.

Net effect: Firestore is read-only from every client; the API is the sole mutation path. Deploy carefully and verify admin flows (grant access, sync) and normal reads still work.

## Testing

* API tests for `GET /regions`: unauthenticated access succeeds, only enabled regions returned, projection has no capacity/endpoints/keys, sorted by `displayOrder`.
* Firestore rules tests (emulator) or a staged check: writes denied for all roles including admin; reads still work for provisioned users and admins.
* Keep `./scripts/test.sh api` green; add the new endpoint to it.

## Open Items

* Apex rate-limit thresholds for the unauthenticated `GET /regions` (Cloudflare/Caddy).

## Acceptance

* `api.gocloudlaunch.com` resolves and every region's Caddy serves it with the reused cert.
* `GET /regions` returns the enabled-region list (no capacity) without auth; `GET /capacity` unchanged.
* Web and iOS get the region list from the apex and drop the direct Firestore `Regions` read; capacity still fans out per region for signed-in users.
* Firestore denies all client writes; API mutations unaffected.
* `docs/api-contract.md` reflects the split.
