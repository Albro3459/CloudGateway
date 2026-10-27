# CloudGateway

CloudGateway is a shared regional WireGuard VPN platform, live at
[gocloudlaunch.com](https://www.gocloudlaunch.com/). Each OCI region runs one
long-lived server. Use the macOS app, `cloudgateway` CLI, or iOS app to manage
clients and connections. The web dashboard also provides config export and admin
tools. Firebase owns product state and stored configs.

Built from [CloudLaunch](https://github.com/Albro3459/CloudLaunch), extending its
VPN proof of concept into a shared regional service.

## Screenshots

### iOS app

<div style="display: flex; justify-content: center; align-items: center; flex-wrap: wrap; gap: 80px;">
  <img src="https://github.com/user-attachments/assets/fe33a1c2-7c88-4047-8647-7a8fb5b721ac" alt="Dashboard" height="400"/>
  <img src="https://github.com/user-attachments/assets/e8fe3bf2-fe29-4c92-857e-0b30b449dbc2" alt="Login" height="400"/>
</div>

### macOS app

<div style="display: flex; justify-content: center; align-items: center;">
  <img src="https://github.com/user-attachments/assets/8023a276-da32-4822-87b0-621578094f08" alt="macOS menu bar app" height="400"/>
</div>

### Website

<div style="display: flex; justify-content: center; align-items: center; flex-wrap: wrap; gap: 80px;">
  <img src="https://github.com/user-attachments/assets/82ceba8e-bb29-45bd-87c3-3fe118f929ec" alt="Dashboard" height="400"/>
  <img src="https://github.com/user-attachments/assets/31ca677e-c3b7-4acf-bb0a-419e149dc1fd" alt="Admin Region Sync" height="400"/>
</div>

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

* [Web dashboard](Frontend/Web/README.md): React/TypeScript and Tailwind,
  Firebase sign-in, region/client inventory, config export, and admin tools.
* [Apple clients](Frontend/Apple/README.md): iOS app, macOS menu app, and CLI.
  Kit/AppCore share VPN/config APIs and app contracts; platform targets own UI
  and runtime adapters. The Mac app and CLI share a background controller.
* [Regional API](Backend/API/README.md): FastAPI with Firebase Admin SDK and
  locked WireGuard/policy mutations. It runs as root on loopback behind Caddy.
* [Firebase](Backend/Firebase/README.md): Auth and Firestore, the source of truth
  for accounts, roles, regions, limits, clients, stored configs, and desired peers.
* [OCI hosts](Infrastructure/OCI/README.md): Terraform-managed WireGuard,
  Caddy, account isolation, and DNS filtering. AWS is used only for SES email.

### API routing and peer state

The apex API serves discovery/access at `https://api.<origin>/api/*`; regional
operations use `https://<regionId>.<origin>/api/*`. The web app derives these
hosts from its hostname. Local development uses the CRA proxy; see the
[web guide](Frontend/Web/README.md#api-origin-behavior) for overrides.

`wg0.conf` stays interface-only. Firebase owns desired peers; API mutations apply
live changes under a host lock, and boot/on-demand sync rebuilds peers from
Firebase. [Account-scoped ACLs](docs/access-control-list.md) isolate users;
[regional mesh](docs/shared-subnet-mesh.md) connects authorized clients across
regions. Never persist peers to host configuration files.

### DNS and privacy

AdGuard Home listens only on tunnel DNS addresses and sends allowed queries to
local Unbound. Unbound forwards over DNS-over-TLS to Quad9, Mullvad, and DNS.SB,
with local DNSSEC validation. DNS query logs and statistics are disabled.
See the [DNS guide](Infrastructure/OCI/adguard-home.md).

Control-plane JSON logs may contain request IDs, routes, outcomes, and user
emails. Never log VPN traffic, DNS queries, destination/packet metadata,
connection history, private keys, full configs, Firebase credentials, or auth tokens.
ACL logs/status expose aggregate counts, hashes, booleans, region IDs, and update
time only, with no account/client identifiers or tunnel addresses.

## Usage

* [Email me](mailto:brodsky.alex22@gmail.com) or message me on [LinkedIn](https://www.linkedin.com/in/brodsky-alex22/) if you want to try it.

* Use the CloudGateway macOS app or `cloudgateway` CLI on Mac, and the CloudGateway iOS app on iPhone or iPad.
* The native apps install the selected VPN profile and manage the tunnel through their packet tunnel extensions.

### iOS

* Build and install the CloudGateway iOS app from Xcode.
* Sign in with your Firebase email/password account.
* Choose one active config by client display name and region.
* Install the VPN profile, then start or stop the tunnel from the app.

### macOS

* Download the CloudGateway macOS app from [gocloudlaunch.com](https://www.gocloudlaunch.com/) and install it at `/Applications/CloudGateway.app`.
* Open the menu bar app and sign in through the browser.
* Complete the one-time VPN extension and profile approvals.
* Choose a client by name and region, then connect or disconnect from the menu. Use **Add Client** or **Remove Client** to manage clients.

### macOS CLI

* Choose **Install Command Line Tool…** from the macOS app menu to install `cloudgateway` at `~/.local/bin/cloudgateway`.
* Add `~/.local/bin` to your shell's PATH. The menu offers **Add to Zsh PATH…** for supported zsh setups; open a new login shell after setup.
* Use the same macOS user that completed desktop VPN setup. The CLI shares sign-in, inventory, and VPN state with the menu bar app.

```sh
cloudgateway auth login
cloudgateway list
cloudgateway up '<client-uuid>'
cloudgateway status
cloudgateway down
```

The CLI also supports client creation and removal, JSON output, diagnostics, and SSH use. See the [CLI setup and command reference](Frontend/Apple/macOS/README.md#command-line-tool).

### Linux CLI

The [Linux client](Frontend/Linux/README.md) targets Ubuntu VMs with the same
commands and JSON contract as the macOS CLI. It is implemented and tested
host-free, but hasn't been validated on Linux or released yet. See the
[design](docs/linux-cli-research.md) and [parity contract](docs/linux-cli-parity.md).

## Documentation

* [All guides and runbooks](docs/README.md)
* [Quick deployment](docs/quick-deployment.md)
* [Apple apps and CLI](Frontend/Apple/README.md)
* [Web development](Frontend/Web/README.md)
* [Tool versions](docs/tool-versions.md)
