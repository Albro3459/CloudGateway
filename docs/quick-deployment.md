# Deployment

## Test

Run the full suite; everything must pass before deploying:

```sh
./test.sh
```

## Deploy the frontend

```sh
cd APP && npm run deploy && cd -
```

## Deploy regional servers

1. Commit and push all your changes.
2. Deploy one or more regions:

   ```sh
   ./terraform.sh <region> [<region> ...]
   ```

`<region>` is a short name (`chicago`, `sanjose`) or a full region id (`us-chicago-1`).
Each region must have a matching gitignored `OCI/terraform/<regionId>.terraform.tfvars`.

This deploys new VPN servers from your local branch. It validates every listed
tfvars file has a `source_ref`, saves the final plan for each region, then bumps
`API/src/version.py`, makes and pushes one `Deploy v<x>` commit and matching
`deploy-v<x>` tag, writes that same tag to every listed region's `source_ref`,
and applies each saved plan in sequence. **This destroys and replaces the
existing VPN server in each listed region.**

Useful forms:

```sh
./terraform.sh chicago plan
./terraform.sh chicago sanjose plan
./terraform.sh chicago sanjose
./terraform.sh chicago destroy
```

If a multi-region apply fails partway through, the script stops. Regions already
applied stay deployed; fix the failed region and rerun.

For the manual, by-hand fallback, see [regional-deployment.md](regional-deployment.md).
