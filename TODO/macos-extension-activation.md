# macOS extension activation

Status: packaging fixed and signed validation passed, live retry pending

The first live setup attempt failed with system-extension error 9. The supplied
`sysextd` log identifies a missing `NSSystemExtensionUsageDescription` in the
network extension's bundle during category validation. Staging succeeded, then
macOS rejected and uninstalled the invalid extension before user approval.

Added the required user-facing explanation to the tunnel Info.plist. Packaging
verification now rejects missing, blank, or non-string descriptions, with
regression coverage. This check runs for both unsigned and signed builds.

`./scripts/test.sh macos --signed` passed, including packaging regressions,
shared package/WireGuard tests, 100 macOS tests, both macOS Periphery scans,
the signed Release build, and packaging/signing verification. The old app in
`/Applications` now fails the new check with the expected description error.
Validation log: `/tmp/cloudgateway-macos-usage-description-fix.log`.

This fixes the diagnosed packaging omission. Another live activation attempt
is needed to confirm approval and runtime startup after replacing the app.
No live activation or VPN commands were performed by the agent. Nothing was pushed.
