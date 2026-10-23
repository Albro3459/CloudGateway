# macOS inventory polling and idle lifecycle

Status: implemented, reviewed, unsigned validation passed

## Agreed behavior

The background controller owns inventory and VPN command state. The menu app and
CLI display that shared state. Refreshing from either interface updates the same
inventory. Already printed CLI output stays unchanged.

- Fetch inventory when starting or restoring an authorized session, and after
  creating a client.
- During the first 2 minutes after actual user activity, automatically refresh
  inventory every 60 seconds.
- From 2 to 15 minutes after activity, refresh every 5 minutes.
- After 15 minutes, stop automatic inventory refresh and allow the controller to
  exit once commands, refreshes, login, extension work, active requests, and
  operation recovery windows no longer require it. The VPN extension can keep
  the tunnel connected independently.
- Menu opening displays the current inventory immediately. If it is stale, the
  controller starts one background refresh. Opening a fresh menu does no cloud
  fetch. Keep open menu items stable while snapshots change.
- CLI commands count as actual user activity once per invocation. `list` waits
  within its caller deadline for stale inventory to refresh. Explicit `refresh`
  and `list --refresh` fetch immediately and report their correlated result.
- Menu opening and user actions count as activity. Passive lifecycle, snapshot,
  operation-result, and login-status polls, and an active VPN, do not reset idle
  time. Doctor keeps its passive runtime behavior.
- Menu snapshot polling pauses after 15 minutes without user interaction,
  including while a dialog or other UI progress remains. Passive polling cannot
  restart an idle controller. A real menu interaction resumes it.
- Concurrent timer, menu, CLI, and explicit refresh requests share one fetch.
  Preserve account fencing and leave local VPN state observation independent.
- Failed automatic refreshes use bounded exponential backoff with jitter,
  separate from activity tiers. Explicit refresh remains available.
- Sleep must not wake the Mac for inventory or queue missed refresh intervals.
  Wake may cause one due refresh, with the next deadline based on completion.

## Implementation boundaries

1. Controller/domain scheduling, shared fetch freshness and lifecycle admission
2. Menu client polling suspension and explicit interaction signaling
3. CLI activity signaling, stale-list waiting, protocol validation and docs

Use monotonic time for elapsed activity, freshness and retry scheduling where
possible. Keep scheduling deterministic under an injected clock for regression
coverage. Retain current request/account/build fences and extension safety gates.

## Acceptance

- [x] Implement activity tiers, idle exit, stale return and failure backoff
- [x] Pause idle frontend polling without losing foreground recovery
- [x] Make CLI list await stale shared inventory within its existing deadline
- [x] Cover coalescing, passive activity, boundaries, failures and late completion
- [x] Complete fresh Sol High review rounds, using Secure unless usage is exhausted
- [x] Pass `./scripts/test.sh macos` with unsigned builds
- [x] Commit reviewed changes locally, without pushing

The separately documented Add Client/local Disconnect finding remains outside
this polling change unless an implementation dependency requires addressing it.

## Review and validation

Secure Sol High round 1 found three P2 issues:

- A pre-mutation stale refresh could make Add Client preparation or submission
  fail busy. Commands must record activity without starting a competing fetch.
- The first menu after idle could keep cached rows disabled after fresh state
  arrived. Update existing items in place while retaining menu structure.
- Failure retry deadlines were still gated by the activity cadence. Use the
  retry deadline while recovering, with the 15-minute inactivity cutoff intact.

The first unsigned run passed build, scans and packaging but found five test
assertions: older idle-clock fixtures and a floating-point jitter boundary.
Those fixtures were corrected, then `./scripts/test.sh macos` passed with 445
macOS tests, shared package/auth-adapter tests, both strict Periphery scans,
unsigned arm64 app/extension build, packaging, and 20 CLI smoke checks. A fresh
review and validation run follow the production fixes above.

All three round 1 findings are fixed. Server-counted commands no longer start a
pre-admission inventory fetch, and manual extension setup records activity
without one. Existing open-menu items update in place from validated snapshots.
Retry deadlines take precedence while recovering from failures, and success
restores the activity cadence. Coverage includes an early failed refresh whose
retry is due before the previous success reaches 60 seconds.

The unsigned run after the first review fixes passes 455 macOS tests, 263 shared Kit/AppCore tests,
31 Firebase auth-adapter tests, both strict Periphery scans, the arm64
app/extension build, bundle verification, and all 20 packaged CLI smoke checks.
No signed validation was run for this change. Secure Sol High round 2 confirmed
the three fixes and found one further P2: the proposed 2-minute UI progress grace
could relaunch an idle controller through Mach-service activation, even without
an explicit bootstrap call. Remove that grace and stop all passive requests at
15 minutes, while confirmed backend work continues independently. Regression
coverage must assert no transport calls after the cutoff.

The post-cutoff-fix run exposed the previously documented 20 ms capacity-test
flakiness: the aggregate deadline could pass before region loading handed off
to the intentionally stalled token request. The fixture now uses the same
one-second budget as the neighboring capacity test and asserts token retrieval
started, while retaining timeout cancellation and unknown-capacity checks.
Production capacity deadlines are unchanged.

Secure Sol High round 3 found no actionable issues in the full diff, including
new files, and verified the prior fixes and capacity fixture adjustment.
`./scripts/test.sh macos` now passes with 457 macOS tests, 263 shared Kit/AppCore
tests, 31 Firebase auth-adapter tests, both strict Periphery scans, unsigned
arm64 app/extension build, bundle verification, and 20 CLI smoke checks.
Live signed launchd/XPC and interactive AppKit behavior were not exercised.
Main and Secure used GPT-6.1 Sol High throughout implementation and review.
