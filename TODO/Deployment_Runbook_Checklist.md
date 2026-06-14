# Deployment Runbook Checklist

Ordered, corrected checklist for bringing up the first shared regional WireGuard
server and validating it end to end. Chicago (`us-chicago-1`) first, then San Jose
(`us-sanjose-1`). This consolidates `docs/regional-deployment.md`,
`docs/github-deployment-setup.md`, and `OCI/README.md` with the gotchas that bite
during a real deploy. The runbooks remain the detailed source of truth.

Region values used below:

- `regionId` = `us-chicago-1`
- API hostname = `us-chicago-1.gateway.gocloudlaunch.com` (orange cloud)
- WG endpoint = `wg.us-chicago-1.gateway.gocloudlaunch.com` (grey cloud)
- CORS origin = `https://gateway.gocloudlaunch.com`

---

## Step 0 - Local gate (cheap, before any cloud spend)

- [ ] `./test.sh` passes (api + app + infra: pyright, pytest, jest, tsc, CRA build,
      terraform validate, host script parse).

## Step 1 - Push a deploy tag

The host fetches `bootstrap.sh` + `API/` from GitHub at boot. The ref must be on
GitHub before deploying. Repo is public, so unauthenticated codeload works.

- [ ] Tag the deployable commit and push it:
      ```sh
      git tag -a deploy-v1.0.0 <commit-sha> -m "deploy-v1.0.0"
      git push origin deploy-v1.0.0
      ```
- [ ] Set `source_ref = "deploy-v1.0.0"` in each region's `<regionId>.terraform.tfvars`.
- Notes: a tag pointing at a commit on any branch works (codeload serves any ref).
  Never move a published `deploy-*` tag - cut a new one.

## Prerequisites (already done - confirm only)

- [x] OCI networking for both regions: compartment, subnet, routed IPv6, security
      lists (`22` from your /32, UDP `51820` from `0.0.0.0/0`+`::/0`, TCP `80`/`443`
      Cloudflare ranges only), egress to `0.0.0.0/0`+`::/0`.
- [x] Firebase `Instances` collection-group index on `regionId` (create/delete
      transactions fail without it).

## Step 2 - Vars and envs

- [ ] `OCI/terraform/us-chicago-1.terraform.tfvars` filled for `us-chicago-1`: region ids,
      `oci_config_profile`, `api_hostname`, `dashboard_cors_origin`, `fastapi_port`,
      `wg_endpoint_hostname`, tunnel DNS IPs, `wg_server_private_key`, Firebase credentials,
      `caddy_acme_email`, `hashed_password`, `source_ref`.
- [ ] `~/.oci/config` has a `[us-chicago-1]` profile (its tenancy's API key) matching
      `oci_config_profile`. SJ and Chicago are different tenancies - one profile each.
- [ ] Firebase Admin credentials available to the host (inline `firebase_credentials_json`
      or copied to `firebase_credentials_file`).
- [ ] Frontend `APP/src/Secrets/firebaseConfig.ts` present for the prod build.
      `REACT_APP_API_ORIGIN` stays UNSET for production.

## Step 3 - Apply Terraform (Chicago)

- [ ] `./terraform.sh chicago plan` (short name expands to `us-chicago-1`; selects
      that workspace + var file; isolated state so it can't clobber San Jose).
- [ ] `./terraform.sh chicago apply`
- [ ] Record the instance public IPv4.
- [ ] On the host, confirm: `wg0` up, `wg0.conf` has NO `[Peer]` blocks,
      `cloudlaunch-api.service` active on `127.0.0.1`, `cloudlaunch-sync-peers.service`
      succeeded (empty region = successful empty sync), Caddy on `80`/`443`,
      `/etc/cloudlaunch/api.env` mode `0600` root-owned with matching `CLOUDLAUNCH_REGION_ID`.
- [ ] If bootstrap failed: `/var/log/wireguard-bootstrap.log` /
      `journalctl -t wireguard-bootstrap`.

## Step 4 - Cloudflare (mostly automated now)

- [x] One-time per zone: SSL/TLS = Full (strict); Origin CA cert in `origin_cert`/`origin_key`;
      Authenticated Origin Pulls Global + Zone on (no uploaded cert). See `CloudFlare/README.md`.
- [ ] DNS is **Terraform-managed** - `apply` creates the orange API + grey wg `A` records from
      the instance IP. Before the first apply, DELETE any pre-existing manual `us-chicago-1` +
      `wg.us-chicago-1` records (the Cloudflare provider errors on a name that already exists).

## Step 5 - Validate `/api/health`

- [ ] `curl -s https://us-chicago-1.gocloudlaunch.com/api/health`
      -> `{ "status": "ok", "regionId": "us-chicago-1" }`
- [ ] Confirm direct origin is REJECTED:
      ```sh
      curl -sk --resolve us-chicago-1.gocloudlaunch.com:443:<public-ipv4> \
        https://us-chicago-1.gocloudlaunch.com/api/health
      ```
      If this returns healthy, the origin is reachable without Cloudflare - STOP and
      fix the firewall/Caddy before enabling the region.

## Step 6 - Firebase

- [ ] Region doc is **self-seeded** by the host (`cloudlaunch-register-region` at end of
      bootstrap): it sets the IP/pubkey/endpoint, `enabled: true` only once the full Cloudflare
      path validates (health checked through the edge, not just loopback), and preserves
      `activeClientCount`. Just confirm `Regions/us-chicago-1` appeared and looks right.
- [ ] Admin `Users/{uid}` + `Roles/{uid}` (`role: admin`) - still manual. The per-user limit
      lives on the region doc (`userClientLimit`); admins are bounded by `capacityLimit`.

## Step 7 - Deploy frontend

- [ ] `cd APP && npm run deploy` (builds locally, pushes to `gh-pages`). `CNAME` and
      `package.json` homepage are already `gateway.gocloudlaunch.com`.
- [ ] Load the dashboard, confirm Firebase auth works and the API call path resolves
      to `https://us-chicago-1.gateway.gocloudlaunch.com/api/*`.

## Step 8 - Test client lifecycle

- [ ] Flip region doc `enabled: true`.
- [ ] Create a client from the dashboard. Confirm `status: active`, assigned tunnel
      IPv4/IPv6, config `Endpoint = wg.us-chicago-1.gateway.gocloudlaunch.com:51820`.
- [ ] Confirm doc at `Users/{uid}/Regions/us-chicago-1/Instances/{clientId}` and
      `activeClientCount` incremented.
- [ ] On host: peer present in `sudo wg show wg0` (`wg0.conf` stays peer-free).
- [ ] Delete the client. Peer gone, doc `status: removed`, counter decremented.

## Step 9 - Verify VPN + DNS filtering

- [ ] Load a client config in WireGuard (QR/download), activate tunnel.
- [ ] `sudo wg show wg0 latest-handshakes` shows a handshake.
- [ ] Traffic + DNS resolve through the tunnel.
- [ ] `systemctl status adguardhome` and `systemctl status unbound` active; a known
      ad/tracker domain is blocked. Remove the test client.

The region is live - leave `enabled: true`.

---

## After Chicago is green

- [ ] Repeat Steps 2-9 for San Jose (`us-sanjose-1`).
- [ ] Rebuild/IP-change test: a `terraform apply` that touches `user_data` destroys
      and recreates the VM (new IP). Client keeps working ONLY after you update the
      grey-cloud `wg.` A record + region doc `wireguardEndpointIpv4`; user re-toggles
      the tunnel (it re-resolves the hostname). See `docs/vm-loss-recovery.md`.
      API-only change = `sudo cloudlaunch-install-api <ref>`, no rebuild.
- [ ] Tear down old San Jose / Chicago per-user stacks; help friends move to the
      shared regions (clean cutoff - no migration).
- [ ] Decide CloudLaunch vs CloudGateway naming, then redirect the old site.

## Known cleanup / open items (non-blocking)

- [ ] SES: no email send exists anywhere (deploy or remove). Either re-add
      deliberately or strip SES mentions from the READMEs.
- [ ] Update `README.md` branding (still says CloudLaunch / gocloudlaunch.com).

## Nice-to-haves (after end-to-end works)

- [ ] Dark mode / frontend UI polish (partially landed).
- [ ] Copy IP with a tap.
- [ ] Create-new-users flow.
- [ ] Google sign-in: ungranted account is disabled on login; admin grant re-enables
      and provisions. Test both paths.
- [ ] Remove one / multiple clients at once.
- [ ] Logo, GitHub/social images, resume / LinkedIn / Handshake.
