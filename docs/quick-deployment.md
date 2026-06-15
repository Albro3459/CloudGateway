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

## Deploy a regional server

1. Commit and push all your changes.
2. Deploy the region:

   ```sh
   ./terraform.sh <region>
   ```

`<region>` is a short name (`chicago`, `sanjose`) or a full region id (`us-chicago-1`).

This deploys a new VPN server in `<region>` from your local branch. It bumps
`API/src/version.py`, makes and pushes a new `Deploy v<x>` commit and matching
`deploy-v<x>` tag, then runs `terraform apply`. **This destroys and replaces the
existing VPN server in `<region>`.**

For the manual, by-hand fallback, see [regional-deployment.md](regional-deployment.md).
