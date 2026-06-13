# CloudLaunch Frontend

React + TypeScript dashboard for the shared regional VPN platform. Users pick a region, add/remove WireGuard clients, and view stored configs (QR, download, copy) from Firebase.

The frontend is a static GitHub Pages app. It does not own VPN server state directly; it authenticates users with Firebase, reads dashboard data from Firestore, and sends client/user mutations to the selected regional FastAPI control plane.

```text
React dashboard
  -> Firebase Auth
  -> Firestore reads for regions, users, client docs, and stored configs
  -> https://<regionId>.<origin>/api/*
      -> regional FastAPI
      -> Firebase Admin SDK
      -> live WireGuard host mutation
```

## Core Responsibilities

* Sign users in with Firebase email/password or Google sign-in.
* Confirm account access through the regional API before entering the dashboard.
* Read enabled regions from Firestore and cache them in the client.
* Show region tabs, capacity hints, client status, tunnel addresses, and server endpoints.
* Create and remove WireGuard clients by calling the regional API with a Firebase bearer token.
* Show stored WireGuard configs from Firebase with QR, copy, and download actions.
* Provide admin-only user creation and cross-user client visibility/removal where the Firebase role allows it.

The frontend never creates, updates, or deletes VPN client documents directly. All client mutation goes through the regional FastAPI using the Firebase Admin SDK. See [../Firebase/README.md](../Firebase/README.md) for Firestore paths, rules, and indexes, and [../API/README.md](../API/README.md) for the API control plane.

## Architecture

[src/App.tsx](src/App.tsx)

* HashRouter route map for GitHub Pages.
* Routes login, home/dashboard, about, password reset, and admin user creation pages.

[src/firebase.ts](src/firebase.ts)

* Initializes Firebase Auth from [src/Secrets/firebaseConfig.ts](src/Secrets/firebaseConfig.ts).
* Exports Auth helpers used by login, dashboard, and admin pages.

[src/pages/Home.tsx](src/pages/Home.tsx)

* Main dashboard.
* Watches auth state, loads role/region/client data, creates/removes clients, renders QR codes, and keeps the table fresh while mutations are running.

[src/components/VPNTable.tsx](src/components/VPNTable.tsx)

* Client table with sorting, selection, status badges, QR/download/copy controls, and admin columns.

[src/helpers/APIHelper.ts](src/helpers/APIHelper.ts)

* Typed fetch wrapper for regional FastAPI calls.
* Adds Firebase bearer auth, sends JSON, and normalizes FastAPI error responses.

[src/helpers/apiEndpoints.ts](src/helpers/apiEndpoints.ts)

* Builds regional API URLs.
* Uses `REACT_APP_API_ORIGIN` for local/dev overrides and derived `https://<regionId>.<origin>/api/*` URLs for production.

[src/helpers/firebaseDbHelper.ts](src/helpers/firebaseDbHelper.ts)

* Reads user/admin-visible client documents and stored WireGuard configs from Firestore.

[src/stores/ociRegionsStore.ts](src/stores/ociRegionsStore.ts)

* Zustand store for enabled region documents.
* Reads `Regions` from Firestore, matching security-rule requirements for non-admin users.

[src/helpers/regionsHelper.ts](src/helpers/regionsHelper.ts), [src/helpers/usersHelper.ts](src/helpers/usersHelper.ts), [src/helpers/vpnStatus.ts](src/helpers/vpnStatus.ts)

* Region parsing/sorting/capacity labels, role helpers, and normalized VPN status display.

## Data Flow

* Firebase Auth owns browser sign-in state and ID tokens.
* Firestore provides dashboard reads for enabled regions, users, roles, client documents, and stored WireGuard configs.
* The regional FastAPI owns protected mutations:
  * `POST /api/auth/check-access`
  * `POST /api/clients`
  * `DELETE /api/clients/{clientId}`
  * `POST /api/users`
* The API writes final product state through the Firebase Admin SDK and applies live WireGuard changes on the regional host.

## API Origin Behavior

* Production builds derive each regional API URL from the selected region and the current frontend origin: `https://<regionId>.<origin>/api/*`, where `<origin>` comes from `window.location.host`. For a frontend loaded from `https://gateway.gocloudlaunch.com`, region `us-sanjose-1` calls `https://us-sanjose-1.gateway.gocloudlaunch.com/api/*`.
* `REACT_APP_API_ORIGIN` is a local/dev override only. When set, API helpers send all API calls to `${REACT_APP_API_ORIGIN}/api/*` instead of deriving a regional hostname. Use it to point at a locally running regional API.
* Production builds leave `REACT_APP_API_ORIGIN` unset. There is no global API router and no Cloudflare Worker dev proxy.

## Running the React Site

Use Node.js `20` LTS or newer with npm `10` or newer. See [../docs/tool-versions.md](../docs/tool-versions.md) for the repo's expected tooling versions.

Update dependencies:
```sh
cd APP
npm install
```

Run the React app:
```sh
cd APP
npm start
```

The `start` script starts React without opening a browser automatically and runs the Tailwind watcher at the same time. Set `REACT_APP_API_ORIGIN` yourself only when you have a local Caddy-style `/api/*` proxy or another regional API-compatible endpoint running.

## Tailwind

Keep tailwind css updated while making changes:
```sh
cd APP
npx @tailwindcss/cli -i ./src/input.css -o ./src/output.css --watch
```

The generated stylesheet is [src/output.css](src/output.css), built from [src/input.css](src/input.css).

## Deploy GitHub Page

* [CNAME](./public/CNAME) specifies the host name. This must match DNS records.
* NOTE: This uses your local build code to deploy. It does NOT pull from any remote branch. It compiles your code to the build folder and deploys that.
  * Pro: Can be run from any branch.
  * Con: Must be run locally and it can be confusing.

```sh
cd APP
npm run deploy # deploys to gh-pages branch
```

## Related Docs

* [../README.md](../README.md): product and system overview.
* [../API/README.md](../API/README.md): regional FastAPI control plane.
* [../Firebase/README.md](../Firebase/README.md): Firestore schema, rules, indexes, roles, and limits.
* [../OCI/README.md](../OCI/README.md): regional host, Terraform, Caddy, WireGuard, and bootstrap.
* [../docs/regional-deployment.md](../docs/regional-deployment.md): new-region deployment flow.
