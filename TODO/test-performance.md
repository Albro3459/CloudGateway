# Local test performance

## Scope

Speed up the existing local test runner without dropping tests, scans, compiler
checks, cross-builds, or signed packaging checks. Independent checks and targets
run concurrently. GitHub Actions and deployment workflows are outside this work.

## Initial serial benchmark method

- Date: 2026-10-28
- Branch: `test-performance`, based on `main` at `35a1fa6`
- Machine: this ARM Mac, macOS 26.5, 8 logical CPUs
- Xcode 26.5 (`17F42`), Apple Swift 6.3.2, Periphery 3.7.4
- Node 24.18.0, Python 3.14.5, default Go 1.26.4
- Linux tests retain the module's pinned Go 1.27.3 toolchain
- Run the full unsigned suite, then the full signed suite, sequentially
- Preserve existing dependency and build caches. These are local incremental
  runs, not clean-build benchmarks
- Measure elapsed time with Python's monotonic clock around the normal
  `./scripts/test.sh` entry point. Record each named check's start and completion
- Keep raw logs and timing JSON under the ignored `.deps/test-performance/`
  directory. Do not commit build logs or signing details
- The user-invoked keychain command reported that the keychain was already
  unlocked before either baseline run

The first unsigned run rebuilt the macOS host-free package in 12.92 seconds.
The following signed run reused that compilation. Treat that cache warm-up
separately from improvements due to this change. Firebase integration tests also
vary between runs because they exercise real emulator transactions.

## Initial serial results

| Full suite | Baseline seconds | Optimized seconds | Result |
| --- | ---: | ---: | --- |
| Unsigned | 250.281 | 197.040 | Both passed |
| Signed | 257.669 | 246.156 | Both passed |

Target breakdown, in seconds:

| Target | Unsigned before | Unsigned after | Signed before | Signed after |
| --- | ---: | ---: | ---: | ---: |
| API | 6.219 | 4.323 | 6.034 | 4.463 |
| Web | 12.877 | 8.645 | 12.618 | 10.541 |
| Infra | 4.610 | 6.690 | 4.639 | 6.893 |
| Firebase | 43.123 | 38.888 | 30.759 | 38.883 |
| Linux | 46.725 | 36.363 | 47.479 | 36.268 |
| iOS | 74.294 | 57.956 | 80.778 | 75.306 |
| macOS | 62.426 | 44.169 | 75.355 | 73.794 |

These are observed single-run times, not a controlled estimate of the change's
causal speedup. Apple compilation caches warmed during validation, and Firebase
transaction retry timing varies. Their changes should not all be credited to
the optimizations. The new runner regression tests also make infra slower.

The most repeatable improvement was the Linux Go test step: 45.384 and 45.982
seconds in the baselines, then 34.282 in targeted validation. Final unsigned and
signed runs took 34.877 and 34.867 seconds. Its limiting package changed from
release/installer tests to daemon tests. All assertions, race checking, and
forced test execution remain.

## Changes

- Print elapsed whole seconds beside each named check
- Cache successful API dependency setup using project metadata, virtual
  environment configuration, interpreter identity, and installed package
  metadata. Invalidate the success stamp before attempting another install
- Combine the four infra Pyright calls into one invocation with the same six
  explicit Python inputs. Keep every compile and unit-test call
- Use two Jest workers and a dedicated incremental TypeScript cache. Keep the
  standalone typecheck, Knip, and the full production build
- Run the 25 installer tests in parallel. Each test retains its own temporary
  root, assets, command stubs, environment, and assertions. Keep Go's race
  detector, forced test execution, all vet passes, and both architecture builds
- Reuse native SwiftPM test executables after their package's successful
  Periphery scan in the same invocation. Failed scans and missing Periphery
  fall back to normal test builds. Shared package test results remain memoized
- Keep all five Periphery scans building and analyzing their original scopes.
  iOS and macOS production scans retain distinct project/scheme cache identities.
  Package test builds are never substituted for production scan indexes
- Keep signed Release builds, unsigned Debug builds, project-list checks, and
  packaging/signature verification

Swift 6.3.2 on this machine already defaults to the native build system. Most of
the package reuse benefit is avoiding another build-planning pass, rather than
avoiding a full compilation. The Firebase adapter still loads its package graph
when executing tests with `--skip-build`.

## Validation

- The targeted API, web, Linux, and Apple run passed after implementation
- All 27 runner regression tests passed through the infra target, including
  scan-failure fallback, missing Periphery, shared failure caching, dependency
  fingerprint invalidation/retry, and grouped Pyright failure propagation
- Runner regression tests took 3.9–4.5 seconds, compared with roughly 0.1 seconds
  before. Full-suite results include that cost
- The grouped infra Pyright invocation, Terraform checks, script parsing,
  compilation, and existing infra tests passed
- A temporary type error inside a web test file passed Jest and the production
  build but failed the standalone cached typecheck with TS2322. The web target
  exited 1. After moving the canary out of the source tree, the full web target
  passed again
- The targeted Apple run retained 280 XCTest and 266 Swift Testing Kit/AppCore
  tests, 31 adapter tests, 837 macOS core tests, all five strict scans, and unsigned
  packaging checks

The Secure Codex account reviewed the changes after targeted validation and
reported no actionable findings. Main Codex handled implementation and runner
regression coverage. The review explicitly checked shared-code naming and
separate iOS/macOS Periphery cache identities.

Both final full-suite runs passed, including all five strict Apple scans,
616 API tests, 13 emulator integration tests, 303 web tests, the unchanged Swift
test counts above, and signed Release builds with packaging/signature checks.
The only changed named checks are dependency setup on a cache hit and the four
infra Pyright invocations consolidated into one with the same six inputs.

Observed full-suite reductions were 53.241 seconds unsigned and 11.513 seconds
signed. The signed result better reflects the remaining cost of Release builds
and provisioning on this machine. The Apple production build commands are
unchanged.

## Parallel execution

The default runner overlaps API, Web, infra, Linux, and Apple targets. Firebase
follows the short API/Web/infra group while Linux and Apple continue, reducing
CPU contention during emulator transactions. Within each target, independent
tests, typechecks, dead-code scans, and builds also overlap. The concurrency graph is fixed by the selected targets. Jest
keeps two workers. Linux vet passes stay in one worker, and its two cross-builds
stay in another, alongside the forced race-enabled tests.

The shared API environment is prepared before Python consumers start. Concurrent
Pyright processes keep their existing explicit source lists and root config.
Web CSS is generated before readers start, then the production build skips its
already-completed prebuild lifecycle hook. Firebase retains one emulator lifetime
and its existing sequential rules/API integration suites inside that lifetime.
An all-at-once run hit emulator transaction lock timeouts in the five-writer
rate-limit test. The scheduling barrier preserves its concurrent requests and
exact response-count assertions.

Apple work is split into independent workers:

- WireGuard startup regressions, once per invocation
- Kit scan followed by Kit/AppCore tests
- Firebase adapter scan followed by adapter tests
- macOS host-free scan followed by core/IPC tests, when macOS is selected
- iOS production scan, project list, and app build
- macOS production scan, project list, app build, and packaging verification

Each package owns its scan result and reuses executables only after that scan
succeeds. Failed scans still run normal test builds and remain failures. A
macOS-only selection retains its earlier behavior: shared package tests run,
but the two iOS package scans do not. Both platform production scans retain
separate Periphery cache keys and indexes. Xcode builds keep their existing
separate DerivedData locations, which also isolate WireGuard make outputs.
Signed platform pipelines stay sequential. Signed builds were not benchmarked
again for this concurrency work.

Workers keep separate working directories, failure lists, and logs. The parent
waits for every worker and collects all failures, including a worker that exits
without writing a failure list. Live named-check status goes to the terminal.
Full output stays under the ignored `.deps/test-runs/` directory, and failed
worker output is printed. `--serial` runs the same checks sequentially and
restores the starting directory between callbacks.

Full concurrency exposed an existing deferred-auth test assertion race. The test
now waits for the expected reload's region fetch before its unchanged exact-count
assertion. A macOS login/stop test now waits for stop admission as well as fresh
profile observation, so startup cancellation cleanup finishes before it submits
the command. A React superseded-read test now waits for its pending write to
release the Sync button before opening the confirmation dialog. Its existing
state assertions remain. A macOS capacity test also hit its one-second deadline
before its read workers ran, when hundreds of MainActor tests competed. The runner limits
macOS core tests to eight concurrent cases, preserving assertions and deadlines.
This uses Swift 6.3's
[maximum-parallelization-width option](https://github.com/swiftlang/swift-package-manager/blob/swift-6.3-RELEASE/Sources/Commands/SwiftTestCommand.swift).

Runner coverage includes real worker overlap, cwd isolation, failure collection,
abrupt worker exit, aliases/deduplication, shared setup ordering, scan-before-test
ordering, shared Apple work running once, scan failure fallback, per-platform
selection, and signed/unsigned build and packaging arguments.

## Parallel benchmark results

Measured on the same M3 Mac with 24 GB RAM on 2026-10-28. Dependency and build
caches stayed in place. Each run used the normal test entry point, measured with
Python's monotonic clock. The final five full unsigned runs ran consecutively
with the same code and no overlapping benchmark suites. No failure retries were
added. Cold builds and signed Release builds are separate measurements.

| Full unsigned suite | Seconds | Result |
| --- | ---: | --- |
| Serial reference (`--serial`) | 187.610 | Passed |
| Target concurrency, sequential Apple | 120.111 | Passed |
| Full parallel run 1 | 70.141 | Passed |
| Full parallel run 2 | 54.055 | Passed |
| Full parallel run 3 | 71.102 | Passed |
| Full parallel run 4 | 53.083 | Passed |
| Full parallel run 5 | 69.898 | Passed |
| Parallel median | 69.898 | 5/5 passed |

The median is 2.68 times faster than the serial reference, and
3.58 times faster than the original 250.281-second unsigned baseline. The
slowest final run was 71.102 seconds, below both the 120-second goal and the
90-second stretch goal. These are warm local observations, not a cold-build or
CI timing guarantee. The serial reference predates the last two test-readiness
fixes and the Firebase scheduling barrier's additional regression test.

Every final run completed all 76 named checks successfully: all 75 earlier
checks, plus separately reported CSS generation that previously ran inside the
Web prebuild hook. Counts were checked in every run: 616 API tests, 13 emulator
integration tests, 303 Web tests, 280 Kit/AppCore XCTest cases and 266 Swift
Testing cases, 31 adapter tests, 837 macOS core tests, and 40 runner regression
tests. All five strict Periphery scans, compiler/type checks, production Web
build, unsigned Apple builds, packaging verification, Linux race tests, vet
passes, and both Linux cross-builds remain.

Resource sampling used Mach CPU counters, IOKit GPU counters, and system swap
usage at roughly two-second intervals. CPU peaked at 100% of all eight logical
CPUs, with per-run averages from 55.9% to 71.6%. GPU utilization
peaked at 1%, and every sampled swap-used value was zero. Individual checks can
take longer under CPU contention even while the full suite finishes sooner.
Firebase transaction retry timing accounts for much of the final variation.

Raw timing logs, JSON results, and resource samples are under
`.deps/test-performance/parallel-complete-1` through `parallel-complete-5`
(`.log`, `.json`, and `-resources.jsonl`). The summary is
`.deps/test-performance/parallel-summary.json`. Full worker logs remain in the
per-invocation directories recorded there. The initial mixed baseline and
failed development candidates are excluded from the comparison.

Main Codex reviewed the scheduler and shared build state. Its serial-cwd finding
was fixed and covered by a regression test. Secure Codex updated Apple runner
coverage. All delegates used 6.1 Sol High. Final manual diff and whitespace
review passed.
