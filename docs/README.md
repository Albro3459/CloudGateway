# Documentation

Start with [Quick Deployment](quick-deployment.md) for commands and side effects,
or the [root README](../README.md) for the product overview.

## Development and contracts

* [Tool versions](tool-versions.md): supported local tools and deployed pins.
* [Web dashboard](../Frontend/Web/README.md): development, routing, and publication.
* [Apple clients](../Frontend/Apple/README.md): iOS, macOS, CLI, and shared packages.
* [Regional API](../Backend/API/README.md): local setup and service architecture.
* [API contracts](api-contract.md): routes, payloads, authorization, and errors.
* [Device sign-in](device-auth.md): browser approval and native token exchange.
* [Firestore](../Backend/Firebase/README.md) and [indexes](../Backend/Firebase/indexes.md):
  schema, access rules, backups, and required indexes.

## Deployment and operations

* [OCI/Terraform](../Infrastructure/OCI/README.md): regional inputs and deployment.
* [GitHub bootstrap setup](github-deployment-setup.md): deploy refs and host fetching.
* [API deployment handoff](deployment-handoff.md): service layout and environment.
* [Regional deployment](regional-deployment.md): manual setup and verification.
* [Service operations](service-operations.md): upgrades, host policy, and mesh rollout.
* [VM loss recovery](vm-loss-recovery.md): rebuild without losing client identity.
* [WireGuard drift repair](wireguard-drift-repair.md): reconcile live peers with Firebase.
* [Cloudflare](../Infrastructure/CloudFlare/README.md): API DNS/edge protection.
* [DNS filtering](../Infrastructure/OCI/adguard-home.md): AdGuard Home and Unbound.
* [Caddy build](../Infrastructure/OCI/caddy/README.md): pinned API-edge binary releases.

## Network policy

* [Account-scoped ACL](access-control-list.md): enforcement, identity, and status.
* [ACL live verification](acl-live-verification.md): controlled runtime checks.
* [Shared subnet mesh](shared-subnet-mesh.md): cross-region routing and reconciliation.

Apple-specific architecture, releases, screenshots, troubleshooting, and health
policies are indexed in the [Apple guide](../Frontend/Apple/README.md).
