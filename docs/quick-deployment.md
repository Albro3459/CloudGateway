# Deployment

## Test

Run the full suite; everything must pass before deploying:

```sh
./scripts/test.sh
```

## Deploy the frontend

```sh
./scripts/deploy-react.sh
```

## Build iOS App Store archive

The release script always increments the iOS build number. It keeps the
marketing version unchanged unless a version flag is supplied. It validates the
individual App Store Connect API key, archives with source Firestore, exports an
IPA, uploads it with Transporter, and commits the project-file bump. It does not
push the commit.

```sh
./scripts/ios-release.sh
./scripts/ios-release.sh --version patch
./scripts/ios-release.sh --version minor
./scripts/ios-release.sh --version major
```

The script expects the team API key at
`$HOME/.ssh/Apple_API_KEY/AuthKey_YDM2P5LSK8.p8` with mode `600`.
The key ID and issuer ID are identifiers, not secrets; the `.p8` file must
never be committed or logged.

Code signing uses your login keychain. If it is locked, the release script
unlocks it and macOS prompts for the password. To unlock it beforehand, run the
command without a password so macOS prompts for it:

```sh
security unlock-keychain "$HOME/Library/Keychains/login.keychain-db"
```

See [apple-ios-app.md](apple-ios-app.md#app-store-archive) for the full docs.

## Deploy regional servers

1. Commit and push all your changes.
2. Back up Firestore before replacing any regional server:

   ```sh
   Backend/API/.venv/bin/python3 scripts/backup_firestore.py
   ls -lh Backend/Firebase/backups
   ```

   Confirm a new `Backend/Firebase/backups/backup-<timestamp>.json` file exists before continuing.

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
Each region must have a matching gitignored `Infrastructure/OCI/terraform/<regionId>.terraform.tfvars`.

This deploys new VPN servers from your local branch. It validates every listed
tfvars file has a `source_ref`, saves the final plan for each region, then bumps
`Backend/API/src/version.py`, makes and pushes one `Deploy v<x>` commit and matching
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

5. Optional: Clear [~/.ssh/known_hosts](~/.ssh/known_hosts) after the new server deployment

`ssh` will yell at you that the IP of your host changed when you try to ssh into the new server, so run this to clear them from `known_hosts` to avoid that:
```sh
# Check first:
ssh-keygen -F wg.us-sanjose-1.gocloudlaunch.com 
ssh-keygen -F wg.us-chicago-1.gocloudlaunch.com

# Clear:
ssh-keygen -R wg.us-sanjose-1.gocloudlaunch.com 
ssh-keygen -R wg.us-chicago-1.gocloudlaunch.com
```
