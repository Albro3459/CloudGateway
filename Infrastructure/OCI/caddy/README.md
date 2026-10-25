# CloudGateway Caddy Binary

Regional OCI hosts use a Linux ARM64 Caddy binary built with Caddy `v2.8.4` and
`github.com/mholt/caddy-ratelimit`. The Dockerfile verifies the `http.handlers.rate_limit`
module before exporting `cloudgateway-caddy-linux-arm64`.

From the repo root:

```sh
./scripts/caddy-release.sh --dry-run
./scripts/caddy-release.sh
```

Both commands build with Docker Buildx and write a local artifact and SHA-256 hash.
`--dry-run` stops there. Publishing requires GitHub CLI authentication, a clean
working tree, and a branch matching its upstream. The script chooses the next
`caddy-vX.Y.Z` tag, updates `VERSION` and commits/pushes it when needed, creates a
GitHub Release with the binary, then writes `caddy_binary_tag` and
`caddy_binary_sha256` into the gitignored tfvars for the configured regions
(currently Chicago and San Jose).

Publishing has remote side effects and does not update running hosts. Bootstrap
downloads the pinned release asset and verifies its hash on the next [regional deployment](../../../docs/regional-deployment.md).
