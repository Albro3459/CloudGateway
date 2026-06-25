# Deployment

## Test

Run the full suite; everything must pass before deploying:

```sh
./scripts/test.sh
```

## Deploy the frontend

```sh
cd APP && npm run deploy && cd -
```

## Deploy regional servers

1. Commit and push all your changes.
2. Back up Firestore before replacing any regional server:

   ```sh
   source API/.venv/bin/activate
   python3 scripts/backup_firestore.py
   ls -lh Firebase/backups
   ```

   Confirm a new `Firebase/backups/backup-<timestamp>.json` file exists before continuing.

3. Optional: build and publish a new prebuilt Caddy binary if the Caddy build inputs changed:

   ```sh
   ./scripts/caddy-release.sh
   ```

   This creates a `caddy-v<x>` GitHub Release and writes `caddy_binary_tag` / `caddy_binary_sha256` into the configured gitignored regional tfvars. Skip this when the existing pinned Caddy binary is still correct.

4. Deploy one or more regions:

   ```sh
   ./scripts/terraform.sh <region> [<region> ...]
   ```

`<region>` is a short name (`chicago`, `sanjose`) or a full region id (`us-chicago-1`).
Each region must have a matching gitignored `OCI/terraform/<regionId>.terraform.tfvars`.

This deploys new VPN servers from your local branch. It validates every listed
tfvars file has a `source_ref`, saves the final plan for each region, then bumps
`API/src/version.py`, makes and pushes one `Deploy v<x>` commit and matching
`deploy-v<x>` tag, writes that same tag to every listed region's `source_ref`,
and applies each saved plan in sequence. The host downloads the pinned Caddy
binary release and verifies it against `caddy_binary_sha256` during bootstrap.
**This destroys and replaces the existing VPN server in each listed region.**

Useful forms:

```sh
./scripts/terraform.sh chicago plan
./scripts/terraform.sh chicago sanjose plan
./scripts/terraform.sh chicago sanjose
./scripts/terraform.sh chicago destroy
```

If a multi-region apply fails partway through, the script stops. Regions already
applied stay deployed; fix the failed region and rerun.

For the manual, by-hand fallback, see [regional-deployment.md](regional-deployment.md).
