#!/bin/bash

# Runs every local test/validation suite for the repo.
#
# Usage:
#   ./scripts/test.sh            # run everything (Apple builds unsigned)
#   ./scripts/test.sh --signed   # run everything with signed Apple builds
#   ./scripts/test.sh --serial   # run the same checks sequentially
#   ./scripts/test.sh api        # API only
#   ./scripts/test.sh ios        # iOS tests + unsigned no-device iOS build
#   ./scripts/test.sh ios --signed  # iOS tests + signed no-device iOS build
#   ./scripts/test.sh macos      # macOS tests + unsigned arm64 app/extension build
#   ./scripts/test.sh macos --signed  # signed macOS build + entitlement/profile checks
#   ./scripts/test.sh apple      # both iOS and macOS, with shared tests run once
#   ./scripts/test.sh apple --signed  # both iOS and macOS with signed builds
#   ./scripts/test.sh linux      # Linux CLI and daemon: Go tests, cross-builds, installer checks
#   ./scripts/test.sh web infra  # any combination of: api web infra ios macos apple firebase linux
#
# One-time setup (API venv, Web node_modules, terraform providers) happens
# automatically on first run.
#
# Every step runs even if an earlier one fails; the script exits 1 if any
# step (setup, test, typecheck, build, or validation) failed.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=()
API_PYTHON_TOOLS_READY=0
APPLE_SIGNED=0
TEST_PARALLEL=1

# Run a named command, recording it in FAILURES on failure. Never aborts, so
# later steps still run. Returns the command's exit code.
run_check() {
  local name="$1"
  shift
  local started=$SECONDS
  echo "--- $name ---"
  if [[ "${PARALLEL_PROGRESS:-0}" -eq 1 ]]; then echo "--- $name ---" >&3; fi
  if "$@"; then
    echo "OK: $name ($((SECONDS - started))s)"
    if [[ "${PARALLEL_PROGRESS:-0}" -eq 1 ]]; then echo "OK: $name ($((SECONDS - started))s)" >&3; fi
    return 0
  fi
  echo "FAILED: $name ($((SECONDS - started))s)" >&2
  if [[ "${PARALLEL_PROGRESS:-0}" -eq 1 ]]; then echo "FAILED: $name ($((SECONDS - started))s)" >&3; fi
  FAILURES+=("$name")
  return 1
}

api_python_tools_fingerprint() {
  ./.venv/bin/python - <<'PY'
from hashlib import sha256
from importlib.metadata import distributions
from pathlib import Path
import sys

if Path(sys.prefix).resolve() != Path('.venv').resolve():
    raise SystemExit('Backend/API/.venv is not a working virtual environment')
interpreter = Path(sys.executable).resolve()
state = [
    Path('pyproject.toml').read_bytes(),
    Path('.venv/pyvenv.cfg').read_bytes(),
    str(Path.cwd().resolve()).encode(),
    sys.version.encode(),
    str(interpreter).encode(),
    str(interpreter.stat().st_mtime_ns).encode(),
]
packages = sorted(
    (dist.metadata['Name'], dist.version, dist.read_text('direct_url.json') or '')
    for dist in distributions()
)
state.append(repr(packages).encode())
print(sha256(b'\0'.join(state)).hexdigest())
PY
}

ensure_api_python_tools() {
  cd "$ROOT/Backend/API" || return 1

  if [[ "$API_PYTHON_TOOLS_READY" -eq -1 ]]; then
    return 1
  fi
  if [[ "$API_PYTHON_TOOLS_READY" -eq 1 ]]; then
    return 0
  fi

  if [[ ! -x .venv/bin/python ]]; then
    echo "Creating Backend/API/.venv"
    run_check "API venv create" python3 -m venv .venv || return 1
    run_check "API pip upgrade" ./.venv/bin/python -m pip install --quiet --upgrade pip || return 1
  fi
  local stamp=.venv/.test-tools-fingerprint
  local fingerprint
  if ! fingerprint="$(api_python_tools_fingerprint)"; then
    FAILURES+=("API dependency state")
    return 1
  fi
  if [[ -f "$stamp" && -x .venv/bin/pyright && -x .venv/bin/vulture &&
        "$(cat "$stamp")" == "$fingerprint" ]]; then
    API_PYTHON_TOOLS_READY=1
    return 0
  fi
  # Invalidate before pip so a failed sync cannot reuse an earlier success
  if ! echo > "$stamp"; then
    FAILURES+=("API dependency cache")
    return 1
  fi
  echo "Syncing API dependencies"
  run_check "API dependency sync" ./.venv/bin/python -m pip install --quiet -e '.[dev]' || return 1
  if ! fingerprint="$(api_python_tools_fingerprint)" || ! echo "$fingerprint" > "$stamp"; then
    FAILURES+=("API dependency cache")
    return 1
  fi
  API_PYTHON_TOOLS_READY=1
}

run_pyright() {
  local name="$1"
  shift
  cd "$ROOT" || return 1
  ensure_api_python_tools || return 1
  cd "$ROOT" || return 1
  run_check "$name" Backend/API/.venv/bin/pyright --project pyrightconfig.json "$@"
}

test_api() {
  ensure_api_python_tools || return 1
  cd "$ROOT/Backend/API" || return 1

  api_compile() { run_check "API compile" ./.venv/bin/python -m compileall -q src tests; }
  api_types() { run_pyright "API pyright" Backend/API/src Backend/API/tests; }
  api_dead_code() { run_check "API dead code (vulture)" ./.venv/bin/vulture; }
  api_tests() { run_check "API pytest" ./.venv/bin/python -m pytest; }
  run_parallel api_compile api_types api_dead_code api_tests
}

test_web() {
  cd "$ROOT/Frontend/Web" || return 1

  run_check "React deployment script syntax" bash -n "$ROOT/scripts/deploy-react.sh"
  if [[ ! -d node_modules ]]; then
    echo "Installing Web dependencies"
    run_check "Web dependency install" npm install || return 1
  fi

  # Generate CSS before readers start; the build below skips this lifecycle hook
  run_check "Web styles" npm run prebuild
  web_tests() { run_check "Web Jest" env CI=true npm run test -- --watchAll=false --maxWorkers=2; }
  web_types() {
    run_check "Web TypeScript" npx tsc --noEmit --incremental --tsBuildInfoFile node_modules/.cache/test-runner.tsbuildinfo
  }
  web_dead_code() { run_check "Web dead code (knip)" npx --no-install knip; }
  web_build() { run_check "Web production build" npm run build --ignore-scripts; }
  run_parallel web_tests web_types web_dead_code web_build
}

test_firebase() {
  ensure_api_python_tools || return 1
  cd "$ROOT/Backend/Firebase" || return 1

  if [[ ! -d node_modules ]]; then
    echo "Installing Firebase rules-test dependencies"
    run_check "Firebase dependency install" npm install || return 1
  fi

  firebase_types() {
    run_check "Firebase schema and tests typecheck" npm run typecheck
    run_pyright "Device auth tools pyright" scripts/device-auth-client.py scripts/test_device_auth_client.py scripts/test_firebase_emulators.py
  }
  firebase_client_tests() {
    cd "$ROOT" || return 1
    run_check "Device auth test client" Backend/API/.venv/bin/python -m unittest scripts/test_device_auth_client.py
  }

  run_firebase_emulator_tests() {
    env FIREBASE_CLI_DISABLE_UPDATE_CHECK=true npm exec -- firebase emulators:exec --only auth,firestore --project demo-cloudgateway "../API/.venv/bin/python ../../scripts/test_firebase_emulators.py" 2> >(
      grep -Ev "^(lsof: WARNING: can't stat\\(\\)|      Output information may be incomplete\\.|      assuming \"dev=)" >&2
    )
  }

  # Both suites share one offline demo-project emulator lifetime
  firebase_emulators() { run_check "Firebase rules and API exchange tests" run_firebase_emulator_tests; }
  run_parallel firebase_types firebase_client_tests firebase_emulators
}

check_apple_signing_prerequisites() {
  local login_keychain="$HOME/Library/Keychains/login.keychain-db"

  if ! security show-keychain-info "$login_keychain" >/dev/null 2>&1; then
    echo "The login keychain is locked or unavailable." >&2
    echo "Unlock it with:" >&2
    echo "  security unlock-keychain \"$login_keychain\"" >&2
    return 1
  fi

  if ! security find-identity -v -p codesigning "$login_keychain" |
      grep -Eq '"Apple Development: .+"'; then
    echo "No accessible Apple Development signing identity was found." >&2
    return 1
  fi

  return 0
}

scan_apple_dead_code() {
  if ! command -v periphery >/dev/null 2>&1; then
    echo "periphery not found; skipping Apple dead-code scans. Install: brew install periphery" >&2
    return 0
  fi
  local failed=0
  run_check "Apple dead code: app project" \
    periphery scan --quiet --strict \
      --config "$ROOT/Frontend/Apple/.periphery.yml" \
      --project "$ROOT/Frontend/Apple/iOS/CloudGateway.xcodeproj" \
      --schemes CloudGateway --schemes CloudGatewayScreenshots \
      --report-exclude "**/wireguard-apple/**" ||
    failed=1
  return "$failed"
}

run_apple_package_tests() {
  local name="$1" package="$2" built="$3"
  local args=(--package-path "$package" --build-system native)
  # Keep hundreds of MainActor tests from starving their own deadline workers
  if [[ "$package" == Frontend/Apple/macOS/CloudGatewayMacCore ]]; then
    args+=(--experimental-maximum-parallelization-width 8)
  fi
  if [[ "$built" -eq 1 ]]; then
    args+=(--skip-build)
  fi
  run_check "$name" swift test "${args[@]}"
}

test_apple_package() {
  local name="$1" package="$2" scan="$3" config="$4"
  local built=0 failed=0
  if [[ -n "$scan" ]]; then
    if command -v periphery >/dev/null 2>&1; then
      if run_check "$scan" \
        periphery scan --quiet --strict --config "$ROOT/$config" \
          --project-root "$ROOT/$package" --report-include "**/Tests/**" -- --build-system native
      then
        built=1
      else
        failed=1
      fi
    else
      echo "periphery not found; skipping $scan. Install: brew install periphery" >&2
    fi
  fi
  # A failed scan still runs tests, with a normal build instead of --skip-build
  run_apple_package_tests "$name" "$package" "$built" || failed=1
  return "$failed"
}

apple_wireguard_tests() {
  cd "$ROOT" || return 1
  run_check "Apple WireGuard startup regressions" make -C Frontend/Apple/wireguard-apple test
}

apple_kit_tests() {
  cd "$ROOT" || return 1
  local scan=""
  if [[ " ${APPLE_TARGETS[*]} " == *" ios "* ]]; then
    scan="Apple dead code: Kit tests"
  fi
  test_apple_package "Apple Kit and AppCore package tests" Frontend/Apple/CloudGatewayKit \
    "$scan" Frontend/Apple/.periphery.yml
}

apple_firebase_tests() {
  cd "$ROOT" || return 1
  local scan=""
  if [[ " ${APPLE_TARGETS[*]} " == *" ios "* ]]; then
    scan="Apple dead code: Firebase adapter tests"
  fi
  test_apple_package "Apple Firebase auth adapter tests" Frontend/Apple/CloudGatewayFirebaseAdapter \
    "$scan" Frontend/Apple/.periphery.yml
}

apple_macos_core_tests() {
  cd "$ROOT" || return 1
  test_apple_package "macOS host-free core and IPC tests" Frontend/Apple/macOS/CloudGatewayMacCore \
    "macOS dead code: host-free tests" Frontend/Apple/macOS/.periphery.yml
}

test_ios() {
  cd "$ROOT" || return 1

  local failed=0

  scan_apple_dead_code ||
    failed=1

  run_check "Apple release script syntax" \
    bash -n scripts/ios-release.sh ||
    failed=1
  run_check "Apple iOS project list" \
    xcodebuild -list -project Frontend/Apple/iOS/CloudGateway.xcodeproj ||
    failed=1

  if [[ "$APPLE_SIGNED" -eq 1 ]]; then
    if run_check \
      "Apple signing prerequisites" \
      check_apple_signing_prerequisites
    then
      run_check "Apple signed Release no-device iOS build" \
        xcodebuild \
          -project Frontend/Apple/iOS/CloudGateway.xcodeproj \
          -scheme CloudGateway \
          -configuration Release \
          -destination generic/platform=iOS \
          -allowProvisioningUpdates \
          build ||
        failed=1
    else
      failed=1
    fi
  else
    run_check "Apple unsigned no-device iOS build" \
      xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj \
        -scheme CloudGateway \
        -configuration Debug \
        -destination generic/platform=iOS \
        CODE_SIGNING_ALLOWED=NO \
        build ||
      failed=1
  fi

  return "$failed"
}

check_macos_signing_prerequisites() {
  local login_keychain="$HOME/Library/Keychains/login.keychain-db"
  # Keychain settings queries require GUI interaction in some remote sessions
  # Identity discovery is read-only; the build verifies private-key access
  if ! security find-identity -v -p codesigning "$login_keychain" |
      grep -Eq '"Apple Development: .+"'; then
    echo "No accessible Apple Development signing identity was found for macOS." >&2
    return 1
  fi
  return 0
}

scan_macos_dead_code() {
  if ! command -v periphery >/dev/null 2>&1; then
    echo "periphery not found; skipping macOS dead-code scans. Install: brew install periphery" >&2
    return 0
  fi
  local failed=0
  # Periphery keys its cache by project and scheme names, without the full path
  # Keep this scheme set distinct from iOS to avoid mixing both tunnel indexes
  run_check "macOS dead code: app and extension" \
    periphery scan --quiet --strict \
      --config "$ROOT/Frontend/Apple/macOS/.periphery.yml" \
      --project "$ROOT/Frontend/Apple/macOS/CloudGateway.xcodeproj" \
      --schemes CloudGateway --schemes CloudGatewayTunnel \
      --report-include "**/macOS/**" \
      --report-include "**/CloudGatewayDeviceAuthClient.swift" \
      --report-include "**/CloudGatewayCustomTokenAuthServicing.swift" \
      --report-include "**/CloudGatewayFirebaseCustomTokenSession.swift" ||
    failed=1
  return "$failed"
}

test_macos() {
  cd "$ROOT" || return 1
  local failed=0
  local derived_data="$ROOT/Frontend/Apple/macOS/.build/Xcode"
  local configuration=Debug
  local destination=generic/platform=macOS
  local signing=(CODE_SIGNING_ALLOWED=NO)

  run_check "macOS packaging verifier tests" \
    python3 -m unittest scripts/test_verify_macos_build.py ||
    failed=1
  run_check "macOS release script syntax" bash -n scripts/macos-release.sh || failed=1
  run_check "macOS release workflow tests" \
    python3 -m unittest scripts/test_macos_release.py || failed=1
  scan_macos_dead_code || failed=1
  run_check "macOS project list" \
    xcodebuild -list -project Frontend/Apple/macOS/CloudGateway.xcodeproj ||
    failed=1

  if [[ "$APPLE_SIGNED" -eq 1 ]]; then
    run_check "macOS signing prerequisites" check_macos_signing_prerequisites || return 1
    configuration=Release
    destination=platform=macOS,arch=arm64
    signing=(-allowProvisioningUpdates)
  fi
  if run_check "macOS $configuration arm64 app and system extension build" \
    xcodebuild -project Frontend/Apple/macOS/CloudGateway.xcodeproj \
      -scheme CloudGateway -configuration "$configuration" \
      -destination "$destination" -derivedDataPath "$derived_data" \
      ARCHS=arm64 "${signing[@]}" build
  then
    if [[ "$APPLE_SIGNED" -eq 1 ]]; then
      run_check "macOS bundle packaging and signing verification" \
        python3 scripts/verify_macos_build.py \
          "$derived_data/Build/Products/$configuration/CloudGateway.app" --signed --cli-smoke ||
        failed=1
    else
      run_check "macOS bundle packaging verification" \
        python3 scripts/verify_macos_build.py \
          "$derived_data/Build/Products/$configuration/CloudGateway.app" --cli-smoke ||
        failed=1
    fi
  else
    failed=1
  fi
  return "$failed"
}

check_linux_gofmt() {
  local unformatted
  unformatted="$(gofmt -l .)" || return 1
  if [[ -n "$unformatted" ]]; then
    echo "gofmt needed:" >&2
    echo "$unformatted" >&2
    return 1
  fi
}

# Host-free Linux checks. Privileged route/DNS behavior needs real Ubuntu VMs
test_linux() {
  cd "$ROOT/Frontend/Linux" || return 1
  linux_style() {
    run_check "Linux Go format" check_linux_gofmt
    run_check "Linux installer syntax" bash -n install/install.sh
  }
  linux_vet() {
    run_check "Linux Go vet (host)" go vet ./...
    run_check "Linux Go vet (linux/amd64)" env GOOS=linux GOARCH=amd64 go vet ./...
    run_check "Linux Go vet (linux/arm64)" env GOOS=linux GOARCH=arm64 go vet ./...
  }
  linux_tests() { run_check "Linux Go tests" go test -race -count=1 ./...; }
  linux_builds() {
    local arch
    for arch in amd64 arm64; do
      run_check "Linux $arch static build" \
        env CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -trimpath -o /dev/null ./cmd/...
    done
  }
  run_parallel linux_style linux_vet linux_tests linux_builds
}

infra_validation() {
  cd "$ROOT" || return 1

  run_check "Test runner routing and failure handling" python3 -m unittest scripts/test_test_runner.py

  if [[ ! -d Infrastructure/OCI/terraform/.terraform || ! -f Infrastructure/OCI/terraform/.terraform.lock.hcl ]]; then
    echo "Initializing Terraform providers"
    run_check "Terraform init" terraform -chdir=Infrastructure/OCI/terraform init -backend=false -input=false || return 1
  fi
  run_check "Terraform format" terraform -chdir=Infrastructure/OCI/terraform fmt -check
  run_check "Terraform validate" terraform -chdir=Infrastructure/OCI/terraform validate

  for script in Infrastructure/OCI/host/*.sh scripts/*.sh; do
    run_check "parse $script" bash -n "$script"
  done

  for template in Infrastructure/OCI/terraform/*.tftpl; do
    run_check "parse $template" bash -n "$template"
  done

  run_check "Unbound forwards over DoT" grep -Fq 'forward-tls-upstream: yes' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound DoT cert bundle" grep -Fq 'tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound DNSSEC trust anchor fallback" grep -Fq 'UNBOUND_TRUST_ANCHOR_LINE=' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound DNSSEC is required" grep -Fq 'DNSSEC validation requires /var/lib/unbound/root.key' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound DNSSEC no fail-soft" sh -c '! grep -Fq "continuing without DNSSEC validation" Infrastructure/OCI/host/bootstrap.sh'
  run_check "Unbound DNSSEC duplicate trust anchor guard" grep -Fq 'Existing Unbound config already declares /var/lib/unbound/root.key' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound DoT upstream Quad9" grep -Fq '9.9.9.9@853#dns.quad9.net' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound DoT upstream Mullvad" grep -Fq '194.242.2.2@853#dns.mullvad.net' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound DoT upstream DNS.SB" grep -Fq '185.222.222.222@853#dns.sb' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound no recursive root-hints override" sh -c '! grep -Fq "root-hints:" Infrastructure/OCI/host/bootstrap.sh'
  run_check "Unbound no plaintext recursion fallback" grep -Fq 'forward-first: no' Infrastructure/OCI/host/bootstrap.sh
  run_check "AdGuard upstream is local Unbound" grep -Fq '127.0.0.1:$UNBOUND_LISTEN_PORT' Infrastructure/OCI/host/bootstrap.sh
  run_check "AdGuard DNSSEC enabled" grep -Fq 'enable_dnssec: true' Infrastructure/OCI/host/bootstrap.sh

  run_check "Caddy release version format" grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+$' Infrastructure/OCI/caddy/VERSION
  run_check "Caddy Dockerfile target asset" grep -Fq 'cloudgateway-caddy-linux-arm64' Infrastructure/OCI/caddy/Dockerfile
  run_check "Caddy Dockerfile rate limit module" grep -Fq 'github.com/mholt/caddy-ratelimit' Infrastructure/OCI/caddy/Dockerfile

  run_check "Terraform preflight compile" python3 -m py_compile scripts/terraform-preflight.py
  run_check "Terraform  preflight tests" python3 -m unittest scripts/test_terraform_preflight.py
  run_check "Terraform wrapper compile" python3 -m py_compile scripts/test_terraform_wrapper.py
  run_check "Terraform wrapper tests" python3 -m unittest scripts/test_terraform_wrapper.py

  run_check "Firestore backup compile" python3 -m py_compile scripts/backup_firestore.py scripts/test_backup_firestore.py
  run_check "Firestore backup tests" python3 -m unittest scripts/test_backup_firestore.py

  # bash -n above only parses the shell; these exercise the Python embedded in
  # the ios-release heredocs (JWT signer + version bumper) so a release-only
  # code path is validated locally instead of first failing during a release.
  run_check "iOS release compile" python3 -m py_compile scripts/test_ios_release.py
  run_check "iOS release tests" python3 -m unittest scripts/test_ios_release.py
}

test_infra() {
  infra_types() {
    run_pyright "Infra tools pyright" \
      scripts/terraform-preflight.py scripts/test_terraform_preflight.py \
      scripts/test_terraform_wrapper.py scripts/backup_firestore.py \
      scripts/test_backup_firestore.py scripts/test_ios_release.py
  }
  run_parallel infra_validation infra_types
}

run_step() {
  local name="$1"
  shift
  echo
  echo "============================================================"
  echo "==> $name"
  echo "============================================================"
  # Run directly (not in a subshell) so the step's run_check failures land in
  # FAILURES. Each target cd's to its own dir first, so a leaked cwd is fine.
  # Judge the target by both its return status and any failures it recorded.
  local before=${#FAILURES[@]}
  local status=0
  "$@" || status=$?
  if [[ "$status" -ne 0 ]]; then
    if [[ ${#FAILURES[@]} -eq $before ]]; then
      FAILURES+=("$name")
    fi
    echo "FAILED: $name" >&2
    return "$status"
  fi
  if [[ ${#FAILURES[@]} -gt $before ]]; then
    echo "FAILED: $name" >&2
    return 1
  fi
  echo "OK: $name"
  return 0
}

# Each worker owns its cwd, failure list, and log. Merge every failure after wait
run_parallel() {
  if [[ "${TEST_PARALLEL:-1}" -eq 0 ]]; then
    local job failed=0 directory="$PWD"
    for job in "$@"; do
      cd "$directory" || return 1
      run_step "$job" "$job" || failed=1
    done
    cd "$directory" || return 1
    return "$failed"
  fi
  local directory
  if ! directory="$(mktemp -d "$TEST_RUN_DIR/group.XXXXXX")"; then
    FAILURES+=("Parallel worker logs")
    return 1
  fi
  local pids=() names=() job
  for job in "$@"; do
    echo "Starting: $job"
    (
      FAILURES=()
      status=0
      run_step "$job" "$job" || status=$?
      if [[ ${#FAILURES[@]} -gt 0 ]]; then
        printf '%s\n' "${FAILURES[@]}" > "$directory/$job.failures"
      fi
      exit "$status"
    ) > "$directory/$job.log" 2>&1 &
    pids+=("$!")
    names+=("$job")
  done
  local index failed=0 failure status
  for ((index=0; index<${#pids[@]}; index++)); do
    job="${names[$index]}"
    status=0
    wait "${pids[$index]}" || status=$?
    if [[ "$status" -ne 0 ]]; then
      failed=1
      if [[ ! -s "$directory/$job.failures" ]]; then
        FAILURES+=("$job")
      fi
    fi
    if [[ "${PARALLEL_PROGRESS:-0}" -eq 0 || "$status" -ne 0 || -s "$directory/$job.failures" ]]; then
      cat "$directory/$job.log"
    fi
    if [[ -f "$directory/$job.failures" ]]; then
      while IFS= read -r failure; do
        FAILURES+=("$failure")
        failed=1
      done < "$directory/$job.failures"
    fi
  done
  return "$failed"
}

test_service_targets() {
  local jobs=() target failed=0
  for target in "${SERVICE_TARGETS[@]}"; do
    if [[ "$target" != firebase ]]; then jobs+=("test_$target"); fi
  done
  if [[ ${#jobs[@]} -gt 0 ]]; then
    run_parallel "${jobs[@]}" || failed=1
  fi
  # Let short CPU-heavy checks finish before emulator transaction contention tests
  if [[ " ${SERVICE_TARGETS[*]} " == *" firebase "* ]]; then
    run_step firebase test_firebase || failed=1
  fi
  return "$failed"
}

test_apple_projects() {
  local jobs=() target
  for target in "${APPLE_TARGETS[@]}"; do
    jobs+=("test_$target")
  done
  # Signing stays sequential; unsigned projects use separate DerivedData and scan caches
  if [[ "$APPLE_SIGNED" -eq 1 ]]; then
    local TEST_PARALLEL=0
    run_parallel "${jobs[@]}"
  else
    run_parallel "${jobs[@]}"
  fi
}

test_apple_targets() {
  local jobs=(apple_wireguard_tests apple_kit_tests apple_firebase_tests)
  if [[ " ${APPLE_TARGETS[*]} " == *" macos "* ]]; then
    jobs+=(apple_macos_core_tests)
  fi
  jobs+=(test_apple_projects)
  run_parallel "${jobs[@]}"
}

targets=()
for arg in "$@"; do
  case "$arg" in
    --signed) APPLE_SIGNED=1 ;;
    --serial) TEST_PARALLEL=0 ;;
    api|web|app|ios|macos|apple|infra|firebase|linux) targets+=("$arg") ;;
    *)
      echo "Unknown target: $arg (expected: api, web, ios, macos, apple, infra, firebase, linux; optional flags: --signed, --serial)" >&2
      exit 2
      ;;
  esac
done

if [[ ${#targets[@]} -eq 0 ]]; then
  # Targets overlap and Apple builds are unsigned by default; pass --signed to sign
  # Non-macOS/CI runners should pass explicit targets instead.
  targets=(api web infra firebase linux apple)
fi

expanded_targets=()
for target in "${targets[@]}"; do
  case "$target" in
    apple) expanded_targets+=(ios macos) ;;
    app) expanded_targets+=(web) ;;
    *) expanded_targets+=("$target") ;;
  esac
done

# Finish shared environment writes before any Python consumers start
for target in "${expanded_targets[@]}"; do
  case "$target" in
    api|infra|firebase)
      ensure_api_python_tools || API_PYTHON_TOOLS_READY=-1
      break
      ;;
  esac
done

mkdir -p "$ROOT/.deps/test-runs" || exit 1
TEST_RUN_DIR="$(mktemp -d "$ROOT/.deps/test-runs/run.XXXXXX")" || exit 1
echo "Parallel logs: $TEST_RUN_DIR"
PARALLEL_PROGRESS="$TEST_PARALLEL"
exec 3>&1
completed_targets=" "
jobs=()
APPLE_TARGETS=()
SERVICE_TARGETS=()
for target in "${expanded_targets[@]}"; do
  if [[ "$completed_targets" == *" $target "* ]]; then
    continue
  fi
  completed_targets+="$target "
  case "$target" in
    api|web|infra|firebase)
      if [[ ${#SERVICE_TARGETS[@]} -eq 0 ]]; then
        jobs+=(test_service_targets)
      fi
      SERVICE_TARGETS+=("$target")
      ;;
    ios|macos)
      if [[ ${#APPLE_TARGETS[@]} -eq 0 ]]; then
        jobs+=(test_apple_targets)
      fi
      APPLE_TARGETS+=("$target")
      ;;
    *) jobs+=("test_$target") ;;
  esac
done
run_parallel "${jobs[@]}"

echo
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "FAILED: ${FAILURES[*]}"
  exit 1
fi
echo "All checks passed."
exit 0
