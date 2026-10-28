# Apple clients

CloudGateway ships an iOS app, a macOS menu app, and the `cloudgateway` CLI.
Shared Swift packages contain VPN/config APIs and app service contracts;
platform targets own UI, lifecycle, signing, and adapters.

* [iOS app](iOS/README.md): API integration, validation, and App Store releases.
* [macOS app and CLI](macOS/README.md): installation, usage, command reference,
  and client-removal contract.
* [Shared packages](CloudGatewayKit/README.md): Kit/AppCore responsibilities.
* [iOS architecture](../../docs/apple-ios-app.md): config storage, profile
  ordering, packet lifecycle, and auth boundaries.
* [macOS development](../../docs/apple-macos-development.md): controller,
  signing, root/user storage, and runtime checklist.
* [macOS releases](../../docs/apple-macos-release.md): version policy,
  notarization, resumption, and publication.
* [Local macOS install](../../docs/quick-deployment.md#install-macos-app-for-local-testing):
  signed testing build and installation command.
* [Known issues](../../docs/apple-known-issues.md): observed platform failures,
  evidence, and mitigations.
* [Tunnel health](../../docs/apple-tunnel-health-notification.md): iOS detection,
  recovery, and notification policy.
* [Screenshots](../../docs/apple-screenshots.md): iOS fixtures and native macOS menu.

Use `./scripts/test.sh ios`, `macos`, or `apple` from the repository root.
Add `--signed` for provisioning/signature checks. Runtime VPN and approval
checks remain manual; documentation-only edits need manual review.

Package tests use the native SwiftPM build system. When a package's Periphery
scan succeeds in the same invocation, tests reuse its built test executables.
If the scan fails or Periphery is unavailable, the tests build normally.
Production scans keep their own indexes, separate from package tests.
