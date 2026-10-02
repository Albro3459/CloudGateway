#!/bin/bash

# Runs every local test/validation suite for the repo.
#
# Usage:
#   ./scripts/test.sh            # run everything (Apple builds unsigned)
#   ./scripts/test.sh --signed   # run everything with signed Apple builds
#   ./scripts/test.sh api        # API only
#   ./scripts/test.sh apple      # Apple tests + unsigned no-device iOS build
#   ./scripts/test.sh apple --signed  # Apple tests + signed no-device iOS build
#   ./scripts/test.sh macos      # macOS tests + unsigned arm64 app/extension build
#   ./scripts/test.sh macos --signed  # signed macOS build + entitlement/profile checks
#   ./scripts/test.sh web infra  # any combination of: api web infra apple macos firebase
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

# Run a named command, recording it in FAILURES on failure. Never aborts, so
# later steps still run. Returns the command's exit code.
run_check() {
  local name="$1"
  shift
  echo "--- $name ---"
  if "$@"; then
    echo "OK: $name"
    return 0
  fi
  echo "FAILED: $name" >&2
  FAILURES+=("$name")
  return 1
}

ensure_api_python_tools() {
  cd "$ROOT/Backend/API" || return 1

  if [[ "$API_PYTHON_TOOLS_READY" -eq 1 ]]; then
    return 0
  fi

  if [[ ! -x .venv/bin/python ]]; then
    echo "Creating Backend/API/.venv"
    run_check "API venv create" python3 -m venv .venv || return 1
    run_check "API pip upgrade" ./.venv/bin/python -m pip install --quiet --upgrade pip || return 1
  fi
  # Upsert dependencies from pyproject every run (like `npm i`) so new deps are
  # picked up on an existing venv. pip is a no-op when everything is satisfied.
  echo "Syncing API dependencies"
  run_check "API dependency sync" ./.venv/bin/python -m pip install --quiet -e '.[dev]' || return 1
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

  run_check "API compile" ./.venv/bin/python -m compileall -q src tests
  run_pyright "API pyright" Backend/API/src Backend/API/tests
  cd "$ROOT/Backend/API" || return 1
  # Dead-code enforcement via vulture (see [tool.vulture] in pyproject.toml),
  # mirroring the Web knip and Apple Periphery scans: unused code fails the
  # target. vulture reads its config from pyproject.toml when run from here.
  run_check "API dead code (vulture)" ./.venv/bin/vulture
  run_check "API pytest" ./.venv/bin/python -m pytest
}

test_web() {
  cd "$ROOT/Frontend/Web" || return 1

  run_check "React deployment script syntax" bash -n "$ROOT/scripts/deploy-react.sh"
  if [[ ! -d node_modules ]]; then
    echo "Installing Web dependencies"
    run_check "Web dependency install" npm install || return 1
  fi

  run_check "Web Jest" env CI=true npm run test -- --watchAll=false --runInBand
  run_check "Web TypeScript" npx tsc --noEmit
  # Dead-code enforcement via knip (see Frontend/Web/knip.json), mirroring the
  # Apple Periphery scans: unused files/exports/deps fail the target.
  run_check "Web dead code (knip)" npx --no-install knip
  run_check "Web production build" npm run build
}

test_firebase() {
  ensure_api_python_tools || return 1
  cd "$ROOT/Backend/Firebase" || return 1

  if [[ ! -d node_modules ]]; then
    echo "Installing Firebase rules-test dependencies"
    run_check "Firebase dependency install" npm install || return 1
  fi

  run_check "Firebase schema and tests typecheck" npm run typecheck
  run_pyright "Device auth tools pyright" scripts/device-auth-client.py scripts/test_device_auth_client.py scripts/test_firebase_emulators.py
  cd "$ROOT" || return 1
  run_check "Device auth test client" Backend/API/.venv/bin/python -m unittest scripts/test_device_auth_client.py
  cd "$ROOT/Backend/Firebase" || return 1

  run_firebase_emulator_tests() {
    env FIREBASE_CLI_DISABLE_UPDATE_CHECK=true npm exec -- firebase emulators:exec --only auth,firestore --project demo-cloudgateway "../API/.venv/bin/python ../../scripts/test_firebase_emulators.py" 2> >(
      grep -Ev "^(lsof: WARNING: can't stat\\(\\)|      Output information may be incomplete\\.|      assuming \"dev=)" >&2
    )
  }

  # Both suites share one offline demo-project emulator lifetime
  run_check "Firebase rules and API exchange tests" run_firebase_emulator_tests
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

# Dead-code enforcement via Periphery, three strict scans (see
# Frontend/Apple/.periphery.yml for why three): the app xcodeproj scan covers
# all production code including unused public shared API, and the two SPM
# scans (which build the test targets) cover dead test code. --strict makes
# any finding fail the target.
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
      --schemes CloudGateway --schemes CloudGatewayScreenshots ||
    failed=1
  run_check "Apple dead code: Kit tests" \
    periphery scan --quiet --strict \
      --config "$ROOT/Frontend/Apple/.periphery.yml" \
      --project-root "$ROOT/Frontend/Apple/CloudGatewayKit" \
      --report-include "**/Tests/**" ||
    failed=1
  run_check "Apple dead code: Firebase adapter tests" \
    periphery scan --quiet --strict \
      --config "$ROOT/Frontend/Apple/.periphery.yml" \
      --project-root "$ROOT/Frontend/Apple/CloudGatewayFirebaseAdapter" \
      --report-include "**/Tests/**" ||
    failed=1
  return "$failed"
}

test_apple() {
  cd "$ROOT" || return 1

  local failed=0

  scan_apple_dead_code ||
    failed=1

  run_check "Apple release script syntax" \
    bash -n scripts/ios-release.sh ||
    failed=1
  run_check "Apple Kit and AppCore package tests" \
    swift test --package-path Frontend/Apple/CloudGatewayKit ||
    failed=1
  run_check "Apple Firebase auth adapter tests" \
    swift test --package-path Frontend/Apple/CloudGatewayFirebaseAdapter ||
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
  run_check "macOS dead code: app and extension" \
    periphery scan --quiet --strict \
      --config "$ROOT/Frontend/Apple/macOS/.periphery.yml" \
      --project "$ROOT/Frontend/Apple/macOS/CloudGateway.xcodeproj" \
      --schemes CloudGateway --report-include "**/macOS/**" ||
    failed=1
  run_check "macOS dead code: host-free tests" \
    periphery scan --quiet --strict \
      --config "$ROOT/Frontend/Apple/macOS/.periphery.yml" \
      --project-root "$ROOT/Frontend/Apple/macOS/CloudGatewayMacCore" \
      --report-include "**/Tests/**" ||
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
  run_check "macOS Kit and AppCore package tests" \
    swift test --package-path Frontend/Apple/CloudGatewayKit ||
    failed=1
  run_check "macOS Firebase auth adapter tests" \
    swift test --package-path Frontend/Apple/CloudGatewayFirebaseAdapter ||
    failed=1
  run_check "macOS host-free core and IPC tests" \
    swift test --package-path Frontend/Apple/macOS/CloudGatewayMacCore ||
    failed=1
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
          "$derived_data/Build/Products/$configuration/CloudGateway.app" --signed ||
        failed=1
    else
      run_check "macOS bundle packaging verification" \
        python3 scripts/verify_macos_build.py \
          "$derived_data/Build/Products/$configuration/CloudGateway.app" ||
        failed=1
    fi
  else
    failed=1
  fi
  return "$failed"
}

test_infra() {
  cd "$ROOT" || return 1

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

  run_pyright "Terraform preflight pyright" scripts/terraform-preflight.py scripts/test_terraform_preflight.py
  run_check "Terraform preflight compile" python3 -m py_compile scripts/terraform-preflight.py
  run_check "Terraform  preflight tests" python3 -m unittest scripts/test_terraform_preflight.py
  run_pyright "Terraform wrapper pyright" scripts/test_terraform_wrapper.py
  run_check "Terraform wrapper compile" python3 -m py_compile scripts/test_terraform_wrapper.py
  run_check "Terraform wrapper tests" python3 -m unittest scripts/test_terraform_wrapper.py

  run_pyright "Firestore backup pyright" scripts/backup_firestore.py scripts/test_backup_firestore.py
  run_check "Firestore backup compile" python3 -m py_compile scripts/backup_firestore.py scripts/test_backup_firestore.py
  run_check "Firestore backup tests" python3 -m unittest scripts/test_backup_firestore.py

  # bash -n above only parses the shell; these exercise the Python embedded in
  # the ios-release heredocs (JWT signer + version bumper) so a release-only
  # code path is validated locally instead of first failing during a release.
  run_pyright "iOS release pyright" scripts/test_ios_release.py
  run_check "iOS release compile" python3 -m py_compile scripts/test_ios_release.py
  run_check "iOS release tests" python3 -m unittest scripts/test_ios_release.py
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

targets=()
for arg in "$@"; do
  case "$arg" in
    --signed) APPLE_SIGNED=1 ;;
    *) targets+=("$arg") ;;
  esac
done

if [[ ${#targets[@]} -eq 0 ]]; then
  # Apple builds run last and unsigned by default; pass --signed to sign.
  # Non-macOS/CI runners should pass explicit targets instead.
  targets=(api web infra firebase macos apple)
fi

for target in "${targets[@]}"; do
  case "$target" in
    api) run_step "API tests (pyright + pytest + compile)" test_api ;;
    web|app) run_step "Web tests + typecheck + build (jest + tsc + CRA)" test_web ;;
    apple) run_step "Apple tests + no-device iOS build" test_apple ;;
    macos) run_step "macOS tests + arm64 app and system extension build" test_macos ;;
    infra) run_step "Infra validation (terraform + script parse)" test_infra ;;
    firebase) run_step "Firebase schema, rules and API exchange tests (emulators)" test_firebase ;;
    *)
      echo "Unknown target: $target (expected: api, web, apple, macos, infra, firebase; optional flag: --signed)" >&2
      exit 2
      ;;
  esac
done

echo
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "FAILED: ${FAILURES[*]}"
  exit 1
fi
echo "All checks passed."
exit 0
