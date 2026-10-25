# Web dashboard

React/TypeScript and Tailwind dashboard, deployed as a static GitHub Pages app.
Firebase Auth owns sign-in; Firestore supplies authorized dashboard reads;
FastAPI owns client/user mutations and host state.

## Features and data

* Email/password, Google, and Apple sign-in, with an API product-access check.
* Enabled region discovery from the apex API and authenticated regional capacity.
* Client creation/removal, region filtering, and stored config QR/copy/download.
* Admin user creation, authorized cross-user clients, and Server Health.
* Browser approval for native device sign-in, plus a public macOS download link.

The dashboard never writes VPN client documents. Server Health reads
`Regions/*`, `Mesh/*`, and aggregate `Policy/*` status, and can change only
`Regions/{regionId}.meshEnabled` directly. Policy read failures stay separate
from mesh state. See [Firestore rules/schema](../../Backend/Firebase/README.md),
[API contracts](../../docs/api-contract.md), and [ACL observability](../../docs/access-control-list.md).

## Source map

* [App.tsx](src/App.tsx): HashRouter routes for dashboard, auth, device approval,
  account/admin pages, and Server Health.
* [firebase.ts](src/firebase.ts): Firebase Auth and provider helpers, configured
  by [firebaseConfig.ts](src/Secrets/firebaseConfig.ts).
* [Home.tsx](src/pages/Home.tsx) and [VPNTable.tsx](src/components/VPNTable.tsx):
  inventory, mutations, selection, and config export.
* [APIHelper.ts](src/helpers/APIHelper.ts) and [apiEndpoints.ts](src/helpers/apiEndpoints.ts):
  typed requests, bearer tokens, error handling, and apex/regional routing.
* [firebaseDbHelper.ts](src/helpers/firebaseDbHelper.ts): Firestore reads and
  the admin mesh toggle. [ociRegionsStore.ts](src/stores/ociRegionsStore.ts)
  caches discovery and fans out capacity reads.
* [ServerHealth.tsx](src/pages/ServerHealth.tsx): mesh/ACL status and region sync.
* [DeviceApproval.tsx](src/pages/DeviceApproval.tsx) and
  [deviceAuthHelper.ts](src/helpers/deviceAuthHelper.ts): approval/denial flow.

Device approval uses `/#/auth/code?deviceRequestId=<32 lowercase hex>&userCode=<6 digits>`.
It requires an authorized signed-in user, labels the device description unverified,
and asks the user to match codes. Framed pages stop before contacting the API.
Login accepts only a validated internal approval return route and skips regional
inventory on that path. Configure the
[Cloudflare anti-framing rule](../../Infrastructure/CloudFlare/README.md#dashboard-anti-framing-rule).

## Local development

Use Node.js 24 or newer and npm 10 or newer; see [tool versions](../../docs/tool-versions.md).

```sh
cd Frontend/Web
npm install
npm run start
```

Start runs CRA without opening a browser and watches Tailwind automatically.
`src/input.css` generates `src/output.css`; production builds minify it before
CRA optimization. No separate watcher command is needed.

## API Origin Behavior

Production URLs use `window.location.hostname`:

* Apex: `https://api.<hostname>/api/*`.
* Regional: `https://<regionId>.<hostname>/api/*`.

On localhost/local hostnames without an override, helpers use the CRA proxy:
`/api/*` goes to `https://api.gocloudlaunch.com`; paths such as
`/api/regions/us-sanjose-1/capacity` go to
`https://us-sanjose-1.gocloudlaunch.com/api/capacity`. The proxy runs only during
`npm run start`.

Leave `REACT_APP_API_ORIGIN` unset for normal local and production builds.
Setting it sends every API call to `<override>/api/*`, bypassing regional routing.
Use it only with a compatible local/regional endpoint; restart CRA after changes.
Setting it to the deployed apex API incorrectly routes regional requests there.

## Validation and deployment

Run `./scripts/test.sh web` from the repository root for Jest, TypeScript,
Knip, and the CRA production build. See [Quick Deployment](../../docs/quick-deployment.md)
for the full release sequence.

Publish from a clean working tree:

```sh
./scripts/deploy-react.sh
```

The wrapper runs `npm run deploy` in the web directory, bumps the npm patch
version, builds the local checkout, publishes `build/` to `gh-pages`, and commits
the package-version change locally. It does not fetch a remote source branch or
push the source commit. [public/CNAME](public/CNAME) must match the DNS hostname.
Direct `npm run deploy` publishes too, but leaves the version change uncommitted.

## macOS download

The shared navbar offers a notarized DMG before/after sign-in, with requirements
and install steps. [macAppRelease.ts](src/helpers/macAppRelease.ts) pins version,
build, and exact public GitHub asset URL. Update it after publishing a Mac release,
then deploy the site. macOS releases receive GitHub's Latest badge; Caddy releases
preserve that selection. See the [macOS release guide](../../docs/apple-macos-release.md).
