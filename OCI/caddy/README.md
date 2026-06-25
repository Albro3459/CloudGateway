# CloudGateway Caddy Binary

Builds the Linux ARM64 Caddy binary used by regional OCI hosts.

The binary is built with:

* Caddy `v2.8.4`
* `github.com/mholt/caddy-ratelimit`

Create a release with:

```sh
./scripts/caddy-release.sh
```

The script publishes one GitHub Release asset named `cloudgateway-caddy-linux-arm64`
and updates the configured gitignored regional tfvars with `caddy_binary_tag`
and `caddy_binary_sha256`.
