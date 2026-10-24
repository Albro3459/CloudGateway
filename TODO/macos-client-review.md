# Review client removal and CLI add

Date: 2026-10-24
Reviewed snapshot: `b5cc728b93fa276c06562c57c664457146cda66b` on `mac-remove-client`
Removal base: `373f854f` (`mac-cli`)
CLI add introduction: `373f854f` in [PR #16](https://github.com/Albro3459/CloudGateway/pull/16)

Review complete. No confirmed new actionable findings at the reviewed removal
head or in the current CLI add implementation. Both earlier add findings are
fixed in this branch. One new removal-menu candidate was rejected during
independent verification, as recorded below.

- [CLI add, Main Codex](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-client-review-add.md)
- [Removal core, Secure Codex](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-client-review-removal-core.md)
- [Removal CLI and menu, Main Codex](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-client-review-removal-frontends.md)

The GitHub PR list has no PR for `mac-remove-client` at review start. Review
covers its local and remote-tracking head against `mac-cli`, plus the preceding
CLI add implementation and its integrated fixes. The existing TODO directory
holds the project review notes. There is no separate TODO repository in the
available GitHub checkout directory.

The initial worktree and index were clean. This review changes documentation
only. No production changes, branch creation, external reviews, cloud requests,
or VPN operations are part of the review. Earlier validation results in the
implementation notes are historical.

## Rejected removal-menu candidate

The initial Main review proposed a P2 because the frontend's incomplete-cleanup
warning hides the controller's disconnect/System Settings guidance. The parent
confirmed message precedence and the existing defensive fixture, but initially
missed the fixture's production-reachability limitation.

A fresh Secure review rejected the claimed trigger: the fixture directly injects
a connected profile, while the [production provider](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayTunnel/PacketTunnelProvider.swift:16)
requires a controller-supplied start grant. [Grant resolution](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacIPC/CloudGatewayMacSecretService.swift:90)
consumes that grant, and normal controller starts are serialized against removal.
System Settings cannot establish the stated ongoing tunnel without it.

The parent checked those production guards and accepts the rejection. A global
stop remains available for an observed active profile. Refresh does not retry
profile removal, and retained orphan profiles are an intentional documented
limit. The shorter warning may be improved, but the proposed P2 impact is not
verified. It is not counted as a current finding. The frontend report preserves
the initial candidate and the independent verification evidence.

## Earlier add findings

The original PR #16 snapshot still uses the ordinary API-error denial catch
and a shared creation/stop command slot. Both previously documented P2 findings
are fixed in `07825f1c`, which is included in the reviewed removal head. They
are upstream-only findings, not new defects in this branch. The parent checked
the original controller and the fix diff independently of the add reviewer.

The preparation-denial classification issue was already fixed in the final
add commit `373f854f`. It is not an open finding at either reviewed snapshot.

## Review and validation record

- Main Codex (`codex_main`), `gpt-6.1-sol`, high reasoning: CLI add and a separate
  removal frontend review, each documenting results in its assigned report
- Secure Codex (`codex_secure`), same model and reasoning: removal core and a
  fresh independent verification of the proposed menu finding and historical
  add findings
- Parent: independently traced HTTP classification, creation/stop admission,
  removal HTTP/backend contracts, cache eviction, profile cleanup, frontend
  message precedence, and the provider start-grant requirement

All accepted findings and historical dispositions were checked against the
relevant source snapshots and existing fixtures. Reviewers wrote notes as
candidates were verified and retained the rejected candidate's final disposition.
No tests or builds were run for this documentation-only review. Existing tests
were inspected, not executed. Signed IPC, live Firebase, Keychain,
NetworkExtension, and AppKit runtime behavior were not exercised.

Manual documentation validation checked local link targets, referenced line
bounds, whitespace, final dispositions, and reviewer account assignments.
The user requested a local commit of the completed review notes. No production
or test code changed, no external review was posted, and nothing was pushed.
