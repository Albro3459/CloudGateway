# macOS stack review: IPC security and controller handoff

Reviewed `mac-cli` at `5ba539b7dd71c4b5f82990051b4d47424cada02a` on 2026-10-23.
Ranges: `origin/main..mac-refactor-to-controller-architecture` (PR17), then
`mac-refactor-to-controller-architecture..HEAD` (PR16), assessed together.

## Confirmed findings

No confirmed P1/P2 findings in this scope. No code changes proposed.

## Coverage

- Controller peer boundary: non-root matching real/effective local UID, same-user
  connection admission and per-call UID checks, Apple-anchored team/bundle signing
  requirements on both peers, request/reply size bounds, connection/request limits,
  cancellation and single-completion reply handling. References:
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerXPC.swift:10,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerXPC.swift:64,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacIPC/CloudGatewayMacXPC.swift:25
- Signed build identity: running-code verification, strict installed-bundle and
  nested-code validation, signed version/build metadata, CodeDirectory-derived
  fingerprint, rejection of unsigned inputs and symlinked installed paths.
  References:
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacIPC/CloudGatewayMacBuildIdentity.swift:31,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacIPC/CloudGatewayMacBuildIdentity.swift:51
- Controller launch and ownership: fixed executable path, signature validation in
  the production bootstrap adapter, launchd user domain and Background session,
  private plist, per-user bootstrap/owner locks, component-wise directory opens,
  file owner/mode/type/link checks, stable lock inode and close-on-exec descriptors.
  References:
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacMenuClient.swift:11,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacControllerLaunch.swift:49,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacControllerLaunch.swift:165,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacControllerLaunch.swift:235,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacControllerLaunch.swift:277
- Launch/reconnect operation boundaries: durable request admission before effects,
  reservation/confirmation split, session check at confirmation, transport-loss
  survival of accepted mutations, read-only preparation cancellation, controller
  instance/generation fencing, no automatic resend of a lost confirmation,
  compatible stop/status/lookup during replacement, and fixed-path menu relaunch.
  References:
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerRequests.swift:65,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift:423,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift:454,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacFrontendClient.swift:263,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacFrontendClient.swift:344,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacAppController.swift:101
- Production wiring: ownership precedes Firebase creation, runtime remains lazy for
  lifecycle/diagnostics, service shutdown checks orchestrator and transport work,
  menu/CLI share the authenticated production adapter, and snapshot contracts omit
  configs, private keys, secret references and auth tokens. References:
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift:21,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift:187,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerRuntime.swift:27,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/main.swift:29,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerState.swift:5
- Secret IPC changes: build-specific privileged Mach endpoint, captured signed
  extension identity in ping responses, unchanged per-user secret ownership and
  single-use start grants, and extension startup ordering. Compared the secret
  transport/service with `origin/main`; the service implementation is unchanged.
  References:
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacIPC/CloudGatewayMacXPC.swift:43,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacIPC/CloudGatewayMacSecretService.swift:5,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayTunnel/main.swift:5
- Related release assumptions: distinct extension-build endpoint, independent
  app/extension versions, fresh extension build relative to the prior signed
  artifact, release artifact drift checks, Developer ID Hardened Runtime and
  debugging entitlement verification. References:
  /Users/alexbrodsky/GitHub/CloudGateway/scripts/macos-release.py:114,
  /Users/alexbrodsky/GitHub/CloudGateway/scripts/macos-release.py:148,
  /Users/alexbrodsky/GitHub/CloudGateway/scripts/verify_macos_build.py:163,
  /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway.xcodeproj/project.pbxproj:101

## Limits and documented behavior

This is a static review, not proof of signed runtime behavior. No tests, builds,
live app, VPN, SSH, shell scripts, or runtime security probes were run. Existing
fixtures were read only. No source, index, branch or commit changes were made.

Lost in-memory ordinary results after restart/replacement, the latest-result-only
recovery window, bounded receipt capacity, and the first lifecycle installation's
one-time controller restart are explicitly documented, so they are not findings.
Background Firebase Keychain access, pre-desktop SSH and Apple's extension
replacement behavior remain the existing signed-runtime proof gates. See:
/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/README.md:249,
/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/README.md:391,
/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/README.md:424,
/Users/alexbrodsky/GitHub/CloudGateway/docs/apple-known-issues.md:1,
/Users/alexbrodsky/GitHub/CloudGateway/docs/apple-macos-development.md:21

Auth/domain semantics and the managed update workflow belong to the other review
scopes. This review followed their production entry points only where needed to
check IPC authorization, handoff and ownership.
