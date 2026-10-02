# macOS security and tunnel lifecycle review

Review complete on branch `apple`, 2026-10-02. SEC-01 is resolved and validated.

## Confirmed findings

### SEC-01, P3: accepted payload can become an unreadable Keychain record

Status: implemented and validated. The store now encodes and bounds the
complete record before either add or update opens the Keychain. Both writes use
the same size limit as reads, so an oversized envelope fails with `invalidRequest`
before a secret is persisted. Host-free regression coverage checks small-record
round trips and an escaped valid config whose request fits but record does not.
No real Keychain access occurs in these tests.
Root passed both the Apple gate and final macOS rerun with the new boundary
and committed/uncommitted round-trip regressions.

* Location: `Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacIPC/CloudGatewayMacSystemKeychainStore.swift:28-30`
* Related paths: the add operation encodes records at line 11;
  `CloudGatewayMacXPC.swift:83-85,184-187` bounds the request;
  `CloudGatewayMacSecretService.swift:34-46` bounds the raw config and stores it
* Trigger: a valid WireGuard configuration with heavily escaped comment text
  makes its install request approach the 96 KiB request limit. The stored JSON
  replaces the action field with `ownerUserId` and `isCommitted`, adding bytes.
  WireGuard parsing discards comments but preserves them in `rawValue`, so the
  64 KiB raw-config bound does not prevent this case.
* Impact: install successfully writes a provisional secret. Subsequent reads
  reject its larger stored envelope, so commit, availability, rollback, and
  start fail with `storageFailure`. Rollback cannot remove the orphaned secret
  because it first reads the record. Generated production configs are small,
  so normal configurations do not reach this boundary.
* Smallest fix: define and enforce a separate encoded-record bound on both
  write and read, sized for the bounded raw config plus JSON escaping and
  metadata. Alternatively reject an oversized encoded record before adding it.
* Evidence: source trace plus a standalone JSON size calculation with synthetic
  all-zero test key material and ignored comment bytes. A 16,454-byte raw config
  produced a 98,304-byte request and a 98,323-byte record using compact JSON.
  Swift's slash escaping can shift both sizes equally; it does not remove the
  envelope difference. This was not exercised against a signed extension or
  the real System Keychain.

## Resolved hypotheses

* Concurrent active adapters were considered because the provider lifecycle is
  instance-local and WireGuardKit scans the process for a utun descriptor and
  installs a global log callback. Apple's
  [NETunnelProviderManager configuration model](https://developer.apple.com/documentation/networkextension/netunnelprovidermanager)
  allows only one enterprise VPN configuration to be enabled system-wide.
  Concurrent container apps alone do not establish concurrent active providers.
  This is not a confirmed finding. Repeated-session and provider teardown
  behavior still require the existing signed runtime checks.

## Evidence and limits

Source review confirms bidirectional code-signing requirements, caller macOS UID
ownership, configuration identity binding, request-size bounds, single-use
30-second start grants, and suppressed WireGuard payload logging. System Keychain
items use an extension-only trusted-application ACL and explicitly select the
System keychain. No exposed keys or auth tokens were found in these sources.

No project tests or live VPN actions were run by this reviewer. Signed activation, real
XPC/System Keychain access, ACL persistence across extension upgrades, and live
networking remain runtime validation gates.

Apple's [Network Extension Provider Packaging guidance](https://developer.apple.com/forums/thread/800887)
supports the System Keychain and privileged Mach-service design and documents
the shared system-extension process and simultaneous container-app users.
