# Local test performance

## Scope

Speed up the existing local test runner without dropping tests, scans, compiler
checks, cross-builds, or signed packaging checks. Target execution remains serial.
GitHub Actions and deployment workflows are outside this work.

## Benchmark method

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

## Results

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
