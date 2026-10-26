# Linux CLI research review

Research baseline: `32dae6c`. Review date: 2026-10-26.
This records design/source review, not runtime acceptance.

## Research assignments

All delegated work uses `gpt-6.1-sol` with `reasoningEffort=high`, shared
read-only checkout, and no builds, tests, installations, or git mutations.
Assignments were spread across the configured main and secure Codex accounts.

* Main: audit every macOS CLI command, parser, serializer, selector, operation,
  cache policy, and portable Swift versus Go reuse option
* Secure: research Linux privileges, WireGuard integration, full/mesh routes,
  DNS, endpoint recovery, VM management, daemon persistence, and acceptance gates
* Main: audit REST device auth/refresh/Firestore/API contracts, mutation unknown
  outcomes, credential storage, installer, versioning, and update design

The original Linux thread was read in full. Its final user corrections retained
direct Firebase REST, required names, daemon ownership, minimal OS flags, shell
installation, Ubuntu first, full IPv4/IPv6/DNS, and ACL-scoped mesh connectivity.
Current macOS mode/selector syntax supersedes the older proposed syntax.

## Initial findings and design responses

* The backend already supports the required reads/mutations. Keep Firebase user
  tokens and rules-constrained REST access, with no Linux-only read endpoints.
* Configs must remain data. Prefer controlled `wg` plus owned network lifecycle
  over privileged execution of remote `wg-quick` input.
* Keep cloud work unprivileged. Use a persistent controller and a narrow network
  service with explicit operator identity and private sockets.
* Ubuntu resolved requires more than `~.` for an all-DNS claim. Detect
  unsupported competing domains and prove dead-tunnel endpoint resolution.
* Full routes can disrupt VM management. Require a bounded management-path
  design and real SSH/cloud-service validation before release.
* Match current Full default and `mode` commands, region-local current indices,
  null/omission rules, and operation ownership. Do not port old proposed flags.
* Create lacks backend idempotency. Keep unknown outcomes and no automatic
  replay, even if a retry library would otherwise resend a request.
* Preserve schema-1 version/build strings using the same Linux release version.
  Keep update as installed-runtime activation, with packaging proof required.
* Start services at boot without connecting by default. Distinguish service
  crash recovery, explicit down, logout, and optional boot resume.
* Source uses a 60-second stale threshold. Older Apple prose says 30. Use source
  for parity and record the discrepancy rather than changing Apple behavior.

## Independent draft review

Fresh delegated reviews use the same model/options and read-only constraints:
main challenges networking/runtime design, while secure checks exact parity,
REST authorization, pagination, caches, mutation replay, and release behavior.

The secure review found a material gap between optional metadata projection and
macOS config-hash authorization. The design now requires full config-bearing
inventory initially. A projection optimization cannot renew offline eligibility
without reading the relevant config bytes in the same snapshot. The reviewer
otherwise found no material parser, JSON-shape, exit-mapping, replay, or version
contradiction. Explicit read-only transactions resolved pagination ambiguity.

The reviewer also suggested appending supersession to the original T3 thread.
The original research produced no Linux Markdown file and remains historical
conversation evidence. The parent keeps that history intact and creates the
linked replacement research here. T3's available send tool starts/steers an
agent turn, rather than attaching a passive historical note. No separate
top-level work or duplicate agent run is needed to update repository research.

Secure round 2 accepted the revised authorization/pagination design and the
repository supersession approach, with no research-handoff blockers.

Main's network/runtime review identified five missing design decisions. The
parent resolved them in the research and checkpoints:

1. Netd is the sole durable network-intent writer. Monotonic revisions serialize
   effects, newer stop/logout suppression wins, and restart requires a fresh
   live-controller generation grant. Logout preserves an already committed
   tunnel while suppressing new starts, and bare down needs no Firebase account.
2. Runtime DNS-policy loss gets one bounded repair. An unsupported conflict
   fails and tears down the managed connection, with explicit disconnected/
   unknown status and doctor failure. Detection windows and restored underlay
   access are disclosed, without claiming fail-closed DNS.
3. Update replaces netd/network assets only, retaining its controller owner.
   The root-owned selector/launcher and staged signed target define activation.
   CLI/controller replacement is separate disconnected-only maintenance.
4. Full requires a root-owned management policy: console administration or
   approved fixed destination prefixes with explicit underlay route rules.
   No SSH environment/ancestry inference is trusted.
5. A normative observation table defines connected, connecting, disconnecting,
   disconnected, partial/unknown, stale, and unavailable. Current stop requires
   proving all owned network resources absent/reverted. Endpoint health stays
   separate from configured readiness.

Main round 2 accepted all five revisions, with no remaining material
contradictions or required design fixes. Both accounts accept the research
handoff. This is design acceptance, with runtime proof still required.

Seven delegated tasks completed: three research audits, two independent draft
reviews, and two fresh verification rounds. All used `gpt-6.1-sol` high across
main and secure. No delegated task changed the checkout.

## Runtime evidence still required

No Linux commands, tests, builds, network changes, or VM experiments have been
executed. Implementation gates in the [research](linux-cli-research.md) and
[checkpoints](../TODO/linux-cli.md) remain open. Review does not establish
deployed regional IPv6 egress, exclusive DNS, SSH safety, or distro support.

Documentation validation passed: local link targets, Markdown fences/newlines,
trailing-whitespace inspection, and `git diff --check`. At research handoff,
the checkout was `linux-cli` at the local main baseline, with documentation
changes uncommitted and no staged changes. No push or release was performed.
