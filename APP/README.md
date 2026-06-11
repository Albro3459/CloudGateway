# CloudLaunch Frontend

React + TypeScript dashboard for the shared regional VPN platform. Users pick a region, add/remove WireGuard clients, and view stored configs (QR, download, copy) from Firebase.

### Running the React Site

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

### API Origin Behavior

* Production builds derive each regional API URL from the selected region and the current frontend origin: `https://<regionId>.<origin>/api/*`, where `<origin>` comes from `window.location.host`. For a frontend loaded from `https://gateway.gocloudlaunch.com`, region `us-sanjose-1` calls `https://us-sanjose-1.gateway.gocloudlaunch.com/api/*`.
* `REACT_APP_API_ORIGIN` is a local/dev override only. When set, API helpers send all API calls to `${REACT_APP_API_ORIGIN}/api/*` instead of deriving a regional hostname. Use it to point at a locally running regional API.
* Production builds leave `REACT_APP_API_ORIGIN` unset. There is no global API router and no Cloudflare Worker dev proxy.

### Data Flow

* Regions, client documents, and stored WireGuard configs are read from Firebase.
* Client create/delete and admin create-user go through the regional FastAPI routes (`POST /api/clients`, `DELETE /api/clients/{clientId}`, `POST /api/users`) with a Firebase bearer token. The frontend never writes client documents directly.

### Tailwind

Keep tailwind css updated while making changes:
```sh
cd APP
npx @tailwindcss/cli -i ./src/input.css -o ./src/output.css --watch
```

---

### Deploy GitHub page:

* [CNAME](./public/CNAME) specifies the host name. This must match DNS records.
* NOTE: This uses your local build code to deploy. It does NOT pull from any remote branch. It compiles your code to the build folder and deploys that.
    * Pro: Can be ran from any branch
    * Con: Must be run locally and it can be confusing

```sh
cd APP
npm run deploy # deploys to gh-pages branch
```
