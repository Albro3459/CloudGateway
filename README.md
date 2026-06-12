# CloudLaunch

## About

* Live at: [gocloudlaunch.com](https://www.gocloudlaunch.com/)

* Shared regional <b>WireGuard VPN</b> platform. Each OCI region runs one long-lived WireGuard server.

* Users do not deploy or terminate their own servers. The dashboard adds and removes WireGuard clients on the existing regional servers and shows stored configs from Firebase.

* View, copy, download, or QR-code your client config straight from the dashboard.

## Architecture

```text
React dashboard
  -> Firebase Auth
  -> Firebase reads for dashboard data/config display
  -> https://<region>.<origin>/api/*
      -> Cloudflare proxied DNS
      -> Caddy on regional OCI server
      -> FastAPI on 127.0.0.1
      -> Firebase Admin SDK
      -> WireGuard host commands

WireGuard client
  -> wg.<regionId>.<origin>:51820 (non-proxied DNS -> server public IPv4)
  -> wg0 on regional OCI server
```

Cloudflare fronts the regional API only. It is not part of the VPN data path; WireGuard clients resolve the non-proxied (grey-cloud) `wg.<regionId>.<origin>` record and connect directly to the server's public IPv4.

### Components

* <b>React dashboard</b> (`APP/`): region tabs, client create/remove, config display with QR/download/copy. Reads regions and client docs from Firebase.
* <b>Firebase</b>: Auth plus Firestore. Product source of truth for users, regions, clients, roles, limits, and stored WireGuard configs.
* <b>Regional API</b> (`API/`): FastAPI control plane on each regional server. Runs as root via `cloudlaunch-api.service`, binds only to `127.0.0.1`, verifies Firebase ID tokens, writes product state through the Firebase Admin SDK, and mutates host WireGuard under a local lock.
* <b>Caddy</b>: custom build with `github.com/mholt/caddy-ratelimit`. Automatic HTTPS, Cloudflare Authenticated Origin Pulls, exact regional Host/SNI allowlist, rate limiting (including `/api/health`), strips `/api/*`, and proxies only to `127.0.0.1:<fastapi_port>`. Host firewall accepts public `80`/`443` only from Cloudflare IP ranges.
* <b>WireGuard</b>: bare metal on the regional host. `/etc/wireguard/wg0.conf` is interface-only; peers live in Firebase and on the live interface, applied by the API with `wg set` and rebuilt at boot by `cloudlaunch-sync-peers`.
* <b>AWS</b>: SES email only. Lambda, DynamoDB, Secrets Manager VPN configs, and the Cloudflare Worker are not part of the platform.

## Regional API URLs

* Each region serves its API at `https://<regionId>.<origin>/api/*`, where `<origin>` is the frontend origin host, for example `gateway.gocloudlaunch.com`.
* In production the frontend derives the URL from the selected region's `regionId` plus the current `window.location.origin`. There is no global API router and no base-domain config.
* `REACT_APP_API_ORIGIN` is a local/dev override only. When set, API helpers call `${REACT_APP_API_ORIGIN}/api/*`. Production builds leave it unset.

## Source of Truth

* Firebase is the single source of truth: users, regions, clients, roles, limits, stored configs, and the WireGuard peer set.
* Peers are never saved to `wg0.conf` or any other host state file. Client create/delete updates Firebase and applies the live `wg0` change in one locked operation.
* On reboot, `wg-quick` brings up the interface from the static config and `cloudlaunch-sync-peers` rebuilds the peer set from Firebase. The same command repairs drift on demand; see [docs/wireguard-drift-repair.md](docs/wireguard-drift-repair.md).

## Clean Cutoff

* No migration from the old per-user VPN stacks. Old Lambda-created servers and old client configs are not supported and cannot be recovered.
* Users on the old model must create new clients in the shared regions.

## Privacy and Logging

* API logs are required and are structured JSON. They may include request IDs, routes, operation status, and user emails/display names, because those are needed to operate the control plane.
* VPN traffic logs are forbidden. Never log DNS queries, domains or destination IPs requested by VPN users, browsing/app traffic metadata, packet metadata, or per-user connection history.
* Never log WireGuard private keys, full WireGuard configs, Firebase service account secrets, or auth tokens.

## Languages and Frameworks

* React with TypeScript and TailwindCSS for the frontend
* Python with FastAPI for the regional control plane
* Firebase for Authentication and Database
* Caddy (custom build with rate limiting) for the regional API edge
* OCI Compute and Terraform for regional servers
* AWS SES for email

## Usage

* Only the admin account is active for the time being.

* [Email me](mailto:brodsky.alex22@gmail.com) or message me on [LinkedIn](https://www.linkedin.com/in/brodsky-alex22/) if you want to try it.

* To save the config file or scan the QR code, on either the phone or computer, you need the WireGuard app because the VPN uses the WireGuard protocol.
  * Desktop: [wireguard.com](https://www.wireguard.com/install/) or for iPhone: [AppStore](https://apps.apple.com/us/app/wireguard/id1441195209)

#### On Phone

* Install the WireGuard app on your phone.

* Either download the config file or scan the QR code in the WireGuard app.

* Enable it in WireGuard and Settings and you're done!

#### On Mac

* It's much easier to use the WireGuard Desktop app, but you can follow these steps instead:

* Start WireGuard manually:
  ```sh
  wg-quick up wg-client
  ```

* Check status:
  ```sh
  sudo wg
  ```

* To stop it:
  ```sh
  wg-quick down wg-client
  ```

## More Docs

* Frontend: [APP/README.md](APP/README.md)
* Regional API: [API/README.md](API/README.md)
* Regional server / Terraform: [OCI/README.md](OCI/README.md)
* Deployment and operations runbooks: [docs/](docs/)
