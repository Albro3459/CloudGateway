# macOS signing verifier

Status: resolved

The signed Release build succeeded, but packaging verification reported
`Invalid file`. Reproduced the failure in `verify_signature`: `codesign --display
--entitlements -` returned human-readable `[Dict]` output, which `plistlib.loads`
cannot parse.

The verifier now requests `--xml`. Both built targets passed entitlement and
profile checks with that format, and direct signed bundle verification passed.
A regression covers signed app and extension verification with text output
unless XML is explicitly requested.

`./scripts/test.sh macos --signed` passed, including all nine packaging verifier
tests, shared package/WireGuard regressions, 100 macOS tests, both macOS
Periphery scans, the signed Release build, and packaging/signing verification.
Validation log: `/tmp/cloudgateway-macos-signed-xml-fix.log`.
No extension activation, VPN commands, index changes, commits, or pushes.
